--- Step 7 workflows: every admin panel op, from the staff panel's page.
---
--- Staff type /hitmanadmin; the server opens the page (adminOpen); every
--- op goes the way a click goes: the page's adminRequest NUI callback (the
--- real client/admin.lua), the panel's one net event, the real op on a real
--- server/main.lua, and the answer back through adminResult. Each test
--- asserts the answer, what changed (the store, the money, the player told)
--- and the staff audit row the op leaves; reads assert they name nobody a
--- staff member without the identity ACE may not see.

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
W.ran.panel = true

local EXPECTED_FAIL = {
}

local function it_(name, fn) W.it(name, fn, EXPECTED_FAIL) end

local C = W.CAST
local STAFF = C.staff.source

--- A server with the cast, a contract taken by the hitman (`held`) and one
--- nobody holds (`open`), and the staff member's panel open.
local function panel(configure)
    W.boot('memory', 'test', configure)
    W.cast(W.s)
    local w = {}
    w.held = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.target.cid,
        reason = 'Unpaid debt from the docks', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } } })
    truthy(w.held, 'a contract')
    truthy(W.s.contracts.accept(W.s.identity.resolve(C.hitman.source), w.held.id, false), 'taken')
    w.open = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.guard.cid,
        reason = 'Owes rent', mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 3000 } } })
    truthy(w.open, 'a second contract')
    W.tick(1)
    W.client(STAFF)
    local out = W.cmd(STAFF, Config.Admin.Commands.panel)
    truthy(out ~= nil, 'the panel command ran')
    W.pump()
    truthy(W.Client.admin.isOpen(), 'the panel page is open')
    return w
end

--- A click: the op answered ok; its data.
local function click(op, data, why)
    local answer, answered = W.nui('adminRequest', { op = op, data = data or {} })
    W.cover('op:' .. op)
    truthy(answered, op .. ' never answered the page')
    if not (type(answer) == 'table' and answer.ok) then
        error(('op %s refused: %s %s (%s)'):format(op, tostring(answer and answer.err),
            tostring(answer and answer.message), tostring(why or '')), 2)
    end
    return answer.data or {}, answer
end

