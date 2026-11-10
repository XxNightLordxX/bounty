--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/org/funds.lua                   ║
    ║     The organisation's money: Renewed-Banking's account, or a ledger      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- With Config.Organisation.Funds = 'auto' and Renewed-Banking started, the
--- funds are its society account for the job (createJobAccount once, then
--- getAccountMoney / addAccountMoney / removeAccountMoney, and
--- handleTransaction for its history). Otherwise, or with 'internal', they
--- are this resource's own ledger (crimson_org_funds): the balance is the
--- sum of its rows.
---
--- Either way every movement is one ledger row, by a reference written once
--- (Storage.insertOrgRowOnce): a cut by its escrow line, a withdrawal by
--- the request that made it. A second credit or debit under a reference
--- already written moves nothing and answers as the first did, so a retry,
--- a double click or a restart never pays twice.
---
--- Renewed-Banking takes a negative amount to add or remove without a word
--- (it validates nothing), so every amount is a whole number above zero
--- here before it is asked anything. Credit order: the row first, then the
--- account, the row taken back if the account refuses. Debit order: the
--- account first (it refuses a shortfall), then the row.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Funds = {}

local Storage, Audit

--- The internal balance by organisation id, and the references written
--- (so a repeat is answered without a read): [org] = n; [ref] = row.
local balances, known = {}, {}

--- Whether the ledger was read whole (Funds.load): every reference this
--- process could have written is in `known` then, and none is asked again.
local loaded = false

--- References being written right now, so two requests for one never
--- interleave across a database await.
local inFlight = {}

local RB = 'Renewed-Banking'

function Funds.init(deps)
    Storage, Audit = deps.storage, deps.audit
    balances, known, inFlight, loaded = {}, {}, {}, false
end

--- Whether Renewed-Banking holds the funds now.
---@return boolean
function Funds.usesBank()
    local mode = type(Config.Organisation) == 'table' and Config.Organisation.Funds or 'auto'
    return mode ~= 'internal' and GetResourceState(RB) == 'started'
end

--- A whole number of dollars above zero, or nil.
---@param value any
---@return integer|nil
function Funds.amount(value)
    if type(value) ~= 'number' and type(value) ~= 'string' then return nil end
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    if n ~= math.floor(n) or n <= 0 or n > 2000000000 then return nil end
    return math.floor(n)
end

--- Read the ledger once, at start: the internal balance and every
--- reference already written.
---@param org table
---@return table[] rows newest first
function Funds.load(org)
    local rows = Storage.readOrgRows('funds', org.id) or {}
    local total = 0
    for i = 1, #rows do
        total = total + (math.floor(tonumber(rows[i].amount) or 0))
        known[rows[i].id] = rows[i]
    end
    balances[org.id] = total
    loaded = true
    table.sort(rows, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then return (a.created_at or 0) > (b.created_at or 0) end
        return tostring(a.id) > tostring(b.id)
    end)
    return rows
end

--- Make sure Renewed-Banking has the job's account. Idempotent there.
function Funds.ensureAccount(org)
    if not Funds.usesBank() then return true end
    local ok, err = pcall(function()
        return exports[RB]:CreateJobAccount({ name = org.job, label = org.label or org.job }, 0)
    end)
    if not ok then
        Log.problem(('warning: Renewed-Banking would not make the %s account: %s; the funds are '
            .. 'read from it all the same'):format(org.job, tostring(err)))
    end
    return ok
end

--- The balance now.
---@param org table
---@return integer|nil
function Funds.balance(org)
    if Funds.usesBank() then
        local ok, money = pcall(function() return exports[RB]:getAccountMoney(org.job) end)
        if not ok or type(money) ~= 'number' then return nil end
        return math.floor(money)
    end
    return balances[org.id] or 0
end

--- What the funds already took of one escrow line (its cut), from what
--- this process knows: no read, so the money path asks it freely.
---@param lineId string|nil
---@return integer
function Funds.taken(lineId)
    local row = type(lineId) == 'string' and known['cut:' .. lineId] or nil
    return row and math.max(0, math.floor(tonumber(row.amount) or 0)) or 0
end

--- The row written under a reference, if any.
---@param ref string
---@return table|nil
function Funds.byRef(ref)
    if known[ref] then return known[ref] end
    if loaded then return nil end
    local row = Storage.readOrgRow and Storage.readOrgRow('funds', ref) or nil
    if row then known[ref] = row end
    return row
end

local function history(org, title, amount, actor, kind)
    if not Funds.usesBank() then return end
    pcall(function()
        return exports[RB]:handleTransaction(org.job, title, amount, tostring(kind),
            tostring(actor or 'crimson-hitman'), org.job, amount > 0 and 'deposit' or 'withdraw')
    end)
end

