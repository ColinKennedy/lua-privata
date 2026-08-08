--- Build throwaway projects on disk for specs to scan.
--
-- Every behavioural spec writes a small fake project and asserts on what
-- privata makes of it, which keeps the tests arguing about rules rather than
-- about fixtures checked into the repository.

local fs = require("privata._fs")

local M = {}
local _P = {}

_P.counter = 0

function _P.mkdir_p(path)
  os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
end

--- Create a project directory containing `files`, a map of relative path to
--- contents. Returns the project root.
function _P.write(files)
  _P.counter = _P.counter + 1
  local root = fs.join(
    os.getenv("TMPDIR") or "/tmp",
    string.format("privata-spec-%d-%d", os.time(), _P.counter)
  )
  _P.mkdir_p(root)

  local names = {}
  for name in pairs(files) do
    names[#names + 1] = name
  end
  table.sort(names)

  for i = 1, #names do
    local name = names[i]
    local path = fs.join(root, name)
    _P.mkdir_p(fs.dirname(path))
    local handle = assert(io.open(path, "wb"))
    handle:write(files[name])
    handle:close()
  end

  return fs.normalize(root)
end

function _P.remove(root)
  if root and root:find("privata%-spec%-") then
    os.execute("rm -rf '" .. root:gsub("'", "'\\''") .. "'")
  end
end

--- Run `body(root)` against a temporary project and always clean up after it.
function M.with(files, body)
  local root = _P.write(files)
  local ok, err = pcall(body, root)
  _P.remove(root)
  if not ok then
    error(err, 0)
  end
end

return M
