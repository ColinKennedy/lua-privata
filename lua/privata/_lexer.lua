--- Tokenizer accepting a superset of Lua 5.1-5.4 and LuaJIT syntax.
--
-- Accepting more than any single dialect is the safe direction. Rejecting
-- syntax that is valid on the user's interpreter would push the file down
-- privata's unreliable-scan path, where a file that stops contributing
-- references makes unrelated modules gain findings that are not real. The
-- worst case for over-acceptance is parsing a file the user's own Lua would
-- reject -- and privata never executes what it reads.

local M = {}
local _P = {}

local find, sub, byte, char = string.find, string.sub, string.byte, string.char

--- Reserved words shared by every dialect privata accepts.
--
-- `goto` is deliberately absent. It is a keyword from 5.2 on but an ordinary
-- name in 5.1 and LuaJIT, where `goto = 1` is legal. The parser treats it as a
-- contextual keyword instead, so both dialects tokenize the same way.
local KEYWORDS = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}

_P.KEYWORDS = KEYWORDS

--- Operators longest-first, so maximal munch falls out of the scan order.
local OPERATORS = {
  "...",
  "..",
  "==",
  "~=",
  "<=",
  ">=",
  "<<",
  ">>",
  "//",
  "::",
  "+",
  "-",
  "*",
  "/",
  "%",
  "^",
  "#",
  "&",
  "~",
  "|",
  "<",
  ">",
  "=",
  "(",
  ")",
  "{",
  "}",
  "[",
  "]",
  ";",
  ":",
  ",",
  ".",
}

local SIMPLE_ESCAPES = {
  a = "\a",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
  v = "\v",
  ["\\"] = "\\",
  ['"'] = '"',
  ["'"] = "'",
}

--- Raise a lexical error carrying its position.
--
-- Thrown as a table with level 0 so the message survives without a "file:line:"
-- prefix that would then be reported twice. `_modules` turns it into an
-- UnparsableModule finding.
function _P.fail(state, message)
  error({ privata_syntax = true, line = state.line, message = message }, 0)
end

function _P.new(src)
  return { src = src, pos = 1, line = 1, line_start = 1, len = #src }
end

function _P.col(state, pos)
  return pos - state.line_start + 1
end

function _P.newline(state, pos)
  -- Treat CRLF, LFCR, CR and LF alike: source lines are what privata reports
  -- and what `-- privata: ignore` is matched against, so a file written on
  -- another platform must not shift every finding by the number of lines in it.
  local c = byte(state.src, pos)
  local nextc = byte(state.src, pos + 1)
  local width = 1
  if (c == 13 and nextc == 10) or (c == 10 and nextc == 13) then
    width = 2
  end
  state.line = state.line + 1
  state.pos = pos + width
  state.line_start = state.pos
  return width
end

--- Encode a code point as UTF-8, for `\u{XXX}` escapes.
--
-- Hand-rolled because `utf8.char` arrived in 5.3 and privata itself must run
-- on 5.1 and LuaJIT.
function _P.utf8_char(code)
  if code < 0x80 then
    return char(code)
  elseif code < 0x800 then
    return char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
  elseif code < 0x10000 then
    return char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + (math.floor(code / 0x40) % 0x40),
      0x80 + (code % 0x40)
    )
  end
  return char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + (math.floor(code / 0x1000) % 0x40),
    0x80 + (math.floor(code / 0x40) % 0x40),
    0x80 + (code % 0x40)
  )
end

--- Measure a long-bracket opener at `pos`, returning its level or nil.
function _P.long_bracket_level(state, pos)
  if byte(state.src, pos) ~= 91 then -- '['
    return nil
  end
  local s, e = find(state.src, "^%[(=*)%[", pos)
  if not s then
    return nil
  end
  return e - s - 1, e + 1
end

--- Read a long bracket body, which both long strings and long comments use.
function _P.read_long(state, level, body_start)
  local close = "%]" .. string.rep("=", level) .. "%]"
  local pos = body_start

  -- A newline immediately after the opener is not part of the contents.
  local first = byte(state.src, pos)
  if first == 10 or first == 13 then
    _P.newline(state, pos)
    pos = state.pos
  end

  local start = pos
  while true do
    if pos > state.len then
      _P.fail(state, "unfinished long string or comment")
    end
    local c = byte(state.src, pos)
    if c == 93 then -- ']'
      local s, e = find(state.src, "^" .. close, pos)
      if s then
        return sub(state.src, start, pos - 1), e + 1
      end
      pos = pos + 1
    elseif c == 10 or c == 13 then
      _P.newline(state, pos)
      pos = state.pos
    else
      pos = pos + 1
    end
  end
