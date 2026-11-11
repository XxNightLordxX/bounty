CrimsonBoot.define('server.org.funds', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/org/funds.lua                   ║
    ║     The organisation's money: Renewed-Banking's account, or a ledger      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Where the funds are kept is chosen once, the first time any
--- organisation is read, and kept by the store (staff meta
--- 'org_funds_backend': 1 this resource's ledger, 2 Renewed-Banking), as
--- every organisation's backend until staff move one: each organisation
--- keeps its own from then on, in a marker row of its ledger
--- ('backend:<id>', kind 'backend', moving nothing). With
--- Config.Integrations.Banking = 'auto' and Renewed-Banking installed, its
--- society account for the job (createJobAccount once, then getAccountMoney
--- / addAccountMoney / removeAccountMoney, and handleTransaction for its
--- history, through server/adapters/banking/); otherwise, or with 'none',
--- this resource's own ledger
--- (crimson_org_funds), whose balance is the sum of the rows written under
--- it. Nothing moves the funds from one to the other but staff
--- (orgFundsBackend, Funds.switch), one organisation at a time, which
--- carries its balance across in two rows, kept on this machine from the
--- moment the money moves until the rows and the marker are written, so a
--- crash in between is finished at the next start (Funds.decideInterrupted).
--- While the bank is chosen and Renewed-Banking is not started, every
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
local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t


local Funds = {}

local Storage, Audit, Review

--- Markers a start found kept and could not write yet, by reference: what
--- they mark happened (Funds.willMark).
local markWaiting = {}

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

--- The backend chosen at the first read ('internal' | 'bank'), nil until
--- then: every organisation's until staff move one.
local defaultBackend = nil

--- Each organisation's own backend, by id, from its marker row (Funds.load).
local backends = {}

--- Whether Renewed-Banking was asked to make each job's account, this
--- process, once it was started: [org id] = true.
local accountMade = {}

--- A backend switch running, by organisation id: its movements wait ('busy').
local switching = {}

local META = 'org_funds_backend'
local CODE = { internal = 1, bank = 2 }

Funds.META = META

function Funds.init(deps)
    Storage, Audit, Review = deps.storage, deps.audit, deps.review
    markWaiting = {}
    balances, known, inFlight, pending, absent, loaded = {}, {}, {}, {}, {}, false
    defaultBackend, backends, accountMade, switching = nil, {}, {}, {}
    if Review and Review.DECIDERS then
        Review.DECIDERS.org_funds_interrupted = function(item) return Funds.decideInterrupted(item) end
        Review.DECIDERS.org_funds_give_unconfirmed = function(item) return Funds.decideGive(item) end
    end
end

--- Whether a banking adapter's resource is installed at all (started,
--- starting, or stopped and waiting for its ensure line).
local function installed(adapter)
    if type(adapter.installed) == 'function' then
        local ok, yes = pcall(adapter.installed)
        return ok and yes == true
    end
    return Integrations.up(adapter)
end

--- The banking adapter the funds use (server/adapters/banking/): the one
--- Config.Integrations.Banking names, or on 'auto' the first installed.
--- 'none' chooses the ledger (`choosing`); funds the store already keeps in
--- the bank are still reached through the first one, so staff can move
--- them back with the funds backend switch.
---@param choosing boolean|nil the first choice of backend
---@return table|nil
local function bankAdapter(choosing)
    local want = Integrations.choice('banking')
    if want == 'none' and choosing then return nil end
    if want ~= 'auto' and want ~= 'none' then return Integrations.adapter('banking', want) end
    local names = Integrations.names('banking')
    for i = 1, #names do
        local adapter = Integrations.adapter('banking', names[i])
        if installed(adapter) then return adapter end
    end
    return names[1] and Integrations.adapter('banking', names[1]) or nil
end

local function bankInstalled()
    local adapter = bankAdapter(true)
    return adapter ~= nil and installed(adapter)
end

local function bankStarted()
    local adapter = bankAdapter()
    return adapter ~= nil and Integrations.up(adapter)
end

--- The bank adapter while it is started; nil (and every call through it
--- raising inside its pcall, as an export of a stopped resource does)
--- otherwise.
local function Bank()
    local adapter = bankAdapter()
    return adapter and Integrations.up(adapter) and adapter or nil
end

--- The backend kept by the store, if one is.
local function keptBackend()
    if not (Storage and Storage.readStaffMeta) then return nil end
    local ok, meta = pcall(Storage.readStaffMeta)
    local code = ok and type(meta) == 'table' and tonumber(meta[META]) or nil
    return code == CODE.bank and 'bank' or code == CODE.internal and 'internal' or nil
end

--- Choose the first backend once: the one the store keeps, or (the first
--- time) the bank when Config.Integrations.Banking has one installed (the
--- ledger on 'none'), kept from then on. Every organisation's until staff
--- move it (its marker row, Funds.load).
---@return string 'internal' | 'bank'
function Funds.pick()
    local kept = keptBackend()
    if not kept then
        local want = bankInstalled() and 'bank' or 'internal'
        local ok, code = false, nil
        if Storage and Storage.claimStaffMeta then ok, code = pcall(Storage.claimStaffMeta, META, CODE[want]) end
        kept = ok and (tonumber(code) == CODE.bank and 'bank' or tonumber(code) == CODE.internal and 'internal') or want
    end
    defaultBackend = kept
    if kept == 'bank' and Integrations.choice('banking') == 'none' then
        Log.problem('note: Config.Integrations.Banking is none, but the organisation\'s funds are kept in '
            .. 'the bank: staff move them with the panel\'s funds backend switch (orgFundsBackend)')
    end
    return kept
end

--- The backend in force for one organisation: 'internal' or 'bank' (with
--- no organisation, the first choice).
---@param org table|nil
---@return string
function Funds.backend(org)
    local id = type(org) == 'table' and org.id or nil
    if id and backends[id] then return backends[id] end
    return defaultBackend or Funds.pick()
end

--- Whether Renewed-Banking holds this organisation's funds.
---@param org table|nil
---@return boolean
function Funds.usesBank(org)
    return Funds.backend(org) == 'bank'
end

--- Whether the funds can move now: always on the ledger; with the bank,
--- only while Renewed-Banking is started.
---@param org table|nil
---@return boolean
function Funds.ready(org)
    if not Funds.usesBank(org) then return true end
    return bankStarted()
end

--- The reference of an organisation's backend marker row.
local function markerRef(org) return ('backend:' .. tostring(org.id)):sub(1, 96) end

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
    if not defaultBackend then Funds.pick() end
    local rows = Storage.readOrgRows('funds', org.id) or {}
    local total = 0
    local own = nil
    for i = 1, #rows do
        local row = rows[i]
        if row.backend ~= 'internal' and row.backend ~= 'bank' then
            row.backend = defaultBackend
            pcall(Storage.writeOrgRow, 'funds', row)
        end
        if row.kind == 'backend' and row.id == markerRef(org) then own = row.backend end
        if row.backend == 'internal' then total = total + (math.floor(tonumber(row.amount) or 0)) end
        known[row.id] = row
    end
    balances[org.id] = total
    backends[org.id] = own or defaultBackend
    loaded = true
    table.sort(rows, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then return (a.created_at or 0) > (b.created_at or 0) end
        return tostring(a.id) > tostring(b.id)
    end)
    return rows
end

--- Ask Renewed-Banking for the job's account (its CreateJobAccount, which
--- answers the account it has or makes one at 0): true once the account
--- can be read. Idempotent there.
---@return boolean made
---@return string|nil err
local function makeAccount(org)
    local bank = Bank()
    if not bank then return false, 'bank_down' end
    if type(bank.CreateJobAccount) ~= 'function' then return false, 'no_account' end
    local ok, err = pcall(function()
        return bank.CreateJobAccount({ name = org.job, label = org.label or org.job }, 0)
    end)
    if not ok then
        Log.problem(('warning: Renewed-Banking would not make the %s account: %s')
            :format(tostring(org.job), tostring(err)))
    end
    local read, money = pcall(function() return Bank().getAccountMoney(org.job) end)
    return read and type(money) == 'number', 'no_account'
