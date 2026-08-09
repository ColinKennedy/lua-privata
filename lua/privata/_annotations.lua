--- LuaCATS annotations, read as the reference edge the require graph does not have.
--
-- A class module is reached through its *instances*, never through its table. A
-- caller writes `item:position()` on a value it was handed, and nothing anywhere
-- spells `code_item.position` -- so the reference scan, which resolves a field
-- read to the module a `require` bound, has no edge to follow and every method
-- on the class looks unread. That is the worst false positive this tool can
-- produce: acting on it moves a method that three other files call.
--
-- The edge is already written down, in the annotation the caller needed anyway.
-- `---@param item pkg.CodeItem` names the class the value has; `---@class
-- pkg.CodeItem` above the exported table names the module that owns it. Joining
-- those two is enough to see the call.
--
-- Annotations are comments, so they are read from raw source rather than from
-- the token stream -- the lexer discards comments, exactly as it does the
-- `-- privata: ignore` marker, which is read the same way and for the same
-- reason.
--
-- **Where this stops.** It follows a *declared* type, never an inferred one:
-- `local x = item` retypes nothing privata can see, and neither does the loop
-- variable in `for _, item in ipairs(items)`. A codebase whose annotations are
-- absent or wrong gets exactly the behaviour it had before this existed.

local ast = require("privata._ast")
local lexer = require("privata._lexer")

local M = {}
local _P = {}

--- The tags privata reads. Every other LuaCATS tag is skipped.
--
-- `class` is the declaring side and the other three are the using side: a
-- parameter, a variable and a re-narrowing are the three places a Lua file says
-- "this value is of that type" without assigning it from a `require`.
_P.TAGS = { class = true, param = true, type = true, cast = true }

--- Characters that carry a type expression across a space.
--
-- `A | B` and `table<string, T>` are one type written with spaces in it, so a
-- space alone cannot mean the type ended and the description began.
_P.CONTINUERS = { ["|"] = true, [","] = true, [":"] = true }

_P.OPENERS = { ["("] = true, ["["] = true, ["<"] = true, ["{"] = true }
_P.CLOSERS = { [")"] = true, ["]"] = true, [">"] = true, ["}"] = true }

--- The leading type expression of `text`, with the trailing description gone.
--
-- Worth the state machine rather than "up to the first space": that rule cuts
-- `table<string, pkg.Module>` in half and loses the one name that mattered.
-- Reading too far is the other failure and is worse in a different way -- the
-- words of a description are ordinary identifiers, and `---@param x number the
-- Point to draw` would claim a reference to a class called `Point`.
---@param text string  everything after the tag, and after the name where there is one
---@return string  the type expression alone
function _P.type_expression(text)
  local depth = 0
  local previous = nil

  for index = 1, #text do
    local char = text:sub(index, index)
    if _P.OPENERS[char] then
      depth = depth + 1
    elseif _P.CLOSERS[char] then
      depth = depth - 1
      -- A closer with nothing open belongs to whatever encloses this comment,
      -- not to the type.
      if depth < 0 then
        return text:sub(1, index - 1)
      end
    elseif (char == " " or char == "\t") and depth == 0 then
      local following = text:match("^%s*(.)", index)
      local continues = (previous ~= nil and _P.CONTINUERS[previous])
        or (following ~= nil and (_P.CONTINUERS[following] or _P.OPENERS[following]))
      if not continues then
        return text:sub(1, index - 1)
      end
    end
    if char ~= " " and char ~= "\t" then
      previous = char
    end
  end

  return text
end

--- Every dotted identifier written inside a type expression.
--
-- One expression can name several types -- `pkg.Item[]`, `pkg.Item|nil`,
-- `table<string, pkg.Item>` -- and each of them is a real reference to the
-- module that declares it. Builtin names come back too; nothing declares a class
-- called `string`, so they match no owner and cost nothing.
---@param expression string
---@return string[]  in the order written, deduplicated
function _P.type_names(expression)
  local out = {}
  local seen = {}
  for name in expression:gmatch("[%a_][%w_%.]*") do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

