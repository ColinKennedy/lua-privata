--- The opt-in method check.
--
-- Off by default, and more conservative than its Python counterpart, because
-- Lua method dispatch is *more* dynamic than Python attribute access, not less:
-- a name can be reached through an `__index` chain assembled at runtime, and
-- there is no class statement to bound the search.
--
-- **Divergence from python-privata, deliberate.** That tool skips classes
-- listed in `__all__` or re-exported by a package `__init__.py`, reasoning that
-- re-export is an explicit declaration of publicity. In Lua, `return C` is the
-- only way to ship a class at all -- it is the language, not a decision -- so
-- applying that rule would skip every class module and leave this check
-- analysing nothing. Returned classes are therefore checked, and the
-- conservatism lives entirely in the disqualifiers below.

local ast = require("privata._ast")
local models = require("privata._models")
local shape = require("privata._shape")

local M = {}
local _P = {}

--- Builtins that reach a field by a name the caller computes.
local DYNAMIC_LOOKUPS = { rawget = true, rawset = true, setmetatable = true }

--- Every name any module mentions as a field, a method or a string literal.
--
-- Matching is by name rather than by receiver, exactly as in python-privata: an
-- unrelated `other.run` elsewhere suppresses a report for `Service.run`. That
-- over-matches, which only ever costs a missed finding -- the safe direction
-- for a tool whose output is acted on by rewriting code.
function _P.referenced_names(modules)
  local names = {}

  for module_name, record in pairs(modules) do
    if record.chunk then
      ast.walk(record.chunk, function(node)
        local found = nil
        if node.kind == "Index" and not node.computed and node.index.kind == "String" then
          found = node.index.value
        elseif node.kind == "MethodCall" then
          found = node.method
        elseif node.kind == "String" then
          -- `obj["run"]` and a dispatch table keyed by name both spell the
          -- method out as a literal, so a literal counts as a reference.
          found = node.value
        end
        if found then
          names[found] = names[found] or {}
          names[found][module_name] = true
        end
      end)
    end
  end

  return names
end

--- Class tables that anything links a metatable to, anywhere in the project.
--
-- A subclass that only overrides a method never mentions that name as a field,
-- so the reference scan cannot see it. Renaming the base method would strand
-- the override under its old name, so any table used as a base keeps its
-- methods public.
function _P.base_tables(modules)
  local bases = {}

  local function note(node)
    local name = ast.dotted_name(node)
    if name then
      bases[name:match("[^.]+$")] = true
    end
  end

  for _, record in pairs(modules) do
    if record.chunk then
      ast.walk(record.chunk, function(node)
        if node.kind == "Call" and ast.dotted_name(node.callee) == "setmetatable" then
          local target = node.args[1]
          local meta = node.args[2]
          if meta then
            if meta.kind == "TableExpr" then
              -- `{ __index = Base }` is the inheritance spelling whatever the
              -- receiver is.
              for i = 1, #meta.fields do
                local field = meta.fields[i]
                if field.key and field.key.kind == "String" and field.key.value == "__index" then
                  note(field.value)
                end
              end
            elseif target ~= nil and target.kind ~= "TableExpr" then
              -- `setmetatable(Child, Base)` links one named table to another,
              -- which is inheritance. `setmetatable({}, C)` attaches a class to
              -- a fresh table, which is every Lua constructor ever written --
              -- reading that as inheritance would make each class its own base
              -- and silently disable the check for the whole project.
              note(meta)
            end
          end
        elseif node.kind == "Assignment" then
          for i = 1, #node.targets do
            local dotted = ast.dotted_name(node.targets[i])
            if dotted and dotted:match("%.__index$") then
              local holder = dotted:match("^(.*)%.__index$")
              local value = ast.dotted_name(node.values[i])
              -- `C.__index = C` is self-reference, not inheritance.
              if value and value ~= holder then
                note(node.values[i])
              end
            end
          end
        end
      end)
    end
  end

  return bases
end