end

--- Make sure Renewed-Banking has the job's account, once it is started,
--- where this organisation's funds are kept there. Idempotent there.
function Funds.ensureAccount(org)
    if not Funds.usesBank(org) or not bankStarted() then return true end
    local ok = makeAccount(org)
    accountMade[org.id] = true
    return ok
end

--- The bank's balance, or nil while it cannot be read.
local function bankBalance(org)
    local ok, money = pcall(function() return Bank().getAccountMoney(org.job) end)
    if not ok or type(money) ~= 'number' then return nil end
    return math.floor(money)
end

--- The balance now: nil while the bank chosen is not started.
---@param org table
---@return integer|nil
function Funds.balance(org)
    if Funds.usesBank(org) then
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
--- A cut's row (or its give-back's), from memory or read once.
local function cutRow(ref)
    local row = known[ref]
    if not row and not loaded and not absent[ref] and Storage and Storage.readOrgRow then
        local ok, found = pcall(Storage.readOrgRow, 'funds', ref)
        if ok and type(found) == 'table' then
            known[ref], row = found, found
        elseif ok then
            absent[ref] = true
        end
    end
    return row
end

--- The references of a line's cut and of its give-back (Funds.cutBack).
function Funds.cutRefs(lineId)
    return ('cut:' .. lineId):sub(1, 96), ('cut:' .. lineId .. ':back'):sub(1, 96)
