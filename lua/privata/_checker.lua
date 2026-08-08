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

--- Names handed to a host as `require'mod'.name` inside a string literal.
--
-- These are entry points, not cross-module reads, and the difference decides
-- whether they are seen at all. The string is almost always written *in the
-- module it names* -- `vim.wo.foldexpr = "v:lua.require'this.module'.foldexpr()"`
-- sits beside the function it points at -- so the cross-reference rule, which
-- correctly ignores a module reading itself, would drop every one of them.
--
-- What makes it public is not that another Lua module reads it; it is that
-- something outside the Lua module graph resolves the name through `require` at
-- evaluation time. That is the same category as a rockspec's installed script.
function _P.string_entrypoints(modules)
  local kept = {}
  for _, record in pairs(modules) do
    if record.chunk then
      local found = requires.string_references(record.chunk)
      for i = 1, #found do
        kept[found[i].module .. "\0" .. found[i].name] = true
      end
    end
  end
  return kept
end

--- Global names any module reaches through `v:lua.NAME` in a string literal.
--
-- `%{v:lua.get_winbar()%}` in a winbar expression can only reach `_G`, so the
-- `_G.get_winbar = ...` shim beside it is the one line in the file that must be
-- global. Reporting it as a leak is exactly backwards.
function _P.host_reachable_globals(modules)
  local reachable = {}
  for _, record in pairs(modules) do
    if record.chunk then
      for name, line in pairs(requires.vim_lua_globals(record.chunk)) do
        reachable[name] = { path = record.path, line = line }
      end
    end
  end
  return reachable
end

