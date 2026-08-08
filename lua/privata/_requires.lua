--- Who reaches whose names, across module boundaries.
--
-- This is the check the whole tool rests on. A symbol stays public because
-- some other production module reads it; everything else is a candidate. The
-- two rules that make the answer useful rather than merely correct:
--
--   * a read from inside the defining module does not count, because that is
--     precisely the situation privata exists to report
--   * a read from a test file does not count either, which is what lets tests
--     reach internals without pinning them public forever
--
-- Resolution is deliberately generous in the other direction. Where privata
-- cannot tell which module an expression refers to, it credits the read rather
-- than dropping it: a missed reference produces a false positive, and a false
-- positive gets acted on with a rewrite that breaks working code.

local ast = require("privata._ast")

local M = {}
local _P = {}

--- Resolve the module name a `require` call names, or nil when computed.
---@param node privata.Node  an expression node
---@return string|nil  the dotted module name, or nil when it is not a literal
function _P.required_module(node)
  if node.kind ~= "Call" then
    return nil
  end
  if ast.dotted_name(node.callee) ~= "require" then
    return nil
  end
  local first = node.args[1]
  if first == nil or first.kind ~= "String" then
    return nil
  end
  return first.value
end

--- Map local names to the modules they hold.
--
-- Covers the three spellings that account for effectively all Lua:
--   local m = require("pkg.mod")
--   local m = require "pkg.mod"
--   local f = require("pkg.mod").field
--
-- The third binds a name directly to a symbol, which is a use of that symbol
-- on its own, so it is reported through `direct` rather than `aliases`.
---@param chunk privata.Node  a Chunk node
---@return table<string, string> aliases  local name to the module it holds
---@return { module: string, name: string, line: integer }[] direct
function _P.require_bindings(chunk)
  local aliases = {}
  local direct = {}

  ast.walk(chunk, function(node)
    if node.kind ~= "LocalDeclaration" and node.kind ~= "Assignment" then
      return
    end
    -- Both kinds bind a list of names; only the field they keep it under differs.
    local names = node.kind == "LocalDeclaration" and node.names or node.targets
    ---@cast names privata.Node[]
    for i = 1, #names do
      local target = names[i]
      local value = node.values[i]
      if value ~= nil then
        local module_name = _P.required_module(value)
        if module_name and target.kind == "Identifier" then
          aliases[target.name] = module_name
        elseif value.kind == "Index" and not value.computed and value.index.kind == "String" then
          local inner = _P.required_module(value.object)
          if inner then
            direct[#direct + 1] = { module = inner, name = value.index.value, line = value.line }
          end
        end
      end
    end
  end)

  return aliases, direct
end

--- `require'mod'.name` written inside a string literal, in any of its spellings.
--
-- Neovim hands Lua functions to Vimscript-evaluated options as strings:
-- `vim.wo.foldexpr = "v:lua.require'mod'.foldexpr(v:lnum)"`. The reference is
-- real, resolves through `require` at evaluation time, and indexes the returned
-- table -- so moving the target to a file-local breaks the editor at runtime,
-- not at load time and not in the test suite.
--
-- Matched exactly rather than by bare name, so this costs no true positives.
local REQUIRE_IN_STRING = "require%s*%(?%s*[\"'`]?([%w_%.%-]+)[\"'`]?%s*%)?%s*%.%s*([%w_]+)"

--- `v:lua.NAME`, which reaches a *global* rather than a module field.
local VIM_LUA_GLOBAL = "v:lua%.([%w_]+)"

--- Module-field references written inside string literals.
---@param chunk privata.Node  a Chunk node
---@return { module: string, name: string, line: integer }[]
function M.string_references(chunk)
  local found = {}
  ast.walk(chunk, function(node)
    if node.kind ~= "String" or node.synthetic or type(node.value) ~= "string" then
      return
    end
    for module_name, field in node.value:gmatch(REQUIRE_IN_STRING) do
      found[#found + 1] = { module = module_name, name = field, line = node.line }
    end
  end)
  return found
end

--- Global names a chunk reaches through `v:lua.NAME` in a string literal.
--
-- `%{v:lua.get_winbar()%}` in a statusline or winbar expression can only reach
-- `_G`, so a deliberate `_G.get_winbar = ...` shim is the one line in such a
-- file that *must* be global.
---@param chunk privata.Node  a Chunk node
---@return table<string, integer>  global name to the line mentioning it
function M.vim_lua_globals(chunk)
  local found = {}
  ast.walk(chunk, function(node)
    if node.kind ~= "String" or node.synthetic or type(node.value) ~= "string" then
      return
    end
    for name in node.value:gmatch(VIM_LUA_GLOBAL) do
      if name ~= "require" then
        found[name] = node.line
      end
    end
  end)
  return found
end

--- Names a string literal appears to *dispatch on*, with where they were seen.
--
-- Used to annotate rather than to suppress. A name reached by a dispatch table,
-- `_G[name]`, `vim.fn[name]` or an RPC method map appears only as a string, and
-- privata cannot tell that from a coincidence -- so it says what it saw and lets
-- the reader decide, instead of silently recommending a breaking rename.
--
-- Only two shapes count, because matching every word in every string is 97%
-- prose. `"setup.cfg"` matched `M.setup`, `"toggle-terminal state"` matched
-- `M.toggle`, and `desc = "…or close the quickfix buffer."` matched `M.close`.
-- At that rate a reader learns to skip the line, which costs the one case it
-- exists for:
--
--   * `[.:]name` -- a call or index written out, as in
--     `"lua require('mod.thing').restore_session_modes({…})"` written into a
--     session file and sourced back later. No reference graph reaches that.
--   * a literal that is exactly the name -- a key lookup, `handlers["run"]`.
--
-- A name assembled at runtime (`"run_" .. mode`) is still invisible, and always
-- will be. `-- privata: ignore` is the answer there.
---@param chunk privata.Node  a Chunk node
---@param path string  file the strings were found in, carried into the report
---@return table<string, { path: string, line: integer }>  first sighting per name
function M.string_dispatch_names(chunk, path)
  local found = {}

  -- First sighting wins, so the reported line is the earliest in the file.
  ---@param name string
  ---@param line integer
  local function record(name, line)
    if found[name] == nil then
      found[name] = { path = path, line = line }
    end
  end

  ast.walk(chunk, function(node)
    if node.kind ~= "String" or node.synthetic or type(node.value) ~= "string" then
      return
    end
    for name in node.value:gmatch("[%.:]([%a_][%w_]*)") do
      record(name, node.line)
    end
    local trimmed = node.value:match("^%s*(.-)%s*$")
    if trimmed:find("^[%a_][%w_]*$") then
      record(trimmed, node.line)
    end
  end)

  return found
end

--- Fields a chunk assigns onto a required module: `mod.name = ...`.
--
-- In a test file this is a monkeypatch seam. Production code calling
-- `M.name(...)` picks up the stub because the call goes through the table at
-- call time, so the indirection through `M` *is* the seam -- and privatising the
-- field removes the injection point rather than merely making it untestable.
---@param chunk privata.Node  a Chunk node
---@return { module: string, name: string, line: integer }[]
function M.field_assignments(chunk)
  local aliases = _P.require_bindings(chunk)
  local found = {}

  ast.walk(chunk, function(node)
    if node.kind ~= "Assignment" then
      return
    end
    for i = 1, #node.targets do
      local target = node.targets[i]
      if target.kind == "Index" and not target.computed and target.index.kind == "String" then
        local object = target.object
        ---@cast object privata.Node
        if object.kind == "Identifier" and aliases[object.name] then
          found[#found + 1] = {
            module = aliases[object.name],
            name = target.index.value,
            line = target.field_line or target.line,
          }
        end
      end
    end
  end)

  return found
end

--- Every (module, field) pair a chunk reads from another module.
--
-- Three shapes reach a required module's field:
--   m.field            through a local bound to the module
--   require("m").field inline, with no local at all
--   m:method()         a call through the module table
---@param chunk privata.Node  a Chunk node
---@return { module: string, name: string, line: integer }[]  deduplicated
function M.references(chunk)
  local aliases, direct = _P.require_bindings(chunk)
  local used = {}
  local seen = {}

  -- Deduplicated on (module, field): a symbol read twice is still one symbol
  -- kept public, and the report names the first line that reads it.
  ---@param module_name string|nil
  ---@param field string|nil
  ---@param line integer
  local function record(module_name, field, line)
    if module_name == nil or field == nil then
      return
    end
    local key = module_name .. "\0" .. field
    if seen[key] then
      return
    end
    seen[key] = true
    used[#used + 1] = { module = module_name, name = field, line = line }
  end

  for i = 1, #direct do
    record(direct[i].module, direct[i].name, direct[i].line)
  end

  -- A `require'mod'.name` written inside a string is as real a reference as one
  -- written as code; only the moment of resolution differs.
  local from_strings = M.string_references(chunk)
  for i = 1, #from_strings do
    record(from_strings[i].module, from_strings[i].name, from_strings[i].line)
  end

  ast.walk(chunk, function(node)
    if node.kind == "Index" and not node.computed and node.index.kind == "String" then
      local object = node.object
      ---@cast object privata.Node
      if object.kind == "Identifier" and aliases[object.name] then
        record(aliases[object.name], node.index.value, node.field_line or node.line)
      else
        local inline = _P.required_module(object)
        if inline then
          record(inline, node.index.value, node.field_line or node.line)
        end
      end
    elseif node.kind == "MethodCall" then
      local object = node.object
      ---@cast object privata.Node
      if object.kind == "Identifier" and aliases[object.name] then
        record(aliases[object.name], node.method, node.method_line or node.line)
      else
        local inline = _P.required_module(object)
        if inline then
          record(inline, node.method, node.method_line or node.line)
        end
      end
    end
  end)

  return used
end

--- Modules a chunk requires, whether or not it reads a field from them.
---@param chunk privata.Node  a Chunk node
---@return { module: string, line: integer }[]  one entry per module, first line
function _P.required_modules(chunk)
  local out = {}
  local seen = {}
  ast.walk(chunk, function(node)
    local module_name = _P.required_module(node)
    if module_name and not seen[module_name] then
      seen[module_name] = true
      out[#out + 1] = { module = module_name, line = node.line }
    end
  end)
  return out
end

--- Symbols of `modules` that some *other* module reads.
--
-- Returns a set keyed `"module\0name"`. Consumers default to the modules
-- themselves; the test-helper rule passes a separate consumer list so that
-- files in a test root can certify helpers without certifying production code.
---@param modules table<string, privata.Module>  the modules whose symbols matter
---@param consumers table<string, privata.Module>|nil  who may certify them
---@return table<string, boolean>  set keyed `"module\0name"`
function M.cross_references(modules, consumers)
  local used = {}
  consumers = consumers or modules

  for consumer_name, consumer in pairs(consumers) do
    if consumer.chunk then
      local references = M.references(consumer.chunk)
      for i = 1, #references do
        local reference = references[i]
        -- A module reading its own field is the situation being reported, not
        -- evidence against it.
        if reference.module ~= consumer_name and modules[reference.module] then
          used[reference.module .. "\0" .. reference.name] = true
        end
      end
    end
  end

  return used
end

--- The same, for a list of consumer records rather than a name-keyed map.
---@param modules table<string, privata.Module>
---@param consumer_list privata.Consumer[]
---@return table<string, boolean>  set keyed `"module\0name"`
function M.cross_references_from(modules, consumer_list)
  local used = {}
  for i = 1, #consumer_list do
    local consumer = consumer_list[i]
    if consumer.chunk then
      local references = M.references(consumer.chunk)
      for index = 1, #references do
        local reference = references[index]
        if reference.module ~= consumer.name and modules[reference.module] then
          used[reference.module .. "\0" .. reference.name] = true
        end
      end
    end
  end
  return used
end

--- True when a module name has a segment matching one of the private patterns.
---@param module_name string   dotted module name
---@param patterns string[]    Lua patterns matched against each segment
---@return boolean
function _P.is_private_module(module_name, patterns)
  for segment in module_name:gmatch("[^.]+") do
    for i = 1, #patterns do
      if segment:find(patterns[i]) then
        return true
      end
    end
  end
  return false
end

--- The package that owns a private module, and may therefore require it.
--
-- Ownership starts at the *first* private segment, not the last: everything
-- from `_report` down in `pkg._report.json` is one private area belonging to
-- `pkg`, so `pkg.cli` may reach into it. Taking the immediate parent instead
-- would make a private subpackage unreachable from the package that owns it,
-- which is the opposite of what marking it private was meant to achieve.
---@param module_name string
---@param patterns string[]
---@return string|nil  the owning package, the module itself when not private,
---                    or nil when the first segment is already private
function _P.owning_package(module_name, patterns)
  local parts = {}
  for segment in module_name:gmatch("[^.]+") do
    parts[#parts + 1] = segment
  end

  for index = 1, #parts do
    for i = 1, #patterns do
      if parts[index]:find(patterns[i]) then
        if index == 1 then
          return nil -- a top-level private module belongs to no package
        end
        return table.concat(parts, ".", 1, index - 1)
      end
    end
  end

  return module_name
end

--- True when both modules sit inside one configured package-private prefix.
--
-- The third visibility level. privata's model is otherwise binary -- a name is
-- on the interface or it is file-local -- but real codebases have a middle:
-- Java's package-private, Rust's `pub(crate)`, Go's `internal/`. `M._FOO` read
-- by eight sibling modules of one application is that level, not eight boundary
-- violations, and there is no call site to "fix".
--
-- Off by default. For a library, a sibling reaching into `pkg.other._helper` is
-- still worth knowing about; only the project can say which it is.
---@param owner string       module the name belongs to
---@param reader string      module doing the reading
---@param prefixes string[]  configured package-private prefixes
---@return boolean
function _P.shares_package(owner, reader, prefixes)
  for i = 1, #prefixes do
    local prefix = prefixes[i]
    if _P.is_within_package(owner, prefix) and _P.is_within_package(reader, prefix) then
      return true
    end
  end
  return false
end

--- True when `module_name` is `package_name` or sits beneath it.
--
-- The `.` is required so `pkg.other` is not read as being inside `pkg.o`.
---@param module_name string
---@param package_name string
---@return boolean
function _P.is_within_package(module_name, package_name)
  return module_name == package_name or module_name:sub(1, #package_name + 1) == package_name .. "."
end

--- Requires of a private module from outside the subtree that owns it.
--
-- Modules living in a test root are skipped: tests are allowed to reach
-- internals, which is the same rule that stops their usage conferring publicity.
---@param modules table<string, privata.Module>
---@param patterns string[]              patterns marking a module segment private
---@param package_private string[]|nil   prefixes within which such reads are allowed
---@return privata.PrivateModuleRequireFinding[] findings
function M.private_module_requires(modules, patterns, package_private)
  package_private = package_private or {}
  local findings = {}

  for consumer_name, consumer in pairs(modules) do
    if consumer.chunk and not consumer.is_test_helper then
      local required = _P.required_modules(consumer.chunk)
      for i = 1, #required do
        local target = required[i].module
        local owner = _P.owning_package(target, patterns)
        if
          modules[target]
          and target ~= consumer_name
          and _P.is_private_module(target, patterns)
          and not (owner and _P.is_within_package(consumer_name, owner))
          and not _P.shares_package(target, consumer_name, package_private)
          and not consumer.ignored_lines[required[i].line]
        then
          findings[#findings + 1] = {
            module = target,
            path = modules[target].path,
            required_by = consumer_name,
            required_by_path = consumer.path,
            line = required[i].line,
            name = target,
          }
        end
      end
    end
  end

  return findings
end

--- Reads of another module's private names.
--
-- Covers both spellings of "private" that a Lua module has: a `_`-prefixed
-- field on the public table, and any field on the private namespace table.
---@param modules table<string, privata.Module>
---@param package_private string[]|nil  prefixes within which such reads are allowed
---@return privata.PrivateSymbolReadFinding[] findings
function M.private_symbol_reads(modules, package_private)
  package_private = package_private or {}
  local private_by_module = {}
  for name, record in pairs(modules) do
    local set = {}
    for i = 1, #record.private_symbols do
      set[record.private_symbols[i].name] = record.private_symbols[i]
    end
    private_by_module[name] = set
  end

  local findings = {}

  for consumer_name, consumer in pairs(modules) do
    if consumer.chunk and not consumer.is_test_helper then
      local references = M.references(consumer.chunk)
      for i = 1, #references do
        local reference = references[i]
        local owner = private_by_module[reference.module]
        if
          reference.module ~= consumer_name
          and owner
          and owner[reference.name]
          and not _P.shares_package(reference.module, consumer_name, package_private)
          and not consumer.ignored_lines[reference.line]
        then
          findings[#findings + 1] = {
            module = reference.module,
            name = reference.name,
            path = owner[reference.name].path,
            read_by = consumer_name,
            read_by_path = consumer.path,
            line = reference.line,
          }
        end
      end
    end
  end

  return findings
end

return M
