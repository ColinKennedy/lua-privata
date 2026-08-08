local privata = require("privata")
local project = require("spec.support.project")

local function scan(files, overrides, body)
  project.with(files, function(root)
    body(assert(privata.check(root, overrides)))
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

describe("references written as strings", function()
  describe("require'mod'.name inside a string", function()
    it("counts as a reference from another module", function()
      scan(
        {
          ["lua/ex/a.lua"] = [[
local M = {}
function M.callback() return 1 end
function M.other() return 2 end
return M
]],
          ["lua/ex/b.lua"] = [[
local M = {}
local S = "v:lua.require'ex.a'.callback()"
function M.go() return S end
return M
]],
        },
        nil,
        function(findings)
          -- `other` is genuinely unused; `callback` is reached through the string.
          assert.same({ "go", "other" }, names(findings.symbols))
        end
      )
    end)

    it("counts even when the string sits in the module it names", function()
      -- This is the normal shape: the option assignment sits beside the
      -- function it points at. Treating it as a self-reference would drop every
      -- real case, since a module reading itself is exactly what gets ignored.
      scan(
        {
          ["lua/ex/folds.lua"] = [[
local M = {}
local EXPR = "v:lua.require'ex.folds'.foldexpr(v:lnum)"
function M.foldexpr() return 0 end
vim.wo.foldexpr = EXPR
return M
]],
        },
        nil,
        function(findings)
          assert.same({}, names(findings.symbols))
        end
      )
    end)

    it("reads the parenthesised and double-quoted spellings too", function()
      scan(
        {
          ["lua/ex/a.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
          ["lua/ex/b.lua"] = [[
local M = {}
M.E = 'v:lua.require("ex.a").run()'
return M
]],
        },
        nil,
        function(findings)
          assert.same({ "E" }, names(findings.symbols))
        end
      )
    end)

    it("does not treat a field access as a string mention", function()
      -- The parser stores `a.b` field names as String nodes; only literals the
      -- author actually wrote may count.
      scan(
        {
          ["lua/ex/a.lua"] = "local M = {}\nfunction M.solo() end\n"
            .. "function M.run() M.solo() end\nreturn M",
        },
        nil,
        function(findings)
          for i = 1, #findings.symbols do
            assert.is_nil(findings.symbols[i].string_mention)
          end
        end
      )
    end)
  end)

  describe("bare-name mentions", function()
    it("annotates the finding rather than suppressing it", function()
      -- A name reached through a dispatch table appears only as a bare string,
      -- which privata cannot tell from a coincidence -- so it reports what it
      -- saw instead of recommending a rename that breaks at runtime.
      scan(
        {
          ["lua/ex/a.lua"] = "local M = {}\nfunction M.handler() end\nreturn M",
          ["lua/ex/b.lua"] = 'local M = {}\nM.dispatch = { "handler" }\nreturn M',
        },
        nil,
        function(findings)
          local handler = nil
          for i = 1, #findings.symbols do
            if findings.symbols[i].name == "handler" then
              handler = findings.symbols[i]
            end
          end
          assert.is_table(handler, "handler should still be reported")
          assert.is_table(handler.string_mention)
          assert.matches("b%.lua", handler.string_mention.path)
        end
      )
    end)
  end)

  describe("v:lua globals", function()
    it("does not report a global the host reaches by name", function()
      scan(
        {
          ["lua/ex/winbar.lua"] = [[
local _P = {}
function _P.get_winbar() return "" end
_G.get_winbar = function() return _P.get_winbar() end
local M = {}
M.EXPRESSION = "%{%v:lua.get_winbar()%}"
return M
]],
        },
        nil,
        function(findings)
          assert.same({}, names(findings.globals))
        end
      )
    end)

    it("still reports a global nothing reaches", function()
      scan(
        {
          ["lua/ex/a.lua"] = "leaked = 1\nlocal M = {}\nreturn M",
        },
        nil,
        function(findings)
          assert.same({ "leaked" }, names(findings.globals))
        end
      )
    end)

    it("marks an explicit _G declaration differently from a missing local", function()
      scan(
        {
          ["lua/ex/a.lua"] = "_G.declared = 1\nfunction accidental() end\nlocal M = {}\nreturn M",
        },
        nil,
        function(findings)
          local by_name = {}
          for i = 1, #findings.globals do
            by_name[findings.globals[i].name] = findings.globals[i]
          end
          assert.is_true(by_name.declared.explicit)
          assert.is_false(by_name.accidental.explicit)
        end
      )
    end)
  end)
end)

describe("test-aware strategy selection", function()
  it("recommends a reachable field when a spec reads the symbol", function()
    -- Test usage still does not make it public. It does decide which
    -- privatisation is legal: the spec holds the module table and nothing else.
    scan(
      {
        ["lua/ex/a.lua"] = "local M = {}\nfunction M.parse() end\n"
          .. "function M.run() M.parse() end\nreturn M",
        ["spec/a_spec.lua"] = 'local a = require("ex.a")\n'
          .. 'describe("x", function() it("y", function() a.parse() end) end)',
      },
      nil,
      function(findings)
        local parse = nil
        for i = 1, #findings.symbols do
          if findings.symbols[i].name == "parse" then
            parse = findings.symbols[i]
          end
        end
        assert.equal("underscore_field", parse.recommendation.strategy)
        assert.matches("rename to `M%._parse`", parse.recommendation.text)
        assert.matches("keep it on the table", parse.recommendation.notes[1])
      end
    )
  end)

  it("leaves the namespace strategy for symbols no spec touches", function()
    scan(
      {
        ["lua/ex/a.lua"] = "local M = {}\nfunction M.untested() end\nreturn M",
      },
      nil,
      function(findings)
        assert.equal("namespace", findings.symbols[1].recommendation.strategy)
      end
    )
  end)

  it("calls out a monkeypatch seam separately from a read", function()
    -- Privatising a stubbed field deletes the injection point, so the spec has
    -- to change too. Saying only "rename it" would hide that.
    scan(
      {
        ["lua/ex/a.lua"] = "local M = {}\nfunction M.refresh() end\nreturn M",
        ["spec/a_spec.lua"] = 'local a = require("ex.a")\na.refresh = function() end',
      },
      nil,
      function(findings)
        local note = findings.symbols[1].recommendation.notes[1]
        assert.matches("injection seam", note)
        assert.matches("spec updated too", note)
      end
    )
  end)

  it("does not let a spec make the symbol public", function()
    -- The policy is unchanged: only the recommended strategy moves.
    scan(
      {
        ["lua/ex/a.lua"] = "local M = {}\nfunction M.parse() end\nreturn M",
        ["spec/a_spec.lua"] = 'local a = require("ex.a")\na.parse()',
      },
      nil,
      function(findings)
        assert.same({ "parse" }, names(findings.symbols))
      end
    )
  end)
end)

describe("exported namespace advice", function()
  it("does not tell an unconsumed module to publish an interface", function()
    scan(
      {
        ["lua/ex/sidefx.lua"] = "local _P = {}\nfunction _P.helper() end\n_P.helper()\nreturn _P",
      },
      nil,
      function(findings)
        local entry = findings.exported_namespaces[1]
        assert.is_false(entry.consumed)
      end
    )
  end)

  it("keeps the rename advice when production really reads it", function()
    scan(
      {
        ["lua/ex/sidefx.lua"] = "local _P = {}\nfunction _P.helper() end\nreturn _P",
        ["lua/ex/user.lua"] = [[
local s = require("ex.sidefx")
local M = {}
function M.go() return s.helper() end
return M
]],
      },
      nil,
      function(findings)
        assert.is_true(findings.exported_namespaces[1].consumed)
      end
    )
  end)

  it("names the spec that holds it, when one does", function()
    scan(
      {
        ["lua/ex/sidefx.lua"] = "local _P = {}\nfunction _P.helper() end\nreturn _P",
        ["spec/sidefx_spec.lua"] = 'local s = require("ex.sidefx")\ns.helper()',
      },
      nil,
      function(findings)
        assert.is_table(findings.exported_namespaces[1].test_handle)
      end
    )
  end)

  it("offers a narrowing that neither obvious remedy gives", function()
    -- A spec holds the table and production does not. "Return nothing" breaks
    -- the spec and "rename to `M`" publishes every field, so the only advice
    -- that narrows is naming the seam: one field instead of all of them.
    local config = require("privata._config")
    local checker = require("privata._checker")
    local text = require("privata._report.text")
    project.with({
      ["lua/ex/sidefx.lua"] = "local _P = {}\nfunction _P.a() end\nfunction _P.b() end\nreturn _P",
      ["spec/sidefx_spec.lua"] = 'local s = require("ex.sidefx")\ns.a()',
    }, function(root)
      local settings = assert(config.load(root))
      local report = text.render(checker.run(root, settings), root, settings)
      assert.matches("held by spec/sidefx_spec.lua:2", report, 1, true)
      assert.matches("local M = {}; M._P = _P; return M", report, 1, true)
      assert.is_nil(report:find("return nothing", 1, true))
    end)
  end)

  it("still says `return nothing` when not even a spec holds it", function()
    local config = require("privata._config")
    local checker = require("privata._checker")
    local text = require("privata._report.text")
    project.with({
      ["lua/ex/sidefx.lua"] = "local _P = {}\nfunction _P.a() end\n_P.a()\nreturn _P",
    }, function(root)
      local settings = assert(config.load(root))
      local report = text.render(checker.run(root, settings), root, settings)
      assert.matches("return nothing", report, 1, true)
    end)
  end)
end)

describe("checks.exported_namespaces", function()
  it("can be switched off without switching off the symbol check", function()
    -- The analysis still runs -- it is what keeps the symbol check quiet about
    -- the offending file -- but the section stops being reported.
    project.with({
      ["lua/ex/sidefx.lua"] = "local _P = {}\nfunction _P.a() end\nreturn _P",
      ["lua/ex/other.lua"] = "local M = {}\nfunction M.h() end\n"
        .. "function M.g() return M.h() end\nreturn M",
    }, function(root)
      local on = assert(privata.check(root))
      assert.equal(1, #on.exported_namespaces)

      local off = assert(privata.check(root, { checks = { exported_namespaces = false } }))
      assert.same({}, off.exported_namespaces)
      -- The offending file is still excluded from the symbol list, so turning
      -- the report off must not resurrect its symbols.
      for i = 1, #off.symbols do
        assert.is_nil(off.symbols[i].path:find("sidefx", 1, true))
      end
    end)
  end)
end)
