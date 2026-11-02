--- Contract decay (Config.Improvements.ContractDecay, README, Optional
--- features). Off as shipped.
---
--- A contract nobody has taken yet (state 'active') changes every Hours it
--- waits, one step at a time, by Mode:
---   * 'rise': its reward goes up by Percent of the money it held at the
---     first step, never past MaxIncreasePercent of that in all. Each step
---     is charged to its placer from Account, through the placer's own
---     add-to-reward path (Amendments.addEscrow): the same checks, the same
---     escrow, charged last and audited, so nothing is made or lost. A step
---     waits while the placer is away (nobody can be charged who is not in
---     the city), and a refusal (they cannot pay, or a ceiling) stops the
---     rise on that contract for good, and they are told.
---   * 'shorten': its deadline is brought in by Percent of the time it has
---     left (Contracts.bringDeadlineIn, never closer than the clock allows;
---     stopped once it is that close). Nothing is charged.
--- The placer is told at each step, their card says what it does and what
--- it has added, and they can turn it off for that contract (decayOff).
--- What each contract has had is kept in the store (crimson_rp_rows, kind
--- 'imp_decay'), so a restart neither repeats a step nor forgets an
--- opt-out. A contract already older than a step when it is first seen
--- (one placed before this was turned on) starts its count then, rather
--- than being stepped at once.

local Util = CrimsonBoot.requireShared('util')

local Decay = {}

local Storage, Identity, Notify, Audit, Escrow, Contracts, Amendments, Board, Projection

local KIND = 'imp_decay'

--- The most steps one pass takes. Every untaken contract placed in the same
--- hour falls due on the same pass, and each 'rise' step is a charge with
--- its escrow, ledger and notice: a hundred of them were 1,951 statements
--- and a second of one frame on mysql in the harness. The rest wait for the
--- passes after, a minute apart; a step is counted in hours.
Decay.STEPS_PER_PASS = 25

--- When the next pass has anything to do, os.time(): the soonest step due,
--- and never later than one step from the last pass, so a contract placed
--- while it sleeps is seen before its first step can fall due. 0: now.
local nextAt = 0
--- The Hours that nextAt was worked out with: a change wakes the next pass.
local nextHours = nil

--- [contractId] = row { id, kind, contract_id, steps, added, base, last_at, off, stopped }
local rows = {}

local function rules()
    return Board and Board.on('ContractDecay') or nil
end

local num = Util.num

local function write(row)
    rows[row.contract_id] = row
    local ok, err = pcall(Storage.writeRpRow, row)
    if not ok then error(err, 0) end
end

local function forget(contractId)
    if not rows[contractId] then return end
    rows[contractId] = nil
    pcall(Storage.deleteRpRow, KIND .. ':' .. contractId)
end

--- The row for a contract, made the first time it is seen.
local function rowFor(contract, now, hours)
    local row = rows[contract.id]
    if row then return row end
    local created = math.floor(num(contract.created_at, now))
    row = { id = KIND .. ':' .. contract.id, kind = KIND, contract_id = contract.id,
            steps = 0, added = 0,
            last_at = (now - created) < hours * 3600 and created or now }
    write(row)
    return row
end


--- Stop the rise on a contract for good, and tell its placer why.
local function stop(row, contract, why, text)
    row.stopped = why
    write(row)
    Notify.toCitizen(contract.creator_cid, 'Contract reward', text)
    Audit.action('imp_decay_stopped', contract.creator_cid, contract.id, { why = why })
end

