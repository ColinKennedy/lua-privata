--- Defaults for a Neovim plugin, where the host loads code nothing requires.
--
-- Everything here is a default the user's own `.privata.lua` still overrides.
-- The preset exists because the entrypoint rules are not guessable: a file in
-- `plugin/` runs at startup and a `health.lua` runs on `:checkhealth`, so their
-- top-level bindings are public even though no module ever requires them.

return {
  source_roots = { "lua" },

  test_roots = { "tests", "spec", "lua/tests" },

  -- Loaded by Neovim itself, never required.
  entrypoint_globs = {
    "plugin/**/*.lua",
    "ftplugin/**/*.lua",
    "after/**/*.lua",
    "colors/**/*.lua",
    "syntax/**/*.lua",
    "indent/**/*.lua",
    "compiler/**/*.lua",
  },

  -- `M.setup` is the near-universal plugin entry point and `check` is what
  -- `:checkhealth` calls; both are public by convention, not by reference.
  entrypoint_names = { "setup", "check" },

  entrypoint_modules = { "health", "*.health" },

  globals = { "vim" },
}
