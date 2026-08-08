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

function _P.relative(path, project_root)
  return fs.relative(path, project_root) or path
end

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

function _P.map(list, transform)
  local out = {}
  for i = 1, #list do
    out[i] = transform(list[i])
  end
  return out
end

--- Render findings as a single JSON object.
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
