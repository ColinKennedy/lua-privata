--- Work out what a file exports, or refuse to guess.
--
-- Lua has no export declaration. What a module publishes is whatever table it
-- returns, and there are several idioms for building that table. Recognising
-- the wrong one is the worst failure available to this tool: it mislabels every
-- symbol in the file at once, in both directions. So the recognisers are exact,
-- and everything else is reported as unanalyzable rather than assumed.

local ast = require("privata._ast")
local models = require("privata._models")

local M = {}
local _P = {}

M.KINDS = {
  TABLE = "table", -- local M = {} ... return M
  CLASS = "class", -- local C = {}; C.__index = C ... return C
  LITERAL = "literal", -- return { a = a, b = b }
  FUNCTION = "function", -- local function run() end ... return run
  SIDE_EFFECT = "side_effect", -- returns nothing; runs for what it does
}

--- A `local X = {}` at chunk level, by name.
--
-- Only an empty table constructor counts. `local M = require("other")` returns
-- someone else's table, and treating its fields as this file's symbols would
-- report another module's interface against this file.
---@param chunk privata.Node  a Chunk node
---@return table<string, { name: string, line: integer }>
function _P.table_locals(chunk)
  local out = {}
  for i = 1, #chunk.body do
    local statement = chunk.body[i]
    if statement.kind == "LocalDeclaration" then
      for index = 1, #statement.names do
        local value = statement.values[index]
        local name = statement.names[index].name
        if value ~= nil and _P.is_table_source(value) then
          out[name] = { name = name, line = statement.names[index].line }
        end
      end
    end
  end
  return out
end

--- A chunk-level local bound to a function literal, by name.
--
-- Kept apart from `table_locals` because the two answer different questions. A
-- table local is a namespace whose *fields* are the interface; a function local
-- *is* the interface, entire. Only a literal function counts: `local run =
-- require("other")` hands back someone else's callable, and this file has no
-- say over it.
---@param chunk privata.Node  a Chunk node
---@return table<string, { name: string, line: integer }>
function _P.function_locals(chunk)
  local out = {}
  for i = 1, #chunk.body do
    local statement = chunk.body[i]
    if statement.kind == "LocalFunction" then
      out[statement.name.name] = { name = statement.name.name, line = statement.line }
    elseif statement.kind == "LocalDeclaration" then
      for index = 1, #statement.names do
        local value = statement.values[index]
        if value ~= nil and value.kind == "FunctionExpr" then
          local name = statement.names[index].name
          out[name] = { name = name, line = statement.names[index].line }
        end
      end
    end
  end
  return out
end

--- True when `node` builds a table this file owns.
--
-- `setmetatable({}, mt)` still owns its table, so the wrapper is looked
-- through; `require("other")` does not, and is deliberately not matched.
---@param node privata.Node  an expression node
---@return boolean
function _P.is_table_source(node)
  if node.kind == "TableExpr" then
    return true
  end
  -- `local M = setmetatable({}, mt)` is still this file's own table.
  if node.kind == "Call" and ast.dotted_name(node.callee) == "setmetatable" then
    return node.args[1] ~= nil and _P.is_table_source(node.args[1])
  end
  return false
end

--- Unwrap the expression a `return` hands back to the caller.
--
-- `return setmetatable(M, mt)` publishes M, so the wrapper is peeled off. The
-- metatable argument is not followed: a metatable supplies behaviour, not the
-- exported names.
---@param node privata.Node|nil  the returned expression node
---@return privata.Node|nil  the expression actually published, or nil if none is
function _P.unwrap_return(node)
  while node ~= nil do
    if node.kind == "Paren" then
      node = node.expr
    elseif node.kind == "Call" and ast.dotted_name(node.callee) == "setmetatable" then
      node = node.args[1]
    else
      return node
    end
  end
  return nil
end