--- Read one source line as an annotation.
--
-- The second return says whether code precedes the comment, which is what
-- decides *what the annotation is about*: a trailing `---@type` describes the
-- line it sits on, and a leading one describes the line below.
---@param text string      the raw source line
---@param number integer   its 1-based line number
---@return privata.Annotation|nil annotation  nil when the line carries no tag privata reads
---@return boolean trailing  true when the comment follows code on the same line
function _P.parse_line(text, number)
  local before, tag, rest = text:match("^(.-)%-%-%-+%s*@(%w+)%s*(.*)$")
  if tag == nil or not _P.TAGS[tag] then
    return nil, false
  end

  local name = nil
  local expression = rest

  if tag == "class" then
    -- `---@class (exact) pkg.Item : pkg.Base` declares `pkg.Item`; what follows
    -- the colon is somebody else's class, and this file does not own it.
    expression = rest:gsub("^%(%s*exact%s*%)%s*", ""):match("^[%w_%.]*")
  elseif tag == "param" or tag == "cast" then
    -- Both name the variable first and its type second.
    local written, remainder = rest:match("^([%w_%.]+)%??%s*(.*)$")
    if written == nil then
      return nil, false
    end
    name = written
    expression = remainder
  end

  return {
    kind = tag,
    name = name,
    types = _P.type_names(_P.type_expression(expression)),
    line = number,
  },
    before:find("%S") ~= nil
end

--- True for a line holding something other than blank space and a comment.
--
-- Matched on raw text, so a `--` inside a long string reads as a comment. That
-- can only move an attachment onto the wrong line, which drops a type edge and
-- leaves the finding privata would have reported anyway.
---@param text string
---@return boolean
function _P.is_code(text)
  return text:find("%S") ~= nil and text:find("^%s*%-%-") == nil
end

