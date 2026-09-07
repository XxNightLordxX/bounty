--- The whole journey, through the boundary a player actually crosses.
---
--- Measured, not guessed: instrumenting App.reply across the whole suite
--- showed that of twenty-nine handlers, thirteen ever returned ok through
--- the net event. The other sixteen — accept and abandon among them, the
--- two most pressed buttons in the resource — were only ever exercised by
--- calling their module directly, which skips the payload the page sends.
---
--- That is the gap that let reduce_reward ship: the page sent { amount },
--- the server read payload.slot, every module test passed, and the button
--- did nothing on a live server. A handler is not covered because something
--- called its module. It is covered when the shape the app posts arrives at
--- it and comes back ok.
---
--- Payload shapes below are copied from the post() sites in ui/app.js and
--- the App.request() sites in client/main.lua, with the line noted. If a
--- shape drifts there and not here this suite goes on passing while the
--- button stops working, so read them from the page rather than inventing
--- them.

--- Every handler that answered ok, so the last test can prove the journey
--- really crossed what it claims rather than falling out early with
--- everything after it silently unrun.
local succeeded = {}

local function call(name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = source
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then
            local reply = event.args[1]
            if reply and reply.ok then succeeded[name] = true end
            return reply
        end
    end
    return nil
end

--- Assert a request came back ok, and say what it said when it did not.
--- A refusal code on its own is not something anybody can act on.
local function ok(name, source, payload, why)
    local reply = call(name, source, payload)
    truthy(reply, ('%s sent no reply at all'):format(name))
    truthy(reply.ok, ('%s was refused (%s)%s'):format(
        name, tostring(reply.err), why and (' — ' .. why) or ''))
    return reply.data
end

local AT = { x = 200.0, y = 200.0, z = 30.0 }

local function seeded(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        bailoutAmount = opts.bailout,
    })
    return s, f, c
end

--- The handle the card is actually given for a face. Not a contract id:
--- the app posts whatever reference the projection handed it, and a
--- mugshot handle is rotated every time the image is re-rendered.
local VALID_IMAGE = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='
local function faceHandle(s, cid)
    s.mugshot.request(cid)
    truthy(s.mugshot.store(cid, VALID_IMAGE), 'the fixture image must store')
    return s.mugshot.handleFor(cid)
end

describe('a hunter taking a contract and putting it back', function()
    it('accepts through the event the button actually sends', function()
        local s, f, c = seeded()
        -- ui/app.js:737 — post('accept', { id, anonymous })
        ok('accept', 3, { id = c.id, anonymous = false })
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
    end)

    --- The anonymity flag has to survive the crossing, not just be sent.
    --- A handler that read the wrong key would still answer ok, and the
    --- hunter would be named to their target having paid a fee not to be.
    it('accepts anonymously when the hunter asks to', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = true })

        local hunters = s.storage.readHunters(c.id) or {}
        truthy(#hunters > 0, 'the accept has to have recorded a hunter')
        eq(hunters[1].anon, true,
            'a hunter who asked to be anonymous, and paid for it, has to be')
    end)

    it('names a hunter who did not ask to be anonymous', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })

        local hunters = s.storage.readHunters(c.id) or {}
        truthy(#hunters > 0, 'the accept has to have recorded a hunter')
        eq(hunters[1].anon, false,
            'anonymity must not be the default: it is a paid choice')
    end)

    it('abandons through the event the button actually sends', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })
        -- ui/app.js:544 — post('abandon', { id })
        ok('abandon', 3, { id = c.id })
    end)
end)

describe('a target buying their way out', function()
    it('bails out through the event the button actually sends', function()
        local s, f, c = seeded({ bailout = 15000 })
        -- ui/app.js:815 — post('bailout', { id })
        ok('bailout', 2, { id = c.id },
            'the target holds 20000 in the bank against a 15000 buyout')
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
    end)
end)

describe('the two parties talking', function()
    local function talking()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })
        -- ui/app.js:1429 — post('threads', { id })
        local threads = ok('threads', 1, { id = c.id })
        local handle
        for _, t in ipairs(threads and (threads.threads or threads) or {}) do
            handle = t.handle or handle
        end
        return s, f, c, handle
    end

    it('sends into a thread and reads it back', function()
        local s, f, c, handle = talking()
        -- ui/app.js:1459 — post('sendMessage', { id, thread, body })
        ok('sendMessage', 1, { id = c.id, thread = handle, body = 'Where are you?' })
        -- ui/app.js:1418 — post('readThread', { id, thread })
        ok('readThread', 1, { id = c.id, thread = handle })
    end)

    it('asks for a call through the event the button actually sends', function()
        local s, f, c, handle = talking()
        -- ui/app.js:1441 — post('requestCall', { id, thread })
        ok('requestCall', 1, { id = c.id, thread = handle })
    end)
