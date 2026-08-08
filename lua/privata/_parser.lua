--- Recursive-descent parser producing the node kinds declared in `_ast`.
--
-- Hand-written rather than grammar-generated so privata keeps zero runtime
-- dependencies and runs anywhere Lua does, including the LuaJIT embedded in
-- Neovim.
--
-- There is no error recovery. A file privata cannot read whole is reported as
-- one unparsable-module finding and nothing else, because a partially parsed
-- file stops contributing references: unrelated modules gain findings that are
-- not real while genuine findings vanish. Guessing past a syntax error would
-- produce exactly that failure silently.

local ast = require("privata._ast")
local lexer = require("privata._lexer")

local M = {}
local _P = {}

---@class privata.ParseState
---@field tokens privata.Token[]  the whole stream, always ending in an "eof" token
---@field index integer           1-based position of the token not yet consumed

--- Left and right binding power per binary operator.
--
-- Mirrors the table in Lua's own lparser.c. A right power below the left power
-- makes the operator right-associative, which is why `..` and `^` differ.
local BINARY_PRIORITY = {
  ["or"] = { 1, 1 },
  ["and"] = { 2, 2 },
  ["<"] = { 3, 3 },
  [">"] = { 3, 3 },
  ["<="] = { 3, 3 },
  [">="] = { 3, 3 },
  ["~="] = { 3, 3 },
  ["=="] = { 3, 3 },
  ["|"] = { 4, 4 },
  ["~"] = { 5, 5 },
  ["&"] = { 6, 6 },
  ["<<"] = { 7, 7 },
  [">>"] = { 7, 7 },
  [".."] = { 9, 8 },
  ["+"] = { 10, 10 },
  ["-"] = { 10, 10 },
  ["*"] = { 11, 11 },
  ["/"] = { 11, 11 },
  ["//"] = { 11, 11 },
  ["%"] = { 11, 11 },
  ["^"] = { 14, 13 },
}

local UNARY_PRIORITY = 12

local UNARY_OPERATORS = { ["-"] = true, ["not"] = true, ["#"] = true, ["~"] = true }

