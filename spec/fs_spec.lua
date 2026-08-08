local fs = require("privata._fs")
local project = require("spec.support.project")

describe("fs", function()
  describe("normalize", function()
    it("collapses redundant segments and separators", function()
      assert.equal("a/c", fs.normalize("a/./b/../c/"))
      assert.equal("a/b", fs.normalize("a//b"))
      assert.equal("a/b", fs.normalize("a\\b"))
    end)

    it("keeps a leading slash", function()
      assert.equal("/a/b", fs.normalize("/a/./b"))
    end)

    it("keeps leading .. it cannot resolve", function()
      assert.equal("../a", fs.normalize("../a"))
    end)

    it("reduces an empty path to .", function()
      assert.equal(".", fs.normalize("./"))
    end)
  end)

  describe("relative", function()
    it("strips the root prefix", function()
      assert.equal("privata/_fs.lua", fs.relative("lua/privata/_fs.lua", "lua"))
    end)

    it("treats a . root as containing every relative path", function()
      -- Scans are routinely rooted at the current directory, and "spec/x.lua"
      -- does not begin with "./", so prefix matching alone gets this wrong.
      assert.equal("spec/x.lua", fs.relative("spec/x.lua", "."))
    end)

    it("returns nil for an absolute path under a . root", function()
      assert.is_nil(fs.relative("/etc/x", "."))
    end)

    it("returns nil when the path is outside the root", function()
      assert.is_nil(fs.relative("spec/x.lua", "lua"))
    end)

    it("returns . for the root itself", function()
      assert.equal(".", fs.relative("lua", "lua"))
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
      assert.equal("_fs.lua", fs.basename("lua/privata/_fs.lua"))
      assert.equal("lua/privata", fs.dirname("lua/privata/_fs.lua"))
    end)

    it("handles a bare name", function()
      assert.equal("x.lua", fs.basename("x.lua"))
      assert.equal(".", fs.dirname("x.lua"))
    end)
  end)

  describe("join", function()
    it("joins without doubling separators", function()
      assert.equal("a/b/c", fs.join("a/", "b", "c"))
    end)

    it("ignores empty parts", function()
      assert.equal("a/b", fs.join("a", "", "b"))
    end)
  end)

  describe("listing", function()
    it("finds lua files under a root, sorted", function()
      local files = fs.list_lua_files("lua")
      assert.is_true(#files >= 4)
      for i = 2, #files do
        assert.is_true(files[i - 1] < files[i])
      end
      assert.equal("lua/privata/_ast.lua", files[1])
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
      project.with({ ["src/notes.md"] = "hello" }, function(root)
        local dir = fs.join(root, "src")
        local file = fs.join(dir, "notes.md")
        assert.is_true(fs.is_dir(dir))
        assert.is_false(fs.is_dir(file))
        assert.is_true(fs.is_file(file))
        assert.is_false(fs.is_file(dir))
      end)
    end)

    it("reports a missing path as neither", function()
      assert.is_false(fs.is_dir("nope-does-not-exist"))
      assert.is_false(fs.is_file("nope-does-not-exist"))
    end)
  end)

  describe("read_file", function()
    it("reads content", function()
      project.with({ ["notes.md"] = "privata reads this" }, function(root)
        assert.equal("privata reads this", fs.read_file(fs.join(root, "notes.md")))
      end)
    end)

    it("returns nil and a message for a missing file", function()
      local content, err = fs.read_file("nope-does-not-exist")
      assert.is_nil(content)
      assert.is_string(err)
    end)
  end)
end)
