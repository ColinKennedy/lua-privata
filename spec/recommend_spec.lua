local config_mod = require("privata._config")
local recommend = require("privata._recommend")

local function settings(overrides)
  local base = config_mod._P.defaults()
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

--- A symbol as `_modules` would build it.
local function symbol(fields)
  return {
    name = fields.name or "helper",
    path_name = "M." .. (fields.name or "helper"),
    kind = fields.kind or "function",
    namespace = fields.namespace or "M",
    line = fields.line or 10,
    end_line = fields.end_line or fields.line or 10,
    uses = fields.uses or {},
  }
end

local function module_record(fields)
  return {
    shape = { private_name = fields and fields.private_name or nil },
    scope = { chunk_locals = (fields and fields.chunk_locals) or 3 },
  }
end

describe("recommend", function()
  describe("strategy order", function()
    it("recommends the namespace by default", function()
      local result = recommend.for_symbol(symbol({}), module_record(), settings())
      assert.equals("namespace", result.strategy)
      assert.matches("move to `_P%.helper`", result.text)
    end)

    it("uses the namespace the file already has", function()
      local record = module_record({ private_name = "_internal" })
      local result = recommend.for_symbol(symbol({}), record, settings())
      assert.matches("move to `_internal%.helper`", result.text)
      assert.same({}, result.notes)
    end)

    it("says where to declare a namespace the file lacks", function()
      local result = recommend.for_symbol(symbol({}), module_record(), settings())
      assert.matches("add `local _P = {}`", result.notes[1])
    end)

    it("honours a configured order", function()
      local result = recommend.for_symbol(
        symbol({}),
        module_record(),
        settings({ privatize = { "local_function", "namespace" } })
      )
      assert.equals("local_function", result.strategy)
      assert.matches("local function helper", result.text)
    end)

    it("falls back to the namespace when nothing configured applies", function()
      -- The namespace form always applies, so it is the floor rather than an
      -- error: a recommendation that cannot be followed is worse than none.
      local result = recommend.for_symbol(
        symbol({}),
        module_record({ chunk_locals = 500 }),
        settings({ privatize = { "local_function" } })
      )
      assert.equals("namespace", result.strategy)
    end)
  end)

  describe("local_function applicability", function()
    local prefer_local = { privatize = { "local_function", "namespace" } }

    it("falls through when the chunk is near Lua's local limit", function()
      local result = recommend.for_symbol(
        symbol({}),
        module_record({ chunk_locals = 180 }),
        settings(prefer_local)
      )
      assert.equals("namespace", result.strategy)
    end)

    it("names the forward declaration a later definition would need", function()
      -- `M.a` may call `M.b` defined further down, but a local cannot: the name
      -- would resolve to a global and silently be nil.
      local result = recommend.for_symbol(
        symbol({ line = 10, uses = { 4 } }),
        module_record(),
        settings(prefer_local)
      )
      assert.equals("local_function", result.strategy)
      assert.matches("forward `local helper` before line 4", result.notes[1])
    end)

    it("falls through instead when forward declarations are turned off", function()
      local result = recommend.for_symbol(
        symbol({ line = 10, uses = { 4 } }),
        module_record(),
        settings({
          privatize = { "local_function", "namespace" },
          local_function_forward_decl = false,
        })
      )
      assert.equals("namespace", result.strategy)
    end)

    it("uses the assignment form when configured", function()
      local result = recommend.for_symbol(
        symbol({}),
        module_record(),
        settings({
          privatize = { "local_function" },
          local_function_style = "assignment",
        })
      )
      assert.matches("local helper = function", result.text)
    end)

    it("forces the statement form for a self-recursive definition", function()
      -- `local f = function()` cannot see its own name inside its initialiser.
      local result = recommend.for_symbol(
        symbol({ line = 10, end_line = 14, uses = { 12 } }),
        module_record(),
        settings({
          privatize = { "local_function" },
          local_function_style = "assignment",
        })
      )
      assert.matches("local function helper", result.text)
      assert.matches("calls itself", result.notes[1])
    end)

    it("makes a non-function a plain local", function()
      local result = recommend.for_symbol(
        symbol({ kind = "table" }),
        module_record(),
        settings({ privatize = { "local_function" } })
      )
      assert.matches("local helper", result.text)
    end)
  end)

  describe("special cases", function()
    it("tells a literal export table to drop the name", function()
      -- The binding is already a local; there is nothing to move.
      local result =
        recommend.for_symbol(symbol({ namespace = "return" }), module_record(), settings())
      assert.matches("drop `helper` from the returned table", result.text)
    end)

    it("renames to an underscore field when that is the only strategy", function()
      local result = recommend.for_symbol(
        symbol({}),
        module_record(),
        settings({ privatize = { "underscore_field" } })
      )
      assert.equals("underscore_field", result.strategy)
      assert.matches("rename to `M%._helper`", result.text)
    end)
  end)
end)