end

--- Whether nothing is left in this organisation's funds under either
--- backend: the ledger's own rows sum to nothing, and Renewed-Banking's
--- account (where it is started and has one) holds nothing. With the bank
--- chosen and not started, not known: false.
---@param org table
---@return boolean
function Funds.emptyEverywhere(org)
    if (balances[org.id] or 0) ~= 0 then return false end
    local bank = Funds.usesBank(org)
    if not bankStarted() then return not bank end
    local held = bankBalance(org)
    if held == nil then return not bank end
    return held == 0
end

--- What the funds already took of one escrow line (its cut): 0 once that
--- cut was given back (Funds.cutBack). From memory where the
--- ledger was read; otherwise (the organisation off since the start) read
--- once from the store, so a cut taken before a restart is never paid to
--- the member as well.
---@param lineId string|nil
---@return integer taken
---@return string|nil cid whom it was taken from (the member)
---@return table|nil row the cut's row
function Funds.taken(lineId)
    if type(lineId) ~= 'string' then return 0 end
    local ref, backRef = Funds.cutRefs(lineId)
    local row = cutRow(ref)
    if not row then return 0 end
    if cutRow(backRef) then return 0 end
    return math.max(0, math.floor(tonumber(row.amount) or 0)), row.actor, row
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
Funds.MARKS = { salary_paid = true, salary_review = true, give_paid = true, give_review = true, backend = true }

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
        reason = spec.reason, created_at = os.time(), backend = Funds.backend(org) }
    local wrote = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote then return false end
    -- Inserted now, or there already: either way it is written.
    known[ref] = row
    absent[ref] = nil
    return true
end

local function history(org, title, amount, actor, kind, always)
    if not always and not Funds.usesBank(org) then return end
    pcall(function()
        return Bank().handleTransaction(org.job, title, amount, tostring(kind),
            tostring(actor or 'crimson-hitman'), org.job, amount > 0 and 'deposit' or 'withdraw')
    end)
end

--- Why the funds cannot move now: 'busy' (a switch), 'bank_down', or nil.
local function blocked(org)
    if switching[org.id] then return 'busy' end
    if Funds.usesBank(org) then
        if not bankStarted() then return 'bank_down' end
        if not accountMade[org.id] then Funds.ensureAccount(org) end
    end
    return nil
end

--------------------------------------------------------------------------
-- A crash between the bank and the ledger (step 7 BUG-4, BUG-5)
--------------------------------------------------------------------------

