--- fxmanifest.lua as FiveM reads it: each list by its key, globs expanded.
---
--- The manifest is Lua whose every unknown name is a directive taking a
--- value or a table (`server_scripts { ... }`). It runs here against a
--- table that records them. A glob expands as FiveM's does
--- (ResourceMetaDataComponent::GlobValue): `*` within one folder, `**`
--- across folders, the files of one entry in sorted order, and an entry
--- starting with @ (another resource's file) kept as it is.

local Manifest = {}

local ROOT = 'crimson-hitman/'

--- Every file in the resource, relative to its root, once per process.
local everyFile
local function files()
    if everyFile then return everyFile end
    everyFile = {}
    local pipe = assert(io.popen('cd ' .. ROOT .. ' && find . -type f | sort'))
    for line in pipe:lines() do everyFile[#everyFile + 1] = line:gsub('^%./', '') end
    pipe:close()
    return everyFile
end

local function globPattern(glob)
    local out = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')
    out = out:gsub('%*%*/', '\1'):gsub('%*%*', '\2'):gsub('%*', '[^/]*')
    out = out:gsub('\1', '.-'):gsub('\2', '.*')
    return '^' .. out .. '$'
end

--- One entry's files, as FiveM expands it.
---@param entry string
---@return string[]
function Manifest.expand(entry)
    if entry:sub(1, 1) == '@' then return { entry } end
    if not entry:find('*', 1, true) then
        for _, f in ipairs(files()) do
            if f == entry then return { entry } end
        end
        return {}
    end
    local pattern, out = globPattern(entry), {}
    for _, f in ipairs(files()) do
        if f:match(pattern) then out[#out + 1] = f end
    end
    table.sort(out)
    return out
end

local parsed

--- The manifest's lists, by key, as written: { server_scripts = { ... } }.
---@return table<string, string[]>
function Manifest.lists()
    if parsed then return parsed end
    parsed = {}
    local env = setmetatable({}, { __index = function(_, key)
        return function(value)
            local list = parsed[key] or {}
            parsed[key] = list
            if type(value) == 'table' then
                for _, v in ipairs(value) do list[#list + 1] = v end
            else
                list[#list + 1] = value
            end
            -- `name 'x'` and `server_scripts { }` both end here; a directive
            -- written as `key 'a' 'b'` would call again.
            return function() end
        end
    end })
    assert(loadfile(ROOT .. 'fxmanifest.lua', 't', env))()
    return parsed
end

--- A list's files in the order the runtime loads them, globs expanded.
---@param key string 'server_scripts', 'client_scripts', 'shared_scripts', ...
---@return string[]
function Manifest.files(key)
    local out = {}
    for _, entry in ipairs(Manifest.lists()[key] or {}) do
        for _, f in ipairs(Manifest.expand(entry)) do out[#out + 1] = f end
    end
    return out
end

--- What the server runs at start, in order: the shared scripts, then the
--- server scripts (another resource's files, @..., left out).
---@return string[]
function Manifest.serverScripts()
    local out = {}
    for _, key in ipairs({ 'shared_scripts', 'server_scripts' }) do
        for _, f in ipairs(Manifest.files(key)) do
            if f:sub(1, 1) ~= '@' then out[#out + 1] = f end
        end
    end
    return out
end

return Manifest
