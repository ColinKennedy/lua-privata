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

function _P.symbols(out, findings, project_root)
  _P.section(
    out,
    string.format("Found %s that could be made private:", models.count(#findings, "public symbol"))
  )
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
        out[#out + 1] = INDENT .. recommendation.notes[index]
      end
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
      "  %s:%d: %s `%s`",
      _P.relative(entry.path, project_root),
      entry.line,
      entry.kind,
      entry.name
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

function _P.private_symbol_reads(out, findings, project_root)
  _P.section(
    out,
    string.format("Found %s from another module:", models.count(#findings, "private symbol read"))
  )
  for i = 1, #findings do
    local entry = findings[i]
    out[#out + 1] = string.format(
      "  %s:%d: reads private symbol `%s.%s`",
      _P.relative(entry.read_by_path, project_root),
      entry.line,
      entry.module,
      entry.name
    )
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
  if #findings.symbols > 0 then
    _P.symbols(out, findings.symbols, project_root)
  end
  if #findings.methods > 0 then
    _P.methods(out, findings.methods, project_root)
  end
  if #findings.globals > 0 then
    _P.globals(out, findings.globals, project_root)
  end
  if #findings.private_module_requires > 0 then
    _P.private_module_requires(out, findings.private_module_requires, project_root)
  end
  if #findings.private_symbol_reads > 0 then
    _P.private_symbol_reads(out, findings.private_symbol_reads, project_root)
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
