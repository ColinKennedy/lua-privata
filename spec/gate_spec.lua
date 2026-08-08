local checker = require("privata._checker")
local cli = require("privata.cli")
local config_mod = require("privata._config")
local privata = require("privata")
local project = require("spec.support.project")

local function capture()
  local buffer = {}
  return {
    write = function(_, text)
      buffer[#buffer + 1] = text
    end,
    text = function()
      return table.concat(buffer)
    end,
  }
end

local function run(root, argv)
  local out, err = capture(), capture()
  local arguments = { root }
  for i = 1, #argv do
    arguments[#arguments + 1] = argv[i]
  end
  return cli.main(arguments, { out = out, err = err }), out.text(), err.text()
end

local DIRTY = { ["lua/pkg/init.lua"] = "leaked = 1\nlocal M = {}\nfunction M.h() end\nreturn M" }

describe("package-private visibility", function()
  local SIBLINGS = {
    ["lua/app/helpers.lua"] = [[
local M = {}
M._SHARED = 1
function M.use() return M._SHARED end
return M
]],
    ["lua/app/reader.lua"] = [[
local helpers = require("app.helpers")
local M = {}
function M.go() return helpers._SHARED end
return M
]],
  }

  it("reports a sibling read by default", function()
    project.with(SIBLINGS, function(root)
      local findings = assert(privata.check(root))
      assert.equal(1, #findings.private_symbol_reads)
    end)
  end)

  it("stays quiet when both modules share a configured package", function()
    -- `M._SHARED` read by a sibling of the same application is a third
    -- visibility level, not a boundary violation with a call site to fix.
    project.with(SIBLINGS, function(root)
      local findings = assert(privata.check(root, { package_private = { "app" } }))
      assert.same({}, findings.private_symbol_reads)
    end)
  end)

  it("still reports a read from outside the package", function()
    project.with({
      ["lua/app/helpers.lua"] = "local M = {}\nM._SHARED = 1\n"
        .. "function M.u() return M._SHARED end\nreturn M",
      ["lua/other/reader.lua"] = [[
local helpers = require("app.helpers")
local M = {}
function M.go() return helpers._SHARED end
return M
]],
    }, function(root)
      local findings = assert(privata.check(root, { package_private = { "app" } }))
      assert.equal(1, #findings.private_symbol_reads)
    end)
  end)

  it("applies to private module requires too", function()
    -- `app.one._internal` is owned by `app.one`, so `app.two.api` reaching it
    -- is reported by default. Both live under `app`, so a package-private rule
    -- naming `app` permits it.
    local files = {
      ["lua/app/one/_internal.lua"] = "local M = {}\nfunction M.go() end\nreturn M",
      ["lua/app/two/api.lua"] = [[
local internal = require("app.one._internal")
local M = {}
function M.go() return internal.go() end
return M
]],
    }
    project.with(files, function(root)
      assert.equal(1, #assert(privata.check(root)).private_module_requires)
    end)
    project.with(files, function(root)
      local findings = assert(privata.check(root, { package_private = { "app" } }))
      assert.same({}, findings.private_module_requires)
    end)
  end)
end)

describe("fail_on", function()
  it("blocks on every kind by default", function()
    project.with(DIRTY, function(root)
      assert.equal(cli._P.EXIT_FINDINGS, (run(root, {})))
    end)
  end)

  it("lets a project report a kind without blocking on it", function()
    -- `checks` cannot express this: switching a check off also stops it
    -- reporting, so "tell me but do not block me" had no expression.
    project.with({
      ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M",
      [".privata.lua"] = 'return { fail_on = { "globals" } }',
    }, function(root)
      local code, out = run(root, {})
      assert.equal(cli._P.EXIT_OK, code)
      -- Still printed; only the exit code changed.
      assert.matches("could be made private", out)
    end)
  end)

  it("rejects an unknown kind", function()
    project.with({ [".privata.lua"] = 'return { fail_on = { "nope" } }' }, function(root)
      local code, _, err = run(root, {})
      assert.equal(cli._P.EXIT_USAGE, code)
      assert.matches("unknown fail_on kind", err)
    end)
  end)

  it("never blocks on an advisory finding", function()
    -- privata has concluded there is no action that improves the file; failing
    -- the build on it would be asking for work that cannot be done.
    project.with({
      ["lua/pkg/thing.lua"] = "local _P = {}\nfunction _P.h() end\nreturn _P",
      ["spec/thing_spec.lua"] = 'local t = require("pkg.thing")\nt.h()',
      [".privata.lua"] = 'return { fail_on = { "exported_namespaces" } }',
    }, function(root)
      local code, out = run(root, {})
      assert.matches("test handle", out)
      assert.equal(cli._P.EXIT_OK, code)
    end)
  end)
end)

describe("report ordering", function()
  it("puts defects above design opinions", function()
    -- An accidental global is a bug; a privatisable symbol is a preference.
    project.with(DIRTY, function(root)
      local config = assert(config_mod.load(root))
      local text = require("privata._report.text").render(checker.run(root, config), root, config)
      assert.is_true(text:find("global binding") < text:find("could be made private"))
    end)
  end)

  it("prints the namespace hint once per file, not once per symbol", function()
    project.with({
      ["lua/pkg/init.lua"] = "local M = {}\nfunction M.a() end\n"
        .. "function M.b() end\nfunction M.c() end\nreturn M",
    }, function(root)
      local config = assert(config_mod.load(root))
      local text = require("privata._report.text").render(checker.run(root, config), root, config)
      local hints = select(2, text:gsub("add `local _P = {}`", ""))
      assert.equal(1, hints)
    end)
  end)
end)
