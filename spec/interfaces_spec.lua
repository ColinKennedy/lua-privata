local interfaces = require("privata._interfaces")

describe("interfaces", function()
  describe("exposes", function()
    it("publishes one name from every module when no `from` is given", function()
      -- tach defaults `from` to every module, which is the shape a name the
      -- host calls takes: `setup` is public wherever the plugin defines it.
      local surface = interfaces.compile({ interfaces = { { expose = { "setup" } } } })
      assert.is_true(interfaces.exposes(surface, "pkg", "setup"))
      assert.is_true(interfaces.exposes(surface, "pkg.deep", "setup"))
      assert.is_false(interfaces.exposes(surface, "pkg", "helper"))
    end)

    it("publishes every name of one module when `expose` is a catch-all", function()
      local surface = interfaces.compile({
        interfaces = { { expose = { ".*" }, from = { "pkg\\.api" } } },
      })
      assert.is_true(interfaces.exposes(surface, "pkg.api", "anything"))
      assert.is_true(interfaces.exposes(surface, "pkg.api", "something_else"))
      assert.is_false(interfaces.exposes(surface, "pkg.internal", "anything"))
    end)

    it("needs one entry to match both halves", function()
      -- Two entries that each match half say nothing together: the first
      -- publishes `setup` from `other`, the second publishes `run` from `pkg`.
      local surface = interfaces.compile({
        interfaces = {
          { expose = { "setup" }, from = { "other" } },
          { expose = { "run" }, from = { "pkg" } },
        },
      })
      assert.is_false(interfaces.exposes(surface, "pkg", "setup"))
      assert.is_true(interfaces.exposes(surface, "pkg", "run"))
    end)

    it("matches `from` as a regex over the dotted module name", function()
      local surface = interfaces.compile({
        interfaces = { { expose = { ".*" }, from = { ".*\\.health" } } },
      })
      assert.is_true(interfaces.exposes(surface, "plugin.health", "check"))
      assert.is_false(interfaces.exposes(surface, "health", "check"))
    end)

    it("is false when nothing is declared", function()
      local surface = interfaces.compile({})
      assert.is_false(interfaces.exposes(surface, "pkg", "setup"))
    end)
  end)

  describe("is_unchecked", function()
    it("matches a module path as a glob", function()
      local surface = interfaces.compile({
        modules = { { path = "plugin.**", unchecked = true } },
      })
      assert.is_true(interfaces.is_unchecked(surface, "plugin"))
      assert.is_true(interfaces.is_unchecked(surface, "plugin.deep.thing"))
      assert.is_false(interfaces.is_unchecked(surface, "plugins"))
    end)

    it("reads the `paths` shorthand as several declarations", function()
      local surface = interfaces.compile({
        modules = { { paths = { "a.one", "a.two" }, unchecked = true } },
      })
      assert.is_true(interfaces.is_unchecked(surface, "a.one"))
      assert.is_true(interfaces.is_unchecked(surface, "a.two"))
      assert.is_false(interfaces.is_unchecked(surface, "a.three"))
    end)

    it("is false for a module declared without `unchecked`", function()
      -- A `[[modules]]` entry is mostly about imports, which privata does not
      -- check. Declaring one must not quietly exempt it from everything else.
      local surface = interfaces.compile({
        modules = { { path = "pkg", depends_on = { "other" } } },
      })
      assert.is_false(interfaces.is_unchecked(surface, "pkg"))
    end)
  end)

  describe("problems", function()
    it("accepts the whole tach entry shape, not just what privata reads", function()
      -- A table that loads in tach and not here would defeat the point of
      -- sharing the vocabulary at all.
      local problems = interfaces.problems({
        interfaces = {
          {
            expose = { "main" },
            from = { "pkg" },
            visibility = { "other" },
            data_types = "primitive",
            exclusive = true,
          },
        },
        modules = {
          {
            path = "pkg",
            depends_on = { "other", { path = "third", deprecated = true } },
            cannot_depend_on = { "fourth" },
            depends_on_external = { "lpeg" },
            cannot_depend_on_external = { "socket" },
            layer = "core",
            visibility = { "other" },
            utility = true,
            unchecked = false,
          },
        },
      })
      assert.same({}, problems)
    end)

    it("requires an interface to expose something", function()
      local problems = interfaces.problems({ interfaces = { { from = { "pkg" } } } })
      assert.matches("needs an `expose` list", problems[1])
    end)

    it("requires a module entry to name a path", function()
      local problems = interfaces.problems({ modules = { { unchecked = true } } })
      assert.matches("needs a `path` or `paths`", problems[1])
    end)

    it("refuses a key neither tool would recognise", function()
      -- tach refuses an unknown field outright, and for the reason both tools
      -- exist: a misspelled key is a rule that silently does not apply.
      local problems = interfaces.problems({ interfaces = { { expose = { "a" }, expse = {} } } })
      assert.matches("unknown setting 'expse'", problems[1])
    end)

    it("reports a pattern that cannot be honoured", function()
      local problems = interfaces.problems({ interfaces = { { expose = { "get|set" } } } })
      assert.matches("alternation", problems[1])
    end)

    it("reports a `data_types` outside the two tach allows", function()
      local problems =
        interfaces.problems({ interfaces = { { expose = { "a" }, data_types = "nope" } } })
      assert.matches("'all' or 'primitive'", problems[1])
    end)

    it("reports every problem rather than the first", function()
      local problems = interfaces.problems({
        interfaces = { { expose = "main" }, { from = { "pkg" } } },
      })
      assert.is_true(#problems >= 2)
    end)

    --- The one problem `interfaces.problems` reports for `entries`.
    local function problem(entries)
      local problems = interfaces.problems(entries)
      assert.equal(1, #problems, table.concat(problems, "; "))
      return problems[1]
    end

    it("says which type each field should have had", function()
      assert.matches(
        "must be true or false",
        problem({ interfaces = { { expose = { "a" }, exclusive = "yes" } } })
      )
      assert.matches(
        "must be a list of strings",
        problem({ interfaces = { { expose = { "a" }, visibility = "other" } } })
      )
      assert.matches("must be a list of patterns", problem({ interfaces = { { expose = "a" } } }))
      assert.matches("must be a string", problem({ modules = { { path = "a", layer = {} } } }))
      assert.matches("must be a module path", problem({ modules = { { path = 7 } } }))
      assert.matches("must be a list of module paths", problem({ modules = { { paths = "a" } } }))
    end)

    it("says which entries were not tables at all", function()
      assert.matches("must be a list of tables", problem({ interfaces = { key = "value" } }))
      assert.matches("interfaces%[1%] must be a table", problem({ interfaces = { "expose" } }))
    end)

    it("checks a dependency list without pretending to read it", function()
      assert.matches("must be a list", problem({ modules = { { path = "a", depends_on = "b" } } }))
      assert.matches(
        "need a string `path`",
        problem({ modules = { { path = "a", depends_on = { { deprecated = true } } } } })
      )
      assert.matches(
        "must be strings or tables",
        problem({ modules = { { path = "a", cannot_depend_on = { 7 } } } })
      )
    end)

    it("reports a module glob it cannot honour", function()
      assert.matches("brace alternation", problem({ modules = { { paths = { "{a,b}.c" } } } }))
    end)
  end)
end)
