--- One player's history, for the read-only card under Players in the admin
--- panel: the contracts they placed, took, completed and cancelled, the
--- buyouts, the informant purchases, the money in and out by kind, and every
--- freeze, suspension and protection with its dates.
---
--- Built from what the store still keeps: the contracts (pruned after
--- Config.Audit.ContractRetentionDays once they hold nothing), their escrow
--- lines, the audit rows the player acted in (Config.Audit.RetentionDays),
--- and the staff records (server/sanctions.lua), which are never pruned.
---
--- Anonymity: names, and anything the player did anonymously, only for
--- staff with IdentityAce. For everyone else a contract the player placed
--- or took anonymously is not theirs here at all, not even in a count, and
--- neither is any money or purchase on it: a count one higher than the
--- named contracts would say an anonymous contract on the board was theirs.
--- An audit row about a contract the store no longer keeps cannot be told
--- apart, so it is left out for them too; and so is every anonymity fee,
--- which is only ever paid to be anonymous. Without IdentityAce no name of
--- anybody is shown, and who acted on a staff record is left out.

local History = {}

--- Recent contracts listed on the card, newest first.
local RECENT_ROWS = 25
--- Audit rows of the player's own read for the purchases and payments.
local AUDIT_ROWS = 500

--- The audit rows that are money, read from the player's own actions:
--- which way it went, the kind it is listed under, and the field the figure
--- is in.
local AUDIT_MONEY = {
    bailout_paid            = { way = 'out', kind = 'buyouts paid', field = 'amount' },
    bailout_refunded        = { way = 'in', kind = 'buyouts refunded', field = 'amount' },
    informant_purchased     = { way = 'out', kind = 'informants', field = 'cost', informant = 'informant' },
    placer_informant_bought = { way = 'out', kind = 'informants', field = 'amount', informant = 'placerInformant' },
    location_tip_bought     = { way = 'out', kind = 'informants', field = 'amount', informant = 'locationTip' },
    location_tip_refunded   = { way = 'in', kind = 'informant refunds', field = 'amount' },
    anonymity_fee           = { way = 'out', kind = 'anonymity fees', field = 'amount', identityOnly = true },
}

local MONEY = { cash = true, bank = true, dirty = true }

local function add(book, kind, amount)
    amount = tonumber(amount) or 0
    if amount == 0 then return end
    book[kind] = (book[kind] or 0) + amount
end

