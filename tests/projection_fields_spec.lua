--- Every field the page reads off a contract, present in every projection
--- that can carry that contract, in every state, for every role.
---
--- The page reads twenty fields off a contract object. A projection that
--- omits one does not fail: JavaScript reads undefined, and the result is a
--- chip that says "undefined", a button drawn for a rule the page cannot
--- evaluate, or money rendered as NaN. None of those throw, so none of them
--- reach the render-crash guards — they are simply wrong on screen.
---
--- Two directions matter and they are different:
---
---   * A field the page reads and the projection never sends. That is the
---     wrong-on-screen case above.
---   * A field the projection sends and no page reads. Harmless on screen and
---     worth knowing about anyway: on an anonymous contract every extra field
---     is a chance to send something that should not leave the server, and
---     one of them was how a stake figure the creator had not disclosed
---     reached the board.
---
--- The field list is extracted from ui/app.js rather than kept by hand, so a
--- page that starts reading a twenty-first field is covered the moment it
--- does.

local PAGE_SOURCE = read_file('crimson-hitman/ui/app.js')

--- Every `contract.<field>` the page reads, minus the ones it writes into a
--- request rather than reads off a projection.
local function fieldsThePageReads()
    local seen, out = {}, {}
    for name in PAGE_SOURCE:gmatch('contract%.([%a][%w]*)') do
        if not seen[name] then seen[name] = true; out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

--- Fields whose presence is CONDITIONAL, with the condition.
---
--- Not an allowlist: each of these is a rule, and the rule is asserted
--- separately below. Demanding them unconditionally was my own first version
--- of this file and it failed against three deliberate decisions — which is
--- the useful kind of failure, because writing down why each one is absent is
--- what turns "the field is missing" into "the field is absent when it should
--- be".
local CONDITIONAL = {
    -- Written by the page from its own kidnapProgress polling.
    kidnapProgress = 'the page fills this in, not the projection',
    -- Stamped by the page as the reply lands, to count the clock down from.
    clockReadAt = 'the page fills this in, not the projection',
    -- Marked by the page on the whitelisted-job view's entries, whose clock
    -- is the lifetime: "within", since the contract may end sooner.
    atLatest = 'the page fills this in, on the whitelisted-job view only',
    -- Never on the target's card: a named client's absence is what stops it.
    clockStopped = 'every role but the target',
    -- Who the hitman is on it, drawn on their own card. Nobody else is one.
    myAlias     = 'hitman-only',
    myAnonymous = 'hitman-only',
    -- Only to a viewer who can never take the contract, with the reason.
    -- Its absence is what lets the board draw Accept.
    barred = 'public viewers only, and only when acceptance would be refused',
    -- What the contract holds in money. The creator's alone: it is the
    -- figure they can add up to the ceiling from, and nobody else adds.
    valueHeld = 'creator-only',
    -- Whether anybody ever took it up, for Withdraw's words and the waits
    -- it starts. The creator's own contract, and every acceptance and walk-
    -- away was told to them as it happened.
    everTaken = 'creator-only',
    -- Only on a contract the viewer is the target of. Its absence elsewhere
    -- is the rule, not a gap.
    bailoutAvailable = 'target-only',
    bailoutAmount    = 'target-only, and creator-only for the figure',
    -- Target-only, and only once they have actually paid. Its absence is how
    -- the card knows to offer the buy button instead.
    bailoutPaid      = 'target-only, and only after the premium has been taken',
    -- How long the hitman on it still has, for that same paid card.
    bailoutSecondsLeft = 'target-only, and only while a paid buyout waits out its delay',
    -- The same delay on the hitman's own card: the warning the delay is for.
    buyoutClosesIn = 'hitman-only, and only while a paid buyout waits out its delay',
    -- The viewer's own informant answer, so only once they have bought one,
    -- and only while the reroll lock lasts.
    informantAnswer  = 'creator or target, and only inside the reroll lock after buying',
    -- The viewer's own purchases left, where the server runs informants.
    informantLeft    = 'creator or target, and only where informants run',
    -- The kind of protected job, only where the target holds one.
    targetProtectedAs = 'present only when targetProtected is',
    -- Exactly one of these two, never both: when the creator chose anonymity
    -- no key carrying their name exists on the payload at all.
    creatorAnonymous = 'present only when the creator chose anonymity',
    creatorName      = 'present only when they did not',
    -- The creator learns how many operatives are on it and, where a hitman
    -- chose to be seen, who. Nobody else gets the list.
    hitmen          = 'creator-only',
    -- A handle for a face that has been rendered. Nil until the target's own
    -- client has answered, which asking is what schedules.
    targetImageId    = 'present once a headshot exists to point at',
    -- When the other side last wrote in the hitman's thread, for the unread
    -- dot on Message. The hitman's alone (the creator's is per operative,
    -- under hitmen), and only once a message from the other side exists.
    lastMessageAt    = 'hitman-only, and only once the other side has written',
    -- The handover's meeting point (server/meeting.lua): on the placer's
    -- card of an alive-only contract a hitman holds, and an active hitman's
    -- once one is set, while Config.Kidnap.MeetingPoint is on; never on the
    -- board (meeting_spec, "who is shown it" and "the switch").
    meetingSet       = 'creator and active hitmen only, on an alive-only contract a hitman holds',
    -- The informant tip (server/locationtip.lua): an active hitman's own,
    -- on their card under Mine alone, never on the board; and on the
    -- target's, when they were told one was bought (location_tip_spec).
    locationTip      = 'hitman-only, on their own card, where tips are sold or one is showing',
    tippedAt         = 'target-only, and only once they were told a tip was bought',
}

