--- Escrow: the single source of truth for what a contract is worth (§9.1).
---
--- Two rules govern this file and nothing may bypass them:
---   1. Funds and items move in the same operation that writes the record.
---   2. Every release passes through releaseEscrow, which performs a guarded
---      compare-and-set on the escrow line's state (§14.3). A line can settle
---      exactly once, no matter which path reaches it.

local Util = require_shared('util')

local Escrow = {}

local Storage, Audit

function Escrow.init(storage, audit)
    Storage, Audit = storage, audit
end

--------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------

--- Validate a client-submitted reward composition against what the player
--- actually holds, reading everything server-side (§3.5, §14.13).
---
--- Returns a normalised line list. The caller never sees the client's own
--- numbers again — only what this function produced.
--- A contract may pay out several times (§3.5): `spec.slots` is an array of
--- reward sets, one per collection, each with its own baseline and bonus.
--- A bare { baseline = ..., bonus = ... } is accepted as a single slot.
---
---@param actor table
---@param spec table client submission
---@param bonusPercent integer|nil derive a bonus from the baseline money
---@param existingLines integer|nil escrow lines the contract already holds
---@return table[]|nil lines
---@return string|nil err
---@return integer|nil slotCount
function Escrow.validate(actor, spec, bonusPercent, existingLines)
    if type(spec) ~= 'table' then return nil, CB.ERR.INVALID_REWARD end

    local slots = spec.slots
    if slots == nil then
        slots = { { baseline = spec.baseline, bonus = spec.bonus } }
    end
    if type(slots) ~= 'table' or #slots < 1 or #slots > Config.Limits.MaxPayoutSlots then
        return nil, CB.ERR.INVALID_REWARD
    end

    local lines = {}
    local moneyTotal = 0
    local slotIndex = 0

    local function addMoney(portion, source, rawAmount)
        local rule = Config.Sources[source]
        if not rule or not rule.enabled then return CB.ERR.INVALID_REWARD end
        local amount = Util.toPositive(rawAmount, rule.max)
        if not amount then return CB.ERR.INVALID_REWARD end

        local held
        if source == 'cash' or source == 'bank' then
            held = actor.player.Functions.GetMoney(source) or 0
        else
            held = exports.ox_inventory:GetItem(actor.source, rule.item, nil, true) or 0
        end
        if held < amount then return CB.ERR.INSUFFICIENT end

        lines[#lines + 1] = { slot = slotIndex, portion = portion, source = source, amount = amount }
        moneyTotal = moneyTotal + amount
        return nil
    end

    local function addItems(portion, list)
        if list == nil then return nil end
        if type(list) ~= 'table' then return CB.ERR.INVALID_REWARD end
        if #list > Config.Sources.item.maxStacks then return CB.ERR.INVALID_REWARD end

        for i = 1, #list do
            local entry = list[i]
            if type(entry) ~= 'table' then return CB.ERR.INVALID_REWARD end
            local name = Util.sanitizeText(entry.name, 64)
            local count = Util.toPositive(entry.count, Config.Sources.item.maxPerStack)
            if not name or not count then return CB.ERR.INVALID_REWARD end
            if Config.EscrowBlacklist[name] then return CB.ERR.INVALID_REWARD end

            local held = exports.ox_inventory:GetItem(actor.source, name, nil, true) or 0
            if held < count then return CB.ERR.INSUFFICIENT end

            lines[#lines + 1] = { slot = slotIndex, portion = portion, source = CB.SOURCE.ITEM, item = name, quantity = count }
        end
        return nil
    end

    -- Inventory slots already staged in this contract. A weapon is one
    -- physical object: naming the same slot in two payouts would snapshot
    -- one weapon twice, take it once, then fail hunting for its twin and
    -- roll the whole contract back. Refused here instead.
    local stagedWeaponSlots = {}

    local function addWeapons(portion, list)
        if list == nil then return nil end
        if type(list) ~= 'table' then return CB.ERR.INVALID_REWARD end
        if #list > Config.Sources.weapon.max then return CB.ERR.INVALID_REWARD end

        for i = 1, #list do
            local entry = list[i]
            if type(entry) ~= 'table' then return CB.ERR.INVALID_REWARD end
            local name = Util.sanitizeText(entry.name, 64)
            -- The inventory slot the weapon is being taken FROM. Named
            -- distinctly from the payout slot (`slotIndex`, set by the
            -- enclosing loop): they are different numbers with different
            -- meanings, and conflating them orphans the escrow line.
            local invSlot = Util.toPositive(entry.slot, 200)
            if not name or not invSlot then return CB.ERR.INVALID_REWARD end
            if Config.EscrowBlacklist[name] then return CB.ERR.INVALID_REWARD end

            -- Read the weapon's real metadata from the server-side inventory
            -- and snapshot it (§9.4). The client's copy is never stored.
            local found
            local slots = exports.ox_inventory:Search(actor.source, 'slots', name) or {}
            for j = 1, #slots do
                if slots[j].slot == invSlot or not found then found = slots[j] end
            end
            if not found then return CB.ERR.INSUFFICIENT end
            if stagedWeaponSlots[found.slot] then return CB.ERR.INVALID_REWARD end
            stagedWeaponSlots[found.slot] = true

            lines[#lines + 1] = {
                slot     = slotIndex,          -- payout slot this reward belongs to
                inv_slot = found.slot,         -- where it came from, for the audit trail
                portion  = portion,
                source   = CB.SOURCE.WEAPON,
                item     = name,
                quantity = 1,
                metadata = Util.copy(found.metadata) or {},
            }
        end
        return nil
    end

    for index = 1, #slots do
        slotIndex = index
        local set = slots[index]
        if type(set) ~= 'table' then return nil, CB.ERR.INVALID_REWARD end

        local before = #lines
        for _, portion in ipairs({ CB.PORTION.BASELINE, CB.PORTION.BONUS }) do
            local part = set[portion]
            if part ~= nil then
                if type(part) ~= 'table' then return nil, CB.ERR.INVALID_REWARD end
                for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
                    -- A zero means the creator did not pick this source, not
                    -- that the whole contract is invalid. Treating it as a
                    -- rejection made every submission from a form that sends
                    -- all its fields fail, which is every form.
                    if part[source] ~= nil and part[source] ~= 0 and part[source] ~= '0' then
                        local err = addMoney(portion, source, part[source])
                        if err then return nil, err end
                    end
                end
                local err = addItems(portion, part.items)
                if err then return nil, err end
                err = addWeapons(portion, part.weapons)
                if err then return nil, err end
            end
        end

        -- Every slot must actually be funded; an empty slot would be a
        -- collection that pays nothing.
        local slotLines = {}
        for i = before + 1, #lines do slotLines[#slotLines + 1] = lines[i] end
        if Util.escrowIsEmpty(slotLines, CB.PORTION.BASELINE) then
            return nil, CB.ERR.INVALID_REWARD
        end
    end

    -- A kidnapping bonus set as a percentage is turned into real escrow
    -- here. A percentage that is only stored and displayed pays nothing:
    -- the bonus release finds no lines and a live delivery is worth exactly
    -- what a kill is worth.
    bonusPercent = Util.toCount(bonusPercent, Config.Bonus.maxPercent) or 0
    if bonusPercent > 0 then
        -- A slot that already names its own bonus is left alone: the
        -- creator said exactly what they meant, and deriving another on top
        -- would charge them twice for one promise.
        local explicit = {}
        for i = 1, #lines do
            if lines[i].portion == CB.PORTION.BONUS then explicit[lines[i].slot] = true end
        end

        local derived = {}
        for i = 1, #lines do
            local line = lines[i]
            if line.portion == CB.PORTION.BASELINE
                and not explicit[line.slot]
                and CB.MONEY_SOURCES[line.source] then
                local extra = math.floor(line.amount * (bonusPercent / 100))
                if extra > 0 then
                    derived[#derived + 1] = {
                        slot = line.slot, portion = CB.PORTION.BONUS,
                        source = line.source, amount = extra,
                    }
                    moneyTotal = moneyTotal + extra
                end
            end
        end
        for i = 1, #derived do lines[#lines + 1] = derived[i] end
    end

    -- Holdings were checked per line against the live balance, so a creator
    -- could otherwise fund three slots from one balance. Re-check the totals.
    local err = Escrow.checkAggregate(actor, lines)
    if err then return nil, err end

    if moneyTotal > Config.MaxContractValue then
        return nil, CB.ERR.INVALID_REWARD
    end

    -- The per-payout limits multiply, so the total needs its own ceiling.
    -- Callers adding to a contract that already holds escrow pass the count
    -- it holds, so a top-up cannot walk past the limit one line at a time.
    if #lines + (existingLines or 0) > Config.Limits.MaxEscrowLines then
        return nil, CB.ERR.INVALID_REWARD
    end

    return lines, nil, #slots
end

--- Confirm the creator actually holds the SUM of every line, not just each
--- line individually. Without this, three slots of $10,000 each would pass
--- on a $10,000 balance and the third confiscation would fail mid-take.
---@return string|nil err
function Escrow.checkAggregate(actor, lines)
    local money, items = {}, {}

    for i = 1, #lines do
        local line = lines[i]
        if CB.MONEY_SOURCES[line.source] then
            money[line.source] = (money[line.source] or 0) + line.amount
        else
            local key = line.item
            items[key] = (items[key] or 0) + (line.quantity or 1)
        end
    end

    for source, total in pairs(money) do
        local held
        if source == 'cash' or source == 'bank' then
            held = actor.player.Functions.GetMoney(source) or 0
        else
            held = exports.ox_inventory:GetItem(actor.source, Config.Sources.dirty.item, nil, true) or 0
        end
        if held < total then return CB.ERR.INSUFFICIENT end
    end

    for name, total in pairs(items) do
        local held = exports.ox_inventory:GetItem(actor.source, name, nil, true) or 0
        if held < total then return CB.ERR.INSUFFICIENT end
    end

    return nil
end

--------------------------------------------------------------------------
-- Taking escrow
--------------------------------------------------------------------------

--- Confiscate the validated lines and write the escrow record as one
--- operation. On any failure everything already taken is put back, so a
--- partially-charged creator is not a reachable state (§3.5).
---@param actor table
---@param contractId string
---@param lines table[] from Escrow.validate
---@return boolean ok
---@return string|nil err
function Escrow.take(actor, contractId, lines)
    local taken = {}

    local function rollback()
        for i = #taken, 1, -1 do
            local line = taken[i]
            if line.source == 'cash' or line.source == 'bank' then
                actor.player.Functions.AddMoney(line.source, line.amount)
            elseif line.source == 'dirty' then
                exports.ox_inventory:AddItem(actor.source, Config.Sources.dirty.item, line.amount)
            elseif line.source == CB.SOURCE.ITEM then
                exports.ox_inventory:AddItem(actor.source, line.item, line.quantity)
            elseif line.source == CB.SOURCE.WEAPON then
                exports.ox_inventory:AddItem(actor.source, line.item, 1, line.metadata)
            end
        end
    end

    for i = 1, #lines do
        local line = lines[i]
        local ok = false

        if line.source == 'cash' or line.source == 'bank' then
            ok = actor.player.Functions.RemoveMoney(line.source, line.amount) and true or false
        elseif line.source == 'dirty' then
            ok = exports.ox_inventory:RemoveItem(actor.source, Config.Sources.dirty.item, line.amount) and true or false
        elseif line.source == CB.SOURCE.ITEM then
            ok = exports.ox_inventory:RemoveItem(actor.source, line.item, line.quantity) and true or false
        elseif line.source == CB.SOURCE.WEAPON then
            ok = exports.ox_inventory:RemoveItem(actor.source, line.item, 1, line.metadata) and true or false
        end

        if not ok then
            rollback()
            return false, CB.ERR.INSUFFICIENT
        end
        taken[#taken + 1] = line
    end

    -- Ids are allocated after whatever the contract already holds, so a
    -- later top-up (§12.1) appends rather than overwriting the original
    -- lines. A caller-supplied id is respected if it is already unique.
    local existing = Storage.readEscrow(contractId)
    local used = {}
    for i = 1, #existing do used[existing[i].id] = true end

    local records = {}
    local nextIndex = #existing
    for i = 1, #lines do
        local line = Util.copy(lines[i])
        line.contract_id = contractId
        line.state = CB.ESCROW_STATE.HELD
        line.slot = line.slot or 1

        if not line.id or used[line.id] then
            repeat
                nextIndex = nextIndex + 1
                line.id = contractId .. ':' .. tostring(nextIndex)
            until not used[line.id]
        end
        used[line.id] = true

        records[#records + 1] = line
    end

    local ok = Storage.writeEscrow(contractId, records)
    if not ok then
        rollback()
        return false, CB.ERR.BAD_STATE
    end

    Audit.financial('escrow_taken', actor.cid, contractId, { lines = #records })
    return true
end

--------------------------------------------------------------------------
-- Releasing escrow
--------------------------------------------------------------------------

--- Release escrow to a recipient.
---
--- The compare-and-set on each line's state is the guard that makes every
--- release path safe against every other: completion, bailout, cancel,
--- expiry, penalty resolution, login retry and the shutdown sweep all call
--- this, and a line that is already `releasing` or `settled` moves nothing.
---
---@param contractId string
---@param recipientCid string
---@param filter table|string|nil { slot = n, portion = s } — nil releases everything
---@param reason string audit tag
---@return boolean moved  true when at least one line settled here
---@return table   result { settled = n, pending = n }
function Escrow.release(contractId, recipientCid, filter, reason)
    if type(filter) == 'string' then filter = { portion = filter } end
    local lines = Storage.readEscrow(contractId)
    local result = { settled = 0, pending = 0, skipped = 0 }

    for i = 1, #lines do
        local line = lines[i]
        local matches = true
        if filter then
            if filter.portion and line.portion ~= filter.portion then matches = false end
            if filter.slot and line.slot ~= filter.slot then matches = false end
            if filter.staker and line.staker ~= filter.staker then matches = false end

            if filter.line then
                -- One named line and nothing else. A caller that names a
                -- specific line has said exactly what it means, so the
                -- general-refund exclusions below do not apply — but the
                -- name has to match, or this releases the whole contract.
                if line.id ~= filter.line then matches = false end
            elseif not filter.portion
                and (line.portion == CB.PORTION.STAKE or line.portion == CB.PORTION.OWED) then
                -- A release that names no portion is a general refund. It
                -- must not sweep up a hunter's stake, nor money already
                -- promised to a named person.
                matches = false
            end
        elseif line.portion == CB.PORTION.STAKE or line.portion == CB.PORTION.OWED then
            matches = false
        end

        -- A line already owed to someone belongs to them, whatever this
        -- release is for. A staff settlement names the line explicitly and
        -- is audited, so it is the one thing that may override this.
        if line.owed_to and line.owed_to ~= recipientCid and not (filter and filter.line) then
            matches = false
        end

        if matches then
            -- Compare-and-set: only a line still `held` may be claimed, and
            -- the claim is what authorises moving the funds.
            local claimed = Storage.claimEscrowLine(line.id, CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING)
            if not claimed then
                result.skipped = result.skipped + 1
            else
                local delivered = Escrow.deliver(recipientCid, line)
                if delivered then
                    Storage.settleEscrowLine(line.id, recipientCid)
                    result.settled = result.settled + 1
                else
                    -- Could not deliver (offline, or inventory full). The line
                    -- stays owed rather than being destroyed (§9.3): it goes
                    -- back to `held`, is marked as owed to this player, and
                    -- is queued for retry on next login.
                    --
                    -- The mark matters: without it a later unfiltered refund
                    -- would sweep a hunter's undelivered payout to the
                    -- creator, quietly paying the wrong person.
                    line.owed_to = recipientCid
                    Storage.writeEscrow(contractId, { line })
                    Storage.claimEscrowLine(line.id, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD)
                    Storage.queuePending(recipientCid, contractId, line.id)
                    result.pending = result.pending + 1
                end
            end
        end
    end

    Audit.financial('escrow_released', recipientCid, contractId, {
        reason = reason, settled = result.settled, pending = result.pending,
    })

    return result.settled > 0, result
end

--- Hand a single escrow line to a player. Returns false when it cannot be
--- delivered right now — never destroys the property to force success.
---@return boolean
function Escrow.deliver(recipientCid, line)
    local recipient = exports.qbx_core:GetPlayerByCitizenId(recipientCid)
    if not recipient or not recipient.PlayerData then return false end

    local src = recipient.PlayerData.source

    if line.source == 'cash' or line.source == 'bank' then
        local account, amount = line.source, line.amount
        if Config.Payout.AllowConversion and line.convertTo == 'dirty' then
            -- Conversion is lossy by design: the rate matches the server's
            -- black market so converting is never profitable (§14.10).
            local converted = math.floor(amount * Config.Payout.DirtyConversionRate)
            if converted <= 0 then return false end
            return exports.ox_inventory:AddItem(src, Config.Sources.dirty.item, converted) and true or false
        end
        recipient.Functions.AddMoney(account, amount)
        return true

    elseif line.source == 'dirty' then
        if not exports.ox_inventory:CanCarryItem(src, Config.Sources.dirty.item, line.amount) then return false end
        return exports.ox_inventory:AddItem(src, Config.Sources.dirty.item, line.amount) and true or false

    elseif line.source == CB.SOURCE.ITEM then
        if not exports.ox_inventory:CanCarryItem(src, line.item, line.quantity) then return false end
        return exports.ox_inventory:AddItem(src, line.item, line.quantity) and true or false

    elseif line.source == CB.SOURCE.WEAPON then
        if not exports.ox_inventory:CanCarryItem(src, line.item, 1) then return false end
        -- The snapshot goes back exactly as it was taken: serial, attachments
        -- and durability all restored (§9.4).
        return exports.ox_inventory:AddItem(src, line.item, 1, line.metadata) and true or false
    end

    return false
end

--- Money-equivalent value of what a contract holds. Items and weapons are
--- counted at zero — this figure is used for bailout clamping and sorting,
--- and inflating it with unpriceable items would let a creator set an
--- arbitrary premium (§14.16).
---@param contractId string
---@param filter table|string|nil
---@return integer
function Escrow.moneyValue(contractId, filter)
    if type(filter) == 'string' then filter = { portion = filter } end
    local lines = Storage.readEscrow(contractId)
    local total = 0
    for i = 1, #lines do
        local line = lines[i]
        local matches = true
        if filter then
            if filter.portion and line.portion ~= filter.portion then matches = false end
            if filter.slot and line.slot ~= filter.slot then matches = false end
        end
        if matches and line.portion ~= CB.PORTION.STAKE
            and line.portion ~= CB.PORTION.OWED
            and CB.MONEY_SOURCES[line.source] then
            if line.state ~= CB.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0)
            end
        end
    end
    return total
end

--- Retry queued deliveries for a player who has just come online (§9.3).
---@param cid string
---@return integer delivered
function Escrow.retryPending(cid)
    local queued = Storage.readPending(cid)
    local delivered = 0

    for i = 1, math.min(#queued, Config.PendingEscrow.MaxRetriesPerLogin) do
        local entry = queued[i]
        local line = Storage.readEscrowLine(entry.line_id)
        if line and line.state == CB.ESCROW_STATE.HELD
            and (line.owed_to == nil or line.owed_to == cid) then
            local claimed = Storage.claimEscrowLine(line.id, CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING)
            if claimed then
                if Escrow.deliver(cid, line) then
                    Storage.settleEscrowLine(line.id, cid)
                    Storage.clearPending(entry.id)
                    delivered = delivered + 1
                else
                    Storage.claimEscrowLine(line.id, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD)
                end
            end
        else
            Storage.clearPending(entry.id)
        end
    end

    if delivered > 0 then
        Audit.financial('pending_delivered', cid, nil, { count = delivered })
    end
    return delivered
end

return Escrow
