local privata = require("privata")
local project = require("spec.support.project")

local PROJECT = {
  ["lua/pkg/init.lua"] = [[
local M = {}
function M.helper() end
function M.run() return M.helper() end
return M
]],
  ["lua/pkg/point.lua"] = [[
local C = {}
C.__index = C
function C:scale() end
return C
]],
  ["lua/pkg/_secret.lua"] = [[
local M = {}
function M._go() end
function M.q() return M._go() end
return M
]],
  ["lua/other/reach.lua"] = [[
local secret = require("pkg._secret")
local M = {}
function M.go() return secret._go() end
return M
]],
  ["lua/pkg/exports.lua"] = "local function a() end\nreturn { a = a, b = b }",
  ["lua/pkg/broken.lua"] = "local = =",
  ["lua/pkg/odd.lua"] = "local A, B = {}, {}\nif x then return A end\nreturn B",
  ["lua/pkg/globals.lua"] = "leaked = 1\nlocal M = {}\nreturn M",
}

describe("public api", function()
  it("returns findings and the effective config from check", function()
    project.with(PROJECT, function(root)
      local findings, config = privata.check(root)
      assert.is_table(findings)
      assert.equals("_P", config.namespace)
    end)
  end)

  it("reports a bad config rather than raising", function()
    project.with({ [".privata.lua"] = "return { format = 'xml' }" }, function(root)
      local findings, problems = privata.check(root)
      assert.is_nil(findings)
      assert.is_string(problems[1])
    end)
  end)

  it("exposes each finding kind through its own helper", function()
    project.with(PROJECT, function(root)
      assert.is_true(#privata.find_private_candidates(root) > 0)
      assert.is_true(#privata.find_globals(root) > 0)
      assert.is_true(#privata.find_private_module_requires(root) > 0)
      assert.is_true(#privata.find_private_symbol_reads(root) > 0)
      assert.is_true(#privata.find_export_issues(root) > 0)
      assert.is_true(#privata.find_unparsable(root) > 0)
      assert.is_true(#privata.find_unanalyzable(root) > 0)
    end)
  end)

  it("runs the method check whenever it is asked for by name", function()
    -- Calling the helper is the opt-in, so the config flag is beside the point.
    project.with(PROJECT, function(root)
      assert.equals(0, #privata.check(root).methods)
      assert.is_true(#privata.find_method_candidates(root) > 0)
    end)
  end)

  it("finds colliding module names", function()
    project.with({
      ["lua/pkg.lua"] = "return {}",
      ["src/pkg.lua"] = "return {}",
      [".privata.lua"] = "return { source_roots = { 'lua', 'src' } }",
    }, function(root)
      assert.equals(1, #privata.find_collisions(root))
    end)
  end)

  it("returns an empty list from every helper when the config is bad", function()
    project.with({ [".privata.lua"] = "return { format = 'xml' }" }, function(root)
      assert.same({}, privata.find_private_candidates(root))
      assert.same({}, privata.find_globals(root))
      assert.same({}, privata.find_private_module_requires(root))
      assert.same({}, privata.find_private_symbol_reads(root))
      assert.same({}, privata.find_export_issues(root))
      assert.same({}, privata.find_method_candidates(root))
      assert.same({}, privata.find_unparsable(root))
      assert.same({}, privata.find_unanalyzable(root))
      assert.same({}, privata.find_collisions(root))
    end)
  end)

  it("carries a version string", function()
    assert.matches("%d+%.%d+%.%d+", privata._VERSION)
  end)
end)
