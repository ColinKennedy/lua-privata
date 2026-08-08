--- Shared vocabulary: finding shapes, name predicates, and sort order.
--
-- Lua has no dataclasses, so these are plain tables. What this module exists
-- for is the annotations and the two name predicates below: every check has an
-- opinion about what "private" means, and they must all be the same opinion.

local M = {}
local _P = {}

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
---@field recommendation table|nil  filled in by `_recommend` when reported
---@field test_read table|nil       where a spec reads it, if one does
---@field test_stub table|nil       where a spec replaces it, if one does
---@field string_mention table|nil  where its name appears in a string literal

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
---@field chunk table|nil      retained AST; every later stage walks this
---@field shape table|nil      what `_shape` made of the file
---@field symbols privata.Symbol[]
---@field private_symbols privata.Symbol[]
---@field ignored_lines table<integer, boolean>
---@field exports table<string, boolean>

---@class privata.Finding
---@field path string
---@field line integer

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

--- True for a name that its own module marks as internal.
--
-- A single leading underscore is the convention; a double underscore is a
-- metamethod, which is neither private nor a name anyone chose.
function M.is_private_name(name)
  if _P.CONVENTIONAL_PUBLIC_NAMES[name] then
    return false
  end
  return name:sub(1, 1) == "_" and name:sub(1, 2) ~= "__"
end

function M.is_metamethod(name)
  return name:sub(1, 2) == "__"
end

--- Order findings by file then position, so output is stable across runs and
--- across filesystems that hand back directory entries in different orders.
function _P.by_location(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  if a.line ~= b.line then
    return a.line < b.line
  end
  return tostring(a.name) < tostring(b.name)
end

function M.sort_findings(findings)
  table.sort(findings, _P.by_location)
  return findings
end

--- Pluralise a count for report text: `M.count(1, "symbol")` -> "1 symbol".
function M.count(number, singular, plural)
  if number == 1 then
    return "1 " .. singular
  end
  return number .. " " .. (plural or (singular .. "s"))
end

return M
