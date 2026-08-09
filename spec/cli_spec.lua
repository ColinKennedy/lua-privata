local cli = require("privata.cli")
local project = require("spec.support.project")

--- Collect what a stream is written to, so a run can be asserted on.
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

--- Run the CLI against a temporary project.
local function run(files, argv, body)
  project.with(files, function(root)
    local out, err = capture(), capture()
    local arguments = { root }
    for i = 1, #argv do
      arguments[#arguments + 1] = argv[i]
    end
    local code = cli.main(arguments, { out = out, err = err })
    body(code, out.text(), err.text(), root)
  end)
end

local CLEAN = {
  ["thing-scm-1.rockspec"] = [[
    package = "thing"
    build = { modules = { ["thing"] = "lua/thing/init.lua" } }
  ]],
  ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
}

describe("cli", function()
  describe("argument parsing", function()
    it("defaults the project root to the current directory", function()
      local root, overrides = cli._P.parse_arguments({})
      assert.equal(".", root)
      assert.same({}, overrides)
    end)

    it("reads flags", function()
      local _, overrides = cli._P.parse_arguments({ "--methods", "--skip-module-collisions" })
      assert.is_true(overrides.methods)
      assert.is_true(overrides.skip_module_collisions)
    end)

    it("reads --ignore-methods", function()
      local _, overrides = cli._P.parse_arguments({ "--ignore-methods" })
      assert.is_true(overrides.ignore_methods)
    end)

    it("accepts both spellings of unparsable", function()
      local _, a = cli._P.parse_arguments({ "--skip-unparsable-files" })
      local _, b = cli._P.parse_arguments({ "--skip-unparseable-files" })
      assert.is_true(a.skip_unparsable_files)
      assert.is_true(b.skip_unparsable_files)
    end)

    it("reads options in both spellings", function()
      local _, spaced = cli._P.parse_arguments({ "--namespace", "_Q" })
      local _, joined = cli._P.parse_arguments({ "--namespace=_Q" })
      assert.equal("_Q", spaced.namespace)
      assert.equal("_Q", joined.namespace)
    end)

    it("rejects an option with no value", function()
      local _, _, problem = cli._P.parse_arguments({ "--namespace" })
      assert.matches("needs a value", problem)
    end)

    it("rejects an unknown option", function()
      local _, _, problem = cli._P.parse_arguments({ "--nope" })
      assert.matches("unknown option", problem)
    end)

    it("rejects a second positional argument", function()
      local _, _, problem = cli._P.parse_arguments({ "a", "b" })
      assert.matches("unexpected argument", problem)
    end)
  end)

  describe("exit codes", function()
    it("returns 0 and says so when a project is clean", function()
      run(CLEAN, {}, function(code, out)
        assert.equal(0, code)
        assert.matches("No module privacy issues found", out)
      end)
    end)

    it("returns 1 when there are findings", function()
      run(
        { ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M" },
        {},
        function(code)
          assert.equal(1, code)
        end
      )
    end)

    it("returns 2 for a bad argument", function()
      local out, err = capture(), capture()
      local code = cli.main({ "--nope" }, { out = out, err = err })
      assert.equal(2, code)
      assert.matches("unknown option", err.text())
    end)

    it("returns 2 for a directory that does not exist", function()
      local out, err = capture(), capture()
      local code = cli.main({ "/nope-does-not-exist" }, { out = out, err = err })
      assert.equal(2, code)
      assert.matches("not a directory", err.text())
    end)

    it("returns 2 for an invalid config", function()
      run({ [".privata.lua"] = "return { namespace = 'not a name' }" }, {}, function(code, _, err)
        assert.equal(2, code)
        assert.matches("valid Lua identifier", err)
      end)
    end)
  end)

  describe("unreliable-scan overrides", function()
    local BAD = {
      ["thing-scm-1.rockspec"] = [[
        package = "thing"
        build = { modules = { ["thing"] = "lua/thing/init.lua" } }
      ]],
      ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
      ["lua/thing/broken.lua"] = "local = =",
    }

    it("fails on an unparsable file by default", function()
      run(BAD, {}, function(code, out)
        assert.equal(1, code)
        assert.matches("error: found 1 source file", out)
      end)
    end)

    it("downgrades it to a warning and exits 0 with the flag", function()
      run(BAD, { "--skip-unparsable-files" }, function(code, out)
        assert.equal(0, code)
        -- The caveat still prints: the flag unblocks a scan, it does not
        -- pretend the scan was complete.
        assert.matches("warning: found 1 source file", out)
        assert.matches("may be wrong", out)
      end)
    end)

    it("does not let the unparsable flag silence a collision", function()
      -- Separate switches on purpose: a collision means privata read the wrong
      -- file, which is worse than reading one file fewer.
      run({
        ["lua/pkg.lua"] = "return {}",
        ["src/pkg.lua"] = "return {}",
        [".privata.lua"] = "return { source_roots = { 'lua', 'src' } }",
      }, { "--skip-unparsable-files" }, function(code, out)
        assert.equal(1, code)
        assert.matches("error: found 1 module name", out)
      end)
    end)

    it("downgrades a collision with its own flag", function()
      run({
        ["lua/pkg.lua"] = "return {}",
        ["src/pkg.lua"] = "return {}",
        [".privata.lua"] = "return { source_roots = { 'lua', 'src' } }",
      }, { "--skip-module-collisions" }, function(code, out)
        assert.equal(0, code)
        assert.matches("warning: found 1 module name", out)
      end)
    end)
  end)

  describe("output", function()
    it("prints help and exits 0", function()
      local out = capture()
      local code = cli.main({ "--help" }, { out = out, err = capture() })
      assert.equal(0, code)
      assert.matches("usage: privata", out.text())
    end)

    it("prints the version", function()
      local out = capture()
      local code = cli.main({ "--version" }, { out = out, err = capture() })
      assert.equal(0, code)
      assert.matches("privata %d", out.text())
    end)

    it("emits json when asked", function()
      run({ ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M" }, {
        "--format",
        "json",
      }, function(code, out)
        assert.equal(1, code)
        assert.matches('"version":1', out)
        assert.matches('"name":"h"', out)
        assert.matches('"recommendation"', out)
      end)
    end)

    it("names the recommended namespace in the report", function()
      run({ ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M" }, {
        "--namespace",
        "_Q",
      }, function(_, out)
        assert.matches("move to `_Q%.h`", out)
      end)
    end)
  end)

  describe("reported paths", function()
    local fs = require("privata._fs")

    it("keeps the scanned root in the path rather than measuring from it", function()
      -- The regression: `privata lua` printed `pkg/init.lua`, a path naming no
      -- file, because it measured from the directory it was told to scan. The
      -- reader is standing where they ran it, one level above that.
      local display = cli._P.path_display("relative")
      assert.equal("lua/pkg/init.lua", display(fs.join(fs.cwd(), "lua/pkg/init.lua")))
    end)

    it("leaves a path outside the working directory as collected", function()
      local display = cli._P.path_display("relative")
      assert.equal("/elsewhere/pkg/init.lua", display("/elsewhere/pkg/init.lua"))
    end)

    it("resolves against the working directory when asked for absolute", function()
      local display = cli._P.path_display("absolute")
      assert.equal(fs.join(fs.cwd(), "lua/pkg/init.lua"), display("lua/pkg/init.lua"))
    end)

    it("prints whole paths under --paths absolute", function()
      run({ ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M" }, {
        "--paths",
        "absolute",
      }, function(_, out, _, root)
        assert.matches(root .. "/lua/pkg/init.lua:2", out, 1, true)
      end)
    end)

    it("returns 2 for an unknown path style", function()
      run(CLEAN, { "--paths", "shortest" }, function(code, _, err)
        assert.equal(2, code)
        assert.matches("paths must be", err)
      end)
    end)
  end)
end)
