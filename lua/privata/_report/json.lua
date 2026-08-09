--- JSON report, for editors and CI.
--
-- Hand-rolled encoder: privata has no runtime dependencies, and the shapes
-- emitted here are its own, so there is nothing to gain from a general one.

local fs = require("privata._fs")

local M = {}
local _P = {}

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

--- Quote a string as a JSON string literal.
--
-- Control characters JSON has no short escape for fall through to `\uXXXX`, so
-- a stray byte in a path or a source line cannot produce a document a consumer
-- refuses to parse.
---@param text string
---@return string  the quoted literal, including its surrounding quotes
function _P.escape(text)
  local escaped = text:gsub('[%c"\\]', function(character)
    local known = ESCAPES[character]
    if known then
      return known
    end
    return string.format("\\u%04x", character:byte())
  end)
  return '"' .. escaped .. '"'
end

--- Encode a Lua value as JSON.
--
-- Object keys are sorted, so the same findings serialise to the same bytes on
-- every run and a CI job can diff two reports without `pairs` order making
-- unrelated files look changed.
--
-- Lua cannot tell an empty array from an empty object, and this picks array:
-- every table privata emits under a plural key is a list, and a consumer
-- iterating `symbols` should not have to special-case `{}`.
---@param value any
---@return string  the JSON text
function _P.encode(value)
  local kind = type(value)
  if kind == "string" then
    return _P.escape(value)
  elseif kind == "number" then
    -- Integers are formatted without a decimal point so line numbers do not
    -- arrive at a consumer as 12.0.
    if value == math.floor(value) then
      return string.format("%d", value)
    end
    return tostring(value)
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind == "nil" then
    return "null"
  end

  if #value > 0 or next(value) == nil then
    local parts = {}
    for i = 1, #value do
      parts[i] = _P.encode(value[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local parts = {}
  for i = 1, #keys do
    parts[i] = _P.escape(tostring(keys[i])) .. ":" .. _P.encode(value[keys[i]])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Path relative to the project root, or the path itself when it lies outside.
--
-- Relative paths keep a report portable between a developer's checkout and a
-- CI workspace; falling back to the absolute path keeps a file outside the root
-- identifiable rather than silently mangled.
---@param path string
---@param project_root string
---@return string
function _P.relative(path, project_root)
  return fs.relative(path, project_root) or path
end

--- Shape one symbol finding, with its recommendation when it has one.
---@param entry privata.Symbol
---@param project_root string
---@return table<string, any>  the JSON object for this symbol
function _P.symbol(entry, project_root)
  local out = {
    file = _P.relative(entry.path, project_root),
    line = entry.line,
    module = entry.module,
    name = entry.name,
    symbol = entry.path_name,
    kind = entry.kind,
    namespace = entry.namespace,
    used_at = entry.uses,
  }
  if entry.recommendation then
    out.recommendation = {
      strategy = entry.recommendation.strategy,
      text = entry.recommendation.text,
      notes = entry.recommendation.notes,
    }
  end
  return out
end

--- Map over a list, keeping it a list so `_P.encode` emits a JSON array.
---@generic T, U
---@param list T[]
---@param transform fun(item: T): U
---@return U[]
function _P.map(list, transform)
  local out = {}
  for i = 1, #list do
    out[i] = transform(list[i])
  end
  return out
end

--- Render findings as a single JSON object.
---@param findings privata.Findings
---@param project_root string  paths are emitted relative to this
---@param config privata.Config  supplies the `downgraded` flags
---@return string  one JSON object, with sorted keys
function M.render(findings, project_root, config)
  local document = {
    version = 1,
    roots = _P.map(findings.roots, function(root)
      return _P.relative(root, project_root)
    end),
    unparsable = _P.map(findings.unparsable, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        message = entry.message,
        downgraded = config.skip_unparsable_files,
      }
    end),
    collisions = _P.map(findings.collisions, function(entry)
      return {
        module = entry.module,
        files = _P.map(entry.paths, function(path)
          return _P.relative(path, project_root)
        end),
        downgraded = config.skip_module_collisions,
      }
    end),
    unanalyzable = _P.map(findings.unanalyzable, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        reason = entry.reason,
      }
    end),
    exported_namespaces = _P.map(findings.exported_namespaces, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        namespace = entry.namespace,
        public_table = entry.public_table,
        public_fields = entry.public_symbols,
      }
    end),
    function_modules = _P.map(findings.function_modules, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        name = entry.name,
        anonymous = entry.anonymous,
        private_module = entry.private_module,
      }
    end),
    symbols = _P.map(findings.symbols, function(entry)
      return _P.symbol(entry, project_root)
    end),
    globals = _P.map(findings.globals, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        name = entry.name,
        kind = entry.kind,
      }
    end),
    private_module_requires = _P.map(findings.private_module_requires, function(entry)
      return {
        file = _P.relative(entry.required_by_path, project_root),
        line = entry.line,
        module = entry.module,
        required_by = entry.required_by,
      }
    end),
    private_symbol_reads = _P.map(findings.private_symbol_reads, function(entry)
      return {
        file = _P.relative(entry.read_by_path, project_root),
        line = entry.line,
        module = entry.module,
        name = entry.name,
        read_by = entry.read_by,
      }
    end),
    export_issues = _P.map(findings.export_issues, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        name = entry.name,
        binding = entry.binding,
        issue = entry.kind,
      }
    end),
    stale_ignores = _P.map(findings.stale_ignores, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        bare = entry.bare,
      }
    end),
    methods = _P.map(findings.methods, function(entry)
      return {
        file = _P.relative(entry.path, project_root),
        line = entry.line,
        module = entry.module,
        name = entry.name,
        class = entry.class_name,
        class_line = entry.class_line,
        class_public_methods = entry.class_public_methods,
      }
    end),
  }

  return _P.encode(document)
end

--- Exposed so this module's own specs can exercise the encoder directly.
M._P = _P

return M
