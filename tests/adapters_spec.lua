--- The other scripts behind adapters (step 5a; server/adapters/,
--- client/adapters/, shared/integrations.lua, docs/dev/adapters.md).
---
---   * detection: 'auto' picks the adapter whose resource is started, a
---     name picks that one only, 'none' and a name no adapter has pick
---     nothing; a start or stop of the resource is followed at the next call
---   * the owner's server: with everything it runs started, 'auto' picks
---     exactly what the calls went to before
---   * every kind set to 'none': the start says one line for it, never a
---     raise, and says it once
---   * what turns off: items with no inventory, the MDT with no dispatch,
---     keys, trust, the bank, the phone's saved notices, the medical
---     resource; and on the client the target, headshots, clothing events
---     and the phone

local Client = require('tests.harness.client')
local Integrations = require('server.adapters.init')
local Log = require('crimson-hitman.shared.log')

--- What the owner's server runs, and what each kind's 'auto' must pick
--- there (rule 7: as before).
local OWNER = {
    framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target', dispatch = 'sc-dispatch',
    ambulance = 'sc-ambulance', banking = 'Renewed-Banking', phone = 'lb-phone', keys = 'qbx_vehiclekeys',
    mugshot = 'MugShotBase64', clothing = 'qb-clothing', progression = 'sc-blackmarket', garage = 'onesync',
}

--- Every resource an adapter stands for, started.
local function ownerServer()
    for _, spec in ipairs(Integrations.KINDS) do
        for _, name in ipairs(Integrations.names(spec.kind)) do
            Natives.resourceStates[Integrations.adapter(spec.kind, name).resource] = 'started'
        end
    end
end

--- Run fn with print captured; the lines printed.
local function printed(fn)
    local lines, real = {}, _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, ' ')
    end
    local ok, err = pcall(fn)
    _G.print = real
    if not ok then error(err, 0) end
    return lines
end

local function saying(lines, text)
    local n = 0
    for _, line in ipairs(lines) do if line:find(text, 1, true) then n = n + 1 end end
    return n
end

