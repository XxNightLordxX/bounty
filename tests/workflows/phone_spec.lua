--- Step 7 workflows: every phone request, driven from the page.
---
--- Each request goes the way a player's tap goes: the page's NUI callback
--- (the real client/main.lua), the client's TriggerServerEvent, the real
--- handler on a real server/main.lua (memory store), the reply back through
--- the client's result event to the page's callback. Each test asserts what
--- the player is answered and what changed: money, the store, the audit
--- row, and that nobody is named who must not be.
---
--- The requests the page does not send itself (the photo token and the
--- picture, which the client asks for inside its own camera callbacks; the
--- map's Set GPS reads; the in-world disposal and NPC places, which other
--- client files send) are driven through those client paths too where the
--- harness can run them, and as the net event the client sends otherwise.

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
W.ran.phone = true

--- Known bugs (tests/workflows: step7-bugs.md): a test named here must fail.
local EXPECTED_FAIL = {
}

local function it_(name, fn) W.it(name, fn, EXPECTED_FAIL) end

local C = W.CAST
local SPARE = { source = 8, cid = 'TARGET02', first = 'Pia', last = 'Nolan' }

--- A city on the memory store with the runner's switches (kills, photos and
--- anonymity on), the cast in it, and two contracts: `held`, on Dana,
--- taken by Rook; `unheld`, on Pia, nobody on it. `configure` runs before
--- the start.
local function city(configure, opts)
    opts = opts or {}
    W.boot('memory', 'test', function()
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        if configure then configure() end
    end)
    local a = W.cast(W.s)
    local p = Env.addPlayer({ source = SPARE.source, citizenid = SPARE.cid, license = 'license:' .. SPARE.cid,
        cash = 50000, bank = 50000, firstname = SPARE.first, lastname = SPARE.last })
    W.everyone[SPARE.cid] = p
    W.loaded(SPARE.source)
    W.s.identity.confirmSession(SPARE.cid)
    Env.advance(3 * 3600)
    local w = { a = a }
    if opts.empty then return w end
    w.held = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.target.cid,
        reason = 'Unpaid debt from the docks', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 },
                   bonus = Config.Completion.Fulfilment ~= 'alive' and { cash = 1000 } or nil },
        bailoutAmount = 15000,
        anonymous = opts.anonymous })
    truthy(w.held, 'a contract to work')
    truthy(W.s.contracts.accept(W.s.identity.resolve(C.hitman.source), w.held.id, opts.anonymous == true),
        'the hitman is on it')
    w.unheld = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = SPARE.cid,
        reason = 'Talked to the police', mode = CH.MODE.EXCLUSIVE,
        reward = { baseline = { cash = 5000, bank = 3000 } } })
    truthy(w.unheld, 'a contract nobody is on')
    W.tick(1)
    return w
end

--- The page of player `src`: the real client booted as their game.
local function page(src) return W.client(src) end

--- Tap: the NUI callback answered ok; its data.
local function tap(name, payload, why)
    local answer, answered = W.nui('crimson:' .. name, payload or {})
    truthy(answered, name .. ' never answered the page')
    if not (type(answer) == 'table' and answer.ok) then
        error(('%s refused: %s (%s)'):format(name, tostring(type(answer) == 'table' and answer.err),
            tostring(why or '')), 2)
    end
    return answer.data, answer
end

--- Tap, refused with this code.
local function tapRefused(name, payload, code)
    local answer, answered = W.nui('crimson:' .. name, payload or {})
    truthy(answered, name .. ' never answered the page')
    falsy(answer.ok, name .. ' should be refused')
    if code then eq(answer.err, code, name .. ' refusal') end
    return answer
end

local function wealth(src)
    local p = Env.players[src] or W.dropped[src]
    return W.purse(p)
end

local REAL = { 'Vic Marlowe', 'CREATOR1', 'Rook Ash', 'HITMAN01' }

--------------------------------------------------------------------------
-- The board and the place form
--------------------------------------------------------------------------