--- Renewed-Banking's account moves at once and the ledger row is an await
--- after it, so a crash in between moved money the ledger never named: a
--- debit's salary was paid again from the funds at the next pay day, a
--- credit (row first, then) left a row for money the account never had,
--- and a member's deposit was charged with nothing written. Each is kept on
--- this machine the moment the money moves, before anything is awaited
--- (Review.prepare, as escrow's take is), let go once the row is answered,
--- and settled at the next start by Funds.decideInterrupted.
---@param spec table { how = 'debit' | 'credit' | 'deposit', ref, amount, org, row, payer, account }
---@return table|nil item
local function intent(spec)
    if not (Review and Review.prepare) then return nil end
    spec.decide = true
    return Review.prepare({
        kind = 'org_funds_interrupted', cids = spec.payer and { payer = spec.payer } or {},
        amount = spec.amount, account = spec.account or 'bank', known = spec,
    })
end

local function letGo(item)
    if item and Review then Review.discard(item) end
end

local function orgRef(org)
    return { id = org.id, job = org.job, label = org.label }
end

local switchRows

--- A backend switch a crash stopped after its money moved: its rows and
--- marker written now (each once), the organisation's balance read again
--- where this process has it loaded.
local function decideSwitch(org, s)
    if type(s) ~= 'table' or type(s.stamp) ~= 'string' or not CODE[s.from] or not CODE[s.to]
        or type(s.carried) ~= 'number' or s.carried < 0 or s.carried ~= math.floor(s.carried) then
        return 'staff', L('org_funds.it_does_not_carry_the_movements')
    end
    s.at = tonumber(s.at) or os.time()
    switchRows(org, s)
    if backends[org.id] then Funds.load(org) end
    if s.carried > 0 then
        Audit.financial('org_funds_switch_recorded', s.actor, nil, { org = org.id, from = s.from, to = s.to,
            carried = s.carried })
    end
    return 'done', L('org_funds.the_switch_moved_its_money_so')
end

--- org_funds_interrupted, settled by the server at the next start:
---   debit   the money left the account: the row is there (the debit
---           stands), or the money is put back, so the caller's next try
---           (the pay day's) pays from the funds once;
---   credit  the money is in the account: its row is written now if it is
---           not, so a retry is answered as the first was;
---   deposit a member was charged: their deposit is made now (once, by its
---           reference) if the ledger does not have it.
--- Never twice: the row decides, and a debit put back is let go from this
--- machine before anything is awaited again.
---@param item table a review item
---@return string verdict 'done' | 'wait' | 'staff'
---@return string note
function Funds.decideInterrupted(item)
    local known_ = type(item.known) == 'table' and item.known or {}
    local ref, amount = known_.ref, Funds.amount(known_.amount)
    local org = type(known_.org) == 'table' and known_.org.id and known_.org.job and known_.org or nil
    if known_.how == 'switch' and org then return decideSwitch(org, known_.switch) end
    if type(ref) ~= 'string' or not org or (not amount and known_.how ~= 'mark') then
        return 'staff', L('org_funds.it_does_not_carry_the_movements')
    end
    if Storage.readOrgRow('funds', ref) then return 'done', L('org_funds.the_ledger_has_it') end
    if known_.how == 'mark' and type(known_.mark) == 'table' then
        if not Funds.mark(org, ref, known_.mark) then
            -- What it marks happened all the same: nothing pays it again
            -- meanwhile (Funds.markWaiting).
            markWaiting[ref] = true
            return 'wait', L('org_funds.the_marker_could_not_be_written')
        end
        markWaiting[ref] = nil
        return 'done', L('org_funds.what_it_marks_happened_so_its')
    end
    local row = type(known_.row) == 'table' and known_.row or {}
    if known_.how == 'debit' then
        if not Bank() then
            return 'staff', (L('org_funds.renewed_banking_is_not_started_check')):format(org.job, amount, ref)
        end
        local ok, added = pcall(function() return Bank().addAccountMoney(org.job, amount) end)
        if not ok or not added then return 'staff', L('org_funds.renewed_banking_would_not_take_the') end
        letGo(item)
        Audit.financial('org_funds_put_back', row.actor, row.contract_id, { ref = ref, amount = amount })
        return 'done', L('org_funds.the_debit_had_no_ledger_row')
    elseif known_.how == 'credit' and row.id == ref then
        Storage.insertOrgRowOnce('funds', row)
        known[ref], absent[ref] = row, nil
        Audit.financial('org_funds_recorded', row.actor, row.contract_id, { ref = ref, amount = amount })
        return 'done', L('org_funds.the_account_had_it_so_its')
    elseif known_.how == 'deposit' then
        local ok, err, repeated = Funds.credit(org, amount, { ref = ref, kind = 'deposit',
            actor = known_.payer, reason = known_.account, title = L('org_funds.member_deposit') })
        if ok or repeated then return 'done', L('org_funds.the_members_deposit_was_made') end
        if err == 'busy' or err == 'bank_down' then return 'wait', L('org_funds.the_funds_cannot_move_now') end
        return 'staff', L('org_funds.the_funds_refused_the_members_deposit')
    end
    return 'staff', L('org_funds.it_does_not_carry_the_movements')
end

--- A member was charged for a deposit (Org.deposit): kept before anything
--- is awaited, let go by Funds.settled once the deposit has answered.
---@return table|nil item
function Funds.charged(org, ref, amount, account, payer)
    return intent({ how = 'deposit', ref = ref:sub(1, 96), amount = amount, org = orgRef(org),
        payer = payer, account = account })
end

---@param item table|nil from Funds.charged
function Funds.settled(item) letGo(item) end

--- Money the funds paid out (a bonus, a withdrawal, a salary: its debit
--- row written) is being handed to a member now: kept on this machine
--- before the give, let go (Funds.settled) the moment its marker is kept
--- instead (Funds.willMark), with nothing awaited between. A crash inside
--- the give leaves it, and the next start cannot tell whether the member
--- got it: left for staff (Funds.decideGive), never paid again on a guess.
--- A debit row found with neither this nor a marker never reached the
--- give, and is paid by the caller's retry.
---@param spec table { ref, cid, amount, account, kind }
---@return table|nil item
function Funds.giving(org, spec)
    if not (Review and Review.prepare) then return nil end
    return Review.prepare({
        kind = 'org_funds_give_unconfirmed', cids = { member = spec.cid }, amount = spec.amount,
        account = spec.account == 'cash' and 'cash' or 'bank',
        known = { decide = true, ref = spec.ref:sub(1, 96), org = orgRef(org), give = spec.kind },
    })
end

--- org_funds_give_unconfirmed, at the next start: the give marked paid (or given
--- back) after all stands; otherwise it is marked as left for staff, so
--- the member's retry pays nothing, and staff check the member's money.
---@return string verdict 'done' | 'staff'
---@return string note
function Funds.decideGive(item)
    local known_ = type(item.known) == 'table' and item.known or {}
    local ref = known_.ref
    local org = type(known_.org) == 'table' and known_.org.id and known_.org.job and known_.org or nil
    if type(ref) ~= 'string' or not org then return 'staff', L('org_funds.it_does_not_carry_the_movements') end
    if Storage.readOrgRow('funds', (ref .. ':paid'):sub(1, 96)) or Storage.readOrgRow('funds', (ref .. ':back'):sub(1, 96)) then
        return 'done', L('org_funds.the_give_was_marked_so_it')
    end
    Funds.mark(org, (ref .. ':review'):sub(1, 96), { kind = 'give_review', actor = item.cids and item.cids.member,
        reason = L('org_funds.left_for_staff_the_server_stopped') })
    return 'staff', L('org_funds.the_server_stopped_while_it_was')
end

--- Give a line's cut back out of the funds: the line went to somebody other
--- than the member it was cut from (handed back to its placer), so the
--- funds keep nothing of a payout nobody was paid. Once, by its own
--- reference; Funds.taken answers 0 from then on.
---@return boolean ok
---@return string|nil err as Funds.debit
---@return boolean|nil repeated
function Funds.cutBack(org, lineId, amount, recipient, contract)
    local _, backRef = Funds.cutRefs(lineId)
    return Funds.debit(org, amount, { ref = backRef, kind = 'cut_back', actor = recipient, contract = contract,
        reason = L('org_funds.cut_given_back'), title = L('org_funds.cut_given_back') })
end

--- What a marker (Funds.MARKS) will say has happened, kept the moment it
--- happens and before the marker is awaited: a salary handed to the
--- member's bank is marked at the next start if a crash stops the write
--- (Funds.decideInterrupted). Let go by Funds.settled once it is written.
---@param spec table { kind, actor, reason } as Funds.mark takes it
---@return table|nil item
function Funds.willMark(org, ref, spec)
    return intent({ how = 'mark', ref = ref:sub(1, 96), org = orgRef(org), mark = spec })
end

--- Whether a marker kept before a restart is waiting to be written: what
--- it marks happened.
---@param ref string
---@return boolean
function Funds.markWaiting(ref)
    return markWaiting[type(ref) == 'string' and ref:sub(1, 96) or ref] == true
end

--- Whether every marker is kept before it is written (Funds.willMark): on a
--- database the server sends to (mysql), with the review queue wired. A
--- debit with no marker then never reached the member.
---@return boolean
function Funds.marksKept()
    return Review ~= nil and Review.prepare ~= nil and Storage ~= nil and Storage.remote == true
end

--- Put money into the funds, once per reference.
---@param org table
---@param amount integer above zero
---@param spec table { ref, kind, actor, reason, contract, charged }
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
    local bank = Funds.usesBank(org)
    local row = { id = ref, org_id = org.id, kind = spec.kind or 'credit', amount = amount,
        actor = spec.actor, reason = spec.reason, contract_id = spec.contract, created_at = os.time(),
        backend = bank and 'bank' or 'internal' }
    -- The bank: the account first, kept on this machine before the row is
    -- awaited (intent), then the row. Row first, a crash in between left a
    -- row for money the account never had, and every retry was answered
    -- 'repeated' (step 7 BUG-5); now the next start writes the row.
    local item
    if bank then
        local ok, added = pcall(function() return Bank().addAccountMoney(org.job, amount) end)
        if not ok or not added then
            inFlight[ref] = nil
            Log.debug(('Renewed-Banking refused %d into %s: %s'):format(amount, org.job, tostring(added)))
            return false, 'refused'
        end
        item = intent({ how = 'credit', ref = ref, amount = amount, row = row, org = orgRef(org) })
        -- The member's deposit is in the account now: this item is what
        -- the next start settles, never both.
        letGo(spec.charged)
    end
    local wrote, inserted = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote or not inserted then
        -- Taken back out of the account: the row is not this credit's.
        if bank then pcall(function() return Bank().removeAccountMoney(org.job, amount) end) end
        letGo(item)
        inFlight[ref] = nil
        return false, wrote and 'busy' or 'refused', wrote and true or nil
    end
    letGo(item)
    if bank then
        history(org, spec.title or L('org_funds.organisation'), amount, spec.actor, spec.kind)
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
    local bank = Funds.usesBank(org)
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
    local row = { id = ref, org_id = org.id, kind = spec.kind or 'debit', amount = -amount,
        actor = spec.actor, reason = spec.reason, contract_id = spec.contract, created_at = now,
        backend = bank and 'bank' or 'internal' }
    -- The bank: kept on this machine as the money leaves, before the row is
    -- awaited (intent). A crash in between lost it: no row named the
    -- reference, and the pay day paid the member from the funds again (step
    -- 7 BUG-4). Now the next start puts it back where the row is missing.
    local item
    if bank then
        local balance = bankBalance(org)
        if not balance or balance < amount then return done(false, 'short') end
        local ok, removed = pcall(function() return Bank().removeAccountMoney(org.job, amount) end)
        if not ok or not removed then return done(false, ok and 'short' or 'refused') end
        item = intent({ how = 'debit', ref = ref, amount = amount, row = row, org = orgRef(org) })
        history(org, spec.title or L('org_funds.organisation'), -amount, spec.actor, spec.kind)
    end
    local wrote, inserted = pcall(Storage.insertOrgRowOnce, 'funds', row)
    if not wrote or not inserted then
        -- The money left the account and the row would not be written: put
        -- the money back rather than lose it (the ledger's reservation is
        -- given back by done).
        if bank then
            pcall(function() return Bank().addAccountMoney(org.job, amount) end)
        end
        letGo(item)
        Audit.financial('org_funds_unrecorded', spec.actor, spec.contract, { ref = ref, amount = amount })
        return done(false, 'refused')
    end
    letGo(item)
    known[ref] = row
    return done(true)
end

--- The rows a backend switch writes: the balance out of the one backend
--- and into the other (each once, by the switch's stamp), and the
--- organisation's marker row naming the backend it keeps from now on.
--- Raises where the store does; written again from the start, each lands
--- once.
---@param s table { stamp, from, to, carried, actor, at }
switchRows = function(org, s)
    local function row(id, b, amount)
        return { id = ('switch:%s:%s'):format(s.stamp, id):sub(1, 96), org_id = org.id, kind = 'switch',
            amount = amount, actor = s.actor, reason = s.from .. '>' .. s.to, created_at = s.at, backend = b }
    end
    if (s.carried or 0) > 0 then
        local out, into = row('out', s.from, -s.carried), row('in', s.to, s.carried)
        Storage.insertOrgRowOnce('funds', out)
        known[out.id], absent[out.id] = out, nil
        Storage.insertOrgRowOnce('funds', into)
        known[into.id], absent[into.id] = into, nil
    end
    local marker = { id = markerRef(org), org_id = org.id, kind = 'backend', amount = 0, actor = s.actor,
        reason = s.from .. '>' .. s.to, created_at = s.at, backend = s.to }
    Storage.writeOrgRow('funds', marker)
    known[marker.id], absent[marker.id] = marker, nil
end

--- Staff only (orgFundsBackend): move one organisation's funds to the other
--- backend, its balance carried across in two rows (out of the one, into
--- the other), and its marker row saying where they are kept now; every
--- other organisation's stay where they are. Both sides need
--- Renewed-Banking started, and the job's account made there first (its
--- CreateJobAccount: a job registered after Renewed-Banking started has
--- none); leaving the bank while it is not started, `abandon` switches with
--- nothing carried (its account keeps what it holds, said on the record).
--- Nothing else moves this organisation's funds meanwhile. The money moves
--- first with nothing awaited, and is kept on this machine at once (intent)
--- until the rows are written: a crash in between has them written at the
--- next start (Funds.decideInterrupted), so the balance is never in both
--- backends or in neither.
---@param org table
---@param to string 'internal' | 'bank'
---@param spec table { actor, abandon }
---@return boolean ok
---@return string|nil err 'invalid' | 'already' | 'busy' | 'bank_down' | 'refused' | 'no_account'
---@return table|nil done { from, to, carried, abandoned }
function Funds.switch(org, to, spec)
    spec = type(spec) == 'table' and spec or {}
    if to ~= 'internal' and to ~= 'bank' then return false, 'invalid' end
    local from = Funds.backend(org)
    if from == to then return false, 'already' end
    if switching[org.id] or next(inFlight) then return false, 'busy' end
    local abandoned = false
    if not bankStarted() then
        if to == 'bank' or not spec.abandon then return false, 'bank_down' end
        abandoned = true
    end
    switching[org.id] = true
    local function finish(ok, err, extra)
        switching[org.id] = nil
        return ok, err, extra
    end
    -- The account first (it awaits its own insert), then nothing awaited
    -- until the money moved is kept on this machine.
    if not abandoned then
        local made, why = makeAccount(org)
        if not made then return finish(false, why) end
    end
    if next(inFlight) then return finish(false, 'busy') end
    local s = { stamp = ('%d:%d'):format(os.time(), math.random(1000, 9999)), from = from, to = to,
        carried = 0, actor = spec.actor, at = os.time() }
    if to == 'bank' then
        s.carried = math.max(0, balances[org.id] or 0)
        if s.carried > 0 then
            local ok, added = pcall(function() return Bank().addAccountMoney(org.job, s.carried) end)
            if not ok or not added then return finish(false, 'refused') end
            balances[org.id] = (balances[org.id] or 0) - s.carried
        end
    elseif not abandoned then
        local held = bankBalance(org)
        if held == nil then return finish(false, 'refused') end
        s.carried = math.max(0, held)
        if s.carried > 0 then
            local ok, removed = pcall(function() return Bank().removeAccountMoney(org.job, s.carried) end)
            if not ok or not removed then return finish(false, 'refused') end
            balances[org.id] = (balances[org.id] or 0) + s.carried
        end
    end
    local item = intent({ how = 'switch', ref = markerRef(org), org = orgRef(org), switch = s })
    backends[org.id] = to
    accountMade[org.id] = nil
    if s.carried > 0 then
        history(org, to == 'bank' and L('org_funds.moved_from_the_ledger') or L('org_funds.moved_to_the_ledger'),
            to == 'bank' and s.carried or -s.carried, spec.actor, 'switch', true)
    end
    local wrote, err = pcall(switchRows, org, s)
    if not wrote then
        -- The money has moved: the rows are written by the server once the
        -- store answers (the item, now open), and this process already
        -- keeps the funds where they went.
        Log.problem(('warning: the funds backend switch of %s moved %d but its rows were not written (%s); '
            .. 'they are written once the database answers'):format(tostring(org.id), s.carried, tostring(err)))
        if item and Review and Review.open then
            item.known.error = tostring(err)
            pcall(Review.open, item)
        end
    else
        letGo(item)
    end
    return finish(true, nil, { from = from, to = to, carried = s.carried, abandoned = abandoned or nil })
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
end)
