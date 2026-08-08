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

---@class privata.Token
---@field type string        "name", "number", "string", "keyword", "op" or "eof"
---@field value any          the name, the numeric value, the decoded string, ...
---@field line integer
---@field col integer
---@field raw string|nil     source text; carried by string and number tokens
---@field long boolean|nil   true when a string came from a long bracket

---@class privata.LexState
---@field src string
---@field pos integer         next byte to read, 1-based
---@field line integer        line the scanner is on, 1-based
---@field line_start integer  byte offset at which the current line begins
---@field len integer         `#src`, cached because it is read per character

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
---@param state privata.LexState
---@param message string
function _P.fail(state, message)
  error({ privata_syntax = true, line = state.line, message = message }, 0)
end

--- Fresh scanner state positioned at the first byte of `src`.
---@param src string
---@return privata.LexState
function _P.new(src)
  return { src = src, pos = 1, line = 1, line_start = 1, len = #src }
end

--- The 1-based column of `pos` on the line the scanner is currently on.
---@param state privata.LexState
---@param pos integer
---@return integer
function _P.col(state, pos)
  return pos - state.line_start + 1
end

--- Consume the line break at `pos`, advancing the scanner onto the next line.
---@param state privata.LexState
---@param pos integer
---@return integer width  bytes consumed: 2 for a paired break, otherwise 1
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
---@param code integer  a Unicode code point
---@return string       its UTF-8 encoding
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
---@param state privata.LexState
---@param pos integer
---@return integer|nil level       count of `=` signs, 0 for `[[`
---@return integer|nil body_start  first byte after the opener
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
---@param state privata.LexState
---@param level integer       level the opener declared, so the closer must match
---@param body_start integer
---@return string body        contents, without the brackets
---@return integer after      first byte past the closer
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

--- Read a quoted string, decoding escapes into the value.
--
-- The decoded value is what the checks compare against -- a name mentioned in a
-- string literal is found by matching the value, not the source text -- so the
-- escapes have to be resolved here rather than left for a consumer to redo.
---@param state privata.LexState
---@param quote integer   byte of the opening quote, matched to close it
---@return string value   decoded contents
---@return integer after  first byte past the closing quote
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
        -- The pattern matched one to three digits, so this always parses.
        local value = assert(tonumber(digits))
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
---@param state privata.LexState
---@return { value: number|nil, raw: string } number  `value` is nil if unreadable
---@return integer after  first byte past the numeral
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

--- Skip a comment, long or short, and report where the source resumes.
--
-- A long comment can span lines, so it is read with the same routine as a long
-- string: the line counter has to advance through it or every finding below
-- would be reported against the wrong line.
---@param state privata.LexState
---@param pos integer     byte of the first `-` of the `--`
---@return integer after  first byte past the comment
function _P.skip_comment(state, pos)
  local level, body_start = _P.long_bracket_level(state, pos + 2)
  if level then
    -- Both results are set together, so a level implies a body start.
    ---@cast body_start integer
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
---@param src string
---@return privata.Token[]
function M.tokenize(src)
  -- Lua itself skips a leading `#!` line when loading a file, so a bin script
  -- is ordinary source; privata must read it the same way.
  if sub(src, 1, 1) == "#" then
    local e = select(2, find(src, "^[^\r\n]*")) or 0
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

  -- Appends by running count rather than `#tokens`, which is O(log n) per call.
  ---@param token privata.Token
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
    -- The bounds check above already returned, so this byte is always present.
    ---@cast c integer

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
        ---@cast body_start integer
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
      -- Guarded by the branch above, which already matched a leading name char.
      local s, e = find(src, "^[%a_][%w_]*", pos)
      ---@cast s integer
      local word = sub(src, assert(s), e)
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
---@param src string
---@return string[]  one entry per line, without its terminator
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
