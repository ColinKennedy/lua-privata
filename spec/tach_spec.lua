local config = require("privata._config")
local project = require("spec.support.project")
local tach = require("privata._tach")

--- Load config against a temporary project and hand the result to `body`.
local function with_config(files, overrides, body)
  project.with(files, function(root)
    local loaded, err = config.load(root, overrides)
    body(loaded, err, root)
  end)
end

--- Load a `tach.lua` holding `source` and hand the result to `body`.
local function with_tach(source, body)
  project.with({ ["tach.lua"] = source }, function(root)
    local settings, problems = tach.load(root .. "/tach.lua", { "symbols", "stale_ignores" })
    body(settings, problems)
  end)
end

describe("tach.lua", function()
  describe("reading", function()
    it("carries over the settings both tools have a use for", function()
      with_tach(
        [[return {
          source_roots = { "src" },
          exclude = { "**/generated" },
          interfaces = { { expose = { "main" }, from = { "app" } } },
          modules = { { path = "app.plugin", unchecked = true } },
        }]],
        function(settings, problems)
          assert.is_nil(problems)
          assert.same({ "src" }, settings.source_roots)
          assert.same({ "**/generated" }, settings.exclude)
          assert.same({ "main" }, settings.interfaces[1].expose)
          assert.is_true(settings.modules[1].unchecked)
        end
      )
    end)

    it("emits nothing for a key the file does not mention", function()
      -- The two tools disagree about defaults, so filling tach's in would let
      -- the mere presence of a `tach.lua` change what privata does.
      with_tach("return { source_roots = { 'src' } }", function(settings)
        assert.is_nil(settings.exclude)
        assert.is_nil(settings.interfaces)
        assert.is_nil(settings.checks)
        assert.is_nil(settings.fail_on)
      end)
    end)

    it("accepts every key tach accepts, whether or not privata reads it", function()
      -- A file that loads in tach and not here would defeat the point.
      with_tach(
        [[return {
          layers = { "ui", "core" },
          exact = true,
          ignore_type_checking_imports = true,
          include_string_imports = false,
          forbid_circular_dependencies = true,
          layers_explicit_depends_on = false,
          respect_gitignore = "if_git_repo",
          root_module = "forbid",
          cache = { file_dependencies = { "spec/**" } },
          external = { exclude = { "busted" } },
          map = { extra_dependencies = { a = { "b" } } },
          plugins = {},
          rules = { unused_external_dependencies = "error" },
        }]],
        function(settings, problems)
          assert.is_nil(problems)
          assert.same({}, settings)
        end
      )
    end)

    it("refuses a key tach would refuse", function()
      with_tach("return { source_rootz = { 'src' } }", function(settings, problems)
        assert.is_nil(settings)
        assert.matches("unknown tach setting 'source_rootz'", problems[1])
      end)
    end)

    it("names the file in every problem it reports", function()
      with_tach("return { exact = 'yes' }", function(_, problems)
        assert.matches("tach%.lua: exact must be true or false", problems[1])
      end)
    end)

    it("checks the values of the enumerated settings", function()
      with_tach("return { root_module = 'sometimes' }", function(_, problems)
        assert.matches("root_module must be", problems[1])
      end)
      with_tach("return { respect_gitignore = 'maybe' }", function(_, problems)
        assert.matches("respect_gitignore must be", problems[1])
      end)
      with_tach("return { rules = { unused_ignore_directives = 'loud' } }", function(_, problems)
        assert.matches("must be 'error', 'warn' or 'off'", problems[1])
      end)
      with_tach("return { rules = { nonsense = 'off' } }", function(_, problems)
        assert.matches("unknown rule 'nonsense'", problems[1])
      end)
    end)

    it("reports a file it cannot parse", function()
      with_tach("return { = }", function(settings, problems)
        assert.is_nil(settings)
        assert.matches("line %d+", problems[1])
      end)
    end)

    it("reports a file that is not there", function()
      local settings, problems = tach.load("nope-does-not-exist/tach.lua", {})
      assert.is_nil(settings)
      assert.matches("nope%-does%-not%-exist", problems[1])
    end)

    it("says which type each setting should have had", function()
      with_tach("return { exclude = 'build' }", function(_, problems)
        assert.matches("exclude must be a list of strings", problems[1])
      end)
      with_tach("return { cache = 'yes' }", function(_, problems)
        assert.matches("cache must be a table", problems[1])
      end)
      with_tach("return { rules = 'strict' }", function(_, problems)
        assert.matches("rules must be a table", problems[1])
      end)
    end)

    it("reads a layer as a name or as a table, and refuses the rest", function()
      with_tach("return { layers = { 'ui', { name = 'core', closed = true } } }", function(_, p)
        assert.is_nil(p)
      end)
      with_tach("return { layers = 'ui' }", function(_, problems)
        assert.matches("layers must be a list", problems[1])
      end)
      with_tach("return { layers = { { closed = true } } }", function(_, problems)
        assert.matches("need a string `name`", problems[1])
      end)
      with_tach("return { layers = { 7 } }", function(_, problems)
        assert.matches("must be strings or tables", problems[1])
      end)
    end)

    it("checks an interface table it finds in a tach file too", function()
      -- The same table means the same thing whichever file it arrived in.
      with_tach("return { interfaces = { { from = { 'pkg' } } } }", function(settings, problems)
        assert.is_nil(settings)
        assert.matches("needs an `expose` list", problems[1])
      end)
    end)
  end)

  describe("rules", function()
    it("switches the stale-ignore check off when tach turns the rule off", function()
      with_tach("return { rules = { unused_ignore_directives = 'off' } }", function(settings)
        assert.is_false(settings.checks.stale_ignores)
      end)
    end)

    it("keeps the check but stops it failing the run when tach says warn", function()
      -- `checks` cannot express "report and do not block", because switching a
      -- check off stops it printing too. `fail_on` is the setting that can.
      with_tach("return { rules = { unused_ignore_directives = 'warn' } }", function(settings)
        assert.is_nil(settings.checks)
        assert.same({ "symbols" }, settings.fail_on)
      end)
    end)

    it("leaves privata's own default alone when tach says error", function()
      with_tach("return { rules = { unused_ignore_directives = 'error' } }", function(settings)
        assert.is_nil(settings.checks)
        assert.is_nil(settings.fail_on)
      end)
    end)
  end)

  describe("layering", function()
    it("reads a tach.lua when there is no .privata.lua at all", function()
      with_config(
        {
          ["tach.lua"] = "return { source_roots = { 'src' } }",
          ["src/pkg/init.lua"] = "return {}",
        },
        nil,
        function(loaded, found)
          assert.same({ "src" }, loaded.source_roots)
          assert.matches("tach%.lua$", found)
        end
      )
    end)

    it("lets .privata.lua win on a setting both files name", function()
      with_config(
        {
          ["tach.lua"] = "return { source_roots = { 'src' } }",
          [".privata.lua"] = "return { source_roots = { 'lua' } }",
        },
        nil,
        function(loaded)
          assert.same({ "lua" }, loaded.source_roots)
        end
      )
    end)

    it("keeps a tach setting the .privata.lua is silent about", function()
      with_config(
        {
          ["tach.lua"] = "return { source_roots = { 'src' }, exclude = { 'src/gen' } }",
          [".privata.lua"] = "return { namespace = '_mine' }",
        },
        nil,
        function(loaded)
          assert.same({ "src" }, loaded.source_roots)
          assert.same({ "src/gen" }, loaded.exclude)
          assert.equal("_mine", loaded.namespace)
        end
      )
    end)

    it("replaces rather than merges a list both files name", function()
      -- The same rule every other list setting follows: a user who narrows a
      -- list means only what they wrote.
      with_config(
        {
          ["tach.lua"] = "return { interfaces = { { expose = { 'setup' } } } }",
          [".privata.lua"] = "return { interfaces = { { expose = { 'run' } } } }",
        },
        nil,
        function(loaded)
          assert.equal(1, #loaded.interfaces)
          assert.same({ "run" }, loaded.interfaces[1].expose)
        end
      )
    end)

    it("still lets the command line beat both files", function()
      with_config({
        ["tach.lua"] = "return { source_roots = { 'src' } }",
        [".privata.lua"] = "return { namespace = '_file' }",
      }, { namespace = "_cli" }, function(loaded)
        assert.equal("_cli", loaded.namespace)
      end)
    end)

    it("applies a preset underneath the tach file", function()
      with_config(
        {
          ["tach.lua"] = "return { source_roots = { 'src' } }",
          [".privata.lua"] = "return { preset = 'neovim' }",
        },
        nil,
        function(loaded)
          assert.same({ "src" }, loaded.source_roots)
          assert.same({ "vim" }, loaded.globals)
        end
      )
    end)

    it("refuses the whole run when the tach file is unusable", function()
      -- Half-reading a configuration is the failure this tool exists to argue
      -- against, and a tach file is not exempt from that.
      with_config(
        {
          ["tach.lua"] = "return { exact = 'yes' }",
          [".privata.lua"] = "return { namespace = '_mine' }",
        },
        nil,
        function(loaded, err)
          assert.is_nil(loaded)
          assert.matches("exact must be", err[1])
        end
      )
    end)
  end)
end)
