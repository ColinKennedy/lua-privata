--- Shared vocabulary: finding shapes, name predicates, and sort order.
--
-- Lua has no dataclasses, so these are plain tables. What this module exists
-- for is the annotations and the two name predicates below: every check has an
-- opinion about what "private" means, and they must all be the same opinion.

local M = {}
local _P = {}

--- One AST node, as `_parser` builds them.
--
-- Declared as the union of every kind's fields rather than one class per kind:
-- `kind` is what the code branches on, and a per-kind hierarchy would mean a
-- cast at every branch without making any of them safer. The comment on each
-- field names the kinds that carry it.
---@class privata.Node
-- Only `kind` and `line` are on every node; the rest are declared optional and
-- the comment names the kinds that carry them. Optional here means "absent on
-- other kinds", not "may be missing on its own" -- every reader narrows on
-- `kind` first, and the two fields that really can be absent say so.
---@class privata.Node
---@field kind string          which node this is; see `_ast.CHILDREN`
---@field line integer         where the construct starts
---@field body? privata.Node[]          Chunk, Do, While, Repeat, IfClause, For, FunctionExpr
---@field cond? privata.Node            While, Repeat, IfClause
---@field clauses? privata.Node[]       IfStatement
---@field else_body? privata.Node[]     IfStatement; absent without an `else`
---@field names? privata.Identifier[]   LocalDeclaration, GenericFor
---@field attribs? (string|false)[]     LocalDeclaration; 5.4 `<const>` / `<close>`
---@field values? privata.Node[]        LocalDeclaration, Assignment, Return
---@field targets? privata.Node[]       Assignment
---@field target? privata.Node          FunctionDeclaration
---@field func? privata.Node            LocalFunction, FunctionDeclaration
---@field name? privata.Identifier|string  a node on LocalFunction, a string on Identifier and Label
---@field label? string                 GotoStatement
---@field var? privata.Identifier       NumericFor
---@field start? privata.Node           NumericFor
---@field limit? privata.Node           NumericFor
---@field step? privata.Node            NumericFor; absent when the loop declares none
---@field exprs? privata.Node[]         GenericFor
---@field expr? privata.Node            CallStatement, Paren
---@field params? privata.Identifier[]  FunctionExpr
---@field is_vararg? boolean            FunctionExpr
---@field is_method? boolean            FunctionExpr, FunctionDeclaration
---@field end_line? integer             FunctionExpr; line of its `end`
---@field fields? privata.Node[]        TableExpr
---@field key? privata.Node             TableField; absent for a positional entry
---@field value? any                    String, Number and TableField all carry one
---@field raw? string                   String, Number; the source text
---@field long? boolean                 String; absent on one the parser synthesised
---@field synthetic? boolean            String the parser made from a field name
---@field op? string                    BinaryOp, UnaryOp
---@field left? privata.Node            BinaryOp
---@field right? privata.Node           BinaryOp
---@field operand? privata.Node         UnaryOp
---@field object? privata.Node          Index, MethodCall
---@field index? privata.Node           Index; the key expression
---@field computed? boolean             Index, TableField; true for `a[k]`
---@field field_line? integer           Index; absent on a computed `a[k]`
---@field callee? privata.Node          Call
---@field args? privata.Node[]          Call, MethodCall
---@field method? string                MethodCall
---@field method_line? integer          MethodCall

--- An `Identifier` node, narrowed so its `name` is known to be a string.
--
-- Worth its own class because the parser puts a *node* under `name` on a
-- `LocalFunction` and a *string* there on an `Identifier`, and the fields that
-- only ever hold identifiers -- parameters, loop variables, declared names --
-- are read for their string constantly.
---@class privata.Identifier : privata.Node
---@field name string
---@field col? integer       absent on the implicit `self`, which has no source text
---@field implicit? boolean  the `self` a method declaration never wrote
---@field vararg? boolean    the `...` parameter

--- One LuaCATS tag, with the line of code it describes.
--
-- `attached_line` is the whole reason this is a record rather than a pair: a
-- `---@type` names no variable, so what it types is decided by the declaration
-- underneath it and nothing else.
---@class privata.Annotation
---@field kind string             "class", "param", "type" or "cast"
---@field name string|nil         the variable a `param` or a `cast` names
---@field types string[]          every type name written in the annotation
---@field line integer            where the comment is written
---@field attached_line integer|nil  the code line it describes; nil when there is none

--- A file location, as the report prints it.
---@class privata.Location
---@field path string
---@field line integer

