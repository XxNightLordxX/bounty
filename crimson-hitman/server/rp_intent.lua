--- Proof of intent (Config.Roleplay.ProofOfIntent, README, Optional features).
---
--- With it on, a payout is held, never refused: the completion stands, and
--- the money waits until the hitman has shown they worked the contract in
--- character. That is MinMessages messages from them to the client in the
--- contract's thread, or a live handover, or a meeting point set on it. What
--- is still missing is said on their receipt and on their card, and after
--- HoldMaxMinutes the payout is released anyway, so money is never stuck.
---
--- The hold is a gate on the escrow's own give (Escrow.holdBack): a held
--- line stays in escrow, owed to the hitman and queued, exactly as a payout
--- that would not fit in their pockets does. The retry that gives those
--- (every 30 seconds while they are online, and at their login) gives this
--- one once the gate opens. So nothing here moves money: it only says not
--- yet, and the escrow's conservation is the escrow's.
---
--- A hold is kept in the store (crimson_rp_rows, kind 'intent') so a
--- restart neither forgets it nor releases it early. Started, released and
--- timed out are all audited.

local Util = CrimsonBoot.requireShared('util')

local Intent = {}

local Storage, Audit, Notify, Escrow

--- Holds in force, by contract and hitman. [contractId .. ':' .. cid] = row
local holds = {}
local loaded = false

--- Whether a proof check found it met lately, so a retry pass over a queue
--- does not read the thread once per line. [key] = { at, met, missing }
local recent = {}
local RECENT_SECONDS = 5

local KIND = 'intent'

local function cfg()
    local rp = type(Config.Roleplay) == 'table' and Config.Roleplay or {}
    return type(rp.ProofOfIntent) == 'table' and rp.ProofOfIntent or {}
end

--- Whether the feature is on now.
---@return boolean
function Intent.enabled()
    return cfg().Enabled == true
end

local function keyOf(contractId, cid)
    return tostring(contractId) .. ':' .. tostring(cid)
end

function Intent.init(deps)
    Storage, Audit, Notify, Escrow = deps.storage, deps.audit, deps.notify, deps.escrow
    holds, recent, loaded = {}, {}, false
    -- The escrow asks before every give (Escrow.deliver).
    if Escrow then Escrow.holdBack = Intent.holds end
    -- And staff settling a line it holds are told until when (Admin.settleLine).
    if Escrow then Escrow.holdUntil = Intent.releasesAt end
    -- And the claim tells this module a payout is about to be released.
    if deps.contracts then
        deps.contracts.intentOnClaim = Intent.onClaim
        deps.contracts.intentAfterClaim = Intent.afterClaim
    end
    -- The hitman's card says what is missing while one of theirs is held.
    if deps.projection and deps.projection.extenders then
        deps.projection.extenders.intent = function(out, contract, viewerCid, role)
            if role ~= 'hitman' then return end
            out.intentHold = Intent.view(contract.id, viewerCid)
            -- The rule, on the card while it can still be met: a payout
            -- here is held unless they show intent. Said before it bites,
            -- not first on the receipt that holds it.
            if not out.intentHold then out.intentRule = Intent.rule(contract) end
        end
    end
end

--- Read the holds from the store, once.
local function load()
    if loaded then return end
    loaded = true
    local ok, rows = pcall(Storage.readRpRows, KIND)
    if not ok or type(rows) ~= 'table' then
        loaded = false
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if row.contract_id and row.hitman_cid then holds[keyOf(row.contract_id, row.hitman_cid)] = row end
    end
end
Intent.load = load

--- How many messages the hitman wrote in the contract's thread with its
--- client. Read from the store, as kept (Config.Relay.MaxMessagesPerThread).
---@return integer
local function messagesSent(contractId, hitmanCid)
    local ok, rows = pcall(Storage.readMessages, contractId, contractId .. '|' .. hitmanCid)
    if not ok or type(rows) ~= 'table' then return 0 end
    local n = 0
    for i = 1, #rows do
        if rows[i].from_cid == hitmanCid then n = n + 1 end
    end
    return n
end
Intent.messagesSent = messagesSent

--- Whether nothing can be done on this contract any more to show intent:
--- it is closed, or the payout being claimed closes it (the last one). Its
--- thread is shut and its meeting point goes with it (Comms.context refuses
--- a closed contract), so the only way the hold ends is its time.
---@param contract table
---@param claiming boolean|nil the payout of contract.next_slot is being claimed now
---@return boolean
local function closedFor(contract, claiming)
    if CH.TERMINAL[contract.state] then return true end
    return claiming == true
        and (tonumber(contract.next_slot) or 1) >= (tonumber(contract.payout_slots) or 1)
end

