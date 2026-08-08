local privata = require("privata")
local project = require("spec.support.project")

local function scan(files, body)
  project.with(files, function(root)
    body(privata.find_method_candidates(root), root)
  end)
end

local function names(list)
  local out = {}
  for i = 1, #list do
    out[i] = list[i].name
  end
  table.sort(out)
  return out
end

describe("methods", function()
  it("reports a method no other module refers to", function()
    -- The divergence from python-privata lives here: a returned class is still
    -- checked, because `return C` is the only way Lua ships a class at all.
    scan({
      ["lua/pkg/point.lua"] = [[
        local C = {}
        C.__index = C
        function C.new() return setmetatable({}, C) end
        function C:len() return self:scale() end
        function C:scale() return 1 end
        return C
      ]],
      ["lua/pkg/api.lua"] = [[
        local Point = require("pkg.point")
        local M = {}
        function M.go() return Point.new():len() end
        return M
      ]],
    }, function(findings)
      assert.same({ "scale" }, names(findings))
    end)
  end)

  it("counts the class's public methods for the ratio", function()
    scan({
      ["lua/pkg/point.lua"] = [[
        local C = {}
        C.__index = C
        function C:a() end
        function C:b() end
        function C:c() end
        return C
      ]],
    }, function(findings)
      assert.equal(3, findings[1].class_public_methods)
      assert.equal("C", findings[1].class_name)
    end)
  end)

  it("skips a class anything uses as a base", function()
    -- A subclass that only overrides a method never mentions the name, so
    -- renaming the base method would strand the override.
    scan({
      ["lua/pkg/base.lua"] = [[
        local Base = {}
        Base.__index = Base
        function Base:run() end
        return Base
      ]],
      ["lua/pkg/child.lua"] = [[
        local Base = require("pkg.base")
        local Child = setmetatable({}, { __index = Base })
        Child.__index = Child
        return Child
      ]],
    }, function(findings)
      assert.same({}, names(findings))
    end)
  end)

  it("skips a class that indexes itself by a computed name", function()
    scan({
      ["lua/pkg/visitor.lua"] = [[
        local C = {}
        C.__index = C
        function C:visit(kind) return self["visit_" .. kind] end
        function C:visit_name() end
        return C
      ]],
    }, function(findings)
      assert.same({}, names(findings))
    end)
  end)

  it("treats a string literal elsewhere as a reference", function()
    scan({
      ["lua/pkg/point.lua"] = [[
        local C = {}
        C.__index = C
        function C:scale() end
        return C
      ]],
      ["lua/pkg/api.lua"] = [[
        local M = {}
        M.dispatch = { "scale" }
        return M
      ]],
    }, function(findings)
      assert.same({}, names(findings))
    end)
  end)

  it("leaves private methods and metamethods alone", function()
    scan({
      ["lua/pkg/point.lua"] = [[
        local C = {}
        C.__index = C
        function C:__tostring() return "" end
        function C:_hidden() end
        return C
      ]],
    }, function(findings)
      assert.same({}, names(findings))
    end)
  end)

  it("honours a privata: ignore comment", function()
    scan({
      ["lua/pkg/point.lua"] = [[
        local C = {}
        C.__index = C
        function C:scale() end -- privata: ignore
        function C:other() end
        return C
      ]],
    }, function(findings)
      assert.same({ "other" }, names(findings))
    end)
  end)

  it("does not run unless asked", function()
    project.with({
      ["lua/pkg/point.lua"] = [[
        local C = {}
        C.__index = C
        function C:scale() end
        return C
      ]],
    }, function(root)
      assert.same({}, privata.check(root).methods)
      assert.equal(1, #privata.check(root, { methods = true }).methods)
    end)
  end)
end)
