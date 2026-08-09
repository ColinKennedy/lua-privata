--- Validate a literal `return { a = a }` export table.
--
-- This is the closest Lua has to Python's `__all__`: a hand-maintained list of
-- what a module publishes, sitting apart from the definitions it names. Like
-- `__all__`, it goes stale, and unlike `__all__` the failure is silent -- Lua
-- exports `nil` for a name that does not exist rather than raising.

local models = require("privata._models")
local shape = require("privata._shape")

local M = {}
local _P = {}

_P.ISSUES = {
  UNKNOWN = "unknown",
  PRIVATE = "private",
  MISSING = "missing",
}

--- Names bound as locals at the chunk's top level.
--
-- Only the top level, because that is the scope a returned table can name: a
-- local declared inside a function is not something `return { a = a }` can see.
---@param chunk privata.Node  a Chunk node
---@return table<string, integer>  local name to the line declaring it
function _P.chunk_local_names(chunk)
  local names = {}
  for i = 1, #chunk.body do
    local statement = chunk.body[i]
    if statement.kind == "LocalDeclaration" then
      for index = 1, #statement.names do
        names[statement.names[index].name] = statement.names[index].line
      end
    elseif statement.kind == "LocalFunction" then
      names[statement.name.name] = statement.name.line
    end
  end
  return names
end

--- Check one module's literal export table.
--
-- Only a re-export list is validated. A literal holding data is not making a
-- claim about bindings, so there is nothing for it to be wrong about.
---@param record privata.Module  needs `chunk` and `shape` filled in
---@return privata.ExportIssueFinding[]  empty unless the file re-exports
function _P.check_module(record)
  local detected = record.shape
  -- `M.collect` only calls this for records that have both.
  ---@cast detected privata.Shape
  local chunk = record.chunk
  ---@cast chunk privata.Node
  if detected.kind ~= shape.KINDS.LITERAL or not detected.is_reexport_table then
    return {}
  end

  local locals = _P.chunk_local_names(chunk)
  local issues = {}

  for i = 1, #detected.literal.fields do
    local field = detected.literal.fields[i]
    local name = field.key.value
    local bound = field.value.name

    local kind = nil
    if locals[bound] == nil then
      -- Lua exports nil for an unbound name rather than raising, so this is a
      -- broken interface that no test necessarily catches.
      kind = _P.ISSUES.UNKNOWN
    elseif models.is_private_name(name) then
      kind = _P.ISSUES.PRIVATE
    end

    if kind ~= nil and not models.is_ignored(record, field.line) then
      issues[#issues + 1] = {
        module = record.name,
        path = record.path,
        name = name,
        binding = bound,
        kind = kind,
        line = field.line,
      }
    end
  end

  return issues
end

--- Export-table issues across every module.
---@param modules table<string, privata.Module>
---@return privata.ExportIssueFinding[]  sorted by location
function M.collect(modules)
  local issues = {}
  for _, record in pairs(modules) do
    if record.chunk and record.shape then
      local found = _P.check_module(record)
      for i = 1, #found do
        issues[#issues + 1] = found[i]
      end
    end
  end
  return models.sort_findings(issues)
end

return M