--- The rule a hitman's card states while the contract is live and nothing
--- is held yet: how many messages, or a live handover, or a meeting point.
--- Nil with the feature off, nothing asked of them, or the contract closed
--- or paying only for a live handover (which is itself the proof).
---@param contract table
---@return table|nil { messages }
function Intent.rule(contract)
    if not Intent.enabled() or type(contract) ~= 'table' then return nil end
    if CH.TERMINAL[contract.state] then return nil end
    if Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE then
        return nil
    end
    if contract.meeting_x ~= nil and contract.meeting_y ~= nil then return nil end
    local want = math.floor(tonumber(cfg().MinMessages) or 0)
    if want <= 0 then return nil end
    return { messages = want }
end

--- Whether the hitman has shown intent on this contract, and if not, what is
--- missing, in words for them. Nothing is missing that cannot be done: on a
--- contract that is closed, or that this payout closes, the third answer is
--- true and there is no `missing` (the hold runs out on its own).
---@param contract table
---@param hitmanCid string
---@param fulfilment string|nil the completion being paid, where known
---@param claiming boolean|nil a payout is being claimed now (Intent.onClaim)
---@return boolean met
---@return string|nil missing
---@return boolean|nil closed
function Intent.proof(contract, hitmanCid, fulfilment, claiming)
    if fulfilment == CH.FULFILMENT.KIDNAPPING then return true end
    if contract.meeting_x ~= nil and contract.meeting_y ~= nil then return true end
    local want = math.floor(tonumber(cfg().MinMessages) or 0)
    if want <= 0 then return true end
    local sent = messagesSent(contract.id, hitmanCid)
    if sent >= want then return true end
    if closedFor(contract, claiming) then return false, nil, true end
    local left = want - sent
    return false, ('%d more message%s to the person who placed it in the contract thread, '
        .. 'a live handover, or a meeting point set'):format(left, left == 1 and '' or 's')
end

--- A claim is about to release a payout to this hitman (Contracts.claimSlot,
--- under its lock). Off, or proof shown: nothing is held, and nil. Otherwise
--- the hold is started (or the one already on is kept) and returned.
---@return table|nil hold { missing, minutes }
function Intent.onClaim(contract, hitmanCid, fulfilment)
    if not Intent.enabled() or type(contract) ~= 'table' then return nil end
    load()
    local met, missing, closed = Intent.proof(contract, hitmanCid, fulfilment, true)
    if met then return nil end
    local key = keyOf(contract.id, hitmanCid)
    local row = holds[key]
    if not row then
        -- Held from here (the escrow's give asks holds[] as the claim
        -- releases), and written to the store only once the claim has gone
        -- through (Intent.afterClaim): a claim refused after this point
        -- left a row for a payout that never happened.
        row = { id = 'intent:' .. key, kind = KIND, contract_id = contract.id,
                hitman_cid = hitmanCid, since = os.time(), unwritten = true, missing = missing }
        holds[key] = row
    end
    recent[key] = { at = os.time(), met = false, missing = missing, closed = closed }
    local minutes = math.floor(tonumber(cfg().HoldMaxMinutes) or 0)
    return { missing = missing, closed = closed or nil, minutes = minutes }
end

--- The claim a hold was started for has ended (Contracts.claimSlot): gone
--- through, or raised part-way (its payout may be owed and recovered), and
--- the hold is written down; refused, and a hold it started goes, with
--- nothing written. A hold already written is left as it is either way.
---@param contractId string
---@param hitmanCid string
---@param claimed boolean
function Intent.afterClaim(contractId, hitmanCid, claimed)
    local key = keyOf(contractId, hitmanCid)
    local row = holds[key]
    if not row or not row.unwritten then return end
    if not claimed then
        holds[key], recent[key] = nil, nil
        return
    end
    row.unwritten = nil
    local missing = row.missing
    row.missing = nil
    local ok, err = pcall(Storage.writeRpRow, row)
    if not ok then
        Audit.rejected('intent_hold_not_written', hitmanCid, contractId, { error = tostring(err) })
    end
    Audit.financial('intent_hold_started', hitmanCid, contractId, { missing = missing })
end

--- Release a hold: the row goes, the release is audited, the hitman is told,
--- and the escrow's retry is woken for them so the payout follows at once.
local function release(key, why)
    local row = holds[key]
    if not row then return end
    holds[key], recent[key] = nil, nil
    pcall(Storage.deleteRpRow, row.id)
    Audit.financial('intent_hold_released', row.hitman_cid, row.contract_id, { why = why })
    if Escrow and Escrow.noteWaiting then Escrow.noteWaiting(row.hitman_cid, true) end
    if Notify and Notify.tellOrKeep then
        pcall(Notify.tellOrKeep, row.hitman_cid, 'Payout released',
            why == 'proof' and 'You showed intent on the contract: your held payout is being handed over.'
                or 'Your held payout is being handed over.', { bypassBudget = true }, row.contract_id)
    end
