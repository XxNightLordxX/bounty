--- Codenames (Config.Organisation.Codenames, plan R6, off as shipped):
---
---   * off: no codename shown anywhere, Set codename says so;
---   * a member picks their own, filtered: length, letters and digits,
---     the blocked words (any case, punctuation and digit swaps folded),
---     unique in the organisation and never another member's own name;
---     their own change once per CodenameCooldownMinutes;
---   * a boss holding M7 gives one to a member below; the member then
---     cannot change it, and a boss cannot change one staff gave;
---   * shown inside the organisation (the roster) and to the placer in
---     place of the hitman's name only where that name was shown at all:
---     an anonymous hitman stays an operative; never the real name with it.

local W = require('tests.harness.org_world')

local BOSS = W.boss(11, 'BOSS0001')
local RECRUIT = { cid = 'RECRUIT1', source = 13, name = 'P13' }

local function world(opts)
    opts = opts or {}
    local s, f = W.world({ configure = function()
        if opts.on ~= false then Config.Organisation.Codenames = true end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

describe('codenames switched off (as shipped)', function()
    it('ships off, and nothing shows one', function()
        resetConfig()
        eq(Config.Organisation.Codenames, false)
        local s, _, org = world({ on = false })
        truthy(s.org.memberStaff(W.STAFF, 'RECRUIT1', { codename = 'Viper' }))
        eq(org.members.RECRUIT1.codename, 'Viper', 'kept for when it is turned on')
        eq(s.org.shownName('RECRUIT1', 'P13 Org'), 'P13 Org', 'the name, as before')
        W.allow(s, 3, 'M1')
        for _, m in ipairs(W.call('orgMembers', 11, {}).data.rows) do
            truthy(m.name ~= 'Viper', 'the roster shows names')
            eq(m.codename, nil)
        end
        local reply = W.call('orgCodename', 13, { codename = 'Ghost' })
        eq(reply.err, 'org_feature_off')
        truthy(reply.data.message, 'worded')
    end)
end)

describe('picking one\'s own', function()
    it('lets a member pick one, filtered', function()
        local s, _, org = world()
        truthy(s.org.setCodename(RECRUIT, nil, '  Night   Owl '))
        eq(org.members.RECRUIT1.codename, 'Night Owl', 'trimmed, spaces folded')
        eq(W.call('orgMine', 13, {}).data.codename, 'Night Owl')
        local function why(name, cid, who)
            return select(2, s.org.setCodename(who or { cid = cid or 'LIEUT001', source = 12 }, nil, name))
        end
        eq(why('ab'), 'invalid_input', 'too short')
        eq(why(string.rep('a', 21)), 'invalid_input', 'too long')
        eq(why('<b>x</b>'), 'invalid_input', 'no markup')
        eq(why('-dash'), 'invalid_input', 'starts with a letter or digit')
        eq(why('héllo'), 'invalid_input', 'letters and digits only')
        eq(why('The Admin'), 'org_name_blocked')
        eq(why('4dm1n'), 'org_name_blocked', 'digit swaps folded')
        eq(why('a.d.m.i.n'), 'invalid_input', 'dots are not allowed at all')
        eq(why('Mod-Erator X'), 'org_name_blocked', 'punctuation folded')
        eq(why('night owl'), 'org_name_taken', 'unique in the organisation, any case')
        eq(why('P11'), 'org_name_taken', 'never another member\'s own name')
        truthy(s.org.setCodename({ cid = 'LIEUT001', source = 12 }, nil, 'Kestrel'))
    end)

    it('lets a member change their own once per cooldown, and clear it', function()
        local s, _, org = world()
        truthy(s.org.setCodename(RECRUIT, nil, 'Raven'))
        eq(select(2, s.org.setCodename(RECRUIT, nil, 'Rook')), 'org_cooldown')
        truthy(s.org.setLimits(W.STAFF, { CodenameCooldownMinutes = 0 }))
        truthy(s.org.setCodename(RECRUIT, nil, 'Rook'))
        truthy(s.org.setCodename(RECRUIT, nil, false))
        eq(org.members.RECRUIT1.codename, nil)
        eq(org.settings.codenames.RECRUIT1, nil)
    end)

    it('refuses a non-member', function()
        local s = world()
        eq(select(2, s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, 'Ghost')), 'org_not_member')
    end)
end)

describe('a boss giving one', function()
    it('needs Assign codenames, below their rank, and the member then cannot change it', function()
        local s, _, org = world()
        eq(select(2, s.org.setCodename(BOSS, 'RECRUIT1', 'Ghost')), 'org_no_power')
        W.allow(s, 3, 'M7')
        truthy(s.org.setCodename(BOSS, 'RECRUIT1', 'Ghost'))
        eq(org.members.RECRUIT1.codename, 'Ghost')
        eq(select(2, s.org.setCodename(RECRUIT, nil, 'Shade')), 'org_locked', 'given, not theirs to change')
        eq(W.call('orgMine', 13, {}).data.codenameGiven, true)
        -- Rank: a lieutenant with the power cannot name the boss.
        W.allow(s, 2, 'M7')
        eq(select(2, s.org.setCodename({ cid = 'LIEUT001', source = 12 }, 'BOSS0001', 'Kingpin')), 'org_rank')
        -- One staff gave stays staff's.
        truthy(s.org.memberStaff(W.STAFF, 'RECRUIT1', { codename = 'Spectre' }))
        eq(select(2, s.org.setCodename(BOSS, 'RECRUIT1', 'Wraith')), 'org_locked')
        s.audit.flush()
        truthy(#s.storage.auditByAction('org_codename', 5) >= 1, 'staff\'s on the record')
    end)

    it('goes through the phone with a member handle, and takes hostile payloads', function()
        local s, _, org = world()
        W.allow(s, 3, 'M7')
        W.allow(s, 3, 'M1')
        local recruit
        for _, m in ipairs(W.call('orgMembers', 11, {}).data.rows) do
            if m.grade == 0 then recruit = m.ref end
        end
        local reply = W.call('orgCodename', 11, { member = recruit, codename = 'Magpie' })
        eq(reply.ok, true, tostring(reply.err))
        eq(org.members.RECRUIT1.codename, 'Magpie')
        for _, payload in ipairs({ { member = 'RECRUIT1', codename = 'X1x' }, { member = recruit, codename = 5 },
            { member = recruit, codename = { 'a' } }, { member = recruit, codename = string.rep('z', 500) },
            { member = recruit }, { member = 12, codename = 'Nope' }, 'junk' }) do
            local r = W.call('orgCodename', 11, payload)
            truthy(r, 'answered')
            falsy(r.ok, 'refused')
            truthy(r.data and r.data.message, 'worded: ' .. tostring(r.err))
        end
        eq(org.members.RECRUIT1.codename, 'Magpie', 'unchanged')
    end)
end)

describe('where a codename is shown', function()
    it('shows it in the roster inside the organisation, with no real name beside it', function()
        local s = world()
        truthy(s.org.setCodename(RECRUIT, nil, 'Sparrow'))
        W.allow(s, 3, 'M1')
        local found
        for _, m in ipairs(W.call('orgMembers', 11, {}).data.rows) do
            if m.codename == 'Sparrow' then found = m end
        end
        truthy(found, 'listed')
        eq(found.name, 'Sparrow')
        eq(found.realName, nil, 'a boss is never shown the name behind it')
    end)

    it('shows it to the placer in place of the name of a hitman who took it openly', function()
        local s, f = world()
        Config.Anonymity = Config.Anonymity or {}
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook Ash', source = 3 }, 0))
        truthy(s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, 'Jackdaw'))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local mine = W.call('mine', 1, {})
        local seen = {}
        for _, card in ipairs(mine.data.created or {}) do
            for _, h in ipairs(card.hitmen or {}) do seen[#seen + 1] = h end
        end
        truthy(#seen >= 1, 'the placer sees the operative')
        local text = ''
        for _, h in ipairs(seen) do text = text .. tostring(h.name) .. ' ' .. tostring(h.alias) .. ';' end
        eq(text:find('Rook', 1, true), nil, 'never the real name: ' .. text)
        eq(seen[1].name, 'Jackdaw', 'the codename in place of the name')
        eq(s.org.shownName('HITMAN01', 'Rook Ash'), 'Jackdaw')
    end)

    it('never names a hitman who took it anonymously, codename or not', function()
        local s, f = world()
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook Ash', source = 3 }, 0))
        truthy(s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, 'Jackdaw'))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id, true))
        local mine = W.call('mine', 1, {})
        for _, card in ipairs(mine.data.created or {}) do
            for _, h in ipairs(card.hitmen or {}) do
                eq(h.name, nil, 'no name of any kind')
            end
        end
    end)

    it('shows the name again once codenames are off', function()
        local s = world()
        truthy(s.org.setCodename(RECRUIT, nil, 'Sparrow'))
        Config.Organisation.Codenames = false
        eq(s.org.shownName('RECRUIT1', 'P13 Org'), 'P13 Org')
    end)
end)
