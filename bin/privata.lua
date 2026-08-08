#!/usr/bin/env lua
-- Console entry point installed by the rockspec as `privata`.

local cli = require("privata.cli")

os.exit(cli.main(arg))
