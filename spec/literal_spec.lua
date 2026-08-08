local literal = require("privata._literal")
local parser = require("privata._parser")

local function eval_expression(src)
  local chunk = assert(parser.parse("return " .. src))
  return literal._P.eval(chunk.body[1].values[1])
end

describe("literal", function()
  describe("eval", function()
    it("reads scalars", function()
      assert.equals("x", eval_expression([["x"]]))
      assert.equals(3, eval_expression("3"))
      assert.equals(true, eval_expression("true"))
      assert.equals(false, eval_expression("false"))
    end)

    it("reads negative numbers", function()
      assert.equals(-2, eval_expression("-2"))
    end)

    it("folds literal concatenation, which rockspecs use constantly", function()
      assert.equals("ab", eval_expression([["a" .. "b"]]))
    end)

    it("refuses concatenation involving a name", function()
      local value, err = eval_expression([["a" .. name]])
      assert.is_nil(value)
      assert.is_string(err)
    end)

    it("reads array and record tables", function()
      assert.same({ 1, 2 }, eval_expression("{ 1, 2 }"))
      assert.same({ a = 1 }, eval_expression("{ a = 1 }"))
      assert.same({ a = { b = "c" } }, eval_expression("{ a = { b = 'c' } }"))
    end)

    it("reads a computed but literal key", function()
      assert.same({ [2] = "x" }, eval_expression("{ [2] = 'x' }"))
    end)

    it("refuses a table holding a function", function()
      -- The point of parsing rather than loading is that a config cannot run,
      -- so a value privata would have to execute is not a value at all.
      local value, err = eval_expression("{ f = function() end }")
      assert.is_nil(value)
      assert.is_string(err)
    end)

    it("refuses a name reference", function()
      assert.is_nil(eval_expression("somevar"))
    end)

    it("refuses a call", function()
      assert.is_nil(eval_expression("os.getenv('X')"))
    end)
  end)

  describe("assignments", function()
    it("collects top-level globals as a rockspec writes them", function()
      local data = literal.load_assignments([[
        package = "privata"
        version = "scm-1"
        build = { type = "builtin", modules = { ["privata"] = "lua/privata/init.lua" } }
      ]])
      assert.equals("privata", data.package)
      assert.equals("lua/privata/init.lua", data.build.modules["privata"])
    end)

    it("omits a name whose value it cannot read", function()
      local data = literal.load_assignments("a = 1\nb = os.time()")
      assert.equals(1, data.a)
      assert.is_nil(data.b)
    end)

    it("reports a parse failure rather than returning a partial table", function()
      local data, err = literal.load_assignments("a = =")
      assert.is_nil(data)
      assert.matches("line %d+", err)
    end)
  end)

  describe("returned_table", function()
    it("reads the table a config file returns", function()
      local data = literal.load_returned_table("return { namespace = '_Q' }")
      assert.equals("_Q", data.namespace)
    end)

    it("rejects a file that returns nothing", function()
      local data, err = literal.load_returned_table("local x = 1")
      assert.is_nil(data)
      assert.matches("does not return", err)
    end)

    it("rejects a file that returns a non-table", function()
      local data, err = literal.load_returned_table("return 1")
      assert.is_nil(data)
      assert.matches("must return a table", err)
    end)

    it("rejects a file that returns several values", function()
      local data, err = literal.load_returned_table("return {}, {}")
      assert.is_nil(data)
      assert.matches("exactly one table", err)
    end)
  end)
end)