--- One 'rise' step on one contract.
local function rise(cfg, row, contract, now)
    local base = row.base
    if not base then
        base = math.floor(num(Escrow.moneyValue(contract.id)))
        row.base = base
    end
    local cap = math.floor(base * num(cfg.MaxIncreasePercent) / 100)
    local amount = math.min(math.floor(base * num(cfg.Percent) / 100), cap - (row.added or 0))
    if amount <= 0 then
        return stop(row, contract, 'cap', 'Your untaken contract\'s reward has risen as far as it will.')
    end
    -- Only a placer in the city can be charged; the step waits for them.
    local placer = Identity.byCitizenId(contract.creator_cid)
    if not placer then return end
    -- Still untaken, read again just before: the tick's list was read
    -- before every await since.
    local fresh = Storage.readContract(contract.id)
    if not fresh or fresh.state ~= CH.STATE.ACTIVE then return end
    local account = cfg.Account == 'cash' and 'cash' or 'bank'
    -- Written first, put back if the charge does not go through.
    local before = { added = row.added, steps = row.steps, last_at = row.last_at }
    row.added, row.steps, row.last_at = (row.added or 0) + amount, (row.steps or 0) + 1, now
    write(row)
    local ran, ok, err = pcall(Amendments.addEscrow, placer, contract.id,
        { baseline = { [account] = amount } })
    if ran and ok then
        Notify.toCitizen(contract.creator_cid, 'Contract reward',
            ('Nobody has taken your contract yet, so its reward rose by %s, taken from your %s.')
                :format(Util.dollars(amount), account))
        Audit.financial('imp_decay_rose', contract.creator_cid, contract.id,
            { amount = amount, account = account, step = row.steps, added = row.added })
        return
    end
    row.added, row.steps, row.last_at = before.added, before.steps, before.last_at
    if not ran then
        write(row)
        error(ok, 0)
    end
    -- Busy (a claim or another change on it): tried again next step.
    if err == CH.ERR.BUSY or err == CH.ERR.LOCKED then
        row.last_at = now
        return write(row)
    end
    -- Ended or taken since it was read: nothing to do.
    if err == CH.ERR.BAD_STATE or err == CH.ERR.NOT_FOUND then return write(row) end
    stop(row, contract, tostring(err),
        ('Your untaken contract\'s reward could not rise by %s from your %s, so it will not rise '
            .. 'any more.'):format(Util.dollars(amount), account))
end

--- One 'shorten' step on one contract.
local function shorten(cfg, row, contract, now)
    if not contract.deadline_at then return end
    local percent = num(cfg.Percent)
    local moved, err = Contracts.bringDeadlineIn(contract.id, function(current)
        local from = current.paused_since or os.time()
        local left = (current.deadline_at or from) - from
        if left <= 0 then return current.deadline_at end
        return current.deadline_at - math.floor(left * percent / 100)
    end)
    if not moved then
        if err == CH.ERR.INVALID_INPUT then
            return stop(row, contract, 'shortest',
                'Nobody has taken your contract, and it is as close to running out as it can be brought.')
        end
        row.last_at = now
        return write(row)
    end
    row.steps, row.last_at = (row.steps or 0) + 1, now
    write(row)
    Notify.toCitizen(contract.creator_cid, 'Contract time',
        'Nobody has taken your contract yet, so it will run out sooner.')
    Audit.action('imp_decay_shortened', contract.creator_cid, contract.id, { step = row.steps })
end