--- Which roles see a contract at all, and through which projection call.
local ROLES = { 'creator', 'hitman', 'target', 'stranger' }

local function build(state)
    local s = newStack()
    local f = fixture(s)
    Env.players[1].PlayerData.money.bank = 400000
    Env.players[3].PlayerData.money.bank = 400000

    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
        bailoutAmount = 9000, penaltyAmount = 2500,
    })
    truthy(c, 'the fixture needs a contract')

    if state ~= CH.STATE.ACTIVE then
        truthy(s.contracts.accept(f.hitman, c.id), 'accept')
    end
    if state == CH.STATE.COMPLETING then
        truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED,
            CH.STATE.COMPLETING, 'fixture'))
    end
    return s, f, c
end

--- Every contract object any projection hands to the page, for one viewer.
local function contractsFor(s, actor)
    local out = {}

    local board = s.projection.listing(actor, 1)
    for _, row in ipairs((board and board.contracts) or {}) do
        out[#out + 1] = { where = 'board', contract = row }
    end

    -- Three separate calls, not three keys on one table. app.lua composes
    -- them into the payload the page reads.
    for _, view in ipairs({ { 'created', s.projection.mine(actor.cid) },
                            { 'accepted', s.projection.accepted(actor.cid) },
                            { 'onMe', s.projection.onMe(actor.cid) } }) do
        for _, row in ipairs(view[2] or {}) do
            out[#out + 1] = { where = 'mine.' .. view[1], contract = row }
        end
    end

    return out
end

describe('every field the page reads off a contract', function()
    it('finds the fields to check, or it is checking nothing', function()
        local fields = fieldsThePageReads()
        truthy(#fields >= 15,
            'only ' .. #fields .. ' fields extracted from ui/app.js; the '
            .. 'pattern has stopped matching rather than the page having '
            .. 'shrunk')
    end)

    it('does not name a condition for a field the page does not read', function()
        local reads = {}
        for _, name in ipairs(fieldsThePageReads()) do reads[name] = true end
        local stale = {}
        for name in pairs(CONDITIONAL) do
            if not reads[name] then stale[#stale + 1] = name end
        end
        table.sort(stale)
        eq(#stale, 0, 'a condition for a field nothing reads has stopped '
            .. 'being checked: ' .. table.concat(stale, ', '))
    end)

    for _, state in ipairs({ CH.STATE.ACTIVE, CH.STATE.ACCEPTED,
                             CH.STATE.COMPLETING }) do
        for _, role in ipairs(ROLES) do
            it(('a %s contract, as seen by the %s'):format(state, role), function()
                local s, f = build(state)

                local actor
                if role == 'creator' then actor = f.creator
                elseif role == 'hitman' then actor = f.hitman
                elseif role == 'target' then actor = f.target
                else
                    Env.addPlayer({ source = 11, citizenid = 'NOSY0001',
                                    license = 'license:nosy', cash = 10, bank = 10,
                                    firstname = 'Ida', lastname = 'Nkemelu' })
                    actor = s.identity.resolve(11)
                end
                truthy(actor, 'the viewer has to resolve')

                local views = contractsFor(s, actor)
                -- A stranger may legitimately see nothing on some states.
                if #views == 0 then return end

                local missing = {}
                for _, view in ipairs(views) do
                    for _, field in ipairs(fieldsThePageReads()) do
                        if CONDITIONAL[field] == nil
                            and view.contract[field] == nil then
                            missing[#missing + 1] = view.where .. '.' .. field
                        end
                    end
                end

                -- Deduplicated, so one absent field on five rows reads as one
                -- problem rather than five.
                local seen, unique = {}, {}
                for _, name in ipairs(missing) do
                    if not seen[name] then seen[name] = true; unique[#unique + 1] = name end
                end
                table.sort(unique)

                eq(#unique, 0,
                    ('the page reads these and this projection does not send '
                    .. 'them, so they render as undefined: %s')
                        :format(table.concat(unique, ', ')))
            end)
        end
    end
end)

describe('the fields whose presence is a rule', function()
    local function boardRow(s, actor)
        local board = s.projection.listing(actor, 1)
        return ((board and board.contracts) or {})[1]
    end

    it('names the creator, or says they are anonymous, never both or neither', function()
        for _, anonymous in ipairs({ false, true }) do
            local s = newStack()
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01',
                reason = 'x', anonymous = anonymous,
                reward = { baseline = { cash = 5000 } } }))

            local row = boardRow(s, f.hitman)
            truthy(row, 'the board should carry it')

            local named = row.creatorName ~= nil
            local hidden = row.creatorAnonymous == true
            truthy(named ~= hidden,
                ('anonymous=%s gave creatorName=%s creatorAnonymous=%s; the '
                .. 'page picks between them, so exactly one must be there')
                    :format(tostring(anonymous), tostring(row.creatorName),
                            tostring(row.creatorAnonymous)))
            if anonymous then
                falsy(row.creatorName,
                    'when anonymous, no key carrying the name may exist at all')
            end
        end
    end)

    it('gives the hitman list to the creator and to nobody else', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id))
        -- The target is shown it once the alert's wait is over.
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)

        local own = (s.projection.mine(f.creator.cid) or {})[1]
        truthy(own, 'the creator should see their own contract')
        truthy(own.hitmen, 'and how many operatives are on it')

        falsy(boardRow(s, f.hitman) and boardRow(s, f.hitman).hitmen,
            'the board must not carry who is working')

        local targetView = (s.projection.onMe(f.target.cid) or {})[1]
        truthy(targetView, 'the target should see the contract on them')
        falsy(targetView.hitmen,
            'and the target must not be told who is after them')

        local hitmanView = (s.projection.accepted(f.hitman.cid) or {})[1]
        truthy(hitmanView, 'the hitman should see what they took')
        falsy(hitmanView.hitmen,
            'and a hitman must not be told who they are competing with')
    end)

    it('counts the viewer\'s own informant purchases left, on their own card only', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local most = Config.Informant.MaxPurchasesPerContract
        eq((s.projection.mine(f.creator.cid) or {})[1].informantLeft, most, 'the creator, none spent')
        eq((s.projection.onMe(f.target.cid) or {})[1].informantLeft, most, 'the target')
        falsy(boardRow(s, f.hitman).informantLeft, 'nobody else')

        Env.players[2].PlayerData.money.bank = 400000
        truthy(s.informant.buy(f.target, c.id))
        eq((s.projection.onMe(f.target.cid) or {})[1].informantLeft, most - 1,
            'one spent is one fewer, on their own card')
        eq((s.projection.mine(f.creator.cid) or {})[1].informantLeft, most,
            'and nobody else\'s count moves')

        Config.Informant.Enabled = false
        falsy((s.projection.onMe(f.target.cid) or {})[1].informantLeft, 'none where none are sold')
    end)

    -- W055: every protected target was "a sworn officer". The kind of job,
    -- never which force, and only where the flag is already set.
    it('says what kind of protected job, only for a protected target', function()
        for _, case in ipairs({
            { job = nil, kind = nil },
            { job = { name = 'ambulance', type = 'ems' }, kind = 'emergency' },
            { job = { name = 'police', type = 'leo' }, kind = 'law' },
            { job = { name = 'lawyer' }, kind = 'legal' },
        }) do
            local s = newStack()
            local f = fixture(s, { targetJob = case.job })
            Env.players[1].PlayerData.money.bank = 400000
            truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01',
                reason = 'x', reward = { baseline = { cash = 5000 } } }))
            local row = boardRow(s, f.hitman)
            eq(row.targetProtectedAs, case.kind, tostring(case.job and case.job.name))
            eq(row.targetProtected, case.kind ~= nil)
        end
    end)

    it('carries a face handle once there is a face to point at', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } }))

        -- Nothing rendered yet: asking is what schedules it, so the first
        -- look legitimately has no handle.
        local first = boardRow(s, f.hitman)
        truthy(first, 'the board row')

        -- The target's client answers. Only an image the server ASKED for is
        -- accepted — a deliberate guard, so the request has to come first.
        s.mugshot.request('TARGET01')
        truthy(s.mugshot.store('TARGET01', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='),
            'store a face the server asked for')

        local second = boardRow(s, f.hitman)
        truthy(second.targetImageId,
            'once a headshot exists the board has to point at it, or no card '
            .. 'ever shows a face')
        falsy(second.targetImageId == 'TARGET01',
            'and it is a handle, not the citizen id')
    end)
end)
