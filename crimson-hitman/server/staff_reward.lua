--[[
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

local StaffReward = {}

local deps

--- How long a raise waits on a claim that started under it, and how often
--- it looks: a claim is a handful of store calls.
local CLAIM_WAIT_MS, CLAIM_POLL_MS = 3000, 100

--- The ops, [name] = level, for the docs and the specs.
StaffReward.OPS = {}

--- What players read. Never who changed it or why.
StaffReward.TITLE_RAISED = 'Reward raised'
StaffReward.TITLE_LOWERED = 'Reward lowered'

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
    if deps.contracts.heldByStaff(contract) then return CH.ERR.CONTRACT_FROZEN end
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
    local target = tostring(contract.target_name or 'your target')
    local title = raised and StaffReward.TITLE_RAISED or StaffReward.TITLE_LOWERED
    local verb = raised and 'raised' or 'lowered'
    deps.notify.tellOrKeep(contract.creator_cid, title,
        ('Staff %s the reward on your contract on %s.%s'):format(verb, target, placerLine or ''),
        { bypassBudget = true }, contract.id)
    local cids = {}
    for _, h in ipairs(deps.storage.readHitmen(contract.id) or {}) do
        if h.state == 'active' then
            cids[#cids + 1] = h.hitman_cid
            deps.notify.tellOrKeep(h.hitman_cid, title,
                ('Staff %s the reward on a contract you hold. Its card shows the new figure.'):format(verb),
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
        placerLine = (' $%d was taken from your %s for it.'):format(by, opts.account)
    elseif (done.toPlacer or 0) > 0 then
        placerLine = (done.queued or 0) > 0
            and (' $%d of what you put up is waiting for you: it arrives when you next have room.')
                :format(done.toPlacer)
            or (' $%d of what you put up came back to you.'):format(done.toPlacer)
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
        if by < 0 then
            local plan, planErr = cutPlan(contract, held, -by)
            if plan then
                local toStaff, toPlacer = 0, 0
                for _, step in ipairs(plan) do
                    if step.line.taken_from == deps.escrow.STAFF then toStaff = toStaff + step.cut
                    else toPlacer = toPlacer + step.cut end
                end
                out.toStaff, out.toPlacer = toStaff, toPlacer
            else
                out.refused = planErr
            end
        end
    end
    return out
end

--------------------------------------------------------------------------
-- The panel's ops
--------------------------------------------------------------------------

local MESSAGES = {
    [CH.ERR.NOT_FOUND] = 'No contract has that id.',
    [CH.ERR.ALREADY_SETTLED] = 'It has ended, or every payout on it is collected.',
    [CH.ERR.BAD_STATE] = 'Only a live contract (active or accepted) has a reward to change.',
    claim_running = 'A payout on it is being settled right now. Try again in a moment.',
    buyout_queued = 'Its target has paid a buyout that is waiting out its delay; that settles first.',
    [CH.ERR.BUSY] = 'Something else was changing this contract. Try again in a moment.',
    placer_away = 'Charging the placer needs them in the city; add it as staff instead, or try later.',
    [CH.ERR.INSUFFICIENT] = 'The placer cannot cover that from the account chosen.',
    [CH.ERR.REWARD_TOO_SMALL] = 'Not below the least a reward may be worth (Config.Limits.MinContractReward).',
}

local function refused(src, contractId, err, detail)
    if err == CH.ERR.CONTRACT_FROZEN then
        -- Said as on hold only where this staff member's view says so: held
        -- through an anonymous party they may not see, no more than that.
        local contract = deps.storage.readContract(contractId)
        if contract and deps.panel.frozenShown
            and deps.panel.frozenShown(contract, deps.panel.identifies(src)) then
            return false, err, 'It is on hold by staff, and nothing on it moves: unfreeze first.'
        end
        return false, 'not_changed', 'Not changed: try again in a moment.'
    end
    if err == 'too_low' then
        return false, err, ('That collection can be lowered by $%d at most: only money it still holds '
            .. 'unclaimed moves, and it keeps some.'):format(detail and detail.most or 0), detail
    end
    if err == 'too_much_value' then
        return false, err, ('Not past the most a contract may hold (Config.MaxContractValue): $%d more '
            .. 'at most.'):format(detail and detail.max or 0), detail
    end
    if err == CH.ERR.REWARD_TOO_SMALL then
        return false, err, ('Not below $%d, the least a reward may be worth (Config.Limits.MinContractReward).')
            :format(detail and detail.min or 0), detail
    end
    return false, err, MESSAGES[err] or 'Not changed: try again in a moment.'
end

--- { id, by } -> what the change would do; a read, scrubbed of nobody (it
--- names no party).
local function opPreview(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local by = data.by ~= nil and wholeChange(data.by) or nil
    if data.by ~= nil and not by then return false, CH.ERR.INVALID_INPUT, 'Give a whole number of dollars.' end
    local view = StaffReward.preview(id, by)
    if view.refused == CH.ERR.NOT_FOUND then return refused(src, id, view.refused) end
    if view.refused == CH.ERR.CONTRACT_FROZEN then
        local _, code, message = refused(src, id, view.refused)
        view.refused, view.message = code, message
    elseif view.refused then
        view.message = select(3, refused(src, id, view.refused))
    end
    return true, nil, nil, view
end

--- { id, by (signed whole dollars), from ('staff' | 'placer'), account
--- ('cash' | 'bank'), reason }.
local function opChange(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local max = most()
    if max == 0 then
        return false, 'reward_change_off', 'Changing a reward is off (Config.Staff.RewardChangeMax is 0).'
    end
    local by = wholeChange(data.by)
    if not by then
        return false, CH.ERR.INVALID_INPUT, 'Give a whole number of dollars to raise (above 0) or lower (below 0) it by.'
    end
    if math.abs(by) > max then
        return false, 'too_much', ('At most $%d at once (Config.Staff.RewardChangeMax).'):format(max), { max = max }
    end
    local from = data.from == nil and 'staff' or data.from
    if from ~= 'staff' and from ~= 'placer' then
        return false, CH.ERR.INVALID_INPUT, 'A raise is added by staff or charged to the placer.'
    end
    local account = data.account == nil and 'bank' or data.account
    if account ~= 'cash' and account ~= 'bank' then
        return false, CH.ERR.INVALID_INPUT, 'Cash or bank.'
    end
    local reason = type(data.reason) == 'string' and Util.sanitizeText(data.reason, 120) or nil
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end

    local ok, err, detail = StaffReward.change(deps.panel.staffActor(src), id, by,
        { from = from, account = account, reason = reason })
    if not ok then return refused(src, id, err, detail) end
    local said
    if by > 0 then
        said = ('Reward raised from $%d to $%d, %s.'):format(detail.before, detail.after,
            detail.from == 'placer' and ('charged to the placer\'s ' .. account) or 'added by staff')
    else
        said = ('Reward lowered from $%d to $%d.'):format(detail.before, detail.after)
        if (detail.toPlacer or 0) > 0 then
            said = said .. (' $%d went back to the placer%s.'):format(detail.toPlacer,
                (detail.queued or 0) > 0 and ' (waiting for them)' or '')
        end
        if (detail.toStaff or 0) > 0 then
            said = said .. (' $%d staff had added came off.'):format(detail.toStaff)
        end
        if detail.partial then said = said .. ' A payout took part of it meanwhile; the rest is as it was.' end
    end
    return true, nil, said .. ' The placer and the operatives were told it changed, by staff.', detail
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
        warn[#warn + 1] = ('Config.Staff.RewardChangeMax is %s, not a whole number of dollars (0 turns '
            .. 'reward changes off); using 100000.'):format(tostring(value))
        Config.Staff.RewardChangeMax = 100000
    end
end

return StaffReward
