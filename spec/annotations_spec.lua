--- The type-annotation reference scan.
--
-- Every case here is one shape of the same problem: a class module is reached
-- through instances, so nothing in the project ever writes `item.position`, and
-- the require graph has no edge to the method. The annotation the caller already
-- wrote is the edge.

local annotations = require("privata._annotations")
local privata = require("privata")
local project = require("spec.support.project")

--- Scan a temporary project and hand the findings to `body`.
local function scan(files, overrides, body)
  project.with(files, function(root)
    local findings, config = privata.check(root, overrides)
    assert.is_table(findings, type(config) == "table" and "" or tostring(config and config[1]))
    body(findings, root)
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

--- A class module whose only interface is its methods.
--
-- `new` is read across the boundary by every consumer below, so the only names
-- left for the symbol check to argue about are the two methods.
local ITEM = [[
---@class pkg.Item
---@field line integer
local Item = {}
Item.__index = Item

function Item.new()
  return setmetatable({ line = 1 }, Item)
end

function Item:position()
  return self.line
end

function Item:text()
  return "text"
end

return Item
]]

describe("annotations", function()
  describe("---@param", function()
    it("counts a method call on an annotated parameter", function()
      -- The case this feature exists for: `report` never requires the class and
      -- never names `Item.position`, yet it calls it on every finding.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param item pkg.Item
          function M.render(item)
            return item:position() .. item:text()
          end

          return M
        ]],
          ["lua/pkg/api.lua"] = [[
          local Item = require("pkg.item")
          local report = require("pkg.report")
          local M = {}
          function M.go() return report.render(Item.new()) end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "go" }, names(findings.symbols))
        end
      )
    end)

    it("counts a plain field read on an annotated parameter", function()
      -- A rename breaks `item.line` exactly as it breaks `item:position()`.
      scan(
        {
          ["lua/pkg/item.lua"] = [[
          ---@class pkg.Item
          local Item = {}
          Item.__index = Item
          Item.line = 0
          return Item
        ]],
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param item pkg.Item
          function M.render(item)
            return item.line
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "render" }, names(findings.symbols))
        end
      )
    end)

    it("sees a class named inside a container type", function()
      -- `table<string, pkg.Item>` is one type written with a space in it, so
      -- reading only up to the first space would lose the name that mattered.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param items table<string, pkg.Item>
          ---@param first pkg.Item
          function M.render(items, first)
            return items and first:position() and first:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)

    it("sees a class named in an array or a union", function()
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param first pkg.Item|nil
          ---@param rest pkg.Item[]
          function M.render(first, rest)
            return first:position() and rest and first:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)

    it("ignores a class name that only appears in the description", function()
      -- Reading past the type expression would let any prose word claim a
      -- reference, and the words after a type are prose by definition.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param count integer how many pkg.Item values were found
          function M.render(count)
            return count:position()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "position", "render", "text" }, names(findings.symbols))
        end
      )
    end)
  end)

  describe("---@type", function()
    it("counts a method call on an annotated local", function()
      -- `---@type` names no variable of its own, so the declaration underneath
      -- it is the only thing that says what was typed.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          function M.render(raw)
            ---@type pkg.Item
            local item = raw
            return item:position() .. item:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)

    it("attaches a trailing annotation to the line it sits on", function()
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          function M.render(raw)
            local item = raw ---@type pkg.Item
            return item:position() .. item:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)

    it("attaches through a comment block to the next line of code", function()
      -- Doc comments sit between the tag and the declaration constantly, and a
      -- blank line between them is a style, not a statement about scope.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          function M.render(raw)
            ---@type pkg.Item
            -- The finding currently being rendered.

            local item = raw
            return item:position() .. item:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)

    it("types an assignment as well as a declaration", function()
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          function M.render(raw)
            local item
            ---@type pkg.Item
            item = raw
            return item:position() .. item:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)
  end)

  describe("---@cast", function()
    it("counts a method call after a cast", function()
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          function M.render(raw)
            ---@cast raw pkg.Item
            return raw:position() .. raw:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)

    it("reads the type a narrowing cast adds", function()
      -- `---@cast x +pkg.Item` adds to a union rather than replacing it, and the
      -- name it adds is still a reference to the module that declares it.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          function M.render(raw)
            ---@cast raw +pkg.Item
            return raw:position() .. raw:text()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "render" }, names(findings.symbols))
        end
      )
    end)
  end)

  describe("what it declines to credit", function()
    it("requires the class to be the module's exported table", function()
      -- An options record, a result shape, an internal node: a file declares
      -- several classes and publishes one of them.
      scan(
        {
          ["lua/pkg/item.lua"] = [[
          ---@class pkg.Item.Opts
          local DEFAULTS = {}

          ---@class pkg.Item
          local Item = {}
          Item.__index = Item
          function Item:position() return DEFAULTS end
          return Item
        ]],
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param opts pkg.Item.Opts
          function M.render(opts)
            return opts:position()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "position", "render" }, names(findings.symbols))
        end
      )
    end)

    it("does not follow a type through an index expression", function()
      -- `items[1]` has the element type, but privata reads declarations rather
      -- than inferring them, and nothing declares the element.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["lua/pkg/report.lua"] = [[
          local M = {}

          ---@param items pkg.Item[]
          function M.render(items)
            return items[1]:position()
          end

          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "position", "render", "text" }, names(findings.symbols))
        end
      )
    end)

    it("does not let a spec's annotation confer publicity", function()
      -- The same rule as everywhere else: tests may reach internals without
      -- pinning them public forever.
      scan(
        {
          ["lua/pkg/item.lua"] = ITEM,
          ["spec/item_spec.lua"] = [[
          local Item = require("pkg.item")

          ---@param item pkg.Item
          local function check(item)
            return item:position() .. item:text()
          end

          return check(Item.new())
        ]],
        },
        nil,
        function(findings)
          assert.same({ "new", "position", "text" }, names(findings.symbols))
        end
      )
    end)

    it("does not let a module certify its own methods", function()
      scan(
        {
          ["lua/pkg/item.lua"] = [[
          ---@class pkg.Item
          local Item = {}
          Item.__index = Item

          function Item:position() return 1 end

          ---@param other pkg.Item
          function Item:before(other)
            return other:position()
          end

          return Item
        ]],
        },
        nil,
        function(findings)
          assert.same({ "before", "position" }, names(findings.symbols))
        end
      )
    end)
  end)

  it("credits every module declaring a name it cannot tell apart", function()
    -- Two files really do declare `pkg.Item`; privata cannot resolve which one a
    -- caller meant, and keeping the method public in both is the direction that
    -- never breaks code.
    scan(
      {
        ["lua/pkg/one.lua"] = [[
        ---@class pkg.Item
        local Item = {}
        Item.__index = Item
        function Item:position() return 1 end
        return Item
      ]],
        ["lua/pkg/two.lua"] = [[
        ---@class pkg.Item
        local Item = {}
        Item.__index = Item
        function Item:position() return 2 end
        return Item
      ]],
        ["lua/pkg/report.lua"] = [[
        local M = {}

        ---@param item pkg.Item
        function M.render(item)
          return item:position()
        end

        return M
      ]],
      },
      nil,
      function(findings)
        assert.same({ "render" }, names(findings.symbols))
      end
    )
  end)

  it("keeps a method the method check would otherwise report", function()
    scan({
      ["lua/pkg/item.lua"] = [[
        ---@class pkg.Item
        local Item = {}
        Item.__index = Item
        function Item:position() return 1 end
        function Item:orphan() return 2 end
        return Item
      ]],
      ["lua/pkg/report.lua"] = [[
        local M = {}

        ---@param item pkg.Item
        function M.render(item)
          return item:position()
        end

        return M
      ]],
    }, { methods = true }, function(findings)
      assert.same({ "orphan" }, names(findings.methods))
    end)
  end)

  describe("reading the tag itself", function()
    it("parses a class declared exact and with a parent", function()
      local found = annotations.scan("---@class (exact) pkg.Item : pkg.Base\nlocal Item = {}\n")
      assert.same({ "pkg.Item" }, found[1].types)
      assert.equal(2, found[1].attached_line)
    end)

    it("keeps a function type whole", function()
      local found = annotations.scan("---@param run fun(item: pkg.Item): boolean the callback\n")
      assert.equal("run", found[1].name)
      assert.same({ "fun", "item", "pkg.Item", "boolean" }, found[1].types)
    end)

    it("skips a tag it has no use for", function()
      local found = annotations.scan("---@field name string\n---@return pkg.Item\n")
      assert.same({}, found)
    end)

    it("drops a param with no name to read", function()
      assert.same({}, annotations.scan("---@param\n---@cast\n"))
    end)

    it("stops a type expression at a closer it never opened", function()
      -- The comment is inside something the annotation does not own, so the
      -- closer is not part of the type.
      assert.equal("pkg.Item", annotations._P.type_expression("pkg.Item) trailing"))
    end)

    it("leaves an unattached annotation unattached", function()
      local found = annotations.scan("local x = 1\n---@type pkg.Item\n")
      assert.equal(nil, found[1].attached_line)
    end)
  end)
end)
