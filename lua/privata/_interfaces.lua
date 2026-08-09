--- The declared public surface: tach's `interfaces` and `modules` tables.
--
-- privata infers publicness from usage inside the checkout, which is exactly
-- right for an application and exactly wrong for a library: its callers are
-- somewhere else by definition, so its whole API looks like drift. The answer
-- is a declaration, and tach already has the vocabulary for one --
-- `[[interfaces]]` says which names a module publishes, `[[modules]]` says
-- which code is not tach's business at all -- so privata reads the same two
-- tables rather than inventing a third spelling of the same idea.
--
-- Only what privata can act on is acted on. An interface's `expose` and `from`
-- decide which symbols stay public; a module's `unchecked` decides which files
-- are reported at all. `depends_on`, `layer`, `visibility` and the rest are
-- accepted and validated, because a `tach.lua` is going to contain them, but
-- they describe an import graph and privata does not check imports.

local patterns = require("privata._patterns")

local M = {}
local _P = {}

--- What an interface with no `from` applies to, matching tach: every module.
_P.DEFAULT_FROM = { ".*" }

--- Keys an `interfaces` entry may carry, and how each is checked.
--
-- The whole tach shape rather than the two fields privata reads, so a config
-- shared with tach loads here unchanged. Anything outside this set is refused,
-- which is what tach does too: a misspelled key is a rule that silently is not
-- applied, and both tools exist to argue against exactly that.
_P.INTERFACE_KEYS = {
  expose = "regexes",
  from = "regexes",
  visibility = "strings",
  data_types = "data_types",
  exclusive = "boolean",
}

_P.DATA_TYPES = { all = true, primitive = true }

--- Keys a `modules` entry may carry.
_P.MODULE_KEYS = {
  path = "module_glob",
  paths = "module_globs",
  depends_on = "dependencies",
  cannot_depend_on = "dependencies",
  depends_on_external = "strings",
  cannot_depend_on_external = "strings",
  layer = "string",
  visibility = "strings",
  utility = "boolean",
  unchecked = "boolean",
}

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