describe('adapters: which one answers', function()
    it('has a kind for every other script the resource calls, each with its adapters', function()
        newStack()
        for kind in pairs(OWNER) do
            truthy(Integrations.BY_KIND[kind], kind)
            truthy(#Integrations.names(kind) > 0, kind .. ' has an adapter')
        end
        eq(#Integrations.KINDS, 12)
    end)

    it("picks on the owner's server exactly what the calls went to before", function()
        newStack()
        ownerServer()
        for kind, name in pairs(OWNER) do
            eq(Integrations.get(kind) and Integrations.get(kind).name, name, kind)
        end
        Natives.resetResourceStates()
    end)

    it('follows the matrix: auto, a name, none, stopped, unknown', function()
        newStack()
        for _, spec in ipairs(Integrations.KINDS) do
            local name = Integrations.names(spec.kind)[1]
            local adapter = Integrations.adapter(spec.kind, name)
            local resource = adapter.resource
            -- Clothing only listens; the garage's OneSync adapter answers
            -- wherever the server has the native (it is no resource).
            local listenedAlways = spec.kind == 'clothing' or spec.kind == 'garage'
            Natives.resourceStates[resource] = 'started'
            Config.Integrations[spec.key] = 'auto'
            truthy(Integrations.get(spec.kind), spec.kind .. ' auto, started')
            Config.Integrations[spec.key] = name
            eq(Integrations.get(spec.kind), adapter, spec.kind .. ' by name')
            if not spec.required then
                Config.Integrations[spec.key] = 'none'
                eq(Integrations.get(spec.kind), nil, spec.kind .. ' none')
                falsy(Integrations.has(spec.kind))
                eq(#Integrations.candidates(spec.kind), 0)
            end
            Config.Integrations[spec.key] = 'no-such-script'
            eq(Integrations.get(spec.kind), nil, spec.kind .. ' a name no adapter has')
            falsy(Integrations.status(spec.kind).valid)
            truthy(Integrations.offLine(Integrations.status(spec.kind)):find('names no adapter', 1, true))
            Config.Integrations[spec.key] = 'auto'
            if not spec.required and not listenedAlways then
                for _, other in ipairs(Integrations.names(spec.kind)) do
                    Natives.resourceStates[Integrations.adapter(spec.kind, other).resource] = 'stopped'
                end
                eq(Integrations.get(spec.kind), nil, spec.kind .. ' auto, stopped')
                Natives.resourceStates[resource] = 'started'
                truthy(Integrations.get(spec.kind), spec.kind .. ' a start is followed at the next call')
            end
        end
        resetConfig()
        Natives.resetResourceStates()
    end)

    it('tries the medical resources in order on auto', function()
        newStack()
        Natives.resourceStates['sc-ambulance'] = 'stopped'
        Natives.resourceStates['qbx_medical'] = 'started'
        eq(Integrations.get('ambulance').name, 'qbx_medical')
        Natives.resourceStates['sc-ambulance'] = 'started'
        eq(Integrations.get('ambulance').name, 'sc-ambulance', 'the first listed first')
        eq(#Integrations.candidates('ambulance'), 2)
        Natives.resetResourceStates()
    end)

    it('never raises from a safe call, whatever the adapter does', function()
        newStack()
        Config.Integrations.Dispatch = 'none'
        local ok, why = Integrations.call('dispatch', 'AddNotification', {})
        falsy(ok)
        eq(why, 'off')
        resetConfig()
        ok, why = Integrations.call('dispatch', 'NoSuchFunction')
        falsy(ok)
        truthy(tostring(why):find('NoSuchFunction', 1, true))
    end)
end)

describe('adapters: every kind set to none', function()
    for _, spec in ipairs(Integrations.KINDS) do
        if not spec.required then
            it(spec.kind .. ': one line at start, never a raise, and said once', function()
                newStack()
                Config.Integrations[spec.key] = 'none'
                -- The line is said whatever Debug says when a feature that
                -- uses it is on; turned on here, so every kind says it.
                Config.Debug = false
                local lines = printed(function()
                    Integrations.report(true)
                    Integrations.report()
                end)
                local st = Integrations.status(spec.kind)
                if st.needed then
                    eq(saying(lines, 'integration ' .. spec.kind .. ' off'), 1,
                        table.concat(lines, ' | '))
                else
                    eq(saying(lines, 'integration ' .. spec.kind .. ' off'), 0,
                        'a feature that is off says it only with Debug: ' .. table.concat(lines, ' | '))
                end
                Config.Debug = true
                lines = printed(function() Integrations.report(true) end)
                eq(saying(lines, 'integration ' .. spec.kind .. ' off'), 1, 'with Debug on, always')
                truthy(lines[1] and lines[1]:find(("Config.Integrations.%s is 'none'"):format(spec.key), 1, true)
                    or saying(lines, ("Config.Integrations.%s is 'none'"):format(spec.key)) == 1)
                resetConfig()
            end)
        end
    end

    it('starts the whole resource with every optional kind none', function()
        newStack()
        for _, spec in ipairs(Integrations.KINDS) do
            if not spec.required then Config.Integrations[spec.key] = 'none' end
        end
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c, 'a cash contract is placed with no other script at all')
        truthy(s.contracts.accept(f.hitman, c.id, false))
        resetConfig()
    end)

    it('puts a framework set to none back to auto, and says so', function()
        newStack()
        Config.Integrations.Framework = 'none'
        local main = require('crimson-hitman.server.main')
        local _, _, warn = main.validateConfig(true)
        eq(Config.Integrations.Framework, 'auto')
        local said = 0
        for _, line in ipairs(warn or {}) do
            if tostring(line):find('Config.Integrations.Framework', 1, true) then said = said + 1 end
        end
        eq(said, 1)
        resetConfig()
    end)
end)

describe('adapters: what turns off without one', function()
    it('item, weapon and dirty-money rewards, with no inventory', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Integrations, 'Inventory', 'none' } }, function()
            eq(#s.app.escrowableItems(f.creator), 0)
            local lines, err = s.escrow.validate(f.creator, {
                baseline = { items = { { name = 'lockpick', count = 1 } } },
            })
            falsy(lines)
            eq(err, CH.ERR.SOURCE_DISABLED)
            lines = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
            truthy(lines, 'cash still works')
        end)
    end)

    it('the police MDT, with no dispatch; the officers are still told', function()
        newStack()
        local Police = require('server.police')
        local before = #Natives.calls.dispatch
        withConfig({ { Config.Integrations, 'Dispatch', 'none' } }, function()
            falsy(Police.dispatch({ title = 't', message = 'm', unique_id = 'ch-x' }))
            Police.clear('ch-x')
        end)
        eq(#Natives.calls.dispatch, before, 'nothing filed')
        truthy(Police.dispatch({ title = 't', message = 'm', unique_id = 'ch-y' }), 'and filed with it')
    end)

    it('the disposal vehicle keys, with no keys script', function()
        local s = newStack()
        fixture(s)
        local saved = {}
        for _, name in ipairs({ 'SetEntityOrphanMode', 'SetEntityRoutingBucket', 'GetEntityRoutingBucket',
            'SetVehicleNumberPlateText', 'Entity', 'SetVehicleDoorsLocked' }) do saved[name] = _G[name] end
        local locked
        _G.SetEntityOrphanMode = function() end
        _G.SetEntityRoutingBucket = function() end
        _G.GetEntityRoutingBucket = function() return 0 end
        _G.SetVehicleNumberPlateText = function() end
        _G.Entity = function() return { state = { set = function() end } } end
        _G.SetVehicleDoorsLocked = function(_, state) locked = state end
        local ok, keyed = pcall(s.disposal.world.prepare, 9001, 'CHABCDEF', 3)
        eq(keyed, false, 'qbx_vehiclekeys is not started here')
        eq(locked, 1, 'left unlocked')
        Natives.resourceStates['qbx_vehiclekeys'] = 'started'
        ok, keyed = pcall(s.disposal.world.prepare, 9002, 'CHABCDEG', 3)
        truthy(ok)
        eq(keyed, true)
        eq(locked, 2, 'locked, the keys given')
        Config.Integrations.Keys = 'none'
        ok, keyed = pcall(s.disposal.world.prepare, 9003, 'CHABCDEH', 3)
        eq(keyed, false, 'none: as if it were not there')
        for name, fn in pairs(saved) do _G[name] = fn end
        resetConfig()
        Natives.resetResourceStates()
    end)

    it('trust on a completion, with no progression script', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hitman, c.id, false)
        local touched = false
        local realExports = _G.exports
        _G.exports = setmetatable({}, { __index = function(_, resource)
            if resource ~= 'sc-blackmarket' then return realExports[resource] end
            return { AddTrust = function() touched = true end }
        end })
        Config.Integrations.Progression = 'none'
        local ok = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING)
        _G.exports = realExports
        truthy(ok, 'the payout is made')
        falsy(touched, 'and no trust asked for')
        resetConfig()
    end)

    it("the bank for the organisation's funds, with banking none", function()
        newStack()
        local Funds = require('server.org.funds')
        Natives.resourceStates['Renewed-Banking'] = 'started'
        Funds.init({ storage = {}, audit = {} })
        Config.Integrations.Banking = 'none'
        eq(Funds.pick(), 'internal', 'the ledger, though Renewed-Banking is installed')
        Funds.init({ storage = {}, audit = {} })
        Config.Integrations.Banking = 'auto'
        eq(Funds.pick(), 'bank', 'and the bank on auto')
        resetConfig()
        Natives.resetResourceStates()
    end)

    it("the phone's saved notices, with no phone: the popup event instead", function()
        local s = newStack()
        local f = fixture(s)
        Config.Integrations.Phone = 'none'
        Env.clientEvents = {}
        s.notify.toCitizen(f.creator.cid, 'Title', 'Text', { bypassBudget = true })
        Env.advance(1)
        local popped, saved = false, false
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:notify' then popped = true end
            if event.name == 'lb-phone:SendNotification' then saved = true end
        end
        falsy(saved, 'lb-phone not asked')
        truthy(popped, 'the client is told to show it')
        resetConfig()
    end)

    it('the medical resource, with ambulance none: the metadata answers', function()
        local s = newStack()
        fixture(s)
        Env.players[2].PlayerData.metadata.isdead = true
        local _, _, _, by = s.identity.deathState(2)
        eq(by, 'sc-ambulance')
        Config.Integrations.Ambulance = 'none'
        local dead, _, resolved
        dead, _, resolved, by = s.identity.deathState(2)
        eq(by, 'metadata')
        truthy(dead and resolved)
        resetConfig()
    end)
end)

