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
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        truthy(place(s, f))
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
