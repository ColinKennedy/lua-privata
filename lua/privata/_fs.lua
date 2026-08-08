--- Filesystem access, over whichever backend the host actually provides.
--
-- Lua's standard library cannot list a directory, so a scanner has to get that
-- capability from somewhere. Requiring LuaFileSystem would put a C extension in
-- the dependency list of a tool whose whole appeal is that it drops into any
-- Lua project, so it is used when present and never demanded:
--
--   1. `vim.uv` / `vim.loop` -- privata running inside Neovim, no extra cost
--   2. `lfs` -- already installed in many rock trees, fastest of the three
--   3. `io.popen` shelling out to `find` -- the POSIX fallback that needs nothing
--
-- The popen backend is POSIX-only. Windows users are covered by the first two,
-- which is why detection prefers them rather than treating popen as normal.

local M = {}
local _P = {}

local SEPARATOR = package.config:sub(1, 1)

--- Choose a backend once, at load time.
--
-- Detection order is capability order, not preference: a host that has `vim.uv`
-- is running inside Neovim, where spawning `find` per directory would be the
-- slowest possible choice.
---@return string backend       one of "uv", "lfs", "popen"
---@return table|nil library    the backend's library, nil for "popen"
function _P.detect()
  local vim_global = rawget(_G, "vim")
  if type(vim_global) == "table" then
    local uv = vim_global.uv or vim_global.loop
    if type(uv) == "table" and uv.fs_scandir then
      return "uv", uv
    end
  end

  local ok, lfs = pcall(require, "lfs")
  if ok and type(lfs) == "table" and lfs.dir then
    return "lfs", lfs
  end

  if io.popen then
    return "popen", nil
  end

  error("privata: no filesystem backend available (need Neovim, lfs, or io.popen)", 0)
end

local BACKEND, BACKEND_LIBRARY = _P.detect()

--- The chosen backend's library. The popen backend has none, so this is an
--- empty table there and every branch that indexes it is guarded by `BACKEND`.
--- Typed loosely on purpose: `vim.uv` and `lfs` share no interface.
---@type table<string, function>
local LIB = BACKEND_LIBRARY or {}

_P.backend = BACKEND

--- Quote a path for the shell, so a directory name with a space or a quote in
--- it cannot alter the command privata runs.
---@param path string
---@return string quoted  single-quoted, safe to interpolate into a command
function _P.shell_quote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- Join path segments with the host's separator.
--
-- Empty and nil segments are dropped rather than producing a doubled
-- separator, so a caller can pass an optional subdirectory without first
-- deciding whether it has one.
---@param ... string|nil  path segments
---@return string
function M.join(...)
  local parts = { ... }
  local out = parts[1] or ""
  for i = 2, #parts do
    local part = parts[i]
    if part ~= nil and part ~= "" then
      if out == "" then
        out = part
      else
        out = out:gsub("[/\\]$", "") .. SEPARATOR .. part
      end
    end
  end
  return out
end

