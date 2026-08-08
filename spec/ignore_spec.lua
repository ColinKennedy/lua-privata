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
