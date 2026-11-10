--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                 crimson-hitman - server/staff_reassign.lua                ║
    ║          Staff give a live contract to another hitman, from the panel     ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The admin panel's Reassign (ops reassignPreview, a read, and
--- reassignHitman, the staff ACE's: Config.Admin.Ace, as Remove operative
--- is, since it moves their stake the same way). Added through Panel.extend,
--- so each runs the panel's own gate. The page asks twice before it sends.
---
--- The hitman is named only by the handle a Players lookup gave this staff
--- member (data.ref), never a name, a player id or a typed citizen id, and
--- must be in the city: an acceptance is theirs to stake on. They have to
--- pass every check their own Accept would: the app's gate (a barred job),
--- the roleplay rules in front of Accept and the tiered board
--- (App.acceptGate), the organisation's gate, and every rule of
--- Contracts.accept (not the target, not the placer or another of their
--- characters, not the target's guard, not suspended or frozen, not barred
--- from it, their own MaxAcceptedPerHitman, a walk-away's wait, the time
--- left, anonymity allowed). The stake is waived, or charged as on Accept,
--- by Config.Staff.ReassignStake ('waive' as shipped).
---
--- Every operative on it now is taken off it exactly as Remove operative
--- takes one off (StaffContract.removeHitman: their stake to the placer as a
--- walk-away hands it over, or back to them with returnStake; barred from
--- taking it again unless block is false). All of it under the contract's
--- own key, which every acceptance holds, so nobody else takes it from the
--- board in between. Where there is room beside them (a competitive
--- contract below Config.Limits.MaxHitmenPerContract) the new hitman is
--- accepted first, so a refusal leaves everybody where they were; otherwise
--- the operatives are taken off first, and a refusal after that is said and
--- audited (staff_reassign_failed). Audited as staff_reassign_hitman with
--- the reason. The new hitman is told staff assigned them a contract, the
--- placer that staff gave it to another hitman; nobody is told who.

local Util = CrimsonBoot.requireShared('util')

local StaffReassign = {}

local deps

StaffReassign.OPS = {}

StaffReassign.ASSIGNED_TITLE = 'Contract assigned'
StaffReassign.PLACER_TITLE = 'Contract reassigned'

---@return boolean whether the stake is waived for a hitman staff assign
function StaffReassign.waived()
    return not (type(Config.Staff) == 'table' and Config.Staff.ReassignStake == 'charge')
end

--- What would refuse this hitman before anything moves, read without
--- writing: the app's gate, the rules in front of Accept, and the parts of
--- Contracts.accept that can be read now. Contracts.accept asks all of them
--- again, under the key, and is what decides.
---@return table|nil actor the hitman as the gate resolved them
---@return string|nil err
---@return table|nil data
local function eligible(subject, contract)
    local who = subject and subject.actor
    if not who or not who.source then return nil, 'hitman_away' end
    local actor, err, data = deps.identity.gate(who.source)
    if not actor then return nil, err or CH.ERR.NO_PLAYER, data end
    if actor.cid ~= subject.cid then return nil, 'hitman_away' end
    if deps.app and deps.app.acceptGate then
        local ok, gateErr, gateData = pcall(deps.app.acceptGate, actor, { id = contract.id })
        if ok and gateErr then return nil, gateErr, gateData end
    end
    local C = deps.contracts
    if C.acceptGate then
        local ran, refused, gateData = pcall(C.acceptGate, actor, contract.id, {})
        if ran and refused then return nil, refused, gateData end
    end
    if contract.target_cid == actor.cid then return nil, CH.ERR.SELF_TARGET end
    if contract.creator_cid == actor.cid then return nil, CH.ERR.SELF_ACCEPT end
    if C.guardsTarget then
        local ran, guards = pcall(C.guardsTarget, contract, actor.cid)
        if ran and guards then return nil, CH.ERR.PROTECTION_GUARDING end
    end
    if Config.AntiCollusion.BlockSameAccount
        and (deps.identity.sameAccount(contract.creator_account, actor.account)
            or deps.identity.sameAccount(contract.target_account, actor.account)) then
        return nil, CH.ERR.SAME_ACCOUNT
    end
    if C.frozenPlayer(actor.cid) then return nil, CH.ERR.CONTRACT_FROZEN end
    if C.suspension(actor.cid) then return nil, CH.ERR.SUSPENDED end
    if C.staffContract and C.staffContract.barred(contract.id, actor.cid, actor.account) then
        return nil, CH.ERR.STAFF_BARRED
    end
    local mine = deps.storage.readHitman(contract.id, actor.cid)
    if C.holds(mine) then return nil, 'already_on' end
    return actor
