local privata = require("privata")
local project = require("spec.support.project")

--- Scan a project and hand the findings to `body`.
local function scan(files, overrides, body)
  project.with(files, function(root)
    body(assert(privata.check(root, overrides)))
  end)
end

--- Every finding kind, with and without the comment on the offending line.
--
-- Each case is written twice on purpose: asserting only that the comment
-- silences something would pass even if the check had stopped working.
local function both(files_without, files_with, overrides, field, body)
  scan(files_without, overrides, function(findings)
    assert.is_true(#findings[field] > 0, field .. " was not reported without the comment")
  end)
  scan(files_with, overrides, function(findings)
    assert.same({}, findings[field])
    if body then
      body(findings)
    end
  end)
end

describe("privata: ignore", function()
  it("suppresses a public symbol", function()
    both(
      { ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end\nreturn M" },
      { ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end -- privata: ignore\nreturn M" },
      nil,
      "symbols"
    )
  end)

  it("suppresses a global binding", function()
    both(
      { ["lua/pkg/init.lua"] = "leaked = 1\nlocal M = {}\nreturn M" },
      { ["lua/pkg/init.lua"] = "leaked = 1 -- privata: ignore\nlocal M = {}\nreturn M" },
      nil,
      "globals"
    )
  end)

  it("suppresses a private module require", function()
    local secret = "local M = {}\nfunction M.go() end\nreturn M"
    local body = "\nlocal M = {}\nfunction M.g() return s.go() end\nreturn M"
    both({
      ["lua/pkg/_secret.lua"] = secret,
      ["lua/other/api.lua"] = "local s = require('pkg._secret')" .. body,
    }, {
      ["lua/pkg/_secret.lua"] = secret,
      ["lua/other/api.lua"] = "local s = require('pkg._secret') -- privata: ignore" .. body,
    }, nil, "private_module_requires")
  end)

  it("suppresses a private symbol read", function()
    local service =
      "local M = {}\nfunction M._go() end\nfunction M.q() return M._go() end\nreturn M"
    local head = "local s = require('pkg.service')\nlocal M = {}\n"
    local read = "function M.g() return s._go() end"
    both({
      ["lua/pkg/service.lua"] = service,
      ["lua/pkg/api.lua"] = head .. read .. "\nreturn M",
    }, {
      ["lua/pkg/service.lua"] = service,
      ["lua/pkg/api.lua"] = head .. read .. " -- privata: ignore\nreturn M",
    }, nil, "private_symbol_reads")
  end)

  it("suppresses an export table issue", function()
    local head = "local function a() end\nreturn {\n  a = a,\n"
    both(
      { ["lua/pkg/init.lua"] = head .. "  b = b,\n}" },
      { ["lua/pkg/init.lua"] = head .. "  b = b, -- privata: ignore\n}" },
      nil,
      "export_issues"
    )
  end)

  it("suppresses an unanalyzable module shape", function()
    both(
      { ["lua/pkg/init.lua"] = "local M = {}\nreturn M, 1" },
      { ["lua/pkg/init.lua"] = "local M = {}\nreturn M, 1 -- privata: ignore" },
      nil,
      "unanalyzable"
    )
  end)

  it("suppresses an unparsable file", function()
    -- The report goes quiet; the consequence does not. The file still
    -- contributes no references, which is the author's call to make.
    both(
      { ["lua/pkg/broken.lua"] = "local = =" },
      { ["lua/pkg/broken.lua"] = "local = = -- privata: ignore" },
      nil,
      "unparsable"
    )
  end)

  it("suppresses an exported private namespace", function()
    both(
      { ["lua/pkg/init.lua"] = "local _P = {}\nfunction _P.h() end\nreturn _P" },
      { ["lua/pkg/init.lua"] = "local _P = {}\nfunction _P.h() end\nreturn _P -- privata: ignore" },
      nil,
      "exported_namespaces"
    )
  end)

  it("suppresses a public method", function()
    local head = "local C = {}\nC.__index = C\nfunction C:scale() end"
    both(
      { ["lua/pkg/point.lua"] = head .. "\nreturn C" },
      { ["lua/pkg/point.lua"] = head .. " -- privata: ignore\nreturn C" },
      { methods = true },
      "methods"
    )
  end)

  it("is line-scoped, not file-scoped", function()
    scan(
      {
        ["lua/pkg/init.lua"] = [[
local M = {}
function M.kept() end -- privata: ignore
function M.reported() end
return M
]],
      },
      nil,
      function(findings)
        assert.equal(1, #findings.symbols)
        assert.equal("reported", findings.symbols[1].name)
      end
    )
  end)

  it("takes anything written after the marker as a reason", function()
    scan(
      {
        ["lua/pkg/init.lua"] = "local M = {}\n"
          .. "function M.h() end -- privata: ignore (the host calls this)\n"
          .. "return M",
      },
      nil,
      function(findings)
        assert.same({}, findings.symbols)
        assert.same({}, findings.stale_ignores)
      end
    )
  end)

  it("is not triggered by prose that mentions the marker", function()
    -- Documentation about this feature is written in Lua comments too. Under a
    -- plain substring match, a line explaining `-- privata: ignore` silently
    -- suppressed whatever finding landed on it -- and privata's own source has
    -- three such lines.
    scan(
      {
        ["lua/pkg/init.lua"] = "local M = {}\n"
          .. "-- `-- privata: ignore` is the answer there.\n"
          .. "function M.h() end\n"
          .. "return M",
      },
      nil,
      function(findings)
        assert.equal(1, #findings.symbols)
        assert.same({}, findings.stale_ignores)
      end
    )
  end)

  describe("when it has nothing left to suppress", function()
    it("reports a comment whose finding is gone", function()
      -- The symbol is read from another module, so there is no finding here to
      -- suppress. Left in place the comment would silently swallow the *next*
      -- finding on that line.
      scan(
        {
          ["lua/pkg/service.lua"] = "local M = {}\n"
            .. "function M.run() end -- privata: ignore\n"
            .. "return M",
          ["lua/pkg/api.lua"] = [[
local service = require("pkg.service")
local M = {}
function M.go() return service.run() end
return M
]],
        },
        nil,
        function(findings)
          assert.equal(1, #findings.stale_ignores)
          assert.equal("pkg.service", findings.stale_ignores[1].module)
          assert.equal(2, findings.stale_ignores[1].line)
          assert.is_false(findings.stale_ignores[1].bare)
        end
      )
    end)

    it("leaves a comment that is doing work alone", function()
      scan(
        {
          ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end -- privata: ignore\nreturn M",
        },
        nil,
        function(findings)
          assert.same({}, findings.symbols)
          assert.same({}, findings.stale_ignores)
        end
      )
    end)

    it("says a comment on a line of its own never suppressed anything", function()
      -- Findings are reported against the line the code is on, so a comment
      -- written above one silences nothing -- the likeliest reason an ignore
      -- looks stale, and worth saying rather than leaving to be puzzled out.
      scan(
        {
          ["lua/pkg/init.lua"] = "-- privata: ignore\nlocal M = {}\nfunction M.h() end\nreturn M",
        },
        nil,
        function(findings)
          assert.equal(1, #findings.symbols)
          assert.equal(1, #findings.stale_ignores)
          assert.is_true(findings.stale_ignores[1].bare)
        end
      )
    end)

    it("credits a check that is switched off", function()
      -- The method check is opt-in, and an ignore it would honour is doing its
      -- job whether or not this run looked. Calling it removable would be advice
      -- that breaks the moment `--methods` comes back.
      scan(
        {
          ["lua/pkg/point.lua"] = [[
local C = {}
C.__index = C
function C:scale() end -- privata: ignore
function C.new() return setmetatable({}, C) end
return C
]],
          ["lua/pkg/init.lua"] = [[
local point = require("pkg.point")
local M = {}
function M.go() return point.new() end
return M
]],
        },
        nil,
        function(findings)
          assert.same({}, findings.methods)
          assert.same({}, findings.stale_ignores)
        end
      )
    end)

    it("says nothing about a file whose shape could not be read", function()
      -- Such a file contributes no symbols at all, so its comments suppressed
      -- nothing for a reason that has nothing to do with them. They may be
      -- load-bearing the moment the shape is fixed.
      scan(
        {
          ["lua/pkg/init.lua"] = "local M = {}\nfunction M.h() end -- privata: ignore\nreturn M, 1",
        },
        nil,
        function(findings)
          assert.equal(1, #findings.unanalyzable)
          assert.same({}, findings.stale_ignores)
        end
      )
    end)

    it("says nothing about a module that exports its private namespace", function()
      -- privata suppresses that file's per-field findings itself, so an unused
      -- comment there is evidence of privata's own silence, not of staleness.
      scan(
        {
          ["lua/pkg/init.lua"] = "local _P = {}\nfunction _P.h() end -- privata: ignore\nreturn _P",
        },
        nil,
        function(findings)
          assert.equal(1, #findings.exported_namespaces)
          assert.same({}, findings.stale_ignores)
        end
      )
    end)

    it("says nothing about a file it could not parse", function()
      scan(
        {
          ["lua/pkg/broken.lua"] = "local = = -- privata: ignore",
        },
        nil,
        function(findings)
          assert.same({}, findings.unparsable)
          assert.same({}, findings.stale_ignores)
        end
      )
    end)

    it("can be switched off", function()
      scan({
        ["lua/pkg/init.lua"] = "-- privata: ignore\nlocal M = {}\nreturn M",
      }, { checks = { stale_ignores = false } }, function(findings)
        assert.same({}, findings.stale_ignores)
      end)
    end)
  end)

  it("does not need code on the line to work", function()
    -- The comment is matched against raw source, so a suppression on its own
    -- line is not silently ignored -- it just does not match any finding.
    scan(
      {
        ["lua/pkg/init.lua"] = "-- privata: ignore\nlocal M = {}\nfunction M.h() end\nreturn M",
      },
      nil,
      function(findings)
        assert.equal(1, #findings.symbols)
      end
    )
  end)
end)
