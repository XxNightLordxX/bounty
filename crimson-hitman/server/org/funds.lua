--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/org/funds.lua                   ║
    ║     The organisation's money: Renewed-Banking's account, or a ledger      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Where the funds are kept is chosen once, the first time the
--- organisation is read, and kept by the store (staff meta
--- 'org_funds_backend': 1 this resource's ledger, 2 Renewed-Banking): with
--- Config.Organisation.Funds = 'auto' and Renewed-Banking installed, its
--- society account for the job (createJobAccount once, then getAccountMoney
--- / addAccountMoney / removeAccountMoney, and handleTransaction for its
--- history); otherwise, or with 'internal', this resource's own ledger
--- (crimson_org_funds), whose balance is the sum of the rows written under
--- it. Nothing moves the funds from one to the other but staff
--- (orgFundsBackend, Funds.switch), which carries the balance across in two
--- rows. While the bank is chosen and Renewed-Banking is not started, every
--- movement is refused ('bank_down') and the balance is unknown: nothing is
--- paid out of, or into, a ledger the bank does not see.
---
--- Either way every movement is one ledger row, by a reference written once
--- (Storage.insertOrgRowOnce), marked with the backend it moved (`backend`):
--- a cut by its escrow line, a withdrawal by the request that made it. A
--- second credit or debit under a reference already written moves nothing
--- and answers as the first did, so a retry, a double click or a restart
--- never pays twice.
---
--- Renewed-Banking takes a negative amount to add or remove without a word
--- (it validates nothing), so every amount is a whole number above zero
--- here before it is asked anything. Credit order: the row first, then the
--- account, the row taken back if the account refuses. Debit order: the
--- money reserved (the ledger's balance, or the account's own refusal of a
--- shortfall) before any await, then the row, the money put back if the row
--- is not written.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')
local Geo = CrimsonBoot.requireShared('geo')

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

--- Debits reserved and not yet written, so a day's cap counts them:
--- [ref] = { org_id, actor, kind, amount, created_at }.
local pending = {}

--- Cut references read from the store and not found, so a line asked about
--- again is not read again: [ref] = true. Only this process writes them.
local absent = {}

--- The backend chosen ('internal' | 'bank'), nil until the first read.
local backend = nil

--- Whether Renewed-Banking was asked to make the job's account, this
--- process, once it was started.
local accountMade = false

--- A backend switch running: every movement waits ('busy').
local switching = false

local RB = 'Renewed-Banking'
local META = 'org_funds_backend'
local CODE = { internal = 1, bank = 2 }

Funds.META = META

function Funds.init(deps)
    Storage, Audit = deps.storage, deps.audit
    balances, known, inFlight, pending, absent, loaded = {}, {}, {}, {}, {}, false
    backend, accountMade, switching = nil, false, false
end

--- Whether Renewed-Banking is installed at all (started, starting, or
--- stopped and waiting for its ensure line).
local function bankInstalled()
    local state = GetResourceState(RB)
    return state ~= nil and state ~= 'missing' and state ~= 'unknown'
end

local function bankStarted() return GetResourceState(RB) == 'started' end

--- The backend kept by the store, if one is.
local function keptBackend()
    if not (Storage and Storage.readStaffMeta) then return nil end
    local ok, meta = pcall(Storage.readStaffMeta)
    local code = ok and type(meta) == 'table' and tonumber(meta[META]) or nil
    return code == CODE.bank and 'bank' or code == CODE.internal and 'internal' or nil
end

--- Choose the backend once: the one the store keeps, or (the first time)
--- the one Config.Organisation.Funds names, kept from then on.
---@return string 'internal' | 'bank'
function Funds.pick()
    local kept = keptBackend()
    if not kept then
        local mode = type(Config.Organisation) == 'table' and Config.Organisation.Funds or 'auto'
        local want = (mode ~= 'internal' and bankInstalled()) and 'bank' or 'internal'
        local ok, code = false, nil
        if Storage and Storage.claimStaffMeta then ok, code = pcall(Storage.claimStaffMeta, META, CODE[want]) end
        kept = ok and (tonumber(code) == CODE.bank and 'bank' or tonumber(code) == CODE.internal and 'internal') or want
    end
    backend = kept
    local mode = type(Config.Organisation) == 'table' and Config.Organisation.Funds or 'auto'
    if kept == 'bank' and mode == 'internal' then
        Log.problem('note: Config.Organisation.Funds is internal, but the organisation\'s funds are kept in '
            .. 'Renewed-Banking: staff move them with the panel\'s funds backend switch (orgFundsBackend)')
    end
    return kept
end

--- The backend in force: 'internal' or 'bank'.
---@return string
function Funds.backend()
    return backend or Funds.pick()
end

--- Whether Renewed-Banking holds the funds (chosen at the first read).
---@return boolean
function Funds.usesBank()
    return Funds.backend() == 'bank'
end

--- Whether the funds can move now: always on the ledger; with the bank,
--- only while Renewed-Banking is started.
---@return boolean
function Funds.ready()
    if not Funds.usesBank() then return true end
    return bankStarted()
end

--- A whole number of dollars above zero, or nil.
---@param value any
---@return integer|nil
function Funds.amount(value)
    if type(value) ~= 'number' and type(value) ~= 'string' then return nil end
    local n = Geo.finite(value)
    if not n then return nil end
    if n ~= math.floor(n) or n <= 0 or n > 2000000000 then return nil end
    return math.floor(n)
end

--- Read the ledger once, at start: the internal balance (the rows written
--- under the ledger only, never the bank's) and every reference already
--- written. A row from before rows were marked is marked once, with the
--- backend chosen at this first read, and kept so.
---@param org table
---@return table[] rows newest first
function Funds.load(org)
    if not backend then Funds.pick() end
    local rows = Storage.readOrgRows('funds', org.id) or {}
    local total = 0
    for i = 1, #rows do
        local row = rows[i]
        if row.backend ~= 'internal' and row.backend ~= 'bank' then
            row.backend = backend
            pcall(Storage.writeOrgRow, 'funds', row)
        end
        if row.backend == 'internal' then total = total + (math.floor(tonumber(row.amount) or 0)) end
        known[row.id] = row
    end
    balances[org.id] = total
    loaded = true
    table.sort(rows, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then return (a.created_at or 0) > (b.created_at or 0) end
        return tostring(a.id) > tostring(b.id)
    end)
    return rows
end

--- Make sure Renewed-Banking has the job's account, once it is started.
--- Idempotent there.
function Funds.ensureAccount(org)
    if not Funds.usesBank() or not bankStarted() then return true end
    local ok, err = pcall(function()
        return exports[RB]:CreateJobAccount({ name = org.job, label = org.label or org.job }, 0)
    end)
    if not ok then
        Log.problem(('warning: Renewed-Banking would not make the %s account: %s; the funds are '
            .. 'read from it all the same'):format(org.job, tostring(err)))
    end
    accountMade = true
    return ok
end

--- The bank's balance, or nil while it cannot be read.
local function bankBalance(org)
    local ok, money = pcall(function() return exports[RB]:getAccountMoney(org.job) end)
    if not ok or type(money) ~= 'number' then return nil end
    return math.floor(money)
end

--- The balance now: nil while the bank chosen is not started.
---@param org table
---@return integer|nil
function Funds.balance(org)
    if Funds.usesBank() then
        if not bankStarted() then return nil end
        return bankBalance(org)
    end
    return balances[org.id] or 0
end

--- What the funds already took of one escrow line (its cut). From memory
--- where the ledger was read; otherwise (the organisation off since the
--- start) read once from the store, so a cut taken before a restart is
--- never paid to the member as well.
---@param lineId string|nil
---@return integer
function Funds.taken(lineId)
    if type(lineId) ~= 'string' then return 0 end
    local ref = ('cut:' .. lineId):sub(1, 96)
    local row = known[ref]
    if not row and not loaded and not absent[ref] and Storage and Storage.readOrgRow then
        local ok, found = pcall(Storage.readOrgRow, 'funds', ref)
        if ok and type(found) == 'table' then
            known[ref], row = found, found
        elseif ok then
            absent[ref] = true
        end
    end
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

--- The kinds of row that move nothing: markers written beside a movement
--- to say what became of it (a salary paid on to the member's bank, or left
--- for staff), amount 0, so no balance or sum counts them.
Funds.MARKS = { salary_paid = true, salary_review = true }

--- Write a marker once per reference (Funds.MARKS): true when it is
--- written, or was already.
---@param org table
---@param ref string
---@param spec table { kind, actor, reason }
---@return boolean
function Funds.mark(org, ref, spec)
    if type(ref) ~= 'string' or type(spec) ~= 'table' or not Funds.MARKS[spec.kind] then return false end
    ref = ref:sub(1, 96)
    if known[ref] then return true end
    local row = { id = ref, org_id = org.id, kind = spec.kind, amount = 0, actor = spec.actor,
        reason = spec.reason, created_at = os.time(), backend = Funds.backend() }
    local wrote = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote then return false end
    -- Inserted now, or there already: either way it is written.
    known[ref] = row
    absent[ref] = nil
    return true
end

local function history(org, title, amount, actor, kind)
    if not Funds.usesBank() then return end
    pcall(function()
        return exports[RB]:handleTransaction(org.job, title, amount, tostring(kind),
            tostring(actor or 'crimson-hitman'), org.job, amount > 0 and 'deposit' or 'withdraw')
    end)
end

--- Why the funds cannot move now: 'busy' (a switch), 'bank_down', or nil.
local function blocked(org)
    if switching then return 'busy' end
    if Funds.usesBank() then
        if not bankStarted() then return 'bank_down' end
        if not accountMade then Funds.ensureAccount(org) end
    end
    return nil
end

--- Put money into the funds, once per reference.
---@param org table
---@param amount integer above zero
---@param spec table { ref, kind, actor, reason, contract }
---@return boolean ok
---@return string|nil err 'invalid' | 'busy' | 'refused' | 'bank_down'
---@return boolean|nil repeated true when the reference was already written
function Funds.credit(org, amount, spec)
    amount = Funds.amount(amount)
    if not amount or type(spec) ~= 'table' or type(spec.ref) ~= 'string' then return false, 'invalid' end
    local ref = spec.ref:sub(1, 96)
    local before = Funds.byRef(ref)
    if before then return (tonumber(before.amount) or 0) > 0, nil, true end
    if inFlight[ref] then return false, 'busy' end
    local why = blocked(org)
    if why then return false, why end
    inFlight[ref] = true
    local bank = Funds.usesBank()
    local row = { id = ref, org_id = org.id, kind = spec.kind or 'credit', amount = amount,
        actor = spec.actor, reason = spec.reason, contract_id = spec.contract, created_at = os.time(),
        backend = bank and 'bank' or 'internal' }
    local wrote, inserted = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote or not inserted then
        inFlight[ref] = nil
        return false, wrote and 'busy' or 'refused', wrote and true or nil
    end
    if bank then
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
    absent[ref] = nil
    inFlight[ref] = nil
    return true
end

--- What one actor took out under one kind since a moment (a day's cap):
--- the rows written, and the debits reserved and not written yet.
---@return integer
function Funds.spentSince(org, actor, kind, since)
    local total = 0
    local function add(row)
        if row.org_id == org.id and row.actor == actor and row.kind == kind
            and (tonumber(row.created_at) or 0) > since then
            total = total + math.abs(math.floor(tonumber(row.amount) or 0))
        end
    end
    for _, row in pairs(known) do add(row) end
    for _, row in pairs(pending) do add(row) end
    return total
end

--- Take money out of the funds, once per reference. Refused, moving
--- nothing, for more than the balance, or past `spec.cap` ({ limit, since }:
--- what this actor took under this kind since then, reserved ones counted).
--- The money is reserved before anything is awaited, so two debits never
--- both pass one balance or one cap.
---@return boolean ok
---@return string|nil err 'invalid' | 'busy' | 'short' | 'refused' | 'bank_down' | 'limit'
---@return boolean|nil repeated
function Funds.debit(org, amount, spec)
    amount = Funds.amount(amount)
    if not amount or type(spec) ~= 'table' or type(spec.ref) ~= 'string' then return false, 'invalid' end
    local ref = spec.ref:sub(1, 96)
    local before = Funds.byRef(ref)
    if before then return (tonumber(before.amount) or 0) < 0, nil, true end
    if inFlight[ref] then return false, 'busy' end
    local why = blocked(org)
    if why then return false, why end
    -- From here to the reservation nothing is awaited: the cap, the balance
    -- and the reservation are one step.
    if type(spec.cap) == 'table' and Funds.spentSince(org, spec.actor, spec.kind or 'debit',
        tonumber(spec.cap.since) or 0) + amount > (tonumber(spec.cap.limit) or 0) then
        return false, 'limit'
    end
    local bank = Funds.usesBank()
    if not bank and (balances[org.id] or 0) < amount then return false, 'short' end
    inFlight[ref] = true
    local now = os.time()
    pending[ref] = { org_id = org.id, actor = spec.actor, kind = spec.kind or 'debit', amount = amount,
        created_at = now }
    if not bank then balances[org.id] = (balances[org.id] or 0) - amount end
    local function done(ok, err)
        inFlight[ref], pending[ref] = nil, nil
        if not ok and not bank then balances[org.id] = (balances[org.id] or 0) + amount end
        return ok, err
    end
    if bank then
        local balance = bankBalance(org)
        if not balance or balance < amount then return done(false, 'short') end
        local ok, removed = pcall(function() return exports[RB]:removeAccountMoney(org.job, amount) end)
        if not ok or not removed then return done(false, ok and 'short' or 'refused') end
        history(org, spec.title or 'Organisation', -amount, spec.actor, spec.kind)
    end
    local row = { id = ref, org_id = org.id, kind = spec.kind or 'debit', amount = -amount,
        actor = spec.actor, reason = spec.reason, contract_id = spec.contract, created_at = now,
        backend = bank and 'bank' or 'internal' }
    local wrote, inserted = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote or not inserted then
        -- The money left the account and the row would not be written: put
        -- the money back rather than lose it (the ledger's reservation is
        -- given back by done).
        if bank then
            pcall(function() return exports[RB]:addAccountMoney(org.job, amount) end)
        end
        Audit.financial('org_funds_unrecorded', spec.actor, spec.contract, { ref = ref, amount = amount })
        return done(false, 'refused')
    end
    known[ref] = row
    return done(true)
end

--- Staff only (orgFundsBackend): move the funds to the other backend, the
--- balance carried across in two rows (out of the one, into the other).
--- Both sides need Renewed-Banking started; leaving the bank while it is
--- not, `abandon` switches with nothing carried (its account keeps what it
--- holds, said on the record). Nothing else moves the funds meanwhile.
---@param org table
---@param to string 'internal' | 'bank'
---@param spec table { actor, abandon }
---@return boolean ok
---@return string|nil err 'invalid' | 'already' | 'busy' | 'bank_down' | 'refused'
---@return table|nil done { from, to, carried, abandoned }
function Funds.switch(org, to, spec)
    spec = type(spec) == 'table' and spec or {}
    if to ~= 'internal' and to ~= 'bank' then return false, 'invalid' end
    local from = Funds.backend()
    if from == to then return false, 'already' end
    if switching or next(inFlight) then return false, 'busy' end
    local abandoned = false
    if not bankStarted() then
        if to == 'bank' or not spec.abandon then return false, 'bank_down' end
        abandoned = true
    end
    switching = true
    local function finish(ok, err, extra)
        switching = false
        return ok, err, extra
    end
    local stamp = ('%d:%d'):format(os.time(), math.random(1000, 9999))
    local carried = 0
    local function write(id, b, amount)
        return pcall(Storage.insertOrgRowOnce, 'funds', { id = ('switch:%s:%s'):format(stamp, id):sub(1, 96),
            org_id = org.id, kind = 'switch', amount = amount, actor = spec.actor, reason = from .. '>' .. to,
            created_at = os.time(), backend = b })
    end
    if to == 'bank' then
        Funds.ensureAccount(org)
        carried = math.max(0, balances[org.id] or 0)
        if carried > 0 then
            local wrote, inserted = write('out', 'internal', -carried)
            if not wrote or not inserted then return finish(false, 'refused') end
            local ok, added = pcall(function() return exports[RB]:addAccountMoney(org.job, carried) end)
            if not ok or not added then
                pcall(Storage.deleteOrgRow, 'funds', ('switch:%s:out'):format(stamp))
                return finish(false, 'refused')
            end
            balances[org.id] = (balances[org.id] or 0) - carried
            write('in', 'bank', carried)
            history(org, 'Moved from the ledger', carried, spec.actor, 'switch')
        end
    elseif not abandoned then
        carried = math.max(0, bankBalance(org) or 0)
        if carried > 0 then
            local ok, removed = pcall(function() return exports[RB]:removeAccountMoney(org.job, carried) end)
            if not ok or not removed then return finish(false, 'refused') end
            history(org, 'Moved to the ledger', -carried, spec.actor, 'switch')
            write('out', 'bank', -carried)
            local wrote, inserted = write('in', 'internal', carried)
            if not wrote or not inserted then
                pcall(function() return exports[RB]:addAccountMoney(org.job, carried) end)
                return finish(false, 'refused')
            end
            balances[org.id] = (balances[org.id] or 0) + carried
        end
    end
    local wrote = Storage.writeStaffMeta and pcall(Storage.writeStaffMeta, META, CODE[to])
    if not wrote then
        Log.problem('warning: the funds backend switch was not kept by the store; it holds until the next start')
    end
    backend = to
    accountMade = false
    -- Every row read again from the store, the balance with them.
    loaded = false
    known, absent = {}, {}
    Funds.load(org)
    return finish(true, nil, { from = from, to = to, carried = carried, abandoned = abandoned or nil })
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
    for i = 1, #rows do
        if #out >= (limit or 50) then break end
        local r = rows[i]
        -- Markers move nothing and are not shown.
        if not Funds.MARKS[r.kind] then
            out[#out + 1] = { kind = r.kind, amount = math.floor(tonumber(r.amount) or 0), at = r.created_at,
                reason = r.reason, contract = r.contract_id, actor = r.actor }
        end
    end
    return out
end

Funds.copy = Util.copy

return Funds
