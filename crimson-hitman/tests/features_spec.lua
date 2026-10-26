--- Every feature switch, turned off and on again from the admin panel
--- (Settings.set), while the server runs.
---
--- Two things are held for each group: that the change takes effect at
--- once, without a restart, because the code reads the config when it uses
--- it (or a hook applies the change); and what happens to what was already
--- under way. The rule is the same everywhere: a contract already placed,
--- and money already owed, finish under the rules they started with; only
--- new actions are refused, and in words. No switch strands money.

local function stack()
    local s = newStack()
    local f = fixture(s)
    return s, f
end

--- Change a setting as the panel does, and insist it took.
local function turn(s, key, value)
    local ok, err, why = s.settings.set(key, value, 'ADMIN001', 'ADMIN001')
    truthy(ok, ('%s: %s %s'):format(key, tostring(err), tostring(why)))
end

local function place(s, f, opts)
    opts = opts or {}
    return s.contracts.create(f.creator, {
        targetCid = opts.target or 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 5000 } },
        bailoutAmount = opts.bailoutAmount, anonymous = opts.anonymous,
    })
end

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function told(name, target)
    local found
    for _, event in ipairs(Env.clientEvents) do
        if event.name == name and (target == nil or event.target == target) then found = event end
    end
    return found
end

--------------------------------------------------------------------------

describe('access, switched from the panel', function()
    local function withOfficer(s)
        Env.addPlayer({ source = 9, citizenid = 'OFFICER9', license = 'license:o9',
            job = { name = 'police', type = 'leo', onduty = false },
            firstname = 'Off', lastname = 'Duty' })
        s.bridges.install(s)
        s.bridges.refreshAccess()
    end

    it('shows the app to barred jobs at once when hiding it is turned off, and hides it again', function()
        local s = stack()
        -- Hiding decides only while the whitelisted-job view is off.
        Config.WhitelistedView.Enabled = false
        withOfficer(s)
        Env.clientEvents = {}
        turn(s, 'HideAppFromBlockedJobs', false)
        local shown = told('crimson-hitman:access', 9)
        truthy(shown, 'every phone is told at once, not at the next tick')
        eq(shown.args[1], true)
        eq(select(2, s.identity.gate(9)), CH.ERR.BLACKLISTED_JOB, 'and the gate still refuses them')
        Env.clientEvents = {}
        turn(s, 'HideAppFromBlockedJobs', true)
        eq(told('crimson-hitman:access', 9).args[1], false)
    end)

    it('lets an off-duty officer in when off duty stops counting', function()
        local s = stack()
        withOfficer(s)
        falsy(s.identity.gate(9), 'barred while off duty counts')
        Env.clientEvents = {}
        turn(s, 'BlockOffDuty', false)
        truthy(s.identity.gate(9), 'not any more')
        eq(told('crimson-hitman:access', 9).args[1], true, 'and their phone is told')
        turn(s, 'BlockOffDuty', true)
        falsy(s.identity.gate(9))
    end)
end)

describe('the app on the home screen, switched from the panel', function()
    it('is kept, sent to every game, and said to apply after a restart', function()
        local s = stack()
        Env.clientEvents = {}
        turn(s, 'App.DefaultInstalled', true)
        eq(Config.App.DefaultInstalled, true)
        eq(told('crimson-hitman:settings', -1).args[1]['App.DefaultInstalled'], true)
        local row
        for _, r in ipairs(s.settings.view().features) do
            if r.key == 'App.DefaultInstalled' then row = r end
        end
        eq(row.live, false, 'read when the app is added to a phone')
    end)
end)

describe('reward sources, switched from the panel', function()
    it('refuses new cash rewards while off, and still returns cash already held', function()
        local s, f = stack()
        local held = place(s, f)
        truthy(held)
        turn(s, 'Sources.cash.enabled', false)
        local refused, err = place(s, f, { target = 'HITMAN01' })
        falsy(refused, 'a new contract paying cash')
        eq(err, CH.ERR.INVALID_REWARD)
        truthy(place(s, f, { target = 'HITMAN01', reward = { baseline = { bank = 4000 } } }),
            'other sources still work')

        local before = money(1)
        truthy(s.contracts.cancel(f.creator, held.id))
        eq(money(1) - before, 5000, 'the cash placed before comes back as it went in')
        turn(s, 'Sources.cash.enabled', true)
        Config.Limits.MaxActiveContractsPerCreator = 5
        Config.Amendments.CancelCooldownSeconds = 0
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        truthy(place(s, f), 'and cash is taken again once it is on')
    end)
end)