end

function _P.read_short_string(state, quote)
  local pos = state.pos + 1
  local pieces = {}
  local count = 0

  while true do
    if pos > state.len then
      _P.fail(state, "unfinished string")
    end
    local c = byte(state.src, pos)

    if c == quote then
      pos = pos + 1
      break
    elseif c == 10 or c == 13 then
      _P.fail(state, "unfinished string")
    elseif c == 92 then -- backslash
      local nextc = sub(state.src, pos + 1, pos + 1)
      local simple = SIMPLE_ESCAPES[nextc]
      if nextc == "\n" or nextc == "\r" then
        _P.newline(state, pos + 1)
        pos = state.pos
        count = count + 1
        pieces[count] = "\n"
      elseif simple then
        count = count + 1
        pieces[count] = simple
        pos = pos + 2
      elseif nextc == "x" or nextc == "X" then
        local s, e, hex = find(state.src, "^(%x%x)", pos + 2)
        if not s then
          _P.fail(state, "hexadecimal digit expected in escape sequence")
        end
        count = count + 1
        pieces[count] = char(tonumber(hex, 16))
        pos = e + 1
      elseif nextc == "z" then
        -- \z skips the following whitespace, newlines included.
        pos = pos + 2
        while pos <= state.len do
          local w = byte(state.src, pos)
          if w == 10 or w == 13 then
            _P.newline(state, pos)
            pos = state.pos
          elseif w == 32 or w == 9 or w == 11 or w == 12 then
            pos = pos + 1
          else
            break
          end
        end
      elseif nextc == "u" then
        local s, e, hex = find(state.src, "^{(%x+)}", pos + 2)
        if not s then
          _P.fail(state, "missing '{' in \\u{xxxx}")
        end
        count = count + 1
        pieces[count] = _P.utf8_char(tonumber(hex, 16))
        pos = e + 1
      elseif find(nextc, "^%d") then
        local _, e, digits = find(state.src, "^(%d%d?%d?)", pos + 1)
        local value = tonumber(digits)
        if value > 255 then
          _P.fail(state, "decimal escape too large")
        end
        count = count + 1
        pieces[count] = char(value)
        pos = e + 1
      else
        _P.fail(state, "invalid escape sequence '\\" .. nextc .. "'")
      end
    else
      -- Consume a run of ordinary characters in one slice rather than byte by
      -- byte; strings are common enough that this shows up in scan time.
      local s, e = find(state.src, "^[^\\\r\n'\"]+", pos)
      if s then
        count = count + 1
        pieces[count] = sub(state.src, s, e)
        pos = e + 1
      else
        count = count + 1
        pieces[count] = char(c)
        pos = pos + 1
      end
    end
  end

  return table.concat(pieces), pos
end

--- Read a numeral, including hex floats and LuaJIT's integer suffixes.
--
-- The numeric value is best-effort: privata never evaluates arithmetic, and
-- `tonumber` on 5.1 cannot read a hex float. `raw` always holds the source
-- text, which is what any check that cares about a literal actually uses.
function _P.read_number(state)
  local src, pos = state.src, state.pos
  local _, e

  if find(src, "^0[xX]", pos) then
    _, e = find(src, "^0[xX]%x*", pos)
    e = select(2, find(src, "^%.%x*", e + 1)) or e
    e = select(2, find(src, "^[pP][-+]?%d+", e + 1)) or e
  else
    _, e = find(src, "^%d*", pos)
    e = select(2, find(src, "^%.%d*", e + 1)) or e
    e = select(2, find(src, "^[eE][-+]?%d+", e + 1)) or e
  end

  -- LuaJIT: 1LL, 1ULL, 1i. Kept out of the text handed to `tonumber`.
  local suffix_e = select(2, find(src, "^[uU]?[lL][lL]", e + 1))
    or select(2, find(src, "^[iI]", e + 1))
  local raw_end = suffix_e or e

  if find(src, "^[%w_]", raw_end + 1) then
    _P.fail(state, "malformed number near '" .. sub(src, pos, raw_end + 1) .. "'")
  end

  local raw = sub(src, pos, raw_end)
  return { value = tonumber(sub(src, pos, e)), raw = raw }, raw_end + 1
end

function _P.skip_comment(state, pos)
  local level, body_start = _P.long_bracket_level(state, pos + 2)
  if level then
    local _, after = _P.read_long(state, level, body_start)
    return after
  end
  local _, e = find(state.src, "^[^\r\n]*", pos)
  return e + 1
