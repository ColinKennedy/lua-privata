--- Run every check once and hand back one set of findings.
--
-- One scan, one parse per file, layered strictly bottom-up. The order below is
-- the order the report prints in, and it leads with the two conditions that
-- make everything after them untrustworthy.

local exports = require("privata._exports")
local models = require("privata._models")
local modules_mod = require("privata._modules")
local recommend = require("privata._recommend")
local requires = require("privata._requires")
local rockspec = require("privata._rockspec")
local source_roots = require("privata._source_roots")

local M = {}
local _P = {}

--- Symbols kept public by something outside the module graph.
--
-- A script in `build.install.bin` runs from a shell and a Neovim `setup`
-- function is called by the host, so neither is reachable through any
-- `require` privata can see. Treating them as unused would report the one
-- symbol in the project that definitely is used.
function _P.external_interface(project_root, config, modules)
  local kept = {}

  local function keep_all(record, name)
    for index = 1, #record.symbols do
      kept[name .. "\0" .. record.symbols[index].name] = true
    end
  end

  local scripts = rockspec.installed_scripts(project_root)
  for i = 1, #scripts do
    for name, record in pairs(modules) do
      if record.path == scripts[i] then
        keep_all(record, name)
      end
    end
  end

  -- The rock's namesake module is what consumers require; nothing inside the
  -- project has to reach it for its interface to be real.
  local api_modules = rockspec.api_module_names(project_root)
  for i = 1, #api_modules do
    local record = modules[api_modules[i]]
    if record then
      keep_all(record, api_modules[i])
    end
  end

  for i = 1, #(config.entrypoint_names or {}) do
    local entry_name = config.entrypoint_names[i]
    for name, record in pairs(modules) do
      for index = 1, #record.symbols do
        if record.symbols[index].name == entry_name then
          kept[name .. "\0" .. entry_name] = true
        end
      end
    end
  end

  for i = 1, #(config.entrypoint_modules or {}) do
    local pattern = "^" .. config.entrypoint_modules[i]:gsub("%.", "%%."):gsub("%*", ".*") .. "$"
    for name, record in pairs(modules) do
      if name:find(pattern) then
        for index = 1, #record.symbols do
          kept[name .. "\0" .. record.symbols[index].name] = true
        end
      end
    end
  end

  return kept
end