--- The money one escrow line moved for this player, if it did: which way,
--- and under what kind.
local function lineMoney(line, cid)
    if not MONEY[line.source] then return nil end
    local amount = tonumber(line.amount) or 0
    if amount <= 0 then return nil end
    local out = {}
    local portion = line.portion
    if portion == CH.PORTION.STAKE then
        if line.staker == cid then out[#out + 1] = { 'out', 'stakes put up', amount } end
        if line.state == CH.ESCROW_STATE.SETTLED and line.settled_to == cid then
            out[#out + 1] = { 'in', line.staker == cid and 'stakes returned' or 'stakes won', amount }
        end
    elseif portion == CH.PORTION.OWED then
        if line.state == CH.ESCROW_STATE.SETTLED and line.settled_to == cid then
            local id = tostring(line.id or '')
            local kind = id:find('^prem:') and 'buyout premiums'
                or id:find('^refund:') and 'buyouts refunded' or 'owed and paid'
            out[#out + 1] = { 'in', kind, amount }
        end
    else
        if line.taken_from == cid then out[#out + 1] = { 'out', 'rewards put up', amount } end
        if line.state == CH.ESCROW_STATE.SETTLED and line.settled_to == cid then
            out[#out + 1] = { 'in', line.taken_from == cid and 'rewards returned' or 'payouts', amount }
        end
    end
    return out
end

--- Build the card.
---@param deps table the panel's: storage, sanctions, freeze, identity
---@param cid string
---@param canIdentify boolean
---@return table
function History.build(deps, cid, canIdentify)
    local Storage = deps.storage
    local counts = { placed = 0, taken = 0, completed = 0, cancelled = 0, onThem = 0, boughtOut = 0 }
    local moneyIn, moneyOut = {}, {}
    local recent = {}
    local known, hidden = {}, {}
    local anonymousCount = 0

    for _, contract in ipairs(Storage.contractsInvolving(cid) or {}) do
        local hitmen = Storage.readHitmen(contract.id) or {}
        local mine
        for i = 1, #hitmen do
            if hitmen[i].hitman_cid == cid then mine = hitmen[i] end
        end
        local anonymous = (contract.creator_cid == cid and contract.anon_creator == true)
            or (mine ~= nil and mine.anon == true)
        known[contract.id] = true
        if anonymous then anonymousCount = anonymousCount + 1 end
        if anonymous and not canIdentify then
            hidden[contract.id] = true
        else
            local roles = {}
            if contract.creator_cid == cid then
                counts.placed = counts.placed + 1
                roles[#roles + 1] = 'client'
                if contract.state == CH.STATE.CANCELLED then counts.cancelled = counts.cancelled + 1 end
            end
            if contract.target_cid == cid then
                counts.onThem = counts.onThem + 1
                roles[#roles + 1] = 'target'
                if contract.state == CH.STATE.BAILED_OUT then counts.boughtOut = counts.boughtOut + 1 end
            end
            if mine and mine.state ~= 'joining' and mine.state ~= 'rejoining' then
                counts.taken = counts.taken + 1
                roles[#roles + 1] = 'hitman'
            end

            local collected = false
            for _, line in ipairs(Storage.readEscrow(contract.id) or {}) do
                for _, moved in ipairs(lineMoney(line, cid) or {}) do
                    add(moved[1] == 'in' and moneyIn or moneyOut, moved[2], moved[3])
                    if moved[2] == 'payouts' then collected = true end
                end
            end
            if collected and mine then counts.completed = counts.completed + 1 end

            recent[#recent + 1] = {
                id = contract.id, state = contract.state, roles = roles,
                anonymous = canIdentify and anonymous or nil,
                created_at = contract.created_at, resolved_at = contract.resolved_at,
                client = canIdentify and (contract.creator_name or contract.creator_cid) or nil,
                target = canIdentify and (contract.target_name or contract.target_cid) or nil,
            }
        end
    end
    table.sort(recent, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then return (a.created_at or 0) > (b.created_at or 0) end
        return tostring(a.id) > tostring(b.id)
    end)
    for i = #recent, RECENT_ROWS + 1, -1 do recent[i] = nil end

    -- Purchases and payments the player made themselves, from the log.
    local informants = { count = 0, spent = 0, informant = 0, placerInformant = 0, locationTip = 0 }
    local buyouts = { paid = 0, amount = 0 }
    local okRows, rows = pcall(Storage.queryAudit, { actor = cid, kind = 'financial' }, nil, AUDIT_ROWS)
    for _, row in ipairs(okRows and rows or {}) do
        local rule = AUDIT_MONEY[row.action]
        local detail = type(row.detail) == 'table' and row.detail or {}
        local shown = rule ~= nil
        if shown and not canIdentify then
            -- Only about a contract still kept and not one they were
            -- anonymous on, and never an anonymity fee.
            shown = not rule.identityOnly and row.contract_id ~= nil and known[row.contract_id] == true
                and not hidden[row.contract_id]
        end
        if shown then
            local amount = tonumber(detail[rule.field]) or 0
            add(rule.way == 'in' and moneyIn or moneyOut, rule.kind, amount)
            if rule.informant then
                informants.count = informants.count + 1
                informants.spent = informants.spent + amount
                informants[rule.informant] = informants[rule.informant] + 1
            end
            if row.action == 'bailout_paid' then
                buyouts.paid = buyouts.paid + 1
                buyouts.amount = buyouts.amount + amount
            end
        end
    end

    -- Staff measures and payments, from the staff records, and the freeze
    -- on them now where its start was never recorded (one from before the
    -- records were kept).
    local measures = {}
    local frozenNoted = false
    local now = os.time()
    for _, row in ipairs(deps.sanctions and deps.sanctions.recordsOf(cid) or {}) do
        if row.kind == 'payment' then
            add(moneyIn, 'staff payments', row.amount)
        else
            local state
            if row.ended_at then
                state = row.ended_why == 'expired' and 'ended' or 'lifted'
            elseif row.until_at and now >= row.until_at then
                state = 'ended'
            else
                state = 'in force'
            end
            if row.kind == 'freeze' and not row.ended_at then frozenNoted = true end
            measures[#measures + 1] = {
                kind = row.kind, from = row.created_at, ['until'] = row.until_at,
                ended = row.ended_at or (state == 'ended' and row.until_at) or nil,
                state = state, reason = row.reason,
                by = canIdentify and row.by_cid or nil,
                endedBy = canIdentify and row.ended_by or nil,
            }
        end
    end
    local frozen = deps.freeze and deps.freeze.of(cid)
    if frozen and not frozenNoted then
        measures[#measures + 1] = { kind = 'freeze', from = frozen.frozen_at, state = 'in force',
            reason = frozen.reason, by = canIdentify and frozen.by_cid or nil }
    end
    table.sort(measures, function(a, b) return (a.from or 0) > (b.from or 0) end)

    local function sorted(book)
        local out = {}
        for kind, amount in pairs(book) do out[#out + 1] = { kind = kind, amount = amount } end
        table.sort(out, function(a, b) return a.kind < b.kind end)
        return out
    end

    return {
        counts = counts,
        recent = recent,
        buyouts = buyouts,
        informants = informants,
        money = { ['in'] = sorted(moneyIn), out = sorted(moneyOut) },
        measures = measures,
        -- How many of theirs they were anonymous on: only to staff with
        -- IdentityAce, who see those contracts too.
        anonymous = canIdentify and anonymousCount or nil,
        identified = canIdentify,
        retentionDays = tonumber(Config.Audit and Config.Audit.RetentionDays) or 0,
    }
end

return History
