--- Read a rockspec for the facts it alone knows.
--
-- A rockspec's `build.modules` is an explicit module-name-to-file map. That is
-- a stronger statement of a project's layout than any directory convention,
-- and it is the closest Lua analogue of the source-root declaration privata's
-- Python counterpart reads from `tach.toml`.
--
-- `build.install.bin` matters for the opposite reason: a script installed on
-- PATH is public without anything ever requiring it, exactly like a console
-- entry point in `pyproject.toml`.
--
-- The file is parsed, never loaded. See `_literal` for why.

local fs = require("privata._fs")
local literal = require("privata._literal")

local M = {}
local _P = {}

--- Rockspec filenames in the project root, newest-looking first.
--
-- A checkout usually holds one; when it holds several, the `scm`/`dev` one
-- describes the working tree and the version-pinned ones describe releases, so
-- the development one wins.
function _P.find(project_root)
  local names = {}
  local pipe = io.popen
    and io.popen("ls -1 " .. _P.quote(fs.normalize(project_root)) .. "/*.rockspec 2>/dev/null")
  if pipe then
    for line in pipe:lines() do
      names[#names + 1] = fs.normalize(line)
    end
    pipe:close()
  end

  table.sort(names, function(a, b)
    local a_dev = a:find("scm") ~= nil or a:find("dev") ~= nil
    local b_dev = b:find("scm") ~= nil or b:find("dev") ~= nil
    if a_dev ~= b_dev then
      return a_dev
    end
    return a > b
  end)

  return names[1]
end

function _P.quote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- Load a rockspec's literal top-level assignments, or nil plus a reason.
function _P.load(project_root)
  local path = _P.find(project_root)
  if not path then
    return nil, "no rockspec found"
  end
  local source, read_error = fs.read_file(path)
  if not source then
    return nil, read_error
  end
  local data, parse_error = literal.load_assignments(source)
  if not data then
    return nil, parse_error
  end
  data.rockspec_path = path
  return data
end

--- The `build.modules` map, as module name to file path.
function _P.modules(project_root)
  local data = _P.load(project_root)
  if not data or type(data.build) ~= "table" then
    return {}
  end
  local modules = data.build.modules
  if type(modules) ~= "table" then
    return {}
  end

  local out = {}
  for name, target in pairs(modules) do
    -- A module may be declared as a path string or as a table describing a C
    -- build. Only the Lua ones are privata's business.
    if type(name) == "string" and type(target) == "string" and target:sub(-4) == ".lua" then
      out[name] = fs.normalize(fs.join(project_root, target))
    end
  end
  return out
end

--- Distinct directories that `build.modules` maps files into.
--
-- Deepest paths are dropped in favour of their ancestors, so a rockspec listing
-- `lua/pkg/a.lua` and `lua/pkg/sub/b.lua` yields one root, not two nested ones
-- that would make every file appear twice under two module names.
function M.module_directories(project_root)
  local modules = _P.modules(project_root)
  local roots = {}

  for name, path in pairs(modules) do
    -- Strip as many trailing path segments as the dotted name has parts; what
    -- is left is the directory that name is relative to.
    local depth = 1
    for _ in name:gmatch("%.") do
      depth = depth + 1
    end
    local directory = fs.dirname(path)
    if fs.basename(path) == "init.lua" then
      -- `pkg` living at `lua/pkg/init.lua` sits one directory deeper than
      -- `pkg` at `lua/pkg.lua`, so its name accounts for one less level.
      depth = depth + 1
    end
    for _ = 2, depth do
      directory = fs.dirname(directory)
    end
    if fs.is_dir(directory) then
      roots[directory] = true
    end
  end

  local out = {}
  for directory in pairs(roots) do
    local nested = false
    for other in pairs(roots) do
      if other ~= directory and fs.is_within(directory, other) then
        nested = true
        break
      end
    end
    if not nested then
      out[#out + 1] = directory
    end
  end

  table.sort(out)
  return out
end

--- Module names that consumers of this rock require to reach its API.
--
-- The rock's namesake module is its public interface: someone installing
-- `privata` writes `require("privata")`, and nothing inside the project needs
-- to require it for that to be true. Without this rule a library's entire API
-- reads as unused, which is the one finding a library author can be certain is
-- wrong.
--
-- Common decorations are stripped because rock names and module names drift:
-- `lua-cjson` ships `cjson`, `foo.lua` ships `foo`.
function M.api_module_names(project_root)
  local data = _P.load(project_root)
  if not data or type(data.package) ~= "string" then
    return {}
  end

  local name = data.package
  local candidates = { [name] = true }
  candidates[(name:gsub("^lua%-", ""))] = true
  candidates[(name:gsub("%-lua$", ""))] = true
  candidates[(name:gsub("%.lua$", ""))] = true

  local out = {}
  for candidate in pairs(candidates) do
    out[#out + 1] = candidate
  end
  table.sort(out)
  return out
end

--- Symbols a rockspec publishes without any module requiring them.
--
-- Every script in `build.install.bin` is reachable from a shell, so the module
-- it lives in is public no matter what the rest of the project does with it.
function M.installed_scripts(project_root)
  local data = _P.load(project_root)
  if not data or type(data.build) ~= "table" then
    return {}
  end
  local install = data.build.install
  if type(install) ~= "table" or type(install.bin) ~= "table" then
    return {}
  end

  local out = {}
  for key, value in pairs(install.bin) do
    local target = type(value) == "string" and value or nil
    if target then
      out[#out + 1] = fs.normalize(fs.join(project_root, target))
    end
    if type(key) == "string" and type(value) ~= "string" then
      out[#out + 1] = key
    end
  end
  table.sort(out)
  return out
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
