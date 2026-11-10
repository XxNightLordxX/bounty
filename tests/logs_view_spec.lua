--- Step 3i: one log view. Every log staff read is one op, logs, each log
--- one of its areas (data.area): the audit log (none, or 'audit'), every
--- setting change ('settings', was settingsHistory) and the hitman
--- organisation's log ('org', was orgAudit; its grant history is action
--- 'org_grant'). Held here: the old ops are gone, each area answers as its
--- list did (rows, paging, scrubbing, who may read it), an unknown area is
--- refused, and the audit log's own search is untouched by an area (its
--- open-search handles, sweep 5 X1, are never an area's cursor).

local W = require('tests.harness.org_world')

local function world(opts)
    local s, f = W.world(opts)
    W.player(8, 'IDENT001')
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    return s, f
end

local function text(t)
    return json.encode(t)
end

describe('step 3i: Records › Logs is one op', function()
    it('the separate list ops are gone: one logs op, its areas a filter', function()
        local s = world()
        for _, op in ipairs({ 'settingsHistory', 'orgAudit' }) do
            local reply = W.ask(6, op, {})
            falsy(reply and reply.ok, op .. ' still answers')
        end
        eq(s.panel.OPS.settingsHistory, nil)
        eq(s.panel.EXTRA_OPS.orgAudit, nil)
        eq(s.panel.OPS.logs, 'read')
        truthy(s.panel.LOG_AREAS.settings and s.panel.LOG_AREAS.org, 'the areas')
    end)

    it('refuses an area it does not have, and answers the audit log with none or audit', function()
        world()
        eq(W.ask(6, 'logs', { area = 'nonsense' }).err, CH.ERR.INVALID_INPUT)
        eq(W.ask(6, 'logs', { area = 42 }).err, CH.ERR.INVALID_INPUT)
        local plain = W.ask(6, 'logs', {})
        truthy(plain.ok)
        eq(text(W.ask(6, 'logs', { area = 'audit' }).data.rows), text(plain.data.rows), 'audit is the default')
    end)

    it('every area is a read: a reader reads each, a player none', function()
        world()
        for _, area in ipairs({ 'audit', 'settings', 'org' }) do
            truthy(W.ask(7, 'logs', { area = area }).ok, 'a reader reads ' .. area)
            eq(W.ask(3, 'logs', { area = area }).err, 'not_allowed', 'a player reads no ' .. area)
        end
    end)

    it('settings: every change, paged by its own cursor, who only with IdentityAce', function()
        world()
        for i = 1, 3 do
            truthy(W.ask(6, 'setSetting', { key = 'Limits.MaxActiveContractsPerTarget', value = 3 + i }).ok)
            Env.advance(1)
        end
        local first = W.ask(6, 'logs', { area = 'settings', limit = 2 })
        eq(#first.data.rows, 2)
        eq(first.data.rows[1].new, 6, 'newest first')
        eq(first.data.rows[1].by, 'a staff member')
        truthy(first.data.rows[1].ref, 'an Undo for the staff ACE')
        truthy(first.data.next ~= nil, 'a next page')
        local second = W.ask(6, 'logs', { area = 'settings', limit = 2, cursor = first.data.next })
        eq(second.data.rows[1].new, 4)
        eq(W.ask(8, 'logs', { area = 'settings' }).data.rows[1].by, 'ADMIN001', 'with IdentityAce')
        eq(W.ask(7, 'logs', { area = 'settings' }).data.rows[1].ref, nil, 'no Undo for a reader')
    end)

    it('org: the organisation\'s log, one action with action, no citizen id without IdentityAce', function()
        local s = world()
        W.crew(s)
        W.allow(s, 3, 'M1')
        s.audit.flush()
        local all = W.ask(6, 'logs', { area = 'org', limit = 100 })
        truthy(all.ok, tostring(all.message))
        truthy(#all.data.rows >= 4, 'hired and granted')
        for _, row in ipairs(all.data.rows) do
            eq(row.by, 'a staff member')
            falsy(text(row.detail):find('BOSS0001', 1, true), 'a citizen id without IdentityAce')
        end
        local grants = W.ask(6, 'logs', { area = 'org', action = 'org_grant' })
        truthy(#grants.data.rows >= 1)
        for _, row in ipairs(grants.data.rows) do eq(row.action, 'org_grant') end
        truthy(text(W.ask(8, 'logs', { area = 'org', limit = 100 }).data.rows):find('BOSS0001', 1, true),
            'the member by citizen id with IdentityAce')
    end)

    it('org: off, the organisation\'s log says so', function()
        world({ off = true })
        eq(W.ask(6, 'logs', { area = 'org' }).err, 'org_off')
    end)

    it('an area never reads an audit search\'s handle, and the audit search never an area\'s cursor', function()
        local s = world()
        for i = 1, 30 do s.audit.staff('admin_note_' .. i, 'ADMIN001', nil, {}) end
        s.audit.flush()
        local page = W.ask(6, 'logs', { limit = 5 })
        truthy(page.data.next ~= nil)
        -- The audit log's cursor given to the settings area is its own
        -- cursor there: rows of that log, never the audit's.
        local other = W.ask(6, 'logs', { area = 'settings', cursor = page.data.next })
        truthy(other.ok)
        for _, row in ipairs(other.data.rows) do falsy(row.action, 'an audit row in the settings log') end
    end)
end)
