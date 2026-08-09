# privata

Find Lua code that looks public but is only used privately.

privata is a static checker for keeping module boundaries intentional. It scans
your production Lua modules and reports interface drift:

- fields on a module table that no other module ever reads
- globals, which are public to the entire process (a `_G.foo = …` declaration is
  reported differently from a missing `local`, and one the host reaches through
  `v:lua.foo` is not reported at all)
- `require`s of a private module from outside the package that owns it
- reads of another module's private names
- literal `return { a = a }` tables that have gone stale
- `-- privata: ignore` comments that no longer suppress anything
- modules whose whole export is a function that nothing requires
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

  To mark any of these public on purpose, declare it in `.privata.lua` rather than
  privatising it -- privata cannot see callers outside this checkout:
      entrypoint_names = { "setup" }        -- one name, wherever it is defined
      entrypoint_modules = { "mylib.api" }  -- everything a module exports

  lua/example/service.lua:3: function `M.helper` -> move to `_P.helper`
      also read at :8
      add `local _P = {}` near the top of the file
```

`M.run` calling `M.helper` is not evidence that `helper` is public — it is
precisely the situation being reported. Note that privata names the *readers*
too: unlike a Python rename, acting on this means rewriting every call site.

The parenthetical names the one thing privata cannot infer: a function called
from outside this checkout looks exactly like one nobody calls. Declaring it in
`.privata.lua` is the fix — see "What privata cannot see".

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
  --ignore-methods            Never report a `function C:m()` declaration. For a
                              codebase whose dispatch privata cannot follow at
                              all; conflicts with --methods.
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
  package_private = {},            -- see "Package-private names"

  fail_on = {                      -- which kinds exit non-zero
    "unparsable", "collisions", "unanalyzable", "symbols", "globals",
    "exported_namespaces", "function_modules", "private_modules",
    "private_symbols", "exports", "methods", "stale_ignores",
  },

  globals = {},                    -- names that are meant to be global

  methods = false,
  ignore_methods = false,          -- never report a `function C:m()` declaration
  skip_unparsable_files = false,
  skip_module_collisions = false,
  format = "text",

  checks = {
    symbols = true, globals = true, exported_namespaces = true,
    function_modules = true, private_modules = true, private_symbols = true,
    exports = true, methods = false, stale_ignores = true,
  },
}
```

The config file is **parsed, never executed**. Rockspecs and `.privata.lua` are
both Lua source, and loading them would mean running arbitrary code just to scan
a checkout. The cost is that a config cannot compute: `source_roots =
vim.fn.glob(...)` is an error, not a list.

### References written as strings

A name is not only reached by code. privata resolves `require'mod'.name` and
`v:lua.NAME` **inside string literals** and treats them as real references,
because they are:

```lua
vim.wo.foldexpr = "v:lua.require'mod.folds'.foldexpr(v:lnum)"
```

That resolves through `require` when the option is evaluated and indexes the
returned table, so moving the target to a file-local breaks the editor at
runtime — not at load time, and not in the test suite. The string usually sits
in the module it names, so these count as **entry points** rather than
cross-module reads; a module referring to itself is otherwise ignored.

For a bare name in a string — a dispatch table, `_G[name]`, `vim.fn[name]` — the
finding is **annotated, never suppressed**:

```
      name also appears in a string at lua/pkg/dispatch.lua:14 -- check it is not reached by name
```

privata cannot tell that from a coincidence, so it says what it saw and leaves
the decision to you rather than silently recommending a breaking rename.

### References written as types

A class module is reached through its **instances**, never through its table.
Nothing anywhere writes `code_item.position` — the caller was handed a value and
calls `item:position()` on it — so the require graph has no edge to follow, and
every method on the class looks unread. That is the worst false positive
available: acting on it moves a method three other files call.

The edge is already written down, in the annotation the caller needed anyway.
privata reads four LuaCATS tags and joins them:

```lua
-- lua/pkg/item.lua
---@class pkg.Item          -- the declaring side: this module owns that type
local Item = {}
Item.__index = Item
function Item:position() end
return Item
```

```lua
-- lua/pkg/report.lua       -- requires nothing from pkg.item, and still calls it
---@param item pkg.Item     -- a function argument
---@type pkg.Item           -- the declaration underneath it
---@cast item pkg.Item      -- a variable re-typed from here on
```

Both spellings of a read count, because a rename breaks both: `item:position()`
and `item.line`. The type may be named anywhere inside a type expression —
`pkg.Item[]`, `pkg.Item|nil`, `table<string, pkg.Item>` all name it — and the
description after the type is prose, so a class name mentioned only there is not
a reference.

Three rules bound it, and each is the same rule the reference scan already has:

- only the `---@class` on the **returned** table counts. A file declares an
  options record and a result shape too, and those are not its interface.
- a module's own annotations certify nothing about its own methods.
- an annotation in a spec certifies nothing, exactly as a call from one does.

