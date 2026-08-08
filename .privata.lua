-- privata's configuration for privata.
--
-- The tool runs on itself in CI, which is the point: the opt-in method check's
-- false positives surface here before they reach anyone else, and every rule
-- privata recommends is one its own source has had to follow.
return {
  source_roots = { "lua" },
  test_roots = { "spec" },

  -- The default, stated explicitly because this file is also the worked
  -- example the README points at.
  privatize = { "namespace", "local_function", "underscore_field" },
  namespace = "_P",

  methods = true,
}
