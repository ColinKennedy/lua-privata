--- privata: find Lua code that looks public but is only used privately.
--
-- This module is the entire public interface. Everything else lives under an
-- `_`-prefixed module path, which makes privata's own internals private
-- modules by privata's own rule -- so the tool enforces its layering on itself.

local checker = require("privata._checker")
local config_mod = require("privata._config")
local fs = require("privata._fs")

local M = {}

M._VERSION = "0.1.0"

--- Scan a project and return every finding.
--
-- `overrides` accepts the same keys as `.privata.lua`. Returns the findings
-- table and the effective config, or nil plus a list of problems.
function M.check(project_root, overrides)
  local root = fs.normalize(project_root or fs.cwd())
  local config, problems = config_mod.load(root, overrides)
  if not config then
    return nil, problems
  end
  return checker.run(root, config), config
end

--- Public symbols that no other production module reads.
function M.find_private_candidates(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.symbols or {}
end

--- Global bindings, which are public to the entire process.
function M.find_globals(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.globals or {}
end

--- Requires of a private module from outside its owning package.
function M.find_private_module_requires(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.private_module_requires or {}
end

--- Reads of another module's private names.
function M.find_private_symbol_reads(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.private_symbol_reads or {}
end

--- Stale or private entries in a literal export table.
function M.find_export_issues(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.export_issues or {}
end

--- Public methods no other production module refers to. Always runs the check,
--- whatever `methods` is set to, since asking for it is opting in.
function M.find_method_candidates(project_root, overrides)
  local merged = { methods = true }
  for key, value in pairs(overrides or {}) do
    merged[key] = value
  end
  local findings = M.check(project_root, merged)
  return findings and findings.methods or {}
end

--- Files privata could not parse.
function M.find_unparsable(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.unparsable or {}
end

--- Files whose module shape privata declined to guess at.
function M.find_unanalyzable(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.unanalyzable or {}
end

--- Module names produced by more than one file.
function M.find_collisions(project_root, overrides)
  local findings = M.check(project_root, overrides)
  return findings and findings.collisions or {}
end

return M