--- Put money into the funds, once per reference.
---@param org table
---@param amount integer above zero
---@param spec table { ref, kind, actor, reason, contract }
---@return boolean ok
---@return string|nil err 'invalid' | 'busy' | 'refused'
---@return boolean|nil repeated true when the reference was already written
function Funds.credit(org, amount, spec)
    amount = Funds.amount(amount)
    if not amount or type(spec) ~= 'table' or type(spec.ref) ~= 'string' then return false, 'invalid' end
    local ref = spec.ref:sub(1, 96)
    local before = Funds.byRef(ref)
    if before then return (tonumber(before.amount) or 0) > 0, nil, true end
    if inFlight[ref] then return false, 'busy' end
    inFlight[ref] = true
    local row = { id = ref, org_id = org.id, kind = spec.kind or 'credit', amount = amount,
        actor = spec.actor, reason = spec.reason, contract_id = spec.contract, created_at = os.time() }
    local wrote, inserted = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote or not inserted then
        inFlight[ref] = nil
        return false, wrote and 'busy' or 'refused', wrote and true or nil
    end
    if Funds.usesBank() then
        local ok, added = pcall(function() return exports[RB]:addAccountMoney(org.job, amount) end)
        if not ok or not added then
            pcall(Storage.deleteOrgRow, 'funds', ref)
            inFlight[ref] = nil
            Log.debug(('Renewed-Banking refused %d into %s: %s'):format(amount, org.job, tostring(added)))
            return false, 'refused'
        end
        history(org, spec.title or 'Organisation', amount, spec.actor, spec.kind)
    else
        balances[org.id] = (balances[org.id] or 0) + amount
    end
    known[ref] = row
    inFlight[ref] = nil
    return true
end

--- Take money out of the funds, once per reference. Refused, moving
--- nothing, for more than the balance.
---@return boolean ok
---@return string|nil err 'invalid' | 'busy' | 'short' | 'refused'
---@return boolean|nil repeated
function Funds.debit(org, amount, spec)
    amount = Funds.amount(amount)
    if not amount or type(spec) ~= 'table' or type(spec.ref) ~= 'string' then return false, 'invalid' end
    local ref = spec.ref:sub(1, 96)
    local before = Funds.byRef(ref)
    if before then return (tonumber(before.amount) or 0) < 0, nil, true end
    if inFlight[ref] then return false, 'busy' end
    inFlight[ref] = true
    local function done(...) inFlight[ref] = nil return ... end
    if Funds.usesBank() then
        local balance = Funds.balance(org)
        if not balance or balance < amount then return done(false, 'short') end
        local ok, removed = pcall(function() return exports[RB]:removeAccountMoney(org.job, amount) end)
        if not ok or not removed then return done(false, ok and 'short' or 'refused') end
        history(org, spec.title or 'Organisation', -amount, spec.actor, spec.kind)
    else
        if (balances[org.id] or 0) < amount then return done(false, 'short') end
    end
    local row = { id = ref, org_id = org.id, kind = spec.kind or 'debit', amount = -amount,
        actor = spec.actor, reason = spec.reason, contract_id = spec.contract, created_at = os.time() }
    local wrote, inserted = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote or not inserted then
        -- The money left the account and the row would not be written: put
        -- the money back rather than lose it.
        if Funds.usesBank() then
            pcall(function() return exports[RB]:addAccountMoney(org.job, amount) end)
        end
        Audit.financial('org_funds_unrecorded', spec.actor, spec.contract, { ref = ref, amount = amount })
        return done(false, 'refused')
    end
    if not Funds.usesBank() then balances[org.id] = (balances[org.id] or 0) - amount end
    known[ref] = row
    return done(true)
end

--- The ledger, newest first, a page at a time.
---@param org table
---@param limit integer
---@return table[]
function Funds.ledger(org, limit)
    local rows = Storage.readOrgRows('funds', org.id) or {}
    table.sort(rows, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then return (a.created_at or 0) > (b.created_at or 0) end
        return tostring(a.id) > tostring(b.id)
    end)
    local out = {}
    for i = 1, math.min(#rows, limit or 50) do
        local r = rows[i]
        out[#out + 1] = { kind = r.kind, amount = math.floor(tonumber(r.amount) or 0), at = r.created_at,
            reason = r.reason, contract = r.contract_id, actor = r.actor }
    end
    return out
end

--- What one actor took out under one kind since a moment (a day's cap).
---@return integer
function Funds.spentSince(org, actor, kind, since)
    local total = 0
    for _, row in pairs(known) do
        if row.org_id == org.id and row.actor == actor and row.kind == kind
            and (tonumber(row.created_at) or 0) > since then
            total = total + math.abs(math.floor(tonumber(row.amount) or 0))
        end
    end
    return total
end

Funds.copy = Util.copy

return Funds
