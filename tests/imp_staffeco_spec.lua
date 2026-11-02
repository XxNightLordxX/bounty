--- The staff and economy improvements (server/imp_*.lua, Config.Improvements,
--- and Config.Limits.TargetCooldownAfterCompletionSeconds): proof items, the
--- completion cooldown, weapon serial scrubbing and the weekly stats. Each
--- ships off and changes nothing off; on, each does what it says, refuses
--- before anything is taken, is a panel setting that applies at once, and
--- names nobody.

--- Every test puts Config.Roleplay and Config.Improvements back as it found
--- them, whatever the order.
local IMP = require('tests.harness.improvements')
local it = IMP.it

--- Fire a net event as a client does, gate and rate limit and all, and
--- return the reply the page would receive.
local function call(name, src, payload)
    local handler = Env.events['crimson-hitman:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

local function turn(s, key, value)
    local ok, err, why = s.settings.set(key, value, 'ADMIN001', 'ADMIN001')
    truthy(ok, ('%s: %s %s'):format(key, tostring(err), tostring(why)))
end

--- Every player's money together, and what the contracts hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do sum = sum + s.escrow.moneyValue(c.id) end
    return sum
end

local function wealth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function count(src, name, field, value)
    local n = 0
    for _, slot in ipairs(Env.players[src]._inventory) do
        if slot.name == name and (not field or (slot.metadata or {})[field] == value) then
            n = n + (slot.count or 0)
        end
    end
    return n
end

local function card(src, cid)
    local p = Env.players[src]
    p._inventory[#p._inventory + 1] = { name = 'id_card', count = 1, slot = 41,
        metadata = { citizenid = cid, firstname = 'Dana', lastname = 'Reyes' } }
end

--- A contract on Dana Reyes by Vic Marlowe (a kill completes it, as the
--- runner's config places them), taken by Rook Ash.
local function held(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt from last week', anonymous = opts.anonymous,
        mode = CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 40000 } },
    })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, opts.anonymous == true), 'taken')
    return s, f, c
end