--- Names that co-located test files certify for helper modules in a test root.
--
-- A helper module living inside a declared test root exists to serve its own
-- suite, so a name those tests read is used. Attribution is scoped per root, so
-- a test file can never certify a production symbol.
function _P.test_helper_references(test_roots, modules, consumers)
  local used = {}

  for i = 1, #test_roots do
    local root = test_roots[i]
    local helpers = {}
    for name, record in pairs(modules) do
      if record.source_root == root then
        helpers[name] = record
      end
    end
    if next(helpers) ~= nil then
      local local_consumers = {}
      for index = 1, #consumers do
        if consumers[index].source_root == root then
          local_consumers[#local_consumers + 1] = consumers[index]
        end
      end
      local found = requires.cross_references_from(helpers, local_consumers)
      for key in pairs(found) do
        used[key] = true
      end
    end
  end

  return used
end

function _P.global_findings(modules, config)
  local allowed = {}
  for i = 1, #(config.globals or {}) do
    allowed[config.globals[i]] = true
  end

  local findings = {}
  for name, record in pairs(modules) do
    if record.scope then
      for i = 1, #record.scope.assigned do
        local entry = record.scope.assigned[i]
        if not allowed[entry.name] and not record.ignored_lines[entry.line] then
          findings[#findings + 1] = {
            name = entry.name,
            kind = entry.kind,
            module = name,
            path = record.path,
            line = entry.line,
          }
        end
      end
    end
  end
  return models.sort_findings(findings)
end

function _P.symbol_findings(modules, config, cross, external)
  local findings = {}

  for name, record in pairs(modules) do
    for i = 1, #record.symbols do
      local symbol = record.symbols[i]
      local key = name .. "\0" .. symbol.name
      if not cross[key] and not external[key] and not record.ignored_lines[symbol.line] then
        symbol.recommendation = recommend.for_symbol(symbol, record, config)
        findings[#findings + 1] = symbol
      end
    end
  end

  return models.sort_findings(findings)
end

--- Run every enabled check against a project.
function M.run(project_root, config)
  local roots = source_roots.discover(project_root, config)
  local test_roots = source_roots.discover_test_roots(project_root, config)

  local modules, unparsable, unanalyzable = modules_mod.collect(roots, config, project_root)
  local collisions = modules_mod.collisions(roots, config, project_root)

  -- Files inside a declared test root are scanned as helper modules too, which
  -- is the one place a test directory contributes symbols rather than only
  -- references. Their names are counted from the project root, because that is
  -- how a co-located spec requires them.
  local helper_modules = modules_mod.collect(test_roots, config, project_root, {
    name_root = project_root,
    is_test_helper = true,
  })
  for name, record in pairs(helper_modules) do
    if modules[name] == nil then
      modules[name] = record
    end
  end

  local consumers = modules_mod.collect_test_consumers(test_roots, project_root)
  local cross = requires.cross_references(modules)

  -- Installed scripts sit outside every source root but still require modules,
  -- and those requires are real uses.
  local script_uses = requires.cross_references_from(
    modules,
    modules_mod.collect_path_consumers(rockspec.installed_scripts(project_root))
  )
  for key in pairs(script_uses) do
    cross[key] = true
  end
  local helper_used = _P.test_helper_references(test_roots, modules, consumers)
  for key in pairs(helper_used) do
    cross[key] = true
  end

  local external = _P.external_interface(project_root, config, modules)

  local findings = {
    roots = roots,
    unparsable = unparsable,
    unanalyzable = unanalyzable,
    collisions = collisions,
    symbols = {},
    globals = {},
    private_module_requires = {},
    private_symbol_reads = {},
    export_issues = {},
    methods = {},
  }

  if config.checks.symbols then
    findings.symbols = _P.symbol_findings(modules, config, cross, external)
  end
  if config.checks.globals then
    findings.globals = _P.global_findings(modules, config)
  end
  if config.checks.private_modules then
    findings.private_module_requires = models.sort_findings(
      requires.private_module_requires(modules, config.private_module_patterns)
    )
  end
  if config.checks.private_symbols then
    findings.private_symbol_reads = models.sort_findings(requires.private_symbol_reads(modules))
  end
  if config.checks.exports then
    findings.export_issues = exports.collect(modules)
  end
  if config.checks.methods then
    local methods = require("privata._methods")
    findings.methods = methods.collect(modules, cross, external)
  end

  return findings
end

--- Whether a findings set contains anything that should fail a run.
--
-- The two unreliable-scan conditions are counted only when their override is
-- off. Downgrading one leaves its warning printed but stops it deciding the
-- exit code, which is the whole point of the flag.
function M.has_failures(findings, config)
  if #findings.unparsable > 0 and not config.skip_unparsable_files then
    return true
  end
  if #findings.collisions > 0 and not config.skip_module_collisions then
    return true
  end
  return #findings.symbols > 0
    or #findings.globals > 0
    or #findings.private_module_requires > 0
    or #findings.private_symbol_reads > 0
    or #findings.export_issues > 0
    or #findings.methods > 0
    or #findings.unanalyzable > 0
end

function _P.is_empty(findings)
  return #findings.unparsable == 0
    and #findings.collisions == 0
    and #findings.unanalyzable == 0
    and #findings.symbols == 0
    and #findings.globals == 0
    and #findings.private_module_requires == 0
    and #findings.private_symbol_reads == 0
    and #findings.export_issues == 0
    and #findings.methods == 0
end

return M
