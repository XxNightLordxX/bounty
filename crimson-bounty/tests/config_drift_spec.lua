--- A config.lua the operator edited before these settings existed.
---
--- config.lua is a file server owners edit, and once edited it stops
--- tracking the shipped one. Every setting added afterwards is simply
--- absent from their copy — and absent reads as nil, which is how
--- "browse everyone in the city" turned into an empty list on a live
--- server with nothing anywhere to say why.

--- Everything the shipped config gained after an operator would have taken
--- their copy. Applied by boot AFTER the config is reset, or the reset
--- would put back the very settings this is removing.
local function asOldConfig(overrides)
    Config.Targeting = {
        MinQueryLength = 4,
        MaxResults = 5,
        AllowProtectedJobTargets = true,
    }
    for key, value in pairs(overrides or {}) do Config.Targeting[key] = value end
end

---@param age function|nil applied to the config just before start
local function boot(age)
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
    package.loaded['server.main'] = nil

    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'memory'
    if age then age() end

    local main = require('server.main')
    return main, main.start()
end

describe('starting on a config that predates a setting', function()
    it('fills in what is missing rather than reading it as off', function()
        boot(asOldConfig)
        eq(Config.Targeting.AllowBrowseAll, true,
            'a setting the operator never had is not a setting they turned off')
        eq(Config.Targeting.BrowsePageSize, 30)
        eq(Config.Targeting.AllowNearby, true)
        eq(Config.Targeting.NearbyRadius, 30.0)
        eq(Config.Targeting.MaxNearby, 12)
        resetConfig()
    end)

    it('leaves alone anything the operator did set', function()
        boot(function ()
            asOldConfig({ MinQueryLength = 6, AllowBrowseAll = false })
        end)
        eq(Config.Targeting.MinQueryLength, 6, 'their value stands')
        eq(Config.Targeting.AllowBrowseAll, false,
            'and a setting they deliberately turned off stays off')
        resetConfig()
    end)

    it('says which settings it filled in', function()
        local said = {}
        local realPrint = _G.print
        _G.print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            said[#said + 1] = table.concat(parts, ' ')
        end
        boot(asOldConfig)
        _G.print = realPrint
        resetConfig()

        local told = table.concat(said, ' | ')
        truthy(told:find('Targeting.AllowBrowseAll', 1, true),
            'an operator has to be told their config has drifted: ' .. told)
        truthy(told:find('config.lua', 1, true), told)
    end)

    it('says nothing when the config is current', function()
        local said = {}
        local realPrint = _G.print
        _G.print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            said[#said + 1] = table.concat(parts, ' ')
        end
        boot()
        _G.print = realPrint

        for _, line in ipairs(said) do
            falsy(line:find('does not set', 1, true),
                'the shipped config must not report itself as drifted: ' .. line)
        end
    end)

    it('browsing still finds people on a config that never had the setting', function()
        -- The whole point. Before this, an operator upgrading the resource
        -- without touching their config got an empty list and no reason.
        local main, modules = boot(asOldConfig)
        local f = fixture(modules)
        Env.addPlayer({ source = 10, citizenid = 'PERSON10', license = 'license:p10',
            firstname = 'Ada', lastname = 'Quill' })

        Env.clientEvents = {}
        _G.source = 1
        Env.events['crimson-bounty:browseTargets']({ scope = 'all' })
        _G.source = nil

        local reply
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:result' then reply = event.args[1] end
        end
        truthy(reply and reply.ok, 'the handler must answer')
        truthy(#reply.data.people > 0,
            'and name somebody, rather than an empty city with no explanation')
        resetConfig()
    end)
end)


--- Reading what a player is carrying, on a build that is not the one this
--- was written against.
---
--- ox_inventory's export surface has moved across releases: GetInventory
--- returns items keyed by slot number rather than listed, some builds
--- expose GetInventoryItems and some do not, and calling an export that is
--- not there throws rather than returning nil. An empty item picker with no
--- explanation is what an operator sees when none of that lines up.
describe('reading an inventory', function()
    local function carrying(s)
        return fixture(s, { creatorInventory = {
            { name = 'lockpick', count = 5, slot = 2, label = 'Lockpick' },
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, label = 'Pistol',
              metadata = { serial = 'ABC123' } },
        } })
    end

    local function offered(s, actor)
        return #s.app.escrowableItems(actor), #s.app.escrowableWeapons(actor)
    end

    it('finds items and weapons through the newer export', function()
        local s = newStack()
        local f = carrying(s)
        Natives.noGetInventoryItems = false
        local items, weapons = offered(s, f.creator)
        eq(items, 1, 'the lockpicks')
        eq(weapons, 1, 'the pistol')
        eq(s.app.inventorySource, 'GetInventoryItems')
    end)

    it('finds them through the older one when the newer is absent', function()
        -- This is the shape a live server most likely answers with, and its
        -- items are keyed by slot rather than listed.
        local s = newStack()
        local f = carrying(s)
        Natives.noGetInventoryItems = true
        local items, weapons = offered(s, f.creator)
        Natives.noGetInventoryItems = false

        eq(items, 1, 'a slot-keyed inventory holds the same lockpicks')
        eq(weapons, 1, 'and the same pistol')
        eq(s.app.inventorySource, 'GetInventory.items')
    end)

    it('keeps the slot number, which is what identifies a weapon on submit', function()
        local s = newStack()
        local f = carrying(s)
        Natives.noGetInventoryItems = true
        local weapons = s.app.escrowableWeapons(f.creator)
        Natives.noGetInventoryItems = false

        eq(#weapons, 1)
        eq(weapons[1].slot, 3,
            'without this the pick is a payload the server can only refuse')
        eq(weapons[1].serial, 'C123', 'and enough to tell two pistols apart')
    end)

    it('says it could not read rather than reporting an empty inventory', function()
        local s = newStack()
        local f = carrying(s)
        Natives.noGetInventoryItems = true
        Natives.noGetInventory = true

        local carried, read = s.app.readInventory(f.creator)
        Natives.noGetInventoryItems = false
        Natives.noGetInventory = false

        eq(read, false, 'no export answered')
        eq(s.app.inventorySource, false)
        eq(next(carried), nil, 'and nothing is invented to fill the gap')
    end)

    it('reports the same through the handler the form calls', function()
        local s = newStack()
        local f = carrying(s)
        Natives.noGetInventoryItems = true
        Natives.noGetInventory = true

        Env.clientEvents = {}
        _G.source = 1
        Env.events['crimson-bounty:rewardOptions']({})
        _G.source = nil
        Natives.noGetInventoryItems = false
        Natives.noGetInventory = false

        local reply
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:result' then reply = event.args[1] end
        end
        truthy(reply and reply.ok, 'the handler still answers')
        eq(reply.data.inventoryRead, false,
            'so the form can say why the picker is empty instead of leaving a gap')
        eq(#reply.data.items, 0)
        eq(reply.data.cash, 100000, 'and money is unaffected by any of it')
    end)

    it('refuses a shape that is a table but not a list of slots', function()
        -- An export that answers with something else entirely is worse than
        -- one that throws: accepted once, every read after it comes back
        -- empty and the picker is empty for good.
        local s = newStack()
        local f = carrying(s)
        local real = exports.ox_inventory.GetInventoryItems
        exports.ox_inventory.GetInventoryItems = function() return { ok = true, count = 3 } end

        local _, read = s.app.readInventory(f.creator)
        local source = s.app.inventorySource
        exports.ox_inventory.GetInventoryItems = real

        eq(read, true, 'the next shape down still answered')
        eq(source, 'GetInventory.items', 'and the wrong one was not taken for an inventory')
    end)

    it('is tested against the shape ox_inventory really returns', function()
        -- GetInventory keys its items by slot number rather than listing
        -- them. A harness that handed back a plain array would let this
        -- resource assume an array it never gets, and every test of the
        -- fallback path would be measuring a shape no server produces.
        local s = newStack()
        local f = carrying(s)
        local inv = exports.ox_inventory:GetInventory(f.creator.source)
        truthy(inv and inv.items, 'the older export returns an inventory')

        eq(inv.items[2] and inv.items[2].name, 'lockpick',
            'the lockpicks are at their slot number, not at index 1')
        eq(inv.items[3] and inv.items[3].name, 'WEAPON_PISTOL',
            'and the pistol at its own')
        eq(inv.items[1], nil, 'slot 1 is empty, so nothing is there')
    end)

    it('treats an empty inventory as read, not as unreadable', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {} })
        local carried, read = s.app.readInventory(f.creator)
        eq(read, true, 'carrying nothing is an answer')
        eq(next(carried), nil)
    end)
end)
