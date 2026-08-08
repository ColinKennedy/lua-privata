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
function _P.require_bindings(chunk)
  local aliases = {}
  local direct = {}

  ast.walk(chunk, function(node)
    if node.kind ~= "LocalDeclaration" and node.kind ~= "Assignment" then
      return
    end
    local names = node.kind == "LocalDeclaration" and node.names or node.targets
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

--- Every (module, field) pair a chunk reads from another module.
--
-- Three shapes reach a required module's field:
--   m.field            through a local bound to the module
--   require("m").field inline, with no local at all
--   m:method()         a call through the module table
function _P.references(chunk)
  local aliases, direct = _P.require_bindings(chunk)
  local used = {}
  local seen = {}

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

  ast.walk(chunk, function(node)
    if node.kind == "Index" and not node.computed and node.index.kind == "String" then
      local object = node.object
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
function M.cross_references(modules, consumers)
  local used = {}
  consumers = consumers or modules

  for consumer_name, consumer in pairs(consumers) do
    if consumer.chunk then
      local references = _P.references(consumer.chunk)
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
function M.cross_references_from(modules, consumer_list)
  local used = {}
  for i = 1, #consumer_list do
    local consumer = consumer_list[i]
    if consumer.chunk then
      local references = _P.references(consumer.chunk)
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

function _P.is_within_package(module_name, package_name)
  return module_name == package_name or module_name:sub(1, #package_name + 1) == package_name .. "."
end

--- Requires of a private module from outside the subtree that owns it.
--
-- Modules living in a test root are skipped: tests are allowed to reach
-- internals, which is the same rule that stops their usage conferring publicity.
function M.private_module_requires(modules, patterns)
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
function M.private_symbol_reads(modules)
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
      local references = _P.references(consumer.chunk)
      for i = 1, #references do
        local reference = references[i]
        local owner = private_by_module[reference.module]
        if
          reference.module ~= consumer_name
          and owner
          and owner[reference.name]
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
