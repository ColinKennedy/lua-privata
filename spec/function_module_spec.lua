local privata = require("privata")
local project = require("spec.support.project")
local text_report = require("privata._report.text")
local config_mod = require("privata._config")

--- Scan a temporary project and hand the findings to `body`.
local function scan(files, overrides, body)
  project.with(files, function(root)
    local findings, config = privata.check(root, overrides)
    assert.is_table(findings, type(config) == "table" and "" or tostring(config and config[1]))
    body(findings, root)
  end)
end

local function modules(findings)
  local out = {}
  for i = 1, #findings.function_modules do
    out[i] = findings.function_modules[i].module
  end
  table.sort(out)
  return out
end

describe("function modules", function()
  describe("the shape itself", function()
    it("reads a module whose whole export is a function", function()
      -- The point of the shape: `local get_foo = require("thing.get_foo")`
      -- followed by `get_foo(10)` is a module used through its return value and
      -- nothing else. Before privata knew the idiom it refused to read the file
      -- at all, which reported the one thing about it that was not a problem.
      scan(
        {
          ["lua/thing/get_foo.lua"] = "local function get_foo(n) return n + 1 end\nreturn get_foo",
          ["lua/thing/init.lua"] = [[
          local get_foo = require("thing.get_foo")
          local M = {}
          function M.run() return get_foo(10) end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
          assert.same({}, findings.unanalyzable)
        end
      )
    end)

    it("reads a function returned without a name", function()
      scan(
        {
          ["lua/thing/run.lua"] = "return function(n) return n end",
          ["lua/thing/init.lua"] = [[
          local run = require("thing.run")
          local M = {}
          function M.go() return run(1) end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
          assert.same({}, findings.unanalyzable)
        end
      )
    end)

    it("still refuses a module that re-exports someone else's function", function()
      -- `return require("other")` hands back a callable this file does not own,
      -- so its interface is not this file's to report on.
      scan(
        {
          ["lua/thing/alias.lua"] = "return require('thing.other')",
          ["lua/thing/other.lua"] = "return function() end",
        },
        nil,
        function(findings)
          assert.equal(1, #findings.unanalyzable)
          assert.equal("thing.alias", findings.unanalyzable[1].module)
        end
      )
    end)
  end)

  describe("the usage rule", function()
    it("reports a function module nothing requires", function()
      scan(
        {
          ["lua/thing/orphan.lua"] = "local function run() end\nreturn run",
        },
        nil,
        function(findings)
          assert.same({ "thing.orphan" }, modules(findings))
          local entry = findings.function_modules[1]
          assert.equal("run", entry.name)
          assert.is_false(entry.anonymous)
          assert.equal("thing._orphan", entry.private_module)
          assert.equal(1, entry.line)
        end
      )
    end)

    it("credits a require whose result is called inline", function()
      scan(
        {
          ["lua/thing/run.lua"] = "return function() end",
          ["lua/thing/init.lua"] = "local M = {}\n"
            .. "function M.go() return require('thing.run')() end\n"
            .. "return M",
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
        end
      )
    end)

    it("credits a require written inside a string", function()
      -- A host that resolves the name at evaluation time -- a Neovim keymap,
      -- a session file sourced back later -- reaches the module without any
      -- field ever being indexed, which the field-shaped matcher cannot see.
      scan(
        {
          ["lua/thing/toggle.lua"] = "return function() end",
          ["lua/thing/init.lua"] = [[
          local M = {}
          M.rhs = "lua require('thing.toggle')()"
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
        end
      )
    end)

    it("reports one a spec requires, and names the spec", function()
      -- Test usage does not make a module public, for the same reason it does
      -- not make a field public. The remedy survives the suite either way: a
      -- spec is allowed to require a private module.
      scan(
        {
          ["lua/thing/orphan.lua"] = "local function run() end\nreturn run",
          ["spec/orphan_spec.lua"] = "local run = require('thing.orphan')\nrun()",
        },
        nil,
        function(findings, root)
          assert.same({ "thing.orphan" }, modules(findings))
          local where = findings.function_modules[1].test_require
          assert.is_table(where)
          assert.matches("orphan_spec%.lua$", where.path)
          assert.equal(1, where.line)
          assert.is_string(root)
        end
      )
    end)

    it("credits a helper its own suite requires", function()
      -- A helper living in a test root exists to serve that suite, so a spec
      -- requiring it is a real use -- the module-level twin of the rule that
      -- lets a spec certify a helper's fields.
      scan(
        {
          ["spec/support/build.lua"] = "return function() end",
          ["spec/thing_spec.lua"] = "local build = require('spec.support.build')\nbuild()",
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
        end
      )
    end)

    it("leaves a module the patterns already mark private alone", function()
      -- There is no publicity left to remove. An unused private module is dead
      -- code, and privata reports interface drift rather than dead code.
      scan(
        {
          ["lua/thing/_orphan.lua"] = "return function() end",
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
        end
      )
    end)

    it("keeps the rock's namesake module, which consumers require", function()
      scan(
        {
          ["thing-scm-1.rockspec"] = 'package = "thing"\n'
            .. 'build = { modules = { thing = "lua/thing.lua" } }',
          ["lua/thing.lua"] = "return function() end",
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
        end
      )
    end)

    it("keeps a module a declared interface exposes", function()
      scan({
        ["lua/thing/health.lua"] = "return function() end",
      }, {
        interfaces = { { expose = { ".*" }, from = { ".*\\.health" } } },
      }, function(findings)
        assert.same({}, modules(findings))
      end)
    end)

    it("still reports one an interface names some other symbol of", function()
      -- An interface is a statement about names, not a blanket exemption for
      -- the module it points at: the one name this file publishes is not on it.
      scan({
        ["lua/thing/health.lua"] = "return function() end",
      }, {
        interfaces = { { expose = { "setup" }, from = { ".*\\.health" } } },
      }, function(findings)
        assert.same({ "thing.health" }, modules(findings))
      end)
    end)

    it("honours a line-scoped ignore", function()
      scan(
        {
          ["lua/thing/orphan.lua"] = "return function() end -- privata: ignore",
        },
        nil,
        function(findings)
          assert.same({}, modules(findings))
        end
      )
    end)

    it("can be switched off", function()
      scan({
        ["lua/thing/orphan.lua"] = "return function() end",
      }, { checks = { function_modules = false } }, function(findings)
        assert.same({}, modules(findings))
      end)
    end)
  end)

  describe("what it still says about the file", function()
    it("publishes no symbols of its own", function()
      -- Not even the helpers it keeps on a private namespace: a function cannot
      -- be indexed, so nothing inside such a file is reachable from outside it.
      scan(
        {
          ["lua/thing/orphan.lua"] = [[
          local _P = {}
          function _P.helper() end
          local function run() return _P.helper() end
          return run
        ]],
        },
        nil,
        function(findings)
          assert.same({}, findings.symbols)
        end
      )
    end)

    it("still counts as a reader of what it requires", function()
      -- A function module is parsed like any other, so the fields it reads keep
      -- those fields public. Treating it as unreadable lost exactly this.
      scan(
        {
          ["lua/thing/service.lua"] = "local M = {}\nfunction M.load() end\nreturn M",
          ["lua/thing/run.lua"] = [[
          local service = require("thing.service")
          return function() return service.load() end
        ]],
          ["lua/thing/init.lua"] = [[
          local run = require("thing.run")
          local M = {}
          function M.go() return run() end
          return M
        ]],
        },
        nil,
        function(findings)
          local names = {}
          for i = 1, #findings.symbols do
            names[i] = findings.symbols[i].name
          end
          assert.same({ "go" }, names)
        end
      )
    end)
  end)

  describe("the recommendation", function()
    it("names the private module to rename to", function()
      project.with({
        ["lua/thing/orphan.lua"] = "local function run() end\nreturn run",
      }, function(root)
        local config = assert(config_mod.load(root))
        local findings = assert(privata.check(root))
        local text = text_report.render(findings, project.display(root), config)
        assert.matches("returns function `run`, which no other module requires", text)
        assert.matches("rename the module to `thing%._orphan`", text)
      end)
    end)

    it("falls back to general wording when the convention would not satisfy the project", function()
      -- `private_module_patterns` holds Lua patterns, and a pattern cannot be
      -- inverted. privata proposes the underscore convention only when the
      -- project's own rule agrees the result is private.
      local overrides = { private_module_patterns = { "^internal_" } }
      project.with({
        ["lua/thing/orphan.lua"] = "return function() end",
      }, function(root)
        local config = assert(config_mod.load(root, overrides))
        local findings = assert(privata.check(root, overrides))
        local text = text_report.render(findings, project.display(root), config)
        assert.matches("returns a function, which no other module requires", text)
        assert.matches("`private_module_patterns` marks private", text)
      end)
    end)
  end)
end)
