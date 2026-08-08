--- Choose how a symbol should be made private, and say so in one line.
--
-- privata only ever recommends narrowing an interface. It never suggests
-- widening one, even where the private-symbol check has just proved a private
-- name is read from elsewhere -- that is a boundary to fix at the call site,
-- not a hint to publish the name.
--
-- Strategies are tried in the configured order and the first *applicable* one
-- wins. Applicability is the substance here, because in Lua the obvious
-- recommendation is frequently illegal:
--
--   * `M.a` may call `M.b` defined further down; `local function a` calling a
--     later `local b` reads a global instead, and silently gets nil
--   * a chunk may hold at most 200 locals, so a large module cannot demote
--     everything to one
--
-- A recommendation that cannot be followed is worse than none, so those cases
-- fall through to a strategy that works rather than being emitted with a caveat.

local M = {}
local _P = {}

_P.STRATEGIES = {
  NAMESPACE = "namespace",
  LOCAL_FUNCTION = "local_function",
  UNDERSCORE_FIELD = "underscore_field",
}

--- The earliest line that reads the symbol, or nil when nothing does.
function _P.earliest_use(symbol)
  local earliest = nil
  for i = 1, #symbol.uses do
    local line = symbol.uses[i]
    if earliest == nil or line < earliest then
      earliest = line
    end
  end
  return earliest
end

--- True when the symbol's own body reads it, which makes it self-recursive.
--
-- `local function f` can call itself; `local f = function()` cannot, because
-- the name is not in scope inside its own initialiser. So a recursive
-- definition pins the statement form whatever the configured style says.
function _P.is_self_recursive(symbol)
  for i = 1, #symbol.uses do
    local line = symbol.uses[i]
    if line >= symbol.line and line <= (symbol.end_line or symbol.line) then
      return true
    end
  end
  return false
end

--- Whether demoting to a local would create a use-before-definition.
function _P.needs_forward_declaration(symbol)
  local earliest = _P.earliest_use(symbol)
  return earliest ~= nil and earliest < symbol.line
end

function _P.namespace_recommendation(symbol, module_record, config)
  local namespace = module_record.shape.private_name or config.namespace
  local text = string.format("move to `%s.%s`", namespace, symbol.name)
  local notes = {}

  if module_record.shape.private_name == nil then
    notes[#notes + 1] = string.format("add `local %s = {}` near the top of the file", namespace)
  end

  return {
    strategy = _P.STRATEGIES.NAMESPACE,
    namespace = namespace,
    text = text,
    notes = notes,
  }
end

function _P.local_function_recommendation(symbol, config)
  local notes = {}
  local recursive = _P.is_self_recursive(symbol)
  local style = config.local_function_style

  -- A function that calls itself needs the statement form, whose name is in
  -- scope inside its own body.
  if recursive then
    style = "statement"
  end

  local text
  if symbol.kind == "function" and style == "statement" then
    text = string.format("make it `local function %s`", symbol.name)
  elseif symbol.kind == "function" then
    text = string.format("make it `local %s = function(...)`", symbol.name)
  else
    text = string.format("make it `local %s`", symbol.name)
  end

  if recursive and config.local_function_style == "assignment" then
    notes[#notes + 1] = "statement form required: the definition calls itself"
  end

  if _P.needs_forward_declaration(symbol) then
    notes[#notes + 1] = string.format(
      "needs a forward `local %s` before line %d",
      symbol.name,
      _P.earliest_use(symbol)
    )
  end

  return {
    strategy = _P.STRATEGIES.LOCAL_FUNCTION,
    text = text,
    notes = notes,
  }
end

function _P.underscore_recommendation(symbol)
  return {
    strategy = _P.STRATEGIES.UNDERSCORE_FIELD,
    text = string.format("rename to `%s._%s`", symbol.namespace, symbol.name),
    notes = {},
  }
end

--- Whether a strategy can be applied to this symbol in this module.
function _P.is_applicable(strategy, symbol, module_record, config)
  if strategy == _P.STRATEGIES.NAMESPACE or strategy == _P.STRATEGIES.UNDERSCORE_FIELD then
    return true
  end

  if strategy == _P.STRATEGIES.LOCAL_FUNCTION then
    -- Every demoted field becomes one more local in the chunk's own scope.
    local budget = (module_record.scope and module_record.scope.chunk_locals or 0) + 1
    if budget > config.max_locals then
      return false
    end
    if _P.needs_forward_declaration(symbol) and not config.local_function_forward_decl then
      return false
    end
    return true
  end

  return false
end

--- Recommend how to privatise `symbol`.
--
-- A symbol published by a literal `return { a = a }` table is a special case
-- worth its own wording: the binding is already a local, so there is nothing to
-- move -- only a line to delete.
function M.for_symbol(symbol, module_record, config)
  if symbol.namespace == "return" then
    return {
      strategy = _P.STRATEGIES.LOCAL_FUNCTION,
      text = string.format("drop `%s` from the returned table", symbol.name),
      notes = { "the binding is already a local" },
    }
  end

  local strategies = config.privatize
  for i = 1, #strategies do
    local strategy = strategies[i]
    if _P.is_applicable(strategy, symbol, module_record, config) then
      if strategy == _P.STRATEGIES.NAMESPACE then
        return _P.namespace_recommendation(symbol, module_record, config)
      elseif strategy == _P.STRATEGIES.LOCAL_FUNCTION then
        return _P.local_function_recommendation(symbol, config)
      end
      return _P.underscore_recommendation(symbol)
    end
  end

  -- The configured list held only strategies that cannot apply here. The
  -- namespace form always can, so it is the floor rather than an error.
  return _P.namespace_recommendation(symbol, module_record, config)
end

return M