function _P.global_findings(modules, config, host_reachable)
  local allowed = {}
  for i = 1, #(config.globals or {}) do
    allowed[config.globals[i]] = true
  end

  local findings = {}
  for name, record in pairs(modules) do
    if record.scope then
      for i = 1, #record.scope.assigned do
        local entry = record.scope.assigned[i]
        local reached = host_reachable[entry.name]
        if not allowed[entry.name] and not reached and not record.ignored_lines[entry.line] then
          findings[#findings + 1] = {
            name = entry.name,
            kind = entry.kind,
            explicit = entry.explicit,
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

--- Where each name is read or stubbed from a test root.
--
-- Test usage still does not make a symbol public -- that policy is unchanged.
-- What it does do is constrain which privatisation is *legal*: a spec calling
-- `mod.parse_diff` cannot follow a recommendation that moves the field to a
-- file-local, because `mod` is the only handle the spec has. privata has always
-- had this information and never asked it this question.
function _P.test_usage(consumers, modules)
  local read = {}
  local stubbed = {}

  for i = 1, #consumers do
    local consumer = consumers[i]
    if consumer.chunk and consumer.is_test_file then
      local references = requires.references(consumer.chunk)
      for index = 1, #references do
        local reference = references[index]
        if modules[reference.module] then
          local key = reference.module .. "\0" .. reference.name
          read[key] = read[key] or { path = consumer.path, line = reference.line }
        end
      end

      local assignments = requires.field_assignments(consumer.chunk)
      for index = 1, #assignments do
        local assignment = assignments[index]
        if modules[assignment.module] then
          local key = assignment.module .. "\0" .. assignment.name
          stubbed[key] = stubbed[key] or { path = consumer.path, line = assignment.line }
        end
      end
    end
  end

  return read, stubbed
end

--- First sighting of each dispatch-shaped name in a string literal, project-wide.
function _P.string_dispatch_names(modules)
  local words = {}
  for _, record in pairs(modules) do
    if record.chunk then
      for word, where in pairs(requires.string_dispatch_names(record.chunk, record.path)) do
        if words[word] == nil then
          words[word] = where
        end
      end
    end
  end
  return words
end

--- Where a test first reaches into this module, if anywhere.
function _P.first_test_reader(module_name, test_read)
  local prefix = module_name .. "\0"
  local best = nil
  for key, where in pairs(test_read) do
    if key:sub(1, #prefix) == prefix then
      if
        best == nil
        or where.path < best.path
        or (where.path == best.path and where.line < best.line)
      then
        best = where
      end
    end
  end
  return best
end

--- The public table a file already has, if any, for the remedy wording.
--
-- A file that also declares a non-private table can merge into it; one that
-- does not needs the namespace renamed outright.
function _P.public_table_name(detected)
  local best = nil
  for name in pairs(detected.table_locals or {}) do
    if not models.is_private_name(name) and (best == nil or name < best) then
      best = name
    end
  end
  return best
end

--- Modules that return the very table the config calls private.
--
-- `local _P = {} ... return _P` exports `_P`, so every field on it is public --
-- the exact opposite of what naming it `_P` was meant to say. This is a
-- contradiction in the module's structure, not a property of any one field, so
-- it is reported once against the file, and its per-field findings are
-- suppressed: they would restate this one problem per field, each pointing at a
-- table the symbol already sits on.
function _P.is_consumed(module_name, cross)
  local prefix = module_name .. "\0"
  for key in pairs(cross) do
    if key:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

function _P.exported_namespace_findings(modules, config, cross, test_read)
  local findings = {}
  local offenders = {}

  for name, record in pairs(modules) do
    local detected = record.shape
    local line = detected and (detected.return_line or detected.public_line or 1)
    if detected and detected.public_name == config.namespace and not record.ignored_lines[line] then
      offenders[name] = true
      findings[#findings + 1] = {
        module = name,
        path = record.path,
        line = line,
        namespace = config.namespace,
        name = config.namespace,
        public_table = _P.public_table_name(detected),
        public_symbols = #record.symbols,
        -- A module nothing consumes, whose table a spec holds, has no fix that
        -- improves it: returning nothing breaks the spec and renaming to `M`
        -- publishes fields no one reads. privata has already concluded it is a
        -- test handle, and "test handle" is a clean bill of health, not the
        -- highest-priority item in the file -- so it says so and stops leading
        -- with it. The symbol check already changes its recommendation on test
        -- evidence; this makes the export check consistent with that.
        advisory = not _P.is_consumed(name, cross) and _P.first_test_reader(name, test_read) ~= nil,
        -- Whether anything in production actually reads this return value
        -- decides which advice is honest. A module nothing consumes is a
        -- side-effect module whose table is a test handle, and telling its
        -- author to rename it to `M` would publish an interface no one asked
        -- for -- the opposite of what this tool is for.
        consumed = _P.is_consumed(name, cross),
        test_handle = _P.first_test_reader(name, test_read),
      }
    end
  end

  return models.sort_findings(findings), offenders
end

function _P.symbol_findings(modules, config, context)
  local findings = {}

  for name, record in pairs(modules) do
    -- A module that exports its private namespace is reported once, as that
    -- one structural fact. Listing its fields as well would restate the same
    -- problem per field, and point each one at a table it already sits on.
    if not context.skip_modules[name] then
      for i = 1, #record.symbols do
        local symbol = record.symbols[i]
        local key = name .. "\0" .. symbol.name
        if
          not context.cross[key]
          and not context.external[key]
          and not record.ignored_lines[symbol.line]
        then
          symbol.test_read = context.test_read[key]
          symbol.test_stub = context.test_stubbed[key]
          symbol.string_mention = context.string_words[symbol.name]
          symbol.recommendation = recommend.for_symbol(symbol, record, config)
          findings[#findings + 1] = symbol
        end
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
  for key in pairs(_P.string_entrypoints(modules)) do
    external[key] = true
  end
  local test_read, test_stubbed = _P.test_usage(consumers, modules)
  local host_reachable = _P.host_reachable_globals(modules)
  local string_words = _P.string_dispatch_names(modules)

  local findings = {
    roots = roots,
    unparsable = unparsable,
    unanalyzable = unanalyzable,
    collisions = collisions,
    exported_namespaces = {},
    symbols = {},
    globals = {},
    private_module_requires = {},
    private_symbol_reads = {},
    export_issues = {},
    methods = {},
  }

  -- Computed before the symbol check because it decides which modules that
  -- check must stay quiet about.
  --
  -- It runs even when the check is switched off, because `namespace_offenders`
  -- is what keeps the symbol check quiet about those files. Only the reporting
  -- is optional; the analysis is not.
  local exported_namespaces, namespace_offenders =
    _P.exported_namespace_findings(modules, config, cross, test_read)
  if config.checks.exported_namespaces then
    findings.exported_namespaces = exported_namespaces
  end

  if config.checks.symbols then
    findings.symbols = _P.symbol_findings(modules, config, {
      cross = cross,
      external = external,
      skip_modules = namespace_offenders,
      test_read = test_read,
      test_stubbed = test_stubbed,
      string_words = string_words,
    })
  end
  if config.checks.globals then
    findings.globals = _P.global_findings(modules, config, host_reachable)
  end
  if config.checks.private_modules then
    findings.private_module_requires = models.sort_findings(
      requires.private_module_requires(
        modules,
        config.private_module_patterns,
        config.package_private
      )
    )
  end
  if config.checks.private_symbols then
    findings.private_symbol_reads =
      models.sort_findings(requires.private_symbol_reads(modules, config.package_private))
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

--- Findings of one kind that should count toward the exit code.
--
-- An advisory finding is exempt: privata has itself concluded there is no
-- action that improves the file, so failing the build on it asks for work that
-- cannot be done.
function _P.blocking_count(list)
  local count = 0
  for i = 1, #list do
    if not list[i].advisory then
      count = count + 1
    end
  end
  return count
end

--- Whether a findings set contains anything that should fail a run.
--
-- `fail_on` names the kinds that block. It defaults to all of them, so the
-- behaviour is unchanged, but it lets a project say "report this and do not
-- block on it" -- which `checks` cannot express, because switching a check off
-- also stops it reporting. A gate that can never go green gets `|| true`'d, and
-- then the findings that *were* worth blocking on are lost with the rest.
function M.has_failures(findings, config)
  local blocking = {}
  for i = 1, #(config.fail_on or {}) do
    blocking[config.fail_on[i]] = true
  end

  if blocking.unparsable and #findings.unparsable > 0 and not config.skip_unparsable_files then
    return true
  end
  if blocking.collisions and #findings.collisions > 0 and not config.skip_module_collisions then
    return true
  end

  local kinds = {
    unanalyzable = findings.unanalyzable,
    symbols = findings.symbols,
    globals = findings.globals,
    exported_namespaces = findings.exported_namespaces,
    private_modules = findings.private_module_requires,
    private_symbols = findings.private_symbol_reads,
    exports = findings.export_issues,
    methods = findings.methods,
  }
  for kind, list in pairs(kinds) do
    if blocking[kind] and _P.blocking_count(list) > 0 then
      return true
    end
  end

  return false
end

function _P.is_empty(findings)
  return #findings.unparsable == 0
    and #findings.collisions == 0
    and #findings.unanalyzable == 0
    and #findings.symbols == 0
    and #findings.exported_namespaces == 0
    and #findings.globals == 0
    and #findings.private_module_requires == 0
    and #findings.private_symbol_reads == 0
    and #findings.export_issues == 0
    and #findings.methods == 0
end

return M
