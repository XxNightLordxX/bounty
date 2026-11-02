--- Manual staff payments, from Players in the admin panel.
---
--- Staff with the staff ACE pay one player an amount of cash or bank, with
--- a reason, on the two-click confirm. At most Config.Staff.ManualPaymentMax
--- (0 turns it off). It is paid the way every other payment that is not a
--- contract's own is (Bailout.payOrOwe): into their hands when they are in
--- the city, and otherwise owed on a line of its own, handed over at their
--- next login (Bailout.owe).
---
--- It creates money on purpose. Every one is on the record as
--- staff_manual_payment (who paid, who was paid, how much, in what, why,
--- and whether it was owed), and the money conservation tests count it as
--- the one thing allowed to add to the world, by exactly that figure
--- (tests/staff_player_spec.lua). Kept as a staff record too
--- (Sanctions.note), for the player's history card.
---
--- The player is told they were paid, by "staff", never which of them.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local Payments = {}

local Storage, Audit, Notify, Bailout, Sanctions

--- One payment to one player at a time: [cid] = true.
local inFlight = {}

local REASON_MAX = 120
Payments.ACCOUNTS = { cash = true, bank = true }

---@param deps table { storage, audit, notify, bailout, sanctions }
function Payments.init(deps)
    Storage, Audit, Notify = deps.storage, deps.audit, deps.notify
    Bailout, Sanctions = deps.bailout, deps.sanctions
    inFlight = {}
end

--- The most one payment may be now (Config.Staff.ManualPaymentMax); 0 off.
---@return integer
function Payments.max()
    local max = tonumber(Config.Staff and Config.Staff.ManualPaymentMax) or 0
    if max ~= max or max < 0 then return 0 end
    return math.floor(max)
end

local function cleanReason(reason)
    if type(reason) ~= 'string' then return nil end
    -- By characters, never through one: a cut UTF-8 character is refused
    -- by utf8mb4 (error 1366), and the whole write with it.
    return Util.sanitizeText(reason, REASON_MAX)
end

local payUnlocked
--- Pay a player.
---@param staffCid string|nil who paid, for the record
---@param cid string the player
---@param amount integer whole dollars, above 0 and at most Payments.max()
---@param account string 'cash' | 'bank'
---@param reason string
---@param name string|nil how staff know them, for the record
---@return boolean ok
---@return string|table err 'payments_off' | 'over_max' | CH.ERR.*; on success { paid, owed, line }
function Payments.pay(staffCid, cid, amount, account, reason, name)
    if type(cid) ~= 'string' or cid == '' then return false, CH.ERR.INVALID_INPUT end
    if not Payments.ACCOUNTS[account] then return false, CH.ERR.INVALID_INPUT end
    if math.type(amount) ~= 'integer' or amount <= 0 then return false, CH.ERR.INVALID_INPUT end
    reason = cleanReason(reason)
    if not reason then return false, CH.ERR.INVALID_INPUT end
    local max = Payments.max()
    if max <= 0 then return false, 'payments_off' end
    if amount > max then return false, 'over_max' end
    if inFlight[cid] then return false, CH.ERR.BUSY end
    inFlight[cid] = true
    local out = table.pack(pcall(payUnlocked, staffCid, cid, amount, account, reason, name))
    inFlight[cid] = nil
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
end

payUnlocked = function(staffCid, cid, amount, account, reason, name)
    -- Its own id, under which an owed line is kept: one per payment, so two
    -- payments to one player never share a line.
    local id = Util.mintId(Storage.nextId, 'mpay', function(candidate)
        return #(Storage.readEscrow(candidate) or {}) > 0
    end)
    if not id then return false, CH.ERR.SERVER_ERROR end

    local placed, raise, paid = Bailout.payOrOwe(cid, id, amount, account, 'staff_manual_payment')
    -- On the record whatever happened, with the figure: money was made, or
    -- was meant to be.
    Audit.financial('staff_manual_payment', staffCid, nil, {
        subject = cid, amount = amount, account = account, reason = reason, payment = id,
        owed = (placed and not paid) or nil, failed = not placed or nil,
        error = raise and raise.error or nil,
    })
    Audit.flush()
    if not placed then
        Log.always(('a manual staff payment of %d %s could not be paid or owed (no id left to owe it '
            .. 'under); nothing was paid'):format(amount, account))
        return false, CH.ERR.SERVER_ERROR
    end
    if Sanctions and Sanctions.note then
        Sanctions.note({ kind = 'payment', cid = cid, name = name, reason = reason, by_cid = staffCid,
                         amount = amount, account = account })
    end
    local words = Notify.dollars and Notify.dollars(amount) or ('$' .. amount)
    Notify.tellOrKeep(cid, 'Payment from staff', paid
        and ('Staff paid you %s in %s: %s'):format(words, account, reason)
        or ('Staff paid you %s in %s: %s. It is handed over when you can take it.')
            :format(words, account, reason), { bypassBudget = true })
    return true, { paid = paid == true, owed = not paid, line = not paid and id or nil, payment = id }
end

return Payments