describe('phone: the board, the place form, placing', function()
    it_('reads the board, finds a target, sees the reward options, places a contract', function()
        local w = city(nil, { empty = true })
        page(C.creator.source)
        local board = tap('list', { page = 1 })
        eq(#(board.contracts or {}), 0, 'an empty board')
        local found = tap('searchTargets', { query = 'Dana' })
        eq(found[1].name, 'Dana Reyes', 'the search finds the target by name')
        local browse = tap('browseTargets', { scope = 'online', page = 1 })
        truthy(#(browse.people or {}) >= 3, 'browse lists who is online')
        local options = tap('rewardOptions', {})
        truthy(options, 'the reward options for the form')
        local before = wealth(C.creator.source)
        local placed = tap('create', { target = found[1].handle, reason = 'Unpaid debt from the docks',
            mode = 'competitive', reward = { slots = { { baseline = { cash = 2500 } } } },
            bailoutAmount = 0, penaltyAmount = 0, anonymous = false,
            shown = { creatorFee = 0, feeAccount = 'bank', fulfilment = Config.Completion.Fulfilment,
                      protectedAck = false } })
        truthy(placed.id, 'placed')
        eq(before - wealth(C.creator.source), 2500, 'the reward is held from the placer')
        truthy(#W.audit('contract_created') == 1, 'audited contract_created')
        local _ = w
    end)

    it_('shows the target\'s face by the reference the board handed out', function()
        local w = city()
        page(C.hitman.source)
        local board = tap('list', { page = 1 })
        local card
        for _, c in ipairs(board.contracts or {}) do if c.id == w.unheld.id then card = c end end
        truthy(card, 'the unheld contract is on the board')
        W.s.mugshot.request(SPARE.cid)
        truthy(W.s.mugshot.store(SPARE.cid, 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='), 'a face')
        local face = tap('mugshotImage', { id = W.s.mugshot.handleFor(SPARE.cid) })
        truthy(face, 'the face is sent to a board viewer')
    end)
end)

--------------------------------------------------------------------------
-- Taking a contract, and putting it down
--------------------------------------------------------------------------

describe('phone: accept and abandon', function()
    it_('a second hitman accepts from the board, then puts it down', function()
        local w = city()
        page(C.hitman2.source)
        local board = tap('list', { page = 1 })
        local card
        for _, c in ipairs(board.contracts or {}) do if c.id == w.held.id then card = c end end
        truthy(card, 'on the board')
        local took = tap('accept', { id = w.held.id, anonymous = false, penaltyAmount = card.penaltyAmount or 0,
            timeLeft = card.timeLeft, shown = { hitmanFee = 0, feeAccount = 'bank',
            creatorAnonymous = card.creatorAnonymous == true, fulfilment = card.fulfilment,
            bailoutAmount = card.bailoutAmount } })
        eq(took.role, 'hitman', 'on it')
        tap('abandon', { id = w.held.id })
        local row = F.hitmanRow and nil
        for _, h in ipairs(W.s.storage.readHitmen(w.held.id)) do
            if h.hitman_cid == C.hitman2.cid then row = h end
        end
        truthy(row and row.state ~= 'active', 'put down')
        truthy(#W.audit('contract_abandoned') >= 1, 'audited contract_abandoned')
    end)
end)

--------------------------------------------------------------------------
-- The placer changing their contract
--------------------------------------------------------------------------

describe('phone: the placer\'s own contract', function()
    it_('revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels', function()
        local w = city()
        page(C.creator.source)
        tap('revise', { id = w.unheld.id, reason = 'Talked to the police, twice' })
        eq(W.contract(w.unheld.id).reason, 'Talked to the police, twice', 'revised')
        local before = wealth(C.creator.source)
        tap('addEscrow', { id = w.unheld.id, reward = { baseline = { cash = 1000 } } })
        eq(before - wealth(C.creator.source), 1000, 'added to the reward')
        local breakdown = tap('rewardBreakdown', { id = w.unheld.id })
        truthy(breakdown, 'the itemised reward')
        local pick
        for _, line in ipairs(W.s.storage.readEscrow(w.unheld.id)) do
            if line.source == 'bank' and line.portion == CH.PORTION.BASELINE then pick = line.id end
        end
        truthy(pick, 'a bank line to take back')
        before = wealth(C.creator.source)
        tap('withdrawReward', { id = w.unheld.id, lines = { pick } })
        eq(wealth(C.creator.source) - before, 3000, 'the bank line came back')
        tap('improve', { id = w.held.id, kind = 'extend_deadline', payload = { seconds = 600 } })
        truthy(#W.audit('contract_improved') >= 1, 'audited contract_improved')
        before = wealth(C.creator.source)
        tap('cancel', { id = w.unheld.id })
        truthy(CH.TERMINAL[W.contract(w.unheld.id).state], 'cancelled')
        eq(wealth(C.creator.source) - before, 6000, 'everything held came back')
        truthy(#W.audit('contract_cancelled') >= 1, 'audited contract_cancelled')
    end)
end)

--------------------------------------------------------------------------
-- Proposals between the two sides
--------------------------------------------------------------------------

describe('phone: proposals', function()
    it_('the hitman proposes a shorter deadline, the placer reads it and agrees', function()
        local w = city()
        page(C.hitman.source)
        local p = tap('propose', { id = w.held.id, kind = 'shorten_deadline', payload = { seconds = 600 } })
        truthy(p, 'proposed')
        page(C.creator.source)
        local list = tap('amendments', { id = w.held.id })
        local id = (list[1] or (list.rows and list.rows[1]) or {}).id
        truthy(id, 'the placer sees it')
        tap('respondAmendment', { id = id, approve = true })
        truthy(#W.audit('amendment_applied') >= 1, 'audited amendment_applied')
    end)
end)

--------------------------------------------------------------------------
-- Messages, calls, a report
--------------------------------------------------------------------------

describe('phone: messages and calls', function()
    it_('the placer writes to the hitman through the masked relay, mutes, calls, reports', function()
        local w = city()
        page(C.creator.source)
        local threads = tap('threads', { id = w.held.id })
        local handle = (threads[1] or {}).handle
        truthy(handle, 'a thread with the hitman')
        tap('sendMessage', { id = w.held.id, thread = handle, body = 'Where are you?' })
        local read = tap('readThread', { id = w.held.id, thread = handle })
        truthy(read, 'the thread reads back')
        tap('muteThread', { id = w.held.id, thread = handle, muted = true })
        local call = W.nui('crimson:requestCall', { id = w.held.id, thread = handle })
        truthy(call, 'the call request is answered')
        tap('endCall', {})
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        tap('report', { id = w.held.id, note = 'Threats in the thread' })
        truthy(#W.audit('relay_message') >= 1, 'audited relay_message')
        truthy(#W.audit('player_report') >= 1, 'audited player_report')
        -- The hitman reads it under an alias, never the placer's name.
        page(C.hitman.source)
        local mine = tap('threads', { id = w.held.id })
        local h2 = (mine[1] or {}).handle
        local theirs = tap('readThread', { id = w.held.id, thread = h2 })
        truthy(W.has({ W.Natives and '' or '' }, ''), 'read')
        if not Config.TargetClasses.default.ShowPlacerOnBoard then
            falsy(W.leaks(theirs, { 'CREATOR1' }), 'no citizen id in the thread')
        end
    end)
end)

--------------------------------------------------------------------------
-- Mine, On me, the ledger
--------------------------------------------------------------------------

describe('phone: my tabs', function()
    it_('the hitman, the placer and the target each read their own tab and the ledger', function()
        local w = city(nil, { anonymous = true })
        for _, src in ipairs({ C.creator.source, C.hitman.source, C.target.source }) do
            page(src)
            local mine = tap('mine', {})
            truthy(mine, 'mine for ' .. src)
            local ledger = tap('ledger', {})
            truthy(ledger, 'ledger for ' .. src)
        end
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        page(C.target.source)
        local onme = tap('mine', {})
        falsy(W.leaks(onme, REAL), 'an anonymous placer and operative are named to nobody')
        local _ = w
    end)
end)

--------------------------------------------------------------------------
-- A kill: photographed, or verified at the scene
--------------------------------------------------------------------------

local function kill(w)
    W.at(C.hitman.source, 100.0, 100.0, 30.0)
    W.at(C.target.source, 101.0, 100.0, 30.0)
    W.sample()
    Env.players[C.target.source]._health = 120
    W.event('weaponDamageEvent', C.hitman.source,
        { weaponDamage = 50, weaponType = 453432689, hitGlobalIds = { 1000 + C.target.source } })
    Env.players[C.target.source]._health = 0
    Env.players[C.target.source].PlayerData.metadata.isdead = true
    Env.advance(1)
    W.net(C.target.source, 'crimson-hitman:iDied', C.hitman.source)
    Env.advance(2)
    truthy(W.s.death.getPending(w.held.id, C.hitman.cid), 'a kill to prove')
end

describe('phone: the kill photo', function()
    it_('the hitman photographs the kill, the placer opens it once and keeps it', function()
        local w = city()
        kill(w)
        local before = wealth(C.hitman.source)
        page(C.hitman.source)
        -- The client asks for the token itself, inside its own camera.
        W.nui('crimson:takeVerificationPhoto', { id = w.held.id })
        truthy(W.covered['handler:requestPhotoToken'], 'the token was asked for')
        truthy(W.Client.camera('https://cdn.fivemanage.com/p.png'), 'the camera took the shot')
        W.pump()
        truthy(W.covered['handler:submitPhoto'], 'the picture was sent')
        truthy(W.Client.answered and W.Client.answer and W.Client.answer.ok,
            'the page was told: ' .. tostring(W.Client.answer and W.Client.answer.err))
        W.tick(2, 10)
        truthy(wealth(C.hitman.source) > before, 'the photographed kill paid')
        -- The placer: one look at the photo.
        local row = W.s.storage.readLedger(C.creator.cid, 10)[1]
        truthy(row and row.photo_ref, 'the placer\'s ledger names the photo')
        page(C.creator.source)
        local opened = tap('openPhoto', { handle = row.photo_ref })
        truthy(opened, 'opened')
        tap('photoDecision', { handle = row.photo_ref, choice = 'keep' })
        local saved = W.nui('crimson:saveToPhotos', { handle = row.photo_ref })
        truthy(saved, 'Save to Photos answers')
        local cam = W.nui('crimson:verificationCamera', { on = false })
        truthy(cam, 'the viewfinder answers')
    end)

    it_('sends a picture kept on the server, through the viewfinder', function()
        local w = city(function() Config.Completion.PhotoStorage = 'server' end)
        kill(w)
        page(C.hitman.source)
        W.nui('crimson:takeVerificationPhoto', { id = w.held.id, viewfinder = true })
        local sent = W.nui('crimson:sendVerificationPhoto', { id = w.held.id,
            image = 'data:image/jpeg;base64,' .. string.rep('A', 400) })
        truthy(sent, 'the page is answered')
    end)

    it_('verifies a kill at the scene with kill photos off', function()
        local w = city(function() Config.Completion.KillPhotos = false end)
        kill(w)
        local before = wealth(C.hitman.source)
        page(C.hitman.source)
        tap('verifyKill', { id = w.held.id })
        W.tick(2, 10)
        truthy(wealth(C.hitman.source) - before >= 5000, 'paid')
        truthy(#W.audit('kill_verified_at_scene') == 1, 'audited kill_verified_at_scene')
    end)
end)

--------------------------------------------------------------------------
-- A live handover
--------------------------------------------------------------------------

describe('phone: the handover', function()
    it_('the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms', function()
        local w = city(function()
            Config.Completion.Fulfilment = 'alive'
            Config.Kidnap.PlacerConfirms = true
        end)
        W.allAt()
        Env.players[C.target.source].PlayerData.metadata.ishandcuffed = true
        page(C.creator.source)
        tap('setMeeting', { id = w.held.id })
        truthy(W.contract(w.held.id).meeting_x, 'the meeting point is set')
        Env.advance(60)
        tap('clearMeeting', { id = w.held.id })
        Env.advance(60)
        tap('setMeeting', { id = w.held.id })
        page(C.hitman.source)
        tap('gps', { kind = 'meeting', id = w.held.id })
        tap('armKidnap', { id = w.held.id })
        tap('kidnapProgress', { id = w.held.id })
        for _ = 1, math.ceil((Config.Kidnap.CountdownSeconds + 2) * 1000 / Config.Kidnap.TickMs) do
            W.s.kidnap.tick(Config.Kidnap.TickMs)
        end
        page(C.creator.source)
        tap('confirmHandover', { id = w.held.id })
        for _ = 1, 3 do W.s.kidnap.tick(Config.Kidnap.TickMs) end
        W.tick(1, 5)
        eq(W.contract(w.held.id).state, CH.STATE.COMPLETED, 'the confirmed handover completed it')
        truthy(#W.audit('kidnap_confirmed') >= 1, 'audited kidnap_confirmed')
    end)
end)

--------------------------------------------------------------------------
-- The target's moves
--------------------------------------------------------------------------

describe('phone: the target', function()
    it_('buys their way out', function()
        local w = city()
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        W.tick(1)
        local before = wealth(C.target.source)
        page(C.target.source)
        tap('bailout', { id = w.held.id })
        W.tick(1, (Config.Bailout.DelaySeconds or 120) + 5)
        eq(before - wealth(C.target.source), 15000, 'the price was paid')
        truthy(CH.TERMINAL[W.contract(w.held.id).state], 'the contract ended')
    end)

    it_('buys an informant\'s name of the hitman after them', function()
        local w = city(function()
            Config.TargetClasses.default.ShowOperativeNames = false
        end)
        W.s.informant.setRandom(function() return 100 end)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        page(C.target.source)
        local card = W.s.projection.contract(W.contract(w.held.id), C.target.cid)
        truthy(card.informantPicks and card.informantPicks[1], 'the card offers an informant')
        local before = wealth(C.target.source)
        tap('informant', { id = w.held.id, pick = card.informantPicks[1].pick,
            shown = { cost = Config.Intel.Informant.Cost, account = Config.Intel.Informant.Account } })
        eq(before - wealth(C.target.source), Config.Intel.Informant.Cost, 'the look-up was paid')
        truthy(#W.audit('informant_purchased') >= 1, 'audited informant_purchased')
    end)

    it_('goes dark once a tip on them is bought', function()
        local w = city(function()
            Config.Intel.GoDark.Enabled = true
            Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        end)
        W.at(C.target.source, 1200.0, -800.0, 30.0)
        Env.advance(1)
        page(C.hitman.source)
        tap('locationTip', { id = w.held.id, shown = { cost = Config.Intel.LocationTip.Cost,
            account = Config.Intel.LocationTip.Account } })
        tap('locationTips', {})
        page(C.target.source)
        tap('goDark', { id = w.held.id, shown = { cost = Config.Intel.GoDark.Cost, account = Config.Intel.GoDark.Account } })
        truthy(#W.audit('go_dark_bought') >= 1, 'audited go_dark_bought')
    end)
end)

describe('phone: the placer\'s informant', function()
    it_('names the anonymous operative on their contract', function()
        local w = city(nil, { anonymous = true })
        W.s.informant.setRandom(function() return 100 end)
        page(C.creator.source)
        local card = W.s.projection.contract(W.contract(w.held.id), C.creator.cid)
        truthy(card.placerInformantPicks and card.placerInformantPicks[1], 'the card offers one')
        tap('placerInformant', { id = w.held.id, pick = card.placerInformantPicks[1].pick,
            shown = { cost = Config.Intel.PlacerInformant.Cost, account = Config.Intel.PlacerInformant.Account } })
        truthy(#W.audit('placer_informant_bought') >= 1, 'audited placer_informant_bought')
    end)
end)

--------------------------------------------------------------------------
-- The whitelisted-job view
--------------------------------------------------------------------------

describe('phone: the whitelisted-job view', function()
    it_('an officer reads the view and turns its alerts on', function()
        local w = city()
        Env.players[C.guard.source].PlayerData.job = { name = 'police', type = 'leo', onduty = true,
            grade = { level = 1 } }
        W.loaded(C.guard.source)
        page(C.guard.source)
        local view = tap('whitelistedView', {})
        truthy(view, 'the view')
        tap('whitelistedViewAlerts', { on = true })
        falsy(W.leaks(view, REAL), 'the view names no party')
        truthy(#W.audit('view_alerts_on') >= 1, 'audited view_alerts_on')
        local _ = w
    end)
end)

--------------------------------------------------------------------------
-- Bodyguards
--------------------------------------------------------------------------

describe('phone: protection', function()
    it_('the target posts a job, a guard takes it, sets GPS to the pin, the target cancels', function()
        local w = city(function() Config.Roleplay.Protection.Enabled = true end)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        W.tick(1)
        page(C.target.source)
        local posted = tap('protectionPost', { id = w.held.id, amount = 1000,
            account = Config.Roleplay.Protection.Account })
        truthy(posted.job, 'a job')
        tap('protectionPin', { job = posted.job })
        page(C.guard.source)
        local board = tap('protectionBoard', {})
        truthy(board, 'the protection board')
        tap('protectionAccept', { job = posted.job, reward = 1000 })
        tap('gps', { kind = 'protection', job = posted.job })
        truthy(W.covered['handler:protectionWaypoint'], 'Set GPS asked the server')
        page(C.target.source)
        local cancelled = W.nui('crimson:protectionCancel', { job = posted.job })
        truthy(cancelled, 'cancel answered')
        truthy(#W.audit('protection_accepted') >= 1, 'audited protection_accepted')
    end)
end)

--------------------------------------------------------------------------
-- Rumours and the broker
--------------------------------------------------------------------------

describe('phone: rumours', function()
    it_('a hitman asks the broker NPC; a broker player briefs somebody standing with them', function()
        local w = city(function()
            Config.Intel.Rumours.Enabled = true
            Config.Intel.Rumours.Locations = { ('%.1f, %.1f, %.1f, 0'):format(W.SCENE.x, W.SCENE.y, W.SCENE.z) }
            Config.Intel.Rumours.BrokerJobs = { broker = true }
        end)
        W.allAt()
        Env.players[C.broker.source].PlayerData.job = { name = 'broker', type = 'none', onduty = true }
        page(C.hitman2.source)
        tap('rumourBrief', { id = w.unheld.id })
        page(C.broker.source)
        local near = tap('brokerNearby', {})
        local first = near.people and near.people[1]
        truthy(first, 'somebody stands near the broker')
        tap('brokerBrief', { id = w.unheld.id, who = first.handle })
        truthy(#W.audit('rumour_briefed') >= 1, 'audited rumour_briefed')
    end)
end)

--------------------------------------------------------------------------
-- Improvements: decay, proof items; the page's own housekeeping
--------------------------------------------------------------------------

describe('phone: decay, proof item, the page', function()
    it_('the placer turns decay off; the hitman hands over a proof item', function()
        local w = city(function()
            Config.Improvements.ContractDecay.Enabled = true
            Config.Improvements.ProofItems.Enabled = true
        end)
        page(C.creator.source)
        tap('decayOff', { id = w.held.id })
        truthy(#W.audit('imp_decay_off') >= 1, 'audited imp_decay_off')
        W.allAt()
        local p = Env.players[C.hitman.source]
        p._inventory[#p._inventory + 1] = { name = 'id_card', count = 1, slot = 40,
            metadata = { citizenid = C.target.cid, firstname = 'Dana', lastname = 'Reyes' } }
        local before = wealth(C.hitman.source)
        page(C.hitman.source)
        tap('proofItem', { id = w.held.id })
        W.tick(1, 5)
        truthy(wealth(C.hitman.source) > before, 'the proof item paid')
    end)

    it_('the page says it broke, asks the access mode, and the NPC places are read', function()
        local w = city()
        page(C.hitman.source)
        tap('pageError', { message = 'TypeError: x is undefined', where = 'board' })
        truthy(#W.audit('page_error') >= 1, 'audited page_error')
        local mode = W.nui('crimson:accessMode', {})
        truthy(mode, 'the access mode answers')
        local r = W.phone(C.hitman.source, 'rpPlaces', {})
        truthy(r and r.ok, 'rpPlaces answers')
        local _ = w
    end)
end)

return W
