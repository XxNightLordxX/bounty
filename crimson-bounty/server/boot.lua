--- Module loader.
---
--- FiveM has no package system, so `require_shared` and a small module
--- registry stand in. Every server file returns a table and is loaded exactly
--- once, in dependency order, by server/main.lua.

local loaded = {}
local loading = {}

--- Load a module by path relative to the resource root, without the .lua.
---@param path string e.g. 'server.escrow'
---@return table
function require(path)
    if loaded[path] then return loaded[path] end
    if loading[path] then
        error(('[crimson-bounty] circular require: %s'):format(path))
    end

    loading[path] = true

    local file = path:gsub('%.', '/') .. '.lua'
    local source = LoadResourceFile(GetCurrentResourceName(), file)
    if not source then
        error(('[crimson-bounty] missing module file: %s'):format(file))
    end

    local chunk, err = load(source, '@' .. file)
    if not chunk then
        error(('[crimson-bounty] failed to compile %s: %s'):format(file, err))
    end

    local module = chunk()
    loaded[path] = module or true
    loading[path] = nil
    return loaded[path]
end

--- Shared modules live under shared/ and are loaded the same way.
function require_shared(name)
    return require('shared.' .. name)
end

CreateThread(function()
    -- Wait for the framework and inventory before wiring anything up, so a
    -- slow start does not produce a half-initialised resource.
    while GetResourceState('qbx_core') ~= 'started' do Wait(250) end
    while GetResourceState('ox_inventory') ~= 'started' do Wait(250) end

    local ok, err = pcall(StartCrimsonBounty)
    if not ok then
        print('[crimson-bounty] failed to start: ' .. tostring(err))
    end
end)
