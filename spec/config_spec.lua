local config = require("privata._config")
local project = require("spec.support.project")

--- Load config against a temporary project and hand the result to `body`.
local function with_config(files, overrides, body)
  project.with(files, function(root)
    local loaded, err = config.load(root, overrides)
    body(loaded, err, root)
  end)
end

describe("config", function()
  describe("defaults", function()
    it("recommends the namespace strategy first", function()
      -- Demoting to a local is not always legal, so the strategy that always
      -- applies has to lead or the first recommendation may be unfollowable.
      local defaults = config._P.defaults()
      assert.equal("namespace", defaults.privatize[1])
      assert.equal("_P", defaults.namespace)
    end)

    it("ships only the underscore private-module pattern", function()
      assert.same({ "^_" }, config._P.defaults().private_module_patterns)
    end)

    it("leaves the method check off", function()
      assert.is_false(config._P.defaults().methods)
      assert.is_false(config._P.defaults().checks.methods)
    end)

    it("leaves both unreliable-scan overrides off", function()
      assert.is_false(config._P.defaults().skip_unparsable_files)
      assert.is_false(config._P.defaults().skip_module_collisions)
    end)
  end)

  describe("file loading", function()
    it("uses defaults when no file exists", function()
      with_config({ ["lua/pkg/init.lua"] = "return {}" }, nil, function(loaded, err)
        assert.is_nil(err)
        assert.equal("_P", loaded.namespace)
      end)
    end)

    it("reads settings from .privata.lua", function()
      with_config(
        {
          [".privata.lua"] = "return { namespace = '_private', max_locals = 20 }",
        },
        nil,
        function(loaded)
          assert.equal("_private", loaded.namespace)
          assert.equal(20, loaded.max_locals)
        end
      )
    end)

    it("replaces list settings rather than merging them", function()
      -- A user who narrows test_roots means only what they wrote; unioning the
      -- defaults back in would rescan directories they had just excluded.
      with_config({ [".privata.lua"] = "return { test_roots = { 't' } }" }, nil, function(loaded)
        assert.same({ "t" }, loaded.test_roots)
      end)
    end)

    it("merges the checks table key by key", function()
      with_config(
        {
          [".privata.lua"] = "return { checks = { globals = false } }",
        },
        nil,
        function(loaded)
          assert.is_false(loaded.checks.globals)
          assert.is_true(loaded.checks.symbols)
        end
      )
    end)

    it("finds a config file from a nested directory", function()
      project.with({
        [".privata.lua"] = "return { namespace = '_up' }",
        ["lua/pkg/init.lua"] = "return {}",
      }, function(root)
        local loaded = config.load(root .. "/lua/pkg")
        assert.equal("_up", loaded.namespace)
      end)
    end)

    it("reports a config file it cannot parse", function()
      with_config({ [".privata.lua"] = "return { = }" }, nil, function(loaded, err)
        assert.is_nil(loaded)
        assert.matches("line %d+", err[1])
      end)
    end)

    it("reports a config file that computes instead of declaring", function()
      with_config(
        {
          [".privata.lua"] = "return { source_roots = os.getenv('X') }",
        },
        nil,
        function(loaded, err)
          assert.is_nil(loaded)
          assert.is_string(err[1])
        end
      )
    end)
  end)

  describe("layering", function()
    it("lets the command line beat the file", function()
      with_config(
        { [".privata.lua"] = "return { namespace = '_file' }" },
        { namespace = "_cli" },
        function(loaded)
          assert.equal("_cli", loaded.namespace)
        end
      )
    end)

    it("applies a preset under the file", function()
      with_config(
        {
          [".privata.lua"] = "return { preset = 'neovim', namespace = '_mine' }",
        },
        nil,
        function(loaded)
          assert.same({ "lua" }, loaded.source_roots)
          assert.same({ "vim" }, loaded.globals)
          assert.equal("_mine", loaded.namespace)
        end
      )
    end)

    it("lets a preset be chosen from the command line", function()
      with_config({}, { preset = "neovim" }, function(loaded)
        assert.same({ "lua" }, loaded.source_roots)
      end)
    end)

    it("rejects an unknown preset", function()
      with_config({}, { preset = "nope" }, function(loaded, err)
        assert.is_nil(loaded)
        assert.matches("unknown preset", err[1])
      end)
    end)

    it("keeps methods and checks.methods in step", function()
      with_config({}, { methods = true }, function(loaded)
        assert.is_true(loaded.checks.methods)
      end)
      with_config(
        { [".privata.lua"] = "return { checks = { methods = true } }" },
        nil,
        function(loaded)
          assert.is_true(loaded.methods)
        end
      )
    end)
  end)

  describe("validation", function()
    it("rejects an unknown privatize strategy", function()
      with_config({ [".privata.lua"] = "return { privatize = { 'nope' } }" }, nil, function(_, err)
        assert.matches("unknown privatize strategy", err[1])
      end)
    end)

    it("rejects an empty privatize list", function()
      with_config({ [".privata.lua"] = "return { privatize = {} }" }, nil, function(_, err)
        assert.matches("at least one strategy", err[1])
      end)
    end)

    it("rejects a namespace that is not an identifier", function()
      with_config(
        { [".privata.lua"] = "return { namespace = 'not a name' }" },
        nil,
        function(_, err)
          assert.matches("valid Lua identifier", err[1])
        end
      )
    end)

    it("rejects an unknown check", function()
      with_config(
        { [".privata.lua"] = "return { checks = { nope = true } }" },
        nil,
        function(_, err)
          assert.matches("unknown check", err[1])
        end
      )
    end)

    it("rejects a non-list where a list belongs", function()
      with_config({ [".privata.lua"] = "return { test_roots = 'spec' }" }, nil, function(_, err)
        assert.matches("list of strings", err[1])
      end)
    end)

    it("rejects an invalid format", function()
      with_config({}, { format = "xml" }, function(_, err)
        assert.matches("format must be", err[1])
      end)
    end)

    it("rejects a malformed private_module_pattern", function()
      with_config(
        {
          [".privata.lua"] = "return { private_module_patterns = { '%' } }",
        },
        nil,
        function(_, err)
          assert.matches("invalid private_module_pattern", err[1])
        end
      )
    end)
  end)
end)