--- Top-level `return`s that are not the file's final statement.
--
-- `if jit then return A end return B` publishes different tables on different
-- interpreters. Neither answer is right for every reader, so privata gives none.
---@param chunk privata.Node  a Chunk node
---@return boolean
function _P.has_conditional_return(chunk)
  local last = chunk.body[#chunk.body]
  local found = false
  ast.walk_shallow(chunk, function(node)
    if node.kind == "ReturnStatement" and node ~= last then
      found = true
    end
  end)
  return found
end

--- True when the file calls 5.1's `module()`, which publishes by side effect.
---@param chunk privata.Node  a Chunk node
---@return boolean
function _P.uses_legacy_module(chunk)
  local found = false
  ast.walk_shallow(chunk, function(node)
    if node.kind == "CallStatement" and ast.dotted_name(node.expr.callee) == "module" then
      found = true
    end
  end)
  return found
end

--- The name a file uses for its private namespace, when it has one.
--
-- Only the configured name counts, and privata will not guess at a substitute.
-- An earlier version fell back to any private-looking table local, which sounds
-- accommodating and is not: `local _DEFAULT_ACCEPTED_CHARS = { ... }` is a
-- private *constant*, not a namespace, and treating it as one made privata
-- recommend moving unrelated functions into a table of characters.
--
-- A project that spells its namespace differently says so in `namespace`. The
-- cost of not guessing is that such a project sees its fields reported until it
-- does; the cost of guessing is advice that is confidently wrong.
---@param table_locals table<string, { name: string, line: integer }>
---@param configured string|nil  the namespace the config asks for
---@return string|nil  the configured name when the file declares it, else nil
function _P.find_private_namespace(table_locals, configured)
  if configured and table_locals[configured] then
    return configured
  end
  return nil
end

--- True when a chunk marks `name` as a metatable-based class.
---@param chunk privata.Node  a Chunk node
---@param name string  the returned table's local name
---@return boolean
function _P.is_class(chunk, name)
  local found = false
  ast.walk_shallow(chunk, function(node)
    if node.kind == "Assignment" then
      for i = 1, #node.targets do
        if ast.dotted_name(node.targets[i]) == name .. ".__index" then
          found = true
        end
      end
    end
  end)
  return found
end

--- True when a returned literal is a re-export list: `{ a = a, b = b }`.
--
-- The distinction matters more than it looks. A re-export list is an interface
-- declaration, and dropping a name from it makes that name private. A literal
-- holding data -- a preset, a lookup table, a set of constants -- is a *value*,
-- and its fields cannot be made private without deleting them, so reporting
-- them would produce advice nobody can follow.
---@param literal_node privata.Node  a TableExpr node
---@return boolean
function _P.is_reexport_table(literal_node)
  if #literal_node.fields == 0 then
    return false
  end
  for i = 1, #literal_node.fields do
    local field = literal_node.fields[i]
    if field.computed or field.key == nil or field.key.kind ~= "String" then
      return false
    end
    if field.value.kind ~= "Identifier" then
      return false
    end
  end
  return true
end

--- Decide what `chunk` exports.
--
-- Returns a shape table. `kind` is one of `M.KINDS` when the file could be
-- read, or nil with `reason` set from `models.UNANALYZABLE` when it could not.
---@param chunk privata.Node       a Chunk node
---@param config privata.Config|nil  supplies `namespace`; the default is used without one
---@return privata.Shape  exactly one of `kind` and `reason` is set
function M.detect(chunk, config)
  local configured_namespace = (config and config.namespace) or models.DEFAULT_NAMESPACE

  if _P.uses_legacy_module(chunk) then
    return { reason = models.UNANALYZABLE.LEGACY_MODULE, line = 1 }
  end

  -- A file that returns nothing is a side-effect module, not a shape privata
  -- failed to read. Setting autocommands, installing keymaps, registering
  -- commands: the file runs for what it does, and exporting nothing is the
  -- point rather than an omission. It exposes no interface, so it has no
  -- symbols to report -- but it is still parsed, and the names it reads still
  -- count as uses of the modules it requires.
  local last = chunk.body[#chunk.body]
  if last == nil or last.kind ~= "ReturnStatement" then
    return { kind = M.KINDS.SIDE_EFFECT, line = last and last.line or 1 }
  end

  if _P.has_conditional_return(chunk) then
    return { reason = models.UNANALYZABLE.CONDITIONAL_RETURN, line = last.line }
  end

  if #last.values ~= 1 then
    return { reason = models.UNANALYZABLE.MULTIPLE_RETURNS, line = last.line }
  end

  local table_locals = _P.table_locals(chunk)
  local private_name = _P.find_private_namespace(table_locals, configured_namespace)
  local returned = _P.unwrap_return(last.values[1])

  if returned == nil then
    return { reason = models.UNANALYZABLE.COMPUTED_RETURN, line = last.line }
  end

  if returned.kind == "TableExpr" then
    return {
      kind = M.KINDS.LITERAL,
      return_line = last.line,
      literal = returned,
      is_reexport_table = _P.is_reexport_table(returned),
      private_name = private_name,
      table_locals = table_locals,
    }
  end

  -- `return function(x) ... end`. A module whose whole export is one function is
  -- a real idiom -- `local get_foo = require("thing.get_foo"); get_foo(10)` --
  -- and it is fully readable: there is no table, so there are no fields to
  -- mislabel. What can still be wrong about it is whether anything requires the
  -- module at all, which `_checker` asks separately.
  if returned.kind == "FunctionExpr" then
    return {
      kind = M.KINDS.FUNCTION,
      public_line = returned.line,
      return_line = last.line,
      private_name = private_name,
      table_locals = table_locals,
    }
  end

  if returned.kind == "Identifier" then
    ---@cast returned privata.Identifier
    local declared = table_locals[returned.name]
    if declared == nil then
      local declared_function = _P.function_locals(chunk)[returned.name]
      if declared_function then
        return {
          kind = M.KINDS.FUNCTION,
          public_name = returned.name,
          public_line = declared_function.line,
          return_line = last.line,
          private_name = private_name,
          table_locals = table_locals,
        }
      end
      -- The returned name is not a table this file built, so its fields belong
      -- to whatever produced it.
      return { reason = models.UNANALYZABLE.COMPUTED_RETURN, line = last.line }
    end
    if returned.name == private_name then
      -- A file that returns the table it calls private is not using it as a
      -- private namespace, whatever it is named.
      private_name = nil
    end
    return {
      kind = _P.is_class(chunk, returned.name) and M.KINDS.CLASS or M.KINDS.TABLE,
      public_name = returned.name,
      public_line = declared.line,
      return_line = last.line,
      private_name = private_name,
      table_locals = table_locals,
    }
  end

  return { reason = models.UNANALYZABLE.COMPUTED_RETURN, line = last.line }
end

return M