--- Keywords that close a block without being consumed by it.
local BLOCK_ENDS = {
  ["end"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["until"] = true,
}

--- Raise a syntax error naming the token it stopped at.
--
-- Thrown as a table with level 0, matching `_lexer.fail`, so `M.parse` can tell
-- a syntax error from a genuine crash and report only the former as a finding.
---@param token privata.Token
---@param message string
function _P.fail(token, message)
  local near = token.value
  if token.type == "eof" then
    near = "<eof>"
  end
  error({
    privata_syntax = true,
    line = token.line,
    message = message .. " near '" .. tostring(near) .. "'",
  }, 0)
end

--- The token `offset` places ahead, without consuming it.
--
-- With no offset this is always a token: the stream ends in "eof" and the
-- parser stops there, so the current position is never past the end. A
-- non-zero offset can run off the end, and the two callers that use one check
-- for nil themselves.
---@param state privata.ParseState
---@param offset integer|nil  defaults to 0, the current token
---@return privata.Token
function _P.peek(state, offset)
  return state.tokens[state.index + (offset or 0)]
end

--- Consume the current token and return it.
---@param state privata.ParseState
---@return privata.Token
function _P.advance(state)
  local token = state.tokens[state.index]
  state.index = state.index + 1
  return token
end

--- True when the current token is exactly this operator or keyword.
---@param state privata.ParseState
---@param kind string    token type, e.g. "op" or "keyword"
---@param value any      the exact token value to match
---@return boolean
function _P.check(state, kind, value)
  local token = state.tokens[state.index]
  return token.type == kind and token.value == value
end

--- Consume the current token if it matches, otherwise leave it alone.
---@param state privata.ParseState
---@param kind string
---@param value any
---@return privata.Token|nil  the consumed token, or nil when it did not match
function _P.accept(state, kind, value)
  if _P.check(state, kind, value) then
    return _P.advance(state)
  end
  return nil
end

--- Consume the current token or fail, naming what went unclosed.
---@param state privata.ParseState
---@param kind string
---@param value any
---@param what string|nil  construct being closed, for the error message
---@return privata.Token
function _P.expect(state, kind, value, what)
  local token = state.tokens[state.index]
  if token.type ~= kind or token.value ~= value then
    _P.fail(token, "'" .. value .. "' expected" .. (what and (" to close " .. what) or ""))
  end
  return _P.advance(state)
end

--- Consume an identifier token, or fail.
---@param state privata.ParseState
---@return privata.Token
function _P.expect_name(state)
  local token = state.tokens[state.index]
  if token.type ~= "name" then
    _P.fail(token, "<name> expected")
  end
  _P.advance(state)
  return token
end

--- Identify `goto` as a statement keyword without making it a reserved word.
--
-- `goto` is reserved from Lua 5.2 on but an ordinary name in 5.1 and LuaJIT,
-- where `goto = 1` and `goto()` are both legal. Only `goto <name>` in statement
-- position is a jump; anything else is the name.
---@param state privata.ParseState
---@return boolean
function _P.at_goto_statement(state)
  local token = _P.peek(state)
  if token.type ~= "name" or token.value ~= "goto" then
    return false
  end
  local next_token = _P.peek(state, 1)
  return next_token ~= nil and next_token.type == "name"
end

--- True at a token that closes the enclosing block without belonging to it.
--
-- `eof` counts, so an unterminated block is caught by whoever expected the
-- closing keyword rather than by running off the end of the token list.
---@param state privata.ParseState
---@return boolean
function _P.at_block_end(state)
  local token = _P.peek(state)
  if token.type == "eof" then
    return true
  end
  return token.type == "keyword" and BLOCK_ENDS[token.value] == true
end

--- Parse statements until the block's closing keyword.
--
-- The closer is left unconsumed for the caller, which is the only one that
-- knows which keyword is legal there and what to name in the error if it is not.
---@param state privata.ParseState
---@return privata.Node[]  statement nodes, in source order
function _P.parse_block(state)
  local body = {}
  local count = 0
  while not _P.at_block_end(state) do
    if _P.check(state, "keyword", "return") then
      count = count + 1
      body[count] = _P.parse_return(state)
      break -- `return` must be the last statement in its block.
    end
    local statement = _P.parse_statement(state)
    if statement then
      count = count + 1
      body[count] = statement
    end
  end
  return body
end

--- Parse `return`, which Lua allows only as the last statement in a block.
---@param state privata.ParseState
---@return privata.Node  a ReturnStatement node
function _P.parse_return(state)
  local token = _P.advance(state)
  local values = {}
  if not _P.at_block_end(state) and not _P.check(state, "op", ";") then
    values = _P.parse_expression_list(state)
  end
  _P.accept(state, "op", ";")
  return { kind = "ReturnStatement", values = values, line = token.line }
end

--- Parse one statement, dispatching on its leading token.
---@param state privata.ParseState
---@return privata.Node|nil  the statement node, or nil for a bare `;`, which binds nothing
function _P.parse_statement(state)
  local token = _P.peek(state)

  if token.type == "op" then
    if token.value == ";" then
      _P.advance(state)
      return nil
    end
    if token.value == "::" then
      return _P.parse_label(state)
    end
  end

  if token.type == "keyword" then
    local value = token.value
    if value == "if" then
      return _P.parse_if(state)
    elseif value == "while" then
      return _P.parse_while(state)
    elseif value == "do" then
      _P.advance(state)
      local body = _P.parse_block(state)
      _P.expect(state, "keyword", "end", "do block")
      return { kind = "DoStatement", body = body, line = token.line }
    elseif value == "for" then
      return _P.parse_for(state)
    elseif value == "repeat" then
      return _P.parse_repeat(state)
    elseif value == "function" then
      return _P.parse_function_declaration(state)
    elseif value == "local" then
      return _P.parse_local(state)
    elseif value == "break" then
      _P.advance(state)
      _P.accept(state, "op", ";")
      return { kind = "BreakStatement", line = token.line }
    end
  end

  if _P.at_goto_statement(state) then
    _P.advance(state)
    local label = _P.expect_name(state)
    return { kind = "GotoStatement", label = label.value, line = token.line }
  end

  return _P.parse_expression_statement(state)
end

--- Parse `::name::`.
---@param state privata.ParseState
---@return privata.Node  a LabelStatement node
function _P.parse_label(state)
  local token = _P.expect(state, "op", "::")
  local name = _P.expect_name(state)
  _P.expect(state, "op", "::", "label")
  return { kind = "LabelStatement", name = name.value, line = token.line }
end

--- Parse an `if`/`elseif`/`else` chain.
--
-- Each clause becomes its own `IfClause` node rather than a plain record, so
-- the walker in `_ast` can descend into it without a special case.
---@param state privata.ParseState
---@return privata.Node  an IfStatement node
function _P.parse_if(state)
  local token = _P.advance(state)
  local clauses = {}
  local count = 0

  local cond = _P.parse_expression(state)
  _P.expect(state, "keyword", "then")
  count = count + 1
  clauses[count] =
    { kind = "IfClause", cond = cond, body = _P.parse_block(state), line = token.line }

  while _P.check(state, "keyword", "elseif") do
    local clause_token = _P.advance(state)
    local clause_cond = _P.parse_expression(state)
    _P.expect(state, "keyword", "then")
    count = count + 1
    clauses[count] = {
      kind = "IfClause",
      cond = clause_cond,
      body = _P.parse_block(state),
      line = clause_token.line,
    }
  end

  local else_body = nil
  if _P.accept(state, "keyword", "else") then
    else_body = _P.parse_block(state)
  end

  _P.expect(state, "keyword", "end", "if statement")
  return { kind = "IfStatement", clauses = clauses, else_body = else_body, line = token.line }
end

--- Parse `while cond do ... end`.
---@param state privata.ParseState
---@return privata.Node  a WhileStatement node
function _P.parse_while(state)
  local token = _P.advance(state)
  local cond = _P.parse_expression(state)
  _P.expect(state, "keyword", "do")
  local body = _P.parse_block(state)
  _P.expect(state, "keyword", "end", "while loop")
  return { kind = "WhileStatement", cond = cond, body = body, line = token.line }
end

--- Parse `repeat ... until cond`.
--
-- The condition is parsed after the body because it can read the body's locals,
-- which is what makes `repeat` the one loop whose scope outlives its block.
---@param state privata.ParseState
---@return privata.Node  a RepeatStatement node
function _P.parse_repeat(state)
  local token = _P.advance(state)
  local body = _P.parse_block(state)
  _P.expect(state, "keyword", "until", "repeat loop")
  local cond = _P.parse_expression(state)
  return { kind = "RepeatStatement", body = body, cond = cond, line = token.line }
end

--- Parse both `for` forms, which share a prefix up to the first name.
---@param state privata.ParseState
---@return privata.Node  a NumericFor node when an `=` follows, else a GenericFor
function _P.parse_for(state)
  local token = _P.advance(state)
  local first = _P.expect_name(state)

  if _P.check(state, "op", "=") then
    _P.advance(state)
    local start = _P.parse_expression(state)
    _P.expect(state, "op", ",")
    local limit = _P.parse_expression(state)
    local step = nil
    if _P.accept(state, "op", ",") then
      step = _P.parse_expression(state)
    end
    _P.expect(state, "keyword", "do")
    local body = _P.parse_block(state)
    _P.expect(state, "keyword", "end", "for loop")
    return {
      kind = "NumericFor",
      var = _P.identifier(first),
      start = start,
      limit = limit,
      step = step,
      body = body,
      line = token.line,
    }
  end

  local names = { _P.identifier(first) }
  while _P.accept(state, "op", ",") do
    names[#names + 1] = _P.identifier(_P.expect_name(state))
  end
  _P.expect(state, "keyword", "in")
  local exprs = _P.parse_expression_list(state)
  _P.expect(state, "keyword", "do")
  local body = _P.parse_block(state)
  _P.expect(state, "keyword", "end", "for loop")
  return { kind = "GenericFor", names = names, exprs = exprs, body = body, line = token.line }
end

--- Parse `function a.b.c:d() end`.
--
-- The dotted target is built as an ordinary index chain, method name included,
-- so `function M.helper()` and `M.helper = function()` reach the checks as the
-- same assignment shape. `is_method` records only that `self` was implicit.
---@param state privata.ParseState
---@return privata.Node  a FunctionDeclaration node
function _P.parse_function_declaration(state)
  local token = _P.advance(state)
  local name = _P.expect_name(state)
  local target = _P.identifier(name)
  local is_method = false

  while _P.check(state, "op", ".") do
    _P.advance(state)
    local field = _P.expect_name(state)
    target = _P.index_node(target, field, false)
  end

  if _P.accept(state, "op", ":") then
    local field = _P.expect_name(state)
    target = _P.index_node(target, field, false)
    is_method = true
  end

  local func = _P.parse_function_body(state, token.line, is_method)
  return {
    kind = "FunctionDeclaration",
    target = target,
    func = func,
    is_method = is_method,
    line = token.line,
  }
end

--- Parse `local x`, `local x <const>` and `local function f`.
---@param state privata.ParseState
---@return privata.Node  a LocalFunction node for `local function`, else LocalDeclaration
function _P.parse_local(state)
  local token = _P.advance(state)

  if _P.accept(state, "keyword", "function") then
    local name = _P.expect_name(state)
    local func = _P.parse_function_body(state, token.line, false)
    return {
      kind = "LocalFunction",
      name = _P.identifier(name),
      func = func,
      line = token.line,
    }
  end

  local names = {}
  local attribs = {}
  repeat
    local name = _P.expect_name(state)
    names[#names + 1] = _P.identifier(name)
    -- Lua 5.4 `<const>` / `<close>`. Accepted on every dialect; privata does
    -- not act on the attribute, but must not choke on a file that uses it.
    if _P.accept(state, "op", "<") then
      local attrib = _P.expect_name(state)
      _P.expect(state, "op", ">", "attribute")
      attribs[#names] = attrib.value
    else
      attribs[#names] = false
    end
  until not _P.accept(state, "op", ",")

  local values = {}
  if _P.accept(state, "op", "=") then
    values = _P.parse_expression_list(state)
  end

  return {
    kind = "LocalDeclaration",
    names = names,
    attribs = attribs,
    values = values,
    line = token.line,
  }
end

--- Parse the statement forms that begin with an expression.
--
-- Lua allows only two: an assignment and a call. Both start the same way, so
-- the expression is parsed first and what follows decides which it was. The
-- assignability check happens here rather than in the grammar because `f() = 1`
-- parses cleanly and is only wrong once you know what a target may be.
---@param state privata.ParseState
---@return privata.Node  an Assignment node or a CallStatement node
function _P.parse_expression_statement(state)
  local token = _P.peek(state)
  local first = _P.parse_suffixed_expression(state)

  if _P.check(state, "op", "=") or _P.check(state, "op", ",") then
    local targets = { first }
    while _P.accept(state, "op", ",") do
      targets[#targets + 1] = _P.parse_suffixed_expression(state)
    end
    _P.expect(state, "op", "=")
    local values = _P.parse_expression_list(state)
    for i = 1, #targets do
      if not ast.ASSIGNABLE[targets[i].kind] then
        _P.fail(token, "cannot assign to this expression")
      end
    end
    return { kind = "Assignment", targets = targets, values = values, line = token.line }
  end

  if first.kind ~= "Call" and first.kind ~= "MethodCall" then
    _P.fail(token, "syntax error")
  end
  return { kind = "CallStatement", expr = first, line = token.line }
end

--- Parse one or more comma-separated expressions.
---@param state privata.ParseState
---@return privata.Node[]  expression nodes; always at least one
function _P.parse_expression_list(state)
  local list = { _P.parse_expression(state) }
  while _P.accept(state, "op", ",") do
    list[#list + 1] = _P.parse_expression(state)
  end
  return list
end

--- Parse a full expression, binding as loosely as the grammar allows.
---@param state privata.ParseState
---@return privata.Node  an expression node
function _P.parse_expression(state)
  return _P.parse_subexpression(state, 0)
end

--- Precedence climbing over the binary operators.
--
-- Stops at the first operator binding no tighter than `limit`, which is what
-- makes associativity fall out of the table: a right-associative operator
-- recurses with a limit below its own, so an equal operator to the right is
-- taken as part of the operand rather than ending it.
---@param state privata.ParseState
---@param limit integer  left binding power the caller has already committed to
---@return privata.Node  an expression node
function _P.parse_subexpression(state, limit)
  local left
  local token = _P.peek(state)
  local unary = (token.type == "op" or token.type == "keyword") and UNARY_OPERATORS[token.value]

  if unary then
    _P.advance(state)
    local operand = _P.parse_subexpression(state, UNARY_PRIORITY)
    left = { kind = "UnaryOp", op = token.value, operand = operand, line = token.line }
  else
    left = _P.parse_simple_expression(state)
  end

  while true do
    local op_token = _P.peek(state)
    if op_token.type ~= "op" and op_token.type ~= "keyword" then
      break
    end
    local priority = BINARY_PRIORITY[op_token.value]
    if not priority or priority[1] <= limit then
      break
    end
    _P.advance(state)
    local right = _P.parse_subexpression(state, priority[2])
    left = {
      kind = "BinaryOp",
      op = op_token.value,
      left = left,
      right = right,
      line = op_token.line,
    }
  end

  return left
end

--- Parse a literal, a function expression or a table, else fall through.
---@param state privata.ParseState
---@return privata.Node  an expression node
function _P.parse_simple_expression(state)
  local token = _P.peek(state)

  if token.type == "number" then
    _P.advance(state)
    return { kind = "Number", value = token.value, raw = token.raw, line = token.line }
  elseif token.type == "string" then
    _P.advance(state)
    return {
      kind = "String",
      value = token.value,
      raw = token.raw,
      long = token.long,
      line = token.line,
    }
  elseif token.type == "keyword" then
    if token.value == "nil" then
      _P.advance(state)
      return { kind = "Nil", line = token.line }
    elseif token.value == "true" then
      _P.advance(state)
      return { kind = "True", line = token.line }
    elseif token.value == "false" then
      _P.advance(state)
      return { kind = "False", line = token.line }
    elseif token.value == "function" then
      _P.advance(state)
      return _P.parse_function_body(state, token.line, false)
    end
  elseif token.type == "op" then
    if token.value == "..." then
      _P.advance(state)
      return { kind = "Vararg", line = token.line }
    elseif token.value == "{" then
      return _P.parse_table(state)
    end
  end

  return _P.parse_suffixed_expression(state)
end

--- Parse what a suffix chain can start from: a name or a parenthesised group.
--
-- Anything else is a syntax error, so the fall-through never returns. LuaLS
-- cannot see that through `_P.fail`, which raises rather than returning.
---@param state privata.ParseState
---@return privata.Node  an Identifier node or a Paren node
function _P.parse_primary_expression(state)
  local token = _P.peek(state)

  if token.type == "name" then
    _P.advance(state)
    return _P.identifier(token)
  end

  if _P.check(state, "op", "(") then
    _P.advance(state)
    local inner = _P.parse_expression(state)
    _P.expect(state, "op", ")", "parenthesised expression")
    -- Parentheses are kept because they are semantic in Lua: `(f())` truncates
    -- a multi-value call to one value.
    return { kind = "Paren", expr = inner, line = token.line }
  end

  ---@diagnostic disable-next-line: missing-return
  _P.fail(token, "unexpected symbol")
end

--- Apply `.field`, `[key]`, `:method(...)` and call suffixes, left to right.
--
-- Every suffix node keeps the line of the expression it started from, not of
-- the suffix, so a finding about `M.helper` points at where `M` was written.
---@param state privata.ParseState
---@return privata.Node  an expression node
function _P.parse_suffixed_expression(state)
  local expr = _P.parse_primary_expression(state)

  while true do
    local token = _P.peek(state)

    if token.type == "op" and token.value == "." then
      _P.advance(state)
      local field = _P.expect_name(state)
      expr = _P.index_node(expr, field, false)
    elseif token.type == "op" and token.value == "[" then
      _P.advance(state)
      local index = _P.parse_expression(state)
      _P.expect(state, "op", "]", "index")
      expr = {
        kind = "Index",
        object = expr,
        index = index,
        computed = true,
        line = expr.line,
      }
    elseif token.type == "op" and token.value == ":" then
      _P.advance(state)
      local method = _P.expect_name(state)
      local args = _P.parse_call_arguments(state)
      expr = {
        kind = "MethodCall",
        object = expr,
        method = method.value,
        method_line = method.line,
        args = args,
        line = expr.line,
      }
    elseif
      (token.type == "op" and (token.value == "(" or token.value == "{"))
      or token.type == "string"
    then
      local args = _P.parse_call_arguments(state)
      expr = { kind = "Call", callee = expr, args = args, line = expr.line }
    else
      return expr
    end
  end
end

--- Parse the three call-argument forms: `f(x)`, `f"s"`, `f{t}`.
---@param state privata.ParseState
---@return privata.Node[]  argument expression nodes; empty for `f()`
function _P.parse_call_arguments(state)
  local token = _P.peek(state)

  if token.type == "string" then
    _P.advance(state)
    return {
      {
        kind = "String",
        value = token.value,
        raw = token.raw,
        long = token.long,
        line = token.line,
      },
    }
  end

  if _P.check(state, "op", "{") then
    return { _P.parse_table(state) }
  end

  _P.expect(state, "op", "(")
  if _P.accept(state, "op", ")") then
    return {}
  end
  local args = _P.parse_expression_list(state)
  _P.expect(state, "op", ")", "argument list")
  return args
end

--- Parse a table constructor.
--
-- All three entry forms become `TableField` nodes, positional ones with a nil
-- key. A `name = value` key is stored as a String node marked `synthetic`, so a
-- check scanning string literals does not mistake a field name for one.
---@param state privata.ParseState
---@return privata.Node  a TableExpr node
function _P.parse_table(state)
  local token = _P.expect(state, "op", "{")
  local fields = {}
  local count = 0

  while not _P.check(state, "op", "}") do
    local field_token = _P.peek(state)

    if _P.check(state, "op", "[") then
      _P.advance(state)
      local key = _P.parse_expression(state)
      _P.expect(state, "op", "]", "table key")
      _P.expect(state, "op", "=")
      count = count + 1
      fields[count] = {
        kind = "TableField",
        key = key,
        value = _P.parse_expression(state),
        computed = true,
        line = field_token.line,
      }
    elseif field_token.type == "name" and _P.check_next_is_assign(state) then
      _P.advance(state)
      _P.advance(state)
      count = count + 1
      fields[count] = {
        kind = "TableField",
        key = {
          kind = "String",
          value = field_token.value,
          raw = field_token.value,
          synthetic = true,
          line = field_token.line,
        },
        value = _P.parse_expression(state),
        computed = false,
        line = field_token.line,
      }
    else
      count = count + 1
      fields[count] = {
        kind = "TableField",
        key = nil,
        value = _P.parse_expression(state),
        computed = false,
        line = field_token.line,
      }
    end

    if not (_P.accept(state, "op", ",") or _P.accept(state, "op", ";")) then
      break
    end
  end

  _P.expect(state, "op", "}", "table constructor")
  return { kind = "TableExpr", fields = fields, line = token.line }
end

--- True when the token after the current one is `=`.
--
-- One token of lookahead is what separates `{ x = 1 }` from `{ x }`: both start
-- with a name, and only the next token says whether it is a key or a value.
---@param state privata.ParseState
---@return boolean
function _P.check_next_is_assign(state)
  local next_token = _P.peek(state, 1)
  return next_token ~= nil and next_token.type == "op" and next_token.value == "="
end

--- Parse a parameter list and body, from the `(` through the closing `end`.
---@param state privata.ParseState
---@param line integer       line of the `function` keyword, which the node reports
---@param is_method boolean  true to prepend the implicit `self` parameter
---@return privata.Node  a FunctionExpr node
function _P.parse_function_body(state, line, is_method)
  local params = {}
  local is_vararg = false

  if is_method then
    -- The receiver is a real parameter to every later check; marking it
    -- implicit keeps a report from pointing at a column the source has not got.
    params[1] = { kind = "Identifier", name = "self", line = line, implicit = true }
  end

  _P.expect(state, "op", "(")
  if not _P.check(state, "op", ")") then
    repeat
      if _P.check(state, "op", "...") then
        local vararg = _P.advance(state)
        is_vararg = true
        params[#params + 1] =
          { kind = "Identifier", name = "...", line = vararg.line, vararg = true }
        break
      end
      params[#params + 1] = _P.identifier(_P.expect_name(state))
    until not _P.accept(state, "op", ",")
  end
  _P.expect(state, "op", ")", "parameter list")

  local body = _P.parse_block(state)
  local close = _P.expect(state, "keyword", "end", "function body")

  return {
    kind = "FunctionExpr",
    params = params,
    is_vararg = is_vararg,
    is_method = is_method,
    body = body,
    line = line,
    end_line = close.line,
  }
end

--- Wrap a name token as an Identifier node.
---@param token privata.Token
---@return privata.Node  an Identifier node
function _P.identifier(token)
  return { kind = "Identifier", name = token.value, line = token.line, col = token.col }
end

--- Build `a.b`, whose field name is stored as a String node.
--
-- `synthetic` marks it as a name the parser turned into a string, not a string
-- literal the author wrote. Checks that scan string contents for dispatch --
-- `v:lua.foo`, a name in a lookup table -- must not see every field access in
-- the file as a string mentioning that field.
---@param object privata.Node            the expression being indexed
---@param field_token privata.Token  the name token after the `.` or `:`
---@param computed boolean        true for `a[k]`, false for `a.b`
---@return privata.Node  an Index node
function _P.index_node(object, field_token, computed)
  return {
    kind = "Index",
    object = object,
    index = {
      kind = "String",
      value = field_token.value,
      raw = field_token.value,
      synthetic = true,
      line = field_token.line,
    },
    computed = computed,
    line = object.line,
    field_line = field_token.line,
  }
end

--- Parse `src` into a Chunk node.
--
-- Returns the node, or nil plus `{ line, message }` when the source cannot be
-- read whole. Callers turn the failure into an UnparsableModule rather than
-- propagating it, so one bad file never aborts a scan of the others.
---@param src string
---@return privata.Node|nil chunk  a Chunk node, or nil when the source cannot be read
---@return { line: integer, message: string }|nil error  set only when chunk is nil
function M.parse(src)
  local ok, result = pcall(function()
    local tokens = lexer.tokenize(src)
    local state = { tokens = tokens, index = 1 }
    local body = _P.parse_block(state)
    local token = _P.peek(state)
    if token.type ~= "eof" then
      _P.fail(token, "'<eof>' expected")
    end
    return { kind = "Chunk", body = body, line = 1 }
  end)

  if ok then
    return result
  end

  if type(result) == "table" and result.privata_syntax then
    return nil, { line = result.line or 0, message = result.message or "syntax error" }
  end
  error(result, 0)
end

return M
