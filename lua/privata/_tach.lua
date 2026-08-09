--- Read a `tach.lua`, and translate what privata can act on out of it.
--
-- tach (https://github.com/gauge-sh/tach) checks that a project's modules
-- import each other the way the project says they should, and its `tach.toml`
-- already answers two questions privata has to ask as well: where the source
-- lives, and which names a module publishes on purpose. A project that has
-- answered them once should not have to answer them again in a second file with
-- different words for the same things.
--
-- So `tach.lua` is `tach.toml`'s schema written as a Lua table -- the same keys,
-- the same values, the same defaults -- and privata reads it as a *lower*
-- priority layer than `.privata.lua`. Both may be present: the shared facts live
-- in `tach.lua`, and anything privata-specific, or any point on which the two
-- tools should disagree, goes in `.privata.lua` and wins.
--
-- Every key tach accepts is accepted here, and an unknown one is refused
-- exactly as tach refuses it. Most of them describe an import graph, which
-- privata does not check; those are validated and then ignored. What is read is
-- listed in `_P.translate` below.

local fs = require("privata._fs")
local interfaces = require("privata._interfaces")
local literal = require("privata._literal")

local M = {}
local _P = {}

_P.FILENAME = "tach.lua"

--- Every top-level key `tach.toml` accepts, and how each is checked here.
--
-- "opaque" means privata validates the type and nothing more: `cache`,
-- `external`, `map` and `plugins` configure work privata does not do, and
-- type-checking their innards would be privata asserting a schema it has no
-- stake in and would have to keep in step with tach forever.
_P.KEYS = {
  modules = "entries",
  interfaces = "entries",
  layers = "layers",
  exclude = "strings",
  source_roots = "strings",
  exact = "boolean",
  ignore_type_checking_imports = "boolean",
  include_string_imports = "boolean",
  forbid_circular_dependencies = "boolean",
  layers_explicit_depends_on = "boolean",
  respect_gitignore = "respect_gitignore",
  root_module = "root_module",
  rules = "rules",
  cache = "opaque",
  external = "opaque",
  map = "opaque",
  plugins = "opaque",
}

_P.ROOT_MODULE_TREATMENTS = {
  ignore = true,
  allow = true,
  dependenciesonly = true,
  forbid = true,
}

_P.RULE_LEVELS = { error = true, warn = true, off = true }

--- The rules tach names, all of which are accepted; see `_P.translate` for the
--- one privata has an equivalent of.
_P.RULES = {
  unused_ignore_directives = true,
  require_ignore_directive_reasons = true,
  unused_external_dependencies = true,
  local_imports = true,
}

--- Locate `tach.lua`, walking up from `start` to the filesystem root.
---@param start string  directory to begin the walk at
---@return string|nil  path to `tach.lua`, or nil when no ancestor has one
function M.find_file(start)
  return fs.find_upwards(start, _P.FILENAME)
end

--- True for a dense array of strings and nothing else.
---@param value any
---@return boolean
function _P.is_string_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  if count ~= #value then
    return false
  end
  for i = 1, #value do
    if type(value[i]) ~= "string" then
      return false
    end
  end
  return true
end

--- Check one top-level key, collecting problems rather than stopping at one.
---@param key string
---@param value any
---@param problems string[]  appended to in place
function _P.check_key(key, value, problems)
  local kind = _P.KEYS[key]

  if kind == nil then
    problems[#problems + 1] = "unknown tach setting '" .. tostring(key) .. "'"
  elseif kind == "boolean" then
    if type(value) ~= "boolean" then
      problems[#problems + 1] = key .. " must be true or false"
    end
  elseif kind == "strings" then
    if not _P.is_string_list(value) then
      problems[#problems + 1] = key .. " must be a list of strings"
    end
  elseif kind == "layers" then
    -- tach writes a layer as a bare name or as `{ name = ..., closed = ... }`.
    if type(value) ~= "table" then
      problems[#problems + 1] = "layers must be a list"
    else
      for i = 1, #value do
        local entry = value[i]
        if type(entry) == "table" then
          if type(entry.name) ~= "string" then
            problems[#problems + 1] = "layers entries need a string `name`"
          end
        elseif type(entry) ~= "string" then
          problems[#problems + 1] = "layers entries must be strings or tables"
        end
      end
    end
  elseif kind == "respect_gitignore" then
    if value ~= true and value ~= false and value ~= "if_git_repo" then
      problems[#problems + 1] = "respect_gitignore must be true, false or 'if_git_repo'"
    end
  elseif kind == "root_module" then
    if not _P.ROOT_MODULE_TREATMENTS[value] then
      problems[#problems + 1] =
        "root_module must be 'ignore', 'allow', 'dependenciesonly' or 'forbid'"
    end
  elseif kind == "rules" then
    if type(value) ~= "table" then
      problems[#problems + 1] = "rules must be a table"
    else
      for rule, level in pairs(value) do
        if not _P.RULES[rule] then
          problems[#problems + 1] = "unknown rule '" .. tostring(rule) .. "'"
        elseif not _P.RULE_LEVELS[level] then
          problems[#problems + 1] = rule .. " must be 'error', 'warn' or 'off'"
        end
      end
    end
  elseif kind == "opaque" then
    if type(value) ~= "table" then
      problems[#problems + 1] = key .. " must be a table"
    end
  end
end

--- Everything wrong with a tach configuration, as a list.
---@param data table
---@return string[]  empty when the table is usable
function _P.problems(data)
  local problems = {}

  for key, value in pairs(data) do
    _P.check_key(key, value, problems)
  end

  -- `interfaces` and `modules` are checked by the module that reads them, so
  -- the same table means the same thing whichever file it arrived in.
  local shared = interfaces.problems(data)
  for i = 1, #shared do
    problems[#problems + 1] = shared[i]
  end

  table.sort(problems)
  return problems
end

--- Remove one kind from a `fail_on` list, without disturbing the rest.
---@param kinds string[]
---@param unwanted string
---@return string[]  a new list
function _P.without(kinds, unwanted)
  local out = {}
  for i = 1, #kinds do
    if kinds[i] ~= unwanted then
      out[#out + 1] = kinds[i]
    end
  end
  return out
end

--- Turn a validated tach table into a privata configuration overlay.
--
-- Only keys the file actually declares are emitted. That matters because the
-- two tools disagree about defaults -- tach's `unused_ignore_directives` is a
-- warning and privata's `stale_ignores` fails the run -- and a translation that
-- filled in tach's defaults would let the mere presence of a `tach.lua` quietly
-- change what privata does about a file that never mentions ignores.
--
-- What carries over, and why:
--
--   `source_roots`  the same question, the same answer
--   `exclude`       the same, and privata now reads its globs the way tach does
--   `interfaces`    the declared public surface; see `_interfaces`
--   `modules`       read for `unchecked`, which is "do not report this file"
--   `rules.unused_ignore_directives`
--                   tach's name for a suppression comment that suppresses
--                   nothing, which is privata's `stale_ignores` check exactly
--
-- Everything else describes which module may import which, and privata has no
-- opinion on that; it is tach's question and tach answers it.
---@param data table  a tach configuration
---@param default_fail_on string[]  privata's default `fail_on`, to narrow
---@return table<string, any>  a config overlay
function _P.translate(data, default_fail_on)
  local settings = {}

  if data.source_roots ~= nil then
    settings.source_roots = data.source_roots
  end
  if data.exclude ~= nil then
    settings.exclude = data.exclude
  end
  if data.interfaces ~= nil then
    settings.interfaces = data.interfaces
  end
  if data.modules ~= nil then
    settings.modules = data.modules
  end

  local level = data.rules and data.rules.unused_ignore_directives
  if level == "off" then
    settings.checks = { stale_ignores = false }
  elseif level == "warn" then
    -- Reported, but not a reason to fail: `fail_on` is the only setting that
    -- can say that, since switching the check off would stop it printing too.
    settings.fail_on = _P.without(default_fail_on, "stale_ignores")
  end

  return settings
end

--- Read `path` and hand back the privata settings it implies.
---@param path string  a `tach.lua`
---@param default_fail_on string[]  privata's default `fail_on`, to narrow
---@return table<string, any>|nil settings
---@return string[]|nil problems  set only when `settings` is nil
function M.load(path, default_fail_on)
  local source, read_error = fs.read_file(path)
  if not source then
    return nil, { path .. ": " .. tostring(read_error) }
  end

  local data, load_error = literal.load_returned_table(source)
  if not data then
    return nil, { path .. ": " .. tostring(load_error) }
  end

  local problems = _P.problems(data)
  if #problems > 0 then
    local labelled = {}
    for i = 1, #problems do
      labelled[i] = path .. ": " .. problems[i]
    end
    return nil, labelled
  end

  return _P.translate(data, default_fail_on)
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
