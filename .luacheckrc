-- privata must run on Lua 5.1 and LuaJIT, so its own source may not use
-- anything newer. Declaring the union of the standard libraries here would hide
-- exactly the mistakes that matter, so the floor is what gets checked.
std = "min"

globals = {
  -- Present on every dialect privata targets, but absent from the `min` set.
  "math",
  "string",
  "table",
  "io",
  "os",
  "select",
  "tonumber",
  "tostring",
  "type",
  "pcall",
  "error",
  "require",
  "setmetatable",
  "getmetatable",
  "rawget",
  "rawset",
  "ipairs",
  "pairs",
  "next",
  "unpack",
  "print",
  "arg",
}

max_line_length = 100

files["spec/"] = {
  read_globals = {
    "describe",
    "it",
    "setup",
    "teardown",
    "before_each",
    "after_each",
    "assert",
    "spy",
    "stub",
    "mock",
    "pending",
    "finally",
  },
}