end

local function contractRefusal(contract)
    if not contract then return CH.ERR.NOT_FOUND end
    if CH.TERMINAL[contract.state] then return CH.ERR.ALREADY_SETTLED end
    if contract.state == CH.STATE.COMPLETING or deps.escrow.claimRunning(contract.id) then
        return 'claim_running'
    end
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then return CH.ERR.BAD_STATE end
    if contract.bailout_queued_at then return 'buyout_queued' end
    if deps.contracts.heldByStaff(contract) then return CH.ERR.CONTRACT_FROZEN end
    return nil
end

local function operatives(contractId, exceptCid)
    local out = {}
    for _, h in ipairs(deps.storage.readHitmen(contractId) or {}) do
        if h.state == 'active' and h.hitman_cid ~= exceptCid then out[#out + 1] = h end
    end
    return out
end

local function reassignUnlocked(staff, contractId, subject, opts)
    local contract = deps.storage.readContract(contractId)
    local err = contractRefusal(contract)
    if err then return false, err end
    local actor, why, data = eligible(subject, contract)
    if not actor then return false, why, data end

    local current = operatives(contractId, actor.cid)
    local room = contract.mode ~= CH.MODE.EXCLUSIVE
        and #current < (tonumber(Config.Limits.MaxHitmenPerContract) or 0)
    local acceptOpts = { staffAssigned = true, waiveStake = StaffReassign.waived() }

    local function accept()
        return deps.contracts.acceptHeld(actor, contractId, opts.anonymous == true, acceptOpts)
    end
    local removed = {}
    local function removeAll()
        for _, h in ipairs(current) do
            local ok, removeErr, detail = deps.staffContract.removeHitman(staff, contractId, h.id, opts.reason,
                { block = opts.block ~= false, returnStake = opts.returnStake == true })
            if not ok then return false, removeErr end
            removed[#removed + 1] = { cid = h.hitman_cid, alias = h.alias, stake = detail and detail.stake or 0,
                returned = detail and detail.returned or 0, forfeited = detail and detail.forfeited or 0 }
        end
        return true
    end

    local ok, acceptErr, row
    if room then
        ok, acceptErr, row = accept()
        if not ok then return false, acceptErr, row end
        local gone, removeErr = removeAll()
        if not gone then
            deps.audit.staff('staff_reassign_failed', staff.cid, contractId, { to = actor.cid,
                err = removeErr, removed = #removed, reason = opts.reason, assigned = true })
            return false, 'not_all_removed', { removed = #removed, assigned = true }
        end
    else
        local gone, removeErr = removeAll()
        if not gone then
            deps.audit.staff('staff_reassign_failed', staff.cid, contractId, { to = actor.cid,
                err = removeErr, removed = #removed, reason = opts.reason })
            return false, #removed == 0 and removeErr or 'not_all_removed', { removed = #removed }
        end
        ok, acceptErr, row = accept()
        if not ok then
            deps.audit.staff('staff_reassign_failed', staff.cid, contractId, { to = actor.cid,
                err = acceptErr, removed = #removed, reason = opts.reason })
            return false, 'not_assigned', { removed = #removed, err = acceptErr, refusal = row }
        end
    end

    local fromCids = {}
    for i, r in ipairs(removed) do fromCids[i] = r.cid end
    deps.audit.staff('staff_reassign_hitman', staff.cid, contractId, {
        to = actor.cid, alias = type(row) == 'table' and row.alias or nil, from = fromCids,
        stake = acceptOpts.waiveStake and 'waived' or 'charged', reason = opts.reason,
    })
    local target = tostring(contract.target_name or 'a target')
    deps.notify.tellOrKeep(actor.cid, StaffReassign.ASSIGNED_TITLE,
        ('Staff assigned you a contract on %s. It is under Mine.%s'):format(target,
            acceptOpts.waiveStake and ' You put no stake up for it.' or ''),
        { bypassBudget = true }, contractId)
    deps.notify.tellOrKeep(contract.creator_cid, StaffReassign.PLACER_TITLE,
        ('Staff gave your contract on %s to another hitman.'):format(target),
        { bypassBudget = true }, contractId)
    return true, nil, { alias = type(row) == 'table' and row.alias or nil, removed = removed,
        stakeWaived = acceptOpts.waiveStake }
end

--- Give a live contract to another hitman (see the top of this file).
---@param staff table { cid, name, source }
---@param contractId string
---@param subject table { cid, actor } from the panel's lookup handle
---@param opts table { reason, block, returnStake, anonymous }
function StaffReassign.reassign(staff, contractId, subject, opts)
    return deps.contracts.serialized({ 'contract:' .. contractId }, reassignUnlocked, staff, contractId,
        subject, opts or {})
end

--------------------------------------------------------------------------
-- The panel's ops
--------------------------------------------------------------------------

local MESSAGES = {
    [CH.ERR.NOT_FOUND] = 'No contract has that id.',
    [CH.ERR.ALREADY_SETTLED] = 'It has ended.',
    [CH.ERR.BAD_STATE] = 'Only a live contract (active or accepted) can be reassigned.',
    claim_running = 'A payout on it is being settled right now. Try again in a moment.',
    buyout_queued = 'Its target has paid a buyout that is waiting out its delay; that settles first.',
    [CH.ERR.BUSY] = 'Something else was changing this contract. Try again in a moment.',
    hitman_away = 'That hitman is not in the city now: they have to be, to take a contract.',
    already_on = 'That hitman is already on it.',
    [CH.ERR.SELF_TARGET] = 'That player is its target.',
    [CH.ERR.SELF_ACCEPT] = 'That player placed it.',
    [CH.ERR.SAME_ACCOUNT] = 'That player shares an account with its placer or its target.',
    [CH.ERR.PROTECTION_GUARDING] = 'That player is paid to guard its target.',
    [CH.ERR.SUSPENDED] = 'That player is suspended from contracts.',
    [CH.ERR.STAFF_BARRED] = 'Staff barred that player from this contract.',
    [CH.ERR.LIMIT_REACHED] = 'That hitman holds as many contracts as they may (Config.Limits.MaxAcceptedPerHitman).',
    [CH.ERR.INSUFFICIENT] = 'That hitman cannot cover the stake (Config.Staff.ReassignStake is charge).',
    [CH.ERR.BLACKLISTED_JOB] = 'That player\'s job is barred from the app.',
    [CH.ERR.APP_PAUSED] = 'The app is paused (Config.Staff.AppPaused).',
    [CH.ERR.ANONYMITY_OFF] = 'Accepting anonymously is off on this server.',
}

local function said(err, detail)
    local base = MESSAGES[err]
    if err == 'not_assigned' then
        local inner = detail and detail.err
        return ('%d operative(s) were taken off it, and the new hitman could not be assigned: %s '
            .. 'It is back on the board.'):format(detail and detail.removed or 0,
                MESSAGES[inner] or ('their Accept was refused (' .. tostring(inner) .. ').'))
    end
    if err == 'not_all_removed' then
        return ('Only %d operative(s) were taken off it before one could not be.%s Look at the contract.')
            :format(detail and detail.removed or 0, detail and detail.assigned and ' The new hitman is on it.' or '')
    end
    return base or ('Not reassigned: their Accept was refused (' .. tostring(err) .. ').')
end

local function staffOf(src)
    local actor = deps.identity.resolve(src)
    return { cid = actor and actor.cid or deps.panel.staffOf(src), name = actor and actor.name or nil, source = src }
end

local function subjectOf(src, data)
    if data.ref == nil then
        return nil, CH.ERR.INVALID_INPUT, 'Look the hitman up under Players first, then reassign from the lookup.'
    end
    return deps.panel.writeSubject({ ref = data.ref }, src)
end

local function frozenSaid(src, id, err)
    local contract = deps.storage.readContract(id)
    if contract and deps.panel.frozenShown and deps.panel.frozenShown(contract, deps.panel.identifies(src)) then
        return false, err, 'It is on hold by staff, and nothing on it moves: unfreeze first.'
    end
    return false, 'not_reassigned', 'Not reassigned: try again in a moment.'
end

--- { id, ref } -> who is on it now (by alias), whether the stake is waived,
--- and what would refuse the hitman named, if anything.
local function opPreview(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local contract = deps.storage.readContract(id)
    if not contract then return false, CH.ERR.NOT_FOUND, MESSAGES[CH.ERR.NOT_FOUND] end
    local view = { stakeWaived = StaffReassign.waived(), stake = contract.penalty_amount or 0, operatives = {} }
    for _, h in ipairs(operatives(id)) do view.operatives[#view.operatives + 1] = h.alias end
    local err = contractRefusal(contract)
    if err == CH.ERR.CONTRACT_FROZEN then
        local _, code, message = frozenSaid(src, id, err)
        view.refused, view.message = code, message
    elseif err then
        view.refused, view.message = err, MESSAGES[err]
    elseif data.ref ~= nil then
        local subject, subjectErr, message = subjectOf(src, data)
        if not subject then
            view.refused, view.message = subjectErr, message
        else
            local actor, why = eligible(subject, contract)
            if not actor then view.refused, view.message = why, said(why) end
        end
    end
    return true, nil, nil, view
end

--- { id, ref, reason, block (default true), returnStake, anonymous }.
local function opReassign(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local reason = type(data.reason) == 'string' and Util.sanitizeText(data.reason, 120) or nil
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end
    for _, key in ipairs({ 'block', 'returnStake', 'anonymous' }) do
        if data[key] ~= nil and type(data[key]) ~= 'boolean' then
            return false, CH.ERR.INVALID_INPUT, 'Tick or untick it.'
        end
    end
    local subject, subjectErr, message = subjectOf(src, data)
    if not subject then return false, subjectErr, message end
    local ok, err, detail = StaffReassign.reassign(staffOf(src), id, subject,
        { reason = reason, block = data.block, returnStake = data.returnStake == true,
          anonymous = data.anonymous == true })
    if not ok then
        if err == CH.ERR.CONTRACT_FROZEN then return frozenSaid(src, id, err) end
        return false, err, said(err, detail), detail
    end
    local stakes = 0
    for _, r in ipairs(detail.removed) do stakes = stakes + (r.forfeited or 0) end
    return true, nil, ('Reassigned to %s; %d operative(s) taken off it%s.%s Each was told as Remove '
        .. 'operative tells them; the placer that staff gave it to another hitman.')
        :format(tostring(detail.alias or 'the new hitman'), #detail.removed,
            stakes > 0 and (' ($%d of stakes went to the placer)'):format(stakes) or '',
            detail.stakeWaived and ' Their stake was waived.' or ' They put up the stake as on Accept.'),
        { alias = detail.alias, removed = #detail.removed, stakeWaived = detail.stakeWaived }
end

---@param d table the wired modules
function StaffReassign.register(d)
    deps = d
    if not (d.panel and d.panel.extend) then return end
    local levels = d.panel.LEVELS
    StaffReassign.OPS = { reassignPreview = levels.READ, reassignHitman = levels.WRITE }
    d.panel.extend('reassignPreview', levels.READ, opPreview)
    d.panel.extend('reassignHitman', levels.WRITE, opReassign)
end

--- Start-up check of the setting (main.lua).
---@param warn string[]
function StaffReassign.validate(warn)
    if type(Config.Staff) ~= 'table' then return end
    local value = Config.Staff.ReassignStake
    if value ~= 'waive' and value ~= 'charge' then
        warn[#warn + 1] = ('Config.Staff.ReassignStake is %s; it has to be \'waive\' or \'charge\'. Using '
            .. '\'waive\'.'):format(tostring(value))
        Config.Staff.ReassignStake = 'waive'
    end
end

return StaffReassign
