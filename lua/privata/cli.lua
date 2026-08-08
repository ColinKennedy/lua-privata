--- Command-line entry point.

local checker = require("privata._checker")
local config_mod = require("privata._config")
local fs = require("privata._fs")
local json_report = require("privata._report.json")
local text_report = require("privata._report.text")

local M = {}
local _P = {}

_P.EXIT_OK = 0
_P.EXIT_FINDINGS = 1
_P.EXIT_USAGE = 2

_P.USAGE = [[
usage: privata [project-root] [options]

Find Lua code that looks public but is only used privately.

Options:
  --methods                   Also report public methods no other module refers
                              to. Off by default: Lua dispatch is dynamic, so
                              this check cannot see every caller.
  --skip-unparsable-files     Downgrade unparsable files from error to warning.
  --skip-module-collisions    Downgrade colliding module names to a warning.
                              Separate from the flag above on purpose: a
                              collision means privata read the wrong file.
  --namespace NAME            Private namespace to recommend (default: _P).
  --preset NAME               Apply a shipped preset, e.g. neovim.
  --format text|json          Output format (default: text).
  --version                   Print the version and exit.
  -h, --help                  Print this message and exit.

Exit codes: 0 clean, 1 findings, 2 bad usage or configuration.]]

local FLAGS = {
  ["--methods"] = { key = "methods", value = true },
  ["--skip-unparsable-files"] = { key = "skip_unparsable_files", value = true },
  -- Both spellings are in common use; rejecting one would be a papercut.
  ["--skip-unparseable-files"] = { key = "skip_unparsable_files", value = true },
  ["--skip-module-collisions"] = { key = "skip_module_collisions", value = true },
}

local OPTIONS = {
  ["--namespace"] = "namespace",
  ["--preset"] = "preset",
  ["--format"] = "format",
}

--- Parse argv into a project root and a config overlay.
function _P.parse_arguments(argv)
  local overrides = {}
  local project_root = nil
  local index = 1

  while index <= #argv do
    local argument = argv[index]

    if argument == "-h" or argument == "--help" then
      return nil, nil, "help"
    elseif argument == "--version" then
      return nil, nil, "version"
    elseif FLAGS[argument] then
      overrides[FLAGS[argument].key] = FLAGS[argument].value
    elseif OPTIONS[argument] then
      local value = argv[index + 1]
      if value == nil then
        return nil, nil, argument .. " needs a value"
      end
      overrides[OPTIONS[argument]] = value
      index = index + 1
    elseif argument:sub(1, 1) == "-" then
      local key, value = argument:match("^(%-%-[%w-]+)=(.*)$")
      if key and OPTIONS[key] then
        overrides[OPTIONS[key]] = value
      else
        return nil, nil, "unknown option " .. argument
      end
    elseif project_root == nil then
      project_root = argument
    else
      return nil, nil, "unexpected argument " .. argument
    end

    index = index + 1
  end

  return project_root or ".", overrides
end

function _P.write(stream, text)
  stream:write(text)
  stream:write("\n")
end

--- Run privata. Returns an exit code.
function M.main(argv, io_streams)
  local out = (io_streams and io_streams.out) or io.stdout
  local err = (io_streams and io_streams.err) or io.stderr

  local project_root, overrides, problem = _P.parse_arguments(argv or {})

  if problem == "help" then
    _P.write(out, _P.USAGE)
    return _P.EXIT_OK
  end
  if problem == "version" then
    _P.write(out, "privata " .. require("privata")._VERSION)
    return _P.EXIT_OK
  end
  if problem then
    _P.write(err, "privata: " .. problem)
    _P.write(err, _P.USAGE)
    return _P.EXIT_USAGE
  end

  project_root = fs.normalize(project_root)
  if not fs.is_dir(project_root) then
    _P.write(err, "privata: not a directory: " .. project_root)
    return _P.EXIT_USAGE
  end

  local config, problems = config_mod.load(project_root, overrides)
  if not config then
    for i = 1, #problems do
      _P.write(err, "privata: " .. problems[i])
    end
    return _P.EXIT_USAGE
  end

  local findings = checker.run(project_root, config)

  if config.format == "json" then
    _P.write(out, json_report.render(findings, project_root, config))
  else
    _P.write(out, text_report.render(findings, project_root, config))
  end

  if checker.has_failures(findings, config) then
    return _P.EXIT_FINDINGS
  end
  return _P.EXIT_OK
end

--- Exposed so this module's own specs can exercise internals directly.
--
-- privata's rule is that test usage does not make a name public, so the
-- alternative would be publishing helpers nobody else calls. Naming the seam
-- explicitly is the honest version of the same access.
M._P = _P

return M
