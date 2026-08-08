--- Defaults, `.privata.lua` discovery, preset merging, and validation.
--
-- Layering is defaults < preset < config file < command line, each layer
-- replacing a key outright rather than merging into it. List settings are
-- replacements for the same reason: a user who writes `test_roots = { "t" }`
-- means only `t`, and silently unioning the defaults back in would scan
-- directories they had just excluded.

local fs = require("privata._fs")
local literal = require("privata._literal")
local models = require("privata._models")

local M = {}
local _P = {}

_P.FILENAME = ".privata.lua"

--- Every setting privata reads, with its default.
--
-- `namespace` defaults to `_P` and `privatize` leads with the namespace
-- strategy because that is the recommendation that always applies: demoting to
-- a local can be illegal where a forward reference or the 200-local chunk limit
-- gets in the way, and a recommendation that cannot be followed is noise.
function _P.defaults()
  return {
    preset = nil,

    source_roots = nil,
    test_roots = { "spec", "test", "tests" },
    exclude = {},

    privatize = { "namespace", "local_function", "underscore_field" },
    namespace = models.DEFAULT_NAMESPACE,
    local_function_style = "statement",
    local_function_forward_decl = true,
    max_locals = 180,

    private_module_patterns = { "^_" },

    -- Package prefixes inside which a private name may be read by a sibling.
    -- Empty by default: for a library, a sibling reaching into another module's
    -- internals is still worth knowing about. An application whose modules all
    -- live under one package says so here.
    package_private = {},

    -- Which finding kinds make the run exit non-zero. Every kind by default,
    -- so behaviour is unchanged; narrowing it is how a project says "report
    -- this but do not block on it", which `checks` cannot express because
    -- switching a check off also stops it reporting.
    fail_on = {
      "unparsable",
      "collisions",
      "unanalyzable",
      "symbols",
      "globals",
      "exported_namespaces",
      "private_modules",
      "private_symbols",
      "exports",
      "methods",
    },

    globals = {},

    entrypoint_globs = {},
    entrypoint_names = {},
    entrypoint_modules = {},

    methods = false,
    skip_unparsable_files = false,
    skip_module_collisions = false,
    format = "text",

    checks = {
      symbols = true,
      globals = true,
      exported_namespaces = true,
      private_modules = true,
      private_symbols = true,
      exports = true,
      methods = false,
    },
  }
end

_P.PRIVATIZE_STRATEGIES = {
  namespace = true,
  local_function = true,
  underscore_field = true,
}

_P.FORMATS = { text = true, json = true }

_P.LOCAL_FUNCTION_STYLES = { statement = true, assignment = true }

--- Locate `.privata.lua`, walking up from `start` to the filesystem root.
--
-- Walking up means privata run from inside a subdirectory of a project still
-- honours the project's configuration, which is what every other Lua tool does.
function _P.find_file(start)
  local directory = fs.normalize(start)
  local seen = {}
  while directory and not seen[directory] do
    seen[directory] = true
    local candidate = fs.join(directory, _P.FILENAME)
    if fs.is_file(candidate) then
      return candidate
    end
    local parent = fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
  return nil
end

function _P.copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = _P.copy(item)
  end
  return out
end

--- Replace keys of `base` with those present in `overlay`.
--
-- `checks` is the one table merged key-by-key rather than replaced, because a
-- user disabling one check should not have to restate the other five.
function _P.overlay(base, overlay)
  if type(overlay) ~= "table" then
    return base
  end
  for key, value in pairs(overlay) do
    if key == "checks" and type(value) == "table" and type(base.checks) == "table" then
      for check, enabled in pairs(value) do
        base.checks[check] = enabled
      end
    else
      base[key] = _P.copy(value)
    end
  end
  return base
end

function _P.load_preset(name)
  if name == nil then
    return {}, nil
  end
  if type(name) ~= "string" then
    return nil, "preset must be a string"
  end
  local ok, preset = pcall(require, "privata._presets." .. name)
  if not ok or type(preset) ~= "table" then
    return nil, "unknown preset '" .. name .. "'"
  end
  return preset
end

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

local STRING_LISTS = {
  "source_roots",
  "test_roots",
  "exclude",
  "privatize",
  "private_module_patterns",
  "package_private",
  "fail_on",
  "globals",
  "entrypoint_globs",
  "entrypoint_names",
  "entrypoint_modules",
}

