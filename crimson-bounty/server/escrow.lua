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
--- A weapon by name. ox_inventory names every weapon WEAPON_*, and this is
--- the boundary between the two escrow paths: one snapshots an object's
--- metadata, the other counts a stack.
--- Whether a reward source is switched on.
---
--- Read through a helper because a config that predates a source has it
--- absent rather than false, and indexing the absent one throws — inside a
--- handler, where it becomes a request that never answers. Absent reads as
--- off here, and startup fills in the shipped default so it should never
--- come to this.
---@param name string
---@return boolean
local function sourceEnabled(name)
    local source = Config.Sources and Config.Sources[name]
    return (source and source.enabled) == true
end

local function isWeaponName(name)
    return type(name) == 'string' and name:upper():sub(1, 7) == 'WEAPON_'
end

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

    -- How much of each inventory slot this validation has already promised.
    --
    -- Nothing is taken until validate returns, so every payout re-reads the
    -- same untouched inventory. Without this, two payouts each asking for
    -- ten of an item both draw them from the first stack the search returns:
    -- the aggregate check passes (the creator really does hold twenty), the
    -- escrow records one stack twice with one stack's metadata, and the take
    -- then fails hunting for a second copy of it and rolls the whole
    -- contract back — a fully-funded contract refused as insufficient.
    --
    -- Weapons share the counter for the opposite reason: a weapon is one
    -- physical object, so a slot named twice is refused rather than walked
    -- past.
    local stagedFromSlot = {}

    local function addItems(portion, list)
        if list == nil then return nil end
        if type(list) ~= 'table' then return CB.ERR.INVALID_REWARD end
        -- The kill switch was read only where the picker is built, so an
        -- operator who turned item escrow off still had it work for anyone
        -- sending the payload by hand. A config switch that only the UI
        -- honours is not a switch.
        if not sourceEnabled('item') then return CB.ERR.INVALID_REWARD end
        if #list > Config.Sources.item.maxStacks then return CB.ERR.INVALID_REWARD end

        for i = 1, #list do
            local entry = list[i]
            if type(entry) ~= 'table' then return CB.ERR.INVALID_REWARD end
            local name = Util.sanitizeText(entry.name, 64)
            local count = Util.toPositive(entry.count, Config.Sources.item.maxPerStack)
            if not name or not count then return CB.ERR.INVALID_REWARD end
            if Config.EscrowBlacklist[name] then return CB.ERR.INVALID_REWARD end

            -- A weapon is one physical object with a serial, attachments and
            -- wear. Through this path it would be stored as a bare name and
            -- handed back as a fresh clean one: attachments destroyed, wear
            -- refunded, serial laundered. Weapons go through addWeapons,
            -- which snapshots the metadata, or they do not go at all.
            if isWeaponName(name) then return CB.ERR.INVALID_REWARD end

            local held = exports.ox_inventory:GetItem(actor.source, name, nil, true) or 0
            if held < count then return CB.ERR.INSUFFICIENT end

            -- Items are not interchangeable just because they share a name.
            -- A repair kit at 11% durability is not a fresh one; a backpack
            -- holding goods is not an empty one. Escrow takes specific
            -- slots and remembers what was in them, so what comes back is
            -- what went in — the same rule §9.4 already applies to weapons.
            local slots = exports.ox_inventory:Search(actor.source, 'slots', name) or {}
            local remaining = count

            for j = 1, #slots do
                if remaining <= 0 then break end
                local found = slots[j]
                -- ox_inventory always numbers a slot, but an inventory build
                -- that does not would otherwise collapse every stack of one
                -- name onto a single nil key — and a nil table index throws.
                -- The search runs against an untouched inventory each time,
                -- so its ordering is a stable fallback identity.
                local key = found.slot or (name .. '#' .. j)
                local free = (found.count or 0) - (stagedFromSlot[key] or 0)
                local take = math.min(free, remaining)

                if take > 0 then
                    remaining = remaining - take
                    stagedFromSlot[key] = (stagedFromSlot[key] or 0) + take
                    lines[#lines + 1] = {
                        slot     = slotIndex,
                        inv_slot = found.slot,
                        portion  = portion,
                        source   = CB.SOURCE.ITEM,
                        item     = name,
                        quantity = take,
                        metadata = Util.copy(found.metadata) or {},
                    }
                end
            end

            -- GetItem said the creator holds enough and the slot walk did
            -- not find it. Refuse rather than escrow a quantity from
            -- nowhere.
            if remaining > 0 then return CB.ERR.INSUFFICIENT end
        end
        return nil
    end

    local function addWeapons(portion, list)
        if list == nil then return nil end
        if type(list) ~= 'table' then return CB.ERR.INVALID_REWARD end
        if not sourceEnabled('weapon') then return CB.ERR.INVALID_REWARD end
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
                if slots[j].slot == invSlot then found = slots[j] end
            end
            -- No fallback to "some weapon of that name". The creator picked
            -- a specific object out of a list the server itself built, and
            -- staking a different one — a kitted rifle instead of a bare
            -- one — is not a near-enough answer.
            if not found then return CB.ERR.INSUFFICIENT end
            -- Naming the same slot in two payouts would snapshot one weapon
            -- twice, take it once, then fail hunting for its twin.
            if (stagedFromSlot[found.slot] or 0) > 0 then return CB.ERR.INVALID_REWARD end
            stagedFromSlot[found.slot] = 1

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
                -- Multiply before dividing. `amount * (percent / 100)`
                -- computes a binary fraction first, and 29/100 is not one:
                -- 29% of 50,000 came out as 14,499, a unit short of what the
                -- creator promised and the hunter was shown.
                local extra = math.floor(line.amount * bonusPercent / 100)
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

    --- Put back everything already taken.
    ---
    --- This is the end of the line: there is nothing left to undo and no
    --- escrow record to hold the property in, so a give-back that fails has
    --- genuinely cost the creator something. It is recorded rather than
    --- shrugged off — the audit row is what tells staff exactly what to
    --- return by hand, and to whom.
    local function rollback()
        for i = #taken, 1, -1 do
            local line = taken[i]
            local back = false

            if line.source == 'cash' or line.source == 'bank' then
                back = actor.player.Functions.AddMoney(line.source, line.amount)
            elseif line.source == 'dirty' then
                back = exports.ox_inventory:AddItem(actor.source, Config.Sources.dirty.item, line.amount)
            elseif line.source == CB.SOURCE.ITEM then
                back = exports.ox_inventory:AddItem(actor.source, line.item, line.quantity, line.metadata)
            elseif line.source == CB.SOURCE.WEAPON then
                back = exports.ox_inventory:AddItem(actor.source, line.item, 1, line.metadata)
            end

            if not back then
                Audit.financial('escrow_rollback_failed', actor.cid, contractId, {
                    source = line.source, item = line.item,
                    amount = line.amount, quantity = line.quantity,
                })
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
            -- Names the metadata, so the slot that was staged is the slot
            -- that is taken rather than any stack of the same name.
            ok = exports.ox_inventory:RemoveItem(actor.source, line.item, line.quantity, line.metadata) and true or false
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

    -- Read back what was written. Ids are allocated from the lines the
    -- contract already had, and reading those yields on a real database —
    -- so two takes on one contract can allocate the same ids, and the
    -- second one's lines are then merged into the first's rather than
    -- stored. The money for them has already been confiscated.
    --
    -- Rather than trusting the count, every line is confirmed present and
    -- ours. One that is not means the id was taken in between: the whole
    -- take is rolled back and the caller can try again, which is far
    -- better than a creator charged for escrow that does not exist.
    local stored = {}
    for _, line in ipairs(Storage.readEscrow(contractId)) do stored[line.id] = line end

    for i = 1, #records do
        local mine = records[i]
        local found = stored[mine.id]
        if not found
            or found.source ~= mine.source
            or found.portion ~= mine.portion
            or (found.amount or 0) ~= (mine.amount or 0)
            or (found.quantity or 0) ~= (mine.quantity or 0) then
            Audit.rejected('escrow_id_collision', actor.cid, contractId, { line = mine.id })
            rollback()
            return false, CB.ERR.LOCKED
        end
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
---@param guard fun(line: table): boolean|nil called once per line, after it has
--- been taken out of `held` and before anything moves. Returning false puts
--- that line back and moves nothing. Use it for a condition that only
--- becomes binding once the line cannot be paid to anyone else.
---@return boolean moved  true when at least one line settled here
---@return table   result { settled = n, pending = n, skipped = n, refused = n }
function Escrow.release(contractId, recipientCid, filter, reason, guard)
    if type(filter) == 'string' then filter = { portion = filter } end
    local lines = Storage.readEscrow(contractId)
    local result = { settled = 0, pending = 0, skipped = 0, refused = 0 }

    for i = 1, #lines do
        local line = lines[i]
        local matches = true
        if filter then
            if filter.portion and line.portion ~= filter.portion then matches = false end
            if filter.slot and line.slot ~= filter.slot then matches = false end
            if filter.staker and line.staker ~= filter.staker then matches = false end

            if filter.line or filter.lines then
                -- Named lines and nothing else. A caller that names specific
                -- lines has said exactly what it means, so the general-refund
                -- exclusions below do not apply — but the name has to match,
                -- or this releases the whole contract.
                --
                -- `lines` is a set of ids rather than one: reducing a reward
                -- hands several lines back at once, and doing that as several
                -- releases would be several audit rows for one decision and
                -- several windows for an acceptance to land in the middle of.
                local named = filter.line and line.id == filter.line
                if not named and filter.lines then named = filter.lines[line.id] == true end
                if not named then matches = false end
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
        if line.owed_to and line.owed_to ~= recipientCid
            and not (filter and (filter.line or filter.lines)) then
            matches = false
        end

        if matches then
            -- Compare-and-set: only a line still `held` may be claimed, and
            -- the claim is what authorises moving the funds.
            local claimed = Storage.claimEscrowLine(line.id, CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING)
            if not claimed then
                result.skipped = result.skipped + 1
            elseif guard and not guard(line) then
                -- A release the caller wanted to make conditional on
                -- something it could only check once the line was already
                -- out of `held`.
                --
                -- A creator reducing a reward may not do it to a hunter who
                -- has accepted, and checking that before calling here is not
                -- enough: every storage read between the check and the money
                -- moving is a yield, and an acceptance can land in any of
                -- them. Claiming the line first and asking afterwards makes
                -- the answer binding — nothing else can pay this line while
                -- it sits in `releasing`, so a refusal can put it straight
                -- back with nothing moved.
                Storage.claimEscrowLine(line.id, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD)
                result.refused = result.refused + 1
            else
                -- Who this release is for, written before the money moves.
                -- A line caught mid-release at a shutdown otherwise recorded
                -- nobody, and staff settling it afterwards had no way to pay
                -- the person it was going to — which is the case the whole
                -- recovery path exists for.
                line.releasing_to = recipientCid
                Storage.writeEscrow(contractId, { line })

                local delivered = Escrow.deliver(recipientCid, line)
                if delivered then
                    -- The money is already with the recipient, so this is
                    -- settled whatever the store says. A refused settle
                    -- means something else took the line out of `releasing`
                    -- between the claim and here — recovery, or a second
                    -- server on the same database — and it is now at risk of
                    -- being paid again. Nothing here can fix that; the row
                    -- is what tells staff to look.
                    if not Storage.settleEscrowLine(line.id, recipientCid) then
                        Audit.financial('escrow_settle_lost', recipientCid, contractId,
                            { line = line.id })
                    end
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
        refused = result.refused > 0 and result.refused or nil,
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
        -- The answer matters. qbx_core's AddMoney returns false for an
        -- account it will not credit, and servers commonly patch a balance
        -- ceiling into it. Reporting success regardless settled the line
        -- with nothing delivered: gone from escrow, never arrived, and no
        -- record that anyone was still owed it.
        return recipient.Functions.AddMoney(account, amount) and true or false

    elseif line.source == 'dirty' then
        if not exports.ox_inventory:CanCarryItem(src, Config.Sources.dirty.item, line.amount) then return false end
        return exports.ox_inventory:AddItem(src, Config.Sources.dirty.item, line.amount) and true or false

    elseif line.source == CB.SOURCE.ITEM then
        if not exports.ox_inventory:CanCarryItem(src, line.item, line.quantity) then return false end
        -- The snapshot goes back exactly as it was taken. Without it a worn
        -- item returns pristine and a container returns as a fresh empty
        -- one, which mints value in the first case and destroys it in the
        -- second (§9.4).
        return exports.ox_inventory:AddItem(src, line.item, line.quantity, line.metadata) and true or false

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
        -- `owed_to` as well as the OWED portion. A line marked for one named
        -- person is already spoken for: the release a hunter's claim runs
        -- skips it, so counting it here advertises a reward bigger than
        -- anything that will ever be paid — and prices a bailout off money
        -- the target could never have won back. A withdrawal that could not
        -- be handed over, because the creator's pockets were full, leaves a
        -- line in exactly that state on a live contract.
        if matches and line.portion ~= CB.PORTION.STAKE
            and line.portion ~= CB.PORTION.OWED
            and not line.owed_to
            and CB.MONEY_SOURCES[line.source] then
            if line.state ~= CB.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0)
            end
        end
    end
    return total
