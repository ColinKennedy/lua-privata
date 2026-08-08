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

--- The table a namespace recommendation would move the symbol into.
--
-- Always the configured namespace. `shape.private_name` is only ever set to
-- that same name, but it is checked rather than trusted: the one thing this
-- recommendation must never do is name some unrelated table that happens to
-- exist in the file, which is exactly the bug that motivated the guard.
function _P.target_namespace(module_record, config)
  local detected = module_record.shape.private_name
  if detected ~= nil and detected == config.namespace then
    return detected
  end
  return config.namespace
end

function _P.namespace_recommendation(symbol, module_record, config)
  local namespace = _P.target_namespace(module_record, config)
  local notes = {}

  -- Only suggest declaring the table when the file does not already have one.
  -- A module whose *public* table happens to be named `_P` still has that
  -- local, and telling its author to add a second one would be nonsense.
  local table_locals = module_record.shape.table_locals or {}
  if table_locals[namespace] == nil then
    notes[#notes + 1] = string.format("add `local %s = {}` near the top of the file", namespace)
  end

  return {
    strategy = _P.STRATEGIES.NAMESPACE,
    namespace = namespace,
    text = string.format("move to `%s.%s`", namespace, symbol.name),
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

--- Relative path wording for a test location, kept short in the report.
function _P.where(location)
  return string.format("%s:%d", location.path:gsub(".*/([^/]+/[^/]+)$", "%1"), location.line)
end

--- The recommendation forced by something outside this module holding the field.
--
-- Two cases, and the second is worse than it looks. A spec that *reads*
-- `mod.name` needs the name to stay on the table. A spec that *assigns*
-- `mod.name = function() ... end` is using the module table as an injection
-- seam: production code calling `M.name(...)` picks up the stub because the
-- call resolves through the table at call time. Privatising that field does not
-- merely make it untestable, it deletes the seam -- so the honest report says
-- the spec must change too, rather than handing over a rename that looks free.
function _P.reachability_recommendation(symbol)
  if symbol.test_stub then
    return {
      strategy = _P.STRATEGIES.UNDERSCORE_FIELD,
      text = string.format("rename to `%s._%s`", symbol.namespace, symbol.name),
      notes = {
        string.format(
          "stubbed by %s -- it is an injection seam; privatising needs the spec updated too",
          _P.where(symbol.test_stub)
        ),
      },
    }
  end

  if symbol.test_read then
    return {
      strategy = _P.STRATEGIES.UNDERSCORE_FIELD,
      text = string.format("rename to `%s._%s`", symbol.namespace, symbol.name),
      notes = {
        string.format(
          "read by %s -- keep it on the table so the spec can still reach it",
          _P.where(symbol.test_read)
        ),
      },
    }
  end

  return nil
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
  if strategy == _P.STRATEGIES.NAMESPACE then
    -- A field cannot be moved into the table it is already on. This is not
    -- hypothetical: a module written as `local _P = {} ... return _P` exports
    -- `_P`, so its fields sit on a table named exactly like the private
    -- namespace privata would otherwise recommend.
    return _P.target_namespace(module_record, config) ~= symbol.namespace
  end

  if strategy == _P.STRATEGIES.UNDERSCORE_FIELD then
    -- A name that is already underscore-led has nowhere to go this way.
    return symbol.name:sub(1, 1) ~= "_"
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

  -- Test usage still does not make a symbol public. It does decide which
  -- privatisation is *legal*: a spec holds the module table and nothing else,
  -- so moving the field to a file-local leaves the spec calling nil. The
  -- underscore field stays reachable, which is why it is the answer here even
  -- though it is the weakest form and ranks last by default.
  local reachable = _P.reachability_recommendation(symbol)
  if reachable then
    return reachable
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

  -- The configured list held only strategies that cannot apply here. Fall back
  -- to whichever of the remaining forms is legal rather than emitting one that
  -- is not: an instruction the reader cannot follow is worse than a blunter one.
  local fallbacks = {
    _P.STRATEGIES.NAMESPACE,
    _P.STRATEGIES.LOCAL_FUNCTION,
    _P.STRATEGIES.UNDERSCORE_FIELD,
  }
  for i = 1, #fallbacks do
    if _P.is_applicable(fallbacks[i], symbol, module_record, config) then
      if fallbacks[i] == _P.STRATEGIES.NAMESPACE then
        return _P.namespace_recommendation(symbol, module_record, config)
      elseif fallbacks[i] == _P.STRATEGIES.LOCAL_FUNCTION then
        return _P.local_function_recommendation(symbol, config)
      end
      return _P.underscore_recommendation(symbol)
    end
  end

  -- Nothing structural is left to suggest, so say the only thing that is
  -- always true rather than inventing a move.
  return {
    strategy = _P.STRATEGIES.LOCAL_FUNCTION,
    text = "stop exporting it",
    notes = {},
  }
end

return M
