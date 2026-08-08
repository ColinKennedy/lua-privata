local parser = require("privata._parser")
local scope = require("privata._scope")

local function analyze(src)
  return scope.analyze(assert(parser.parse(src)))
end

local function assigned_names(src)
  local names = {}
  for _, entry in ipairs(analyze(src).assigned) do
    names[#names + 1] = entry.name
  end
  return names
end

describe("scope", function()
  describe("global assignment", function()
    it("reports an undeclared function", function()
      assert.same({ "helper" }, assigned_names("function helper() end"))
    end)

    it("reports an undeclared assignment", function()
      assert.same({ "config" }, assigned_names("config = {}"))
    end)

    it("says whether a global holds a function", function()
      local entry = analyze("thing = function() end").assigned[1]
      assert.equal("function", entry.kind)
      assert.equal("value", analyze("thing = 1").assigned[1].kind)
    end)

    it("stays quiet about a local", function()
      assert.same({}, assigned_names("local function helper() end"))
      assert.same({}, assigned_names("local x\nx = 1"))
    end)

    it("reports the explicit _G spelling", function()
      assert.same({ "helper" }, assigned_names("_G.helper = function() end"))
    end)

    it("does not report a field on a local table", function()
      assert.same({}, assigned_names("local M = {}\nM.f = 1"))
    end)

    it("reports a global nested inside a function", function()
      assert.same({ "leaked" }, assigned_names("local function f()\n leaked = 1\nend"))
    end)

    it("records the line", function()
      assert.equal(2, analyze("local a = 1\nglobal_thing = 2").assigned[1].line)
    end)
  end)

  describe("scoping rules", function()
    it("evaluates a local initialiser before the name exists", function()
      -- `local x = x` reads the outer x, so the read must not resolve to the
      -- name being declared.
      assert.equal(1, analyze("local x = x").read.x)
    end)

    it("makes a local function visible inside its own body", function()
      assert.is_nil(analyze("local function f() return f() end").read.f)
    end)

    it("keeps a block local out of the enclosing scope", function()
      assert.same({ "inner" }, assigned_names("do local inner_local = 1 end\ninner = 1"))
    end)

    it("lets an until-condition see the loop body's locals", function()
      assert.is_nil(analyze("repeat local done = true until done").read.done)
    end)

    it("scopes for-loop variables to the loop", function()
      assert.equal(2, analyze("for i = 1, 2 do end\nreturn i").read.i)
      assert.is_nil(analyze("for i = 1, 2 do return i end").read.i)
    end)

    it("scopes generic-for names to the loop", function()
      assert.is_nil(analyze("for k, v in pairs(t) do return k, v end").read.k)
    end)

    it("scopes function parameters to the function", function()
      assert.is_nil(analyze("local f = function(a) return a end").read.a)
      assert.equal(2, analyze("local f = function(a) end\nreturn a").read.a)
    end)
  end)

  describe("locals budget", function()
    it("counts locals in the chunk's own scope", function()
      assert.equal(2, analyze("local a = 1\nlocal b = 2").chunk_locals)
    end)

    it("does not count block locals against the chunk", function()
      -- Lua's limit is per function, and a do-block shares the enclosing
      -- function's register file, but privata only budgets what it would add.
      assert.equal(1, analyze("local a = 1\ndo local b = 2 end").chunk_locals)
    end)

    it("counts a repeated declaration once", function()
      assert.equal(1, analyze("local a = 1\nlocal a = 2").chunk_locals)
    end)

    it("tracks the largest function scope", function()
      assert.equal(3, analyze("local f = function(a, b) local c end").max_function_locals)
    end)
  end)
end)