local function dump(value, out)
    out = out or {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            out[#out + 1] = tostring(k)
            dump(v, out)
        end
    else
        out[#out + 1] = tostring(value)
    end
    return table.concat(out, ' ')
end

--------------------------------------------------------------------------
-- Off, as shipped
--------------------------------------------------------------------------

describe('the staff and economy improvements, as shipped', function()
    it('ship off', function()
        local shipped = require('tests.harness.shipped').fromFile()
        for _, name in ipairs({ 'ProofItems', 'SerialScrub', 'WeeklyStats' }) do
            eq(shipped.Improvements[name].Enabled, false, name)
            eq(ConfigDefaults.Improvements[name].Enabled, false, name .. ' in defaults.lua')
        end
        eq(shipped.Limits.TargetCooldownAfterCompletionSeconds, 0)
        eq(ConfigDefaults.Limits.TargetCooldownAfterCompletionSeconds, 0)
    end)

    it('change nothing off: no proof handover, a weapon keeps its serial, no weekly post', function()
        local s, f, c = held({ anonymous = true,
            reward = { baseline = { cash = 5000, weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } } })
        card(3, 'TARGET01')
        local before = total(s)
        eq(call('proofItem', 3, { id = c.id }).err, CH.ERR.FEATURE_OFF)
        eq(count(3, 'id_card'), 1, 'the card is kept')
        eq(total(s), before)
        -- Paid by a kill verified at the scene: the pistol arrives with its serial.
        eq(s.escrow.scrubSerial ~= nil, true, 'the escrow asks the scrub')
        local line
        for _, l in ipairs(s.storage.readEscrow(c.id)) do if l.source == 'weapon' then line = l end end
        truthy(line, 'a weapon line')
        eq(s.impScrub.scrub('HITMAN01', line, line.metadata), nil, 'off: left as it is')
        eq(select(2, s.impWeekly.tick()), 'off')
        eq(#(Natives.calls.http or {}), 0)
        truthy(f)
    end)

    it('change nothing off: a target is free again once the ordinary wait is over', function()
        local s, f, c = held()
        card(3, 'TARGET01')
        Config.Improvements.ProofItems.Enabled = true
        truthy(call('proofItem', 3, { id = c.id }).ok, 'completed')
        Config.Improvements.ProofItems.Enabled = false
        Env.advance(math.max(Config.Limits.TargetCooldownAfterResolveSeconds,
            Config.Limits.SameCreatorSameTargetCooldownSeconds) + 10)
        local again = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Another debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(again, 'placed again after the ordinary wait')
    end)
end)

--------------------------------------------------------------------------
-- Proof items
--------------------------------------------------------------------------

describe('proof items', function()
    local function on(s) turn(s, 'Improvements.ProofItems.Enabled', true) end

    it('pays a hitman who hands over the target\'s id card', function()
        local s, _, c = held()
        on(s)
        card(3, 'TARGET01')
        local before, hitman = total(s), wealth(3)
        local reply = call('proofItem', 3, { id = c.id })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(count(3, 'id_card'), 0, 'the card is taken')
        eq(wealth(3), hitman + 40000, 'paid the reward')
        eq(total(s), before, 'no money made or lost')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        local hitmanRow = s.storage.readLedger('HITMAN01', 10)[1]
        truthy(hitmanRow and hitmanRow.fulfilment == CH.FULFILMENT.ELIMINATION, 'a ledger row, as a kill')
        -- A second handover pays nothing.
        card(3, 'TARGET01')
        local again = call('proofItem', 3, { id = c.id })
        falsy(again.ok)
        eq(wealth(3), hitman + 40000, 'paid once')
        eq(count(3, 'id_card'), 1, 'and the second card is kept')
    end)

    it('refuses, taking nothing, without the card, with somebody else\'s, or far from the placer', function()
        local s, _, c = held()
        on(s)
        local before = total(s)
        eq(call('proofItem', 3, { id = c.id }).err, CH.ERR.PROOF_MISSING)
        card(3, 'BYSTAND9')
        eq(call('proofItem', 3, { id = c.id }).err, CH.ERR.PROOF_MISSING)
        eq(count(3, 'id_card'), 1, 'somebody else\'s card is kept')
        card(3, 'TARGET01')
        Env.players[3]._coords = { x = 50.0, y = 0.0, z = 0.0 }
        local far = call('proofItem', 3, { id = c.id })
        eq(far.err, CH.ERR.PROOF_TOO_FAR)
        eq(far.data.radius, 3.0)
        eq(count(3, 'id_card', 'citizenid', 'TARGET01'), 1, 'the card is kept')
        eq(total(s), before)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)

    it('says an anonymous placer who is away exactly as one too far away', function()
        local s, _, c = held({ anonymous = true })
        on(s)
        card(3, 'TARGET01')
        Env.players[3]._coords = { x = 50.0, y = 0.0, z = 0.0 }
        local far = call('proofItem', 3, { id = c.id })
        Env.players[3]._coords = { x = 0.0, y = 0.0, z = 0.0 }
        Env.removePlayer(1)
        local away = call('proofItem', 3, { id = c.id })
        eq(away.err, far.err)
        eq(dump(away.data), dump(far.data))
        falsy(dump(away):find('Marlowe'), 'the placer is never named')
    end)

    it('never pays on a contract placed for a live delivery only', function()
        local s = newStack()
        local f = fixture(s)
        Config.Completion.Fulfilment = 'alive'
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c and s.contracts.accept(f.hitman, c.id, false))
        on(s)
        card(3, 'TARGET01')
        eq(call('proofItem', 3, { id = c.id }).err, CH.ERR.KILL_NOT_ALLOWED)
        eq(count(3, 'id_card'), 1)
    end)

    it('lets only the hitman holding the contract hand it over', function()
        local s, _, c = held()
        on(s)
        for _, src in ipairs({ 1, 2 }) do
            card(src, 'TARGET01')
            eq(call('proofItem', src, { id = c.id }).err, CH.ERR.NOT_PARTICIPANT)
            eq(count(src, 'id_card'), 1)
        end
    end)

    it('gives the card back when the payout is refused after it was taken', function()
        local s, _, c = held()
        on(s)
        card(3, 'TARGET01')
        local before = total(s)
        local claim = s.contracts.claimSlot
        s.contracts.claimSlot = function() return false, CH.ERR.LOCKED end
        local reply = call('proofItem', 3, { id = c.id })
        s.contracts.claimSlot = claim
        eq(reply.err, CH.ERR.LOCKED)
        eq(count(3, 'id_card', 'citizenid', 'TARGET01'), 1, 'the card is back, as it was')
        eq(total(s), before)
        local returned = false
        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit() or {}) do
            if row.action == 'proof_item_returned' and row.contract_id == c.id then returned = true end
        end
        truthy(returned, 'given back, and audited')
    end)

    it('does nothing with ox_inventory not started', function()
        local s, _, c = held()
        on(s)
        card(3, 'TARGET01')
        local state = GetResourceState
        _G.GetResourceState = function(name)
            if name == 'ox_inventory' then return 'stopped' end
            return state(name)
        end
        local reply = call('proofItem', 3, { id = c.id })
        _G.GetResourceState = state
        eq(reply.err, CH.ERR.FEATURE_OFF)
        eq(count(3, 'id_card'), 1)
    end)

    it('is told to the page only while on', function()
        local s = held()
        eq(call('list', 3, { page = 1 }).data.settings.proofItem, nil)
        on(s)
        local shown = call('list', 3, { page = 1 }).data.settings.proofItem
        eq(shown.item, 'id_card')
        eq(shown.radius, 3.0)
    end)

    it('takes its item, field and distance from the panel, at once', function()
        local s, _, c = held()
        on(s)
        turn(s, 'Improvements.ProofItems.Item', 'dog_tag')
        turn(s, 'Improvements.ProofItems.MetadataKey', 'owner')
        turn(s, 'Improvements.ProofItems.HandoverRadius', 20)
        local p = Env.players[3]
        p._inventory[#p._inventory + 1] = { name = 'dog_tag', count = 1, slot = 42,
            metadata = { owner = 'TARGET01' } }
        Env.players[3]._coords = { x = 15.0, y = 0.0, z = 0.0 }
        truthy(call('proofItem', 3, { id = c.id }).ok, 'paid with the tag, 15 m away')
        eq(count(3, 'dog_tag'), 0)
        local bad = { s.settings.set('Improvements.ProofItems.Item', 'two words', 'ADMIN001', 'ADMIN001') }
        falsy(bad[1], 'a name with a space is refused')
        bad = { s.settings.set('Improvements.ProofItems.HandoverRadius', 500, 'ADMIN001', 'ADMIN001') }
        falsy(bad[1], 'a distance past 50 is refused')
    end)
end)

--------------------------------------------------------------------------
-- The completion cooldown
--------------------------------------------------------------------------

describe('the completion cooldown', function()
    local function completed()
        local s, f, c = held()
        card(3, 'TARGET01')
        Config.Improvements.ProofItems.Enabled = true
        truthy(call('proofItem', 3, { id = c.id }).ok, 'completed')
        Config.Improvements.ProofItems.Enabled = false
        return s, f, c
    end
    local function place(s, f)
        return s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Another debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
    end

    it('keeps everybody off the target for the longer wait, said in hours only', function()
        local s, f = completed()
        turn(s, 'Limits.TargetCooldownAfterCompletionSeconds', 7200)
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 10)
        local before = total(s)
        local c, err, data = place(s, f)
        eq(c, nil)
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
        eq(data.hours, 2)
        local keys = {}
        for k in pairs(data) do keys[#keys + 1] = k end
        eq(#keys, 1, 'nothing but the hours')
        eq(total(s), before, 'nothing taken')
        -- Through the app, the same: another player placing.
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:ddd', cash = 50000,
            bank = 50000, firstname = 'Bea', lastname = 'Stander' })
        Env.advance(3600)
        local _, err2, data2 = s.contracts.create(s.identity.resolve(4), { targetCid = 'TARGET01',
            reason = 'Another debt', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        eq(err2, CH.ERR.TARGET_RECENTLY_ON)
        eq(data2.hours, 1)
        Env.advance(3600)
        truthy(place(s, f), 'free again once it has passed')
    end)

    it('only after a completion: a contract cancelled before anybody took it starts no such wait', function()
        local s = newStack()
        local f = fixture(s)
        turn(s, 'Limits.TargetCooldownAfterCompletionSeconds', 86400)
        Env.players[4] = nil
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:ddd', cash = 50000,
            bank = 50000, firstname = 'Bea', lastname = 'Stander' })
        local c = place(s, f)
        truthy(c and s.contracts.cancel(f.creator, c.id), 'withdrawn')
        local other = s.contracts.create(s.identity.resolve(4), { targetCid = 'TARGET01',
            reason = 'Another debt', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(other, 'somebody else places on them at once')
    end)

    it('is refused from the panel outside 0 to thirty days', function()
        local s = newStack()
        falsy(s.settings.set('Limits.TargetCooldownAfterCompletionSeconds', -1, 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Limits.TargetCooldownAfterCompletionSeconds', 2592001, 'ADMIN001', 'ADMIN001'))
    end)
end)

--------------------------------------------------------------------------
-- Weapon serial scrubbing
--------------------------------------------------------------------------

describe('weapon serial scrubbing', function()
    local PISTOL = { baseline = { cash = 5000, weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } }

    local function paidWithPistol(anonymous)
        local s, f, c = held({ anonymous = anonymous, reward = PISTOL })
        turn(s, 'Improvements.SerialScrub.Enabled', true)
        Config.Improvements.ProofItems.Enabled = true
        card(3, 'TARGET01')
        local before = total(s)
        truthy(call('proofItem', 3, { id = c.id }).ok, 'paid')
        eq(total(s), before, 'no money made or lost')
        local pistol
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'WEAPON_PISTOL' then pistol = slot end
        end
        truthy(pistol, 'the pistol reached the hitman')
        return s, f, c, pistol
    end

    it('hands an anonymous placer\'s weapon over with a new serial in ox_inventory\'s form', function()
        local s, _, c, pistol = paidWithPistol(true)
        falsy(pistol.metadata.serial == 'ABC123', 'a new serial')
        truthy(pistol.metadata.serial:match('^%d%d%d%d%d%d%u%u%u%d%d%d%d%d%d$'), pistol.metadata.serial)
        eq(pistol.metadata.ammo, 12, 'everything else as it was')
        -- The stored line keeps the original, for a refund.
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'weapon' then eq(line.metadata.serial, 'ABC123') end
        end
        eq(count(1, 'WEAPON_PISTOL'), 0)
    end)

    it('audits it, with the original shown only to staff with the identity ACE', function()
        local s, _, c = paidWithPistol(true)
        s.audit.flush()
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:fff',
            firstname = 'Sam', lastname = 'Steward' })
        Env.aces[6] = { ['crimson.admin'] = true }
        s.bridges.install(s)
        local function logRow(identity)
            Env.aces[6]['crimson.identity'] = identity or nil
            Env.clientEvents = {}
            _G.source = 6
            Env.events['crimson-hitman:admin']({ op = 'logs', data = { contract = c.id }, __rid = 3 })
            _G.source = nil
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'crimson-hitman:adminResult' then
                    for _, row in ipairs((event.args[1].data or {}).rows or {}) do
                        if row.action == 'weapon_serial_scrubbed' then return row end
                    end
                end
            end
        end
        local plain = logRow(false)
        truthy(plain, 'the scrub is in the log')
        eq(plain.detail.original, '(identity only)')
        local full = logRow(true)
        eq(full.detail.original, 'ABC123')
    end)

    it('never scrubs a named placer\'s weapon, nor the one going back to its placer', function()
        local _, _, _, pistol = paidWithPistol(false)
        eq(pistol.metadata.serial, 'ABC123')
        local s, f, c = held({ anonymous = true, reward = PISTOL })
        turn(s, 'Improvements.SerialScrub.Enabled', true)
        truthy(s.contracts.abandon(f.hitman, c.id))
        truthy(s.contracts.cancel(f.creator, c.id), 'withdrawn and refunded')
        local back
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'WEAPON_PISTOL' and (slot.count or 0) > 0 then back = slot end
        end
        truthy(back, 'the pistol is back with its placer')
        eq(back.metadata.serial, 'ABC123')
    end)
end)

--------------------------------------------------------------------------
-- Weekly stats
--------------------------------------------------------------------------

describe('the weekly stats', function()
    local HOOK = 'https://discord.example/api/webhooks/9/stats'

    --- Day and hour set to now, as staff would to try it.
    local function due(s)
        local t = os.date('*t', os.time())
        turn(s, 'Improvements.WeeklyStats.Day', s.impWeekly and ({ 'sunday', 'monday', 'tuesday',
            'wednesday', 'thursday', 'friday', 'saturday' })[t.wday])
        turn(s, 'Improvements.WeeklyStats.Hour', t.hour)
        turn(s, 'Improvements.WeeklyStats.Enabled', true)
    end

    it('posts the week\'s totals once, counts only, to the stats webhook', function()
        local s, _, c = held({ anonymous = true })
        Config.Improvements.ProofItems.Enabled = true
        card(3, 'TARGET01')
        truthy(call('proofItem', 3, { id = c.id }).ok)
        Natives.convars[s.impWeekly.CONVAR] = HOOK
        Natives.calls.http = {}
        due(s)
        truthy(s.impWeekly.tick(), 'posted')
        eq(#Natives.calls.http, 1)
        local post = Natives.calls.http[1]
        eq(post.url, HOOK)
        local body = json.decode(post.body).content
        truthy(body:find('Contracts placed: 1', 1, true), body)
        truthy(body:find('Contracts completed: 1', 1, true), body)
        truthy(body:find('Paid out to hitmen: $40,000', 1, true), body)
        for _, needle in ipairs({ 'CREATOR1', 'HITMAN01', 'TARGET01', 'Marlowe', 'Rook', 'Dana',
                                  'Operative', 'license' }) do
            falsy(body:find(needle, 1, true), needle .. ' in the post')
        end
        eq(select(2, s.impWeekly.tick()), 'done', 'not twice')
        eq(#Natives.calls.http, 1)
    end)

    it('keeps the week it posted across a restart, in every backend', function()
        for _, mode in ipairs({ 'memory', 'json' }) do
            local s = newStack()
            Natives.convars[s.impWeekly.CONVAR] = HOOK
            due(s)
            truthy(s.impWeekly.tick(), mode .. ': posted')
            local kept = s.storage.readStaffMeta()[s.impWeekly.META]
            truthy(kept and kept > 20000000, mode .. ': the day is kept')
            -- A start reads it back, and does not post again.
            s.impWeekly.init({ storage = s.storage, audit = s.audit, alerts = s.alerts })
            eq(select(2, s.impWeekly.tick()), 'done', mode)
        end
        local mysql = read_file('crimson-hitman/server/storage/mysql.lua')
        truthy(mysql:find("'imp_weekly_day'", 1, true), 'the mysql backend reads the key back')
    end)

    it('falls back to the alert webhook, and waits for its day', function()
        local s = newStack()
        Natives.convars['crimson_hitman_webhook'] = 'https://discord.example/api/webhooks/1/x'
        Natives.calls.http = {}
        local t = os.date('*t', os.time())
        turn(s, 'Improvements.WeeklyStats.Enabled', true)
        turn(s, 'Improvements.WeeklyStats.Day', ({ 'sunday', 'monday', 'tuesday', 'wednesday',
            'thursday', 'friday', 'saturday' })[(t.wday % 7) + 1])
        turn(s, 'Improvements.WeeklyStats.Hour', t.hour)
        eq(select(2, s.impWeekly.tick()), 'early', 'tomorrow is its day')
        due(s)
        truthy(s.impWeekly.tick())
        eq(Natives.calls.http[1].url, 'https://discord.example/api/webhooks/1/x')
    end)

    it('refuses a day or an hour that is not one', function()
        local s = newStack()
        falsy(s.settings.set('Improvements.WeeklyStats.Day', 'funday', 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Improvements.WeeklyStats.Hour', 24, 'ADMIN001', 'ADMIN001'))
    end)
end)

--------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------

describe('the improvements in the admin panel', function()
    it('lists every setting, each switch under Features in its own group', function()
        local s = newStack()
        local keys = {
            'Improvements.ProofItems.Enabled', 'Improvements.ProofItems.Item',
            'Improvements.ProofItems.MetadataKey', 'Improvements.ProofItems.HandoverRadius',
            'Improvements.SerialScrub.Enabled', 'Improvements.WeeklyStats.Enabled',
            'Improvements.WeeklyStats.Day', 'Improvements.WeeklyStats.Hour',
            'Limits.TargetCooldownAfterCompletionSeconds',
        }
        for _, key in ipairs(keys) do
            local entry = s.settings.entry(key)
            truthy(entry, key .. ' is in the catalogue')
            truthy(entry.group:match('^Improvements: '), key .. ' is in an Improvements group')
            if key:match('%.Enabled$') then
                eq(entry.category, 'features', key)
                eq(entry.kind, 'switch', key)
            else
                truthy(entry.category:match('^rules%-'), key)
            end
        end
    end)

    it('fills a block an older config.lua lacks, and puts a bad value back with a warning', function()
        local s = newStack()
        local saved = Config.Improvements
        Config.Improvements = nil
        local warn = {}
        s.impProof.validate(warn)
        s.impScrub.validate(warn)
        s.impWeekly.validate(warn)
        eq(#warn, 0)
        eq(Config.Improvements.ProofItems.Item, 'id_card')
        Config.Improvements.WeeklyStats.Hour = 30
        s.impWeekly.validate(warn)
        eq(Config.Improvements.WeeklyStats.Hour, 18)
        truthy(warn[1] and warn[1]:find('Improvements.WeeklyStats.Hour', 1, true), tostring(warn[1]))
        Config.Improvements = saved
    end)
end)