--- Reduce a path to a comparable form: forward slashes, no `.` segments, no
--- trailing separator, and `..` resolved where it can be resolved textually.
--
-- Paths become table keys and are compared to decide whether a file sits under
-- a source root, so two spellings of one path must not read as two places.
---@param path string
---@return string
function M.normalize(path)
  path = path:gsub("\\", "/")
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
      parts[#parts] = nil
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  local joined = table.concat(parts, "/")
  if absolute then
    return "/" .. joined
  end
  return joined == "" and "." or joined
end

--- The last segment of a path.
---@param path string
---@return string
function M.basename(path)
  return (M.normalize(path):gsub(".*/", ""))
end

--- The parent of a path: "." for a bare filename, "/" at the filesystem root.
---@param path string
---@return string
function M.dirname(path)
  local normalized = M.normalize(path)
  local parent = normalized:match("^(.*)/[^/]*$")
  if parent == nil or parent == "" then
    return normalized:sub(1, 1) == "/" and "/" or "."
  end
  return parent
end

--- True when `path` sits inside `root`, or is `root` itself.
--
-- Compares whole segments so `lua/spec` is not read as being inside `lua/spe`.
---@param path string
---@param root string
---@return boolean
function M.is_within(path, root)
  return M.relative(path, root) ~= nil
end

--- Return `path` expressed relative to `root`, or nil when it is outside.
--
-- A root of "." contains every relative path, which is not something prefix
-- matching can see: "spec/x.lua" does not start with "./". Scans are routinely
-- rooted at the current directory, so this case is the common one, not an edge.
---@param path string
---@param root string
---@return string|nil  the relative path, "." when equal, nil when outside
function M.relative(path, root)
  path, root = M.normalize(path), M.normalize(root)
  if path == root then
    return "."
  end
  if root == "." then
    -- Written long-hand: `cond and nil or path` always yields `path`, because
    -- `nil` is falsy and the `or` takes over.
    if path:sub(1, 1) == "/" then
      return nil
    end
    return path
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return nil
end

--- Read a whole file as a string.
--
-- Opened in binary mode so a CRLF checkout is not silently rewritten on the way
-- in: the lexer counts lines itself, and a translated newline would shift every
-- line number in the report.
---@param path string
---@return string|nil content
---@return string|nil error    set only when `content` is nil
function M.read_file(path)
  local handle, err = io.open(path, "rb")
  if not handle then
    return nil, err or ("cannot open " .. path)
  end
  local content = handle:read("*a")
  handle:close()
  if content == nil then
    return nil, "cannot read " .. path
  end
  return content
end

--- The libuv stat type of `path`, or nil when it cannot be stat'ed.
---@param path string
---@return string|nil  "file", "directory", ... as libuv reports it
function _P.uv_stat_type(path)
  local stat = LIB.fs_stat(path)
  return stat and stat.type or nil
end

--- True when `path` is a directory.
--
-- The popen fallback asks `find` rather than trying to open the path, because
-- opening a directory succeeds on some platforms and fails on others.
---@param path string
---@return boolean
function M.is_dir(path)
  if BACKEND == "uv" then
    return _P.uv_stat_type(path) == "directory"
  elseif BACKEND == "lfs" then
    return LIB.attributes(path, "mode") == "directory"
  end
  local pipe = io.popen("find " .. _P.shell_quote(path) .. " -maxdepth 0 -type d 2>/dev/null")
  if not pipe then
    return false
  end
  local output = pipe:read("*a")
  pipe:close()
  return output ~= nil and output ~= ""
end

--- True when `path` is a regular file.
--
-- The popen fallback opens the path and then rules out a directory, since a
-- successful open proves only that something is there.
---@param path string
---@return boolean
function M.is_file(path)
  if BACKEND == "uv" then
    return _P.uv_stat_type(path) == "file"
  elseif BACKEND == "lfs" then
    return LIB.attributes(path, "mode") == "file"
  end
  local handle = io.open(path, "rb")
  if not handle then
    return false
  end
  handle:close()
  return not M.is_dir(path)
end

--- The current working directory, normalized. Falls back to "." if unreadable.
---@return string
function M.cwd()
  if BACKEND == "uv" then
    return M.normalize(LIB.cwd())
  elseif BACKEND == "lfs" then
    return M.normalize(LIB.currentdir())
  end
  local pipe = io.popen("pwd")
  if not pipe then
    return "."
  end
  local output = pipe:read("*l")
  pipe:close()
  return M.normalize(output or ".")
end

--- Yield `name, type` for each entry directly inside `path`.
---
--- Only the scandir-capable backends implement this; the popen backend answers
--- the one question privata actually asks with a single `find`.
---@param path string
---@return { name: string, type: string }[]  empty when `path` cannot be read
function _P.entries(path)
  local out = {}
  if BACKEND == "uv" then
    local handle = LIB.fs_scandir(path)
    if not handle then
      return out
    end
    while true do
      local name, kind = LIB.fs_scandir_next(handle)
      if not name then
        break
      end
      out[#out + 1] = { name = name, type = kind }
    end
  elseif BACKEND == "lfs" then
    -- `lfs.dir` returns an iterator *and* a directory object that the iterator
    -- needs as its state, so both have to be carried into the generic for.
    local ok, iterator, state = pcall(LIB.dir, path)
    if not ok or type(iterator) ~= "function" then
      return out
    end
    for name in iterator, state do
      if name ~= "." and name ~= ".." then
        local mode = LIB.attributes(M.join(path, name), "mode")
        out[#out + 1] = { name = name, type = mode == "directory" and "directory" or "file" }
      end
    end
  end
  return out
end

--- Recursively collect `.lua` files under `dir`, appending to `out`.
--
-- Entries are sorted before descending so the accumulated order is the same on
-- every filesystem, not merely sorted once at the end: a caller that stops
-- early still sees a deterministic prefix.
---@param dir string                     directory currently being walked
---@param root string                    scan root, for relative paths given to `skip_dir`
---@param skip_dir nil|fun(name: string, relative: string|nil): boolean
---@param out string[]                   accumulator, appended to in place
function _P.walk_lua_files(dir, root, skip_dir, out)
  local entries = _P.entries(dir)
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  for i = 1, #entries do
    local entry = entries[i]
    local full = M.join(dir, entry.name)
    if entry.type == "directory" then
      if not (skip_dir and skip_dir(entry.name, M.relative(full, root))) then
        _P.walk_lua_files(full, root, skip_dir, out)
      end
    elseif entry.name:sub(-4) == ".lua" then
      out[#out + 1] = M.normalize(full)
    end
  end
end

--- Every `.lua` file under `root`, sorted, as normalized paths.
--
-- `skip_dir(name, relative_path)` prunes a directory before privata descends
-- into it. Pruning rather than filtering afterwards matters on the popen
-- backend too, where a vendored rock tree can hold more files than the project.
---@param root string
---@param skip_dir nil|fun(name: string, relative: string|nil): boolean
---@return string[]  normalized paths, sorted; empty when `root` is not a directory
function M.list_lua_files(root, skip_dir)
  local out = {}
  if not M.is_dir(root) then
    return out
  end

  if BACKEND == "popen" then
    local pipe = io.popen("find " .. _P.shell_quote(root) .. " -type f -name '*.lua' 2>/dev/null")
    if not pipe then
      return out
    end
    for line in pipe:lines() do
      local path = M.normalize(line)
      local relative = M.relative(path, root)
      local pruned = false
      if skip_dir and relative then
        local segments = {}
        for segment in relative:gmatch("[^/]+") do
          segments[#segments + 1] = segment
        end
        -- The last segment is the filename; only the ones before it are
        -- directories the scandir backends would have had the chance to prune.
        local walked = nil
        for i = 1, #segments - 1 do
          walked = walked and (walked .. "/" .. segments[i]) or segments[i]
          if skip_dir(segments[i], walked) then
            pruned = true
            break
          end
        end
      end
      if not pruned then
        out[#out + 1] = path
      end
    end
    pipe:close()
    table.sort(out)
    return out
  end

  _P.walk_lua_files(M.normalize(root), M.normalize(root), skip_dir, out)
  table.sort(out)
  return out
end

return M