end)

describe('changing a contract after it is placed', function()
    it('improves the deadline through the event the button sends', function()
        local s, f, c = seeded()
        -- ui/app.js:1131 — post('improve', { id, kind, payload })
        ok('improve', 1, { id = c.id, kind = 'extend_deadline',
                           payload = { seconds = 600 } })
    end)

    it('adds to the pot through the event the button sends', function()
        local s, f, c = seeded()
        -- ui/app.js:1376 — post('addEscrow', { id, reward })
        ok('addEscrow', 1, { id = c.id, reward = { baseline = { cash = 1000 } } })
    end)

    it('proposes, is listed as open, and is answered', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })

        -- ui/app.js:1032 — sendProposal(contract, 'shorten_deadline', { seconds })
        local proposal = ok('propose', 1, { id = c.id, kind = 'shorten_deadline',
                                            payload = { seconds = 600 } })
        truthy(proposal and proposal.id, 'a proposal has to come back with its id')

        -- ui/app.js:919 — post('amendments', { id })
        ok('amendments', 3, { id = c.id },
            'a proposal nobody can see is a proposal nobody can answer')

        -- ui/app.js:930 — post('respondAmendment', { id: proposal.id, approve })
        --
        -- The outcome is asserted, not just the reply. Declining is also a
        -- successful response, so a handler that read the wrong key and
        -- turned every approval into a decline would still answer ok — and
        -- an "approve" button that quietly declines is worse than one that
        -- errors, because nobody finds out.
        local answer = ok('respondAmendment', 3, { id = proposal.id, approve = true })
        eq(answer and answer.outcome, 'applied',
            'approving has to apply the amendment, not decline it')

        local after = s.storage.readContract(c.id)
        truthy(after.deadline_at and after.deadline_at <= os.time() + 600,
            'an approved shorten_deadline has to actually move the deadline')
    end)

    --- The regression this whole suite exists for. The page used to send
    --- { amount } here and the server read payload.slot, so the proposal
    --- was built with nothing in it. Every module-level test passed.
    it('reduces a reward by the slot the page names, not an amount', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })

        local breakdown = ok('rewardBreakdown', 1, { id = c.id })
        local lines = breakdown and (breakdown.lines or breakdown.removable) or {}
        truthy(#lines > 0, 'the editor has to be offered something to take back')

        -- ui/app.js:1070 — sendProposal(contract, 'reduce_reward', { slot })
        local proposal = ok('propose', 1, {
            id = c.id, kind = 'reduce_reward',
            payload = { slot = lines[1].id or lines[1].slot },
        })
        truthy(proposal and proposal.id, 'a reduction has to come back with its id')
    end)
end)

describe('taking somebody alive', function()
    it('arms a kidnap and reads its countdown', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })

        -- All three together, target restrained: what the client checks
        -- before it ever offers the button.
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true

        -- client/main.lua — App.request('armKidnap', { id })
        ok('armKidnap', 3, { id = c.id })
        -- client/main.lua — App.request('kidnapProgress', { id })
        ok('kidnapProgress', 3, { id = c.id })
    end)
end)

describe('proving the kill', function()
    it('gets a token and submits a photo against it', function()
        local s, f, c = seeded()
        ok('accept', 3, { id = c.id, anonymous = false })

        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()

        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)

        -- client/main.lua:455 — App.request('requestPhotoToken', { id })
        local issued = ok('requestPhotoToken', 3, { id = c.id })
        truthy(issued and issued.token, 'a token request has to hand back a token')

        -- client/main.lua:493 — App.request('submitPhoto', { token, url })
        ok('submitPhoto', 3, { token = issued.token,
                               url = 'https://cdn.fivemanage.com/p.png' })
    end)

    it('serves the face the card asks for, by the handle it was given', function()
        local s, f, c = seeded()
        local handle = faceHandle(s, 'TARGET01')
        truthy(handle, 'the fixture must produce a handle to ask for')
        -- ui/app.js:322 — post('mugshotImage', { id })
        local served = ok('mugshotImage', 1, { id = handle })
        eq(served.image, VALID_IMAGE)
    end)
