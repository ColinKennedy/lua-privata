local project = require("spec.support.project")
local rockspec = require("privata._rockspec")
local source_roots = require("privata._source_roots")

describe("source_roots", function()
  describe("module_name", function()
    it("derives a dotted name from a path", function()
      assert.equal("foo.bar", source_roots.module_name("lua/foo/bar.lua", "lua"))
    end)

    it("treats init.lua as the package itself", function()
      -- package.path ships `?/init.lua`, which is the __init__.py analogue.
      assert.equal("foo", source_roots.module_name("lua/foo/init.lua", "lua"))
    end)

    it("names a top-level file", function()
      assert.equal("bar", source_roots.module_name("lua/bar.lua", "lua"))
    end)

    it("returns nil for a root-level init.lua, which names nothing", function()
      assert.is_nil(source_roots.module_name("lua/init.lua", "lua"))
    end)

    it("returns nil for a path outside the root", function()
      assert.is_nil(source_roots.module_name("other/bar.lua", "lua"))
    end)
  end)

  describe("package_parts", function()
    it("drops the final segment", function()
      assert.same({ "a", "b" }, source_roots.package_parts("a.b.c"))
    end)

    it("is empty for a top-level module", function()
      assert.same({}, source_roots.package_parts("a"))
    end)
  end)

  describe("test filenames", function()
    it("recognises busted and luaunit conventions", function()
      assert.is_true(source_roots.is_test_filename("thing_spec.lua"))
      assert.is_true(source_roots.is_test_filename("thing_test.lua"))
      assert.is_true(source_roots.is_test_filename("test_thing.lua"))
    end)

    it("leaves an ordinary module alone", function()
      assert.is_false(source_roots.is_test_filename("contest.lua"))
      assert.is_false(source_roots.is_test_filename("helpers.lua"))
    end)
  end)

  describe("ignored directories", function()
    it("skips build output, vendored trees and test directories", function()
      assert.is_true(source_roots._P.is_ignored_directory("lua_modules"))
      assert.is_true(source_roots._P.is_ignored_directory("spec"))
      assert.is_true(source_roots._P.is_ignored_directory("vendor"))
    end)

    it("skips hidden directories wholesale", function()
      assert.is_true(source_roots._P.is_ignored_directory(".git"))
      assert.is_false(source_roots._P.is_ignored_directory("lua"))
    end)
  end)

  describe("discover", function()
    it("prefers lua/ by convention", function()
      project.with({ ["lua/pkg/init.lua"] = "return {}" }, function(root)
        local roots, why = source_roots.discover(root, nil)
        assert.same({ root .. "/lua" }, roots)
        assert.equal("convention", why)
      end)
    end)

    it("falls back to src/", function()
      project.with({ ["src/pkg.lua"] = "return {}" }, function(root)
        local roots = source_roots.discover(root, nil)
        assert.same({ root .. "/src" }, roots)
      end)
    end)

    it("falls back to the project root", function()
      project.with({ ["pkg.lua"] = "return {}" }, function(root)
        local roots, why = source_roots.discover(root, nil)
        assert.same({ root }, roots)
        assert.equal("project root", why)
      end)
    end)

    it("lets the config override every convention", function()
      project.with({ ["lua/a.lua"] = "return {}", ["mine/b.lua"] = "return {}" }, function(root)
        local roots, why = source_roots.discover(root, { source_roots = { "mine" } })
        assert.same({ root .. "/mine" }, roots)
        assert.equal("config", why)
      end)
    end)

    it("ignores a configured root that does not exist", function()
      project.with({ ["lua/a.lua"] = "return {}" }, function(root)
        local roots, why = source_roots.discover(root, { source_roots = { "nope" } })
        assert.equal("convention", why)
        assert.same({ root .. "/lua" }, roots)
      end)
    end)

    it("prefers a rockspec's module map over the lua/ convention", function()
      -- build.modules names each module outright, which is a stronger statement
      -- of layout than any directory convention.
      project.with({
        ["thing-scm-1.rockspec"] = [[
          package = "thing"
          version = "scm-1"
          build = { type = "builtin", modules = { ["thing"] = "alt/thing.lua" } }
        ]],
        ["alt/thing.lua"] = "return {}",
        ["lua/decoy.lua"] = "return {}",
      }, function(root)
        local roots, why = source_roots.discover(root, nil)
        assert.equal("rockspec", why)
        assert.same({ root .. "/alt" }, roots)
      end)
    end)
  end)
end)

describe("rockspec", function()
  it("reads build.modules", function()
    project.with({
      ["thing-scm-1.rockspec"] = [[
        build = { modules = { ["a.b"] = "lua/a/b.lua", c = "lua/c.lua" } }
      ]],
    }, function(root)
      local modules = rockspec._P.modules(root)
      assert.equal(root .. "/lua/a/b.lua", modules["a.b"])
      assert.equal(root .. "/lua/c.lua", modules["c"])
    end)
  end)

  it("skips a C module entry", function()
    project.with({
      ["thing-scm-1.rockspec"] = [[
        build = { modules = { native = { sources = "src/native.c" } } }
      ]],
    }, function(root)
      assert.same({}, rockspec._P.modules(root))
    end)
  end)

  it("collapses nested module directories to one root", function()
    project.with({
      ["thing-scm-1.rockspec"] = [[
        build = { modules = { ["p.a"] = "lua/p/a.lua", ["p.s.b"] = "lua/p/s/b.lua" } }
      ]],
      ["lua/p/a.lua"] = "return {}",
      ["lua/p/s/b.lua"] = "return {}",
    }, function(root)
      assert.same({ root .. "/lua" }, rockspec.module_directories(root))
    end)
  end)

  it("resolves an init.lua entry to the right root", function()
    project.with({
      ["thing-scm-1.rockspec"] = [[
        build = { modules = { ["p"] = "lua/p/init.lua" } }
      ]],
      ["lua/p/init.lua"] = "return {}",
    }, function(root)
      assert.same({ root .. "/lua" }, rockspec.module_directories(root))
    end)
  end)

  it("reads installed scripts, which are public without being required", function()
    project.with({
      ["thing-scm-1.rockspec"] = [[
        build = { install = { bin = { privata = "bin/privata.lua" } } }
      ]],
    }, function(root)
      assert.same({ root .. "/bin/privata.lua" }, rockspec.installed_scripts(root))
    end)
  end)

  it("prefers the scm rockspec when several exist", function()
    project.with({
      ["thing-1.0-1.rockspec"] = 'package = "old"',
      ["thing-scm-1.rockspec"] = 'package = "dev"',
    }, function(root)
      assert.equal("dev", rockspec._P.load(root).package)
    end)
  end)

  it("returns nothing when there is no rockspec", function()
    project.with({ ["lua/a.lua"] = "return {}" }, function(root)
      assert.same({}, rockspec._P.modules(root))
      assert.same({}, rockspec.module_directories(root))
    end)
  end)
end)
