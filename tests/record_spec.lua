--- Step 3j: one Record (server/record/). A character's standing is kept and
--- read in one module: the counters (the only module that bumps or reads
--- them), standing and level, trust and the reputation factor, the tiered
--- board, heat and the placer's record; one config section (Config.Record),
--- one start-up check (Record.validate), one admin area (Record & standing,
--- groups 'Record: ...'), one minute job (record.tick), and one read the
--- app, the cards and the panel share (Record.of). Every value as before.

local function read_file(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

local function exists(path)
    local handle = io.open(path, 'r')
    if handle then handle:close() end
    return handle ~= nil
end

--- Every server Lua file, by its path from the repository root.
local function serverFiles()
    local out = {}
    local pipe = assert(io.popen('find crimson-hitman/server -name "*.lua" | sort'))
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
    return out
end

local SHIPPED = {
    Progression = { Enabled = true, Resource = 'sc-blackmarket', TrustPerElimination = 10, TrustPerKidnapping = 20 },
    Reputation = { Enabled = false, BaseFactor = 0.5, ThreadBonus = 0.2, MeetingBonus = 0.2, HandoverBonus = 0.3,
        WitnessFreeBonus = 0.2, WitnessRadius = 50.0, MaxFactor = 1.5 },
    Tiers = { Enabled = false, CompletionsPerLevel = 5, Tiers = { 'Professional, 50000, 2', 'Elite, 150000, 4' } },
    Heat = { Enabled = false, ProtectedCompletionHeat = 3, WitnessHeat = 2, AdvisoryHeat = 1, DecayHours = 24,
        Threshold = 5, WarnTargetChancePercent = 50, BulletinEveryMinutes = 60,
        BulletinTitle = 'Intelligence bulletin',
        BulletinText = 'A known contract killer is believed active in the city.' },
    PlacerRecord = { Enabled = false, LookbackDays = 30, ShowForAnonymous = false },
}

local function same(a, b, path)
    if type(a) == 'table' and type(b) == 'table' then
        for k, v in pairs(a) do same(v, b[k], path .. '.' .. tostring(k)) end
        for k in pairs(b) do truthy(a[k] ~= nil, path .. '.' .. tostring(k) .. ' is new') end
        return
    end
    eq(b, a, path)
    eq(math.type(b), math.type(a), path .. ' kind')
end

describe('step 3j: one Record', function()
    it('the old modules, sections and keys are gone', function()
        for _, file in ipairs({ 'progression', 'rp_reputation', 'imp_heat', 'imp_tiers', 'imp_placer_record' }) do
            falsy(exists('crimson-hitman/server/' .. file .. '.lua'), file .. '.lua still there')
        end
        for _, file in ipairs({ 'init', 'heat', 'placer' }) do
            truthy(exists('crimson-hitman/server/record/' .. file .. '.lua'), 'record/' .. file .. '.lua')
        end
        local shipped = require('tests.harness.shipped').fromFile()
        for _, root in ipairs({ { 'config.lua', shipped }, { 'defaults.lua', ConfigDefaults } }) do
            local c = root[2]
            eq(c.Progression, nil, root[1] .. ': Progression')
            eq(c.Roleplay.Reputation, nil, root[1] .. ': Roleplay.Reputation')
            for _, name in ipairs({ 'HitmanHeat', 'Tiers', 'PlacerRecord' }) do
                eq(c.Improvements[name], nil, root[1] .. ': Improvements.' .. name)
            end
        end
    end)

    it('is one config section with every value it shipped with', function()
        local shipped = require('tests.harness.shipped').fromFile()
        truthy(type(shipped.Record) == 'table', 'Config.Record in config.lua')
        same(SHIPPED, shipped.Record, 'Config.Record')
        same(SHIPPED, ConfigDefaults.Record, 'ConfigDefaults.Record')
        eq(shipped.Record.Progression.TrustPerElimination, 10, 'trust per kill')
        eq(shipped.Record.Progression.TrustPerKidnapping, 20, 'trust per live handover')
    end)

    it('is the one module that keeps and reads the counters', function()
        local by = {}
        for _, path in ipairs(serverFiles()) do
            if not path:find('/storage/', 1, true) and path ~= 'crimson-hitman/server/record/init.lua' then
                local src = read_file(path)
                -- A call, not a name in a list of the store's methods.
                if src:find('[%.:]readStats%s*%(') or src:find('[%.:]bumpStat%s*%(') then by[#by + 1] = path end
            end
        end
        eq(#by, 0, 'the counters read or bumped outside the record: ' .. table.concat(by, ', '))
        -- And every reader of a record reads it through Record.of.
        truthy(read_file('crimson-hitman/server/app.lua'):find('deps.record.of(actor.cid)', 1, true), 'the Ledger')
        truthy(read_file('crimson-hitman/server/panel.lua'):find('deps.record.of(cid)', 1, true), 'the player card')
        truthy(read_file('crimson-hitman/server/projection.lua'):find('Record.of(cid)', 1, true), 'a card\'s operatives')
    end)

    it('answers the Ledger, the cards and the panel with the one record', function()
        local s = newStack()
        local f = fixture(s)
        s.storage.bumpStat('HITMAN01', 'completed', 6)
        s.storage.bumpStat('HITMAN01', 'failed', 2)
        local record = s.record.of('HITMAN01')
        eq(record.completed, 6)
        eq(record.failed, 2)
        eq(record.rate, 75)
        eq(record.standing, 'Known')
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c and s.contracts.accept(f.hitman, c.id, false))
        local card = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(card.hitmen[1].record.completed, 6, 'a card\'s operative')
        eq(card.hitmen[1].record.standing, 'Known')
    end)

    it('holds every block to its rule at the start, filling one that is missing', function()
        local s = newStack()
        local RP = require('tests.harness.roleplay')
        RP.guard(function()
            Config.Record.Heat.Threshold = 0
            Config.Record.Tiers = nil
            Config.Record.Reputation.BaseFactor = 2
            local warn, filled = {}, {}
            s.record.validate(warn, filled)
            eq(Config.Record.Heat.Threshold, 5, 'put back to what ships')
            truthy(Config.Record.Tiers and Config.Record.Tiers.CompletionsPerLevel == 5, 'the block filled')
            eq(Config.Record.Reputation.BaseFactor, 1.5, 'held to the cap')
            local said = table.concat(warn, '\n')
            truthy(said:find('Record.Heat.Threshold', 1, true), said)
            truthy(said:find('Config.Record.Reputation.BaseFactor', 1, true), said)
        end)()
    end)

    it('lists every Record setting in one area, each group a Record group', function()
        local s = newStack()
        local keys, gone = 0, {}
        local OLD = { ['Progression'] = true, ['Roleplay: Reputation'] = true, ['Improvements: Placer record'] = true,
            ['Improvements: Hitman heat'] = true, ['Improvements: Tiered board'] = true }
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.key:find('^Record%.') then
                keys = keys + 1
                truthy(entry.group:find('^Record: '), entry.key .. ' in ' .. tostring(entry.group))
                eq(s.settings.areaOf(entry), 'record', entry.key)
            end
            if OLD[entry.group] then gone[#gone + 1] = entry.key end
        end
        eq(keys, 27, 'every Record setting (the resource name is read only)')
        eq(#gone, 0, 'left in an old group: ' .. table.concat(gone, ', '))
    end)

    it('reads one level, from the same record, for the tiered board', function()
        local s = newStack()
        local RP = require('tests.harness.roleplay')
        RP.guard(function()
            eq(s.record.level({ completed = 9 }), 2, 'off: five a level')
            Config.Record.Tiers.Enabled = true
            Config.Record.Tiers.CompletionsPerLevel = 3
            eq(s.record.level({ completed = 9 }), 4)
            eq(s.record.tierFor(160000).name, 'Elite')
            eq(s.record.tierFor(49999), nil)
            Config.Record.Progression.Enabled = false
            eq(#s.record.tiers(), 0, 'no tier while progression is off')
        end)()
    end)

    it('runs one minute job for heat and the placer records', function()
        local main = read_file('crimson-hitman/server/main.lua')
        truthy(main:find("['record.tick'] = { every = 60, phase = 50 }", 1, true), 'its schedule')
        falsy(main:find('imp_board.tick', 1, true), 'the old job name')
        truthy(main:find("every('record.tick', RecordMinute, now)", 1, true), 'on the tick')
    end)
end)