--- True when a chunk reaches the class table by a name it computes.
--
-- `C[key]` may reach any method the class has, so renaming one would break a
-- call the scan never saw. None of the class's methods are checked.
function _P.uses_dynamic_lookup(chunk, class_name)
  local dynamic = false

  ast.walk(chunk, function(node)
    if node.kind == "Index" and node.computed then
      local object = ast.dotted_name(node.object)
      if object == class_name or object == "self" then
        dynamic = true
      end
    elseif node.kind == "Call" then
      local callee = ast.dotted_name(node.callee)
      if DYNAMIC_LOOKUPS[callee] then
        local second = node.args[2]
        if second and second.kind ~= "String" then
          local first = ast.dotted_name(node.args[1])
          if first == class_name or first == "self" then
            dynamic = true
          end
        end
      end
    end
  end)

  return dynamic
end

--- Methods defined on `class_name`, in source order.
function _P.class_methods(chunk, class_name)
  local found = {}
  local order = {}

  local function record(name, line)
    if name == nil or found[name] then
      return
    end
    found[name] = { name = name, line = line }
    order[#order + 1] = found[name]
  end

  ast.walk(chunk, function(node)
    if node.kind == "FunctionDeclaration" then
      local dotted = ast.dotted_name(node.target)
      if dotted then
        local holder, field = dotted:match("^(.*)%.([^.]+)$")
        if holder == class_name then
          record(field, node.target.field_line or node.line)
        end
      end
    elseif node.kind == "Assignment" then
      for i = 1, #node.targets do
        local value = node.values[i]
        if value and value.kind == "FunctionExpr" then
          local dotted = ast.dotted_name(node.targets[i])
          if dotted then
            local holder, field = dotted:match("^(.*)%.([^.]+)$")
            if holder == class_name then
              record(field, node.targets[i].field_line or node.line)
            end
          end
        end
      end
    end
  end)

  return order
end

--- True when a method forwards to a same-named method on a base.
--
-- Cooperative overrides have to keep the name they override.
function _P.forwards_to_base(chunk, class_name, method_name)
  local forwards = false
  ast.walk(chunk, function(node)
    if node.kind == "MethodCall" and node.method == method_name then
      local object = ast.dotted_name(node.object)
      if object and object ~= class_name and object ~= "self" then
        forwards = true
      end
    end
  end)
  return forwards
end

--- Public methods that no other production module refers to.
function M.collect(modules, cross_references, external_interface)
  local references = _P.referenced_names(modules)
  local bases = _P.base_tables(modules)
  local findings = {}

  for module_name, record in pairs(modules) do
    local detected = record.shape
    if record.chunk and detected and detected.kind == shape.KINDS.CLASS then
      local class_name = detected.public_name
      local qualifies = not bases[class_name]
        and not _P.uses_dynamic_lookup(record.chunk, class_name)

      if qualifies then
        local methods = _P.class_methods(record.chunk, class_name)
        local public_count = 0
        for i = 1, #methods do
          local name = methods[i].name
          if not models.is_private_name(name) and not models.is_metamethod(name) then
            public_count = public_count + 1
          end
        end

        for i = 1, #methods do
          local method = methods[i]
          local name = method.name
          local referencing = references[name] or {}
          local referenced_elsewhere = false
          for other in pairs(referencing) do
            if other ~= module_name then
              referenced_elsewhere = true
            end
          end

          if
            not models.is_private_name(name)
            and not models.is_metamethod(name)
            and not referenced_elsewhere
            and not cross_references[module_name .. "\0" .. name]
            and not external_interface[module_name .. "\0" .. name]
            and not record.ignored_lines[method.line]
            and not _P.forwards_to_base(record.chunk, class_name, name)
          then
            findings[#findings + 1] = {
              name = name,
              class_name = class_name,
              line = method.line,
              module = module_name,
              path = record.path,
              class_line = detected.public_line or 1,
              class_public_methods = public_count,
            }
          end
        end
      end
    end
  end

  return models.sort_findings(findings)
end

return M
