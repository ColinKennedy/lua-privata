--- Resolve names to locals or globals, with real Lua scoping rules.
--
-- Two checks need this and neither tolerates an approximation. The globals
-- check reports a binding visible to the entire process, so mistaking a local
-- for one is a false positive on working code. The locals budget decides
-- whether `local function` is even a legal recommendation, and Lua's limit is
-- per function, not per file.
--
-- The traversal is hand-rolled rather than built on `ast.walk` because scoping
-- depends on statement order: `local x = x` reads the outer `x`, and a
-- `local function` is visible inside its own body while a `local` assignment is
-- not visible in its own initialiser.

local ast = require("privata._ast")

local M = {}
local _P = {}

function _P.new_scope(parent)
  return { parent = parent, names = {}, count = 0 }
end

function _P.declare(scope, name)
  if not scope.names[name] then
    scope.count = scope.count + 1
  end
  scope.names[name] = true
end

function _P.resolves(scope, name)
  while scope do
    if scope.names[name] then
      return true
    end
    scope = scope.parent
  end
  return false
end

--- Per-function local counts, so the caller can compare against Lua's limit.
function _P.note_function_scope(state, scope)
  if scope.count > state.max_function_locals then
    state.max_function_locals = scope.count
  end
end

function _P.record_global_assignment(state, name, line, kind)
  state.assigned[#state.assigned + 1] = { name = name, line = line, kind = kind }
end

function _P.visit_expression(state, node, scope)
  if not ast.is_node(node) then
    return
  end

  if node.kind == "FunctionExpr" then
    local inner = _P.new_scope(scope)
    for i = 1, #node.params do
      _P.declare(inner, node.params[i].name)
    end
    _P.visit_block(state, node.body, inner)
    _P.note_function_scope(state, inner)
    return
  end

  if node.kind == "Identifier" then
    if not _P.resolves(scope, node.name) then
      state.read[node.name] = state.read[node.name] or node.line
    end
    return
  end

  local fields = ast.CHILDREN[node.kind]
  for i = 1, #fields do
    local value = node[fields[i]]
    if value ~= nil then
      if ast.is_node(value) then
        _P.visit_expression(state, value, scope)
      else
        for j = 1, #value do
          _P.visit_expression(state, value[j], scope)
        end
      end
    end
  end
end

--- Visit an assignment target, where a bare name binds rather than reads.
function _P.visit_target(state, node, scope, kind)
  if node.kind == "Identifier" then
    if not _P.resolves(scope, node.name) then
      _P.record_global_assignment(state, node.name, node.line, kind)
    end
    return
  end

  -- `_G.name = ...` is the explicit spelling of the same thing, and says so
  -- deliberately enough that it would be perverse not to report it.
  local dotted = ast.dotted_name(node)
  if dotted and dotted:sub(1, 3) == "_G." and not _P.resolves(scope, "_G") then
    _P.record_global_assignment(state, dotted:sub(4), node.field_line or node.line, kind)
    return
  end

  _P.visit_expression(state, node, scope)
end

function _P.visit_statement(state, node, scope)
  local kind = node.kind

  if kind == "LocalDeclaration" then
    -- Initialisers are evaluated before the names come into scope.
    for i = 1, #node.values do
      _P.visit_expression(state, node.values[i], scope)
    end
    for i = 1, #node.names do
      _P.declare(scope, node.names[i].name)
    end
    return
  end

  if kind == "LocalFunction" then
    -- Declared before its body, so the function can call itself.
    _P.declare(scope, node.name.name)
    _P.visit_expression(state, node.func, scope)
    return
  end

  if kind == "FunctionDeclaration" then
    _P.visit_target(state, node.target, scope, "function")
    _P.visit_expression(state, node.func, scope)
    return
  end

  if kind == "Assignment" then
    for i = 1, #node.values do
      _P.visit_expression(state, node.values[i], scope)
    end
    for i = 1, #node.targets do
      local value = node.values[i]
      local target_kind = (value and value.kind == "FunctionExpr") and "function" or "value"
      _P.visit_target(state, node.targets[i], scope, target_kind)
    end
    return
  end

  if kind == "DoStatement" then
    _P.visit_block(state, node.body, _P.new_scope(scope))
    return
  end

  if kind == "WhileStatement" then
    _P.visit_expression(state, node.cond, scope)
    _P.visit_block(state, node.body, _P.new_scope(scope))
    return
  end

  if kind == "RepeatStatement" then
    -- The until-condition can see the body's locals, so they share a scope.
    local inner = _P.new_scope(scope)
    _P.visit_block(state, node.body, inner)
    _P.visit_expression(state, node.cond, inner)
    return
  end

  if kind == "IfStatement" then
    for i = 1, #node.clauses do
      local clause = node.clauses[i]
      _P.visit_expression(state, clause.cond, scope)
      _P.visit_block(state, clause.body, _P.new_scope(scope))
    end
    if node.else_body then
      _P.visit_block(state, node.else_body, _P.new_scope(scope))
    end
    return
  end

  if kind == "NumericFor" then
    _P.visit_expression(state, node.start, scope)
    _P.visit_expression(state, node.limit, scope)
    _P.visit_expression(state, node.step, scope)
    local inner = _P.new_scope(scope)
    _P.declare(inner, node.var.name)
    _P.visit_block(state, node.body, inner)
    return
  end

  if kind == "GenericFor" then
    for i = 1, #node.exprs do
      _P.visit_expression(state, node.exprs[i], scope)
    end
    local inner = _P.new_scope(scope)
    for i = 1, #node.names do
      _P.declare(inner, node.names[i].name)
    end
    _P.visit_block(state, node.body, inner)
    return
  end

  if kind == "ReturnStatement" then
    for i = 1, #node.values do
      _P.visit_expression(state, node.values[i], scope)
    end
    return
  end

  if kind == "CallStatement" then
    _P.visit_expression(state, node.expr, scope)
    return
  end

  -- Break, goto and label bind nothing and read nothing.
end

function _P.visit_block(state, statements, scope)
  for i = 1, #statements do
    _P.visit_statement(state, statements[i], scope)
  end
end

--- Analyse a chunk's name bindings.
--
-- Returns `assigned` (globals this file creates, in source order), `read` (a
-- name-to-first-line map of globals it only reads), `chunk_locals` (locals in
-- the file's own top-level scope) and `max_function_locals`.
function M.analyze(chunk)
  local state = {
    assigned = {},
    read = {},
    max_function_locals = 0,
  }
  local scope = _P.new_scope(nil)
  _P.visit_block(state, chunk.body, scope)
  _P.note_function_scope(state, scope)

  return {
    assigned = state.assigned,
    read = state.read,
    chunk_locals = scope.count,
    max_function_locals = state.max_function_locals,
  }
end

return M