describe('how contracts complete, switched from the panel', function()
    it('keeps a contract on the rule it was placed under', function()
        local s, f = stack()
        turn(s, 'Completion.Fulfilment', 'either')
        local before = place(s, f)
        turn(s, 'Completion.Fulfilment', 'alive')
        local after = place(s, f, { target = 'HITMAN01' })
        eq(require('crimson-hitman.shared.util').fulfilmentRule(s.storage.readContract(before.id)),
            'either', 'placed before: a kill still completes it')
        eq(require('crimson-hitman.shared.util').fulfilmentRule(s.storage.readContract(after.id)),
            'alive', 'placed after: live transfer only')
    end)

    it('takes a kill photo the way its token was issued, after the storage changes', function()
        local s, f = stack()
        local c = place(s, f, { reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        local token = s.photo.issue(f.hitman, c.id)
        truthy(token, 'a token, on a link from the image host')

        turn(s, 'Completion.PhotoStorage', 'server')
        local ok, err = s.photo.submit(f.hitman, token, 'https://cdn.fivemanage.com/proof.png')
        truthy(ok, 'the camera was already open on the old storage: ' .. tostring(err))
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
    end)
end)

describe('buyouts, switched from the panel', function()
    it('refuses new buyouts while off, and still closes one already paid', function()
        local s, f = stack()
        s.bridges.install(s)
        local c = place(s, f, { bailoutAmount = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.bailout.buy(f.target, c.id), 'paid while buyouts were on')
        truthy(s.storage.readContract(c.id).bailout_queued_at, 'and waiting out its delay')

        turn(s, 'Bailout.Enabled', false)
        local other = place(s, f, { target = 'HITMAN01', bailoutAmount = 15000 })
        eq(s.storage.readContract(other.id).bailout_amount or 0, 0,
            'a contract placed while they are off carries no buyout price')

        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        s.bailout.processQueue()
        eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT,
            'the one already paid for closes as it was promised')

        local again = place(s, f, { target = 'HITMAN01', bailoutAmount = 15000 })
        eq(select(2, s.bailout.buy(f.target, again and again.id or 'ct00000009')), CH.ERR.BAILOUT_OFF)
        Env.chat = {}
        Env.commands[Config.Bailout.Command](2, {})
        truthy(Env.chat[#Env.chat].text:find('does not offer buyouts', 1, true),
            '/cleanse says so too: ' .. tostring(Env.chat[#Env.chat].text))
    end)

    it('has /cleanse when a start had them off and the panel turns them on', function()
        local s, f = stack()
        Config.Bailout.Enabled = false
        s.bridges.install(s)
        truthy(Env.commands[Config.Bailout.Command], 'registered whatever the switch said at start')
        Config.Bailout.Enabled = true
        local c = place(s, f, { bailoutAmount = 15000 })
        -- Shown to the target once the alert's wait is over, as the app's
        -- On me tab shows it.
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.chat = {}
        Env.commands[Config.Bailout.Command](2, { c.id })
        truthy(Env.chat[#Env.chat].text:find('Paid', 1, true), tostring(Env.chat[#Env.chat].text))
    end)
end)

--- W042: the re-price after a withdrawal went through clampBailout, which
--- answers 0 while buyouts are off and reads the panel's most buyout: a
--- withdrawal made meanwhile wiped the target's way out for good, and a
--- lower "Most buyout ($)" re-priced contracts placed long before.
describe('a buyout price already set, across the switch and the limits', function()
    local function priced(s, f)
        local c = place(s, f, { reward = { baseline = { cash = 4000, bank = 2000 } },
            bailoutAmount = 15000 })
        truthy(c)
        eq(s.storage.readContract(c.id).bailout_amount, 15000)
        return c
    end

    local function withdrawBank(s, f, c)
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'bank' then
                return s.contracts.withdrawReward(f.creator, c.id, { line.id })
            end
        end
    end

    it('comes down only with the reward while buyouts are off, and is there when they are on', function()
        local s, f = stack()
        local c = priced(s, f)
        turn(s, 'Bailout.Enabled', false)
        truthy(withdrawBank(s, f, c))
        turn(s, 'Bailout.Enabled', true)
        eq(s.storage.readContract(c.id).bailout_amount,
            math.floor(4000 * Config.Bailout.MaxMultiplier),
            'lowered to what the money left buys, not wiped')
    end)

    it('is not re-priced by a lower most buyout set after it was placed', function()
        local s, f = stack()
        local c = priced(s, f)
        turn(s, 'Bailout.AbsoluteMax', 2000)
        truthy(withdrawBank(s, f, c))
        eq(s.storage.readContract(c.id).bailout_amount,
            math.floor(4000 * Config.Bailout.MaxMultiplier),
            'the panel says new contracts only')
    end)
end)

describe('proposals, switched from the panel', function()
    it('refuses new ones while off, as turned off, and still answers one already open', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local open = s.amendments.propose(f.hitman, c.id, 'shorten_deadline', { seconds = 600 })
        truthy(open, 'on the table before the switch')

        turn(s, 'Amendments.Enabled', false)
        local refused, err = s.amendments.propose(f.creator, c.id, 'shorten_deadline', { seconds = 900 })
        falsy(refused)
        eq(err, CH.ERR.FEATURE_OFF, 'said to be turned off, not "not right now"')
        local answered = s.amendments.respond(f.creator, open.id, false)
        truthy(answered, 'the open one is still answered')
        turn(s, 'Amendments.Enabled', true)
        truthy(s.amendments.propose(f.creator, c.id, 'shorten_deadline', { seconds = 900 }))
    end)
end)

describe('the informant, switched from the panel', function()
    it('refuses a purchase as turned off, and sells again once on', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        turn(s, 'Informant.Enabled', false)
        eq(select(2, s.informant.buy(f.target, c.id)), CH.ERR.FEATURE_OFF)
        turn(s, 'Informant.Enabled', true)
        local _, err = s.informant.buy(f.target, c.id)
        falsy(err == CH.ERR.FEATURE_OFF, 'on again: ' .. tostring(err))
    end)

    it('keeps showing a name already bought while it is off', function()
        local s, f = stack()
        Config.Informant.RequireProximity = false
        Config.Informant.Cost = 100
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local ok, err = s.informant.buy(f.target, c.id)
        truthy(ok, 'bought: ' .. tostring(err))
        local function shown()
            return s.projection.contract(s.storage.readContract(c.id), 'TARGET01').informantAnswer
        end
        local bought = shown()
        truthy(bought, 'shown once bought')
        turn(s, 'Informant.Enabled', false)
        eq(shown(), bought, 'paid for under the rules it was bought under, and still shown')
        eq(select(2, s.informant.buy(f.target, c.id)), CH.ERR.FEATURE_OFF, 'only a new purchase is refused')
        turn(s, 'Informant.Enabled', true)
        eq(shown(), bought)
    end)
end)

describe('messages, switched from the panel', function()
    it('keeps a thread while off, and gives it back when on', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        truthy(s.comms.send(f.creator, c.id, handle, 'before the switch'))
        turn(s, 'Relay.Enabled', false)
        eq(select(2, s.comms.send(f.creator, c.id, handle, 'during')), CH.ERR.RELAY_OFF)
        turn(s, 'Relay.Enabled', true)
        local thread = s.comms.read(f.creator, c.id, handle)
        truthy(thread, 'readable again')
        local text = {}
        for _, m in ipairs(thread.messages or thread) do text[#text + 1] = tostring(m.body) end
        truthy(table.concat(text, '|'):find('before the switch', 1, true), table.concat(text, '|'))
    end)
end)

describe('targeting, switched from the panel', function()
    it('empties the everyone-online list while browsing is off', function()
        local s, f = stack()
        turn(s, 'Targeting.AllowBrowseAll', false)
        local list = s.app.handlers.browseTargets(f.creator, { scope = 'all' })
        eq(#(list.people or {}), 0)
        turn(s, 'Targeting.AllowBrowseAll', true)
        truthy(#(s.app.handlers.browseTargets(f.creator, { scope = 'all' }).people or {}) > 0)
    end)

    it('refuses new contracts on officers, and leaves the ones already placed', function()
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'trooper', type = 'leo', onduty = true } })
        local placed = place(s, f)
        truthy(placed, 'placed while officers may be targeted')
        turn(s, 'Targeting.AllowProtectedJobTargets', false)
        Config.Limits.MaxActiveContractsPerTarget = 5
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        eq(select(2, place(s, f)), CH.ERR.TARGET_IS_LEO)
        eq(s.storage.readContract(placed.id).state, CH.STATE.ACTIVE, 'the one already placed runs on')
    end)

    it('tells every game when the nearby list or headshot backgrounds change', function()
        local s = stack()
        Env.clientEvents = {}
        turn(s, 'Targeting.AllowNearby', true)
        eq(told('crimson-hitman:settings', -1).args[1]['Targeting.AllowNearby'], true)
        turn(s, 'Mugshot.RemoveBackground', true)
        eq(told('crimson-hitman:settings', -1).args[1]['Mugshot.RemoveBackground'], true)
    end)
end)

describe('the advisory, switched from the panel', function()
    it('sends no bulletin while off, and does again once on', function()
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'trooper', type = 'leo', onduty = true } })
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
            job = { name = 'police', type = 'leo', onduty = true }, firstname = 'Ada', lastname = 'Kane' })
        local function bulletins()
            local n = 0
            for _, note in ipairs(Natives.calls.notifications) do
                if tostring(note.title):find('THREAT ADVISORY') then n = n + 1 end
            end
            return n
        end
        turn(s, 'Advisory.Enabled', false)
        truthy(place(s, f))
        eq(bulletins(), 0)
        turn(s, 'Advisory.Enabled', true)
        Config.Limits.MaxActiveContractsPerTarget = 5
        -- Another client: one live contract per player on one target.
        Env.addPlayer({ source = 21, citizenid = 'CREATOR2', license = 'license:c2',
            cash = 100000, bank = 100000, firstname = 'Ann', lastname = 'Poe' })
        truthy(place(s, { creator = s.identity.resolve(21) }))
        truthy(bulletins() > 0, 'on again')
    end)
end)

describe('notifications and progression, switched from the panel', function()
    it('stops refreshing open apps while pushes are off', function()
        local s = stack()
        turn(s, 'Notifications.PushEnabled', false)
        falsy(s.notify.push('CREATOR1', 'test'))
        turn(s, 'Notifications.PushEnabled', true)
        s.notify.clearPush('CREATOR1')
        truthy(s.notify.push('CREATOR1', 'test'))
    end)

    it('credits no trust while progression is off, and still pays the hitman', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Natives.resourceStates['sc-blackmarket'] = 'started'
        local touched = false
        local realExports = _G.exports
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                if resource ~= 'sc-blackmarket' then return realExports[resource] end
                return { AddTrust = function() touched = true end }
            end,
        })
        turn(s, 'Progression.Enabled', false)
        local ok = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        _G.exports = realExports
        truthy(ok)
        falsy(touched, 'no trust while it is off')
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and the payout is untouched')
    end)
end)

describe('anti-collusion and the audit log, switched from the panel', function()
    it('allows a contract between one account\'s characters only while the check is off', function()
        local s, f = stack()
        Env.addPlayer({ source = 11, citizenid = 'ALT00001', license = 'license:aaa',
            firstname = 'Alt', lastname = 'Ego' })
        eq(select(2, place(s, f, { target = 'ALT00001' })), CH.ERR.SAME_ACCOUNT)
        turn(s, 'AntiCollusion.BlockSameAccount', false)
        truthy(place(s, f, { target = 'ALT00001' }))
    end)

    it('keeps logging money and staff while player conduct is off', function()
        local s = stack()
        turn(s, 'Audit.LogAllActions', false)
        s.audit.action('conduct_row', 'CREATOR1', nil, {})
        s.audit.financial('money_row', 'CREATOR1', nil, {})
        s.audit.flush()
        eq(#s.storage.auditByAction('conduct_row', 5), 0)
        eq(#s.storage.auditByAction('money_row', 5), 1)
        eq(#s.storage.auditByAction('admin_setting_changed', 5), 1, 'and the switch itself')
    end)
end)

describe('limits, changed from the panel', function()
    it('never cancels what is over a lowered cap, and refuses only new ones', function()
        local s, f = stack()
        Config.Limits.MinContractReward = 0
        local first = place(s, f)
        local second = place(s, f, { target = 'HITMAN01' })
        truthy(first and second)
        turn(s, 'Limits.MaxActiveContractsPerCreator', 1)
        eq(s.storage.readContract(first.id).state, CH.STATE.ACTIVE)
        eq(s.storage.readContract(second.id).state, CH.STATE.ACTIVE)
        Env.addPlayer({ source = 12, citizenid = 'TARGET12', license = 'license:t12',
            firstname = 'New', lastname = 'Mark' })
        eq(select(2, place(s, f, { target = 'TARGET12' })), CH.ERR.LIMIT_REACHED)
        turn(s, 'Limits.MaxActiveContractsPerCreator', 3)
        truthy(place(s, f, { target = 'TARGET12' }))
    end)

    it('tells the page a new handover countdown at once', function()
        local s = stack()
        turn(s, 'Kidnap.CountdownSeconds', 45)
        eq(s.projection.listing('HITMAN01', 1).settings.kidnap.seconds, 45)
    end)

    it('refunds an anonymity fee as it was charged, whatever it was changed to meanwhile', function()
        local s, f = stack()
        turn(s, 'Anonymity.CreatorFee', 500)
        local take = s.escrow.take
        s.escrow.take = function(...)
            -- Staff change the fee while the escrow is being taken, and the
            -- take then fails: the contract is not placed.
            Config.Anonymity.CreatorFee = 900
            Config.Anonymity.FeeAccount = 'cash'
            return false, CH.ERR.INSUFFICIENT
        end
        local before = Env.players[1].PlayerData.money
        local bank, cash = before.bank, before.cash
        local placed = place(s, f, { anonymous = true })
        s.escrow.take = take
        falsy(placed)
        eq(Env.players[1].PlayerData.money.bank, bank, 'the 500 taken from the bank came back there')
        eq(Env.players[1].PlayerData.money.cash, cash, 'and nothing more, nowhere else')
    end)
end)

--------------------------------------------------------------------------
-- Kill photos and headshots, switched off
--------------------------------------------------------------------------

--- Fire a handler the way a client does and hand back the reply.
local function reply(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return { ok = false, err = 'NO REPLY' }
end

--- A contract under 'either', taken, and its target killed by the hitman,
--- who is standing over the body.
local function killedHere(s, f, opts)
    opts = opts or {}
    local c = place(s, f, opts)
    truthy(c, 'the contract has to exist')
    truthy(s.contracts.accept(f.hitman, c.id, false))
    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    return c
end

describe('Verify kill with kill photos off', function()
    it('completes the contract at the scene, on the server\'s checks alone, with no picture', function()
        local s, f = stack()
        turn(s, 'Completion.KillPhotos', false)
        local c = killedHere(s, f)
        local before = Env.players[3].PlayerData.money.cash

        local answer = reply('verifyKill', 3, { id = c.id })
        truthy(answer.ok, 'verified: ' .. tostring(answer.err))
        eq(Env.players[3].PlayerData.money.cash, before + 5000, 'the hitman is paid')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        eq(s.photo.tokenCount(), 0, 'no token was ever issued')
        eq(#s.storage.photosOf('CREATOR1'), 0, 'and no photo kept')
        falsy(s.storage.readLedger('CREATOR1', 10)[1].photo_ref)

        local ledger = reply('ledger', 1, {})
        truthy(ledger.ok)
        falsy(ledger.data.entries[1].photo, 'the client\'s ledger offers no photo')
        local said = {}
        for _, data in ipairs(Natives.calls.notifications) do
            said[#said + 1] = tostring(data.title) .. ': ' .. tostring(data.content)
        end
        local text = table.concat(said, '\n')
        truthy(text:find('Your contract was fulfilled', 1, true), text)
        falsy(text:lower():find('photo', 1, true), 'and nothing told anybody about a photo: ' .. text)
    end)

    it('holds it to the scene: too far is too far, a revive past the window undoes it', function()
        local s, f = stack()
        turn(s, 'Completion.KillPhotos', false)
        local c = killedHere(s, f)
        Env.players[3]._coords = { x = 160.0, y = 100.0, z = 30.0 }
        eq(reply('verifyKill', 3, { id = c.id }).err, CH.ERR.PHOTO_TOO_FAR)

        -- Up and about past the proof window: not an elimination.
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2].PlayerData.metadata.isdead = false
        Env.advance(Config.Completion.ProofWindowSeconds + 5)
        Env.gameTimer = (Env.gameTimer or 0) + (Config.Completion.ProofWindowSeconds + 5) * 1000
        local answer = reply('verifyKill', 3, { id = c.id })
        falsy(answer.ok, 'a kill undone is not paid')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'and the contract is still open')
    end)

    it('never completes a contract placed for a live delivery', function()
        local s, f = stack()
        turn(s, 'Completion.KillPhotos', false)
        turn(s, 'Completion.Fulfilment', 'alive')
        local c = killedHere(s, f)
        eq(reply('verifyKill', 3, { id = c.id }).err, CH.ERR.KILL_NOT_ALLOWED)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)

    it('is refused where kill photos are on, so the photo stays one of the checks', function()
        local s, f = stack()
        local c = killedHere(s, f)
        eq(reply('verifyKill', 3, { id = c.id }).err, CH.ERR.PHOTO_REQUIRED)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'nothing was paid without one')
        truthy(reply('requestPhotoToken', 3, { id = c.id }).ok, 'the camera is the way in')
    end)

    --- A contract placed before the rule existed, on a server running every
    --- switch as this resource ships them (tests/harness/shipped.lua): the
    --- one place a kill still completes a contract there.
    it('completes an older contract a kill may complete, on the switches this resource ships', function()
        local Shipped = require('crimson-hitman.tests.harness.shipped')
        local s, f = stack()
        local c = place(s, f)
        truthy(c, 'placed under either')
        truthy(s.contracts.accept(f.hitman, c.id, false))
        -- As a row an older version stored it: no rule, read as 'either'.
        s.storage.readContract(c.id).fulfilment_rule = nil
        Shipped.apply()
        eq(s.projection.accepted('HITMAN01')[1].fulfilment, 'either', 'on the terms it was taken on')

        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        local before = Env.players[3].PlayerData.money.cash
        Natives.calls.notifications = {}

        eq(reply('requestPhotoToken', 3, { id = c.id }).err, CH.ERR.PHOTO_GONE, 'no camera')
        local answer = reply('verifyKill', 3, { id = c.id })
        truthy(answer.ok, 'verified at the scene: ' .. tostring(answer.err))
        eq(Env.players[3].PlayerData.money.cash, before + 5000, 'the hitman is paid')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        eq(s.photo.tokenCount(), 0, 'no token was ever issued')
        eq(#s.storage.photosOf('CREATOR1'), 0, 'and no photo kept')
        falsy(Natives.dirs['data/photos'], 'nor a folder made for one')
        for _, entry in ipairs(reply('ledger', 1, {}).data.entries or {}) do
            falsy(entry.photo, 'the client\'s Ledger offers no photo')
        end
        local said = {}
        for _, data in ipairs(Natives.calls.notifications) do
            said[#said + 1] = tostring(data.title) .. ': ' .. tostring(data.content)
        end
        local text = table.concat(said, '\n')
        truthy(text:find('Contract fulfilled: Your contract was fulfilled.', 1, true), text)
        falsy(text:lower():find('photo', 1, true), 'and nothing told anybody about a photo: ' .. text)
    end)

    it('takes effect at the next tap, both ways, with no restart', function()
        local s, f = stack()
        local c = killedHere(s, f)
        turn(s, 'Completion.KillPhotos', false)
        eq(reply('requestPhotoToken', 3, { id = c.id }).err, CH.ERR.PHOTO_GONE)
        eq(s.projection.listing('HITMAN01', 1).settings.killPhotos, false,
            'and the page is told, so it opens no camera')
        turn(s, 'Completion.KillPhotos', true)
        truthy(reply('requestPhotoToken', 3, { id = c.id }).ok)
        eq(s.projection.listing('HITMAN01', 1).settings.killPhotos, true)
    end)
end)

describe('target headshots switched off', function()
    local VALID_IMAGE = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='

    local function asked(events, target)
        for _, event in ipairs(events or {}) do
            if event.name == 'crimson-hitman:renderMugshot'
                and (target == nil or event.target == target) then
                return true
            end
        end
        return false
    end

    it('asks no game for a render, and the board carries no face', function()
        local s, f = stack()
        turn(s, 'Mugshot.Enabled', false)
        local c = place(s, f)
        truthy(c)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.clientEvents = {}
        local board = reply('list', 3, { page = 1 })
        truthy(board.ok)
        falsy(asked(Env.clientEvents), 'no render was asked of anybody')
        for _, row in ipairs(board.data.contracts) do
            eq(row.targetImageId, nil, 'every card shows the placeholder')
        end
        -- Sanity: on again, the same look asks.
        turn(s, 'Mugshot.Enabled', true)
        Env.clientEvents = {}
        reply('list', 3, { page = 1 })
        truthy(asked(Env.clientEvents, 2), 'with them on, the target\'s game is asked')
    end)

    it('refuses a headshot sent anyway before reading it, and keeps nothing', function()
        local s = stack()
        s.bridges.install(s)
        s.mugshot.request('TARGET01')
        turn(s, 'Mugshot.Enabled', false)
        local stored, floods = 0, 0
        local realStore, realFlood = s.mugshot.store, s.app.floodOk
        s.mugshot.store = function(...) stored = stored + 1 return realStore(...) end
        s.app.floodOk = function(...) floods = floods + 1 return realFlood(...) end
        local ok, err = pcall(function()
            _G.source = 2
            Env.events['crimson-hitman:mugshot'](VALID_IMAGE)
            _G.source = nil
        end)
        _G.source = nil
        s.mugshot.store, s.app.floodOk = realStore, realFlood
        truthy(ok, tostring(err))
        eq(stored, 0, 'the picture is never handed to the store')
        eq(floods, 0, 'nor is the sender even counted')
        eq(s.mugshot.count(), 0, 'and nothing is kept')
        eq(s.mugshot.handleFor('TARGET01'), nil)
    end)

    it('forgets every headshot kept when it is turned off', function()
        local s = stack()
        s.bridges.install(s)
        s.mugshot.request('TARGET01')
        truthy(s.mugshot.store('TARGET01', VALID_IMAGE))
        local handle = s.mugshot.handleFor('TARGET01')
        truthy(handle)
        turn(s, 'Mugshot.Enabled', false)
        eq(s.mugshot.count(), 0, 'none is kept while they are off')
        eq(s.mugshot.byHandle(handle), nil, 'and a card holding the old handle gets nothing')
        eq(reply('mugshotImage', 1, { id = handle }).err, CH.ERR.NOT_FOUND)
    end)
end)

describe('kill photos off, from the first start', function()
    --- The real boot path (main.lua), as boot_spec runs it, with the photo
    --- settings given: an upload host the photos would use and a public
    --- address that would be warned about.
    --- `debug` boots with Config.Debug on, so each warning is said in full
    --- rather than counted in the start's one line.
    local function bootWith(killPhotos, debug)
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'memory'
        Config.Completion.KillPhotos = killPhotos
        Config.Completion.Fulfilment = 'either'
        Config.Completion.PhotoStorage = 'host'
        Config.Completion.ExtraPhotoHosts = {}
        Config.Completion.PhotoPublicUrl = 'not an address'
        Config.Debug = debug == true
        Env.console = {}
        local main = require('server.main')
        return main, main.start()
    end

    --- Every lookup of lb-phone's config made from the photo modules while
    --- fn runs, by the file that made it. Calls placed by the relay ask it
    --- too, for whether a call can be masked; those are not about photos.
    local function photoLookups(fn)
        local phone = exports['lb-phone']
        local realLookup, realConfig = phone.GetConfig, Natives.phoneConfig
        local from = {}
        phone.GetConfig = function(...)
            -- The whole stack, since the photo modules ask in a tail call.
            local stack = debug.traceback()
            local file = stack:match('(server/completion/photo%.lua)')
                or stack:match('(server/photos%.lua)')
            if file then from[#from + 1] = file end
            return realLookup(...)
        end
        -- An empty allow list, so the warning that every photo would be
        -- refused has something to say if anything asks.
        Natives.phoneConfig = {}
        local ok, err = pcall(fn)
        phone.GetConfig, Natives.phoneConfig = realLookup, realConfig
        truthy(ok, tostring(err))
        return from
    end

    it('asks lb-phone nothing about upload hosts: not at start, not on the tick, not in /ch-diag', function()
        local said
        local off = photoLookups(function()
            local main, modules = bootWith(false)
            fixture(modules)
            Env.advance((Config.Completion.PhotoHostRefreshSeconds or 300) + 1)
            main.tick()
            modules.admin.diagnose(0)
            modules.admin.diagnose(0, 1)
            said = table.concat(Env.console, '\n')
        end)
        eq(#off, 0, 'looked up from: ' .. table.concat(off, ', '))
        for _, word in ipairs({ 'ExtraPhotoHosts', 'PhotoPublicUrl', 'web_baseUrl', 'upload host' }) do
            falsy(said:find(word, 1, true), 'nothing at start about ' .. word .. ': ' .. said)
        end

        -- The same start with them on asks, and warns: what the spy and the
        -- console would have caught. With Config.Debug on, so the warnings
        -- are said in full rather than counted in one line.
        local onSaid
        local on = photoLookups(function()
            local main, modules = bootWith(true, true)
            fixture(modules)
            Env.advance((Config.Completion.PhotoHostRefreshSeconds or 300) + 1)
            main.tick()
            modules.admin.diagnose(0, 1)
            onSaid = table.concat(Env.console, '\n')
        end)
        truthy(#on > 0, 'with kill photos on, the photo modules ask lb-phone')
        truthy(onSaid:find('PhotoPublicUrl', 1, true), onSaid)
        truthy(onSaid:find('upload host', 1, true), onSaid)
    end)

    it('does not touch data/photos', function()
        bootWith(false)
        eq(Natives.files['data/photos/.mode'], nil, 'not even to say which mode it is')
        falsy(Natives.dirs['data/photos'])
        bootWith(true)
        truthy(Natives.files['data/photos/.mode'], 'with them on the start-up sweep marks it')
    end)

    it('says so in /ch-diag', function()
        local _, modules = bootWith(false)
        fixture(modules)
        local text = table.concat(modules.admin.diagnose(0), '\n')
        truthy(text:find('\nKill photos: off\n', 1, true), 'from the console as well: ' .. text)
        text = table.concat(modules.admin.diagnose(0, 1), '\n')
        truthy(text:find('\nKill photos: off\n', 1, true), text)
        truthy(text:find('photo settings: not used (kill photos are off)', 1, true), text)
        falsy(text:find('photo hosts:', 1, true), 'nothing about hosts nobody asks')
        local _, again = bootWith(true)
        fixture(again)
        text = table.concat(again.admin.diagnose(0, 1), '\n')
        truthy(text:find('Kill photos: on', 1, true), text)
        truthy(text:find('photo hosts:', 1, true), text)
    end)
end)
