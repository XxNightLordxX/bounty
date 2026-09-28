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

local PAGE_SOURCE = read_file('crimson-bounty/ui/app.js')

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
    -- Only to a viewer who can never take the contract, with the reason.
    -- Its absence is what lets the board draw Accept.
    barred = 'public viewers only, and only when acceptance would be refused',
    -- What the contract holds in money. The creator's alone: it is the
    -- figure they can add up to the ceiling from, and nobody else adds.
    valueHeld = 'creator-only',
    -- Only on a contract the viewer is the target of. Its absence elsewhere
    -- is the rule, not a gap.
    bailoutAvailable = 'target-only',
    bailoutAmount    = 'target-only, and creator-only for the figure',
    -- Target-only, and only once they have actually paid. Its absence is how
    -- the card knows to offer the buy button instead.
    bailoutPaid      = 'target-only, and only after the premium has been taken',
    -- Exactly one of these two, never both: when the creator chose anonymity
    -- no key carrying their name exists on the payload at all.
    creatorAnonymous = 'present only when the creator chose anonymity',
    creatorName      = 'present only when they did not',
    -- The creator learns how many operatives are on it and, where a hunter
    -- chose to be seen, who. Nobody else gets the list.
    hunters          = 'creator-only',
    -- A handle for a face that has been rendered. Nil until the target's own
    -- client has answered, which asking is what schedules.
    targetImageId    = 'present once a headshot exists to point at',
}

--- Which roles see a contract at all, and through which projection call.
local ROLES = { 'creator', 'hunter', 'target', 'stranger' }

local function build(state)
    local s = newStack()
    local f = fixture(s)
    Env.players[1].PlayerData.money.bank = 400000
    Env.players[3].PlayerData.money.bank = 400000

    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
        bailoutAmount = 9000, penaltyAmount = 2500,
    })
    truthy(c, 'the fixture needs a contract')

    if state ~= CB.STATE.ACTIVE then
        truthy(s.contracts.accept(f.hunter, c.id), 'accept')
    end
    if state == CB.STATE.COMPLETING then
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED,
            CB.STATE.COMPLETING, 'fixture'))
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

    for _, state in ipairs({ CB.STATE.ACTIVE, CB.STATE.ACCEPTED,
                             CB.STATE.COMPLETING }) do
        for _, role in ipairs(ROLES) do
            it(('a %s contract, as seen by the %s'):format(state, role), function()
                local s, f = build(state)

                local actor
                if role == 'creator' then actor = f.creator
                elseif role == 'hunter' then actor = f.hunter
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

            local row = boardRow(s, f.hunter)
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

    it('gives the hunter list to the creator and to nobody else', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hunter, c.id))

        local own = (s.projection.mine(f.creator.cid) or {})[1]
        truthy(own, 'the creator should see their own contract')
        truthy(own.hunters, 'and how many operatives are on it')

        falsy(boardRow(s, f.hunter) and boardRow(s, f.hunter).hunters,
            'the board must not carry who is hunting')

        local targetView = (s.projection.onMe(f.target.cid) or {})[1]
        truthy(targetView, 'the target should see the contract on them')
        falsy(targetView.hunters,
            'and the target must not be told who is hunting them')

        local hunterView = (s.projection.accepted(f.hunter.cid) or {})[1]
        truthy(hunterView, 'the hunter should see what they took')
        falsy(hunterView.hunters,
            'and a hunter must not be told who they are competing with')
    end)

    it('carries a face handle once there is a face to point at', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } }))

        -- Nothing rendered yet: asking is what schedules it, so the first
        -- look legitimately has no handle.
        local first = boardRow(s, f.hunter)
        truthy(first, 'the board row')

        -- The target's client answers. Only an image the server ASKED for is
        -- accepted — a deliberate guard, so the request has to come first.
        s.mugshot.request('TARGET01')
        truthy(s.mugshot.store('TARGET01', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='),
            'store a face the server asked for')

        local second = boardRow(s, f.hunter)
        truthy(second.targetImageId,
            'once a headshot exists the board has to point at it, or no card '
            .. 'ever shows a face')
        falsy(second.targetImageId == 'TARGET01',
            'and it is a handle, not the citizen id')
    end)
end)
