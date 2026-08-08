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

---@class privata.Scope
---@field parent privata.Scope|nil
---@field names table<string, boolean>  names this scope binds
---@field count integer                 how many, for the locals budget

---@class privata.ScopeState
---@field assigned { name: string, line: integer, kind: string, explicit: boolean }[]
---@field read table<string, integer>  global name to the line that first reads it
---@field max_function_locals integer  the largest per-function local count seen

---@class privata.ScopeReport
---@field assigned { name: string, line: integer, kind: string, explicit: boolean }[]
---@field read table<string, integer>  globals the file only reads, to first line
---@field chunk_locals integer         locals in the file's own top-level scope
---@field max_function_locals integer  the most locals any one function declares

--- A lexical scope: the names it binds, how many, and the scope enclosing it.
--
-- The count is kept alongside the names because the locals budget asks how many
-- registers a function already spends, and `names` is a set -- there is nothing
-- to count in it later without walking the whole table.
---@param parent privata.Scope|nil  nil for the chunk's own top-level scope
---@return privata.Scope
function _P.new_scope(parent)
  return { parent = parent, names = {}, count = 0 }
end

--- Bind `name` in `scope`, counting it once however often it is redeclared.
--
-- Shadowing a name in the same scope (`local x` twice) is rare enough that
-- undercounting it costs nothing, and the count only ever guards a
-- recommendation: if privata is unsure a `local` will fit, it says so.
---@param scope privata.Scope
---@param name string
function _P.declare(scope, name)
  if not scope.names[name] then
    scope.count = scope.count + 1
  end
  scope.names[name] = true
end

--- True when `name` is bound by this scope or any scope enclosing it.
--
-- This is the whole definition of "global" that the globals check uses: a name
-- no enclosing scope binds is one Lua will look up in `_G`.
---@param scope privata.Scope|nil
---@param name string
---@return boolean
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
---@param state privata.ScopeState
---@param scope privata.Scope  a scope whose function body is now fully walked
function _P.note_function_scope(state, scope)
  if scope.count > state.max_function_locals then
    state.max_function_locals = scope.count
  end
end

--- `explicit` distinguishes `_G.foo = ...` from a missing `local`.
--
-- They are different mistakes, and only one of them is a mistake. Writing `_G.`
-- is a declaration -- often the only way to reach a name from a host that can
-- see nothing else -- while `function foo()` with no `local` is an accident.
-- Telling the first "this should be local" is wrong advice.
---@param state privata.ScopeState
---@param name string
---@param line integer
---@param kind string             "function" or "value"
---@param explicit boolean|nil    true when written as `_G.name`
function _P.record_global_assignment(state, name, line, kind, explicit)
  state.assigned[#state.assigned + 1] = {
    name = name,
    line = line,
    kind = kind,
    explicit = explicit or false,
  }
end

--- Walk an expression, recording every name no enclosing scope binds.
--
-- A `FunctionExpr` is entered with a scope of its own, its parameters declared
-- in it, and its locals counted separately once the body is done: Lua's limit
-- on locals is per function, so a count that spanned the file would be a
-- number no check could use.
---@param state privata.ScopeState
---@param node any    an expression node; anything else is ignored
---@param scope privata.Scope
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
---@param state privata.ScopeState
---@param node privata.Node  the target expression node
---@param scope privata.Scope
---@param kind string  "function" or "value", for the recorded assignment
function _P.visit_target(state, node, scope, kind)
  if node.kind == "Identifier" then
    ---@cast node privata.Identifier
    if not _P.resolves(scope, node.name) then
      _P.record_global_assignment(state, node.name, node.line, kind)
    end
    return
  end

  local dotted = ast.dotted_name(node)
  if dotted and dotted:sub(1, 3) == "_G." and not _P.resolves(scope, "_G") then
    _P.record_global_assignment(state, dotted:sub(4), node.field_line or node.line, kind, true)
    return
  end

  _P.visit_expression(state, node, scope)
end

--- Dispatch one statement, threading scope through by hand.
--
-- Every branch here exists because that statement kind has its own rule about
-- when its names become visible and to which of its children: a `local`'s
-- initialiser cannot see it, a `local function`'s body can, and `repeat` shares
-- one scope with its until-condition. That is what a generic walk cannot do.
---@param state privata.ScopeState
---@param node privata.Node  a statement node
---@param scope privata.Scope  the block's scope, mutated as names are declared
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

--- Visit statements in source order, all sharing one scope.
--
-- Order is the point: a `local` declared halfway down a block is a global read
-- everywhere above it, and only a forward pass sees that.
---@param state privata.ScopeState
---@param statements privata.Node[]
---@param scope privata.Scope
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
---@param chunk privata.Node  a Chunk node
---@return privata.ScopeReport
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
