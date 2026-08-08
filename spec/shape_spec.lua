local parser = require("privata._parser")
local shape = require("privata._shape")

local function detect(src, config)
  return shape.detect(assert(parser.parse(src)), config)
end

describe("shape", function()
  describe("recognised idioms", function()
    it("reads the classic local M table", function()
      local result = detect("local M = {}\nfunction M.f() end\nreturn M")
      assert.equal("table", result.kind)
      assert.equal("M", result.public_name)
    end)

    it("reads a two-namespace module", function()
      local result = detect("local _P = {}\nlocal M = {}\nreturn M")
      assert.equal("M", result.public_name)
      assert.equal("_P", result.private_name)
    end)

    it("uses the configured namespace name", function()
      local result = detect("local Priv = {}\nlocal M = {}\nreturn M", { namespace = "Priv" })
      assert.equal("Priv", result.private_name)
    end)

    it("does not mistake a private constant table for the namespace", function()
      -- `local _DEFAULT_CHARS = {...}` is a private constant, not a namespace.
      -- Treating it as one made privata recommend moving unrelated functions
      -- into a table of characters.
      local result = detect("local _DEFAULT_CHARS = { 'a' }\nlocal M = {}\nreturn M")
      assert.is_nil(result.private_name)
    end)

    it("only recognises the configured namespace name", function()
      local source = "local _internal = {}\nlocal M = {}\nreturn M"
      assert.is_nil(detect(source).private_name)
      assert.equal("_internal", detect(source, { namespace = "_internal" }).private_name)
    end)

    it("reads a literal export table", function()
      local result = detect("local function a() end\nreturn { a = a }")
      assert.equal("literal", result.kind)
      assert.equal("TableExpr", result.literal.kind)
    end)

    it("reads a metatable class", function()
      local result = detect("local C = {}\nC.__index = C\nfunction C:m() end\nreturn C")
      assert.equal("class", result.kind)
      assert.equal("C", result.public_name)
    end)

    it("unwraps a setmetatable on the way out", function()
      local result = detect("local M = {}\nreturn setmetatable(M, {})")
      assert.equal("table", result.kind)
      assert.equal("M", result.public_name)
    end)

    it("accepts a local built with setmetatable", function()
      local result = detect("local M = setmetatable({}, {})\nreturn M")
      assert.equal("table", result.kind)
    end)

    it("does not treat the returned table as its own private namespace", function()
      -- A file whose only table is named _P is publishing it, whatever it is
      -- called, so nothing in that file is private by namespace.
      local result = detect("local _P = {}\nreturn _P")
      assert.equal("_P", result.public_name)
      assert.is_nil(result.private_name)
    end)
  end)

  describe("side-effect modules", function()
    it("recognises a file that returns nothing", function()
      -- Setting autocommands or keymaps and returning nothing is an idiom, not
      -- a shape privata failed to read.
      local result = detect("vim.keymap.set('n', 'x', function() end)")
      assert.equal("side_effect", result.kind)
      assert.is_nil(result.reason)
    end)
  end)

  describe("refusals", function()
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
      assert.equal(2, result.line)
    end)
  end)
end)