It follows a **declared** type, never an inferred one. `local x = item` retypes
nothing privata can see, and neither does `items[1]` or the loop variable in
`for _, item in ipairs(items)`. A codebase with no annotations gets exactly the
behaviour it had before this existed.

Where the dispatch is beyond reading at all — methods handed to a host, stored
in a callback table, reached through a metatable chain assembled at runtime —
the alternative to an `-- privata: ignore` on every method in the project is to
take methods out of the check entirely:

```lua
ignore_methods = true,
```

A symbol declared `function C:m()` is then never reported. The colon is the whole
signal: it is the one declaration form that says, in the language itself, that
the name is called on an instance, so `function C.new()` on the same table is
still reported. privata refuses to run this alongside the method check rather
than half-applying either, since one exists to report methods and the other
exists never to.

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
  testable from specs; the weakest form, last by default. Note that `_` then
  carries two meanings in one codebase — module-internal-but-test-reachable
  here, and package-internal if you use `package_private`. Usage disambiguates
  them, but it is worth knowing before adopting both.

**Test reachability overrides the order.** Test usage still does not make a
symbol public — that policy is unchanged. But it does decide which
privatisation is *legal*: a spec holds the module table and nothing else, so a
field moved to a file-local leaves the spec calling nil. When a spec reads the
symbol, privata recommends `M._foo`, which stays reachable, and says why:

```
lua/pkg/git.lua:407: function `M.parse_diff` -> rename to `M._parse_diff`
    also read at :565
    read by spec/git_spec.lua:204 -- keep it on the table so the spec can still reach it
```

A spec that *assigns* `mod.name = function() … end` is using the table as an
injection seam, and privatising the field deletes it. That gets its own note,
because the rename is not free — the spec has to change too.

privata **only ever recommends narrowing an interface**, and there is no
`--fix`. Where the private-symbol check proves a private name is read from
elsewhere, that is reported as a boundary to fix at the call site, not as a hint
to publish the name.

### Package-private names

privata otherwise models two visibility levels: on the interface, or file-local.
Real codebases have a third. `M._SHARED` read by eight sibling modules of one
application is not eight boundary violations with call sites to fix — it is
Java's package-private, Rust's `pub(crate)`, Go's `internal/`.

```lua
package_private = { "modules" },
```

Private names are then readable from any module under `modules.*`, and still
reported when read from outside it. Empty by default: for a library, a sibling
reaching into another module's internals is worth knowing about, and only the
project can say which it is.

Because the default is empty and this setting is what makes the whole section go
away, the section says so itself rather than leaving you to find it here:

```text
Found 20 private symbols read from another module (36 reads):

  (if these are package-internal by design, set `package_private`)
```

### Adopting on an existing codebase

A checker that goes red on day one and cannot go green gets `|| true`'d, and the
findings that *were* worth blocking on are lost with the rest.

**`fail_on`** names the kinds that exit non-zero. All of them by default. This
is what `checks` cannot express: switching a check off also stops it reporting,
so "tell me but do not block me" had no spelling.

```lua
fail_on = { "globals", "unparsable", "collisions" },
```

For anything finer-grained than a kind, the mechanism is `-- privata: ignore` on
the line itself. It is deliberately the only way to dismiss an individual
finding: a dismissal that lives next to the code it excuses is one a reviewer
sees in the diff, and one that stops applying the moment the line changes. A
recorded list of blessed findings kept somewhere else is neither.

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
local function run() end … return run        -- function module
return function(…) … end                     -- the same, unnamed
return setmetatable(M, mt)                   -- wrapped
-- and a file with no return at all         -- side-effect module
```

A file whose whole export is a function is a **function module**:

```lua
-- lua/thing/get_foo.lua
local function get_foo(count)
  return count + 1
end

return get_foo
```

```lua
local get_foo = require("thing.get_foo")
get_foo(10)
```

It publishes no fields — the function *is* the interface, entire — so the symbol
check has nothing to say about it. What can still be wrong is whether anything
requires the module at all, so the question the symbol check asks per field is
asked here per module:

```text
Found 1 module returning a function that nothing requires:

  lua/thing/orphan.lua:1: returns function `run`, which no other module requires
      rename the module to `thing._orphan`, or delete it
```

A require is enough — the result may be called, passed on, or stored. Requires
from installed scripts, the rock's namesake module, `entrypoint_modules` and
`require` written inside a string all count, exactly as they do for a symbol.
Test usage does not, on the same rule as everywhere else; the spec is named in
the report, and the rename is a change the suite survives, since a spec may
require a private module.

A module the `private_module_patterns` already mark private is left alone: there
is no publicity left to remove, and privata reports interface drift rather than
dead code. Switch the whole check off with `checks = { function_modules = false }`.

A file that returns nothing is a **side-effect module**, not a failure to read.
Setting autocommands, installing keymaps, registering commands: the file runs
for what it does, and exporting nothing is the point. It publishes no interface,
so it has no symbols to report — but it is still parsed, and the names it reads
still count as uses of the modules it requires.

A side-effect module that returns `_P` anyway is usually doing it so a spec has
something to require. privata says so, and the advice it gives is neither of the
two obvious ones, because both are wrong here — returning nothing breaks the
spec, and renaming to `M` publishes every field:

```text
Found 1 module returning the private namespace as a test handle
(nothing in production reads it; advisory, never blocks):

  lua/app/winbar.lua:989: returns `_P`, so all 38 fields on it are public
      held by spec/winbar_spec.lua:42, and no production module reads it
      if that is deliberate, say so: `local M = {}; M._P = _P; return M`
