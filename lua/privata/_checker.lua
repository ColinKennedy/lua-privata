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
local shape = require("privata._shape")
local source_roots = require("privata._source_roots")

local M = {}
local _P = {}

--- Everything the symbol check needs that is not the modules themselves.
--
-- Gathered once and passed as one table because each entry is computed from the
-- whole project: they cannot be derived per module inside the loop.
---@class privata.SymbolCheckContext
---@field cross table<string, boolean>        names some other module reads
---@field external table<string, boolean>     names something outside Lua reaches
---@field skip_modules table<string, boolean> modules already reported as a whole
---@field test_read table<string, privata.Location>     where a spec reads a name
---@field test_stubbed table<string, privata.Location>  where a spec replaces one
---@field string_words table<string, privata.Location>  names seen in a string literal

--- Symbols kept public by something outside the module graph.
--
-- A script in `build.install.bin` runs from a shell and a Neovim `setup`
-- function is called by the host, so neither is reachable through any
-- `require` privata can see. Treating them as unused would report the one
-- symbol in the project that definitely is used.
---@param project_root string
---@param config privata.Config
---@param modules table<string, privata.Module>
---@return table<string, boolean>  set keyed `"module\0name"`
function _P.external_interface(project_root, config, modules)
  local kept = {}

  -- Whole-module publicity: the host can reach any name the module exports.
  ---@param record privata.Module
  ---@param name string  the module's dotted name
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

  for name, record in pairs(modules) do
    if _P.is_entrypoint_module(name, config.entrypoint_modules or {}) then
      keep_all(record, name)
    end
  end

  return kept
end

--- True when a module name matches one of the configured entrypoint patterns.
--
-- `*` stands for any run of characters and everything else is literal, so
-- `*.health` reads as a glob rather than as a Lua pattern nobody wrote.
---@param module_name string
---@param patterns string[]  from `entrypoint_modules`
---@return boolean
function _P.is_entrypoint_module(module_name, patterns)
  for i = 1, #patterns do
    local pattern = "^" .. patterns[i]:gsub("%.", "%%."):gsub("%*", ".*") .. "$"
    if module_name:find(pattern) then
      return true
    end
  end
  return false
end

--- Names that co-located test files certify for helper modules in a test root.
--
-- A helper module living inside a declared test root exists to serve its own
-- suite, so a name those tests read is used. Attribution is scoped per root, so
-- a test file can never certify a production symbol.
---@param test_roots string[]
---@param modules table<string, privata.Module>
---@param consumers privata.Consumer[]
---@return table<string, boolean>  set keyed `"module\0name"`
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
---@param modules table<string, privata.Module>
---@return table<string, boolean>  set keyed `"module\0name"`
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
---@param modules table<string, privata.Module>
---@return table<string, privata.Location>  global name to where it is mentioned
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

--- Globals each module creates, minus the ones a host has to be able to reach.
---@param modules table<string, privata.Module>
---@param config privata.Config
---@param host_reachable table<string, privata.Location>
---@return privata.GlobalFinding[]  sorted by location
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
        if
          not allowed[entry.name]
          and not reached
          and not models.is_ignored(record, entry.line)
        then
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
---@param consumers privata.Consumer[]
---@param modules table<string, privata.Module>
---@return table<string, privata.Location> read     first spec read, keyed `"module\0name"`
---@return table<string, privata.Location> stubbed  first spec stub, keyed the same
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
---@param modules table<string, privata.Module>
---@return table<string, privata.Location>  name to where it was first seen
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
--
-- The earliest by path then line, so the reported handle does not move when
-- `pairs` hands the keys back in a different order.
---@param module_name string
---@param test_read table<string, privata.Location>  keyed `"module\0name"`
---@return privata.Location|nil
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
---@param detected privata.Shape
---@return string|nil  the alphabetically first non-private table local, if any
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
---@param module_name string
---@param cross table<string, boolean>  set keyed `"module\0name"`
---@return boolean  true when anything reads any of this module's names
function _P.is_consumed(module_name, cross)
  local prefix = module_name .. "\0"
  for key in pairs(cross) do
    if key:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

