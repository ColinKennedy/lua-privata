#!/usr/bin/env lua
-- Fail the build when luacov's summary falls below a threshold.
--
-- luacov reports coverage but does not gate on it, and a coverage number
-- nothing enforces drifts down one commit at a time.

local threshold = tonumber(arg[1] or "100")
local report_path = arg[2] or "luacov.report.out"

local handle = io.open(report_path, "r")
if not handle then
  io.stderr:write("check_coverage: no report at " .. report_path .. "\n")
  os.exit(2)
end

local text = handle:read("*a")
handle:close()

-- The summary's final Total line carries the project-wide percentage.
local total = nil
for hits, missed, percent in text:gmatch("Total%s+(%d+)%s+(%d+)%s+([%d%.]+)%%") do
  total = { hits = tonumber(hits), missed = tonumber(missed), percent = tonumber(percent) }
end

if not total then
  io.stderr:write("check_coverage: could not find a Total line in " .. report_path .. "\n")
  os.exit(2)
end

print(
  string.format("coverage: %.2f%% (%d hit, %d missed)", total.percent, total.hits, total.missed)
)

if total.percent + 1e-9 < threshold then
  io.stderr:write(
    string.format("check_coverage: %.2f%% is below %.2f%%\n", total.percent, threshold)
  )
  os.exit(1)
end
