CrimsonBoot.define('server.staff_reassign', function() --[[
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
--- by Config.Staff.ReassignStake ('waive' as shipped). They go on it
--- anonymously, never charged the anonymity fee, unless staff choose
--- 'named' or 'carry' (what they chose on their own earlier stint on it);
--- named only where the server has turned a hitman's anonymity off.
---
--- Every operative on it now is taken off it exactly as Remove operative
--- takes one off (StaffContract.removeHitman: their stake to the placer as a
--- walk-away hands it over, or back to them with returnStake; barred from
--- taking it again unless block is false). All of it under the contract's
--- own key, which every acceptance holds, so nobody else takes it from the
--- board in between. Where there is room beside them (a competitive
--- contract below Config.Limits.MaxHitmenPerContract) the new hitman is
--- accepted first, so a refusal leaves everybody where they were; otherwise
--- every check of the acceptance is run first with nothing written (the
--- money, the limits, the anonymity, a walk-away's wait: Contracts
--- .acceptHeld with dryRun, as the preview runs it), then the operatives are
--- taken off with their stakes held back, and the acceptance made. One
--- refused after all (a balance or a limit that moved in between) puts every
--- operative back on it with their stake and lifts the bar this set
--- (Contracts.reinstateHitman, StaffContract.liftRemoval); one that stands
--- hands each stake over as the removal chose. Either is audited
--- (staff_reassign_failed with what was put back). Audited as staff_reassign_hitman with
--- the reason. The new hitman is told staff assigned them a contract, the
--- placer that staff gave it to another hitman; nobody is told who.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local L = CrimsonBoot.requireShared('locale').t

local StaffReassign = {}

local deps

StaffReassign.OPS = {}

StaffReassign.ASSIGNED_TITLE = L('staff_reassign.contract_assigned')
StaffReassign.PLACER_TITLE = L('staff_reassign.contract_reassigned')
StaffReassign.REINSTATED_TITLE = L('staff_reassign.back_on_the_contract')

--- How the new hitman goes on it (opReassign's `identity`).
StaffReassign.IDENTITIES = { anonymous = true, named = true, carry = true }

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
    if Holds.of(actor.cid) then return nil, CH.ERR.CONTRACT_FROZEN end
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
    if Holds.on(contract, nil, 'staff') then return CH.ERR.CONTRACT_FROZEN end
    return nil
end

local function operatives(contractId, exceptCid)
    local out = {}
    for _, h in ipairs(deps.storage.readHitmen(contractId) or {}) do
        if h.state == 'active' and h.hitman_cid ~= exceptCid then out[#out + 1] = h end
    end
    return out
end

--- Whether the new hitman goes on it anonymously (opts.identity):
--- 'anonymous' (the default) unless the server has turned a hitman's
--- anonymity off on this contract (then named, as any hitman would be);
--- 'named' when staff chose it; 'carry' what this hitman chose on their own
--- earlier stint on this contract, or anonymous with none. Never named to
--- the placer by default: staff choosing for them is not their choice.
---@return boolean anonymous
local function anonymousFor(contract, actor, identity)
    if identity == 'named' then return false end
    if not Util.targetRule('AllowAnonymousHitman', contract.target_protected == true) then return false end
    if identity == 'carry' then
        local previous = deps.storage.readHitman(contract.id, actor.cid)
        if previous and previous.state ~= 'refused' then return previous.anon == true end
    end
    return true
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
    local anonymous = anonymousFor(contract, actor, opts.identity)
    local acceptOpts = { staffAssigned = true, waiveStake = StaffReassign.waived(), waiveFee = true }

    local function accept()
        return deps.contracts.acceptHeld(actor, contractId, anonymous, acceptOpts)
    end

    -- Every check of the acceptance first, the money, the limits, the
    -- anonymity and a walk-away's wait among them, with the operatives about
    -- to come off counted as gone and nothing written: a refusal is said
    -- before anybody is taken off, as the preview says it.
    local vacating = {}
    for _, h in ipairs(current) do vacating[h.id] = true end
    local dry, dryErr, dryData = deps.contracts.acceptHeld(actor, contractId, anonymous,
        { staffAssigned = true, waiveStake = acceptOpts.waiveStake, waiveFee = true,
          vacating = vacating, dryRun = true })
    if not dry then return false, dryErr, dryData end

    local removed = {}
    local function removeAll(holdStake)
        for _, h in ipairs(current) do
            local ok, removeErr, detail = deps.staffContract.removeHitman(staff, contractId, h.id, opts.reason,
                { block = opts.block ~= false, returnStake = opts.returnStake == true, holdStake = holdStake })
            if not ok then return false, removeErr end
            removed[#removed + 1] = { cid = h.hitman_cid, alias = h.alias, stake = detail and detail.stake or 0,
                returned = detail and detail.returned or 0, forfeited = detail and detail.forfeited or 0,
                held = detail and detail.held or nil, record = detail and detail.record,
                hitmanId = h.id }
        end
        return true
    end

    --- The stakes a removal held back for the acceptance, handed over as
    --- each removal chose, now that it stands.
    local function settleHeld()
        local now = deps.storage.readContract(contractId) or contract
        for _, r in ipairs(removed) do
            if r.held then
                local moved, returned = deps.contracts.settleWalkedStake(now, r.cid, r.held,
                    { staff = true, returnStake = opts.returnStake == true })
                r.forfeited = moved > 0 and r.held or 0
                r.returned = returned > 0 and r.held or 0
                r.held = nil
            end
        end
    end

    --- The acceptance was refused after all: every operative this took off
    --- is put back on it with their stake, and the bar this set lifted.
    local function rollBack()
        local back = 0
        for _, r in ipairs(removed) do
            if deps.contracts.reinstateHitman(contractId, r.hitmanId) then
                back = back + 1
                if r.record then deps.staffContract.liftRemoval(contractId, r.record) end
                deps.notify.tellOrKeep(r.cid, StaffReassign.REINSTATED_TITLE,
                    L('staff_reassign.staff_put_you_back_on_a'),
                    { bypassBudget = true }, contractId)
            elseif r.held then
                -- Not put back (it ended meanwhile, or the row moved): the
                -- stake goes as the removal chose.
                local now = deps.storage.readContract(contractId) or contract
                if not CH.TERMINAL[now.state] then
                    deps.contracts.settleWalkedStake(now, r.cid, r.held,
                        { staff = true, returnStake = opts.returnStake == true })
                end
            end
        end
        return back
    end

    local ok, acceptErr, row
    if room then
        ok, acceptErr, row = accept()
        if not ok then return false, acceptErr, row end
        local gone, removeErr = removeAll(false)
        if not gone then
            deps.audit.staff('staff_reassign_failed', staff.cid, contractId, { to = actor.cid,
                err = removeErr, removed = #removed, reason = opts.reason, assigned = true })
            return false, 'not_all_removed', { removed = #removed, assigned = true }
        end
    else
        local gone, removeErr = removeAll(true)
        if not gone then
            local back = rollBack()
            deps.audit.staff('staff_reassign_failed', staff.cid, contractId, { to = actor.cid,
                err = removeErr, removed = #removed, reinstated = back, reason = opts.reason })
            if back == #removed then return false, removeErr end
            return false, 'not_all_removed', { removed = #removed - back }
        end
        ok, acceptErr, row = accept()
        if not ok then
            local back = rollBack()
            deps.audit.staff('staff_reassign_failed', staff.cid, contractId, { to = actor.cid,
                err = acceptErr, removed = #removed, reinstated = back, reason = opts.reason })
            return false, 'not_assigned', { removed = #removed, reinstated = back, err = acceptErr, refusal = row }
        end
        settleHeld()
    end

    local fromCids = {}
    for i, r in ipairs(removed) do fromCids[i] = r.cid end
    local named = type(row) == 'table' and row.anon == false
    deps.audit.staff('staff_reassign_hitman', staff.cid, contractId, {
        to = actor.cid, alias = type(row) == 'table' and row.alias or nil, from = fromCids,
        stake = acceptOpts.waiveStake and 'waived' or 'charged', reason = opts.reason,
        identity = opts.identity or 'anonymous', anonymous = not named,
    })
    local target = tostring(contract.target_name or L('staff_reassign.a_target'))
    deps.notify.tellOrKeep(actor.cid, StaffReassign.ASSIGNED_TITLE,
        (L('staff_reassign.staff_assigned_you_a_contract_on')):format(target,
            acceptOpts.waiveStake and L('staff_reassign.you_put_no_stake_up_for') or '',
            named and L('staff_reassign.the_person_who_placed_it_sees')
                or L('staff_reassign.you_are_on_it_anonymously_at')),
        { bypassBudget = true }, contractId)
    deps.notify.tellOrKeep(contract.creator_cid, StaffReassign.PLACER_TITLE,
        (L('staff_reassign.staff_gave_your_contract_on_to')):format(target),
        { bypassBudget = true }, contractId)
    return true, nil, { alias = type(row) == 'table' and row.alias or nil, removed = removed,
        stakeWaived = acceptOpts.waiveStake, anonymous = not named }
end

--- Give a live contract to another hitman (see the top of this file).
---@param staff table { cid, name, source }
---@param contractId string
---@param subject table { cid, actor } from the panel's lookup handle
---@param opts table { reason, block, returnStake, identity = 'anonymous'|'named'|'carry' }
function StaffReassign.reassign(staff, contractId, subject, opts)
    return deps.contracts.serialized({ 'contract:' .. contractId }, reassignUnlocked, staff, contractId,
        subject, opts or {})
end

--------------------------------------------------------------------------
-- The panel's ops
--------------------------------------------------------------------------

local MESSAGES = {
    [CH.ERR.NOT_FOUND] = L('staff_reassign.no_contract_has_that_id'),
    [CH.ERR.ALREADY_SETTLED] = L('staff_reassign.it_has_ended'),
    [CH.ERR.BAD_STATE] = L('staff_reassign.only_a_live_contract_active_or'),
    claim_running = L('staff_reassign.a_payout_on_it_is_being'),
    buyout_queued = L('staff_reassign.its_target_has_paid_a_buyout'),
    [CH.ERR.BUSY] = L('staff_reassign.something_else_was_changing_this_contract'),
    hitman_away = L('staff_reassign.that_hitman_is_not_in_the'),
    already_on = L('staff_reassign.that_hitman_is_already_on_it'),
    [CH.ERR.SELF_TARGET] = L('staff_reassign.that_player_is_its_target'),
    [CH.ERR.SELF_ACCEPT] = L('staff_reassign.that_player_placed_it'),
    [CH.ERR.SAME_ACCOUNT] = L('staff_reassign.that_player_shares_an_account_with'),
    [CH.ERR.PROTECTION_GUARDING] = L('staff_reassign.that_player_is_paid_to_guard'),
    [CH.ERR.SUSPENDED] = L('staff_reassign.that_player_is_suspended_from_contracts'),
    [CH.ERR.STAFF_BARRED] = L('staff_reassign.staff_barred_that_player_from_this'),
    [CH.ERR.LIMIT_REACHED] = L('staff_reassign.that_hitman_holds_as_many_contracts'),
    [CH.ERR.INSUFFICIENT] = L('staff_reassign.that_hitman_cannot_cover_the_stake'),
    [CH.ERR.BLACKLISTED_JOB] = L('staff_reassign.that_players_job_is_barred_from'),
    [CH.ERR.APP_PAUSED] = L('staff_reassign.the_app_is_paused_config_holds'),
    [CH.ERR.ANONYMITY_OFF] = L('staff_reassign.accepting_anonymously_is_off_on_this'),
}

local function said(err, detail)
    local base = MESSAGES[err]
    if err == 'not_assigned' then
        local inner = detail and detail.err
        local back = detail and detail.reinstated or 0
        return (L('staff_reassign.the_new_hitman_could_not_be')):format(
            MESSAGES[inner] or (L('staff_reassign.their_accept_was_refused') .. tostring(inner) .. ').'),
            back == (detail and detail.removed or 0)
                and L('staff_reassign.everybody_taken_off_it_was_put')
                or (L('staff_reassign.of_operative_taken_off_it_could'))
                    :format((detail and detail.removed or 0) - back, detail and detail.removed or 0))
    end
    if err == 'not_all_removed' then
        return (L('staff_reassign.only_operative_were_taken_off_it'))
            :format(detail and detail.removed or 0, detail and detail.assigned and L('staff_reassign.the_new_hitman_is_on_it') or '')
    end
    return base or (L('staff_reassign.not_reassigned_their_accept_was_refused') .. tostring(err) .. ').')
end

local function subjectOf(src, data)
    if data.ref == nil then
        return nil, CH.ERR.INVALID_INPUT, L('staff_reassign.look_the_hitman_up_under_players')
    end
    return deps.panel.writeSubject({ ref = data.ref }, src)
end

local function frozenSaid(src, id, err)
    local contract = deps.storage.readContract(id)
    if contract and Holds.shown(contract, nil, deps.panel.identifies(src)) then
        return false, err, L('staff_reassign.it_is_on_hold_by_staff')
    end
    return false, 'not_reassigned', L('staff_reassign.not_reassigned_try_again_in_a')
end

--- { id, ref } -> who is on it now (by alias), whether the stake is waived,
--- and what would refuse the hitman named, if anything.
local function opPreview(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('staff_reassign.give_a_contract_id') end
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
            if not actor then
                view.refused, view.message = why, said(why)
            else
                -- And every check of the acceptance itself, as the
                -- reassignment asks it before it takes anybody off: the
                -- same refusals, nothing written.
                local vacating = {}
                for _, h in ipairs(operatives(id, actor.cid)) do vacating[h.id] = true end
                local identity = StaffReassign.IDENTITIES[data.identity] and data.identity or nil
                local anonymous = anonymousFor(contract, actor, identity)
                view.anonymous = anonymous
                local ok, acceptErr = deps.contracts.acceptHeld(actor, id, anonymous,
                    { staffAssigned = true, waiveStake = StaffReassign.waived(), waiveFee = true,
                      vacating = vacating, dryRun = true })
                if not ok then
                    if acceptErr == CH.ERR.CONTRACT_FROZEN then
                        local _, code, frozenMessage = frozenSaid(src, id, acceptErr)
                        view.refused, view.message = code, frozenMessage
                    else
                        view.refused, view.message = acceptErr, said(acceptErr)
                    end
                end
            end
        end
    end
    return true, nil, nil, view
end

--- { id, ref, reason, block (default true), returnStake, anonymous }.
local function opReassign(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('staff_reassign.give_a_contract_id') end
    local reason = type(data.reason) == 'string' and Util.sanitizeText(data.reason, 120) or nil
    if not reason then return false, CH.ERR.INVALID_INPUT, L('staff_reassign.give_a_reason_it_goes_on') end
    for _, key in ipairs({ 'block', 'returnStake', 'anonymous' }) do
        if data[key] ~= nil and type(data[key]) ~= 'boolean' then
            return false, CH.ERR.INVALID_INPUT, L('staff_reassign.tick_or_untick_it')
        end
    end
    -- How the new hitman goes on it: 'anonymous' (the default), 'named' or
    -- 'carry'. The old boolean `anonymous = false` still reads as named.
    local identity = data.identity
    if identity == nil then identity = data.anonymous == false and 'named' or 'anonymous' end
    if not StaffReassign.IDENTITIES[identity] then
        return false, CH.ERR.INVALID_INPUT, L('staff_reassign.choose_anonymous_named_or_as_they')
    end
    local subject, subjectErr, message = subjectOf(src, data)
    if not subject then return false, subjectErr, message end
    local ok, err, detail = StaffReassign.reassign(deps.panel.staffActor(src), id, subject,
        { reason = reason, block = data.block, returnStake = data.returnStake == true,
          identity = identity })
    if not ok then
        if err == CH.ERR.CONTRACT_FROZEN then return frozenSaid(src, id, err) end
        return false, err, said(err, detail), detail
    end
    local stakes = 0
    for _, r in ipairs(detail.removed) do stakes = stakes + (r.forfeited or 0) end
    return true, nil, (L('staff_reassign.reassigned_to_operative_taken_off_it'))
        :format(tostring(detail.alias or L('staff_reassign.the_new_hitman')), #detail.removed,
            stakes > 0 and (L('staff_reassign.of_stakes_went_to_the_placer')):format(stakes) or '',
            (detail.stakeWaived and L('staff_reassign.their_stake_was_waived') or L('staff_reassign.they_put_up_the_stake_as'))
                .. (detail.anonymous and L('staff_reassign.they_are_on_it_anonymously_at')
                    or L('staff_reassign.the_placer_sees_their_name'))),
        { alias = detail.alias, removed = #detail.removed, stakeWaived = detail.stakeWaived,
          anonymous = detail.anonymous }
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
        warn[#warn + 1] = (L('staff_reassign.config_staff_reassignstake_is_it_has')
            .. '\'waive\'.'):format(tostring(value))
        Config.Staff.ReassignStake = 'waive'
    end
end

return StaffReassign
end)