end)

--- The guard that stops this gap reopening.
---
--- Without it a journey that falls out at step two goes on "passing" every
--- test after it, because a test whose assertion never runs cannot fail.
--- This one counts what actually came back ok across the whole file.
describe('what this suite really covered', function()
    it('got an ok from every handler it claims to exercise', function()
        local claimed = {
            'accept', 'abandon', 'bailout', 'threads', 'sendMessage',
            'readThread', 'requestCall', 'improve', 'addEscrow', 'propose',
            'amendments', 'respondAmendment', 'armKidnap', 'kidnapProgress',
            'requestPhotoToken', 'submitPhoto', 'mugshotImage',
            'rewardBreakdown',
        }
        local missing = {}
        for _, name in ipairs(claimed) do
            if not succeeded[name] then missing[#missing + 1] = name end
        end
        eq(#missing, 0,
            'these handlers never once returned ok through the net event, so '
            .. 'nothing here proves the page can reach them: '
            .. table.concat(missing, ', '))
    end)
end)

--- A reason mode the operator can choose, and the form that has to offer it.
---
--- Config.Reason.Mode takes 'freetext', 'preset' or 'off'. Two of those
--- worked. On 'preset' the server requires a reasonPreset index, the page
--- had no picker and never sent one, and Util.toPositive(nil) is nil — so
--- every contract placed on such a server was refused with invalid_input,
--- for as long as the setting stayed. Nothing in the app could say why: the
--- form draws a reason box, the player fills it in, and the server rejects
--- a field the box does not correspond to.
---
--- The same shape as the money sources an operator had switched off, which
--- the form went on offering until caps started carrying the flags.
describe('the reason a contract gives, in every mode the operator can pick', function()
    local function submitAs(mode, extra)
        local s = newStack()
        local f = fixture(s)
        local sent = {
            target = 'TARGET01',
            reason = 'Unpaid debt',
            mode = 'exclusive',
            reward = { slots = { { baseline = { cash = 5000 } } } },
        }
        for k, v in pairs(extra or {}) do sent[k] = v end

        local reply
        withConfig({ { Config.Reason, 'Mode', mode } }, function()
            -- The target handle the page posts is whatever browseTargets
            -- handed it, so go through that rather than inventing one.
            local list = call('browseTargets', 1, { scope = 'online', page = 1 })
            truthy(list and list.ok, 'the form has to be able to list somebody')
            local handle
            for _, row in ipairs(list.data.people or {}) do
                if row.name == 'Dana Reyes' then handle = row.handle end
            end
            truthy(handle, 'the target the contract names has to be listed')
            sent.target = handle
            reply = call('create', 1, sent)
        end)
        return s, reply
    end

    it('places a contract on a freetext server', function()
        local _, reply = submitAs('freetext')
        truthy(reply and reply.ok,
            'freetext is the default and has to work: ' .. tostring(reply and reply.err))
    end)

    it('places a contract on a server that asks for no reason at all', function()
        local _, reply = submitAs('off')
        truthy(reply and reply.ok,
            'off means the reason is not required, not that nothing can be '
            .. 'placed: ' .. tostring(reply and reply.err))
    end)

    --- The one that was broken. The page is told the mode and the list, so
    --- it can send an index; without that this is unplaceable.
    it('places a contract on a preset server, using what the form was offered', function()
        local s = newStack()
        fixture(s)
        withConfig({ { Config.Reason, 'Mode', 'preset' } }, function()
            local wallet = call('rewardOptions', 1, {})
            truthy(wallet and wallet.ok, 'the form has to be able to read the wallet')
            local caps = wallet.data.caps
            eq(caps.reasonMode, 'preset',
                'the form cannot draw a picker for a mode it is never told about')
            truthy(caps.reasonPresets and #caps.reasonPresets > 0,
                'a picker with nothing in it is not a picker')
        end)
    end)

    it('is placeable when the form sends the index the picker gives it', function()
        local _, reply = submitAs('preset', { reasonPreset = 1 })
        truthy(reply and reply.ok,
            'a contract carrying a valid preset index has to be placeable: '
            .. tostring(reply and reply.err))
    end)
end)
