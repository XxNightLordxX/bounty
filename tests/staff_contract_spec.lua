--- Staff tools on one contract (server/staffcontract.lua and the admin
--- panel's addNote, removeHitman, editText, exportContract and playerView),
--- and the log search by contract or citizen id.
---
--- Booted through main.lua, so the wiring is the real one. What these hold
--- the tools to: notes are kept in every backend and in the log and never
--- reach a player; taking one operative off hands their stake on exactly
--- as a walk-away does (or back to them, when staff choose), tells the
--- others what a walk-away tells them and the operative only that staff
--- removed them, bars them from it when asked, and moves no money that is
--- not accounted for; a player's text is replaced only through the checks a
--- player's text gets, the original kept in the log, the new one marked;
--- the export and the player view are scrubbed for staff without
--- IdentityAce as the contract view is, and the player view is the real
--- projection and writes nothing; only staff with the write ACE write.

local Exec = require('tests.harness.mysql_exec')

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode)
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode or 'memory'
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    Config.Limits.ExclusiveIdleReleaseSeconds = 0
    Config.Limits.ExclusiveAttemptWindowSeconds = 0
    local main = require('server.main')
    return main, main.start()
end

local function restart(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local main = require('server.main')
    return main, main.start()
end

--- The usual three players, a second hitman, and three staff:
--- crimson.admin, a read-only extra ACE, and crimson.admin with
--- crimson.identity.
local function people(s)
    local f = fixture(s)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    f.hitman2 = s.identity.resolve(4)
    return f
end

local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

local function place(s, actor, extra)
    local req = { targetCid = 'TARGET01', reason = 'Owes the crew', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(actor, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function notices(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            out[#out + 1] = tostring(event.args[1].title) .. ' | ' .. tostring(event.args[1].content)
        end
    end
    return out
end

local function stored(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

--- Every string anywhere in a value, keys included, as one text.
local function textOf(value)
    local seen = {}
    local function walk(v)
        if type(v) == 'string' then seen[#seen + 1] = v
        elseif type(v) == 'table' then for k, inner in pairs(v) do walk(k) walk(inner) end end
    end
    walk(value)
    return table.concat(seen, '\n')
end

--- All the money there is: every player's cash and bank, and every escrow
--- line not yet settled. Nothing a tool does may make or lose any.
local function total(s, ids)
    local sum = 0
    for src = 1, 4 do
        local m = Env.players[src].PlayerData.money
        sum = sum + m.cash + m.bank
    end
    for _, id in ipairs(ids) do
        for _, line in ipairs(s.storage.readEscrow(id) or {}) do
            if line.state ~= CH.ESCROW_STATE.SETTLED and CH.MONEY_SOURCES[line.source] then
                sum = sum + (tonumber(line.amount) or 0)
            end
        end
    end
    return sum
end

local function wealth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function hitmanRow(s, c, cid)
    return s.storage.readHitman(c.id, cid)
end

--------------------------------------------------------------------------
-- Notes
--------------------------------------------------------------------------

describe('staff notes on a contract', function()
    it('are kept with author and time, shown in the contract view, logged, and never sent to a player', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')

        Env.advance(5)
        local reply = ask(6, 'addNote', { id = c.id, text = 'ticket #42, waiting on clip' })
        eq(reply.ok, true, tostring(reply.message))
        for _, event in ipairs(Env.clientEvents) do
            truthy(event.target == 6, 'a note sent something to source ' .. tostring(event.target))
        end
        Env.advance(5)
        eq(ask(8, 'addNote', { id = c.id, text = 'clip received' }).ok, true)

        local view = ask(6, 'contract', { id = c.id }).data
        local notes = view.staff.notes
        eq(#notes, 2, 'both notes')
        eq(notes[1].text, 'ticket #42, waiting on clip', 'oldest first')
        eq(notes[1].by, 'Staff', 'the author without IdentityAce, as a freeze\'s is')
        truthy(notes[1].at and notes[2].at > notes[1].at, 'each with its time')
        local identified = ask(8, 'contract', { id = c.id }).data.staff.notes
        eq(identified[1].by, 'Sam Steward (ADMIN001)', 'with IdentityAce, by name and citizen id')
        eq(identified[2].by, 'Uma Mask (UNMASK01)')

        local rows = stored(s, 'staff_note')
        eq(#rows, 2, 'each on the record')
        eq(rows[1].contract_id, c.id)
        truthy(textOf(rows).find(textOf(rows), 'ticket #42', 1, true), 'with its text')

        -- Nothing a player reads carries it.
        local row = s.storage.readContract(c.id)
        for _, cid in ipairs({ 'CREATOR1', 'TARGET01', 'HITMAN01', 'BYSTAND1' }) do
            falsy(textOf(s.projection.contract(row, cid)):find('clip', 1, true), cid .. ' was shown a note')
        end
    end)

    it('refuses an empty or long note, an unknown contract, and anybody without the write ACE', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator)
        eq(ask(6, 'addNote', { id = c.id, text = '   ' }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'addNote', { id = c.id, text = string.rep('a', 301) }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'addNote', { id = c.id }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'addNote', { id = 'ct99999999', text = 'x' }).err, CH.ERR.NOT_FOUND)
        eq(ask(7, 'addNote', { id = c.id, text = 'a reader' }).err, 'not_allowed', 'a reader')
        eq(ask(3, 'addNote', { id = c.id, text = 'a player' }).err, 'not_allowed', 'a player')
        eq(#s.staffContract.records(c.id), 0, 'nothing kept')
    end)

    it('scrubs an anonymous client\'s name out of a note for staff without IdentityAce', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { anonymous = true })
        eq(ask(8, 'addNote', { id = c.id, text = 'Vic Marlowe called in, CREATOR1' }).ok, true)
        local shown = ask(6, 'contract', { id = c.id }).data
        local text = textOf(shown)
        falsy(text:find('Vic Marlowe', 1, true), 'the name')
        falsy(text:find('CREATOR1', 1, true), 'the citizen id')
        truthy(textOf(ask(8, 'contract', { id = c.id }).data):find('Vic Marlowe called in', 1, true),
            'whole with IdentityAce')
    end)

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': notes, removals and edits are kept across a restart', function()
            local _, s = boot(mode)
            local f = people(s)
            local c = place(s, f.creator, { penaltyAmount = 500 })
            truthy(s.contracts.accept(f.hitman, c.id), 'taken')
            truthy(s.contracts.accept(f.hitman2, c.id), 'taken twice')
            eq(ask(6, 'addNote', { id = c.id, text = 'kept across a restart' }).ok, true)
            eq(ask(6, 'editText', { id = c.id, text = 'Settling a score', reason = 'slur' }).ok, true)
            local id = hitmanRow(s, c, 'HITMAN01').id
            eq(ask(6, 'removeHitman', { id = c.id, hitman = id, reason = 'metagaming', block = true }).ok, true)

            local _, after = restart(mode, s)
            local records = after.staffContract.records(c.id)
            eq(#records, 3, mode .. ': the records were lost to the restart')
            local kinds = {}
            for _, row in ipairs(records) do kinds[row.kind] = row end
            eq(kinds.note.body, 'kept across a restart', mode)
            eq(kinds.edit.field, 'reason', mode)
            eq(kinds.removal.subject_cid, 'HITMAN01', mode)
            eq(kinds.removal.blocked, true, mode)
            eq(after.storage.readContract(c.id).reason, 'Settling a score', mode)
            eq(after.projection.contract(after.storage.readContract(c.id), 'CREATOR1').staffEdited, true,
                mode .. ': the mark was lost to the restart')
            local ok, err = after.contracts.accept(after.identity.resolve(3), c.id)
            falsy(ok, mode .. ': the bar was lost to the restart')
            eq(err, CH.ERR.STAFF_BARRED, mode)
        end)
    end
end)

--------------------------------------------------------------------------
-- Taking one operative off
--------------------------------------------------------------------------

describe('taking one operative off a contract', function()
    it('hands their stake to the client as a walk-away does, and keeps it live for the rest', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        truthy(s.contracts.accept(f.hitman2, c.id), 'taken twice')
        local ids = { c.id }
        local start = total(s, ids)
        local client, hitman = wealth(1), wealth(3)

        local reply = ask(6, 'removeHitman', { id = c.id, hitman = hitmanRow(s, c, 'HITMAN01').id,
            reason = 'combat logging' })
        eq(reply.ok, true, tostring(reply.message))
        eq(total(s, ids), start, 'money appeared or vanished')
        eq(wealth(1), client + 500, 'the stake went to the client')
        eq(wealth(3), hitman, 'and nothing to the operative')
        eq(hitmanRow(s, c, 'HITMAN01').state, 'abandoned', 'off it')
        eq(hitmanRow(s, c, 'HITMAN02').state, 'active', 'the other operative stays')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'not ended for anybody')

        -- What everybody was told.
        local toHitman = notices(3)
        eq(#toHitman, 1, table.concat(toHitman, '; '))
        eq(toHitman[1], 'Taken off a contract | Staff removed you from a contract.')
        local toClient = notices(1)
        eq(#toClient, 1)
        eq(toClient[1], 'Operative walked away | An operative left your contract on Dana Reyes. '
            .. 'Their $500 stake is yours. 1 operative is still on it.')
        eq(#notices(4), 0, 'the other operative is told nothing but a refresh')
        eq(#notices(2), 0, 'the target is told nothing')
        for _, src in ipairs({ 1, 2, 3, 4 }) do
            for _, said in ipairs(notices(src)) do
                falsy(said:find('Sam', 1, true) or said:find('ADMIN001', 1, true) or said:find('combat', 1, true),
                    'a player was told who or why: ' .. said)
            end
        end

        local rows = stored(s, 'staff_remove_hitman')
        eq(#rows, 1)
        eq(rows[1].actor_cid, 'ADMIN001')
        eq(rows[1].detail.hitman, 'HITMAN01')
        eq(rows[1].detail.reason, 'combat logging')
        eq(rows[1].detail.stake_to, 'client')
        eq(#stored(s, 'stake_forfeited'), 1, 'the stake on the record as a walk-away puts it')
        eq(#stored(s, 'contract_abandoned'), 0, 'not as their own walk-away')
    end)

    it('says to the client exactly what a walk-away says', function()
        local _, s = boot('memory')
        local f = people(s)
        local walked = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, walked.id), 'taken')
        Env.clientEvents = {}
        truthy(s.contracts.abandon(f.hitman, walked.id), 'walked away')
        local byWalk = notices(1)

        Env.advance(3 * 3600)
        local removed = place(s, f.creator, { penaltyAmount = 500, targetCid = 'HITMAN02' })
        truthy(s.contracts.accept(f.hitman, removed.id), 'taken')
        eq(ask(6, 'removeHitman', { id = removed.id, hitman = hitmanRow(s, removed, 'HITMAN01').id,
            reason = 'x' }).ok, true)
        local byStaff = notices(1)
        eq(#byStaff, #byWalk)
        eq(byStaff[1], (byWalk[1]:gsub('Dana Reyes', 'Kit Vane')), 'the same words')
        eq(s.storage.readContract(removed.id).state, CH.STATE.ACTIVE, 'back on the board, as a walk-away puts it')
    end)

    it('gives the stake back when staff choose, and money is conserved', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 700 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local ids = { c.id }
        local start = total(s, ids)
        local client, hitman = wealth(1), wealth(3)
        local reply = ask(6, 'removeHitman', { id = c.id, hitman = hitmanRow(s, c, 'HITMAN01').id,
            reason = 'staff error', returnStake = true })
        eq(reply.ok, true, tostring(reply.message))
        eq(total(s, ids), start, 'money appeared or vanished')
        eq(wealth(3), hitman + 700, 'the stake went back to the operative')
        eq(wealth(1), client, 'and nothing to the client')
        local toClient = notices(1)
        eq(toClient[1], 'Operative walked away | An operative left your contract on Dana Reyes. It is back on the board.',
            'no stake named to the client')
        eq(stored(s, 'staff_remove_hitman')[1].detail.stake_to, 'operative')
        eq(#stored(s, 'stake_returned_by_staff'), 1)

        -- And an ending after it reads the stake as theirs too: nothing left
        -- under the row to move, and nothing moves twice.
        eq(ask(6, 'void', { id = c.id, reason = 'done' }).ok, true)
        eq(total(s, ids), start, 'money appeared or vanished at the void')
        eq(wealth(3), hitman + 700, 'the void moved the stake again')
    end)

    it('a stake still held under a row staff took off goes to whoever staff chose, at the ending', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 400 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local row = hitmanRow(s, c, 'HITMAN01')
        local ids = { c.id }
        local start = total(s, ids)
        local client, hitman = wealth(1), wealth(3)
        -- As a removal that stopped between its row and the stake leaves it:
        -- the record kept, the row off, the stake still held; and read back
        -- as a start reads it.
        s.storage.addContractStaff({ id = 'cs99999999', contract_id = c.id, kind = 'removal',
            author_cid = 'ADMIN001', body = 'x', subject_cid = 'HITMAN01', stint = row.accepted_at,
            stake_returned = true, blocked = false, created_at = os.time() })
        truthy(s.storage.abandonHitman(row.id, c.id, os.time()), 'off it')
        s.staffContract.init({ storage = s.storage, audit = s.audit, notify = s.notify,
                               contracts = s.contracts, identity = s.identity })
        eq(ask(6, 'void', { id = c.id, reason = 'done' }).ok, true)
        eq(total(s, ids), start, 'money appeared or vanished')
        eq(wealth(3), hitman + 400, 'the stake staff chose to give back went back')
        eq(wealth(1) - client, 5000, 'and the client got their reward back, not the stake')
    end)

    it('bars them from taking it again only when asked, on any of their characters', function()
        local _, s = boot('memory')
        local f = people(s)
        local open = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, open.id), 'taken')
        eq(ask(6, 'removeHitman', { id = open.id, hitman = hitmanRow(s, open, 'HITMAN01').id,
            reason = 'warned' }).ok, true)
        truthy(s.contracts.accept(f.hitman, open.id), 'not barred: they may take it again')

        local barred = place(s, f.creator, { targetCid = 'HITMAN02' })
        truthy(s.contracts.accept(f.hitman, barred.id), 'taken')
        eq(ask(6, 'removeHitman', { id = barred.id, hitman = hitmanRow(s, barred, 'HITMAN01').id,
            reason = 'metagaming', block = true }).ok, true)
        local ok, err = s.contracts.accept(f.hitman, barred.id)
        falsy(ok, 'barred')
        eq(err, CH.ERR.STAFF_BARRED)
        eq(s.projection.contract(s.storage.readContract(barred.id), 'HITMAN01').barred, 'staff_removed',
            'their board card says so, and draws no Accept')
        -- Another character on the same account.
        Env.addPlayer({ source = 9, citizenid = 'ALTCHAR1', license = 'license:ccc',
            cash = 5000, bank = 5000, firstname = 'Alt', lastname = 'Ash' })
        local alt, altErr = s.contracts.accept(s.identity.resolve(9), barred.id)
        falsy(alt, 'their other character took it')
        eq(altErr, CH.ERR.STAFF_BARRED)
    end)

    it('refuses a closed, frozen or unknown contract, an operative not on it, and the wrong people', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local id = hitmanRow(s, c, 'HITMAN01').id
        local ids = { c.id }
        local start = total(s, ids)
        eq(ask(6, 'removeHitman', { id = c.id, hitman = id }).err, CH.ERR.INVALID_INPUT, 'no reason')
        eq(ask(6, 'removeHitman', { id = c.id, reason = 'x' }).err, CH.ERR.INVALID_INPUT, 'no operative')
        eq(ask(6, 'removeHitman', { id = c.id, hitman = 'hn99999999', reason = 'x' }).err, 'no_operative')
        eq(ask(7, 'removeHitman', { id = c.id, hitman = id, reason = 'x' }).err, 'not_allowed', 'a reader')
        eq(ask(3, 'removeHitman', { id = c.id, hitman = id, reason = 'x' }).err, 'not_allowed', 'a player')
        eq(ask(1, 'removeHitman', { id = c.id, hitman = id, reason = 'x' }).err, 'not_allowed', 'the client')
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'dispute'), 'frozen')
        eq(ask(6, 'removeHitman', { id = c.id, hitman = id, reason = 'x' }).err, CH.ERR.CONTRACT_FROZEN)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01'), 'released')
        eq(hitmanRow(s, c, 'HITMAN01').state, 'active', 'still on it')
        eq(total(s, ids), start, 'and nothing moved')
        eq(#s.staffContract.records(c.id), 0, 'no record of a removal that never happened')
        eq(ask(6, 'void', { id = c.id, reason = 'x' }).ok, true)
        eq(ask(6, 'removeHitman', { id = c.id, hitman = id, reason = 'x' }).err, CH.ERR.BAD_STATE)
    end)
end)

--------------------------------------------------------------------------
-- Replacing a player's text
--------------------------------------------------------------------------

describe('replacing a player\'s text', function()
    it('goes through the checks a player\'s text gets, keeps the original in the log, and marks it', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { reason = 'Owes the crew money' })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        Config.Reason.PatternDenylist = { 'https?://', 'discord%.gg' }

        local refused = ask(6, 'editText', { id = c.id, text = 'join discord.gg/abc', reason = 'x' })
        eq(refused.err, CH.ERR.REASON_REFUSED, 'a link is refused as it is to a player')
        truthy(refused.message:find('PatternDenylist', 1, true), refused.message)
        eq(ask(6, 'editText', { id = c.id, text = '555 123 4567 89', reason = 'x' }).err, CH.ERR.REASON_REFUSED,
            'digits')
        eq(ask(6, 'editText', { id = c.id, text = string.rep('a', Config.Reason.MaxLength + 1), reason = 'x' }).err,
            CH.ERR.REASON_REFUSED, 'too long')
        eq(ask(6, 'editText', { id = c.id, text = 'Fine words' }).err, CH.ERR.INVALID_INPUT, 'no reason')
        eq(ask(6, 'editText', { id = c.id, field = 'targetName', text = 'x', reason = 'x' }).err,
            CH.ERR.INVALID_INPUT, 'only free text a player wrote')
        eq(ask(7, 'editText', { id = c.id, text = 'Fine words', reason = 'x' }).err, 'not_allowed', 'a reader')
        eq(ask(1, 'editText', { id = c.id, text = 'Fine words', reason = 'x' }).err, 'not_allowed', 'a player')
        eq(s.storage.readContract(c.id).reason, 'Owes the crew money', 'nothing changed yet')
        eq(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').staffEdited, nil, 'no mark yet')

        local reply = ask(6, 'editText', { id = c.id, text = 'Settling a score', reason = 'ticket #9: slur' })
        eq(reply.ok, true, tostring(reply.message))
        eq(s.storage.readContract(c.id).reason, 'Settling a score')
        local rows = stored(s, 'staff_text_edit')
        eq(#rows, 1)
        eq(rows[1].detail.old, 'Owes the crew money', 'the original kept for staff')
        eq(rows[1].detail.new, 'Settling a score')
        eq(rows[1].detail.reason, 'ticket #9: slur')
        local row = s.storage.readContract(c.id)
        for _, cid in ipairs({ 'CREATOR1', 'TARGET01', 'HITMAN01', 'BYSTAND1' }) do
            local card = s.projection.contract(row, cid)
            eq(card.reason, 'Settling a score', cid)
            eq(card.staffEdited, true, cid .. ' sees the mark')
            falsy(textOf(card):find('Owes the crew', 1, true), cid .. ' sees the original')
        end
        eq(ask(6, 'editText', { id = c.id, text = 'Settling a score', reason = 'x' }).err, 'unchanged')
        eq(ask(6, 'contract', { id = c.id }).data.staff.text.edited, true)
    end)

    it('in preset mode takes only one of the presets', function()
        local _, s = boot('memory')
        local f = people(s)
        Config.Reason.Mode = 'preset'
        Config.Reason.Presets = { 'Debt', 'Disrespect' }
        local c = place(s, f.creator, { reason = nil, reasonPreset = 1 })
        eq(ask(6, 'editText', { id = c.id, text = 'Anything else', reason = 'x' }).err, CH.ERR.REASON_REFUSED)
        eq(ask(6, 'editText', { id = c.id, text = 'Disrespect', reason = 'x' }).ok, true)
        eq(s.storage.readContract(c.id).reason, 'Disrespect')
    end)

    it('the original stays scrubbed for staff without IdentityAce', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { anonymous = true, reason = 'Vic Marlowe wants it done' })
        eq(ask(6, 'editText', { id = c.id, text = 'Settling a score', reason = 'names the client' }).ok, true)
        local view = ask(6, 'contract', { id = c.id }).data
        falsy(textOf(view):find('Vic Marlowe', 1, true), 'the anonymous client named in the timeline')
        truthy(textOf(ask(8, 'contract', { id = c.id }).data):find('Vic Marlowe wants it done', 1, true),
            'whole with IdentityAce')
    end)
end)

--------------------------------------------------------------------------
-- Export and the player view
--------------------------------------------------------------------------

describe('a contract\'s record as text', function()
    it('carries its states, payments, staff actions and notes, scrubbed as the view is', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { anonymous = true, penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
        eq(ask(6, 'addNote', { id = c.id, text = 'ticket #42, waiting on clip' }).ok, true)
        eq(ask(6, 'removeHitman', { id = c.id, hitman = hitmanRow(s, c, 'HITMAN01').id, reason = 'rdm' }).ok, true)

        local reply = ask(7, 'exportContract', { id = c.id })
        eq(reply.ok, true, 'a reader may export: ' .. tostring(reply.message))
        local text = reply.data.text
        for _, needle in ipairs({ 'Contract ' .. c.id, 'State: active', 'Reason: Owes the crew',
            'Payments (escrow lines):', 'stake', 'Staff notes:', 'ticket #42, waiting on clip',
            'Timeline', 'contract_created', 'staff_remove_hitman', 'staff_note', 'stake_forfeited' }) do
            truthy(text:find(needle, 1, true), 'the export lacks ' .. needle .. '\n' .. text)
        end
        for _, hidden in ipairs({ 'CREATOR1', 'HITMAN01', 'Vic Marlowe', 'Rook Ash', 'TARGET01',
            'ADMIN001', 'license:' }) do
            falsy(text:find(hidden, 1, true), hidden .. ' in the export without IdentityAce')
        end
        local whole = ask(8, 'exportContract', { id = c.id }).data.text
        truthy(whole:find('CREATOR1', 1, true) and whole:find('Vic Marlowe', 1, true), 'whole with IdentityAce')
        eq(#stored(s, 'admin_panel_export'), 1, 'looking is on the record')
        eq(ask(3, 'exportContract', { id = c.id }).err, 'not_allowed', 'a player')
        eq(ask(7, 'exportContract', { id = 'ct99999999' }).err, CH.ERR.NOT_FOUND)
    end)
end)

describe('a contract as a player sees it', function()
    it('is the real projection for each party, and writes nothing', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        s.audit.flush()
        local row = s.storage.readContract(c.id)
        local before = textOf(s.storage.readEscrow(c.id)) .. textOf(s.storage.readHitmen(c.id)) .. textOf(row)

        local cases = {
            { role = 'placer', cid = 'CREATOR1' },
            { role = 'target', cid = 'TARGET01' },
            { role = 'hitman', cid = 'HITMAN01', hitman = hitmanRow(s, c, 'HITMAN01').id },
        }
        for _, case in ipairs(cases) do
            local reply = ask(8, 'playerView', { id = c.id, role = case.role, hitman = case.hitman })
            eq(reply.ok, true, case.role .. ': ' .. tostring(reply.message))
            for _, event in ipairs(Env.clientEvents) do
                eq(event.target, 8, case.role .. ': looking sent something to source ' .. tostring(event.target))
            end
            local real = s.projection.contract(s.storage.readContract(c.id), case.cid)
            if case.role == 'target' then real.hitmen = nil end
            eq(reply.data.view.role, real.role, case.role)
            eq(textOf(reply.data.view), textOf(real), case.role .. ': not the projection the phone gets')
            eq(reply.data.viewer.cid, case.cid, case.role .. ': who, with IdentityAce')
        end
        eq(textOf(s.storage.readEscrow(c.id)) .. textOf(s.storage.readHitmen(c.id))
            .. textOf(s.storage.readContract(c.id)), before, 'looking changed the contract')
        eq(ask(6, 'playerView', { id = c.id, role = 'nobody' }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'playerView', { id = c.id, role = 'hitman', hitman = 'hn99999999' }).err, CH.ERR.INVALID_INPUT)
        eq(ask(3, 'playerView', { id = c.id, role = 'placer' }).err, 'not_allowed', 'a player')
    end)

    it('keeps anonymous parties hidden without IdentityAce', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
        truthy(s.contracts.accept(f.hitman2, c.id, false), 'taken under a name')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        for _, case in ipairs({ { role = 'placer' }, { role = 'target' },
            { role = 'hitman', hitman = hitmanRow(s, c, 'HITMAN01').id },
            { role = 'hitman', hitman = hitmanRow(s, c, 'HITMAN02').id } }) do
            local reply = ask(7, 'playerView', { id = c.id, role = case.role, hitman = case.hitman })
            eq(reply.ok, true, case.role .. ': ' .. tostring(reply.message))
            local text = textOf(reply.data)
            for _, hidden in ipairs({ 'CREATOR1', 'HITMAN01', 'Vic Marlowe', 'Rook Ash', 'license:' }) do
                falsy(text:find(hidden, 1, true), case.role .. ': ' .. hidden)
            end
            eq(reply.data.viewer, nil, 'nor who the viewer is')
        end
        local placer = ask(7, 'playerView', { id = c.id, role = 'placer' }).data.view
        eq(placer.creatorAnonymous, true)
        truthy(textOf(placer.hitmen):find('Kit Vane', 1, true), 'the named operative, as the placer sees him')
    end)

    it('says when the target has not been shown it yet, or it is closed', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator)
        local early = ask(6, 'playerView', { id = c.id, role = 'target' }).data
        if early.shown == false then truthy(early.note:find('Not shown', 1, true), early.note) end
        eq(ask(6, 'void', { id = c.id, reason = 'x' }).ok, true)
        local closed = ask(6, 'playerView', { id = c.id, role = 'placer' }).data
        eq(closed.shown, false)
        eq(closed.view, nil)
    end)
end)

--------------------------------------------------------------------------
-- The log search
--------------------------------------------------------------------------

describe('Logs search by contract or citizen id', function()
    it('a contract id returns every row for it, staff actions and notes included', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator)
        local other = place(s, f.creator, { targetCid = 'HITMAN02' })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        eq(ask(6, 'addNote', { id = c.id, text = 'n' }).ok, true)
        s.audit.flush()
        local every = s.storage.auditForContract(c.id, 1000)
        local rows = ask(6, 'logs', { contract = c.id, limit = 100 }).data.rows
        local found = {}
        for _, row in ipairs(rows) do
            eq(row.contract, c.id, 'a row of another contract')
            found[row.action] = true
        end
        truthy(#rows >= #every, ('%d rows of %d'):format(#rows, #every))
        truthy(found.staff_note and found.contract_created, 'the note and the placing')
        truthy(other, 'another contract')
    end)

    it('a citizen id: every row with IdentityAce; without it, only their rows in a role not anonymous', function()
        local _, s = boot('memory')
        local f = people(s)
        local anon = place(s, f.creator, { anonymous = true })
        local named = place(s, f.creator, { targetCid = 'HITMAN02' })
        truthy(s.contracts.accept(f.hitman, anon.id, true), 'taken anonymously')
        truthy(s.contracts.accept(f.hitman, named.id, false), 'taken under a name')
        s.audit.flush()

        local function contracts(rows)
            local out = {}
            for _, row in ipairs(rows) do out[row.contract or 'none'] = true end
            return out
        end
        local withIdentity = ask(8, 'logs', { actor = 'HITMAN01', limit = 100 }).data.rows
        local seen = contracts(withIdentity)
        truthy(seen[anon.id] and seen[named.id], 'IdentityAce finds both')

        local reply = ask(6, 'logs', { actor = 'HITMAN01', limit = 100 })
        eq(reply.ok, true, tostring(reply.message))
        local open = contracts(reply.data.rows)
        truthy(open[named.id], 'the contract they took under their name')
        falsy(open[anon.id], 'the one they took anonymously')
        falsy(open.none, 'a row about no contract')
        falsy(textOf(reply.data):find('HITMAN01', 1, true), 'the citizen id itself is still not shown')

        -- The target is never anonymous; the anonymous client never found.
        truthy(#ask(6, 'logs', { actor = 'TARGET01', limit = 100 }).data.rows >= 0)
        eq(#ask(6, 'logs', { actor = 'CREATOR1', contract = anon.id, limit = 100 }).data.rows, 0,
            'the anonymous client found by citizen id')
        truthy(#ask(6, 'logs', { actor = 'CREATOR1', contract = named.id, limit = 100 }).data.rows > 0,
            'the client who placed it under their name')
        eq(#stored(s, 'admin_panel_logs_player'), 4, 'each search on the record')
        eq(ask(3, 'logs', { actor = 'HITMAN01' }).err, 'not_allowed', 'a player')
    end)
end)
