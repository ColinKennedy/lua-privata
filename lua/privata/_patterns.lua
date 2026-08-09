--- Translate the pattern syntaxes `tach.toml` uses into Lua patterns.
--
-- tach describes a public interface with regular expressions and names modules
-- with globs. privata's configuration speaks the same two syntaxes, so that a
-- `tach.lua` and a `.privata.lua` mean the same thing by the same string. Lua
-- has neither syntax: `string.find` takes Lua patterns, which look like regular
-- expressions and are not one -- `%` escapes rather than `\`, `\d` is a syntax
-- error, and there is no alternation at all.
--
-- Translating is therefore the only way a pattern written for tach can be
-- honoured here rather than approximated. What Lua patterns cannot express --
-- alternation, grouping, repetition counts -- is reported as a configuration
-- problem instead of being quietly dropped: these patterns decide which symbols
-- privata calls public, so one that silently matches something else is worse
-- than one that refuses to load.
--
-- Both syntaxes match a whole string, matching tach: an `expose` entry names a
-- symbol outright, not a substring of one.

local M = {}
local _P = {}

--- Characters Lua patterns give a meaning to, which a literal has to escape.
_P.MAGIC = {
  ["^"] = true,
  ["$"] = true,
  ["("] = true,
  [")"] = true,
  ["%"] = true,
  ["."] = true,
  ["["] = true,
  ["]"] = true,
  ["*"] = true,
  ["+"] = true,
  ["-"] = true,
  ["?"] = true,
}

--- Regex shorthand classes, as a Lua pattern spells them.
--
-- `\w` is the one that is not a rename: a regex word character includes the
-- underscore and Lua's `%w` does not, so translating it to `%w` would quietly
-- stop matching every private name in the project. Only these translate; `\b`
-- and `\B` are word boundaries, which Lua spells `%f[%w]` and only
-- approximately, so they are refused rather than guessed at.
_P.CLASS_ESCAPES = {
  d = "%d",
  D = "%D",
  w = "[%w_]",
  W = "[^%w_]",
  s = "%s",
  S = "%S",
}

--- The same shorthands written for use *inside* a bracketed class, where Lua
--- allows no nesting. `\W` and `\S` have no form here: a Lua class negates as a
--- whole or not at all, so one negated member cannot be expressed.
_P.INNER_CLASS_ESCAPES = {
  d = "%d",
  w = "%w_",
  s = "%s",
}

--- Regex constructs with no Lua pattern equivalent, and what to call them.
_P.UNSUPPORTED = {
  ["|"] = "alternation",
  ["("] = "a group",
  [")"] = "a group",
  ["{"] = "a repetition count",
  ["}"] = "a repetition count",
}

--- The placeholder standing in for `**` between expansion and translation.
--
-- A control character, because it has to be a byte no glob would contain: the
-- expansion below rewrites `**` into alternatives before any escaping happens,
-- and a placeholder a user could have typed would be indistinguishable from
-- their own text by the time it is read back.
_P.GLOBSTAR = "\1"

--- Quote one character so a Lua pattern matches it literally.
---@param char string  a single character
---@return string
function _P.escape(char)
  if _P.MAGIC[char] then
    return "%" .. char
  end
  return char
end

--- Translate a bracketed character class, which both syntaxes share.
--
-- Lua's own class syntax is close enough to copy through: ranges and a leading
-- negating `^` mean the same thing. What differs is the escape character, so a
-- `%` inside the class is doubled and a `\x` is re-spelled.
---@param source string
---@param position integer  index of the opening `[`
---@return string|nil text   the Lua class, including its brackets
---@return string|integer rest  the index after the closing `]`, or the reason
function _P.bracket(source, position)
  local out = { "[" }
  local index = position + 1

  if source:sub(index, index) == "^" then
    out[#out + 1] = "^"
    index = index + 1
  end

  -- A `]` written first is a literal in both syntaxes, so only a later one
  -- closes the class.
  local first = true
  while index <= #source do
    local char = source:sub(index, index)
    if char == "]" and not first then
      out[#out + 1] = "]"
      return table.concat(out), index + 1
    end

    if char == "\\" then
      local escaped = source:sub(index + 1, index + 1)
      if escaped == "" then
        return nil, "pattern ends in a backslash"
      end
      local inner = _P.INNER_CLASS_ESCAPES[escaped]
      if inner then
        out[#out + 1] = inner
      elseif escaped:find("^%a") then
        return nil, "unsupported escape '\\" .. escaped .. "' inside a character class"
      else
        out[#out + 1] = _P.escape(escaped)
      end
      index = index + 2
    elseif char == "%" or char == "]" then
      out[#out + 1] = "%" .. char
      index = index + 1
    else
      out[#out + 1] = char
      index = index + 1
    end
    first = false
  end

  return nil, "unterminated character class in pattern"
end

--- Translate a regular expression into an anchored Lua pattern.
--
-- The supported subset is the one tach configurations actually use: literals,
-- `.`, the three quantifiers, character classes, and backslash escapes. A
-- leading `^` and a trailing `$` are accepted and dropped, since the result is
-- anchored either way; an anchor anywhere else is refused, because it would be
-- asserting something about a partial match that cannot happen here.
---@param source string
---@return string|nil pattern
---@return string|nil reason  set only when `pattern` is nil
function M.from_regex(source)
  if type(source) ~= "string" then
    return nil, "pattern must be a string"
  end

  local out = {}
  local index = 1
  local stop = #source

  if source:sub(1, 1) == "^" then
    index = 2
  end
  if stop > 0 and source:sub(stop, stop) == "$" and source:sub(stop - 1, stop - 1) ~= "\\" then
    stop = stop - 1
  end

  -- Whether the last thing emitted can carry a quantifier. Zero after a
  -- quantifier as well as at the start, so `a**` is refused rather than
  -- translated into a Lua pattern that means something else entirely.
  local quantifiable = false

  while index <= stop do
    local char = source:sub(index, index)

    if char == "\\" then
      local escaped = source:sub(index + 1, index + 1)
      if escaped == "" then
        return nil, "pattern ends in a backslash"
      end
      local class = _P.CLASS_ESCAPES[escaped]
      if class then
        out[#out + 1] = class
      elseif escaped:find("^%a") then
        return nil, "unsupported escape '\\" .. escaped .. "' in pattern"
      else
        out[#out + 1] = _P.escape(escaped)
      end
      index = index + 2
      quantifiable = true
    elseif char == "[" then
      local text, rest = _P.bracket(source, index)
      if text == nil then
        return nil, tostring(rest)
      end
      out[#out + 1] = text
      ---@cast rest integer
      index = rest
      quantifiable = true
    elseif char == "." then
      out[#out + 1] = "."
      index = index + 1
      quantifiable = true
    elseif char == "*" or char == "+" or char == "?" then
      if not quantifiable then
        return nil, "'" .. char .. "' has nothing to repeat in pattern"
      end
      out[#out + 1] = char
      index = index + 1
      quantifiable = false
    elseif char == "^" or char == "$" then
      return nil, "'" .. char .. "' is only supported at the ends of a pattern"
    elseif _P.UNSUPPORTED[char] then
      return nil, _P.UNSUPPORTED[char] .. " is not supported in a pattern"
    else
      out[#out + 1] = _P.escape(char)
      index = index + 1
      quantifiable = true
    end
  end

  return "^" .. table.concat(out) .. "$"
end

--- Rewrite every `**` into the alternatives a Lua pattern can express.
--
-- `**` spans separators and, next to one, spans zero of them too: tach matches
-- `libs` as well as `libs.thing` for `libs.**`, and `tests` as well as
-- `python/tests` for `**/tests`. Lua patterns have no optional group, so the
-- optionality is expanded into separate patterns and the caller matches against
-- any of them. Real configurations hold one or two `**`, so the expansion stays
-- small.
---@param glob string
---@param separator string
---@return string[]  globs holding `_P.GLOBSTAR` in place of every `**`
function _P.expand_globstar(glob, separator)
  local before, after = glob:match("^(.-)%*%*(.*)$")
  if before == nil then
    return { glob }
  end

  local variants = {}
  local function expand(candidate)
    local rest = _P.expand_globstar(candidate, separator)
    for i = 1, #rest do
      variants[#variants + 1] = rest[i]
    end
  end

  if after:sub(1, #separator) == separator then
    -- `**/rest`: no leading segments at all, or any number of them.
    expand(before .. after:sub(#separator + 1))
    expand(before .. _P.GLOBSTAR .. after)
  elseif after == "" and before:sub(-#separator) == separator then
    -- `prefix/**`: the prefix itself, or anything beneath it.
    expand(before:sub(1, #before - #separator))
    expand(before .. _P.GLOBSTAR)
  else
    expand(before .. _P.GLOBSTAR .. after)
  end

  return variants
end

--- Translate one globstar-free glob into an anchored Lua pattern.
---@param glob string  may contain `_P.GLOBSTAR`
---@param separator string  the path separator `*` must not cross
---@return string|nil pattern
---@return string|nil reason  set only when `pattern` is nil
function _P.glob_pattern(glob, separator)
  local segment = "[^" .. _P.escape(separator) .. "]"
  local out = {}
  local index = 1

  while index <= #glob do
    local char = glob:sub(index, index)
    if char == _P.GLOBSTAR then
      out[#out + 1] = ".*"
      index = index + 1
    elseif char == "*" then
      out[#out + 1] = segment .. "*"
      index = index + 1
    elseif char == "?" then
      out[#out + 1] = segment
      index = index + 1
    elseif char == "[" then
      local text, rest = _P.bracket(glob, index)
      if text == nil then
        return nil, tostring(rest)
      end
      out[#out + 1] = text
      ---@cast rest integer
      index = rest
    elseif char == "{" or char == "}" then
      return nil, "brace alternation is not supported in a glob"
    elseif char == "\\" then
      local escaped = glob:sub(index + 1, index + 1)
      if escaped == "" then
        return nil, "glob ends in a backslash"
      end
      out[#out + 1] = _P.escape(escaped)
      index = index + 2
    else
      out[#out + 1] = _P.escape(char)
      index = index + 1
    end
  end

  return "^" .. table.concat(out) .. "$"
end

--- Translate a glob into the Lua patterns that together mean the same thing.
--
-- Returns a list rather than one pattern because `**` is optional next to a
-- separator and Lua patterns cannot say "optional" about anything longer than a
-- character. `M.any` is what callers use to ask the list a question.
---@param glob string
---@param separator string|nil  defaults to `/`; `.` for a dotted module name
---@return string[]|nil patterns
---@return string|nil reason  set only when `patterns` is nil
function M.from_glob(glob, separator)
  if type(glob) ~= "string" then
    return nil, "glob must be a string"
  end
  separator = separator or "/"
  if glob:find(_P.GLOBSTAR, 1, true) then
    return nil, "glob contains a control character"
  end

  local expanded = _P.expand_globstar(glob, separator)
  local patterns = {}
  for i = 1, #expanded do
    local pattern, reason = _P.glob_pattern(expanded[i], separator)
    if pattern == nil then
      return nil, reason
    end
    patterns[#patterns + 1] = pattern
  end

  return patterns
end

--- Translate a dotted module glob, as `modules[].path` writes them.
---@param glob string
---@return string[]|nil patterns
---@return string|nil reason
function M.from_module_glob(glob)
  return M.from_glob(glob, ".")
end

--- True when any of `patterns` matches the whole of `text`.
---@param patterns string[]  Lua patterns, already anchored
---@param text string
---@return boolean
function M.any(patterns, text)
  for i = 1, #patterns do
    if text:find(patterns[i]) then
      return true
    end
  end
  return false
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
