--- Read Lua data out of a Lua file without running it.
--
-- Rockspecs and `.privata.lua` are both Lua source that exists to describe
-- data. LuaRocks and luacheck load theirs with `load`, which means scanning a
-- checkout runs whatever the checkout says. privata never executes what it
-- reads, so both are parsed and their literal values lifted out statically.
--
-- The cost is real and worth stating: a config cannot compute. `source_roots =
-- vim.fn.glob(...)` yields nil here, not a list. Anything this module cannot
-- read as a literal is reported to the caller rather than guessed at, so the
-- failure is visible instead of arriving as a silently empty setting.

local ast = require("privata._ast")
local parser = require("privata._parser")

local M = {}
local _P = {}

--- Convert one expression node to a Lua value.
--
-- Returns the value, or nil plus a reason. Note that a literal `nil` in the
-- source is indistinguishable from failure in a single return value, which is
-- why the reason is what callers branch on.
---@param node any  an expression node; anything else reads as a failure
---@return any value   the Lua value, or nil when it could not be read
---@return string|nil reason
function _P.eval(node)
  if not ast.is_node(node) then
    return nil, "missing value"
  end

  local kind = node.kind
  if kind == "String" then
    return node.value
  elseif kind == "Number" then
    if node.value == nil then
      return nil, "numeral this scan cannot evaluate: " .. tostring(node.raw)
    end
    return node.value
  elseif kind == "True" then
    return true
  elseif kind == "False" then
    return false
  elseif kind == "Nil" then
    return nil, "nil"
  elseif kind == "Paren" then
    return _P.eval(node.expr)
  elseif kind == "TableExpr" then
    return _P.eval_table(node)
  elseif kind == "UnaryOp" and node.op == "-" then
    local inner, err = _P.eval(node.operand)
    if type(inner) ~= "number" then
      return nil, err or "negation of a non-number"
    end
    return -inner
  elseif kind == "BinaryOp" and node.op == ".." then
    -- Rockspecs concatenate constantly: `source = { url = base .. name }`.
    -- Only literal operands fold; a name reference still fails.
    local left, left_err = _P.eval(node.left)
    local right, right_err = _P.eval(node.right)
    if type(left) ~= "string" and type(left) ~= "number" then
      return nil, left_err or "concatenation of a non-literal"
    end
    if type(right) ~= "string" and type(right) ~= "number" then
      return nil, right_err or "concatenation of a non-literal"
    end
    return left .. right
  end

  return nil, "expression this scan cannot read statically"
end

--- Convert a table constructor to a Lua table.
--
-- One unreadable entry fails the whole table rather than being skipped: a
-- config half-read is worse than one not read at all, because the caller cannot
-- tell a setting the user omitted from one privata quietly dropped.
---@param node privata.Node   a TableExpr node
---@return table|nil value
---@return string|nil reason  set only when `value` is nil
function _P.eval_table(node)
  local out = {}
  local array_index = 0

  for i = 1, #node.fields do
    local field = node.fields[i]
    local value, value_err = _P.eval(field.value)
    if value == nil then
      return nil, value_err or "table value this scan cannot read statically"
    end

    if field.key == nil then
      array_index = array_index + 1
      out[array_index] = value
    else
      local key, key_err = _P.eval(field.key)
      if key == nil then
        return nil, key_err or "table key this scan cannot read statically"
      end
      out[key] = value
    end
  end

  return out
end

--- Collect top-level assignments to bare names, as a rockspec produces them.
--
-- A rockspec is a sequence of global assignments (`package = "x"`, `build =
-- {...}`), so the file's meaning is exactly this table. Names whose value is
-- not literal are omitted; a caller that needed one treats it as absent.
---@param chunk privata.Node  a Chunk node
---@return table<string, any>  name to value, for the names that could be read
function _P.assignments(chunk)
  local out = {}
  for i = 1, #chunk.body do
    local statement = chunk.body[i]
    if statement.kind == "Assignment" then
      for target_index = 1, #statement.targets do
        local target = statement.targets[target_index]
        local value = statement.values[target_index]
        if target.kind == "Identifier" and value ~= nil then
          local evaluated = _P.eval(value)
          if evaluated ~= nil then
            out[target.name] = evaluated
          end
        end
      end
    end
  end
  return out
end

--- Evaluate the table a chunk returns, as `.privata.lua` produces it.
---@param chunk privata.Node  a Chunk node
---@return table|nil value
---@return string|nil reason  set only when `value` is nil
function _P.returned_table(chunk)
  local last = chunk.body[#chunk.body]
  if last == nil or last.kind ~= "ReturnStatement" then
    return nil, "file does not return anything"
  end
  if #last.values ~= 1 then
    return nil, "file must return exactly one table"
  end
  local value, err = _P.eval(last.values[1])
  if type(value) ~= "table" then
    return nil, err or "file must return a table"
  end
  return value
end

--- Describe a parse failure, tolerating a missing reason.
---@param parse_error { line: integer, message: string }|nil
---@return string
function _P.parse_failure(parse_error)
  if parse_error == nil then
    return "syntax error"
  end
  return string.format("line %d: %s", parse_error.line, parse_error.message)
end

--- Parse `src` and lift its returned table.
---@param src string
---@return table|nil value
---@return string|nil reason  set only when `value` is nil
function M.load_returned_table(src)
  local chunk, parse_error = parser.parse(src)
  if not chunk then
    return nil, _P.parse_failure(parse_error)
  end
  return _P.returned_table(chunk)
end

--- Parse `src` and lift its top-level assignments.
---@param src string
---@return table<string, any>|nil values
---@return string|nil reason  set only when `values` is nil
function M.load_assignments(src)
  local chunk, parse_error = parser.parse(src)
  if not chunk then
    return nil, _P.parse_failure(parse_error)
  end
  return _P.assignments(chunk)
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
