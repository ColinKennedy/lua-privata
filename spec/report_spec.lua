local config_mod = require("privata._config")
local json_report = require("privata._report.json")
local privata = require("privata")
local project = require("spec.support.project")
local text_report = require("privata._report.text")

--- Scan a project and render both reports from the same findings.
local function render(files, overrides, body)
  project.with(files, function(root)
    local config = assert(config_mod.load(root, overrides))
    local findings = assert(privata.check(root, overrides))
    body(
      text_report.render(findings, root, config),
      json_report.render(findings, root, config),
      findings
    )
  end)
end

local ROCKSPEC = [[
package = "thing"
build = { modules = { thing = "lua/thing/init.lua" } }
]]

describe("report", function()
  describe("text", function()
    it("says so plainly when a project is clean", function()
      render(
        {
          ["thing-scm-1.rockspec"] = ROCKSPEC,
          ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        },
        nil,
        function(text)
          assert.equals("No module privacy issues found.", text)
        end
      )
    end)

    it("names the readers of a reported symbol", function()
      -- Acting on this means rewriting every call site, not only the
      -- definition, so the call sites are in the report.
      render(
        {
          ["lua/pkg/init.lua"] = [[
local M = {}
function M.helper() end
function M.a() M.helper() end
function M.b() M.helper() end
return M
]],
        },
        nil,
        function(text)
          assert.matches("function `M%.helper` %-> move to `_P%.helper`", text)
          assert.matches("also read at :3, :4", text)
        end
      )
    end)

    it("renders every section", function()
      render(
        {
          ["lua/pkg/init.lua"] = "leaked = 1\nlocal M = {}\nfunction M.h() end\nreturn M",
          ["lua/pkg/broken.lua"] = "local = =",
          ["lua/pkg/odd.lua"] = "local A, B = {}, {}\nif x then return A end\nreturn B",
          ["lua/pkg/_secret.lua"] = [[
local M = {}
function M._go() end
function M.q() return M._go() end
return M
]],
          ["lua/other/reach.lua"] = [[
local secret = require("pkg._secret")
local M = {}
function M.go() return secret._go() end
return M
]],
          ["lua/pkg/exports.lua"] = "local function a() end\nreturn { a = a, b = b }",
        },
        nil,
        function(text)
          assert.matches("could not be parsed", text)
          assert.matches("module shape could not be determined", text)
          assert.matches("could be made private", text)
          assert.matches("global binding", text)
          assert.matches("private module require", text)
          assert.matches("private symbol read", text)
          assert.matches("export table issue", text)
        end
      )
    end)

    it("groups method findings by class with an n-of-m ratio", function()
      render({
        ["lua/pkg/point.lua"] = [[
local C = {}
C.__index = C
function C:a() end
function C:b() end
return C
]],
      }, { methods = true }, function(text)
        assert.matches("Found 2 public methods in 1 class", text)
        assert.matches("class `C` %(2 of 2 public methods%)", text)
        assert.matches("a:3, b:4", text)
      end)
    end)

    it("switches error to warning when a scan override is on", function()
      local files = {
        ["thing-scm-1.rockspec"] = ROCKSPEC,
        ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        ["lua/thing/broken.lua"] = "local = =",
      }
      render(files, nil, function(text)
        assert.matches("error: found 1 source file", text)
      end)
      render(files, { skip_unparsable_files = true }, function(text)
        assert.matches("warning: found 1 source file", text)
        -- The caveat survives the downgrade; the flag unblocks a scan, it does
        -- not claim the scan was complete.
        assert.matches("may be wrong", text)
      end)
    end)

    it("pluralises counts", function()
      render(
        {
          ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M",
        },
        nil,
        function(text)
          assert.matches("Found 1 public symbol that", text)
        end
      )
      render(
        {
          ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nfunction M.i() end\nreturn M",
        },
        nil,
        function(text)
          assert.matches("Found 2 public symbols that", text)
        end
      )
    end)

    it("wraps a long list of read sites", function()
      local lines = { "local M = {}", "function M.helper() end" }
      for i = 1, 40 do
        lines[#lines + 1] = string.format("function M.f%d() M.helper() end", i)
      end
      lines[#lines + 1] = "return M"
      render({ ["lua/pkg/init.lua"] = table.concat(lines, "\n") }, nil, function(text)
        for line in text:gmatch("[^\n]+") do
          assert.is_true(#line <= 100, "line too long: " .. line)
        end
      end)
    end)
  end)

  describe("json", function()
    it("emits a versioned document with every section", function()
      render(
        {
          ["lua/pkg/init.lua"] = "leaked = 1\nlocal M = {}\nfunction M.h() end\nreturn M",
        },
        nil,
        function(_, json)
          assert.matches('"version":1', json)
          assert.matches('"symbols":%[', json)
          assert.matches('"globals":%[', json)
          assert.matches('"name":"h"', json)
          assert.matches('"strategy":"namespace"', json)
        end
      )
    end)

    it("uses project-relative paths", function()
      render(
        {
          ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M",
        },
        nil,
        function(_, json)
          assert.matches('"file":"lua/pkg/init%.lua"', json)
          assert.is_nil(json:find("/tmp/"))
        end
      )
    end)

    it("emits integers without a decimal point", function()
      render(
        {
          ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M",
        },
        nil,
        function(_, json)
          assert.matches('"line":2', json)
          assert.is_nil(json:find('"line":2%.0'))
        end
      )
    end)

    it("escapes quotes, backslashes and control characters", function()
      local encode = json_report._P.encode
      -- Long strings do not process escapes, so these are the literal bytes
      -- the encoder must produce.
      assert.equals([["a\tb"]], encode("a\tb"))
      assert.equals([["say \"hi\""]], encode('say "hi"'))
      assert.equals([["back\\slash"]], encode("back\\slash"))
      -- A control character with no short escape falls back to \u.
      assert.equals([["\u0001"]], encode("\1"))
    end)

    it("encodes an empty table as an array", function()
      assert.equals("[]", json_report._P.encode({}))
    end)

    it("encodes nested objects with sorted keys", function()
      assert.equals([[{"a":1,"b":[1,2]}]], json_report._P.encode({ b = { 1, 2 }, a = 1 }))
    end)

    it("marks a downgraded condition", function()
      render({
        ["thing-scm-1.rockspec"] = ROCKSPEC,
        ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        ["lua/thing/broken.lua"] = "local = =",
      }, { skip_unparsable_files = true }, function(_, json)
        assert.matches('"downgraded":true', json)
      end)
    end)

    it("emits empty arrays rather than omitting sections", function()
      render(
        {
          ["thing-scm-1.rockspec"] = ROCKSPEC,
          ["lua/thing/init.lua"] = "local M = {}\nfunction M.run() end\nreturn M",
        },
        nil,
        function(_, json)
          assert.matches('"symbols":%[%]', json)
          assert.matches('"methods":%[%]', json)
        end
      )
    end)
  end)
end)
