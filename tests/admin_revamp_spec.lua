--- The admin panel rebuild's server gaps (docs plan §8): the Suspended and
--- Protected lists (op sanctions), the diagnosis run as the player Players
--- looked up (diag with a lookup handle), and each setting's feature area
--- (the catalogue's `area`, Game rules' pages).
---
--- What these hold them to: the lists name only who is suspended or
--- protected now, newest first, scrubbed without IdentityAce, each row with
--- a handle a Lift takes and a stale one refused; every level that may open
--- the panel may read them; the diagnosis takes a fresh handle of an online
--- player and refuses a stale one or an offline player; and every catalogue
--- group belongs to a named area.

local function staff(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 1000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
    if s.bridges and s.bridges.install then s.bridges.install(s) end
end

local function world()
    local s = newStack()
    local f = fixture(s)
    staff(s)
    return s, f
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

local function lookedUp(src, subject)
    local reply = ask(src, 'player', { subject = subject })
    truthy(reply and reply.ok, 'looked up ' .. tostring(subject) .. ': ' .. tostring(reply and reply.message))
    return reply.data.player.ref
end

describe('admin rebuild: the Suspended and Protected lists', function()
    it('lists who is suspended and protected now, scrubbed without IdentityAce', function()
        local s = world()
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 3, reason = 'Contract spam' }).ok)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 0, reason = 'Event guest' }).ok)
        local reply = ask(6, 'sanctions')
        truthy(reply and reply.ok, 'read: ' .. tostring(reply and reply.message))
        eq(#reply.data.suspended, 1)
        eq(#reply.data.protected, 1)
        local row = reply.data.suspended[1]
        eq(row.reason, 'Contract spam')
        truthy(row.name, 'the name')
        eq(row.cid, nil, 'no citizen id without IdentityAce')
        eq(row.by, nil, 'nor who set it')
        truthy(type(row.ref) == 'string' and row.ref:sub(1, 1) == 'f', 'a list handle')
        truthy(row['until'] and row['until'] > os.time(), 'until when')
        local unmasked = ask(8, 'sanctions')
        eq(unmasked.data.suspended[1].cid, 'CREATOR1', 'the citizen id with IdentityAce')
        eq(unmasked.data.suspended[1].by, 'ADMIN001')
        eq(unmasked.data.protected[1]['until'], nil, 'protected for good')
        local _ = s
    end)

    it('is a read: an extra ACE alone reads it', function()
        world()
        local reply = ask(7, 'sanctions')
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(#reply.data.suspended, 0)
        eq(#reply.data.protected, 0)
    end)

    it('lifts from a row by its handle, and refuses a handle that names nobody', function()
        world()
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 1, reason = 'x' }).ok)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 5, reason = 'y' }).ok)
        local list = ask(6, 'sanctions').data
        truthy(ask(6, 'unsuspend', { ref = list.suspended[1].ref }).ok, 'lifted from the row')
        truthy(ask(6, 'unprotect', { ref = list.protected[1].ref }).ok, 'lifted from the row')
        local after = ask(6, 'sanctions').data
        eq(#after.suspended, 0)
        eq(#after.protected, 0)
        eq(ask(6, 'unsuspend', { ref = 'f99999' }).err, CH.ERR.NOT_FOUND, 'a row that is gone')
        eq(ask(7, 'unsuspend', { ref = list.suspended[1].ref }).err, 'not_allowed', 'still a moderator\'s')
    end)

    it('lists newest first and leaves out one whose time has passed', function()
        local s = world()
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 1, reason = 'first' }).ok)
        Env.advance(5)
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 2), days = 3, reason = 'second' }).ok)
        local rows = ask(6, 'sanctions').data.suspended
        eq(rows[1].reason, 'second')
        eq(rows[2].reason, 'first')
        Env.advance(86400 + 10)
        rows = ask(6, 'sanctions').data.suspended
        eq(#rows, 1, 'the one-day suspension is over')
        eq(rows[1].reason, 'second')
        local _ = s
    end)