end

--- Whether the hold on this hitman's payout on this contract has run its
--- course: the switch off, its time up, or proof shown since. Releases it if
--- so. Answers whether it still holds.
---@return boolean holding
---@return string|nil missing
---@return boolean|nil closed nothing left to do but wait
local function stillHolding(key, row)
    if not Intent.enabled() then
        release(key, 'switched_off')
        return false
    end
    local minutes = math.floor(tonumber(cfg().HoldMaxMinutes) or 0)
    if os.time() - (tonumber(row.since) or 0) >= minutes * 60 then
        release(key, 'timeout')
        return false
    end
    local seen = recent[key]
    if seen and os.time() - seen.at < RECENT_SECONDS then
        return not seen.met, seen.missing, seen.closed
    end
    local contract = Storage.readContract(row.contract_id)
    local met, missing, closed = true, nil, nil
    if contract then met, missing, closed = Intent.proof(contract, row.hitman_cid) end
    recent[key] = { at = os.time(), met = met, missing = missing, closed = closed }
    if met then
        release(key, 'proof')
        return false
    end
    return true, missing, closed
end

--- The escrow's gate (Escrow.holdBack): whether this give to this recipient
--- waits. Only a payout to the hitman a hold names (the baseline and the
--- bonus of the contract), never a refund, a stake or anybody else's line.
---@param recipientCid string
---@param line table
---@return boolean wait
function Intent.holds(recipientCid, line)
    if type(line) ~= 'table' then return false end
    if line.portion ~= CH.PORTION.BASELINE and line.portion ~= CH.PORTION.BONUS then return false end
    if not loaded then load() end
    -- The store could not be read: whether a hold stands is unknown, so
    -- the payout waits until a read succeeds. Answered 'not held', a hold
    -- written before a restart paid out the moment the store hiccupped.
    if not loaded then return Intent.enabled() end
    local key = keyOf(line.contract_id, recipientCid)
    local row = holds[key]
    if not row then return false end
    return (stillHolding(key, row))
end

--- When the hold on this give is released anyway (os.time()), or nil when
--- nothing holds it: for staff who settle a held line and are told why it
--- did not go (Admin.settleLine), rather than only that it is queued.
---@param recipientCid string
---@param line table
---@return integer|nil releasesAt
function Intent.releasesAt(recipientCid, line)
    if not Intent.holds(recipientCid, line) then return nil end
    if not loaded then return nil end
    local row = holds[keyOf(line.contract_id, recipientCid)]
    if not row then return nil end
    local minutes = math.floor(tonumber(cfg().HoldMaxMinutes) or 0)
    return (tonumber(row.since) or 0) + minutes * 60
end

--- What the hitman's card says while a payout of theirs on this contract is
--- held: what is missing, and in how many minutes it is released anyway.
---@return table|nil { missing, closed, minutesLeft }
function Intent.view(contractId, cid)
    if not loaded then load() end
    local key = keyOf(contractId, cid)
    local row = holds[key]
    if not row then return nil end
    local holding, missing, closed = stillHolding(key, row)
    if not holding then return nil end
    local minutes = math.floor(tonumber(cfg().HoldMaxMinutes) or 0)
    local left = math.max(0, (tonumber(row.since) or 0) + minutes * 60 - os.time())
    return { missing = missing, closed = closed or nil,
             minutesLeft = math.max(1, math.ceil(left / 60)) }
end

--- Every payout of this hitman's held now, newest first, for the note at the
--- top of Mine (a contract that completed is no longer on a card).
---@return table[] { ref, missing, closed, minutesLeft }
function Intent.heldFor(cid)
    if not loaded then load() end
    local out = {}
    local keys = {}
    for key, row in pairs(holds) do
        if row.hitman_cid == cid then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for i = 1, #keys do
        local row = holds[keys[i]]
        local seen = row and Intent.view(row.contract_id, cid)
        if seen then
            out[#out + 1] = { ref = row.contract_id, missing = seen.missing,
                              closed = seen.closed, minutesLeft = seen.minutesLeft }
        end
    end
    return out
end

--- The tick: holds whose time is up are released even while nobody gives,
--- so a hitman who is away gets the payout at their next login.
---@return integer released
function Intent.sweep()
    if not loaded then load() end
    local released = 0
    local keys = {}
    for key in pairs(holds) do keys[#keys + 1] = key end
    for i = 1, #keys do
        local row = holds[keys[i]]
        if row and not stillHolding(keys[i], row) then released = released + 1 end
    end
    return released
end

--- How many holds are in force (the diagnosis, the tests).
---@return integer
function Intent.count()
    if not loaded then load() end
    local n = 0
    for _ in pairs(holds) do n = n + 1 end
    return n
end

return Intent
