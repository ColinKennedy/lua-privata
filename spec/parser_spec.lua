local ast = require("privata._ast")
local parser = require("privata._parser")

--- Parse, asserting success, and return the chunk body.
local function body(src)
  local chunk, err = parser.parse(src)
  assert.is_nil(err)
  assert.equals("Chunk", chunk.kind)
  return chunk.body
end

local function first(src)
  return body(src)[1]
end

local function fails(src)
  local chunk, err = parser.parse(src)
  assert.is_nil(chunk)
  assert.is_table(err)
  return err
end

--- Collect node kinds in walk order, which is the order checks will see them.
local function kinds(node)
  local seen = {}
  ast.walk(node, function(current)
    seen[#seen + 1] = current.kind
  end)
  return seen
end

describe("parser", function()
  describe("statements", function()
    it("parses a local declaration with several names", function()
      local node = first("local a, b = 1, 2")
      assert.equals("LocalDeclaration", node.kind)
      assert.same({ "a", "b" }, { node.names[1].name, node.names[2].name })
      assert.equals(2, #node.values)
    end)

    it("parses a local declaration with no values", function()
      local node = first("local a")
      assert.equals(0, #node.values)
    end)

    it("parses 5.4 attributes without acting on them", function()
      local node = first("local a <const>, b <close> = 1, 2")
      assert.same({ "const", "close" }, node.attribs)
    end)

    it("parses local function", function()
      local node = first("local function helper() end")
      assert.equals("LocalFunction", node.kind)
      assert.equals("helper", node.name.name)
      assert.equals("FunctionExpr", node.func.kind)
    end)

    it("parses assignment to several targets", function()
      local node = first("a, b.c = 1, 2")
      assert.equals("Assignment", node.kind)
      assert.equals(2, #node.targets)
      assert.equals("Index", node.targets[2].kind)
    end)

    it("rejects assignment to a call", function()
      assert.matches("cannot assign", fails("f() = 1").message)
    end)

    it("rejects a bare expression that is not a call", function()
      assert.matches("syntax error", fails("a + b").message)
    end)

    it("parses if/elseif/else as clauses plus an else body", function()
      local node = first("if a then x() elseif b then y() else z() end")
      assert.equals("IfStatement", node.kind)
      assert.equals(2, #node.clauses)
      assert.equals(1, #node.else_body)
    end)

    it("leaves else_body nil when there is no else", function()
      assert.is_nil(first("if a then end").else_body)
    end)

    it("parses both for shapes", function()
      assert.equals("NumericFor", first("for i = 1, 10 do end").kind)
      assert.equals("NumericFor", first("for i = 1, 10, 2 do end").kind)
      local generic = first("for k, v in pairs(t) do end")
      assert.equals("GenericFor", generic.kind)
      assert.same({ "k", "v" }, { generic.names[1].name, generic.names[2].name })
    end)

    it("parses while, repeat and do", function()
      assert.equals("WhileStatement", first("while a do end").kind)
      assert.equals("RepeatStatement", first("repeat until a").kind)
      assert.equals("DoStatement", first("do end").kind)
    end)

    it("parses return with and without values", function()
      assert.equals(0, #first("return").values)
      assert.equals(2, #first("return a, b").values)
    end)

    it("rejects a statement after return", function()
      assert.matches("'<eof>' expected", fails("return a b()").message)
    end)

    it("skips empty statements", function()
      assert.equals(1, #body(";;a();;"))
    end)

    it("parses labels and goto", function()
      local statements = body("::top:: goto top")
      assert.equals("LabelStatement", statements[1].kind)
      assert.equals("GotoStatement", statements[2].kind)
      assert.equals("top", statements[2].label)
    end)

    it("still treats goto as a name where 5.1 allows it", function()
      -- `goto = 1` is legal 5.1 and LuaJIT. Making `goto` reserved would fail
      -- the file, and a file that fails to parse stops contributing references.
      assert.equals("Assignment", first("goto = 1").kind)
      assert.equals("CallStatement", first("goto()").kind)
    end)
  end)

  describe("functions", function()
    it("builds a dotted declaration target as an index chain", function()
      local node = first("function a.b.c() end")
      assert.equals("FunctionDeclaration", node.kind)
      assert.equals("a.b.c", ast.dotted_name(node.target))
      assert.is_false(node.is_method)
    end)

    it("folds a method declaration into the same target shape", function()
      -- `function M.helper()` and `M.helper = function()` must reach the checks
      -- as one shape, or every check would need to know both spellings.
      local node = first("function C:m() end")
      assert.equals("C.m", ast.dotted_name(node.target))
      assert.is_true(node.is_method)
    end)

    it("gives a method an implicit self parameter", function()
      local node = first("function C:m(a) end")
      assert.same({ "self", "a" }, { node.func.params[1].name, node.func.params[2].name })
      assert.is_true(node.func.params[1].implicit)
    end)

    it("records varargs", function()
      local node = first("local f = function(a, ...) end")
      assert.is_true(node.values[1].is_vararg)
    end)

    it("records the closing line", function()
      local node = first("local function f()\n\nend")
      assert.equals(1, node.func.line)
      assert.equals(3, node.func.end_line)
    end)
  end)

  describe("expressions", function()
    it("applies left associativity and precedence", function()
      local node = first("return 1 + 2 * 3").values[1]
      assert.equals("+", node.op)
      assert.equals("*", node.right.op)
    end)

    it("makes concatenation right associative", function()
      local node = first("return a .. b .. c").values[1]
      assert.equals("..", node.op)
      assert.equals("..", node.right.op)
    end)

    it("makes exponentiation right associative and tighter than unary minus", function()
      local node = first("return -a ^ b").values[1]
      assert.equals("UnaryOp", node.kind)
      assert.equals("^", node.operand.op)
    end)

    it("parses comparison below arithmetic", function()
      local node = first("return a + 1 < b").values[1]
      assert.equals("<", node.op)
      assert.equals("+", node.left.op)
    end)

    it("parses 5.3 bitwise operators at their own levels", function()
      local node = first("return a | b & c").values[1]
      assert.equals("|", node.op)
      assert.equals("&", node.right.op)
    end)

    it("distinguishes unary from binary ~", function()
      assert.equals("UnaryOp", first("return ~a").values[1].kind)
      assert.equals("BinaryOp", first("return a ~ b").values[1].kind)
    end)

    it("keeps parentheses, which are semantic in Lua", function()
      -- `(f())` truncates a multi-value call to one value, so the node cannot
      -- be folded away.
      local node = first("return (f())").values[1]
      assert.equals("Paren", node.kind)
      assert.equals("Call", node.expr.kind)
    end)

    it("parses all three call-argument forms", function()
      assert.equals("Call", first("f(1)").expr.kind)
      assert.equals("String", first("f 'x'").expr.args[1].kind)
      assert.equals("TableExpr", first("f { a = 1 }").expr.args[1].kind)
    end)

    it("parses method calls", function()
      local node = first("obj:run(1)").expr
      assert.equals("MethodCall", node.kind)
      assert.equals("run", node.method)
      assert.equals("obj", node.object.name)
    end)

    it("chains suffixes", function()
      -- `:d()` is one MethodCall node, not a Call wrapping an index, so the
      -- receiver stays attached to the call that uses it.
      local node = first("return a.b[c]:d().e").values[1]
      assert.equals("Index", node.kind)
      assert.equals("e", node.index.value)
      assert.equals("MethodCall", node.object.kind)
      assert.equals("d", node.object.method)
      assert.equals("Index", node.object.object.kind)
      assert.is_true(node.object.object.computed)
    end)

    it("marks computed indexes so a name is never invented for one", function()
      assert.is_false(first("return a.b").values[1].computed)
      assert.is_true(first("return a[b]").values[1].computed)
      assert.is_nil(ast.dotted_name(first("return a[b].c").values[1]))
    end)
  end)

  describe("tables", function()
    it("parses the three field forms", function()
      local node = first("return { 1, x = 2, [k] = 3 }").values[1]
      assert.equals(3, #node.fields)
      assert.is_nil(node.fields[1].key)
      assert.equals("x", node.fields[2].key.value)
      assert.is_false(node.fields[2].computed)
      assert.is_true(node.fields[3].computed)
    end)

    it("accepts semicolons and a trailing separator", function()
      local node = first("return { 1; 2, }").values[1]
      assert.equals(2, #node.fields)
    end)

    it("parses an empty table", function()
      assert.equals(0, #first("return {}").values[1].fields)
    end)
  end)

  describe("walking", function()
    it("visits parents before children in source order", function()
      assert.same({
        "Chunk",
        "LocalDeclaration",
        "Identifier",
        "BinaryOp",
        "Number",
        "Number",
      }, kinds(parser.parse("local a = 1 + 2")))
    end)

    it("stops descending when a visitor returns false", function()
      local seen = {}
      ast.walk(parser.parse("local a = function() return b end"), function(node)
        seen[#seen + 1] = node.kind
        return node.kind ~= "FunctionExpr"
      end)
      assert.same({ "Chunk", "LocalDeclaration", "Identifier", "FunctionExpr" }, seen)
    end)

    it("walk_shallow visits a nested function without entering it", function()
      -- The node has to be seen -- `M.helper = function() end` binds a function
      -- and a caller must be able to tell that -- but its body is another scope.
      local seen = {}
      ast.walk_shallow(parser.parse("local f = function() return inner end"), function(node)
        seen[#seen + 1] = node.kind
      end)
      assert.same({ "Chunk", "LocalDeclaration", "Identifier", "FunctionExpr" }, seen)
    end)

    it("walk_shallow enters the root when the root is the function", function()
      local chunk = parser.parse("local f = function() return inner end")
      local seen = {}
      ast.walk_shallow(chunk.body[1].values[1], function(node)
        seen[#seen + 1] = node.kind
      end)
      assert.same({ "FunctionExpr", "ReturnStatement", "Identifier" }, seen)
    end)

    it("declares children for every node kind it can produce", function()
      -- A missing entry makes the walker raise rather than silently skip a
      -- subtree, which would drop references and invent findings.
      local src = table.concat({
        "local a <const> = 1",
        "local function f(...) return ... end",
        "function M.g() end",
        "function C:h() end",
        "a, b = 1, 2",
        "do end",
        "while a do break end",
        "repeat until a",
        "if a then elseif b then else end",
        "for i = 1, 2, 3 do end",
        "for k in pairs(t) do end",
        "::l:: goto l",
        "x = { 1, y = 2, [z] = 3 }",
        "x = -a ^ #b .. not c",
        "x = (a).b[c]:d 'e'",
        "x = nil or true and false",
        "return x",
      }, "\n")
      local chunk = parser.parse(src)
      assert.has_no.errors(function()
        ast.walk(chunk, function() end)
      end)
    end)
  end)

  describe("failure reporting", function()
    it("reports the line of the offending token", function()
      local err = fails("local a = 1\nlocal b =\n")
      assert.equals(3, err.line)
    end)

    it("reports an unclosed block against the construct it closes", function()
      assert.matches("to close function body", fails("local function f()").message)
    end)

    it("returns nil rather than raising, so one bad file cannot abort a scan", function()
      local chunk, err = parser.parse("local = =")
      assert.is_nil(chunk)
      assert.is_number(err.line)
      assert.is_string(err.message)
    end)
  end)
end)
