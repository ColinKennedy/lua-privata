local lexer = require("privata._lexer")

--- Tokenize and drop the trailing eof token, which every case would repeat.
local function tokens(src)
  local list = lexer.tokenize(src)
  table.remove(list)
  return list
end

local function types_and_values(src)
  local result = {}
  for i, token in ipairs(tokens(src)) do
    result[i] = token.type .. ":" .. tostring(token.value)
  end
  return result
end

local function fails(src)
  local ok, err = pcall(lexer.tokenize, src)
  assert.is_false(ok)
  assert.is_true(type(err) == "table" and err.privata_syntax == true)
  return err
end

describe("lexer", function()
  describe("names and keywords", function()
    it("separates reserved words from ordinary names", function()
      assert.same(
        { "keyword:local", "name:x", "op:=", "keyword:nil" },
        types_and_values("local x = nil")
      )
    end)

    it("treats goto as a name so 5.1 sources still tokenize", function()
      -- `goto` is reserved from 5.2 on but assignable in 5.1 and LuaJIT. The
      -- parser decides which it is; the lexer must not pre-empt that.
      assert.same({ "name:goto", "op:=", "number:1" }, types_and_values("goto = 1"))
    end)

    it("accepts underscore-led and digit-bearing names", function()
      assert.same({ "name:_P", "op:.", "name:helper2" }, types_and_values("_P.helper2"))
    end)
  end)

  describe("operators", function()
    it("takes the longest match", function()
      assert.same({ "op:...", "op:..", "op:." }, types_and_values("... .. ."))
      assert.same({ "op:==", "op:=" }, types_and_values("== ="))
      assert.same({ "op:~=", "op:~" }, types_and_values("~= ~"))
    end)

    it("reads 5.3 bitwise and integer-division operators", function()
      assert.same({ "op://", "op:&", "op:|", "op:<<", "op:>>" }, types_and_values("// & | << >>"))
    end)

    it("reads 5.2 label delimiters", function()
      assert.same({ "op:::", "name:continue", "op:::" }, types_and_values("::continue::"))
    end)
  end)

  describe("numbers", function()
    it("reads decimals, floats and exponents", function()
      assert.same({ "number:1", "number:1.5", "number:1000" }, types_and_values("1 1.5 1e3"))
    end)

    it("reads a leading-dot float", function()
      assert.same({ "number:0.5" }, types_and_values(".5"))
    end)

    it("reads hexadecimal integers", function()
      assert.same({ "number:255" }, types_and_values("0xFF"))
    end)

    it("keeps the raw text of a hex float even where tonumber cannot read it", function()
      -- Lua 5.1's tonumber has no hex-float support, and privata never
      -- evaluates arithmetic, so `raw` is the field that has to survive.
      local token = tokens("0x1p4")[1]
      assert.equals("0x1p4", token.raw)
    end)

    it("reads LuaJIT integer and imaginary suffixes", function()
      local list = tokens("1LL 2ULL 3i")
      assert.same({ "1LL", "2ULL", "3i" }, { list[1].raw, list[2].raw, list[3].raw })
      assert.equals(1, list[1].value)
    end)

    it("rejects a numeral running into a name", function()
      local err = fails("1and")
      assert.matches("malformed number", err.message)
    end)
  end)

  describe("strings", function()
    it("reads both quote styles", function()
      assert.same({ "string:a", "string:b" }, types_and_values([['a' "b"]]))
    end)

    it("decodes simple escapes", function()
      assert.equals("a\tb\nc", tokens([["a\tb\nc"]])[1].value)
    end)

    it("decodes decimal, hex and unicode escapes", function()
      assert.equals("A", tokens([["\65"]])[1].value)
      assert.equals("A", tokens([["\x41"]])[1].value)
      assert.equals("\226\130\172", tokens([["\u{20AC}"]])[1].value)
    end)

    it("skips whitespace after \\z", function()
      assert.equals("ab", tokens('"a\\z   \n   b"')[1].value)
    end)

    it("reads long strings at any bracket level", function()
      assert.equals("a]]b", tokens("[==[a]]b]==]")[1].value)
    end)

    it("drops a newline immediately after a long opener", function()
      assert.equals("body", tokens("[[\nbody]]")[1].value)
    end)

    it("rejects an unterminated string", function()
      assert.matches("unfinished string", fails('"abc').message)
    end)

    it("rejects a decimal escape above 255", function()
      assert.matches("decimal escape too large", fails([["\300"]]).message)
    end)
  end)

  describe("comments", function()
    it("drops line comments", function()
      assert.same({ "name:a" }, types_and_values("a -- trailing\n"))
    end)

    it("drops long comments at any level", function()
      assert.same({ "name:a", "name:b" }, types_and_values("a --[==[ x ]] y ]==] b"))
    end)

    it("does not mistake a subtraction for a comment", function()
      assert.same({ "name:a", "op:-", "name:b" }, types_and_values("a - b"))
    end)
  end)

  describe("positions", function()
    it("numbers lines from one", function()
      local list = tokens("a\nb\nc")
      assert.same({ 1, 2, 3 }, { list[1].line, list[2].line, list[3].line })
    end)

    it("counts a CRLF pair as one line break", function()
      -- A file written on Windows must not shift every finding by its line
      -- count, and `-- privata: ignore` is matched by line number.
      local list = tokens("a\r\nb")
      assert.same({ 1, 2 }, { list[1].line, list[2].line })
    end)

    it("counts lines inside long strings", function()
      local list = tokens("[[\n\n]] x")
      assert.equals(3, list[2].line)
    end)

    it("reports columns from the line start", function()
      local list = tokens("a\n  bb")
      assert.equals(3, list[2].col)
    end)

    it("keeps a shebang line from shifting later lines", function()
      local list = tokens("#!/usr/bin/env lua\nx")
      assert.equals(2, list[1].line)
    end)

    it("skips a UTF-8 byte order mark", function()
      assert.same({ "name:x" }, types_and_values("\239\187\191x"))
    end)
  end)

  describe("source_lines", function()
    it("splits on every newline style with stable numbering", function()
      assert.same({ "a", "b", "c" }, lexer.source_lines("a\nb\r\nc"))
    end)

    it("returns one entry for empty source", function()
      assert.same({ "" }, lexer.source_lines(""))
    end)

    it("agrees with the line numbers the lexer assigns", function()
      local src = "local a = 1\n-- privata: ignore\nlocal b = 2"
      local lines = lexer.source_lines(src)
      local list = tokens(src)
      local last = list[#list]
      assert.equals(3, last.line)
      assert.matches("privata: ignore", lines[2])
    end)
  end)
end)