describe('adapters: the client', function()
    it('has no third-eye option, headshot or clothing listener when each is none', function()
        resetConfig()
        Config.Integrations.Target = 'none'
        Config.Integrations.Mugshot = 'none'
        Config.Integrations.Clothing = 'none'
        Natives.resourceStates['ox_target'] = 'started'
        Client.boot()
        falsy(CrimsonNpc.targetUp(), 'no target adapter')
        -- Registered (the choice is read when the event comes: A2), and
        -- answered with nothing while the choice is none.
        Client.toServer = {}
        Client.fire('qb-clothing:client:loadOutfit')
        for _, sent in ipairs(Client.toServer) do
            truthy(sent.name ~= 'crimson-hitman:appearanceChanged', 'no clothing event acted on')
        end
        Client.toServer = {}
        Client.fire('crimson-hitman:renderMugshot')
        for _, sent in ipairs(Client.toServer) do
            truthy(sent.name ~= 'crimson-hitman:mugshot', 'no headshot rendered')
        end
        resetConfig()
        Natives.resetResourceStates()
    end)

    it('shows a notice in the game feed with no phone', function()
        resetConfig()
        Config.Integrations.Phone = 'none'
        Client.boot()
        Client.feed = {}
        Client.fire('crimson-hitman:notify', { title = 'Crimson', content = 'Hello' })
        eq(#Client.feed, 1)
        truthy(Client.feed[1]:find('Hello', 1, true))
        resetConfig()
    end)

    it('follows a live change of the clothing choice, either way (A2)', function()
        local function told(event)
            Client.toServer = {}
            Client.fire(event)
            for _, sent in ipairs(Client.toServer) do
                if sent.name == 'crimson-hitman:appearanceChanged' then return true end
            end
            return false
        end
        resetConfig()
        Config.Integrations.Clothing = 'none'
        Client.boot()
        falsy(told('illenium-appearance:client:reloadSkin'), 'none: nothing')
        Config.Integrations.Clothing = 'auto'      -- the settings push, after the file loaded
        truthy(told('illenium-appearance:client:reloadSkin'), 'auto now: listened for')
        Config.Integrations.Clothing = 'qb-clothing'
        truthy(told('qb-clothing:client:loadOutfit'), 'the one named')
        falsy(told('illenium-appearance:client:reloadSkin'), 'not another')
        Config.Integrations.Clothing = 'none'
        falsy(told('qb-clothing:client:loadOutfit'), 'none again: nothing')
        resetConfig()
    end)

    it('listens for every clothing event on auto, as before', function()
        resetConfig()
        Client.boot()
        for _, event in ipairs({ 'qb-clothing:client:loadOutfit', 'illenium-appearance:client:reloadSkin',
                                 'rcore_clothing:outfitChanged' }) do
            truthy(Client.netEvents[event], event)
        end
    end)
end)
