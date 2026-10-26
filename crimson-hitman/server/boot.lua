--- Module loader, and the wait for everything this resource stands on.
---
--- FiveM has no package system, so CrimsonBoot.require and a small module
--- registry stand in. Every server file returns a table and is loaded exactly
--- once, in dependency order, by server/main.lua.
---
--- The loader lives in this resource's one server namespace table rather
--- than as bare globals. It used to replace the runtime's own `require`
--- (and add a lowercase `require_shared` beside it), which every other
--- script in this Lua state saw too: anything that reached for the real
--- loader got this one, with its resource-root paths and its errors.

CrimsonBoot = {}

local loaded = {}
local loading = {}

--- Load a module by path relative to the resource root, without the .lua.
---@param path string e.g. 'server.escrow'
---@return table
function CrimsonBoot.require(path)
    if loaded[path] ~= nil then return loaded[path] end
    if loading[path] then
        error(('[crimson-hitman] circular require: %s'):format(path))
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
        error(('[crimson-hitman] missing module file: %s'):format(file))
    end

    local chunk, err = load(source, '@' .. file)
    if not chunk then
        done()
        error(('[crimson-hitman] failed to compile %s: %s'):format(file, err))
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
        error(('[crimson-hitman] %s returned %s, not a module table')
            :format(file, type(module)))
    end

    loaded[path] = module
    return done(module)
end

--- Shared modules live under shared/ and are loaded the same way, from the
--- same registry: this file's own loader, whatever the table field holds.
local loadModule = CrimsonBoot.require

---@param name string e.g. 'util'
---@return table
function CrimsonBoot.requireShared(name)
    return loadModule('shared.' .. name)
end

--- The one way to the console (shared/log.lua), through this loader.
---@return table
function CrimsonBoot.log()
    return CrimsonBoot.requireShared('log')
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
        ('still waiting after %ds for %d resource(s) to start:')
            :format(waited, #missing),
    }
    for i = 1, #missing do
        lines[#lines + 1] = ('  %s is %s — %s')
            :format(missing[i].name, GetResourceState(missing[i].name), missing[i].why)
    end
    lines[#lines + 1] = 'a renamed or forked resource will never '
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
            -- Start progress: with Config.Debug only, and kept for the
            -- diagnosis (shared/log.lua).
            if waited >= GRACE_SECONDS then
                CrimsonBoot.log().debug(('everything it waits for is up after %ds; starting.')
                    :format(waited))
            end
            return true
        end

        -- Whatever Config.Debug says: the resource is not starting, and
        -- nothing else will say why.
        if CrimsonBoot.shouldReport(waited) then
            for _, line in ipairs(CrimsonBoot.waitReport(missing, waited)) do
                CrimsonBoot.log().always(line)
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

    local ok, err = pcall(StartCrimsonHitman)
    if not ok then
        -- Refusing to start, so in full whatever Config.Debug says: the
        -- problems the start found as well, since no diagnosis can be run
        -- to read them now.
        local Log = CrimsonBoot.log()
        Log.reportProblems(true)
        Log.always('failed to start: ' .. tostring(err))
    end
end)
