.PHONY: all check check-stylua clean coverage download-dependencies llscheck luacheck privata stylua test

# Git will error if the repository already exists. We ignore the error.
# NOTE: We still print out that we did the clone to the user so that they know.
#
ifeq ($(OS),Windows_NT)
    IGNORE_EXISTING =
else
    IGNORE_EXISTING = 2> /dev/null || true
endif

CONFIGURATION = .luarc.json
SOURCES = lua spec bin scripts
ARGUMENTS ?=

# Not 100: _fs.lua carries three filesystem backends and only one of them can
# execute on any given interpreter. See .luacov.
COVERAGE_THRESHOLD ?= 92

# Everything CI runs, in the order CI runs it.
all: check

check: luacheck check-stylua llscheck test privata

# LuaCATS definitions for the busted globals and luassert's `assert.same` and
# friends. Without them llscheck reports every spec assertion as an undefined
# field. Cloned over HTTPS so CI needs no key material.
download-dependencies:
	git clone https://github.com/LuaCATS/busted.git .dependencies/busted $(IGNORE_EXISTING)
	git clone https://github.com/LuaCATS/luassert.git .dependencies/luassert $(IGNORE_EXISTING)

llscheck: download-dependencies
	llscheck --configpath $(CONFIGURATION) .

luacheck:
	luacheck $(ARGUMENTS) $(SOURCES)

check-stylua:
	stylua $(SOURCES) --color always --check

stylua:
	stylua $(SOURCES)

test:
	busted $(ARGUMENTS)

coverage:
	busted --coverage
	lua scripts/check_coverage.lua $(COVERAGE_THRESHOLD)

# privata on itself. Any internal helper must either live in `_P` or be
# genuinely used across modules, or this fails.
privata:
	LUA_PATH="./lua/?.lua;./lua/?/init.lua;;" lua bin/privata.lua . $(ARGUMENTS)

clean:
	rm -rf luacov.stats.out luacov.report.out .dependencies