end

--- What a slot holds beyond money: how many item stacks and how many
--- weapons, and what they are.
---
--- Items and weapons are deliberately not priced — an unpriceable item
--- would let a creator set any headline figure they liked — but leaving
--- them out of the projection entirely advertised a contract paying a
--- kitted rifle as $0. A hunter needs to know the goods are there to
--- decide, without being told a number nobody can defend.
---@return table { items = n, weapons = n, labels = { name, ... } }
function Escrow.goodsIn(contractId, filter)
    if type(filter) == 'string' then filter = { portion = filter } end

    local lines = Storage.readEscrow(contractId)
    local out = { items = 0, weapons = 0, labels = {} }
    local seen = {}

    for i = 1, #lines do
        local line = lines[i]
        local matches = true
        if filter then
            if filter.portion and line.portion ~= filter.portion then matches = false end
            if filter.slot and line.slot ~= filter.slot then matches = false end
        end

        -- Same rule as moneyValue: goods promised to one named person are
        -- not part of what this contract pays anybody else.
        if matches and line.state ~= CB.ESCROW_STATE.SETTLED
            and not line.owed_to
            and line.portion ~= CB.PORTION.STAKE and line.portion ~= CB.PORTION.OWED then

            if line.source == CB.SOURCE.ITEM then
                out.items = out.items + (line.quantity or 0)
            elseif line.source == CB.SOURCE.WEAPON then
                out.weapons = out.weapons + 1
            end

            -- Names only. A serial is an identifier and never crosses, and
            -- metadata is nobody's business but the parties'.
            if (line.source == CB.SOURCE.ITEM or line.source == CB.SOURCE.WEAPON)
                and line.item and not seen[line.item] then
                seen[line.item] = true
                out.labels[#out.labels + 1] = line.item
            end
        end
    end

    table.sort(out.labels)
    return out
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
                    if not Storage.settleEscrowLine(line.id, cid) then
                        Audit.financial('escrow_settle_lost', cid, line.contract_id,
                            { line = line.id })
                    end
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
