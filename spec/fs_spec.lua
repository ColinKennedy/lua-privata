local fs = require("privata._fs")

describe("fs", function()
  describe("normalize", function()
    it("collapses redundant segments and separators", function()
      assert.equals("a/c", fs.normalize("a/./b/../c/"))
      assert.equals("a/b", fs.normalize("a//b"))
      assert.equals("a/b", fs.normalize("a\\b"))
    end)

    it("keeps a leading slash", function()
      assert.equals("/a/b", fs.normalize("/a/./b"))
    end)

    it("keeps leading .. it cannot resolve", function()
      assert.equals("../a", fs.normalize("../a"))
    end)

    it("reduces an empty path to .", function()
      assert.equals(".", fs.normalize("./"))
    end)
  end)

  describe("relative", function()
    it("strips the root prefix", function()
      assert.equals("privata/_fs.lua", fs.relative("lua/privata/_fs.lua", "lua"))
    end)

    it("treats a . root as containing every relative path", function()
      -- Scans are routinely rooted at the current directory, and "spec/x.lua"
      -- does not begin with "./", so prefix matching alone gets this wrong.
      assert.equals("spec/x.lua", fs.relative("spec/x.lua", "."))
    end)

    it("returns nil for an absolute path under a . root", function()
      assert.is_nil(fs.relative("/etc/x", "."))
    end)

    it("returns nil when the path is outside the root", function()
      assert.is_nil(fs.relative("spec/x.lua", "lua"))
    end)

    it("returns . for the root itself", function()
      assert.equals(".", fs.relative("lua", "lua"))
    end)
  end)

  describe("is_within", function()
    it("compares whole segments", function()
      assert.is_true(fs.is_within("lua/privata", "lua"))
      assert.is_false(fs.is_within("luax/privata", "lua"))
    end)
  end)

  describe("basename and dirname", function()
    it("splits a path", function()
      assert.equals("_fs.lua", fs.basename("lua/privata/_fs.lua"))
      assert.equals("lua/privata", fs.dirname("lua/privata/_fs.lua"))
    end)

    it("handles a bare name", function()
      assert.equals("x.lua", fs.basename("x.lua"))
      assert.equals(".", fs.dirname("x.lua"))
    end)
  end)

  describe("join", function()
    it("joins without doubling separators", function()
      assert.equals("a/b/c", fs.join("a/", "b", "c"))
    end)

    it("ignores empty parts", function()
      assert.equals("a/b", fs.join("a", "", "b"))
    end)
  end)

  describe("listing", function()
    it("finds lua files under a root, sorted", function()
      local files = fs.list_lua_files("lua")
      assert.is_true(#files >= 4)
      for i = 2, #files do
        assert.is_true(files[i - 1] < files[i])
      end
      assert.equals("lua/privata/_ast.lua", files[1])
    end)

    it("prunes a directory by name before descending", function()
      local files = fs.list_lua_files(".", function(name)
        return name == "spec"
      end)
      for _, path in ipairs(files) do
        assert.is_false(path:find("^spec/") ~= nil)
      end
    end)

    it("prunes by relative path, not only by name", function()
      local files = fs.list_lua_files(".", function(_, relative)
        return relative == "lua/privata"
      end)
      for _, path in ipairs(files) do
        assert.is_false(path:find("^lua/privata/") ~= nil)
      end
    end)

    it("returns nothing for a path that is not a directory", function()
      assert.same({}, fs.list_lua_files("nope-does-not-exist"))
    end)
  end)

  describe("stat", function()
    it("tells directories from files", function()
      assert.is_true(fs.is_dir("lua"))
      assert.is_false(fs.is_dir("PLAN.md"))
      assert.is_true(fs.is_file("PLAN.md"))
      assert.is_false(fs.is_file("lua"))
    end)

    it("reports a missing path as neither", function()
      assert.is_false(fs.is_dir("nope-does-not-exist"))
      assert.is_false(fs.is_file("nope-does-not-exist"))
    end)
  end)

  describe("read_file", function()
    it("reads content", function()
      assert.matches("privata", fs.read_file("PLAN.md"))
    end)

    it("returns nil and a message for a missing file", function()
      local content, err = fs.read_file("nope-does-not-exist")
      assert.is_nil(content)
      assert.is_string(err)
    end)
  end)
end)