---@class privata.Symbol
---@field name string          field name as written, e.g. "helper"
---@field path_name string     full path on its table, e.g. "M.helper"
---@field kind string          one of M.KINDS
---@field namespace string     table the name lives on: "M", "_P", "_G", ...
---@field line integer
---@field module string
---@field path string
---@field uses integer[]       lines inside the defining module that read it
---@field end_line integer     last line of a function value, for recursion checks
---@field recommendation privata.Recommendation|nil  filled in by `_recommend` when reported
---@field is_method boolean       declared `function C:m()`, so `self` is implicit
---@field test_read privata.Location|nil       where a spec reads it, if one does
---@field test_stub privata.Location|nil       where a spec replaces it, if one does
---@field string_mention privata.Location|nil  where its name appears in a string literal

---@class privata.Method
---@field name string
---@field class_name string
---@field line integer
---@field module string
---@field path string
---@field class_line integer
---@field class_public_methods integer

---@class privata.Module
---@field name string          dotted module name, e.g. "pkg.service"
---@field path string
---@field source_root string
---@field package_parts string[]
---@field chunk privata.Node|nil  retained AST; every later stage walks this
---@field annotations privata.Annotation[]|nil  LuaCATS tags read from raw source
---@field shape privata.Shape|nil what `_shape` made of the file
---@field scope privata.ScopeReport|nil  what `_scope` made of its name bindings
---@field symbols privata.Symbol[]
---@field private_symbols privata.Symbol[]
---@field ignored_lines table<integer, boolean>
---@field used_ignores table<integer, boolean>  lines whose ignore suppressed something
---@field bare_ignores table<integer, boolean>  ignored lines holding no code
---@field exports table<string, boolean>
---@field is_test_helper boolean|nil  true for a helper co-located with the specs

---@class privata.Finding
---@field path string
---@field line integer
---@field name string|nil  present on most kinds; the last tiebreak when sorting

--- How privata suggests a symbol be made private.
---@class privata.Recommendation
---@field strategy string        "namespace", "local_function" or "underscore_field"
---@field text string            the one-line instruction printed in the report
---@field notes string[]         caveats: a forward declaration needed, a spec to update
---@field namespace string|nil   the table to move into, on a namespace recommendation

--- What `_shape` made of a file. Exactly one of `kind` and `reason` is set.
---@class privata.Shape
---@field kind string|nil        one of `_shape.KINDS` when the file could be read
---@field reason string|nil      one of `models.UNANALYZABLE` when it could not
---@field line integer|nil       where to point when reporting a `reason`
---@field public_name string|nil the local name of the returned table or function;
---                              absent when a FUNCTION shape returns an unnamed one
---@field public_line integer|nil where that local is declared
---@field return_line integer|nil where the file returns it
---@field private_name string|nil the private namespace, when the file declares one
---@field table_locals table<string, { name: string, line: integer }>|nil
---@field literal privata.Node|nil        the returned TableExpr, on a LITERAL shape
---@field is_reexport_table boolean|nil   whether that literal is `{ a = a }`

--- A file scanned only for the references it makes, never for symbols.
---@class privata.Consumer
---@field name string             dotted name, or `"\0script:<path>"` for a bin script
---@field path string
---@field chunk privata.Node      retained AST
---@field package_parts string[]
---@field source_root string|nil  the test root it was found under, where there is one
---@field is_test_file boolean|nil true when its filename marks it a spec

--- The effective configuration for one scan.
--
-- Layered defaults < preset < `tach.lua` < `.privata.lua` < command line, each
-- layer replacing a key outright. See `_config.defaults` for the values.
---@class privata.Config
---@field preset string|nil                name of the applied preset
---@field source_roots string[]|nil        nil means "discover them"
---@field test_roots string[]
---@field exclude string[]                 paths relative to the project root
---@field privatize string[]               strategies in the order they are tried
---@field namespace string                 the private table to recommend
---@field local_function_style string      "statement" or "assignment"
---@field local_function_forward_decl boolean  may a recommendation add a forward local
---@field max_locals integer               ceiling below Lua's own 200-local limit
---@field private_module_patterns string[] patterns marking a module segment private
---@field package_private string[]         prefixes inside which siblings may reach in
---@field fail_on string[]                 finding kinds that make the run exit non-zero
---@field globals string[]                 global names the project allows
---@field interfaces privata.InterfaceEntry[]  what each module publishes on purpose
---@field modules privata.ModuleEntry[]        tach's module table; read for `unchecked`
---@field methods boolean                  the `--methods` spelling of `checks.methods`
---@field ignore_methods boolean            never report a `function C:m()` declaration
---@field skip_unparsable_files boolean
---@field skip_module_collisions boolean
---@field format string                    "text" or "json"
---@field checks table<string, boolean>    which checks report at all

