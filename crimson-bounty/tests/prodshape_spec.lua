--- PROBE (scratch): production-shaped ox_inventory + roster.

local function reply(name)
    local out
    for _, e in ipairs(Env.clientEvents) do
        if e.name == 'crimson-bounty:result' and e.args[1].event == name then out = e.args[1] end
    end
    return out
end

local function call(name, src, payload)
    Env.clientEvents = {}
    _G.source = src
    Env.events['crimson-bounty:' .. name](payload or {})
    _G.source = nil
    return reply(name)
end

describe('PROBE production shapes', function()
    it('inventory: slot-keyed map with real ox_inventory fields', function()
        local s = newStack()
        local f = fixture(s)

        -- Real ox_inventory: exports('GetInventoryItems') returns inv.items,
        -- a table keyed by SLOT with these exact fields.
        local real = {
            [1] = { name = 'lockpick', label = 'Lockpick', weight = 100, slot = 1,
                    count = 5, description = '', metadata = {}, stack = true, close = true },
            [4] = { name = 'WEAPON_PISTOL', label = 'Walther P99', weight = 970, slot = 4,
                    count = 1, description = '', metadata = { serial = 'ABC123', ammo = 12 },
                    stack = false, close = true },
            [7] = { name = 'black_money', label = 'Dirty Money', weight = 0, slot = 7,
                    count = 5000, description = '', metadata = {}, stack = true, close = true },
        }
        local ox = _G.exports.ox_inventory
        local orig = ox.GetInventoryItems
        ox.GetInventoryItems = function(_, src) return real end

        local inv, ok = s.app.readInventory(f.creator)
        io.write('PROBE readInventory ok=' .. tostring(ok) .. ' source=' .. tostring(s.app.inventorySource) .. '\n')
        io.write('PROBE items=' .. #s.app.escrowableItems(f.creator, inv)
            .. ' weapons=' .. #s.app.escrowableWeapons(f.creator, inv) .. '\n')

        local r = call('rewardOptions', 1, {})
        io.write('PROBE rewardOptions ok=' .. tostring(r and r.ok) .. ' err=' .. tostring(r and r.err) .. '\n')
        if r and r.data then
            io.write('PROBE data items=' .. #r.data.items .. ' weapons=' .. #r.data.weapons
                .. ' read=' .. tostring(r.data.inventoryRead) .. ' dirty=' .. tostring(r.data.dirty) .. '\n')
        end
        ox.GetInventoryItems = orig
        truthy(true)
    end)

    it('browse: everyone online', function()
        local s = newStack()
        local f = fixture(s)
        local r = call('browseTargets', 1, { scope = 'all', query = '', page = 1 })
        io.write('PROBE browse ok=' .. tostring(r and r.ok) .. ' err=' .. tostring(r and r.err) .. '\n')
        if r and r.data then
            io.write('PROBE browse people=' .. tostring(#r.data.people) .. ' total=' .. tostring(r.data.total) .. '\n')
        end
        truthy(true)
    end)
end)
