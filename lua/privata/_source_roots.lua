--- Where to look, what to skip, and what a file's module name is.

local fs = require("privata._fs")
local rockspec = require("privata._rockspec")

local M = {}
local _P = {}

--- Directories that never hold production modules.
--
-- Test directories are in this set, which is what makes "test usage does not
-- confer publicity" the default: a file under `spec/` is not scanned as a
-- module at all unless the config names that directory a test root, at which
-- point it is scanned under the co-located-helper rule instead.
_P.IGNORED_DIRECTORIES = {
  [".git"] = true,
  [".github"] = true,
  [".luarocks"] = true,
  ["lua_modules"] = true,
  ["node_modules"] = true,
  ["deps"] = true,
  ["vendor"] = true,
  ["build"] = true,
  ["doc"] = true,
  ["docs"] = true,
  ["spec"] = true,
  ["test"] = true,
  ["tests"] = true,
}

--- Filename patterns that mark a busted or luaunit test file.
_P.TEST_FILE_PATTERNS = {
  "^.+_spec%.lua$",
  "^.+_test%.lua$",
  "^test_.+%.lua$",
}

_P.DEFAULT_TEST_ROOTS = { "spec", "test", "tests" }

--- Roots tried in order when the config names none.
_P.DEFAULT_SOURCE_ROOTS = { "lua", "src" }

function M.is_test_filename(name)
  for i = 1, #_P.TEST_FILE_PATTERNS do
    if name:find(_P.TEST_FILE_PATTERNS[i]) then
      return true
    end
  end
  return false
end

--- True for a directory privata never descends into.
--
-- Hidden directories are skipped wholesale: they hold tooling, not modules,
-- and a scan that walked `.git` would be slower than the check it performs.
function _P.is_ignored_directory(name)
  if _P.IGNORED_DIRECTORIES[name] then
    return true
  end
  return name:sub(1, 1) == "." and name ~= "." and name ~= ".."
end

--- Derive a dotted module name from a path under a source root.
--
-- `lua/foo/bar.lua` is `foo.bar`; `lua/foo/init.lua` is `foo`, because
-- `package.path` ships `?/init.lua` and that is the `__init__.py` analogue.
-- Returns nil for a root-level `init.lua`, which names no module.
function M.module_name(path, root)
  local relative = fs.relative(path, root)
  if relative == nil or relative == "." then
    return nil
  end

  local parts = {}
  for segment in relative:gmatch("[^/]+") do
    parts[#parts + 1] = segment
  end
  if #parts == 0 then
    return nil
  end

  parts[#parts] = parts[#parts]:gsub("%.lua$", "")
  if parts[#parts] == "init" then
    parts[#parts] = nil
  end
  if #parts == 0 then
    return nil
  end

  return table.concat(parts, ".")
end

--- The package path used to resolve a relative reference from this module.
function M.package_parts(module_name)
  local parts = {}
  for segment in module_name:gmatch("[^.]+") do
    parts[#parts + 1] = segment
  end
  parts[#parts] = nil
  return parts
end

function _P.existing_directories(project_root, names)
  local roots = {}
  for i = 1, #names do
    local candidate = fs.join(project_root, names[i])
    if fs.is_dir(candidate) then
      roots[#roots + 1] = fs.normalize(candidate)
    end
  end
  return roots
end

--- Resolve the source roots for a project.
--
-- Order is authority order, not convenience order:
--   1. `source_roots` in `.privata.lua` -- the user said so
--   2. the directories a rockspec's `build.modules` actually maps into --
--      an explicit name-to-file table, and a stronger signal than a directory
--      convention because it names each module outright
--   3. `lua/` then `src/`
--   4. the project root, with the ignored directories pruned
--
-- Returns the roots and a label saying which rule produced them, so the CLI
-- can tell a user why privata scanned where it did.
function M.discover(project_root, config)
  project_root = fs.normalize(project_root)

  if config and config.source_roots and #config.source_roots > 0 then
    local roots = _P.existing_directories(project_root, config.source_roots)
    if #roots > 0 then
      return roots, "config"
    end
  end

  local from_rockspec = rockspec.module_directories(project_root)
  if #from_rockspec > 0 then
    return from_rockspec, "rockspec"
  end

  local conventional = _P.existing_directories(project_root, _P.DEFAULT_SOURCE_ROOTS)
  if #conventional > 0 then
    return conventional, "convention"
  end

  return { project_root }, "project root"
end

--- Resolve the test roots, which are scanned only as consumers.
function M.discover_test_roots(project_root, config)
  local names = (config and config.test_roots) or _P.DEFAULT_TEST_ROOTS
  return _P.existing_directories(project_root, names)
end

--- The directory filter handed to `_fs.list_lua_files` for a production scan.
--
-- Configured exclusions are applied afterwards, against the project root, not
-- here: a scan can have several source roots, so a rule resolved relative to
-- whichever root happened to be current would mean different things per root.
function M.production_skip()
  return function(name)
    return _P.is_ignored_directory(name)
  end
end

--- The directory filter for a test root, where test directories are the point.
function M.test_skip()
  return function(name)
    if _P.IGNORED_DIRECTORIES[name] and not _P.is_test_directory_name(name) then
      return true
    end
    return name:sub(1, 1) == "." and name ~= "." and name ~= ".."
  end
end

function _P.is_test_directory_name(name)
  for i = 1, #_P.DEFAULT_TEST_ROOTS do
    if _P.DEFAULT_TEST_ROOTS[i] == name then
      return true
    end
  end
  return false
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
