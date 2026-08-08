--- Human-readable report.
--
-- Sections print in the order the checker collected them, which puts the two
-- unreliable-scan conditions first. That order is deliberate: when a file could
-- not be read, every finding below it may be wrong, and a reader has to know
-- that before acting on any of them.

local fs = require("privata._fs")
local models = require("privata._models")

local M = {}
local _P = {}

local INDENT = "      "
local WIDTH = 94

function _P.relative(path, project_root)
  return fs.relative(path, project_root) or path
end

--- Wrap a comma-joined list so the indented detail lines stay readable.
function _P.wrap(items, width)
  local lines = {}
  local current = ""
  for i = 1, #items do
    local piece = items[i] .. (i < #items and "," or "")
    if current == "" then
      current = piece
    elseif #current + 1 + #piece > width then
      lines[#lines + 1] = current
      current = piece
    else
      current = current .. " " .. piece
    end
  end
  if current ~= "" then
    lines[#lines + 1] = current
  end
  return lines
end

function _P.section(out, heading)
  if #out > 0 then
    out[#out + 1] = ""
  end
  out[#out + 1] = heading
  out[#out + 1] = ""
end

function _P.unparsable(out, findings, project_root, config)
  local verb = config.skip_unparsable_files and "warning" or "error"
  _P.section(
    out,
    string.format(
      "%s: found %s that could not be parsed; a skipped file stops contributing "
        .. "references, so findings below may be wrong:",
      verb,
      models.count(#findings, "source file")
    )
  )
  for i = 1, #findings do
    local entry = findings[i]
    out[#out + 1] =
      string.format("  %s:%d: %s", _P.relative(entry.path, project_root), entry.line, entry.message)
  end
end

function _P.collisions(out, findings, project_root, config)
  local verb = config.skip_module_collisions and "warning" or "error"
  _P.section(
    out,
    string.format(
      "%s: found %s defined by more than one file; only one file per name is "
        .. "scanned, so privata may have read the wrong one:",
      verb,
      models.count(#findings, "module name")
    )
  )
  for i = 1, #findings do
    local entry = findings[i]
    local paths = {}
    for index = 1, #entry.paths do
      paths[index] = _P.relative(entry.paths[index], project_root)
    end
    out[#out + 1] =
      string.format("  module `%s` is defined by: %s", entry.module, table.concat(paths, ", "))
  end
end

function _P.unanalyzable(out, findings, project_root)
  _P.section(
    out,
    string.format(
      "Found %s whose module shape could not be determined:",
      models.count(#findings, "file")
    )
  )
  for i = 1, #findings do
    local entry = findings[i]
    out[#out + 1] =
      string.format("  %s:%d: %s", _P.relative(entry.path, project_root), entry.line, entry.reason)
  end
end

--- Report a module that returns the table the config calls private.
--
-- Printed above the symbol list, and the offending file contributes nothing to
-- that list, so this is the first and only thing said about it. Everything else
-- privata could say about the file follows from this being fixed first, and the
-- remedy is spelled out rather than implied: a reader -- or a tool acting on the
-- report -- should not have to infer what to rename it to.
function _P.exported_namespaces(out, findings, project_root)
  local blocking, advisory = {}, {}
  for i = 1, #findings do
    local bucket = findings[i].advisory and advisory or blocking
    bucket[#bucket + 1] = findings[i]
  end

  if #blocking > 0 then
    _P.exported_namespace_group(out, blocking, project_root, true)
  end
  if #advisory > 0 then
    _P.exported_namespace_group(out, advisory, project_root, false)
  end
end

function _P.exported_namespace_group(out, findings, project_root, blocking)
  _P.section(
    out,
    blocking
        and string.format(
          "Found %s exporting the namespace configured as private; "
            .. "fix this before anything else in the file:",
          models.count(#findings, "module")
        )
      or string.format(
        "Found %s returning the private namespace as a test handle "
          .. "(nothing in production reads it; advisory, never blocks):",
        models.count(#findings, "module")
      )
  )
  for i = 1, #findings do
    local entry = findings[i]
    local surface = entry.public_symbols == 1 and "its 1 field is public"
      or string.format("all %d fields on it are public", entry.public_symbols)
    out[#out + 1] = string.format(
      "  %s:%d: returns `%s`, so %s",
      _P.relative(entry.path, project_root),
      entry.line,
      entry.namespace,
      surface
    )

    if not entry.consumed and entry.test_handle then
      -- A test holds the table and production does not, so both of the obvious
      -- remedies are wrong: returning nothing breaks the spec, and renaming to
      -- `M` publishes every field. Naming the seam publishes exactly one, which
      -- is narrower than either -- and it is the idiom, not an invention.
      out[#out + 1] = INDENT
        .. string.format(
          "held by %s:%d, and no production module reads it",
          _P.relative(entry.test_handle.path, project_root),
          entry.test_handle.line
        )
      out[#out + 1] = INDENT
        .. string.format(
          "if that is deliberate, say so: `local M = {}; M.%s = %s; return M`",
          entry.namespace,
          entry.namespace
        )
    elseif not entry.consumed then
      -- Nothing reads this return value at all. Here "return nothing" really is
      -- available, and it is the narrowest thing the file can do.
      out[#out + 1] = INDENT .. "no production module reads this return value"
      out[#out + 1] = INDENT .. "return nothing, or rename to `M` if you intend a public interface"
    elseif entry.public_table then
      out[#out + 1] = INDENT
        .. string.format(
          "merge `%s` into `%s` and return `%s`; keep `%s` for what stays private",
          entry.namespace,
          entry.public_table,
          entry.public_table,
          entry.namespace
        )
    else
      out[#out + 1] = INDENT
        .. string.format(
          "rename the returned table to `M`; keep `%s` for what stays private",
          entry.namespace
        )
    end
  end
end

function _P.symbols(out, findings, project_root)
  _P.section(
    out,
    string.format("Found %s that could be made private:", models.count(#findings, "public symbol"))
  )
  -- The namespace-declaration hint is per file, not per symbol. Printed once
  -- per finding it accounted for eighty-odd identical lines on a real repo.
  local hinted = {}
  for i = 1, #findings do
    local symbol = findings[i]
    local recommendation = symbol.recommendation
    out[#out + 1] = string.format(
      "  %s:%d: %s `%s` -> %s",
      _P.relative(symbol.path, project_root),
      symbol.line,
      symbol.kind,
      symbol.path_name,
      recommendation and recommendation.text or "make it private"
    )

    if #symbol.uses > 0 then
      local marks = {}
      for index = 1, #symbol.uses do
        marks[index] = ":" .. symbol.uses[index]
      end
      -- Acting on this means rewriting the readers too, not only the
      -- definition, so the readers are named. The label sits on the first line,
      -- so it has to come out of that line's budget.
      local label = "also read at "
      local wrapped = _P.wrap(marks, WIDTH - #INDENT - #label)
      out[#out + 1] = INDENT .. label .. wrapped[1]
      for index = 2, #wrapped do
        out[#out + 1] = INDENT .. string.rep(" ", #label) .. wrapped[index]
      end
    end

    if recommendation then
      for index = 1, #recommendation.notes do
        local note = recommendation.notes[index]
        local declaration = note:match("^add `local .* = {}`")
        if declaration == nil then
          out[#out + 1] = INDENT .. note
        elseif not hinted[symbol.path] then
          hinted[symbol.path] = true
          out[#out + 1] = INDENT .. note
        end
      end
    end

    -- Annotated, never suppressed. A name reached through a dispatch table,
    -- `_G[name]` or `vim.fn[name]` appears only as a bare string, and privata
    -- cannot tell that from a coincidence -- so it reports what it saw rather
    -- than silently recommending a rename that breaks at runtime.
    if symbol.string_mention then
      out[#out + 1] = INDENT
        .. string.format(
          "name also appears in a string at %s:%d -- check it is not reached by name",
          _P.relative(symbol.string_mention.path, project_root),
          symbol.string_mention.line
        )
    end
  end
end

function _P.globals(out, findings, project_root)
  _P.section(
    out,
    string.format(
      "Found %s that should be local; a global is visible to the whole process:",
      models.count(#findings, "global binding")
    )
  )
  for i = 1, #findings do
    local entry = findings[i]
    out[#out + 1] = string.format(
      "  %s:%d: %s `%s`%s",
      _P.relative(entry.path, project_root),
      entry.line,
      entry.kind,
      entry.name,
      -- `_G.foo = ...` is a declaration, not a missing `local`. Often it is the
      -- only way a host that can see nothing else reaches the name, so "should
      -- be local" would be wrong advice.
      entry.explicit and " -- declared on `_G`; confirm the host needs it" or ""
    )
  end
end

function _P.private_module_requires(out, findings, project_root)
  _P.section(
    out,
    string.format(
      "Found %s from outside the owning package:",
      models.count(#findings, "private module require")
    )
  )
  for i = 1, #findings do
    local entry = findings[i]
    out[#out + 1] = string.format(
      "  %s:%d: requires private module `%s`",
      _P.relative(entry.required_by_path, project_root),
      entry.line,
      entry.module
    )
  end
end

--- Group private-symbol reads by the name being read, not by the reader.
--
-- One private name read by eight sibling modules is a single design fact, not
-- eight boundary violations, and printing it eight times buries that. The
-- fan-out is the interesting number, so it leads.
function _P.private_symbol_reads(out, findings, project_root, config)
  local groups = {}
  local order = {}
  for i = 1, #findings do
    local entry = findings[i]
    local key = entry.module .. "." .. entry.name
    if groups[key] == nil then
      groups[key] = {}
      order[#order + 1] = key
    end
    local readers = groups[key]
    readers[#readers + 1] = entry
  end
  table.sort(order)

  -- Both numbers, because they are both true and they are not the same one:
  -- how many names leak, and how much of the codebase depends on them leaking.
  _P.section(
    out,
    string.format(
      "Found %s read from another module (%s):",
      models.count(#order, "private symbol"),
      models.count(#findings, "read")
    )
  )
  if config and #(config.package_private or {}) == 0 then
    -- The option that resolves this whole section exists and nothing else here
    -- points at it. A user who has to find it in the README will not.
    out[#out + 1] = "  (if these are package-internal by design, set `package_private`)"
    out[#out + 1] = ""
  end

  for i = 1, #order do
    local readers = groups[order[i]]
    out[#out + 1] =
      string.format("  `%s` -- read by %s", order[i], models.count(#readers, "module"))
    local marks = {}
    for index = 1, #readers do
      marks[index] = string.format(
        "%s:%d",
        _P.relative(readers[index].read_by_path, project_root),
        readers[index].line
      )
    end
    local wrapped = _P.wrap(marks, WIDTH - #INDENT)
    for index = 1, #wrapped do
      out[#out + 1] = INDENT .. wrapped[index]
    end
  end
end

function _P.export_issues(out, findings, project_root)
  _P.section(out, string.format("Found %s:", models.count(#findings, "export table issue")))
  for i = 1, #findings do
    local entry = findings[i]
    local location = string.format("  %s:%d: ", _P.relative(entry.path, project_root), entry.line)
    if entry.kind == "unknown" then
      out[#out + 1] = location
        .. string.format(
          "exports `%s`, which is bound to nothing; Lua exports nil rather than raising",
          entry.name
        )
    else
      out[#out + 1] = location .. string.format("exports private name `%s`", entry.name)
    end
  end
end

function _P.methods(out, findings, project_root)
  local groups = {}
  local order = {}
  for i = 1, #findings do
    local method = findings[i]
    local key = method.path .. "\0" .. method.class_line
    if groups[key] == nil then
      groups[key] = { class = method, items = {} }
      order[#order + 1] = key
    end
    local items = groups[key].items
    items[#items + 1] = method
  end

  _P.section(
    out,
    string.format(
      "Found %s in %s that could be made private:",
      models.count(#findings, "public method"),
      models.count(#order, "class", "classes")
    )
  )

  for i = 1, #order do
    local group = groups[order[i]]
    local class = group.class
    -- The n-of-m ratio separates two different questions: a class that is
    -- wholly internal, and a single method that leaked out of a public one.
    out[#out + 1] = string.format(
      "  %s:%d: class `%s` (%d of %d public methods)",
      _P.relative(class.path, project_root),
      class.class_line,
      class.class_name,
      #group.items,
      class.class_public_methods
    )
    local marks = {}
    for index = 1, #group.items do
      marks[index] = group.items[index].name .. ":" .. group.items[index].line
    end
    local wrapped = _P.wrap(marks, WIDTH - #INDENT)
    for index = 1, #wrapped do
      out[#out + 1] = INDENT .. wrapped[index]
    end
  end
end

--- Render findings as text.
function M.render(findings, project_root, config)
  local out = {}

  if #findings.unparsable > 0 then
    _P.unparsable(out, findings.unparsable, project_root, config)
  end
  if #findings.collisions > 0 then
    _P.collisions(out, findings.collisions, project_root, config)
  end
  if #findings.unanalyzable > 0 then
    _P.unanalyzable(out, findings.unanalyzable, project_root)
  end
  -- Defects lead. An accidental global is objectively a bug; everything below
  -- it is a statement about intended surface area, and a reader who has to
  -- scroll past two hundred opinions to reach three real leaks will not.
  if #findings.globals > 0 then
    _P.globals(out, findings.globals, project_root)
  end
  if #findings.exported_namespaces > 0 then
    _P.exported_namespaces(out, findings.exported_namespaces, project_root)
  end
  if #findings.symbols > 0 then
    _P.symbols(out, findings.symbols, project_root)
  end
  if #findings.methods > 0 then
    _P.methods(out, findings.methods, project_root)
  end
  if #findings.private_module_requires > 0 then
    _P.private_module_requires(out, findings.private_module_requires, project_root)
  end
  if #findings.private_symbol_reads > 0 then
    _P.private_symbol_reads(out, findings.private_symbol_reads, project_root, config)
  end
  if #findings.export_issues > 0 then
    _P.export_issues(out, findings.export_issues, project_root)
  end

  if #out == 0 then
    return "No module privacy issues found."
  end

  return table.concat(out, "\n")
end

return M
