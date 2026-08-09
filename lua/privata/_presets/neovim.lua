--- Defaults for a Neovim plugin, where the host loads code nothing requires.
--
-- Everything here is a default the user's own `.privata.lua` still overrides.
-- The preset exists because a Neovim plugin's public surface is not guessable
-- from its code: `M.setup` is the near-universal way a plugin is configured and
-- `check` is what `:checkhealth` calls, so both are public by convention rather
-- than by any reference privata can see.
--
-- The interface entries are tach's, and read as they do there: `expose` and
-- `from` are regular expressions matching a whole name, and an entry with no
-- `from` applies to every module.

return {
  source_roots = { "lua" },

  test_roots = { "tests", "spec", "lua/tests" },

  interfaces = {
    -- Called by the host, wherever the plugin defines them.
    { expose = { "setup", "check" } },

    -- `:checkhealth` loads a health module for its own sake and reaches
    -- whatever it finds there, so the whole module is surface.
    { expose = { ".*" }, from = { "health", ".*\\.health" } },
  },

  globals = { "vim" },
}
