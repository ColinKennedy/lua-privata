local patterns = require("privata._patterns")

--- True when the translated regex matches the whole of `text`.
local function regex_matches(source, text)
  local pattern = assert(patterns.from_regex(source), "did not translate: " .. source)
  return text:find(pattern) ~= nil
end

--- True when the translated glob matches the whole of `text`.
local function glob_matches(source, text, separator)
  local compiled = assert(patterns.from_glob(source, separator), "did not translate: " .. source)
  return patterns.any(compiled, text)
end

describe("patterns", function()
  describe("regular expressions", function()
    it("matches a whole name rather than a substring", function()
      -- tach's interfaces name a symbol outright: an `expose` of "run" that
      -- also matched "run_later" would publish names nobody declared.
      assert.is_true(regex_matches("run", "run"))
      assert.is_false(regex_matches("run", "run_later"))
      assert.is_false(regex_matches("run", "prerun"))
    end)

    it("reads `.` and `*` as a regex, not as a Lua pattern", function()
      assert.is_true(regex_matches("build_.*", "build_report"))
      assert.is_true(regex_matches("build_.*", "build_"))
      assert.is_false(regex_matches("build_.*", "rebuild_report"))
    end)

    it("escapes a dot that the config escaped", function()
      assert.is_true(regex_matches("mylib\\.api", "mylib.api"))
      assert.is_false(regex_matches("mylib\\.api", "mylibxapi"))
    end)

    it("translates the shorthand classes Lua has an equivalent of", function()
      assert.is_true(regex_matches("v\\d+", "v12"))
      assert.is_false(regex_matches("v\\d+", "vx"))
      assert.is_true(regex_matches("\\w+", "name_2"))
    end)

    it("reads a character class, negated or not", function()
      assert.is_true(regex_matches("[a-c]+", "abc"))
      assert.is_false(regex_matches("[a-c]+", "abd"))
      assert.is_true(regex_matches("[^_].*", "run"))
      assert.is_false(regex_matches("[^_].*", "_run"))
    end)

    it("accepts the anchors a regex habit adds, and changes nothing", function()
      assert.is_true(regex_matches("^run$", "run"))
      assert.is_false(regex_matches("^run$", "running"))
    end)

    it("treats a Lua pattern's own escape as a literal", function()
      -- `%` means nothing in a regex, so a config that wrote one meant the
      -- character. Passing it through unquoted would make it an escape here.
      assert.is_true(regex_matches("100%", "100%"))
      assert.is_false(regex_matches("100%", "100d"))
    end)

    it("refuses what a Lua pattern cannot express", function()
      -- Silently dropping alternation would leave a pattern that matches
      -- something else, and these patterns decide what privata calls public.
      local _, reason = patterns.from_regex("get|set")
      assert.matches("alternation", reason)

      local _, group = patterns.from_regex("(ab)+")
      assert.matches("group", group)

      local _, count = patterns.from_regex("a{2}")
      assert.matches("repetition count", count)
    end)

    it("refuses an escape it has no equivalent for", function()
      local _, reason = patterns.from_regex("\\bword")
      assert.matches("unsupported escape", reason)
    end)

    it("refuses a quantifier with nothing to repeat", function()
      local _, reason = patterns.from_regex("*run")
      assert.matches("nothing to repeat", reason)
    end)

    it("refuses an anchor in the middle, which cannot mean anything here", function()
      local _, reason = patterns.from_regex("a^b")
      assert.matches("only supported at the ends", reason)
    end)

    it("refuses an unterminated class and a trailing backslash", function()
      local _, class = patterns.from_regex("[abc")
      assert.matches("unterminated character class", class)

      local _, backslash = patterns.from_regex("run\\")
      assert.matches("ends in a backslash", backslash)
    end)

    it("translates an escape written inside a character class", function()
      assert.is_true(regex_matches("[\\d]+", "123"))
      assert.is_true(regex_matches("[\\w]+", "a_1"))
      assert.is_true(regex_matches("[\\.]+", "..."))
      assert.is_false(regex_matches("[\\.]+", "abc"))
    end)

    it("quotes a Lua escape written inside a character class", function()
      assert.is_true(regex_matches("[%$]+", "%$"))
      assert.is_false(regex_matches("[%$]+", "d"))
    end)

    it("refuses inside a class what a class cannot hold", function()
      -- A Lua class negates as a whole or not at all, so `\W` has no form
      -- there. Emitting `%W` would negate the wrong thing.
      local _, reason = patterns.from_regex("[\\W]")
      assert.matches("inside a character class", reason)

      local _, backslash = patterns.from_regex("[a\\")
      assert.matches("ends in a backslash", backslash)

      local _, unterminated = patterns.from_regex("[^abc")
      assert.matches("unterminated character class", unterminated)
    end)

    it("reads a `]` written first in a class as a literal", function()
      assert.is_true(regex_matches("[]a]+", "]a"))
    end)

    it("refuses anything that is not a string", function()
      local _, reason = patterns.from_regex(nil)
      assert.matches("must be a string", reason)
    end)
  end)

  describe("globs", function()
    it("keeps `*` inside one path segment", function()
      assert.is_true(glob_matches("lua/*.lua", "lua/init.lua"))
      assert.is_false(glob_matches("lua/*.lua", "lua/pkg/init.lua"))
    end)

    it("lets `**` span segments, including none of them", function()
      -- tach matches `tests` as well as `python/tests` for `**/tests`, so the
      -- optional half has to survive translation.
      assert.is_true(glob_matches("**/tests", "tests"))
      assert.is_true(glob_matches("**/tests", "python/tests"))
      assert.is_true(glob_matches("**/tests", "a/b/tests"))
      assert.is_false(glob_matches("**/tests", "tests/deeper"))
    end)

    it("lets a trailing `**` match the prefix itself", function()
      assert.is_true(glob_matches("build/**", "build"))
      assert.is_true(glob_matches("build/**", "build/a/b"))
      assert.is_false(glob_matches("build/**", "rebuild"))
    end)

    it("matches a single character with `?`", function()
      assert.is_true(glob_matches("v?.lua", "v1.lua"))
      assert.is_false(glob_matches("v?.lua", "v12.lua"))
    end)

    it("uses the dot as the separator for a module glob", function()
      -- A module path is dotted, so `*` has to stop at a dot the way it stops
      -- at a slash in a file path.
      local compiled = assert(patterns.from_module_glob("libs.*"))
      assert.is_true(patterns.any(compiled, "libs.one"))
      assert.is_false(patterns.any(compiled, "libs.one.two"))

      local deep = assert(patterns.from_module_glob("libs.**"))
      assert.is_true(patterns.any(deep, "libs"))
      assert.is_true(patterns.any(deep, "libs.one.two"))
    end)

    it("treats a path with no glob syntax as a literal", function()
      assert.is_true(glob_matches("lua/pkg", "lua/pkg"))
      assert.is_false(glob_matches("lua/pkg", "lua/pkgs"))
    end)

    it("lets `**` span segments away from a separator too", function()
      assert.is_true(glob_matches("lua/**.lua", "lua/pkg/init.lua"))
      assert.is_false(glob_matches("lua/**.lua", "src/pkg/init.lua"))
    end)

    it("reads a character class and a backslash escape", function()
      assert.is_true(glob_matches("v[0-9]/x", "v2/x"))
      assert.is_false(glob_matches("v[0-9]/x", "vv/x"))
      assert.is_true(glob_matches("a\\*b", "a*b"))
      assert.is_false(glob_matches("a\\*b", "axb"))
    end)

    it("refuses brace alternation, which Lua patterns have no form of", function()
      local _, reason = patterns.from_glob("{a,b}/x")
      assert.matches("brace alternation", reason)
    end)

    it("refuses a malformed glob rather than matching something else", function()
      local _, class = patterns.from_glob("v[0-9/x")
      assert.matches("unterminated character class", class)

      local _, backslash = patterns.from_glob("a\\")
      assert.matches("ends in a backslash", backslash)

      local _, control = patterns.from_glob("a\1b")
      assert.matches("control character", control)

      local _, kind = patterns.from_glob(nil)
      assert.matches("must be a string", kind)
    end)
  end)

  describe("any", function()
    it("is false for an empty pattern list", function()
      assert.is_false(patterns.any({}, "anything"))
    end)
  end)
end)
