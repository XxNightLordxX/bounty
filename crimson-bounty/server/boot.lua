--- Module loader, and the wait for everything this resource stands on.
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
    if loaded[path] ~= nil then return loaded[path] end
    if loading[path] then
        error(('[crimson-bounty] circular require: %s'):format(path))
    end

    loading[path] = true

    -- Cleared on the way out of every branch, not only the one that works.
    --
    -- A module that errors while loading left this set, so the next attempt
    -- to load it reported a circular require — a made-up diagnosis, in place
    -- of the real error, at exactly the moment somebody is trying to find
    -- out why the resource will not start.
    local function done(value)
        loading[path] = nil
        return value
    end

    local file = path:gsub('%.', '/') .. '.lua'
    local source = LoadResourceFile(GetCurrentResourceName(), file)
    if not source then
        done()
        error(('[crimson-bounty] missing module file: %s'):format(file))
    end

    local chunk, err = load(source, '@' .. file)
    if not chunk then
        done()
        error(('[crimson-bounty] failed to compile %s: %s'):format(file, err))
    end

    local ok, module = pcall(chunk)
    if not ok then
        done()
        error(module, 0)
    end

    -- `module or true` cached a module that returned nothing as `true`, and
    -- every later require of it then handed the caller a boolean where a
    -- table was expected. Every file here returns a table, so it never
    -- happened — and if one ever stops, the error should name the file
    -- rather than surface as "attempt to index a boolean" somewhere else.
    if type(module) ~= 'table' then
        done()
        error(('[crimson-bounty] %s returned %s, not a module table')
            :format(file, type(module)))
    end

    loaded[path] = module
    return done(module)
end

--- Shared modules live under shared/ and are loaded the same way.
function require_shared(name)
    return require('shared.' .. name)
end

--------------------------------------------------------------------------
-- Waiting for the resources this one is built on
--------------------------------------------------------------------------

--- What this resource cannot start without, and what each is for.
---
--- The message matters as much as the wait: 'qbx_core' is a resource NAME,
--- and a server running a fork or a rename has a framework that works
--- perfectly and a name this never matches.
local DEPENDENCIES = {
    { name = 'qbx_core',
      why = 'players, jobs and money are read through it' },
    { name = 'ox_inventory',
      why = 'items and weapons cannot be escrowed without it' },
}

--- Seconds of quiet before the first report. A server coming up has
--- everything missing for a moment, and saying so immediately is noise.
local GRACE_SECONDS = 15
--- And how often to repeat afterwards, so somebody who looks at the console
--- late still finds out.
local REPEAT_SECONDS = 30

CrimsonBoot = {}

--- Which dependencies are not started yet.
---@return table[] entries from DEPENDENCIES
function CrimsonBoot.missingDependencies()
    local missing = {}
    for i = 1, #DEPENDENCIES do
        local entry = DEPENDENCIES[i]
        if GetResourceState(entry.name) ~= 'started' then
            missing[#missing + 1] = entry
        end
    end
    return missing
end

--- Whether a wait this long should say something.
---@param waited integer seconds waited so far
---@return boolean
function CrimsonBoot.shouldReport(waited)
    if waited < GRACE_SECONDS then return false end
    return ((waited - GRACE_SECONDS) % REPEAT_SECONDS) == 0
end

--- What to print about a wait, as lines.
---
--- Named separately from the printing so a test can read the words rather
--- than capture a global.
---@param missing table[]
---@param waited integer
---@return string[]
function CrimsonBoot.waitReport(missing, waited)
    local lines = {
        ('[crimson-bounty] still waiting after %ds for %d resource(s) to start:')
            :format(waited, #missing),
    }
    for i = 1, #missing do
        lines[#lines + 1] = ('[crimson-bounty]   %s is %s — %s')
            :format(missing[i].name, GetResourceState(missing[i].name), missing[i].why)
    end
    lines[#lines + 1] = '[crimson-bounty] a renamed or forked resource will never '
        .. 'match these names; nothing else is wrong and nothing will happen '
        .. 'until they do.'
    return lines
end

--- Block until everything is up, saying what is missing while it waits.
---
--- This loop used to have no output and no end. A dependency that is
--- renamed, forked, or simply failed to start left the resource here
--- forever with nothing in the console — no error, no warning, not one line
--- — which to an operator is indistinguishable from a resource that started
--- and does nothing. It still waits forever, because a dependency starting
--- late is ordinary and giving up would be worse; it no longer waits in
--- silence.
---
--- Bounded only by `limit`, which exists so a test can run it.
---@param limit integer|nil maximum seconds to wait
---@return boolean ready
function CrimsonBoot.awaitDependencies(limit)
    local waited = 0
    while true do
        local missing = CrimsonBoot.missingDependencies()
        if #missing == 0 then
            if waited >= GRACE_SECONDS then
                print(('[crimson-bounty] everything it waits for is up after %ds; starting.')
                    :format(waited))
            end
            return true
        end

        if CrimsonBoot.shouldReport(waited) then
            for _, line in ipairs(CrimsonBoot.waitReport(missing, waited)) do
                print(line)
            end
        end

        if limit and waited >= limit then return false end
        Wait(1000)
        waited = waited + 1
    end
end

CreateThread(function()
    -- Wait for the framework and inventory before wiring anything up, so a
    -- slow start does not produce a half-initialised resource.
    if not CrimsonBoot.awaitDependencies() then return end

    local ok, err = pcall(StartCrimsonBounty)
    if not ok then
        print('[crimson-bounty] failed to start: ' .. tostring(err))
    end
end)
