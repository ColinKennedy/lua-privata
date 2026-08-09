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

local function modules_of(list)
  local out = {}
  for i = 1, #list do
    out[i] = list[i].module
  end
  table.sort(out)
  return out
end

local LEAKY = [[
local M = {}
function M.setup() end
function M.helper() end
return M
]]

describe("the declared surface", function()
  describe("interfaces", function()
    it("reports both names when nothing is declared", function()
      -- The baseline the entries below are read against: usage inside the
      -- checkout is all privata has until a project says otherwise.
      scan({ ["lua/pkg/init.lua"] = LEAKY }, nil, function(findings)
        assert.same({ "helper", "setup" }, names(findings.symbols))
      end)
    end)

    it("keeps a name an interface exposes, wherever it is defined", function()
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/pkg/other.lua"] = LEAKY,
      }, {
        interfaces = { { expose = { "setup" } } },
      }, function(findings)
        assert.same({ "helper", "helper" }, names(findings.symbols))
      end)
    end)

    it("keeps every name of a module an interface exposes wholesale", function()
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/pkg/other.lua"] = LEAKY,
      }, {
        interfaces = { { expose = { ".*" }, from = { "pkg" } } },
      }, function(findings)
        -- `pkg` is covered entirely; `pkg.other` is untouched by the entry.
        assert.same({ "helper", "setup" }, names(findings.symbols))
        assert.same({ "pkg.other", "pkg.other" }, modules_of(findings.symbols))
      end)
    end)

    it("reads `expose` as a regex rather than as a Lua pattern", function()
      scan({
        ["lua/pkg/init.lua"] = [[
local M = {}
function M.build_report() end
function M.build_graph() end
function M.helper() end
return M
]],
      }, {
        interfaces = { { expose = { "build_.*" } } },
      }, function(findings)
        assert.same({ "helper" }, names(findings.symbols))
      end)
    end)

    it("refuses a pattern it cannot honour rather than scanning differently", function()
      project.with(
        { [".privata.lua"] = "return { interfaces = { { expose = { 'a|b' } } } }" },
        function(root)
          local findings, problems = privata.check(root)
          assert.is_nil(findings)
          assert.matches("alternation", problems[1])
        end
      )
    end)
  end)

  describe("unchecked modules", function()
    it("reports nothing inside one", function()
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/pkg/plugin.lua"] = "leaked = 1\n" .. LEAKY,
      }, {
        modules = { { path = "pkg.plugin", unchecked = true } },
      }, function(findings)
        assert.same({ "pkg", "pkg" }, modules_of(findings.symbols))
        assert.same({}, modules_of(findings.globals))
      end)
    end)

    it("still lets it certify the names it reads elsewhere", function()
      -- Dropping the file from the scan outright would turn what it requires
      -- into findings that are not real -- the failure unparsable files cause.
      scan({
        ["lua/pkg/service.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        ["lua/pkg/plugin.lua"] = 'local s = require("pkg.service")\nreturn s.run()',
      }, {
        modules = { { path = "pkg.plugin", unchecked = true } },
      }, function(findings)
        assert.same({}, names(findings.symbols))
      end)
    end)

    it("still reports another module reaching into it", function()
      -- `unchecked` says "do not report this file", not "this file's privacy is
      -- nobody's business". The finding belongs to the reader either way: it is
      -- the reader's line that is printed and the reader that has to change.
      local files = {
        ["lua/pkg/_private.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        ["lua/other/reader.lua"] = 'local p = require("pkg._private")\nreturn p.run()',
      }

      scan(files, {
        modules = { { path = "pkg._private", unchecked = true } },
      }, function(findings)
        assert.equal(1, #findings.private_module_requires)
        assert.equal("other.reader", findings.private_module_requires[1].required_by)
      end)

      -- And it goes away when the file that has to change is the exempt one.
      scan(files, {
        modules = { { path = "other.reader", unchecked = true } },
      }, function(findings)
        assert.same({}, findings.private_module_requires)
      end)
    end)

    it("matches a glob over the module path", function()
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/plugin/one.lua"] = LEAKY,
        ["lua/plugin/deep/two.lua"] = LEAKY,
      }, {
        modules = { { path = "plugin.**", unchecked = true } },
      }, function(findings)
        assert.same({ "pkg", "pkg" }, modules_of(findings.symbols))
      end)
    end)
  end)

  describe("exclude", function()
    it("still reads a plain directory name as a directory", function()
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/pkg/generated/thing.lua"] = LEAKY,
      }, { exclude = { "lua/pkg/generated" } }, function(findings)
        assert.same({ "pkg", "pkg" }, modules_of(findings.symbols))
      end)
    end)

    it("reads an entry holding a glob the way tach does", function()
      -- `**/generated` names a directory wherever it sits, not one directory
      -- whose name is two asterisks.
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/pkg/generated/thing.lua"] = LEAKY,
        ["lua/other/generated/thing.lua"] = LEAKY,
      }, { exclude = { "**/generated" } }, function(findings)
        assert.same({ "pkg", "pkg" }, modules_of(findings.symbols))
      end)
    end)

    it("excludes a file a glob names outright", function()
      scan({
        ["lua/pkg/init.lua"] = LEAKY,
        ["lua/pkg/thing.lua"] = LEAKY,
      }, { exclude = { "lua/pkg/*.lua" } }, function(findings)
        -- `lua/pkg/init.lua` matches too, so the scan finds nothing at all.
        assert.same({}, names(findings.symbols))
      end)
    end)
  end)
end)
