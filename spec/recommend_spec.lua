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
  fields = fields or {}
  local table_locals = fields.table_locals or {}
  -- A file privata found a private namespace in necessarily declares it, so
  -- the two always agree outside a deliberately contrived case.
  if fields.private_name then
    table_locals[fields.private_name] = true
  end
  return {
    shape = { private_name = fields.private_name, table_locals = table_locals },
    scope = { chunk_locals = fields.chunk_locals or 3 },
  }
end

describe("recommend", function()
  describe("strategy order", function()
    it("recommends the namespace by default", function()
      local result = recommend.for_symbol(symbol({}), module_record(), settings())
      assert.equal("namespace", result.strategy)
      assert.matches("move to `_P%.helper`", result.text)
    end)

    it("uses the configured namespace when the file already declares it", function()
      local record = module_record({ private_name = "_internal" })
      local result = recommend.for_symbol(symbol({}), record, settings({ namespace = "_internal" }))
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
      assert.equal("local_function", result.strategy)
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
      assert.equal("namespace", result.strategy)
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
      assert.equal("namespace", result.strategy)
    end)

    it("names the forward declaration a later definition would need", function()
      -- `M.a` may call `M.b` defined further down, but a local cannot: the name
      -- would resolve to a global and silently be nil.
      local result = recommend.for_symbol(
        symbol({ line = 10, uses = { 4 } }),
        module_record(),
        settings(prefer_local)
      )
      assert.equal("local_function", result.strategy)
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
      assert.equal("namespace", result.strategy)
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

  describe("never recommends a move to where the symbol already is", function()
    it("skips the namespace when the public table is already named _P", function()
      -- `local _P = {} ... return _P` exports `_P`, so its fields sit on a
      -- table named exactly like the namespace privata would suggest. Telling
      -- the author to move `_P.x` to `_P.x` is not an instruction.
      local result = recommend.for_symbol(
        symbol({ namespace = "_P" }),
        module_record({ table_locals = { _P = true } }),
        settings()
      )
      assert.not_equal("namespace", result.strategy)
      assert.is_nil(result.text:find("move to `_P%.helper`"))
    end)

    it("does not tell a file with a _P local to add one", function()
      local result = recommend.for_symbol(
        symbol({ namespace = "M" }),
        module_record({ table_locals = { _P = true } }),
        settings()
      )
      assert.equal("namespace", result.strategy)
      assert.same({}, result.notes)
    end)

    it("skips the underscore field for an already underscore-led name", function()
      local result = recommend.for_symbol(
        symbol({ name = "_helper", namespace = "M" }),
        module_record(),
        settings({ privatize = { "underscore_field" } })
      )
      assert.not_equal("underscore_field", result.strategy)
    end)
  end)

  describe("never names a table other than the configured namespace", function()
    it("ignores a stale private_name that disagrees with the config", function()
      -- Belt and braces: shape should never hand over a name the config did not
      -- ask for, and if it ever did, the recommendation must not repeat it.
      local record = module_record({ private_name = "_DEFAULT_CHARS" })
      local result = recommend.for_symbol(symbol({}), record, settings())
      assert.matches("move to `_P%.helper`", result.text)
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
      assert.equal("underscore_field", result.strategy)
      assert.matches("rename to `M%._helper`", result.text)
    end)
  end)
end)
