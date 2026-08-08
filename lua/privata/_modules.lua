--- Parse every production file once and extract what it binds.
--
-- Parsing dominates a scan, so each file is read and parsed exactly here, and
-- every later stage walks the AST this module retains. Failures are collected
-- in the same pass rather than by re-reading: a file privata could not read is
-- itself a finding, and one it had to read twice to discover that would be a
-- waste of the only expensive thing this tool does.

local ast = require("privata._ast")
local fs = require("privata._fs")
local lexer = require("privata._lexer")
local models = require("privata._models")
local parser = require("privata._parser")
local scope = require("privata._scope")
local shape = require("privata._shape")
local source_roots = require("privata._source_roots")

local M = {}
local _P = {}

M.IGNORE_COMMENT = "privata: ignore"

--- Line numbers carrying a `-- privata: ignore` comment.
--
-- Matched against raw source text rather than tokens because the lexer discards
-- comments, and a suppression that only worked when the line also held code
-- would be a surprising rule to explain.
function _P.ignored_lines(source)
  local ignored = {}
  local lines = lexer.source_lines(source)
  for number = 1, #lines do
    if lines[number]:find(M.IGNORE_COMMENT, 1, true) then
      ignored[number] = true
    end
  end
  return ignored
end

--- The field name a target assigns on `holder`, or nil.
--
-- Only a direct, non-computed field counts: `M.a` yields "a", while `M.a.b`
-- yields "a" as well, because the interface `M` publishes is `a` either way.
-- `M[k]` yields nil -- privata will not invent a name it cannot read.
function _P.field_on(target, holder)
  local node = target
  local field
  while ast.is_node(node) and node.kind == "Index" do
    if node.computed or node.index.kind ~= "String" then
      return nil
    end
    field = node.index.value
    if ast.is_node(node.object) and node.object.kind == "Identifier" then
      if node.object.name == holder then
        return field, node.field_line or node.line
      end
      return nil
    end
    node = node.object
  end
  return nil
end

function _P.value_kind(value)
  if value == nil then
    return models.KINDS.VALUE
  end
  if value.kind == "FunctionExpr" then
    return models.KINDS.FUNCTION
  end
  if value.kind == "TableExpr" then
    return models.KINDS.TABLE
  end
  return models.KINDS.VALUE
end