```

That publishes one clearly-marked seam instead of thirty-eight fields, which is
narrower than either alternative. These findings are advisory: they print in
their own section and never decide the exit code, because privata has already
concluded there is no action that would improve the file. A module whose return
value production *does* read is a different finding, and still gets the rename.

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

Line-scoped: it suppresses the finding on that line and nothing else. It works
on **every** finding kind — public symbols, globals, private-module requires,
private-symbol reads, export-table entries, exported namespaces, methods, an
undetermined module shape, and even a file that will not parse.

Two things worth knowing:

- On an unparsable file it silences the *report*, not the consequence. The file
  still contributes no references, so findings elsewhere may still be wrong.
  That is the same trade `--skip-unparsable-files` makes, scoped to one file.
- It is matched against raw source text, so it does not need code on the line to
  be recognised — but a comment on its own line matches no finding, because
  findings are located by the line they occur on.
- The marker must be the **first thing in the comment**. Anything may follow it,
  so `-- privata: ignore (the host calls this)` works, but a line that merely
  mentions the marker in prose is not a directive — documentation about this
  feature is written in Lua comments too.

Module-name collisions are the one thing it cannot suppress: a collision is a
fact about two files, so there is no single line to put it on. Use
`--skip-module-collisions`.

### Ignores that have gone stale

An ignore is a claim that there is a finding here and it is deliberate. Once the
finding is gone — the symbol was made private, the global got its `local`, the
read moved — the comment is a claim about nothing, and it will silently swallow
the *next* finding on that line. privata reports it:

```text
Found 2 unused `privata: ignore` comments that can be removed:

  lua/pkg/init.lua:3: unused ignore -- nothing on this line is reported
      the comment is on a line of its own; a finding is reported against the line its code is on
  lua/pkg/service.lua:7: unused ignore -- nothing on this line is reported
```

Every check records the comments it honoured, including the checks this run was
not asked to report. An ignore on a method stays live with `methods` off,
because it is doing its job the moment the check comes back.

Two kinds of file are exempt, because an unused ignore in them proves nothing: a
file whose shape privata could not read contributes no symbols at all, and one
that exports its private namespace has its per-field findings suppressed by
privata itself. Switch the check off with `checks = { stale_ignores = false }`.

## The method check

Off by default, because Lua method dispatch through metatable chains is *more*
dynamic than Python attribute access, not less.

A method is reported when no other production module mentions its name — as
`obj:name()`, as `t.name`, as a string literal, or through a type-annotated
instance. Matching is by name rather than by receiver, so an unrelated
`other.run` elsewhere conservatively suppresses a report for `Service.run`.

A class is skipped when anything links a metatable to it, when it indexes itself
by a computed name, or when it is reached through `_G` or `load`. Dispatch
privata cannot see at all — a table of bound methods assembled elsewhere, a name
forwarded through `...` — is **not supported** and will produce false positives.
Use `-- privata: ignore`.

## What privata cannot see

**Dispatch it cannot resolve.** The symbol check has the same blind spot the
method check documents: a name assembled at runtime (`handlers["run_" .. mode]`),
reached through `_G[name]`, `vim.fn[name]`, `load()`, or forwarded through `...`
is invisible. privata resolves the two string shapes it can (above), follows a
declared type to the module that owns it, and annotates a third; beyond that,
`-- privata: ignore` is the answer, or `ignore_methods` where the whole category
is out of reach.

**Intent that has not been exercised.** privata infers intent from observed
usage, which holds for an application — every consumer is in-repo — and inverts
for a library, whose callers are outside it by definition. A library's entire
public API can look like drift. Try it on privata itself: it is clean, but move
`privata-scm-1.rockspec` aside and its whole documented API is flagged, because
the rockspec's `build.modules` was the only thing saying which module consumers
require.

The in-band answer is `entrypoint_modules`, which does not depend on packaging:

```lua
return { entrypoint_modules = { "mylib", "mylib.cli" } }
```

A deliberate API not yet called, a hook point kept for extension, a function
published for downstream consumers who are not in this checkout — none of that
is recoverable from the code, and privata does not pretend otherwise.

**Whether test usage should count is a position, not a derivation.** privata
holds that it does not establish publicness but does constrain which
privatisation is legal. An application team usually wants that; a library team
may reasonably want the opposite. It is a choice, documented as one.

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
