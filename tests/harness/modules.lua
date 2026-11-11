--- The resource's modules, loaded the way the manifest and server/boot.lua
--- load them, through the runtime's require.
---
--- Every module file hands its body to CrimsonBoot.define in its first line
--- (server/boot.lua). On a live server the manifest runs the file, which
--- only stores the body, and CrimsonBoot.require runs it once. Here a
--- searcher in front of Lua's own does the same for 'server.x',
--- 'shared.x' and 'crimson-hitman.server.x': it runs the file, insists it
--- defined exactly one body under its own path, and runs that. Lua's
--- package.loaded is the cache, so a suite that clears an entry gets a
--- fresh copy of the module, as it always has.
---
--- A file that is not a module (server/main.lua, config, locales, the
--- client's files, shared/constants.lua) is left to Lua's own searcher.

local Modules = {}

Modules.ROOT = 'crimson-hitman/'

--- Files under server/ and shared/ that are manifest scripts in their own
--- right rather than modules.
Modules.NOT_MODULES = {
    ['server/boot.lua'] = true,          -- the loader itself
    ['server/main.lua'] = true,          -- the start, listed last
    ['server/adapters/TEMPLATE.lua'] = true,  -- never loaded; a copy is
    ['shared/constants.lua'] = true,     -- a shared script (CH)
}

--- The module name a resource file defines: 'server/lib/db.lua' is
--- 'server.lib.db'. nil for a file that is not a module.
---@param path string from the resource root
---@return string|nil
function Modules.nameOf(path)
    if Modules.NOT_MODULES[path] then return nil end
    if not (path:match('^server/.+%.lua$') or path:match('^shared/.+%.lua$')) then return nil end
    return (path:gsub('%.lua$', ''):gsub('/', '.'))
end

--- The bodies being defined, innermost last: a file's chunk only calls
--- CrimsonBoot.define, so this is never more than one deep in practice.
local pending = {}

--- The harness's CrimsonBoot.define: records the body for the file being
--- loaded. Called anywhere else it is a mistake, said as one.
function Modules.define(name, factory)
    local top = pending[#pending]
    if not top then
        error(('CrimsonBoot.define(%q) outside a module load: a client env needs client/boot.lua first')
            :format(tostring(name)), 2)
    end
    top.count = top.count + 1
    top.name, top.factory = name, factory
end

local function exists(file)
    local handle = io.open(file, 'r')
    if handle then handle:close() return true end
    return false
end

local function searcher(modname)
    local rel = modname:gsub('^crimson%-hitman%.', '')
    if not (rel:match('^server%.') or rel:match('^shared%.')) then return nil end
    -- The same file name Lua's own searcher found, so a stack trace and the
    -- coverage report name the file as before.
    local file = package.searchpath(rel, './' .. Modules.ROOT .. '?.lua')
    if not file or not exists(file) then return nil end
    local path = file:gsub('^%./' .. Modules.ROOT:gsub('%-', '%%-'), '')
    local expected = Modules.nameOf(path)
    if not expected then return nil end
    return function()
        local chunk = assert(loadfile(file))
        local slot = { count = 0 }
        pending[#pending + 1] = slot
        local ok, err = pcall(chunk)
        table.remove(pending)
        if not ok then error(err, 0) end
        if slot.count ~= 1 or slot.name ~= expected then
            error(('%s must call CrimsonBoot.define(%q, ...) exactly once; it called it %d time(s)%s')
                :format(path, expected, slot.count, slot.name and (', last as ' .. slot.name) or ''), 0)
        end
        local module = slot.factory()
        if type(module) ~= 'table' then
            error(('%s returned %s, not a module table'):format(path, type(module)), 0)
        end
        return module
    end, file
end

local installed = false

--- Put the searcher in front of Lua's file searcher, and the harness's
--- CrimsonBoot in the global table (unless one is there already).
function Modules.install()
    if not installed then
        table.insert(package.searchers, 2, searcher)
        installed = true
    end
    if not rawget(_G, 'CrimsonBoot') then
        -- Through the global require at call time rather than capturing it
        -- here, so a wrapper installed around it (tests/invariants.lua) still
        -- sees every module a server file asks for.
        _G.CrimsonBoot = {
            define = Modules.define,
            require = function(path) return require(path) end,
            requireShared = function(name) return require('crimson-hitman.shared.' .. name) end,
        }
    end
    return _G.CrimsonBoot
end

return Modules