--- Collect fields assigned onto `holder` at any depth in the file.
--
-- Assignments inside an `if` or a loop still build the module's interface, so
-- the whole chunk is walked rather than only its top level. Nested function
-- bodies are included for the same reason: `function M.setup() M.ready = true
-- end` publishes `ready`.
function _P.fields_assigned(chunk, holder)
  local found = {}
  local order = {}

  -- `end_line` is kept for function values so a later stage can tell a
  -- self-recursive definition from one merely used further down the file: the
  -- two need different privatisation forms.
  local function record(name, line, kind, value)
    if name == nil or found[name] then
      return
    end
    found[name] = {
      name = name,
      line = line,
      kind = kind,
      end_line = value and value.kind == "FunctionExpr" and value.end_line or line,
    }
    order[#order + 1] = found[name]
  end

  ast.walk(chunk, function(node)
    if node.kind == "FunctionDeclaration" then
      local name, line = _P.field_on(node.target, holder)
      record(name, line or node.line, models.KINDS.FUNCTION, node.func)
    elseif node.kind == "Assignment" then
      for i = 1, #node.targets do
        local name, line = _P.field_on(node.targets[i], holder)
        record(name, line or node.line, _P.value_kind(node.values[i]), node.values[i])
      end
    end
  end)

  return order
end

--- Lines where `holder.name` is read, rather than assigned.
--
-- The report names these, because acting on a finding in Lua means rewriting
-- every reader as well as the definition -- unlike a Python rename, which the
-- interpreter resolves for you.
function _P.field_reads(chunk, holder)
  local reads = {}
  local assigned_nodes = {}

  ast.walk(chunk, function(node)
    if node.kind == "Assignment" then
      for i = 1, #node.targets do
        assigned_nodes[node.targets[i]] = true
      end
    elseif node.kind == "FunctionDeclaration" then
      assigned_nodes[node.target] = true
    end
  end)

  ast.walk(chunk, function(node)
    if node.kind == "Index" and not assigned_nodes[node] then
      local name = _P.field_on(node, holder)
      if name then
        reads[name] = reads[name] or {}
        local line = node.field_line or node.line
        reads[name][#reads[name] + 1] = line
      end
    elseif node.kind == "MethodCall" then
      -- `M.helper:run()` reads `helper`; the method name belongs to whatever
      -- `helper` holds and is the method check's business, not this one's.
      local name = _P.field_on(node.object, holder)
      if name then
        reads[name] = reads[name] or {}
        reads[name][#reads[name] + 1] = node.line
      end
    end
  end)

  for _, lines in pairs(reads) do
    table.sort(lines)
  end
  return reads
end

--- Names a literal `return { a = a }` table publishes, with their lines.
function _P.literal_fields(literal_node)
  local out = {}
  for i = 1, #literal_node.fields do
    local field = literal_node.fields[i]
    if field.key ~= nil and not field.computed and field.key.kind == "String" then
      out[#out + 1] = {
        name = field.key.value,
        line = field.line,
        kind = _P.value_kind(field.value),
        value = field.value,
      }
    end
  end
  return out
end

--- Build the symbol lists for one parsed module.
function _P.extract_symbols(module_record)
  local chunk = module_record.chunk
  local detected = module_record.shape
  local symbols = {}
  local private_symbols = {}

  local function add(list, entry, namespace, reads)
    list[#list + 1] = {
      name = entry.name,
      path_name = namespace .. "." .. entry.name,
      kind = entry.kind,
      namespace = namespace,
      line = entry.line,
      end_line = entry.end_line or entry.line,
      module = module_record.name,
      path = module_record.path,
      uses = reads and reads[entry.name] or {},
    }
  end

  if detected.kind == shape.KINDS.LITERAL then
    -- A literal that is not a re-export list is data, not an interface. Its
    -- fields cannot be made private without deleting them.
    if not detected.is_reexport_table then
      return symbols, private_symbols
    end
    local fields = _P.literal_fields(detected.literal)
    for i = 1, #fields do
      local entry = fields[i]
      if models.is_private_name(entry.name) then
        add(private_symbols, entry, "return", nil)
      else
        add(symbols, entry, "return", nil)
      end
    end
    return symbols, private_symbols
  end

  local public_name = detected.public_name
  local public_reads = _P.field_reads(chunk, public_name)
  local public_fields = _P.fields_assigned(chunk, public_name)

  for i = 1, #public_fields do
    local entry = public_fields[i]
    -- `__index` and friends are behaviour, not interface: nobody requires a
    -- module to call its metamethods by name.
    if not models.is_metamethod(entry.name) then
      if models.is_private_name(entry.name) then
        add(private_symbols, entry, public_name, public_reads)
      else
        add(symbols, entry, public_name, public_reads)
      end
    end
  end

  if detected.private_name then
    local private_reads = _P.field_reads(chunk, detected.private_name)
    local private_fields = _P.fields_assigned(chunk, detected.private_name)
    for i = 1, #private_fields do
      add(private_symbols, private_fields[i], detected.private_name, private_reads)
    end
  end

  return symbols, private_symbols
end

--- Read and parse one file into a module record.
function _P.load_module(path, root, module_name, config)
  local source, read_error = fs.read_file(path)
  if source == nil then
    return nil, { module = module_name, path = path, line = 0, message = read_error }
  end

  local chunk, parse_error = parser.parse(source)
  if chunk == nil then
    return nil,
      {
        module = module_name,
        path = path,
        line = parse_error.line,
        message = parse_error.message,
      }
  end

  local record = {
    name = module_name,
    path = path,
    source_root = root,
    package_parts = source_roots.package_parts(module_name),
    chunk = chunk,
    ignored_lines = _P.ignored_lines(source),
    shape = shape.detect(chunk, config),
    scope = scope.analyze(chunk),
    symbols = {},
    private_symbols = {},
    exports = {},
  }

  if record.shape.kind ~= nil then
    record.symbols, record.private_symbols = _P.extract_symbols(record)
    for i = 1, #record.symbols do
      record.exports[record.symbols[i].name] = true
    end
  end

  return record
end

--- True when `path` sits under one of the configured `exclude` entries.
--
-- Matched against the project root rather than the source root, because that is
-- where a user writing `lua/pkg/generated` is counting from -- and a scan can
-- have several source roots, so a source-root-relative rule would be ambiguous.
function _P.is_excluded(path, config, project_root)
  local excluded = config.exclude or {}
  for i = 1, #excluded do
    if fs.is_within(path, fs.join(project_root, excluded[i])) then
      return true
    end
  end
  return false
end

--- Every production file under `roots`, with test files and exclusions gone.
--
-- `name_root` is where module names are counted from, which is not always the
-- source root. A helper at `spec/support/project.lua` is required by its
-- co-located specs as `spec.support.project`, because busted runs from the
-- project root -- naming it `support.project` would leave every reference to it
-- unresolvable, and the helper would look unused.
function _P.production_files(roots, config, project_root, name_root)
  local out = {}
  local skip = source_roots.production_skip()

  for root_index = 1, #roots do
    local root = roots[root_index]
    local files = fs.list_lua_files(root, skip)
    for i = 1, #files do
      local path = files[i]
      if
        not source_roots.is_test_filename(fs.basename(path))
        and not _P.is_excluded(path, config, project_root)
      then
        local module_name = source_roots.module_name(path, name_root or root)
        if module_name then
          out[#out + 1] = { path = path, root = root, module_name = module_name }
        end
      end
    end
  end

  return out
end

--- Parse every production file under `roots`.
--
-- Returns the modules by dotted name, the files that could not be parsed, and
-- the files whose module shape privata declined to guess at.
function M.collect(roots, config, project_root, options)
  options = options or {}
  local modules = {}
  local unparsable = {}
  local unanalyzable = {}
  local files = _P.production_files(roots, config, project_root, options.name_root)

  for i = 1, #files do
    local entry = files[i]
    local record, failure = _P.load_module(entry.path, entry.root, entry.module_name, config)
    if record == nil then
      unparsable[#unparsable + 1] = failure
    else
      if record.shape.kind == nil then
        unanalyzable[#unanalyzable + 1] = {
          module = entry.module_name,
          path = entry.path,
          line = record.shape.line or 1,
          reason = record.shape.reason,
        }
      end
      record.is_test_helper = options.is_test_helper or false
      modules[entry.module_name] = record
    end
  end

  return modules, unparsable, unanalyzable
end

--- Module names produced by more than one file.
--
-- Only one file per name can be scanned, so the others silently stop
-- contributing references. Files are not parsed here: a file with broken syntax
-- still occupies its module name.
function M.collisions(roots, config, project_root)
  local paths_by_name = {}
  local files = _P.production_files(roots, config, project_root, nil)

  for i = 1, #files do
    local entry = files[i]
    paths_by_name[entry.module_name] = paths_by_name[entry.module_name] or {}
    local list = paths_by_name[entry.module_name]
    list[#list + 1] = entry.path
  end

  local out = {}
  for name, paths in pairs(paths_by_name) do
    if #paths > 1 then
      table.sort(paths)
      out[#out + 1] = { module = name, paths = paths }
    end
  end
  table.sort(out, function(a, b)
    return a.module < b.module
  end)
  return out
end

--- Parse arbitrary files as consumers only, by path.
--
-- Installed scripts live outside every source root -- a rockspec points at
-- `bin/thing.lua` -- but they do require modules, and those requires are real
-- uses. Ignoring them would report a CLI's entry function as unused.
function M.collect_path_consumers(paths)
  local consumers = {}
  for i = 1, #paths do
    local source = fs.read_file(paths[i])
    if source then
      local chunk = parser.parse(source)
      if chunk then
        consumers[#consumers + 1] = {
          name = "\0script:" .. paths[i],
          path = paths[i],
          chunk = chunk,
          package_parts = {},
        }
      end
    end
  end
  return consumers
end

--- Parse test files as consumers only.
--
-- A test file is never a source of symbols, only of references. That asymmetry
-- is the whole of "test usage does not confer publicity": these files can point
-- at a name, but nothing they contain becomes part of an interface.
function M.collect_test_consumers(test_roots, project_root)
  local consumers = {}
  local skip = source_roots.test_skip()

  for root_index = 1, #test_roots do
    local root = test_roots[root_index]
    local files = fs.list_lua_files(root, skip)
    for i = 1, #files do
      local path = files[i]
      local source = fs.read_file(path)
      if source then
        local chunk = parser.parse(source)
        if chunk then
          -- Named from the project root, matching how a spec requires it.
          local relative = fs.relative(path, project_root) or fs.basename(path)
          local name = relative:gsub("%.lua$", ""):gsub("/", ".")
          consumers[#consumers + 1] = {
            name = name,
            path = path,
            source_root = root,
            package_parts = source_roots.package_parts(name),
            chunk = chunk,
            is_test_file = source_roots.is_test_filename(fs.basename(path)),
          }
        end
      end
    end
  end

  return consumers
end

return M