--- The tick (once a minute, on a tick of its own): one step on each
--- untaken contract that is due one, at most STEPS_PER_PASS a pass, and the
--- rows of contracts that ended forgotten. The steps sleep until the
--- soonest is due; what is running comes from the snapshot the other loops
--- share (Projection.liveSnapshot), so a pass with no step due and no row
--- kept reads nothing, and one with rows kept reads nothing new while
--- nothing was written.
---@return integer stepped
function Decay.tick()
    local cfg = rules()
    if not cfg then
        nextAt = 0
        return 0
    end
    local now = os.time()
    local hours = math.max(1, num(cfg.Hours, 1))
    if hours ~= nextHours then nextAt, nextHours = 0, hours end
    local stepping = now >= nextAt
    if not stepping and next(rows) == nil then return 0 end
    local every = hours * 3600
    local soonest, stepped, more = now + every, 0, false
    local list
    if Projection and Projection.liveSnapshot then
        list = Projection.liveSnapshot()
    else
        list = Storage.liveContracts()
    end
    local live = {}
    for _, contract in ipairs(list or {}) do
        live[contract.id] = true
        if stepping and contract.state == CH.STATE.ACTIVE then
            if (Contracts.heldByStaff and Contracts.heldByStaff(contract))
                or (Contracts.appPaused and Contracts.appPaused()) then
                -- Held: no step, and looked at again on the next pass.
                soonest = now
            else
                local row = rowFor(contract, now, hours)
                if not row.off and not row.stopped then
                    local dueAt = num(row.last_at, now) + every
                    if now < dueAt then
                        soonest = math.min(soonest, dueAt)
                    elseif stepped >= Decay.STEPS_PER_PASS then
                        more = true
                    else
                        stepped = stepped + 1
                        if cfg.Mode == 'shorten' then
                            shorten(cfg, row, contract, now)
                        else
                            rise(cfg, row, contract, now)
                        end
                        -- One that waited (its placer away) is due again on
                        -- the next pass; one taken, a step from now.
                        if not row.stopped then
                            soonest = math.min(soonest, num(row.last_at, now) + every)
                        end
                    end
                end
            end
        end
    end
    for id in pairs(rows) do
        if not live[id] then forget(id) end
    end
    if stepping then nextAt = more and 0 or soonest end
    return stepped
end

--- What the placer's card says of it, or nil.
---@param contract table
---@return table|nil
function Decay.cardFor(contract)
    local cfg = rules()
    if not cfg or type(contract) ~= 'table' then return nil end
    local row = rows[contract.id]
    if contract.state ~= CH.STATE.ACTIVE and not row then return nil end
    return {
        mode = cfg.Mode == 'shorten' and 'shorten' or 'rise',
        percent = math.floor(num(cfg.Percent)),
        hours = math.floor(num(cfg.Hours, 1)),
        maxPercent = math.floor(num(cfg.MaxIncreasePercent)),
        account = cfg.Account == 'cash' and 'cash' or 'bank',
        added = row and math.floor(num(row.added)) or 0,
        steps = row and math.floor(num(row.steps)) or 0,
        off = row and row.off == true or nil,
        stopped = row and row.stopped ~= nil or nil,
        taken = contract.state ~= CH.STATE.ACTIVE or nil,
    }
end

--- The placer turns it off for one contract of theirs (decayOff).
---@return boolean ok
---@return string|table err or the card's new decay
function Decay.turnOff(actor, contractId)
    if not rules() then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    local contract = Storage.readContract(contractId)
    if not contract or contract.creator_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    local now = os.time()
    local row = rowFor(contract, now, math.max(1, num(rules().Hours, 1)))
    if not row.off then
        row.off = true
        write(row)
        Audit.action('imp_decay_off', actor.cid, contract.id, {})
    end
    return true, nil, Decay.cardFor(contract)
end

function Decay.init(deps, board)
    Storage, Identity, Notify, Audit = deps.storage, deps.identity, deps.notify, deps.audit
    Escrow, Contracts, Amendments, Board = deps.escrow, deps.contracts, deps.amendments, board
    Projection = deps.projection
    rows, nextAt, nextHours = {}, 0, nil
    if Storage and Storage.readRpRows then
        local ok, kept = pcall(Storage.readRpRows, KIND)
        for _, row in ipairs(ok and type(kept) == 'table' and kept or {}) do
            if type(row.contract_id) == 'string' then rows[row.contract_id] = row end
        end
    end
    local projection = deps.projection
    if projection and projection.extenders then
        projection.extenders.impDecay = function(out, contract, _, role)
            if role == 'creator' then out.decay = Decay.cardFor(contract) end
        end
        projection.settingsExtenders.impDecay = function(settings)
            local cfg = rules()
            if not cfg then return end
            settings.contractDecay = {
                mode = cfg.Mode == 'shorten' and 'shorten' or 'rise',
                percent = math.floor(num(cfg.Percent)),
                hours = math.floor(num(cfg.Hours, 1)),
                maxPercent = math.floor(num(cfg.MaxIncreasePercent)),
                account = cfg.Account == 'cash' and 'cash' or 'bank',
            }
        end
    end
end

return Decay
