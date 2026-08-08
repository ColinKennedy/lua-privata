# privata

Find Lua code that looks public but is only used privately.

privata is a static checker for keeping module boundaries intentional. It scans
your production Lua modules and reports interface drift:

- fields on a module table that no other module ever reads
- globals, which are public to the entire process
- `require`s of a private module from outside the package that owns it
- reads of another module's private names
- literal `return { a = a }` tables that have gone stale
- public methods on a class that no other module refers to (opt in with `--methods`)

Test usage does not count, so tests can reach internals without pinning them
public forever.

Zero runtime dependencies. Runs on Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.

## Example

Given:

```lua
-- lua/example/service.lua
local M = {}

function M.helper()
  return 1
end

function M.run()
  return M.helper()
end

return M
```

privata reports:

```text
Found 1 public symbol that could be made private:

  lua/example/service.lua:3: function `M.helper` -> move to `_P.helper`
      also read at :8
      add `local _P = {}` near the top of the file
```

`M.run` calling `M.helper` is not evidence that `helper` is public — it is
precisely the situation being reported. Note that privata names the *readers*
too: unlike a Python rename, acting on this means rewriting every call site.

## Install

```bash
luarocks install privata
```

## Usage

```bash
privata .
```

```text
Options:
  --methods                   Also report public methods no other module refers
                              to. Off by default: Lua dispatch is dynamic, so
                              this check cannot see every caller.
  --skip-unparsable-files     Downgrade unparsable files from error to warning.
  --skip-module-collisions    Downgrade colliding module names to a warning.
  --namespace NAME            Private namespace to recommend (default: _P).
  --preset NAME               Apply a shipped preset, e.g. neovim.
  --format text|json          Output format (default: text).
```

Exit codes: `0` clean, `1` findings, `2` bad usage or configuration.

### Where privata looks

In order of authority:

1. `source_roots` in `.privata.lua`
2. the directories a rockspec's `build.modules` maps into — an explicit
   name-to-file table, and a stronger statement of layout than any convention
3. `lua/`, then `src/`
4. the project root, with vendored and build directories pruned

## Configuration

`.privata.lua`, returning a table. Discovered by walking up from the scan root.

```lua
return {
  preset = nil,                    -- or "neovim"

  source_roots = nil,              -- nil = auto-detect
  test_roots = { "spec", "test", "tests" },
  exclude = {},

  privatize = { "namespace", "local_function", "underscore_field" },
  namespace = "_P",
  local_function_style = "statement",   -- or "assignment"
  local_function_forward_decl = true,
  max_locals = 180,

  private_module_patterns = { "^_" },

  globals = {},                    -- names that are meant to be global

  methods = false,
  skip_unparsable_files = false,
  skip_module_collisions = false,
  format = "text",

  checks = {
    symbols = true, globals = true, private_modules = true,
    private_symbols = true, exports = true, methods = false,
  },
}
```

The config file is **parsed, never executed**. Rockspecs and `.privata.lua` are
both Lua source, and loading them would mean running arbitrary code just to scan
a checkout. The cost is that a config cannot compute: `source_roots =
vim.fn.glob(...)` is an error, not a list.

### How privata recommends privatising

Strategies are tried in the configured order and the first *applicable* one
wins. `namespace` leads by default because it always applies:

- **`namespace`** — `move to _P.helper`. The name is whatever `namespace` says.
- **`local_function`** — `make it local function helper`. Not always legal:
  - `M.a` may call `M.b` defined further down the file, but `local function a`
    calling a later `local b` reads a *global* and silently gets nil. privata
    names the forward declaration you would need, or falls through.
  - a Lua chunk holds at most 200 locals, so a large module cannot demote
    everything to one. Above `max_locals`, the strategy falls through.
  - a self-recursive definition always emits the statement form, because
    `local f = function()` cannot see its own name inside its initialiser.
- **`underscore_field`** — `rename to M._helper`. Still reachable, so it stays
  testable from specs; the weakest form, last by default.

privata **only ever recommends narrowing an interface**, and there is no
`--fix`. Where the private-symbol check proves a private name is read from
elsewhere, that is reported as a boundary to fix at the call site, not as a hint
to publish the name.

### Neovim

```lua
return { preset = "neovim" }
```

Sets `lua/` as the source root, allows the `vim` global, and treats the files
Neovim loads itself — `plugin/`, `ftplugin/`, `after/`, `health.lua`, and
`M.setup` — as public without any module requiring them. Everything it sets is
a default your own config still overrides.

## Module shapes

privata recognises:

```lua
local M = {} … return M                      -- classic
local _P, M = {}, {} … return M              -- two-namespace
return { foo = foo, bar = bar }              -- literal export table
local C = {}; C.__index = C … return C       -- class module
return setmetatable(M, mt)                   -- wrapped
```

It **refuses to guess** at multiple return values, conditional returns,
loop-built tables, and Lua 5.1's `module()`. Those are reported as
"module shape could not be determined" rather than assumed: a wrong shape
inference mislabels every symbol in the file at once, in both directions.

## When the scan is unreliable

An unparsable file and a colliding module name are both printed *first* and fail
the run, because a file privata could not read stops contributing references —
unrelated modules gain findings that are not real while genuine findings vanish.

Each has its own override, and each downgrades only itself:

| situation | default | with the matching flag |
|---|---|---|
| unparsable files only | 1 | **0** |
| module collisions only | 1 | **0** |
| either condition + real findings | 1 | 1 |

They are separate switches deliberately. An unparsable file makes findings
*incomplete*; a collision means privata read the *wrong file* for a name, so
findings elsewhere can be actively wrong. Turning off the common annoyance
should not silently turn off the dangerous one. Both still print their caveat
when downgraded.

## Suppressing a finding

```lua
function M.helper() end -- privata: ignore
```

Line-scoped: it suppresses the finding on that line and nothing else.

## The method check

Off by default, because Lua method dispatch through metatable chains is *more*
dynamic than Python attribute access, not less.

A method is reported when no other production module mentions its name — as
`obj:name()`, as `t.name`, or as a string literal. Matching is by name rather
than by receiver, so an unrelated `other.run` elsewhere conservatively
suppresses a report for `Service.run`.

A class is skipped when anything links a metatable to it, when it indexes itself
by a computed name, or when it is reached through `_G` or `load`. Dispatch
privata cannot see at all — a table of bound methods assembled elsewhere, a name
forwarded through `...` — is **not supported** and will produce false positives.
Use `-- privata: ignore`.

## Library use

```lua
local privata = require("privata")

local findings = privata.check(".")
local candidates = privata.find_private_candidates(".")
```

Each `find_*` helper runs a full scan, so do not call several in a loop — use
`check` and read the fields you want.

## Development

```bash
busted                 # specs
busted --coverage && lua scripts/check_coverage.lua 92
luacheck lua spec bin
stylua --check lua spec bin
LUA_PATH="./lua/?.lua;./lua/?/init.lua;;" lua bin/privata.lua .
```

privata runs on itself in CI with `--methods`. Any internal helper must either
live in `_P` or be genuinely used across modules, or the build fails.

## Prior art

A port of [python-privata](https://github.com/basnijholt/privata) to Lua's
module model, keeping its opinions and adapting its mechanics.

The one deliberate divergence is the method check. python-privata skips classes
re-exported by a package, reasoning that re-export declares publicity. In Lua,
`return C` is the only way to ship a class at all — it is the language, not a
decision — so applying that rule would skip every class module and leave the
check analysing nothing. privata checks returned classes and puts all of the
conservatism into the disqualifiers instead.

## License

MIT