end)

describe('admin rebuild: the diagnosis as the selected player', function()
    it('runs as the player a lookup handle names', function()
        world()
        local reply = ask(6, 'diag', { ref = lookedUp(6, 1) })
        truthy(reply and reply.ok, tostring(reply and reply.message))
        truthy(#reply.data.lines > 3, 'the report')
    end)

    it('refuses a stale or foreign handle, and a player who is not online', function()
        world()
        eq(ask(6, 'diag', { ref = 'p1_123456' }).err, 'stale_lookup')
        local mine = lookedUp(8, 1)
        eq(ask(6, 'diag', { ref = mine }).err, 'stale_lookup', 'another staff member\'s handle')
        local ref = lookedUp(6, 'CREATOR1')
        Env.removePlayer(1)
        local reply = ask(6, 'diag', { ref = ref })
        eq(reply.err, CH.ERR.NOT_FOUND)
        truthy(reply.message:find('not in the city', 1, true), reply.message)
    end)

    it('still takes a typed player id, which wins over a handle', function()
        world()
        local reply = ask(6, 'diag', { subject = 2, ref = 'p1_123456' })
        truthy(reply.ok, 'the typed id')
    end)
end)

describe('admin rebuild: every setting in a feature area', function()
    it('puts every catalogue group in a named area', function()
        local s = world()
        local loose = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if s.settings.areaOf(entry) == 'other' then loose[#loose + 1] = entry.key .. ' (' .. entry.group .. ')' end
        end
        eq(#loose, 0, 'groups with no area: ' .. table.concat(loose, ', '))
    end)

    it('sends each row\'s area with the settings', function()
        world()
        local reply = ask(6, 'settings', { whole = true })
        truthy(reply and reply.ok)
        local seen, missing = 0, {}
        for _, list in ipairs({ 'features', 'limits', 'readonly' }) do
            for _, row in ipairs(reply.data[list] or {}) do
                seen = seen + 1
                local area = row.area or (reply.data.schema and reply.data.schema[row.key]
                    and reply.data.schema[row.key].area)
                if type(area) ~= 'string' then missing[#missing + 1] = row.key end
            end
        end
        truthy(seen > 100, seen .. ' rows')
        eq(#missing, 0, 'rows with no area: ' .. table.concat(missing, ', '))
    end)

    it('puts developer-only keys in the engine area or their own', function()
        local s = world()
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.category == 'organisation' then eq(s.settings.areaOf(entry), 'organisation', entry.key) end
            if entry.category == 'target-limits' then eq(s.settings.areaOf(entry), 'targets', entry.key) end
        end
    end)
end)

describe('admin rebuild: the overview counts the measures on players', function()
    it('counts everybody suspended and protected now beside the frozen', function()
        world()
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 1, reason = 'x' }).ok)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 0, reason = 'y' }).ok)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 3), hours = 2, reason = 'z' }).ok)
        Env.advance(60)
        local reply = ask(7, 'overview')
        truthy(reply and reply.ok, 'a read')
        eq(reply.data.sanctions.suspended, 1)
        eq(reply.data.sanctions.protected, 2)
    end)
end)

describe('admin rebuild: the organisation\'s boss menu layout reaches the panel', function()
    it('sends the layout staff set with the rest of orgGet', function()
        local W = require('tests.harness.org_world')
        W.world()
        local saved = W.ask(6, 'orgLayout', { layout = { labels = { members = 'Crew' }, hidden = {} } })
        truthy(saved and saved.ok, tostring(saved and saved.message))
        local view = W.ask(6, 'orgGet', {})
        truthy(view.ok)
        eq(view.data.layout.labels.members, 'Crew')
        local reader = W.ask(7, 'orgGet', {})
        truthy(reader.ok, 'a read for every reader of the panel')
        Config.Organisation.Enabled = false
    end)
end)