--- Every annotation in a file, each tied to the line of code it documents.
--
-- The attachment is what makes `---@type` usable at all: unlike `---@param` and
-- `---@cast`, it names no variable, so the only thing that says what it types is
-- the declaration underneath it.
--
-- A blank line does *not* end a block, though LuaLS treats it as ending one. The
-- two failures are not symmetric: crossing the gap can attach a `---@class` to a
-- table it does not describe, which credits a read that never happened and costs
-- a finding; refusing to cross it strands the annotation on a file written with
-- a blank line before its declaration, and every method on that class is
-- reported as unused. privata takes the direction that only ever loses a
-- finding, exactly as the reference scan does.
---@param source string  raw file contents
---@return privata.Annotation[]  in source order
function M.scan(source)
  local lines = lexer.source_lines(source)
  local found = {}
  local pending = {}

  ---@param number integer  the code line the waiting annotations describe
  local function attach(number)
    for i = 1, #pending do
      pending[i].attached_line = number
    end
    pending = {}
  end

  for number = 1, #lines do
    local text = lines[number]
    local annotation, trailing = _P.parse_line(text, number)

    if annotation == nil then
      if _P.is_code(text) then
        attach(number)
      end
    else
      found[#found + 1] = annotation
      if trailing then
        -- The code before the comment closes any block waiting above it, and is
        -- also what this annotation itself describes.
        attach(number)
        annotation.attached_line = number
      else
        pending[#pending + 1] = annotation
      end
    end
  end

  return found
end

--- Names each line of a chunk binds.
--
-- Every name on the line is credited: `local a, b = f()` under one `---@type` is
-- ambiguous, and crediting both can only cost a missed finding.
---@param chunk privata.Node  a Chunk node
---@return table<integer, string[]>  line number to the names declared on it
function _P.names_by_line(chunk)
  local out = {}

  ---@param node any  a declaration target, which is not always an identifier
  local function note(node)
    if ast.is_node(node) and node.kind == "Identifier" then
      ---@cast node privata.Identifier
      out[node.line] = out[node.line] or {}
      local list = out[node.line]
      list[#list + 1] = node.name
    end
  end

  ast.walk(chunk, function(node)
    if node.kind == "LocalDeclaration" then
      for i = 1, #node.names do
        note(node.names[i])
      end
    elseif node.kind == "Assignment" then
      for i = 1, #node.targets do
        note(node.targets[i])
      end
    end
  end)

  return out
end

--- Variables a file declares a type for, by variable name.
--
-- Scoped per file rather than per block, deliberately. Two functions in one file
-- taking a differently-typed `item` credit both types to both names, which
-- over-matches -- and over-matching costs only a missed finding, the safe
-- direction for a tool whose output is acted on by rewriting code. Block scoping
-- would buy precision in the direction that breaks working code.
---@param record privata.Module  needs `chunk` and `annotations` filled in
---@return table<string, table<string, boolean>>  variable name to its type names
function _P.typed_variables(record)
  local out = {}
  local by_line = nil

  ---@param name string
  ---@param types string[]
  local function add(name, types)
    out[name] = out[name] or {}
    for i = 1, #types do
      out[name][types[i]] = true
    end
  end

  local annotations = record.annotations or {}
  for i = 1, #annotations do
    local annotation = annotations[i]
    if annotation.kind == "param" or annotation.kind == "cast" then
      local name = annotation.name
      -- Both tags name their variable first, and `parse_line` drops one that
      -- does not, so a `param` or a `cast` that got this far has a name.
      ---@cast name string
      add(name, annotation.types)
    elseif annotation.kind == "type" and annotation.attached_line then
      by_line = by_line or _P.names_by_line(record.chunk)
      local names = by_line[annotation.attached_line] or {}
      for index = 1, #names do
        add(names[index], annotation.types)
      end
    end
  end

  return out
end

--- The class names a module declares for the table it exports.
--
-- Only the `---@class` sitting on the *returned* table counts. A file usually
-- declares several -- an options record, a result shape, an internal node -- and
-- those describe values this module does not publish. Crediting a read of one to
-- this module's interface would keep the wrong names public.
---@param record privata.Module
---@return string[]
function _P.exported_types(record)
  local out = {}
  local detected = record.shape
  if detected == nil or detected.public_line == nil then
    return out
  end

  local annotations = record.annotations or {}
  for i = 1, #annotations do
    local annotation = annotations[i]
    if annotation.kind == "class" and annotation.attached_line == detected.public_line then
      for index = 1, #annotation.types do
        out[#out + 1] = annotation.types[index]
      end
    end
  end

  return out
end

--- Which module owns each declared class name.
--
-- A name two modules declare maps to both. privata cannot resolve that -- both
-- files really do declare it -- and crediting both keeps the method public in
-- each, which is the direction that never breaks code.
---@param modules table<string, privata.Module>
---@return table<string, table<string, boolean>>  type name to the modules declaring it
function _P.type_owners(modules)
  local owners = {}
  for name, record in pairs(modules) do
    local types = _P.exported_types(record)
    for i = 1, #types do
      owners[types[i]] = owners[types[i]] or {}
      owners[types[i]][name] = true
    end
  end
  return owners
end

--- Every (module, field) pair a file reads through a type-annotated instance.
--
-- Both spellings count, because a rename breaks both: `item:position()` and
-- `item.line`.
---@param record privata.Module  needs `chunk` and `annotations` filled in
---@param owners table<string, table<string, boolean>>  from `type_owners`
---@return { module: string, name: string, line: integer }[]  deduplicated
function _P.instance_references(record, owners)
  local typed = _P.typed_variables(record)
  local found = {}
  local seen = {}

  -- The receiver has to be a bare local for its annotation to say anything:
  -- `a.b:run()` resolves to "a.b", which no `---@param` ever names.
  ---@param object privata.Node|nil  what the field was read from
  ---@param field string|nil         the name read off it
  ---@param line integer
  local function note(object, field, line)
    local variable = ast.dotted_name(object)
    if variable == nil or field == nil then
      return
    end
    local types = typed[variable]
    if types == nil then
      return
    end
    for type_name in pairs(types) do
      for module_name in pairs(owners[type_name] or {}) do
        local key = module_name .. "\0" .. field
        if not seen[key] then
          seen[key] = true
          found[#found + 1] = { module = module_name, name = field, line = line }
        end
      end
    end
  end

  ast.walk(record.chunk, function(node)
    if node.kind == "MethodCall" then
      note(node.object, node.method, node.method_line or node.line)
    elseif node.kind == "Index" and not node.computed and node.index.kind == "String" then
      note(node.object, node.index.value, node.field_line or node.line)
    end
  end)

  -- The walk is deterministic but the type and owner sets above are iterated
  -- with `pairs`, so the list is ordered here rather than left to hash order.
  table.sort(found, function(a, b)
    if a.module ~= b.module then
      return a.module < b.module
    end
    return a.name < b.name
  end)

  return found
end

--- Symbols kept public by a read through a type-annotated instance.
--
-- The instance counterpart of `_requires.cross_references`, answering the same
-- question under the same two rules: a module reading its own names is the
-- situation being reported rather than evidence against it, and only production
-- modules certify -- an annotation in a spec is as uncertifying as its calls.
---@param modules table<string, privata.Module>
---@return table<string, boolean>  set keyed `"module\0name"`
function M.cross_references(modules)
  local owners = _P.type_owners(modules)
  local used = {}

  -- Nothing in the project declares a class, so no annotation anywhere can
  -- resolve to a module. Skipping the walk keeps this free for the projects it
  -- has nothing to say about.
  if next(owners) == nil then
    return used
  end

  for consumer_name, record in pairs(modules) do
    if record.chunk then
      local references = _P.instance_references(record, owners)
      for i = 1, #references do
        local reference = references[i]
        if reference.module ~= consumer_name then
          used[reference.module .. "\0" .. reference.name] = true
        end
      end
    end
  end

  return used
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
