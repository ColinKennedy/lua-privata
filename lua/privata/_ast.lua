--- Node kinds produced by the parser, and a deterministic walker over them.
--
-- Every child of a node is either a node or an array of nodes, so the walker
-- needs no per-kind special cases. Shapes that would otherwise be plain records
-- -- table constructor fields, `elseif` clauses -- are given their own kinds
-- (`TableField`, `IfClause`) to preserve that property.
--
-- Children are declared as an ordered list rather than discovered with `pairs`
-- so a walk visits nodes in source order on every run. Findings are sorted
-- before printing, but an unstable walk would still make reference collection
-- order-dependent and reproduction of a bug report a matter of luck.

local M = {}

--- Ordered child fields per node kind. A field holds a node, an array of
--- nodes, or nil; the walker tells them apart by looking for `kind`.
M.CHILDREN = {
  -- Statements
  Chunk = { "body" },
  LocalDeclaration = { "names", "values" },
  LocalFunction = { "name", "func" },
  FunctionDeclaration = { "target", "func" },
  Assignment = { "targets", "values" },
  CallStatement = { "expr" },
  DoStatement = { "body" },
  WhileStatement = { "cond", "body" },
  RepeatStatement = { "body", "cond" },
  IfStatement = { "clauses", "else_body" },
  IfClause = { "cond", "body" },
  NumericFor = { "var", "start", "limit", "step", "body" },
  GenericFor = { "names", "exprs", "body" },
  ReturnStatement = { "values" },
  BreakStatement = {},
  GotoStatement = {},
  LabelStatement = {},

  -- Expressions
  Nil = {},
  True = {},
  False = {},
  Vararg = {},
  Number = {},
  String = {},
  Identifier = {},
  FunctionExpr = { "params", "body" },
  TableExpr = { "fields" },
  TableField = { "key", "value" },
  BinaryOp = { "left", "right" },
  UnaryOp = { "operand" },
  Index = { "object", "index" },
  Call = { "callee", "args" },
  MethodCall = { "object", "args" },
  Paren = { "expr" },
}

--- Kinds that can legally be assigned to.
M.ASSIGNABLE = { Identifier = true, Index = true }

function M.is_node(value)
  return type(value) == "table" and type(value.kind) == "string"
end

--- Call `visit` on `node` and every descendant, parents before children.
--
-- `visit` may return `false` to stop the walk descending into that node's
-- children; any other return value continues. This is what lets a caller skip
-- a nested function scope without filtering the whole tree afterwards.
function M.walk(node, visit)
  if not M.is_node(node) then
    return
  end
  if visit(node) == false then
    return
  end
  local fields = M.CHILDREN[node.kind]
  if not fields then
    error("privata: no child declaration for node kind " .. tostring(node.kind), 0)
  end
  for i = 1, #fields do
    local value = node[fields[i]]
    if value ~= nil then
      if M.is_node(value) then
        M.walk(value, visit)
      else
        for j = 1, #value do
          M.walk(value[j], visit)
        end
      end
    end
  end
end

--- Walk without descending into nested function bodies.
--
-- Several checks reason about a single scope -- which names a chunk binds at
-- its top level, which fields a class body assigns -- and a nested function is
-- a different scope whose bindings do not belong to the enclosing one.
--
-- A nested `FunctionExpr` is still visited, only not entered: `M.helper =
-- function() ... end` binds a function, and a caller deciding what kind of
-- thing was bound has to see the node to know that. When `node` is itself a
-- `FunctionExpr` it is the scope under inspection, so its body is walked.
function M.walk_shallow(node, visit)
  local seen_root = false
  M.walk(node, function(current)
    if seen_root and current.kind == "FunctionExpr" then
      visit(current)
      return false
    end
    seen_root = true
    return visit(current)
  end)
end

--- Resolve a dotted expression to a string, or nil when any segment is computed.
--
-- `a.b.c` resolves; `a[k].c` does not, because the name privata would report
-- is not the name the code uses. Returning nil is the safe direction: a caller
-- that cannot read a path declines to report it.
function M.dotted_name(node)
  if not M.is_node(node) then
    return nil
  end
  if node.kind == "Identifier" then
    return node.name
  end
  if node.kind == "Index" and not node.computed and node.index.kind == "String" then
    local parent = M.dotted_name(node.object)
    if parent == nil then
      return nil
    end
    return parent .. "." .. node.index.value
  end
  return nil
end

return M