--- One `[[interfaces]]` entry, spelled exactly as `tach.toml` spells it.
--
-- `expose` and `from` are regular expressions matching a whole name, and they
-- are the two privata reads: a symbol stays public when one entry's `from`
-- matches its module and that same entry's `expose` matches its name. The rest
-- are accepted so one table can serve both tools, and describe which module may
-- import the interface -- a question privata does not ask.
---@class privata.InterfaceEntry
---@field expose string[]            names this interface publishes
---@field from string[]|nil          modules that adopt it; every module by default
---@field visibility string[]|nil    unused by privata
---@field data_types string|nil      unused by privata; "all" or "primitive"
---@field exclusive boolean|nil      unused by privata

--- One `[[modules]]` entry, spelled exactly as `tach.toml` spells it.
--
-- `path`/`paths` are module globs, and `unchecked` is the field privata reads:
-- it means no finding is reported inside the module. The dependency fields
-- describe an import graph, which is tach's subject and not privata's.
---@class privata.ModuleEntry
---@field path string|nil                       a dotted module path or glob
---@field paths string[]|nil                    shorthand for several of them
---@field unchecked boolean|nil                 report nothing inside this module
---@field depends_on (string|table)[]|nil       unused by privata
---@field cannot_depend_on (string|table)[]|nil unused by privata
---@field depends_on_external string[]|nil      unused by privata
---@field cannot_depend_on_external string[]|nil unused by privata
---@field layer string|nil                      unused by privata
---@field visibility string[]|nil               unused by privata
---@field utility boolean|nil                   unused by privata

---@class privata.UnparsableFinding
---@field module string
---@field path string
---@field line integer
---@field message string

---@class privata.CollisionFinding
---@field module string        the dotted name two or more files claim
---@field paths string[]       sorted

---@class privata.UnanalyzableFinding
---@field module string
---@field path string
---@field line integer
---@field reason string        one of `models.UNANALYZABLE`

---@class privata.GlobalFinding
---@field name string
---@field kind string          one of `M.KINDS`
---@field explicit boolean     written as `_G.name`, rather than a missing `local`
---@field module string
---@field path string
---@field line integer

--- A module that returns the very table the config calls private.
---@class privata.ExportedNamespaceFinding
---@field module string
---@field path string
---@field line integer
---@field namespace string
---@field name string                      the same as `namespace`, for sorting
---@field public_table string|nil          a non-private table the file also declares
---@field public_symbols integer           how many fields this publishes
---@field consumed boolean                 whether production code reads the return
---@field advisory boolean                 true when no fix would improve the file
---@field test_handle privata.Location|nil where a spec holds the table

--- A module whose whole export is a function, that nothing requires.
--
-- The module-level twin of an unread public field: a file returning a function
-- publishes no fields, so the require is the only evidence it is used, and the
-- remedy is a rename of the module rather than a move of a symbol.
---@class privata.FunctionModuleFinding
---@field module string
---@field path string
---@field line integer               where the returned function is written
---@field name string                its local name, or the module's last segment
---@field anonymous boolean          true when the file returns an unnamed function
---@field private_module string|nil  the private name to rename to, when one can be derived
---@field test_require privata.Location|nil  where a spec requires it, if one does

--- An `-- privata: ignore` that suppressed nothing this run.
---@class privata.StaleIgnoreFinding
---@field module string
---@field path string
---@field line integer
---@field bare boolean  true when the comment sits on a line holding no code

---@class privata.PrivateModuleRequireFinding
---@field module string             the private module being required
---@field path string               where that module lives
---@field required_by string
---@field required_by_path string
---@field line integer              the `require` line, in the requiring file
---@field name string               the same as `module`, for sorting

---@class privata.PrivateSymbolReadFinding
---@field module string             the module owning the private name
---@field name string
---@field path string               where that name is defined
---@field read_by string
---@field read_by_path string
---@field line integer              the read line, in the reading file

---@class privata.ExportIssueFinding
---@field module string
---@field path string
---@field name string               the name in the returned table
---@field binding string            the local it names
---@field kind string               "unknown", "private" or "missing"
---@field line integer

--- Everything one scan found, in the order the report prints it.
---@class privata.Findings
---@field roots string[]                                the source roots scanned
---@field unparsable privata.UnparsableFinding[]
---@field collisions privata.CollisionFinding[]
---@field unanalyzable privata.UnanalyzableFinding[]
---@field exported_namespaces privata.ExportedNamespaceFinding[]
---@field function_modules privata.FunctionModuleFinding[]
---@field symbols privata.Symbol[]
---@field globals privata.GlobalFinding[]
---@field private_module_requires privata.PrivateModuleRequireFinding[]
---@field private_symbol_reads privata.PrivateSymbolReadFinding[]
---@field export_issues privata.ExportIssueFinding[]
---@field methods privata.Method[]
---@field stale_ignores privata.StaleIgnoreFinding[]