end

--- Tokenize `src`, returning an array of tokens ending in one of kind "eof".
--
-- Each token is `{ type, value, line, col }`, where `type` is one of "name",
-- "number", "string", "keyword", "op", "eof". String and number tokens carry a
-- `raw` field holding their source text.
function M.tokenize(src)
  -- Lua itself skips a leading `#!` line when loading a file, so a bin script
  -- is ordinary source; privata must read it the same way.
  if sub(src, 1, 1) == "#" then
    local _, e = find(src, "^[^\r\n]*")
    src = string.rep(" ", e) .. sub(src, e + 1)
  end
  -- A UTF-8 BOM is not whitespace to the pattern matcher, so strip it rather
  -- than fail on a file an editor helpfully re-encoded.
  if sub(src, 1, 3) == "\239\187\191" then
    src = "   " .. sub(src, 4)
  end

  local state = _P.new(src)
  local tokens = {}
  local count = 0

  local function push(token)
    count = count + 1
    tokens[count] = token
  end

  while true do
    local pos = state.pos
    if pos > state.len then
      push({ type = "eof", value = "<eof>", line = state.line, col = _P.col(state, pos) })
      break
    end

    local c = byte(src, pos)

    if c == 10 or c == 13 then
      _P.newline(state, pos)
    elseif c == 32 or c == 9 or c == 11 or c == 12 then
      local _, e = find(src, "^[ \t\v\f]+", pos)
      state.pos = e + 1
    elseif c == 45 and byte(src, pos + 1) == 45 then -- '--'
      state.pos = _P.skip_comment(state, pos)
    elseif c == 91 then -- '['
      local level, body_start = _P.long_bracket_level(state, pos)
      if level then
        local line = state.line
        local col = _P.col(state, pos)
        local value, after = _P.read_long(state, level, body_start)
        state.pos = after
        push({
          type = "string",
          value = value,
          raw = sub(src, pos, after - 1),
          long = true,
          line = line,
          col = col,
        })
      else
        state.pos = pos + 1
        push({ type = "op", value = "[", line = state.line, col = _P.col(state, pos) })
      end
    elseif c == 34 or c == 39 then -- '"' or "'"
      local line = state.line
      local col = _P.col(state, pos)
      local value, after = _P.read_short_string(state, c)
      state.pos = after
      push({
        type = "string",
        value = value,
        raw = sub(src, pos, after - 1),
        long = false,
        line = line,
        col = col,
      })
    elseif find(src, "^[%d]", pos) or (c == 46 and find(src, "^%.%d", pos)) then
      local col = _P.col(state, pos)
      local number, after = _P.read_number(state)
      state.pos = after
      push({
        type = "number",
        value = number.value,
        raw = number.raw,
        line = state.line,
        col = col,
      })
    elseif find(src, "^[%a_]", pos) then
      local s, e = find(src, "^[%a_][%w_]*", pos)
      local word = sub(src, s, e)
      state.pos = e + 1
      push({
        type = KEYWORDS[word] and "keyword" or "name",
        value = word,
        line = state.line,
        col = _P.col(state, s),
      })
    else
      local matched = nil
      for i = 1, #OPERATORS do
        local op = OPERATORS[i]
        if sub(src, pos, pos + #op - 1) == op then
          matched = op
          break
        end
      end
      if not matched then
        _P.fail(state, "unexpected symbol near '" .. sub(src, pos, pos) .. "'")
      end
      state.pos = pos + #matched
      push({ type = "op", value = matched, line = state.line, col = _P.col(state, pos) })
    end
  end

  return tokens
end

--- Split source into lines, preserving 1-based numbering.
--
-- `-- privata: ignore` is matched against these, so the split has to agree with
-- the line numbers the lexer assigns: same newline handling, same count.
function M.source_lines(src)
  local lines = {}
  local count = 0
  local pos = 1
  local len = #src
  local start = 1
  while pos <= len do
    local c = byte(src, pos)
    if c == 10 or c == 13 then
      local nextc = byte(src, pos + 1)
      count = count + 1
      lines[count] = sub(src, start, pos - 1)
      if (c == 13 and nextc == 10) or (c == 10 and nextc == 13) then
        pos = pos + 2
      else
        pos = pos + 1
      end
      start = pos
    else
      pos = pos + 1
    end
  end
  if start <= len or count == 0 then
    count = count + 1
    lines[count] = sub(src, start)
  end
  return lines
end

return M
