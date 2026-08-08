local parser = require("privata._parser")
local shape = require("privata._shape")

local function detect(src, config)
  return shape.detect(assert(parser.parse(src)), config)
end

describe("shape", function()
  describe("recognised idioms", function()
    it("reads the classic local M table", function()
      local result = detect("local M = {}\nfunction M.f() end\nreturn M")
      assert.equals("table", result.kind)
      assert.equals("M", result.public_name)
    end)

    it("reads a two-namespace module", function()
      local result = detect("local _P = {}\nlocal M = {}\nreturn M")
      assert.equals("M", result.public_name)
      assert.equals("_P", result.private_name)
    end)

    it("uses the configured namespace name", function()
      local result = detect("local Priv = {}\nlocal M = {}\nreturn M", { namespace = "Priv" })
      assert.equals("Priv", result.private_name)
    end)

    it("still finds an underscore namespace when none is configured", function()
      local result = detect("local _internal = {}\nlocal M = {}\nreturn M")
      assert.equals("_internal", result.private_name)
    end)

    it("reads a literal export table", function()
      local result = detect("local function a() end\nreturn { a = a }")
      assert.equals("literal", result.kind)
      assert.equals("TableExpr", result.literal.kind)
    end)

    it("reads a metatable class", function()
      local result = detect("local C = {}\nC.__index = C\nfunction C:m() end\nreturn C")
      assert.equals("class", result.kind)
      assert.equals("C", result.public_name)
    end)

    it("unwraps a setmetatable on the way out", function()
      local result = detect("local M = {}\nreturn setmetatable(M, {})")
      assert.equals("table", result.kind)
      assert.equals("M", result.public_name)
    end)

    it("accepts a local built with setmetatable", function()
      local result = detect("local M = setmetatable({}, {})\nreturn M")
      assert.equals("table", result.kind)
    end)

    it("does not treat the returned table as its own private namespace", function()
      -- A file whose only table is named _P is publishing it, whatever it is
      -- called, so nothing in that file is private by namespace.
      local result = detect("local _P = {}\nreturn _P")
      assert.equals("_P", result.public_name)
      assert.is_nil(result.private_name)
    end)
  end)

  describe("refusals", function()
    it("refuses a file that returns nothing", function()
      assert.matches("returns nothing", detect("local M = {}").reason)
    end)

    it("refuses several return values", function()
      assert.matches("more than one value", detect("local M = {}\nreturn M, 1").reason)
    end)

    it("refuses a conditional return", function()
      -- Different interpreters would read different interfaces, and neither
      -- answer is right for every reader.
      local result = detect("local A, B = {}, {}\nif x then return A end\nreturn B")
      assert.matches("more than one place", result.reason)
    end)

    it("refuses a returned name this file did not build", function()
      assert.matches("cannot read", detect("local M = require('other')\nreturn M").reason)
    end)

    it("refuses a computed return", function()
      assert.matches("cannot read", detect("return make_module()").reason)
    end)

    it("refuses the 5.1 module function", function()
      assert.matches("module%(%)", detect("module('x', package.seeall)\nreturn nil").reason)
    end)

    it("reports a line with every refusal, so the finding can be located", function()
      local result = detect("local M = {}\nreturn M, 1")
      assert.equals(2, result.line)
    end)
  end)
end)