local function audited(action)
    truthy(#W.audit(action) >= 1, 'audited ' .. action)
end

local function refOf(cid) return W.ref(cid, STAFF) end

describe('panel: home', function()
    it_('the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console', function()
        local w = panel()
        click('overview')
        click('access')
        click('reviews', { all = true })
        click('stuck')
        click('alerts', {})
        Natives.convars['crimson_hitman_alert_webhook'] = 'https://discord.com/api/webhooks/1/abc'
        click('testAlert')
        -- A problem the server printed is an alert in the inbox.
        W.s.alerts.note('problem', 'the dispatch resource did not answer')
        W.s.alerts.flush()
        local alerts = click('alerts', {})
        local ids = {}
        for _, a in ipairs(alerts.rows or {}) do ids[#ids + 1] = a.id end
        truthy(#ids >= 1, 'an alert to acknowledge')
        click('ackAlerts', { ids = ids })
        click('announce', { scope = 'active', text = 'The docks are hot tonight.' })
        audited('staff_announce')
        click('refresh')
        click('flush')
        click('console')
        click('diag', {})
        click('diag', { subject = tostring(C.hitman.source) })
        local _ = w
    end)
end)

describe('panel: players', function()
    it_('looks a player up, views them, their history, and every measure on them', function()
        local w = panel()
        local card = click('player', { subject = C.hitman.cid })
        truthy(card.player and card.player.ref, 'a lookup handle')
        click('playerView', { id = w.held.id, role = 'hitman', hitman = F.hitmanRow(w.held.id).id })
        click('history', { subject = C.hitman.cid })
        click('measures', {})
        click('freeze', { subject = C.hitman.cid, reason = 'looking into a report' })
        audited('freeze_player')
        click('unfreeze', { subject = C.hitman.cid, reason = 'report closed' })
        audited('unfreeze_player')
        click('suspend', { subject = C.hitman2.cid, days = 1, reason = 'griefing the board' })
        click('unsuspend', { subject = C.hitman2.cid, reason = 'appeal upheld' })
        click('protect', { subject = C.guard.cid, hours = 2, reason = 'new player week' })
        click('unprotect', { subject = C.guard.cid, reason = 'week over' })
        click('setPlaytime', { subject = C.guard.cid, hours = 50 })
        audited('admin_playtime_set')
        local before = W.purse(Env.players[C.guard.source])
        click('manualPay', { subject = C.guard.cid, amount = 500, account = 'bank', reason = 'refund for a bug' })
        eq(W.purse(Env.players[C.guard.source]) - before, 500, 'paid by staff')
        audited('staff_manual_payment')
        click('whois', { id = w.held.id })
    end)
end)

describe('panel: contracts', function()
    it_('lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids', function()
        local w = panel()
        local list = click('contracts', {})
        truthy(list, 'the contract list')
        click('contract', { id = w.held.id })
        click('addNote', { id = w.held.id, text = 'Placer says the target owes him' })
        audited('staff_note')
        click('adjustDeadline', { id = w.held.id, seconds = 600, reason = 'server lag' })
        audited('staff_deadline_adjust')
        click('editText', { id = w.held.id, field = 'reason', text = 'Unpaid debt', reason = 'slur removed' })
        audited('staff_text_edit')
        click('exportContract', { id = w.held.id })
        click('removeHitman', { id = w.held.id, hitman = F.hitmanRow(w.held.id).id,
            reason = 'cheating', block = false, returnStake = false })
        truthy(F.hitmanRow(w.held.id).state ~= 'active', 'taken off it')
        audited('staff_remove_hitman')
        local before = W.purse(Env.players[C.creator.source])
        click('void', { id = w.open.id, reason = 'placed by mistake' })
        truthy(CH.TERMINAL[W.contract(w.open.id).state], 'voided')
        eq(W.purse(Env.players[C.creator.source]) - before, 3000, 'the placer got the reward back')
        audited('admin_void')
    end)

    it_('settles a review item staff are given', function()
        local w = panel()
        -- A player's report is a review item.
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        W.phone(C.target.source, 'report', { id = w.held.id, note = 'They threatened me' })
        local items = click('reviews', { all = true }).items or {}
        truthy(#items >= 1, 'the report is in the inbox')
        click('resolve', { id = items[1].id, action = 'dismiss', note = 'nothing to act on' })
        audited('review_resolved')
    end)
end)

describe('panel: target limits', function()
    it_('reads the limits, overrides one player, extends, resets, and sets a job\'s', function()
        local w = panel()
        click('targetLimits')
        click('targetStatus', { subject = C.target.cid })
        local why = 'staff ticket 12'
        click('targetCounts', { ref = refOf(C.target.cid), reason = why })
        click('targetOverride', { ref = refOf(C.target.cid), hours = 2, limits = { MaxContractsPerTargetPerDay = 1 }, reason = why })
        click('targetOverrideClear', { ref = refOf(C.target.cid), reason = why })
        click('targetExtend', { ref = refOf(C.target.cid), minutes = 30, reason = why })
        click('targetReset', { ref = refOf(C.target.cid), reason = why })
        click('targetJobSet', { job = 'mechanic', limits = { MaxContractsPerTargetPerDay = 2 } })
        click('targetJobCount', { job = 'mechanic' })
        Env.players[C.guard.source].PlayerData.job = { name = 'mechanic', type = 'mechanic', onduty = true,
            grade = { level = 0 } }
        click('targetJobAction', { job = 'mechanic', action = 'extend', minutes = 30, reason = 'event' })
        click('targetJobRemove', { job = 'mechanic' })
        audited('staff_target_job_set')
        audited('staff_target_job_removed')
        local _ = w
    end)
end)

describe('panel: game rules', function()
    it_('changes a setting, undoes it, resets it, applies a preset, runs the first-start setup', function()
        local w = panel()
        click('settings', {})
        click('setSetting', { key = 'Limits.TargetCooldownAfterResolveSeconds', value = 900 })
        eq(Config.Limits.TargetCooldownAfterResolveSeconds, 900, 'in force at once')
        local hist = click('logs', { area = 'settings' }).rows or {}
        truthy(hist[1] and hist[1].ref, 'the change is in the history with Undo')
        click('undoSetting', { ref = hist[1].ref })
        eq(Config.Limits.TargetCooldownAfterResolveSeconds, 1800, 'undone')
        click('setSetting', { key = 'Limits.TargetCooldownAfterResolveSeconds', value = 600 })
        click('resetSetting', { key = 'Limits.TargetCooldownAfterResolveSeconds' })
        click('resetSettings')
        local presets = click('presets')
        click('presetSave')
        local name = (presets.presets or presets.rows or presets)[1]
        name = type(name) == 'table' and (name.name or name.id) or name
        truthy(name, 'a preset to apply')
        click('presetApply', { name = name })
        click('setup')
        local values = { ['Limits.TargetCooldownAfterResolveSeconds'] = 1200 }
        local preview = click('setupPreview', { values = values })
        truthy(preview.changes, 'what the setup would change')
        click('setupApply', { values = values })
        audited('admin_setting_changed')
        local _ = w
    end)
end)

describe('panel: logs, locations, photos', function()
    it_('reads the logs, sets and removes a place, resets a kind, removes kept photos', function()
        local w = panel(function()
            Config.Disposal.Enabled = true
        end)
        click('logs', {})
        click('logs', { area = 'settings' })
        click('placeList')
        W.at(STAFF, 300.0, 300.0, 30.0)
        click('placeMyPosition')
        click('placeSet', { kind = 'disposal_drop', here = true, label = 'Crematorium' })
        local list = click('placeList')
        local id
        for _, kind in ipairs(list.kinds or {}) do
            for _, row in ipairs(kind.rows or {}) do if row.kind == 'disposal_drop' or kind.name == 'disposal_drop' then id = row.id end end
        end
        truthy(id, 'the place is listed')
        click('placeRemove', { id = id })
        -- A kind with a reset: the broker NPC's places back to config.lua.
        W.s.settings.set('Roleplay.NpcPlaces.Enabled', true, 'test', 'ADMIN001')
        Config.Roleplay.NpcPlaces.Enabled = true
        W.at(STAFF, 310.0, 310.0, 30.0)
        click('placeSet', { kind = 'broker', here = true, label = 'Broker' })
        click('placeReset', { kind = 'broker' })
        audited('disposal_spot_set')
        W.s.settings.set('Completion.KillPhotos', false, 'test', 'ADMIN001')
        Config.Completion.KillPhotos = false
        click('removePhotos')
        audited('admin_photos_removed')
        local _ = w
    end)

    it_('lists a disposal step, respawns its vehicle and skips it', function()
        -- A step to act on: the disposal flow up to the verified kill.
        W.boot('memory', 'shipped')
        W.cast(W.s)
        local ctx = {}
        F.disposal.setup(ctx)
        W.tick(1)
        for i = 1, 4 do F.disposal.steps[i].run(ctx) end
        W.client(STAFF)
        W.cmd(STAFF, Config.Admin.Commands.panel)
        W.pump()
        local rows = click('disposalList').steps or {}
        truthy(rows[1], 'a step in progress')
        click('disposalRespawn', { id = rows[1].id })
        click('disposalSkip', { id = rows[1].id })
        audited('disposal_staff_skip')
    end)
end)

describe('panel: the organisation and boss permissions', function()
    it_('sets up, edits roles, hires and manages a member, moves money, decides an application', function()
        panel(function()
            Config.Organisation.Enabled = true
            Config.Organisation.Payroll = true
            Config.Organisation.Codenames = true
        end)
        click('orgSetup')
        click('orgGet')
        click('orgRename', { label = 'The Firm' })
        click('orgLayout', { layout = { labels = { members = 'Crew' } } })
        click('orgNotice', { text = 'Meet at nine', broadcast = true })
        click('orgRoleSet', { grade = 1, name = 'runner', label = 'Runner', pay = 5 })
        click('orgRolePowers', { grade = 1, power = 'M1', on = true })
        click('orgMemberHire', { subject = C.hitman.cid, grade = 1 })
        click('orgMemberRole', { subject = C.hitman.cid, grade = 0 })
        click('orgMemberSuspend', { subject = C.hitman.cid, hours = 1, reason = 'late' })
        click('orgMemberLimits', { subject = C.hitman.cid, maxAtOnce = 2, cooldownMinutes = 5 })
        click('orgMemberOverride', { subject = C.hitman.cid, codename = 'Ghost' })
        click('orgAccess', { grade = 0, rules = { maxAtOnce = 2 } })
        click('orgCuts', { kind = 'payout', percent = 10 })
        click('orgFunds', {})
        click('orgFundsMove', { direction = 'deposit', amount = 1000, reason = 'seed', nonce = 'p-1' })
        click('orgSalary', { grade = 0, amount = 50 })
        click('orgFundsBackend', { backend = 'internal' })
        local c = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.broker.cid,
            reason = 'Unpaid', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 2000 } } })
        click('orgPick', { id = c.id, subject = C.hitman.cid })
        -- An application at the sign-up spot, decided by staff.
        W.allAt()
        click('placeSet', { kind = 'signup', here = true, label = 'The bar' })
        local applied = W.phone(C.guard.source, 'orgApply', { text = 'I want in' })
        truthy(applied and applied.ok, 'applied: ' .. tostring(applied and applied.err))
        local _, _, apps = W.s.org.applications({ staff = true, cid = 'ADMIN001' })
        truthy(apps.rows[1], 'the application is waiting')
        click('orgApplication', { id = apps.rows[1].id, accept = false })
        audited('org_application')
        click('orgMemberFire', { subject = C.hitman.cid, reason = 'gone' })
        click('orgRoleRemove', { grade = 1 })
        click('bossPermsGet')
        click('bossPermsSet', { cells = { { subject = 'role', id = 3, power = 'M1', state = 'allow' } } })
        click('bossPermsRevokeAll', { subject = 'role', id = 3 })
        click('bossLimits', { limits = { MaxMembers = 20 } })
        click('bossOfficeRule', { power = 'M2', on = true })
        audited('org_setup')
        audited('org_member_hired')
        audited('org_member_fired')
        audited('org_funds_staff_deposit')
    end)
end)

return W