--- Modules whose returned table is the one the config calls private.
---@param modules table<string, privata.Module>
---@param config privata.Config
---@param cross table<string, boolean>
---@param test_read table<string, privata.Location>
---@return privata.ExportedNamespaceFinding[] findings  sorted by location
---@return table<string, boolean> offenders  modules the symbol check must skip
function _P.exported_namespace_findings(modules, config, cross, test_read)
  local findings = {}
  local offenders = {}

  for name, record in pairs(modules) do
    local detected = record.shape
    -- A FUNCTION shape's `public_name` is the name of a function, not of a
    -- table anything can be assigned onto, so a file returning `local function
    -- _P()` is not exporting a namespace whatever it called it.
    if
      detected
      and detected.kind ~= shape.KINDS.FUNCTION
      and detected.public_name == config.namespace
      and not models.is_ignored(record, detected.return_line or detected.public_line or 1)
    then
      offenders[name] = true
      findings[#findings + 1] = {
        module = name,
        path = record.path,
        line = detected.return_line or detected.public_line or 1,
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

--- Public symbols that nothing outside their own module reads.
--
-- The symbol tables are annotated in place before being collected, so the
-- recommendation and the test evidence travel with the finding.
---@param modules table<string, privata.Module>
---@param config privata.Config
---@param context privata.SymbolCheckContext
---@return privata.Symbol[]  sorted by location
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
          and not models.is_ignored(record, symbol.line)
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

--- Everything the function-module check needs beyond the modules themselves.
---@class privata.ModuleReachContext
---@field scripts privata.Consumer[]    installed scripts, which require but export nothing
---@field consumers privata.Consumer[]  every file found under the test roots
---@field test_roots string[]

--- Modules a host can reach without any Lua module requiring them.
--
-- The whole-module counterpart of `external_interface`: the same three things
-- that keep a *symbol* public regardless of the reference graph -- an installed
-- script, the rock's namesake module, a configured entrypoint -- keep the module
-- holding them public too.
---@param project_root string
---@param config privata.Config
---@param modules table<string, privata.Module>
---@return table<string, boolean>  set of module names
function _P.external_modules(project_root, config, modules)
  local kept = {}

  local api_modules = rockspec.api_module_names(project_root)
  for i = 1, #api_modules do
    if modules[api_modules[i]] then
      kept[api_modules[i]] = true
    end
  end

  local scripts = rockspec.installed_scripts(project_root)
  for name, record in pairs(modules) do
    if _P.is_entrypoint_module(name, config.entrypoint_modules or {}) then
      kept[name] = true
    end
    for i = 1, #scripts do
      if record.path == scripts[i] then
        kept[name] = true
      end
    end
  end

  return kept
end

--- Helper modules a test root's own specs require.
--
-- The module-level twin of `test_helper_references`, and scoped the same way: a
-- helper living in a test root exists to serve that suite, so a spec requiring
-- it is a real use, and attribution stays inside one root so a spec can never
-- certify production code.
---@param test_roots string[]
---@param modules table<string, privata.Module>
---@param consumers privata.Consumer[]
---@return table<string, boolean>  set of module names
function _P.test_helper_module_requires(test_roots, modules, consumers)
  local used = {}

  for i = 1, #test_roots do
    local root = test_roots[i]
    local local_consumers = {}
    for index = 1, #consumers do
      if consumers[index].source_root == root then
        local_consumers[#local_consumers + 1] = consumers[index]
      end
    end
    for name in pairs(requires.module_requires_from(local_consumers)) do
      local record = modules[name]
      if record and record.source_root == root then
        used[name] = true
      end
    end
  end

  return used
end

--- Every module something other than itself reaches.
---@param project_root string
---@param config privata.Config
---@param modules table<string, privata.Module>
---@param context privata.ModuleReachContext
---@return table<string, boolean>  set of module names
function _P.reachable_modules(project_root, config, modules, context)
  local consumers = {}
  for _, record in pairs(modules) do
    -- A helper in a test root is certified by its own suite below, not by being
    -- a module: crediting it here would let one unused helper keep another
    -- alive with no spec involved at all.
    if not record.is_test_helper then
      consumers[#consumers + 1] = record
    end
  end
  for i = 1, #context.scripts do
    consumers[#consumers + 1] = context.scripts[i]
  end

  local reachable = {}
  for name in pairs(requires.module_requires_from(consumers)) do
    reachable[name] = true
  end
  for name in pairs(_P.external_modules(project_root, config, modules)) do
    reachable[name] = true
  end
  local helpers = _P.test_helper_module_requires(context.test_roots, modules, context.consumers)
  for name in pairs(helpers) do
    reachable[name] = true
  end

  return reachable
end

--- The private module name a public one would become, when the convention fits.
--
-- `private_module_patterns` holds Lua patterns, and a pattern cannot be
-- inverted: privata can test a name against one, not build a name from it. So
-- it proposes the convention -- a leading underscore on the last segment -- and
-- offers it only when the project's own patterns agree the result is private. A
-- project that spells privacy some other way gets the general wording instead of
-- a rename that would not satisfy its own rule.
---@param module_name string
---@param patterns string[]
---@return string|nil
function _P.private_module_name(module_name, patterns)
  local prefix, last = module_name:match("^(.*%.)([^.]+)$")
  local candidate = (prefix or "") .. "_" .. (last or module_name)
  if requires.is_private_module(candidate, patterns) then
    return candidate
  end
  return nil
end

--- Modules whose whole export is a function that nothing requires.
--
-- A file returning a function publishes no fields, so the symbol check has
-- nothing to say about it: `local get_foo = require("thing.get_foo");
-- get_foo(10)` reaches the module without ever indexing it. The require *is* the
-- interface, so the question the symbol check asks per field is asked here per
-- module, and a module nothing outside itself requires is public surface that
-- nobody uses.
--
-- Test usage does not certify it, for the same reason it does not certify a
-- field -- and the remedy survives either way, since a spec is allowed to
-- require a private module. A module the patterns already mark private is left
-- alone: there is no publicity left to remove, and privata does not report dead
-- code.
---@param modules table<string, privata.Module>
---@param config privata.Config
---@param reachable table<string, boolean>  modules something outside themselves reaches
---@param test_required table<string, privata.Location>  where a spec requires each module
---@return privata.FunctionModuleFinding[]  sorted by location
function _P.function_module_findings(modules, config, reachable, test_required)
  local findings = {}

  for name, record in pairs(modules) do
    local detected = record.shape
    if detected and detected.kind == shape.KINDS.FUNCTION and not reachable[name] then
      local line = detected.public_line or detected.return_line or 1
      if
        not requires.is_private_module(name, config.private_module_patterns)
        and not models.is_ignored(record, line)
      then
        findings[#findings + 1] = {
          module = name,
          path = record.path,
          line = line,
          name = detected.public_name or name:match("[^.]+$") or name,
          anonymous = detected.public_name == nil,
          private_module = _P.private_module_name(name, config.private_module_patterns),
          test_require = test_required[name],
        }
      end
    end
  end

  return models.sort_findings(findings)
end

--- `-- privata: ignore` comments that suppressed nothing.
--
-- A suppression is a claim that there is a finding here and it is deliberate.
-- Once the finding is gone -- the symbol was made private, the global got its
-- `local`, the read moved -- the comment is a claim about nothing, and it will
-- silently swallow the *next* finding on that line. So privata reports it, the
-- same way it reports an export table entry that has gone stale.
--
-- Two kinds of file are exempt, because an unused ignore in them proves nothing.
-- A file whose shape privata could not read contributes no symbols at all, and
-- one that exports its private namespace has its per-field findings suppressed
-- by privata itself. In both, a comment that suppressed nothing this run may be
-- load-bearing the moment the larger problem above it is fixed, and privata does
-- not advise a deletion it would immediately ask to have undone.
---@param modules table<string, privata.Module>
---@param namespace_offenders table<string, boolean>  modules reported whole
---@return privata.StaleIgnoreFinding[]  sorted by location
function _P.stale_ignore_findings(modules, namespace_offenders)
  local findings = {}

  for name, record in pairs(modules) do
    if record.shape and record.shape.kind ~= nil and not namespace_offenders[name] then
      for line in pairs(record.ignored_lines) do
        if not record.used_ignores[line] then
          findings[#findings + 1] = {
            module = name,
            path = record.path,
            line = line,
            bare = record.bare_ignores[line] or false,
          }
        end
      end
    end
  end

  return models.sort_findings(findings)
end

--- Test files, which certify nothing but are named when a finding is theirs.
---@param consumers privata.Consumer[]
---@return privata.Consumer[]
function _P.test_files(consumers)
  local out = {}
  for i = 1, #consumers do
    if consumers[i].is_test_file then
      out[#out + 1] = consumers[i]
    end
  end
  return out
end

--- Run every enabled check against a project.
---@param project_root string
---@param config privata.Config
---@return privata.Findings
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
  local script_consumers =
    modules_mod.collect_path_consumers(rockspec.installed_scripts(project_root))
  local script_uses = requires.cross_references_from(modules, script_consumers)
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
    function_modules = {},
    symbols = {},
    globals = {},
    private_module_requires = {},
    private_symbol_reads = {},
    export_issues = {},
    methods = {},
    stale_ignores = {},
  }

  -- Every check below *runs*; `checks` decides only which results are kept.
  --
  -- Two of them are load-bearing for the others whatever the config says. The
  -- exported-namespace check produces `namespace_offenders`, which is what keeps
  -- the symbol check quiet about those files. And every check records the
  -- `-- privata: ignore` comments it honoured, which is the only evidence the
  -- stale-ignore check has: a suppression silenced by a check nobody asked to
  -- see is still doing its job, and calling it removable would be advice that
  -- breaks the moment the check is switched back on.
  local exported_namespaces, namespace_offenders =
    _P.exported_namespace_findings(modules, config, cross, test_read)

  local reachable = _P.reachable_modules(project_root, config, modules, {
    scripts = script_consumers,
    consumers = consumers,
    test_roots = test_roots,
  })
  local function_modules = _P.function_module_findings(
    modules,
    config,
    reachable,
    requires.module_requires_from(_P.test_files(consumers))
  )

  local symbols = _P.symbol_findings(modules, config, {
    cross = cross,
    external = external,
    skip_modules = namespace_offenders,
    test_read = test_read,
    test_stubbed = test_stubbed,
    string_words = string_words,
  })
  local globals = _P.global_findings(modules, config, host_reachable)
  local private_module_requires = models.sort_findings(
    requires.private_module_requires(
      modules,
      config.private_module_patterns,
      config.package_private
    )
  )
  local private_symbol_reads =
    models.sort_findings(requires.private_symbol_reads(modules, config.package_private))
  local export_issues = exports.collect(modules)
  local methods = require("privata._methods").collect(modules, cross, external)

  if config.checks.exported_namespaces then
    findings.exported_namespaces = exported_namespaces
  end
  if config.checks.function_modules then
    findings.function_modules = function_modules
  end
  if config.checks.symbols then
    findings.symbols = symbols
  end
  if config.checks.globals then
    findings.globals = globals
  end
  if config.checks.private_modules then
    findings.private_module_requires = private_module_requires
  end
  if config.checks.private_symbols then
    findings.private_symbol_reads = private_symbol_reads
  end
  if config.checks.exports then
    findings.export_issues = export_issues
  end
  if config.checks.methods then
    findings.methods = methods
  end
  -- Last, because it reads what every check above recorded.
  if config.checks.stale_ignores then
    findings.stale_ignores = _P.stale_ignore_findings(modules, namespace_offenders)
  end

  return findings
end

--- Findings of one kind that should count toward the exit code.
--
-- An advisory finding is exempt: privata has itself concluded there is no
-- action that improves the file, so failing the build on it asks for work that
-- cannot be done.
---@param list table[]  findings of one kind
---@return integer  how many of them are not advisory
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
---@param findings privata.Findings
---@param config privata.Config
---@return boolean
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
    function_modules = findings.function_modules,
    symbols = findings.symbols,
    globals = findings.globals,
    exported_namespaces = findings.exported_namespaces,
    private_modules = findings.private_module_requires,
    private_symbols = findings.private_symbol_reads,
    exports = findings.export_issues,
    methods = findings.methods,
    stale_ignores = findings.stale_ignores,
  }
  for kind, list in pairs(kinds) do
    if blocking[kind] and _P.blocking_count(list) > 0 then
      return true
    end
  end

  return false
end

--- True when a scan found nothing at all, of any kind.
---@param findings privata.Findings
---@return boolean
function _P.is_empty(findings)
  return #findings.unparsable == 0
    and #findings.collisions == 0
    and #findings.unanalyzable == 0
    and #findings.symbols == 0
    and #findings.exported_namespaces == 0
    and #findings.function_modules == 0
    and #findings.globals == 0
    and #findings.private_module_requires == 0
    and #findings.private_symbol_reads == 0
    and #findings.export_issues == 0
    and #findings.methods == 0
    and #findings.stale_ignores == 0
end

return M