--- The comment that suppresses a finding on the line it is written on.
--
-- Defined here rather than where it is matched, so the check that reads it and
-- the report that tells a user to delete it cannot drift apart.
M.IGNORE_COMMENT = "privata: ignore"

--- The private namespace privata recommends when a config does not say
--- otherwise. Defined here so `_config` and `_shape` cannot drift apart: one
--- of them deciding the default is `_P` while the other assumes nothing would
--- mean a file's own `_P` went unrecognised.
M.DEFAULT_NAMESPACE = "_P"

--- What a public name is bound to. Only used for wording a report; no check
--- branches on it, because a table and a function leak an interface alike.
M.KINDS = {
  FUNCTION = "function",
  TABLE = "table",
  VALUE = "value",
}

--- Where a binding lives. `_G` is its own namespace because a global is public
--- to the entire process, not merely to whoever requires the module.
_P.NAMESPACES = {
  PUBLIC = "M",
  GLOBAL = "_G",
}

--- Reasons `_shape` gives up on a file. Reported rather than guessed at: a
--- wrong shape inference mislabels every symbol in the file at once.
M.UNANALYZABLE = {
  MULTIPLE_RETURNS = "returns more than one value",
  CONDITIONAL_RETURN = "returns from more than one place",
  COMPUTED_RETURN = "returns a table this scan cannot read statically",
  LEGACY_MODULE = "uses the 5.1 module() function",
}

--- Underscore-led names that Lua convention makes public anyway.
--
-- `_VERSION` is what the language itself calls the version string, and rocks
-- follow it. Reporting a module for using the conventional name would be
-- telling users to break a convention to satisfy a linter.
_P.CONVENTIONAL_PUBLIC_NAMES = {
  _VERSION = true,
  _NAME = true,
  _DESCRIPTION = true,
  _COPYRIGHT = true,
  _LICENSE = true,
}

--- True when the file suppresses a finding on `line`, recording that it did.
--
-- Every check asks this rather than reading `ignored_lines` itself, which is
-- what lets privata tell a suppression that is doing work from one left behind
-- by a finding somebody already fixed. The recording is a side effect on the
-- record, and it is here rather than in each check for the reason the two name
-- predicates are: the checks must all agree on what an ignore means, and one of
-- them forgetting to mark would report a live suppression as removable.
--
-- Ask this *last* in a condition. A finding privata dropped for another reason
-- was never suppressed by the comment, and crediting the comment for it would
-- hide the very staleness this exists to find.
---@param record privata.Module
---@param line integer
---@return boolean
function M.is_ignored(record, line)
  if not record.ignored_lines[line] then
    return false
  end
  record.used_ignores[line] = true
  return true
end

--- True for a name that its own module marks as internal.
--
-- A single leading underscore is the convention; a double underscore is a
-- metamethod, which is neither private nor a name anyone chose.
---@param name string
---@return boolean
function M.is_private_name(name)
  if _P.CONVENTIONAL_PUBLIC_NAMES[name] then
    return false
  end
  return name:sub(1, 1) == "_" and name:sub(1, 2) ~= "__"
end

--- True for a `__`-led name, which Lua reserves for metamethods.
--
-- Separate from `is_private_name` because a metamethod is not a privacy
-- decision anyone made: it is the name the language requires.
---@param name string
---@return boolean
function M.is_metamethod(name)
  return name:sub(1, 2) == "__"
end

--- Order findings by file then position, so output is stable across runs and
--- across filesystems that hand back directory entries in different orders.
---@param a privata.Finding
---@param b privata.Finding
---@return boolean
function _P.by_location(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  if a.line ~= b.line then
    return a.line < b.line
  end
  return tostring(a.name) < tostring(b.name)
end

--- Sort a finding list in place by location, and hand it back for chaining.
---@param findings privata.Finding[]
---@return privata.Finding[]  the same list, sorted
function M.sort_findings(findings)
  table.sort(findings, _P.by_location)
  return findings
end

--- Pluralise a count for report text: `M.count(1, "symbol")` -> "1 symbol".
---@param number integer
---@param singular string
---@param plural string|nil  irregular plural; defaults to `singular .. "s"`
---@return string
function M.count(number, singular, plural)
  if number == 1 then
    return "1 " .. singular
  end
  return number .. " " .. (plural or (singular .. "s"))
end

return M