--- Reject a configuration privata cannot honour, rather than half-applying it.
--
-- A misspelled strategy or a `checks` key that does not exist would otherwise
-- turn into a silently different scan, which is the failure mode this whole
-- tool exists to argue against.
function _P.validate(config)
  local problems = {}

  for i = 1, #STRING_LISTS do
    local key = STRING_LISTS[i]
    local value = config[key]
    if value ~= nil and not _P.is_string_list(value) then
      problems[#problems + 1] = key .. " must be a list of strings"
    end
  end

  if config.privatize ~= nil and _P.is_string_list(config.privatize) then
    if #config.privatize == 0 then
      problems[#problems + 1] = "privatize must name at least one strategy"
    end
    for i = 1, #config.privatize do
      if not _P.PRIVATIZE_STRATEGIES[config.privatize[i]] then
        problems[#problems + 1] = "unknown privatize strategy '" .. config.privatize[i] .. "'"
      end
    end
  end

  if type(config.namespace) ~= "string" or config.namespace == "" then
    problems[#problems + 1] = "namespace must be a non-empty string"
  elseif not config.namespace:find("^[%a_][%w_]*$") then
    problems[#problems + 1] = "namespace must be a valid Lua identifier"
  end

  if not _P.LOCAL_FUNCTION_STYLES[config.local_function_style] then
    problems[#problems + 1] = "local_function_style must be 'statement' or 'assignment'"
  end

  if not _P.FORMATS[config.format] then
    problems[#problems + 1] = "format must be 'text' or 'json'"
  end

  local FAIL_ON_KINDS = {
    unparsable = true,
    collisions = true,
    unanalyzable = true,
    symbols = true,
    globals = true,
    exported_namespaces = true,
    private_modules = true,
    private_symbols = true,
    exports = true,
    methods = true,
  }
  if _P.is_string_list(config.fail_on) then
    for i = 1, #config.fail_on do
      if not FAIL_ON_KINDS[config.fail_on[i]] then
        problems[#problems + 1] = "unknown fail_on kind '" .. config.fail_on[i] .. "'"
      end
    end
  end

  if type(config.max_locals) ~= "number" or config.max_locals < 1 then
    problems[#problems + 1] = "max_locals must be a positive number"
  end

  local defaults = _P.defaults()
  if type(config.checks) ~= "table" then
    problems[#problems + 1] = "checks must be a table"
  else
    for key in pairs(config.checks) do
      if defaults.checks[key] == nil then
        problems[#problems + 1] = "unknown check '" .. tostring(key) .. "'"
      end
    end
  end

  for i = 1, #config.private_module_patterns do
    local pattern = config.private_module_patterns[i]
    local ok = pcall(string.find, "", pattern)
    if not ok then
      problems[#problems + 1] = "invalid private_module_pattern '" .. pattern .. "'"
    end
  end

  if #problems > 0 then
    return nil, problems
  end
  return config
end

--- Build the effective configuration for a scan.
--
-- `overrides` carries command-line settings, which win over the file. Returns
-- the config and the path of the file that contributed to it, or nil plus a
-- list of problems.
function M.load(project_root, overrides)
  local config = _P.defaults()
  local file_path = _P.find_file(project_root)
  local from_file = {}

  if file_path then
    local source, read_error = fs.read_file(file_path)
    if not source then
      return nil, { file_path .. ": " .. tostring(read_error) }
    end
    local data, load_error = literal.load_returned_table(source)
    if not data then
      return nil, { file_path .. ": " .. tostring(load_error) }
    end
    from_file = data
  end

  -- The preset is chosen by whichever layer names it, but always applies
  -- beneath both, so an explicit setting in either can still override it.
  local preset_name = (overrides and overrides.preset) or from_file.preset
  local preset, preset_error = _P.load_preset(preset_name)
  if not preset then
    return nil, { preset_error }
  end

  _P.overlay(config, preset)
  _P.overlay(config, from_file)
  _P.overlay(config, overrides or {})
  config.preset = preset_name

  -- `--methods` and `checks.methods` are two spellings of one switch; keeping
  -- them in step means no caller has to know which one the user used.
  if config.methods then
    config.checks.methods = true
  elseif config.checks.methods then
    config.methods = true
  end

  local validated, problems = _P.validate(config)
  if not validated then
    local issues = problems or {}
    local labelled = {}
    for i = 1, #issues do
      labelled[i] = (file_path and (file_path .. ": ") or "") .. issues[i]
    end
    return nil, labelled
  end

  return config, file_path
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