--- Check one field of one entry, collecting problems rather than stopping.
---@param kind string  a value of `_P.INTERFACE_KEYS` or `_P.MODULE_KEYS`
---@param label string  how the problem should name this field
---@param value any
---@param problems string[]  appended to in place
function _P.check_field(kind, label, value, problems)
  if kind == "boolean" then
    if type(value) ~= "boolean" then
      problems[#problems + 1] = label .. " must be true or false"
    end
  elseif kind == "string" then
    if type(value) ~= "string" then
      problems[#problems + 1] = label .. " must be a string"
    end
  elseif kind == "strings" then
    if not _P.is_string_list(value) then
      problems[#problems + 1] = label .. " must be a list of strings"
    end
  elseif kind == "data_types" then
    if not _P.DATA_TYPES[value] then
      problems[#problems + 1] = label .. " must be 'all' or 'primitive'"
    end
  elseif kind == "regexes" then
    if not _P.is_string_list(value) then
      problems[#problems + 1] = label .. " must be a list of patterns"
    else
      for i = 1, #value do
        local _, reason = patterns.from_regex(value[i])
        if reason then
          problems[#problems + 1] = label .. " '" .. value[i] .. "': " .. reason
        end
      end
    end
  elseif kind == "module_glob" or kind == "module_globs" then
    local list = kind == "module_glob" and { value } or value
    if kind == "module_globs" and not _P.is_string_list(value) then
      problems[#problems + 1] = label .. " must be a list of module paths"
      return
    end
    if kind == "module_glob" and type(value) ~= "string" then
      problems[#problems + 1] = label .. " must be a module path"
      return
    end
    for i = 1, #list do
      local _, reason = patterns.from_module_glob(list[i])
      if reason then
        problems[#problems + 1] = label .. " '" .. list[i] .. "': " .. reason
      end
    end
  elseif kind == "dependencies" then
    -- tach lets a dependency be a bare path or `{ path = ..., deprecated = ...}`.
    -- privata never reads either, but a config it refuses to load is a config
    -- that cannot be shared with tach.
    if type(value) ~= "table" then
      problems[#problems + 1] = label .. " must be a list"
      return
    end
    for i = 1, #value do
      local entry = value[i]
      if type(entry) == "table" then
        if type(entry.path) ~= "string" then
          problems[#problems + 1] = label .. " entries need a string `path`"
        end
      elseif type(entry) ~= "string" then
        problems[#problems + 1] = label .. " entries must be strings or tables"
      end
    end
  end
end

--- Validate a list of entries against one key table.
---@param entries any  the raw `interfaces` or `modules` value
---@param keys table<string, string>
---@param name string  "interfaces" or "modules", for the problem text
---@param problems string[]  appended to in place
function _P.check_entries(entries, keys, name, problems)
  if entries == nil then
    return
  end
  if type(entries) ~= "table" or (next(entries) ~= nil and #entries == 0) then
    problems[#problems + 1] = name .. " must be a list of tables"
    return
  end

  for index = 1, #entries do
    local entry = entries[index]
    local label = string.format("%s[%d]", name, index)
    if type(entry) ~= "table" then
      problems[#problems + 1] = label .. " must be a table"
    else
      for key, value in pairs(entry) do
        local kind = keys[key]
        if kind == nil then
          problems[#problems + 1] = label .. ": unknown setting '" .. tostring(key) .. "'"
        else
          _P.check_field(kind, label .. "." .. key, value, problems)
        end
      end
    end
  end
end

--- Report everything wrong with a config's `interfaces` and `modules`.
--
-- Every problem, not the first: a user fixing a config file wants the list.
---@param config table  anything carrying `interfaces` and `modules` keys
---@return string[]  empty when both tables are usable
function M.problems(config)
  local problems = {}

  _P.check_entries(config.interfaces, _P.INTERFACE_KEYS, "interfaces", problems)
  for index = 1, #(config.interfaces or {}) do
    local entry = config.interfaces[index]
    if type(entry) == "table" and entry.expose == nil then
      problems[#problems + 1] = string.format("interfaces[%d] needs an `expose` list", index)
    end
  end

  _P.check_entries(config.modules, _P.MODULE_KEYS, "modules", problems)
  for index = 1, #(config.modules or {}) do
    local entry = config.modules[index]
    if type(entry) == "table" and entry.path == nil and entry.paths == nil then
      problems[#problems + 1] = string.format("modules[%d] needs a `path` or `paths`", index)
    end
  end

  return problems
end

--- Translate a list of regexes, dropping any that will not compile.
--
-- Compiling twice -- once to validate, once here -- is deliberate: this runs
-- against a config the loader already accepted, so a failure at this point
-- cannot be reported to anyone, and silently keeping a pattern that does not
-- mean what it says would be worse than dropping it.
---@param sources string[]
---@return string[]  Lua patterns
function _P.compile_regexes(sources)
  local out = {}
  for i = 1, #sources do
    local pattern = patterns.from_regex(sources[i])
    if pattern then
      out[#out + 1] = pattern
    end
  end
  return out
end

--- The declared surface of one scan, in the form the checks ask questions of.
---@class privata.Surface
---@field interfaces { expose: string[], from: string[] }[]
---@field modules { paths: string[], unchecked: boolean }[]

--- Compile a config's declarations once, for a whole run.
---@param config privata.Config
---@return privata.Surface
function M.compile(config)
  local surface = { interfaces = {}, modules = {} }

  for index = 1, #(config.interfaces or {}) do
    local entry = config.interfaces[index]
    surface.interfaces[#surface.interfaces + 1] = {
      expose = _P.compile_regexes(entry.expose or {}),
      from = _P.compile_regexes(entry.from or _P.DEFAULT_FROM),
    }
  end

  for index = 1, #(config.modules or {}) do
    local entry = config.modules[index]
    local declared = entry.paths or { entry.path }
    local paths = {}
    for i = 1, #declared do
      -- Dropped rather than kept on a translation failure, for the reason
      -- `_P.compile_regexes` gives: the loader accepted this config already, so
      -- there is nobody left to report to.
      local compiled = patterns.from_module_glob(declared[i]) or {}
      for j = 1, #compiled do
        paths[#paths + 1] = compiled[j]
      end
    end
    surface.modules[#surface.modules + 1] = {
      paths = paths,
      unchecked = entry.unchecked == true,
    }
  end

  return surface
end

--- True when a declared interface publishes `symbol_name` out of `module_name`.
--
-- Both halves have to match the same entry: `{ expose = { "setup" } }` says
-- every module's `setup` is public and says nothing about anything else, while
-- `{ expose = { ".*" }, from = { "mylib" } }` says all of `mylib` is.
---@param surface privata.Surface
---@param module_name string
---@param symbol_name string
---@return boolean
function M.exposes(surface, module_name, symbol_name)
  for i = 1, #surface.interfaces do
    local entry = surface.interfaces[i]
    if patterns.any(entry.from, module_name) and patterns.any(entry.expose, symbol_name) then
      return true
    end
  end
  return false
end

--- True for a module the config declares `unchecked`.
--
-- tach's `unchecked` means "do not check this module's imports"; the same
-- sentence in privata's terms is "do not report anything inside this module".
-- What it does not mean is that other modules stop being checked against it: a
-- file loaded by a host is still a file whose private names nobody else may
-- read.
---@param surface privata.Surface
---@param module_name string
---@return boolean
function M.is_unchecked(surface, module_name)
  for i = 1, #surface.modules do
    local entry = surface.modules[i]
    if entry.unchecked and patterns.any(entry.paths, module_name) then
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
