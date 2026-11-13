CrimsonBoot.define('server.staff_reward', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/staff_reward.lua                 ║
    ║       Staff raise or lower the reward on a live contract, through escrow  ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The admin panel's Change reward (ops rewardPreview, a read, and
--- rewardChange, the staff ACE's: Config.Admin.Ace). Added through
--- Panel.extend, so each runs the panel's own gate: the source, the ACE on
--- every request, the token buckets (admin, adminWrite), a write waiting for
--- boot recovery, the log written at once. The page asks twice before it
--- sends a change (the two-click confirm, naming the figure).
---
--- What a change does, on the collection being competed for (next_slot):
---
---   * Raise by N: one new baseline money line of N. Funded by staff by
---     default ('added by staff', Escrow.addStaffLine: taken from nobody,
---     and handed back to staff, never to the placer, by every ending that
---     refunds the placer); or, with from = 'placer', charged to the placer's
---     cash or bank as their own top-up (Escrow.take; they must be in the
---     city and able to cover it). Never past Config.MaxContractValue.
---   * Lower by N: held baseline money lines on that collection are cut,
---     staff-added ones first, then the placer's newest first; each cut owes
---     the difference to whoever funded that line (Escrow.reduceLine: the
---     placer, queued if they are away, or staff). Never below
---     Config.Limits.MinContractReward, never a collection left with no
---     money when it holds no goods, and never a line already owed, being
---     paid or paid: only what the contract still holds unclaimed moves. The
---     buyout and the stake the next hitman is quoted are re-clamped
---     (Contracts.reclampToEscrow); a stake already put up is not.
---
--- Refused while a claim is paying the contract (COMPLETING, or a claim in
--- flight), while a buyout waits out its delay, while it is on hold by staff
--- (a freeze: nothing on it moves; unfreeze first), and past
--- Config.Staff.RewardChangeMax at once (0 turns it off). One change at a
--- time per contract, on the key every acceptance, top-up and withdrawal
--- holds. Audited (staff_reward_changed, with the reason); the placer and
--- every active operative are told the reward changed, by staff, never by
--- whom, and nothing about any other party.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local L = CrimsonBoot.requireShared('locale').t

local StaffReward = {}

local deps

--- How long a raise waits on a claim that started under it, and how often
--- it looks: a claim is a handful of store calls.
local CLAIM_WAIT_MS, CLAIM_POLL_MS = 3000, 100

--- The ops, [name] = level, for the docs and the specs.
StaffReward.OPS = {}

--- What players read. Never who changed it or why.
StaffReward.TITLE_RAISED = L('staff_reward.reward_raised')
StaffReward.TITLE_LOWERED = L('staff_reward.reward_lowered')

---@return integer the most one change may move now; 0 = off
local function most()
    local max = tonumber(Config.Staff and Config.Staff.RewardChangeMax) or 0
    if max ~= max or max < 0 then return 0 end
    return math.floor(max)
end

--- A signed whole number of dollars, not nothing, or nil.
local function wholeChange(value)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return nil end
    if value ~= math.floor(value) or value == 0 then return nil end
    if value > 2147483647 or value < -2147483647 then return nil end
    return math.floor(value)
end

local function isMoneyBaseline(line, slot)
    return line.portion == CH.PORTION.BASELINE and CH.MONEY_SOURCES[line.source]
        and (line.slot or 1) == slot
end

--- What the collection being competed for holds, as this change measures
--- it: its money (held, owed to nobody), whether it holds goods, and the
--- lines a cut may come off, staff-added first, then newest first.
---@return table { slot, reward, goods, lines }
local function slotOf(contract)
    local slot = contract.next_slot or 1
    local out = { slot = slot, reward = 0, goods = false, lines = {} }
    for _, line in ipairs(deps.storage.readEscrow(contract.id) or {}) do
        local held = line.state == CH.ESCROW_STATE.HELD and not line.owed_to
        if held and line.portion == CH.PORTION.BASELINE and (line.slot or 1) == slot
            and not CH.MONEY_SOURCES[line.source] then
            out.goods = true
        end
        if held and isMoneyBaseline(line, slot) and (line.amount or 0) > 0 then
            out.reward = out.reward + line.amount
            if not deps.escrow.inFlight(line.id) then out.lines[#out.lines + 1] = line end
        end
    end
    local function index(id) return tonumber(tostring(id):match(':(%d+)$')) or 0 end
    table.sort(out.lines, function(a, b)
        local sa, sb = a.taken_from == deps.escrow.STAFF, b.taken_from == deps.escrow.STAFF
        if sa ~= sb then return sa end
        return index(a.id) > index(b.id)
    end)
    return out
end

--- Why a change may not be made to this contract now, or nil.
---@return string|nil err
local function refusal(contract)
    if not contract then return CH.ERR.NOT_FOUND end
    if CH.TERMINAL[contract.state] then return CH.ERR.ALREADY_SETTLED end
    if contract.state == CH.STATE.COMPLETING or deps.escrow.claimRunning(contract.id) then
        return 'claim_running'
    end
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then return CH.ERR.BAD_STATE end
    if contract.bailout_queued_at then return 'buyout_queued' end
    if Holds.on(contract, nil, 'staff') then return CH.ERR.CONTRACT_FROZEN end
    if (contract.next_slot or 1) > (contract.payout_slots or 1) then return CH.ERR.ALREADY_SETTLED end
    return nil
end

--- What a cut of `need` would take off which lines, or nil and why.
---@return table|nil plan { { line, to = amount } ... }
---@return string|nil err
---@return table|nil detail { most = n } or { min = n }
local function cutPlan(contract, held, need)
    local keep = held.goods and 0 or 1
    local most = math.max(0, held.reward - keep)
    if need > most then return nil, 'too_low', { most = most } end
    local tooSmall, floor = deps.contracts.belowMinReward(deps.escrow.moneyValue(contract.id) - need)
    if tooSmall then return nil, tooSmall, floor end
    local plan, left = {}, need
    for _, line in ipairs(held.lines) do
        if left <= 0 then break end
        local cut = math.min(line.amount, left)
        plan[#plan + 1] = { line = line, to = line.amount - cut, cut = cut }
        left = left - cut
    end
    if left > 0 then return nil, 'too_low', { most = need - left } end
    return plan
end

--- Wait out a claim that started under a raise, then whether the new line
--- still sweetens the collection it was put on. One that cannot is handed
--- back to whoever funded it; one a claim paid out went where it was meant.
---@return boolean kept
---@return string|nil err
local function keptOrBack(contractId, slot, ids, funder)
    local now = deps.storage.readContract(contractId)
    local waited = 0
    while now and now.state == CH.STATE.COMPLETING and waited < CLAIM_WAIT_MS do
        Wait(CLAIM_POLL_MS)
        waited = waited + CLAIM_POLL_MS
        now = deps.storage.readContract(contractId)
    end
    local state = now and now.state
    if (state == CH.STATE.ACTIVE or state == CH.STATE.ACCEPTED) and (now.next_slot or 1) == slot then
        return true
    end
    local back, paid = {}, false
    for id in pairs(ids) do
        local line = deps.storage.readEscrowLine(id)
        if line and line.state == CH.ESCROW_STATE.HELD and not line.owed_to then
            back[id] = true
        elseif line and (line.settled_to or line.owed_to or line.releasing_to) ~= funder then
            paid = true
        end
    end
    if next(back) then deps.escrow.release(contractId, funder, { lines = back }, 'staff_reward_moved') end
    if paid then return true end
    if CH.TERMINAL[state] then return false, CH.ERR.ALREADY_SETTLED end
    return false, 'claim_running'
end

--- Tell the placer and every active operative, each in their own words.
local function tell(contract, raised, placerLine)
    local target = tostring(contract.target_name or L('staff_reward.your_target'))
    local title = raised and StaffReward.TITLE_RAISED or StaffReward.TITLE_LOWERED
    -- Whole sentences for a raise and a cut: the verb slotted in was
    -- English in any language.
    deps.notify.tellOrKeep(contract.creator_cid, title,
        (L(raised and 'staff_reward.staff_raised_the_reward_on_your_contract'
            or 'staff_reward.staff_lowered_the_reward_on_your_contract')):format(target, placerLine or ''),
        { bypassBudget = true }, contract.id)
    local cids = {}
    for _, h in ipairs(deps.storage.readHitmen(contract.id) or {}) do
        if h.state == 'active' then
            cids[#cids + 1] = h.hitman_cid
            deps.notify.tellOrKeep(h.hitman_cid, title,
                L(raised and 'staff_reward.staff_raised_the_reward_on_a_contract'
                    or 'staff_reward.staff_lowered_the_reward_on_a_contract'),
                { bypassBudget = true }, contract.id)
        end
    end
    deps.notify.pushParties(contract, cids, raised and 'improved' or 'edited')
end

local function changeUnlocked(staff, contractId, by, opts)
    local contract = deps.storage.readContract(contractId)
    local err = refusal(contract)
    if err then return false, err end
    local held = slotOf(contract)
    local before = held.reward
    local done = { before = before, slot = held.slot }

    if by > 0 then
        local worth = deps.escrow.moneyValue(contractId)
        local ceiling = tonumber(Config.MaxContractValue) or 0
        if ceiling > 0 and worth + by > ceiling then
            return false, 'too_much_value', { max = math.max(0, ceiling - worth) }
        end
        local ok, ids, funder
        if opts.from == 'placer' then
            local placer = deps.identity.byCitizenId(contract.creator_cid)
            if not placer or not placer.player then return false, 'placer_away' end
            ok, err, ids = deps.escrow.take(placer, contractId, { {
                slot = held.slot, portion = CH.PORTION.BASELINE, source = opts.account, amount = by,
            } })
            if not ok then return false, err == CH.ERR.LOCKED and CH.ERR.BUSY or err end
            funder = contract.creator_cid
        else
            ok, err, ids = deps.escrow.addStaffLine(contractId, held.slot, by, opts.account, staff.cid)
            if not ok then return false, err == CH.ERR.LOCKED and CH.ERR.BUSY or err end
            funder = deps.escrow.STAFF
        end
        local kept, movedErr = keptOrBack(contractId, held.slot, ids, funder)
        if not kept then return false, movedErr end
        done.after, done.added = before + by, by
        done.from = opts.from == 'placer' and 'placer' or 'staff'
    else
        local plan, planErr, detail = cutPlan(contract, held, -by)
        if not plan then return false, planErr, detail end
        local toPlacer, toStaff, queued, cut = 0, 0, 0, 0
        -- A claim takes no key: one that starts in any await of this change
        -- marks the collection's lines for its hitman and pays them as they
        -- stand. So the contract is asked again right before each cut, and
        -- the claim count once more with nothing awaited before the cut is
        -- written (the guard), and the store cuts only a line still owed to
        -- nobody (Escrow.reduceLine).
        local function noClaim() return not deps.escrow.claimRunning(contractId) end
        for _, step in ipairs(plan) do
            local line = step.line
            local staffLine = line.taken_from == deps.escrow.STAFF
            local recipient = staffLine and deps.escrow.STAFF or (line.taken_from or contract.creator_cid)
            local now = deps.storage.readContract(contractId)
            if not now or (now.state ~= CH.STATE.ACTIVE and now.state ~= CH.STATE.ACCEPTED) or not noClaim() then
                break
            end
            local owedId, delivered = deps.escrow.reduceLine(contractId, line, step.to,
                'staff_reward_lowered', recipient, noClaim)
            -- A claim took the line from under the cut: stop here, with
            -- what was cut already on the record.
            if not owedId then break end
            cut = cut + step.cut
            if staffLine then
                toStaff = toStaff + step.cut
            else
                toPlacer = toPlacer + step.cut
                if not delivered then queued = queued + step.cut end
            end
        end
        if cut == 0 then return false, 'claim_running' end
        deps.contracts.reclampToEscrow(contractId, staff.cid)
        done.after, done.cut, done.toPlacer, done.toStaff, done.queued = before - cut, cut, toPlacer, toStaff, queued
        done.partial = cut < -by or nil
    end

    deps.audit.staff('staff_reward_changed', staff.cid, contractId, {
        by = by, from = done.from, account = by > 0 and opts.account or nil, reason = opts.reason,
        before = before, after = done.after, slot = held.slot,
        to_placer = done.toPlacer, to_staff = done.toStaff, partial = done.partial,
    })
    local placerLine
    if by > 0 and done.from == 'placer' then
        placerLine = (opts.account == 'cash' and L('staff_reward.was_taken_from_your_cash_for_it')
            or L('staff_reward.was_taken_from_your_bank_for_it')):format(by)
    elseif (done.toPlacer or 0) > 0 then
        placerLine = (done.queued or 0) > 0
            and (L('staff_reward.of_what_you_put_up_is'))
                :format(done.toPlacer)
            or (L('staff_reward.of_what_you_put_up_came')):format(done.toPlacer)
    end
    tell(deps.storage.readContract(contractId) or contract, by > 0, placerLine)
    return true, nil, done
end

--- Raise or lower a live contract's reward (see the top of this file).
---@param staff table { cid, name, source }
---@param contractId string
---@param by integer signed whole dollars
---@param opts table { from = 'staff'|'placer', account = 'cash'|'bank', reason }
---@return boolean ok
---@return string|nil err
---@return table|nil detail
function StaffReward.change(staff, contractId, by, opts)
    return deps.contracts.serialized({ 'contract:' .. contractId }, changeUnlocked, staff, contractId, by, opts)
end

--- What a change would do, for the confirm: the collection's reward now and
--- after, the most it may be lowered by, and why it may not be made.
---@return table
function StaffReward.preview(contractId, by)
    local contract = deps.storage.readContract(contractId)
    local out = { max = most() }
    local err = refusal(contract)
    if err then
        out.refused = err
        return out
    end
    local held = slotOf(contract)
    out.slot, out.reward, out.total = held.slot, held.reward, deps.escrow.moneyValue(contractId)
    out.mostLower = math.max(0, held.reward - (held.goods and 0 or 1))
    local floor = tonumber(Config.Limits.MinContractReward) or 0
    if floor > 0 then out.mostLower = math.max(0, math.min(out.mostLower, out.total - floor)) end
    out.staffAdded = 0
    for _, line in ipairs(held.lines) do
        if line.taken_from == deps.escrow.STAFF then out.staffAdded = out.staffAdded + line.amount end
    end
    if by then
        out.after = held.reward + by
        -- Refused here as the change itself refuses it (opChange): off while
        -- RewardChangeMax is 0, and past it either way, a lowering as well.
        if most() == 0 then
            out.refused = 'reward_change_off'
            return out
        end
        if math.abs(by) > most() then
            out.refused, out.refusedDetail = 'too_much', { max = most() }
            return out
        end
        if by > 0 then
            -- Refused here as the change itself refuses it, with its own
            -- figures: the preview said nothing and only the confirm did.
            local ceiling = tonumber(Config.MaxContractValue) or 0
            if ceiling > 0 and out.total + by > ceiling then
                out.refused, out.refusedDetail = 'too_much_value', { max = math.max(0, ceiling - out.total) }
            end
        end
        if by < 0 then
            -- With the figure the refusal names (the most it may be
            -- lowered by, the least a reward may be): without it the
            -- preview said $0 where the change says the real limit.
            local plan, planErr, planDetail = cutPlan(contract, held, -by)
            if plan then
                local toStaff, toPlacer = 0, 0
                for _, step in ipairs(plan) do
                    if step.line.taken_from == deps.escrow.STAFF then toStaff = toStaff + step.cut
                    else toPlacer = toPlacer + step.cut end
                end
                out.toStaff, out.toPlacer = toStaff, toPlacer
            else
                out.refused, out.refusedDetail = planErr, planDetail
            end
        end
    end
    return out
end

--------------------------------------------------------------------------
-- The panel's ops
--------------------------------------------------------------------------

local MESSAGES = {
    [CH.ERR.NOT_FOUND] = L('staff_reward.no_contract_has_that_id'),
    [CH.ERR.ALREADY_SETTLED] = L('staff_reward.it_has_ended_or_every_payout'),
    [CH.ERR.BAD_STATE] = L('staff_reward.only_a_live_contract_active_or'),
    claim_running = L('staff_reward.a_payout_on_it_is_being'),
    buyout_queued = L('staff_reward.its_target_has_paid_a_buyout'),
    [CH.ERR.BUSY] = L('staff_reward.something_else_was_changing_this_contract'),
    placer_away = L('staff_reward.charging_the_placer_needs_them_in'),
    [CH.ERR.INSUFFICIENT] = L('staff_reward.the_placer_cannot_cover_that_from'),
    [CH.ERR.REWARD_TOO_SMALL] = L('staff_reward.not_below_the_least_a_reward'),
    reward_change_off = L('staff_reward.changing_a_reward_is_off_config'),
}

local function refused(src, contractId, err, detail)
    if err == CH.ERR.CONTRACT_FROZEN then
        -- Said as on hold only where this staff member's view says so: held
        -- through an anonymous party they may not see, no more than that.
        local contract = deps.storage.readContract(contractId)
        if contract and Holds.shown(contract, nil, deps.panel.identifies(src)) then
            return false, err, L('staff_reward.it_is_on_hold_by_staff')
        end
        return false, 'not_changed', L('staff_reward.not_changed_try_again_in_a')
    end
    if err == 'too_low' then
        return false, err, (L('staff_reward.that_collection_can_be_lowered_by')):format(detail and detail.most or 0), detail
    end
    if err == 'too_much_value' then
        return false, err, (L('staff_reward.not_past_the_most_a_contract')):format(detail and detail.max or 0), detail
    end
    if err == 'too_much' then
        return false, err, (L('staff_reward.at_most_at_once_config_staff')):format(detail and detail.max or most()), detail
    end
    if err == CH.ERR.REWARD_TOO_SMALL then
        return false, err, (L('staff_reward.not_below_the_least_a_reward_2'))
            :format(detail and detail.min or 0), detail
    end
    return false, err, MESSAGES[err] or L('staff_reward.not_changed_try_again_in_a')
end

--- { id, by } -> what the change would do; a read, scrubbed of nobody (it
--- names no party).
local function opPreview(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('staff_reward.give_a_contract_id') end
    local by = data.by ~= nil and wholeChange(data.by) or nil
    if data.by ~= nil and not by then return false, CH.ERR.INVALID_INPUT, L('staff_reward.give_a_whole_number_of_dollars') end
    local view = StaffReward.preview(id, by)
    if view.refused == CH.ERR.NOT_FOUND then return refused(src, id, view.refused) end
    if view.refused == CH.ERR.CONTRACT_FROZEN then
        local _, code, message = refused(src, id, view.refused)
        view.refused, view.message = code, message
    elseif view.refused then
        view.message = select(3, refused(src, id, view.refused, view.refusedDetail))
    end
    view.refusedDetail = nil
    return true, nil, nil, view
end

--- { id, by (signed whole dollars), from ('staff' | 'placer'), account
--- ('cash' | 'bank'), reason }.
local function opChange(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('staff_reward.give_a_contract_id') end
    local max = most()
    if max == 0 then
        return false, 'reward_change_off', L('staff_reward.changing_a_reward_is_off_config')
    end
    local by = wholeChange(data.by)
    if not by then
        return false, CH.ERR.INVALID_INPUT, L('staff_reward.give_a_whole_number_of_dollars_2')
    end
    if math.abs(by) > max then
        return false, 'too_much', (L('staff_reward.at_most_at_once_config_staff')):format(max), { max = max }
    end
    local from = data.from == nil and 'staff' or data.from
    if from ~= 'staff' and from ~= 'placer' then
        return false, CH.ERR.INVALID_INPUT, L('staff_reward.a_raise_is_added_by_staff')
    end
    local account = data.account == nil and 'bank' or data.account
    if account ~= 'cash' and account ~= 'bank' then
        return false, CH.ERR.INVALID_INPUT, L('staff_reward.cash_or_bank')
    end
    local reason = type(data.reason) == 'string' and Util.sanitizeText(data.reason, 120) or nil
    if not reason then return false, CH.ERR.INVALID_INPUT, L('staff_reward.give_a_reason_it_goes_on') end

    local ok, err, detail = StaffReward.change(deps.panel.staffActor(src), id, by,
        { from = from, account = account, reason = reason })
    if not ok then return refused(src, id, err, detail) end
    local said
    if by > 0 then
        said = (L('staff_reward.reward_raised_from_to')):format(detail.before, detail.after,
            detail.from == 'placer' and (account == 'cash' and L('staff_reward.charged_to_the_placers_cash')
                or L('staff_reward.charged_to_the_placers_bank')) or L('staff_reward.added_by_staff'))
    else
        said = (L('staff_reward.reward_lowered_from_to')):format(detail.before, detail.after)
        if (detail.toPlacer or 0) > 0 then
            said = said .. (L('staff_reward.went_back_to_the_placer')):format(detail.toPlacer,
                (detail.queued or 0) > 0 and L('staff_reward.waiting_for_them') or '')
        end
        if (detail.toStaff or 0) > 0 then
            said = said .. (L('staff_reward.staff_had_added_came_off')):format(detail.toStaff)
        end
        if detail.partial then said = said .. L('staff_reward.a_payout_took_part_of_it') end
    end
    return true, nil, said .. L('staff_reward.the_placer_and_the_operatives_were'), detail
end

--- Add the ops to the panel.
---@param d table the wired modules
function StaffReward.register(d)
    deps = d
    if not (d.panel and d.panel.extend) then return end
    local levels = d.panel.LEVELS
    StaffReward.OPS = { rewardPreview = levels.READ, rewardChange = levels.WRITE }
    d.panel.extend('rewardPreview', levels.READ, opPreview)
    d.panel.extend('rewardChange', levels.WRITE, opChange)
end

--- Start-up check of the setting (main.lua): a whole number of dollars,
--- 0 or more; anything else is the shipped figure, said.
---@param warn string[]
function StaffReward.validate(warn)
    if type(Config.Staff) ~= 'table' then return end
    local value = Config.Staff.RewardChangeMax
    if type(value) ~= 'number' or value ~= value or value < 0 or value ~= math.floor(value) then
        warn[#warn + 1] = (L('staff_reward.config_staff_rewardchangemax_is_not_a')):format(tostring(value))
        Config.Staff.RewardChangeMax = 100000
    end
end

return StaffReward
end)
