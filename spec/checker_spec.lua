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

describe("checker", function()
  describe("the central rule", function()
    it("reports a field no other module reads", function()
      scan(
        {
          ["lua/pkg/service.lua"] = [[
          local M = {}
          function M.helper() return 1 end
          function M.run() return M.helper() end
          return M
        ]],
          ["lua/pkg/api.lua"] = [[
          local service = require("pkg.service")
          local M = {}
          function M.go() return service.run() end
          return M
        ]],
        },
        nil,
        function(findings)
          -- `go` qualifies too: nothing reads it either. `helper` is the point --
          -- it is read, but only from the module that defines it.
          assert.same({ "go", "helper" }, names(findings.symbols))
        end
      )
    end)

    it("keeps a field another module reads", function()
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
          ["lua/pkg/api.lua"] = [[
          local service = require("pkg.service")
          local M = {}
          function M.go() return service.run() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "go" }, names(findings.symbols))
        end
      )
    end)

    it("reads a field bound directly off the require", function()
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
          ["lua/pkg/api.lua"] = [[
          local run = require("pkg.service").run
          local M = {}
          function M.go() return run() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "go" }, names(findings.symbols))
        end
      )
    end)

    it("reads a field through an inline require", function()
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
          ["lua/pkg/api.lua"] = [[
          local M = {}
          function M.go() return require("pkg.service").run() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "go" }, names(findings.symbols))
        end
      )
    end)

    it("does not let a module's own reads keep its field public", function()
      -- This is the situation privata exists to report, not evidence against it.
      scan(
        {
          ["lua/pkg/service.lua"] = [[
          local M = {}
          function M.helper() end
          function M.a() M.helper() end
          function M.b() M.helper() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "a", "b", "helper" }, names(findings.symbols))
        end
      )
    end)
  end)

  describe("tests", function()
    it("does not let a spec confer publicity", function()
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\nfunction M.helper() end\nreturn M",
          ["spec/service_spec.lua"] = [[
          local service = require("pkg.service")
          describe("x", function() it("y", function() service.helper() end) end)
        ]],
        },
        nil,
        function(findings)
          assert.same({ "helper" }, names(findings.symbols))
        end
      )
    end)

    it("lets a co-located spec certify a helper in the same test root", function()
      -- A helper inside a test root exists to serve its own suite, so serving
      -- the suite is its job.
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\nreturn M",
          ["spec/support/helper.lua"] = [[
          local M = {}
          function M.build() end
          function M.unused() end
          return M
        ]],
          ["spec/service_spec.lua"] = [[
          local helper = require("spec.support.helper")
          describe("x", function() it("y", function() helper.build() end) end)
        ]],
        },
        nil,
        function(findings)
          assert.same({ "unused" }, names(findings.symbols))
        end
      )
    end)

    it("lets a test helper reach production internals", function()
      scan(
        {
          ["lua/pkg/_internal.lua"] = "local M = {}\nfunction M.go() end\nreturn M",
          ["lua/pkg/init.lua"] = [[
          local internal = require("pkg._internal")
          local M = {}
          function M.run() return internal.go() end
          return M
        ]],
          ["spec/support/helper.lua"] = [[
          local internal = require("pkg._internal")
          local M = {}
          function M.poke() return internal.go() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({}, findings.private_module_requires)
        end
      )
    end)
  end)

  describe("globals", function()
    it("reports an undeclared function", function()
      scan(
        {
          ["lua/pkg/init.lua"] = "function leaked() end\nlocal M = {}\nreturn M",
        },
        nil,
        function(findings)
          assert.same({ "leaked" }, names(findings.globals))
        end
      )
    end)

    it("honours the allowlist", function()
      scan({
        ["lua/pkg/init.lua"] = "wanted = 1\nlocal M = {}\nreturn M",
      }, { globals = { "wanted" } }, function(findings)
        assert.same({}, findings.globals)
      end)
    end)
  end)

  describe("private boundaries", function()
    it("reports a private module required from outside its owner", function()
      scan(
        {
          ["lua/pkg/feature/_runtime.lua"] = "local M = {}\nfunction M.go() end\nreturn M",
          ["lua/other/api.lua"] = [[
          local runtime = require("pkg.feature._runtime")
          local M = {}
          function M.go() return runtime.go() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.equal(1, #findings.private_module_requires)
          assert.equal("pkg.feature._runtime", findings.private_module_requires[1].module)
        end
      )
    end)

    it("lets the owning package reach its own private module", function()
      scan(
        {
          ["lua/pkg/_internal/thing.lua"] = "local M = {}\nfunction M.go() end\nreturn M",
          ["lua/pkg/api.lua"] = [[
          local thing = require("pkg._internal.thing")
          local M = {}
          function M.go() return thing.go() end
          return M
        ]],
        },
        nil,
        function(findings)
          -- Ownership starts at the first private segment, so `pkg` owns
          -- everything under `pkg._internal`.
          assert.same({}, findings.private_module_requires)
        end
      )
    end)

    it("reports a read of an underscore field on another module's table", function()
      scan(
        {
          ["lua/pkg/service.lua"] = [[
          local M = {}
          function M._helper() end
          function M.run() return M._helper() end
          return M
        ]],
          ["lua/pkg/api.lua"] = [[
          local service = require("pkg.service")
          local M = {}
          function M.go() return service._helper() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.equal(1, #findings.private_symbol_reads)
          assert.equal("_helper", findings.private_symbol_reads[1].name)
        end
      )
    end)

    it("reports a read through an exposed private namespace", function()
      -- `M._P = _P` is a common test seam. Reaching it from another production
      -- module is the boundary violation this check exists for.
      scan(
        {
          ["lua/pkg/service.lua"] = [[
          local _P = {}
          local M = {}
          function _P.secret() end
          function M.run() return _P.secret() end
          M._P = _P
          return M
        ]],
          ["lua/pkg/api.lua"] = [[
          local service = require("pkg.service")
          local M = {}
          function M.go() return service._P.secret() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.equal(1, #findings.private_symbol_reads)
          assert.equal("_P", findings.private_symbol_reads[1].name)
        end
      )
    end)
  end)

  describe("export tables", function()
    it("reports a name bound to nothing", function()
      -- Lua exports nil rather than raising, so nothing else catches this.
      scan(
        {
          ["lua/pkg/init.lua"] = "local function a() end\nreturn { a = a, b = b }",
        },
        nil,
        function(findings)
          assert.equal(1, #findings.export_issues)
          assert.equal("unknown", findings.export_issues[1].kind)
        end
      )
    end)

    it("leaves a data table alone", function()
      -- A preset or a lookup table is a value; its fields cannot be made
      -- private without deleting them.
      scan(
        {
          ["lua/pkg/init.lua"] = "return { colours = { 'red' }, size = 3 }",
        },
        nil,
        function(findings)
          assert.same({}, findings.export_issues)
          assert.same({}, findings.symbols)
        end
      )
    end)
  end)

  describe("unreliable scans", function()
    it("reports a file it cannot parse", function()
      scan({ ["lua/pkg/bad.lua"] = "local = =" }, nil, function(findings)
        assert.equal(1, #findings.unparsable)
      end)
    end)

    it("reports a module name claimed by two files", function()
      scan({
        ["lua/pkg.lua"] = "return {}",
        ["src/pkg.lua"] = "return {}",
      }, { source_roots = { "lua", "src" } }, function(findings)
        assert.equal(1, #findings.collisions)
        assert.equal("pkg", findings.collisions[1].module)
      end)
    end)

    it("reports a shape it declines to guess at", function()
      scan(
        {
          ["lua/pkg/init.lua"] = "local A, B = {}, {}\nif x then return A end\nreturn B",
        },
        nil,
        function(findings)
          assert.equal(1, #findings.unanalyzable)
          assert.matches("more than one place", findings.unanalyzable[1].reason)
        end
      )
    end)
  end)

  describe("exporting the private namespace", function()
    it("reports a module that returns the configured private namespace", function()
      -- `return _P` publishes the table the config calls private, which is the
      -- exact opposite of what naming it `_P` was meant to say.
      scan(
        {
          ["lua/pkg/thing.lua"] = [[
local _P = {}
function _P.helper() end
function _P.run() return _P.helper() end
return _P
]],
        },
        nil,
        function(findings)
          assert.equal(1, #findings.exported_namespaces)
          assert.equal("_P", findings.exported_namespaces[1].namespace)
          assert.equal(2, findings.exported_namespaces[1].public_symbols)
        end
      )
    end)

    it("suppresses the per-field findings for that module", function()
      -- Each would restate the same structural problem and point at a table the
      -- field already sits on.
      scan(
        {
          ["lua/pkg/thing.lua"] = [[
local _P = {}
function _P.helper() end
return _P
]],
        },
        nil,
        function(findings)
          assert.same({}, names(findings.symbols))
        end
      )
    end)

    it("names the table to merge into when the file already has one", function()
      scan(
        {
          ["lua/pkg/thing.lua"] = [[
local _P = {}
local M = {}
function _P.helper() end
function M.run() return _P.helper() end
return _P
]],
        },
        nil,
        function(findings)
          assert.equal("M", findings.exported_namespaces[1].public_table)
        end
      )
    end)

    it("leaves public_table nil when there is nothing to merge into", function()
      scan(
        {
          ["lua/pkg/thing.lua"] = "local _P = {}\nfunction _P.helper() end\nreturn _P",
        },
        nil,
        function(findings)
          assert.is_nil(findings.exported_namespaces[1].public_table)
        end
      )
    end)

    it("follows the configured namespace, not the literal name _P", function()
      scan({
        ["lua/pkg/thing.lua"] = "local Priv = {}\nfunction Priv.helper() end\nreturn Priv",
      }, { namespace = "Priv" }, function(findings)
        assert.equal(1, #findings.exported_namespaces)
      end)
    end)

    it("says nothing about a module returning an ordinary table", function()
      scan(
        {
          ["lua/pkg/thing.lua"] = "local M = {}\nfunction M.helper() end\nreturn M",
        },
        nil,
        function(findings)
          assert.same({}, findings.exported_namespaces)
          assert.same({ "helper" }, names(findings.symbols))
        end
      )
    end)
  end)

  describe("side-effect modules", function()
    it("does not report a file that returns nothing", function()
      scan(
        {
          ["lua/pkg/keymaps.lua"] = "local vim = vim\nvim.keymap.set('n', 'x', function() end)",
        },
        nil,
        function(findings)
          assert.same({}, findings.unanalyzable)
          assert.same({}, findings.symbols)
        end
      )
    end)

    it("still counts what a side-effect module reads", function()
      -- The file exports nothing, but its requires are real uses.
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
          ["lua/pkg/setup.lua"] = "local service = require('pkg.service')\nservice.run()",
        },
        nil,
        function(findings)
          assert.same({}, findings.symbols)
        end
      )
    end)
  end)

  describe("external interface", function()
    it("keeps the rock's namesake module public", function()
      -- Nothing inside a library requires its own entry point, but consumers do.
      scan(
        {
          ["thing-scm-1.rockspec"] = [[
          package = "thing"
          build = { modules = { ["thing"] = "lua/thing/init.lua" } }
        ]],
          ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        },
        nil,
        function(findings)
          assert.same({}, findings.symbols)
        end
      )
    end)

    it("counts a require from an installed script", function()
      scan(
        {
          ["thing-scm-1.rockspec"] = [[
          package = "thing"
          build = {
            modules = { ["thing.cli"] = "lua/thing/cli.lua" },
            install = { bin = { thing = "bin/thing.lua" } },
          }
        ]],
          ["lua/thing/cli.lua"] = "local M = {}\nfunction M.main() end\nreturn M",
          ["bin/thing.lua"] = "local cli = require('thing.cli')\nos.exit(cli.main(arg))",
        },
        nil,
        function(findings)
          assert.same({}, findings.symbols)
        end
      )
    end)
  end)

  describe("suppression", function()
    it("honours a privata: ignore comment on the definition line", function()
      scan(
        {
          ["lua/pkg/init.lua"] = [[
          local M = {}
          function M.helper() end -- privata: ignore
          function M.other() end
          return M
        ]],
        },
        nil,
        function(findings)
          assert.same({ "other" }, names(findings.symbols))
        end
      )
    end)
  end)

  describe("check toggles", function()
    it("skips a disabled check entirely", function()
      scan({
        ["lua/pkg/init.lua"] = "leaked = 1\nlocal M = {}\nfunction M.h() end\nreturn M",
      }, { checks = { globals = false } }, function(findings)
        assert.same({}, findings.globals)
        assert.same({ "h" }, names(findings.symbols))
      end)
    end)
  end)
end)
