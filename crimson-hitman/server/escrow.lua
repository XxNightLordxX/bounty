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

--- Players owed something that could not be handed over, by citizen id, and
--- the earliest moment to try them again. See Escrow.retryWaiting.
local waiting = {}

--- When each queued entry that could not be handed over was last tried, by
--- citizen id and then pending entry id, as an attempt number.
---
--- A pass tries at most MaxRetriesPerLogin entries, and one that cannot be
--- handed over stays queued where it was. Taken oldest first, the same five
--- items that would not fit were tried on every pass for ever, and whatever
--- was queued behind them — a buyout premium in cash, which always fits —
--- was never tried at all. Least recently tried goes first instead.
local lastTried = {}
local attempts = 0

--- How many times something new has been queued for each player, so a
--- retry pass can tell whether anything arrived while it was running.
local wakes = {}

--- The ox_inventory items that are a money account, by name; read once per
--- start (accountItem).
local accountItems = nil

function Escrow.init(storage, audit)
    Storage, Audit = storage, audit
    waiting = {}
    lastTried = {}
    wakes = {}
    accountItems = nil
end

--- Remember that this player has a delivery queued, so the tick tries it
--- again while they are online rather than only at their next login.
---
--- `fresh` when something has just been queued for them. That is due now
--- whatever the player's wait between tries, and it is counted: a retry
--- pass running for this player at that moment had already read their
--- queue, found it empty and was about to forget them — a wake-up lost,
--- and the new payout left for a relog.
---@param cid string
---@param fresh boolean|nil
function Escrow.noteWaiting(cid, fresh)
    if not cid then return end
    if fresh then
        wakes[cid] = (wakes[cid] or 0) + 1
        waiting[cid] = 0
    elseif waiting[cid] == nil then
        waiting[cid] = 0
    end
end

--------------------------------------------------------------------------
-- Reading the same contract several times in one request
--------------------------------------------------------------------------

--- Opening the board asks what each contract is worth about seven times per
--- row — once for the sort key, and again for every figure the row shows —
--- and each of those is a separate Storage.readEscrow. On the mysql backend
--- that is a separate awaited SELECT that yields, so a single player opening
--- a 500-contract board issued hundreds of round trips to answer the same
--- question about the same contracts.
---
--- Memoised for the length of one projection and dropped afterwards. Strictly
--- a read path: Escrow.cached wraps code that does not write, and every
--- writer here drops the memo anyway, so nothing can read its own stale rows.
local memo = nil

local function readLines(contractId)
    if not memo then return Storage.readEscrow(contractId) end
    local hit = memo[contractId]
    if hit == nil then
        hit = Storage.readEscrow(contractId)
        memo[contractId] = hit
    end
    return hit
end

--- Anything that changes escrow throws the memo away rather than trying to
--- keep it correct. A cache that is sometimes right is worse than none.
local function forget() memo = nil end

--- Run a read-only projection with escrow reads memoised.
---
--- Nested calls share the outer memo, and an error inside still clears it:
--- a memo left open would be read by the next write path to come along.
---@param fn function
---@return any
function Escrow.cached(fn, ...)
    local outer = memo
    memo = outer or {}
    local ok, a, b, c = pcall(fn, ...)
    memo = outer
    if not ok then error(a, 0) end
    return a, b, c
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
---@param existingValue integer|nil money the contract already holds, so the
--- total ceiling bounds the contract rather than one request to add to it
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

--- Which item a dirty-money line is denominated in.
---
--- The line's own name when it has one, so escrow taken before a rename
--- comes back as what went in. Lines written by an older version carry
--- none, and the configured name is the only answer available for those.
---@param line table
---@return string
local function dirtyItemOf(line)
    return line.item or (Config.Sources.dirty and Config.Sources.dirty.item) or 'black_money'
end

local function isWeaponName(name)
    return type(name) == 'string' and name:upper():sub(1, 7) == 'WEAPON_'
end

--- An item name as ox_inventory reads it: lower case, and a weapon's in upper
--- case. It folds case on every lookup, so 'Handcuffs' and 'handcuffs' are
--- one item to it — and the blacklist and the dirty-money check compared
--- the name exactly as the client sent it, so a capital letter walked a
--- blacklisted item, or black money past its own cap, into escrow.
local function canonicalItem(name)
    if type(name) ~= 'string' then return name end
    local lower = name:lower()
    if lower:sub(1, 7) == 'weapon_' then return lower:upper() end
    return lower
end

--- Whether an item IS money: one of the accounts the server keeps as an
--- inventory item.
---
--- On Qbox, cash is the item 'money'. qbx_core keeps the item and the cash
--- balance in step, and ox_inventory moves the balance when the item
--- moves, both by the list in the convar inventory:accounts (default
--- '["money"]'). Offered as an item, cash went into escrow past
--- Config.Sources.cash altogether, its switch and its ceiling, and showed
--- on the board as goods: the hole closed for black_money (isDirtyItem),
--- open for the other currency. Read from the same convar, so a server
--- that keeps more accounts as items has all of them refused.
local function accountItem(name)
    if not accountItems then
        accountItems = {}
        local ok, list = pcall(function()
            return json.decode(GetConvar('inventory:accounts', '["money"]'))
        end)
        if not ok or type(list) ~= 'table' then list = { 'money' } end
        for _, item in pairs(list) do
            if type(item) == 'string' then accountItems[canonicalItem(item)] = true end
        end
    end
    return accountItems[canonicalItem(name)] == true
end

--- Whether a name is on the blacklist, compared the way the inventory
--- compares names. An operator writing 'Handcuffs' in the config is covered
--- too. An item that is money is on it whatever the config says.
local function blacklisted(name)
    local wanted = canonicalItem(name)
    for listed, on in pairs(Config.EscrowBlacklist or {}) do
        if on and canonicalItem(listed) == wanted then return true end
    end
    return accountItem(name)
end

local function isDirtyItem(name)
    local dirtyItem = Config.Sources.dirty and Config.Sources.dirty.item
    return dirtyItem ~= nil and canonicalItem(dirtyItem) == canonicalItem(name)
end

-- The picker offers what the server will take, by the same rule.
Escrow.blacklisted = blacklisted
Escrow.isDirtyItem = isDirtyItem

--- Metadata keys that say whose an item is, as the resources that write
--- them spell them, compared without case.
local OWNER_KEYS = {
    citizenid = true, cid = true, owner = true, ownername = true,
    name = true, firstname = true, lastname = true, fullname = true,
    phonenumber = true, lbphonenumber = true, phone_number = true,
    dob = true, birthdate = true, dateofbirth = true,
}

--- Whether any of these item lines would tell whoever receives it who put
--- it up.
---
--- An item goes into escrow with its metadata, and comes out the other end
--- with it, which is the point (§9.4). For an anonymous client that is a
--- name tag: ox_inventory's `identification` carries the holder's name and
--- date of birth, a unique lb-phone carries its number, and a bank card or
--- a key from another resource carries its owner. The weapon path strips
--- `registered` on delivery for exactly this reason (handedOver); an item
--- cannot be stripped without breaking it, so it is refused instead.
---
--- Two tests: a key that names an owner, whatever it holds; and the
--- client's own citizen id, name or phone number anywhere in a value,
--- whatever the key (`identification` keeps the name under `type`).
--- Weapons are left to handedOver. Only the items' own lines are read.
---@param actor table the client
---@param lines table[] from Escrow.validate
---@return boolean
function Escrow.namesOwner(actor, lines)
    local needles = {}
    local function want(value)
        if type(value) == 'number' then value = tostring(math.floor(value)) end
        if type(value) == 'string' and #value >= 3 then needles[#needles + 1] = value:lower() end
    end
    want(actor and actor.cid)
    want(actor and actor.name)
    local charinfo = actor and actor.player and actor.player.PlayerData
        and actor.player.PlayerData.charinfo
    if type(charinfo) == 'table' then want(charinfo.phone) end

    local function carries(meta, depth)
        if type(meta) ~= 'table' or depth > 4 then return false end
        for key, value in pairs(meta) do
            if type(key) == 'string' and OWNER_KEYS[key:lower()] and value ~= nil
                and value ~= false and value ~= '' then
                return true
            end
            if type(value) == 'table' then
                if carries(value, depth + 1) then return true end
            elseif type(value) == 'string' or type(value) == 'number' then
                local text = tostring(value):lower()
                for i = 1, #needles do
                    if text:find(needles[i], 1, true) then return true end
                end
            end
        end
        return false
    end

    for i = 1, #(lines or {}) do
        local line = lines[i]
        if line.source == CH.SOURCE.ITEM and carries(line.metadata, 1) then return true end
    end
    return false
end

function Escrow.validate(actor, spec, bonusPercent, existingLines, existingValue)
    if type(spec) ~= 'table' then return nil, CH.ERR.INVALID_REWARD end

    local slots = spec.slots
    if slots == nil then
        slots = { { baseline = spec.baseline, bonus = spec.bonus } }
    end
    if type(slots) ~= 'table' or #slots < 1 or #slots > Config.Limits.MaxPayoutSlots then
        return nil, CH.ERR.INVALID_REWARD
    end

    local lines = {}
    local moneyTotal = 0
    local slotIndex = 0

    local function addMoney(portion, source, rawAmount)
        local rule = Config.Sources[source]
        if not rule or not rule.enabled then return CH.ERR.INVALID_REWARD end
        local amount = Util.toPositive(rawAmount, rule.max)
        if not amount then return CH.ERR.INVALID_REWARD end

        local held
        if source == 'cash' or source == 'bank' then
            held = actor.player.Functions.GetMoney(source) or 0
        else
            held = exports.ox_inventory:GetItem(actor.source, rule.item, nil, true) or 0
        end
        if held < amount then return CH.ERR.INSUFFICIENT end

        local line = { slot = slotIndex, portion = portion, source = source, amount = amount }

        -- Dirty money is an item, so the line remembers which one.
        --
        -- Every read and write of it went through Config.Sources.dirty.item
        -- at the moment of the call, so an operator who renamed that setting
        -- while escrow was held took one currency out of a player's pocket
        -- and handed a different one back — destroying the first and minting
        -- the second. Items and weapons have recorded their own identity
        -- since §9.4; this is the same rule for the third money source.
        if source == CH.SOURCE.DIRTY then line.item = rule.item end

        lines[#lines + 1] = line
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
    -- then fails searching for a second copy of it and rolls the whole
    -- contract back — a fully-funded contract refused as insufficient.
    --
    -- Weapons share the counter for the opposite reason: a weapon is one
    -- physical object, so a slot named twice is refused rather than walked
    -- past.
    local stagedFromSlot = {}

    local function addItems(portion, list)
        if list == nil then return nil end
        if type(list) ~= 'table' then return CH.ERR.INVALID_REWARD end
        -- The kill switch was read only where the picker is built, so an
        -- operator who turned item escrow off still had it work for anyone
        -- sending the payload by hand. A config switch that only the UI
        -- honours is not a switch.
        if not sourceEnabled('item') then return CH.ERR.INVALID_REWARD end
        if #list > Config.Sources.item.maxStacks then return CH.ERR.INVALID_REWARD end

        for i = 1, #list do
            local entry = list[i]
            if type(entry) ~= 'table' then return CH.ERR.INVALID_REWARD end
            local name = canonicalItem(Util.sanitizeText(entry.name, 64))
            local count = Util.toPositive(entry.count, Config.Sources.item.maxPerStack)
            if not name or not count then return CH.ERR.INVALID_REWARD end
            if blacklisted(name) then return CH.ERR.INVALID_REWARD end

            -- Dirty money is an inventory item, so without this it can be
            -- escrowed twice over: once as `dirty`, which is capped by
            -- Config.Sources.dirty.max and switched by its `enabled` flag,
            -- and again through the item picker, which is neither. A server
            -- that had turned dirty money off entirely still took it, and a
            -- creator could put up more of it than the ceiling allows by
            -- offering the rest as an item. It also read as two different
            -- things on the board.
            --
            -- Compared against the configured item name rather than a
            -- literal, because that name is the operator's to choose.
            if isDirtyItem(name) then return CH.ERR.INVALID_REWARD end

            -- A weapon is one physical object with a serial, attachments and
            -- wear. Through this path it would be stored as a bare name and
            -- handed back as a fresh clean one: attachments destroyed, wear
            -- refunded, serial laundered. Weapons go through addWeapons,
            -- which snapshots the metadata, or they do not go at all.
            if isWeaponName(name) then return CH.ERR.INVALID_REWARD end

            local held = exports.ox_inventory:GetItem(actor.source, name, nil, true) or 0
            if held < count then return CH.ERR.INSUFFICIENT end

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
                        source   = CH.SOURCE.ITEM,
                        item     = name,
                        quantity = take,
                        metadata = Util.copy(found.metadata) or {},
                    }
                end
            end

            -- GetItem said the creator holds enough and the slot walk did
            -- not find it. Refuse rather than escrow a quantity from
            -- nowhere.
            if remaining > 0 then return CH.ERR.INSUFFICIENT end
        end
        return nil
    end

    local function addWeapons(portion, list)
        if list == nil then return nil end
        if type(list) ~= 'table' then return CH.ERR.INVALID_REWARD end
        if not sourceEnabled('weapon') then return CH.ERR.INVALID_REWARD end
        if #list > Config.Sources.weapon.max then return CH.ERR.INVALID_REWARD end

        for i = 1, #list do
            local entry = list[i]
            if type(entry) ~= 'table' then return CH.ERR.INVALID_REWARD end
            local name = canonicalItem(Util.sanitizeText(entry.name, 64))
            -- The inventory slot the weapon is being taken FROM. Named
            -- distinctly from the payout slot (`slotIndex`, set by the
            -- enclosing loop): they are different numbers with different
            -- meanings, and conflating them orphans the escrow line.
            local invSlot = Util.toPositive(entry.slot, 200)
            if not name or not invSlot then return CH.ERR.INVALID_REWARD end
            if blacklisted(name) then return CH.ERR.INVALID_REWARD end
            -- The weapons list takes weapons. Anything else sent here was
            -- escrowed as a "weapon": past the item switch an operator had
            -- turned off, past the item stack limits, and on the board as a
            -- weapon. The items list refuses weapons the same way round.
            if not isWeaponName(name) then return CH.ERR.INVALID_REWARD end

            -- Dirty money is an inventory item, so without this it can be
            -- escrowed twice over: once as `dirty`, which is capped by
            -- Config.Sources.dirty.max and switched by its `enabled` flag,
            -- and again through the item picker, which is neither. A server
            -- that had turned dirty money off entirely still took it, and a
            -- creator could put up more of it than the ceiling allows by
            -- offering the rest as an item. It also read as two different
            -- things on the board.
            --
            -- Compared against the configured item name rather than a
            -- literal, because that name is the operator's to choose.
            if isDirtyItem(name) then return CH.ERR.INVALID_REWARD end

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
            if not found then return CH.ERR.INSUFFICIENT end
            -- Naming the same slot in two payouts would snapshot one weapon
            -- twice, take it once, then fail searching for its twin.
            if (stagedFromSlot[found.slot] or 0) > 0 then return CH.ERR.INVALID_REWARD end
            stagedFromSlot[found.slot] = 1

            lines[#lines + 1] = {
                slot     = slotIndex,          -- payout slot this reward belongs to
                inv_slot = found.slot,         -- where it came from, for the audit trail
                portion  = portion,
                source   = CH.SOURCE.WEAPON,
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
        if type(set) ~= 'table' then return nil, CH.ERR.INVALID_REWARD end

        local before = #lines
        for _, portion in ipairs({ CH.PORTION.BASELINE, CH.PORTION.BONUS }) do
            local part = set[portion]
            if part ~= nil then
                if type(part) ~= 'table' then return nil, CH.ERR.INVALID_REWARD end
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
        if Util.escrowIsEmpty(slotLines, CH.PORTION.BASELINE) then
            return nil, CH.ERR.INVALID_REWARD
        end
    end

    -- A kidnapping bonus set as a percentage is turned into real escrow
    -- here. A percentage that is only stored and displayed pays nothing:
    -- the bonus release finds no lines and a live delivery is worth exactly
    -- what a kill is worth.
    bonusPercent = Util.toCount(bonusPercent, Config.Bonus.maxPercent) or 0
    if bonusPercent > 0 then
        -- A slot that already names its own money bonus is left alone: the
        -- creator said exactly what they meant, and deriving another on top
        -- would charge them twice for one promise. Money only: goods marked
        -- for a live delivery are a different promise, made beside the
        -- percentage, and counting them here silently dropped the money
        -- bonus from any payout carrying one.
        local explicit = {}
        for i = 1, #lines do
            if lines[i].portion == CH.PORTION.BONUS and CH.MONEY_SOURCES[lines[i].source] then
                explicit[lines[i].slot] = true
            end
        end

        local derived = {}
        for i = 1, #lines do
            local line = lines[i]
            if line.portion == CH.PORTION.BASELINE
                and not explicit[line.slot]
                and CH.MONEY_SOURCES[line.source] then
                -- Multiply before dividing. `amount * (percent / 100)`
                -- computes a binary fraction first, and 29/100 is not one:
                -- 29% of 50,000 came out as 14,499, a unit short of what the
                -- creator promised and the hitman was shown.
                local extra = math.floor(line.amount * bonusPercent / 100)
                if extra > 0 then
                    derived[#derived + 1] = {
                        slot = line.slot, portion = CH.PORTION.BONUS,
                        source = line.source, amount = extra,
                        -- Denominated in whatever the baseline it derives
                        -- from is, so a rename cannot turn a bonus and the
                        -- line it was computed from into two currencies.
                        item = line.item,
                        -- Marked, so raising the percentage later can tell a
                        -- bonus this resource worked out from a percentage
                        -- apart from one the creator named themselves. A
                        -- top-up must recompute the first and leave the
                        -- second alone.
                        derived = true,
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

    -- Counted against what the contract already holds, not just against
    -- this submission. The ceiling was applied to one call at a time, so a
    -- creator could top a contract up past it in as many steps as they
    -- liked — and the setting exists to bound what one contract can be
    -- worth, which is a property of the contract, not of a request.
    if moneyTotal + (existingValue or 0) > Config.MaxContractValue then
        return nil, CH.ERR.INVALID_REWARD
    end

    -- The per-payout limits multiply, so the total needs its own ceiling.
    -- Callers adding to a contract that already holds escrow pass the count
    -- it holds, so a top-up cannot walk past the limit one line at a time.
    if #lines + (existingLines or 0) > Config.Limits.MaxEscrowLines then
        return nil, CH.ERR.INVALID_REWARD
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
        if CH.MONEY_SOURCES[line.source] then
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
        if held < total then return CH.ERR.INSUFFICIENT end
    end

    for name, total in pairs(items) do
        local held = exports.ox_inventory:GetItem(actor.source, name, nil, true) or 0
        if held < total then return CH.ERR.INSUFFICIENT end
    end

    return nil
end

--------------------------------------------------------------------------
-- Taking escrow
--------------------------------------------------------------------------

local takeUnlocked

--- Contracts with a take in flight in this process.
---
--- Line ids are allocated from the lines a contract already holds, and on
--- mysql reading those is an await. Two takes on one contract in the same
--- instant — two hitmen staking a competitive contract, a top-up sent
--- twice — allocated the same id, and the second write merged into the
--- first row instead of adding one: two people charged, one line held. The
--- read-back below compared source, portion and amount, which two stakes
--- of the same figure share, so it passed both and one stake stopped
--- existing. One take per contract at a time closes the allocation race;
--- the loser is told the contract is busy and nothing is charged.
local taking = {}

--- Call another resource's export, treating a raise as a refusal.
---
--- ox_inventory's and qbx_core's calls can raise (a patched hook, a
--- dependency mid-restart), and on the take, the rollback and the delivery
--- a raise skipped the code that keeps the books: money charged with
--- nothing held, or a line left in `releasing`.
---@return boolean ok
---@return string|nil raised the error, when it raised
local function guarded(fn, ...)
    local ran, result = pcall(fn, ...)
    if not ran then return false, tostring(result) end
    return result and true or false, nil
end

--- Confiscate the validated lines and write the escrow record as one
--- operation. On any failure everything already taken is put back, so a
--- partially-charged creator is not a reachable state (§3.5).
---@param actor table
---@param contractId string
---@param lines table[] from Escrow.validate
---@return boolean ok
---@return string|nil err
---@return table<string, boolean>|nil ids the stored line ids, on success
function Escrow.take(actor, contractId, lines)
    if taking[contractId] then return false, CH.ERR.LOCKED end
    taking[contractId] = true
    local ok, result, err, ids = pcall(takeUnlocked, actor, contractId, lines)
    taking[contractId] = nil
    if not ok then error(result, 0) end
    return result, err, ids
end

takeUnlocked = function(actor, contractId, lines)
    forget()
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

            -- Each give-back in its own pcall: one that raised stopped the
            -- loop, and every line after it stayed taken with no row.
            if line.source == 'cash' or line.source == 'bank' then
                back = Util.credit(actor.player, line.source, line.amount)
            elseif line.source == 'dirty' then
                back = guarded(function()
                    return exports.ox_inventory:AddItem(actor.source, dirtyItemOf(line), line.amount)
                end)
            elseif line.source == CH.SOURCE.ITEM then
                back = guarded(function()
                    return exports.ox_inventory:AddItem(actor.source, line.item, line.quantity, line.metadata)
                end)
            elseif line.source == CH.SOURCE.WEAPON then
                back = guarded(function()
                    return exports.ox_inventory:AddItem(actor.source, line.item, 1, line.metadata)
                end)
            end

            if not back then
                Audit.financial('escrow_rollback_failed', actor.cid, contractId, {
                    source = line.source, item = line.item,
                    amount = line.amount, quantity = line.quantity,
                })
            end
        end
    end

    -- Ids are allocated after whatever the contract already holds, so a
    -- later top-up (§12.1) appends rather than overwriting the original
    -- lines. A caller-supplied id is respected if it is already unique.
    --
    -- Before anything is charged: the read yields on mysql and raises on a
    -- dropped connection, and one that raised after the charge kept the
    -- creator's reward, or a hitman's stake, with nothing written for it and
    -- nothing put back.
    local existing = Storage.readEscrow(contractId)
    local used = {}
    for i = 1, #existing do used[existing[i].id] = true end

    local records = {}
    local nextIndex = #existing
    for i = 1, #lines do
        local line = Util.copy(lines[i])
        line.contract_id = contractId
        line.state = CH.ESCROW_STATE.HELD
        line.slot = line.slot or 1
        -- Who it came from, on the line itself. A new contract's escrow is
        -- written before its row, and a crash between the two left lines
        -- naming a contract that does not exist: nothing said whose they
        -- were, so nothing could hand them back (Contracts.recoverNeverPlaced).
        line.taken_from = actor.cid

        if not line.id or used[line.id] then
            repeat
                nextIndex = nextIndex + 1
                line.id = contractId .. ':' .. tostring(nextIndex)
            until not used[line.id]
        end
        used[line.id] = true

        records[#records + 1] = line
    end

    for i = 1, #lines do
        local line = lines[i]
        local ok, raised = false, nil

        if line.source == 'cash' or line.source == 'bank' then
            -- Through Util.charge, which reads the balance before it
            -- removes. RemoveMoney's return is not an affordability check:
            -- qbx_core ships dontAllowMinus as { 'cash', 'crypto' }, so a
            -- bank debit succeeds on an empty account and reports success.
            --
            -- Escrow.validate did check, against the live balance — and then
            -- money moves between the check and here. The anonymity fee is
            -- charged in exactly that window, out of the same account, which
            -- is how a creator with exactly enough for the escrow funded a
            -- contract out of an overdraft nobody offered them: checked
            -- 10,000 against 10,000, took the 500 fee, debited 10,000 from
            -- 9,500, and reported success with the balance at -500.
            --
            -- The fee is only the reachable case. Re-reading here covers
            -- anything that moves money in that window, including another
            -- resource, and costs one balance read on a path that is already
            -- writing to the database.
            ok, raised = guarded(Util.charge, actor.player, line.source, line.amount)
        elseif line.source == 'dirty' then
            ok, raised = guarded(function()
                return exports.ox_inventory:RemoveItem(actor.source, dirtyItemOf(line), line.amount)
            end)
        elseif line.source == CH.SOURCE.ITEM then
            -- Names the metadata, so the slot that was staged is the slot
            -- that is taken rather than any stack of the same name.
            ok, raised = guarded(function()
                return exports.ox_inventory:RemoveItem(actor.source, line.item, line.quantity, line.metadata)
            end)
        elseif line.source == CH.SOURCE.WEAPON then
            ok, raised = guarded(function()
                return exports.ox_inventory:RemoveItem(actor.source, line.item, 1, line.metadata)
            end)
        end

        -- A raise is a refusal. It used to leave this loop through
        -- Escrow.take, past the rollback, with nothing written: every line
        -- charged before it was gone, and the stuck-create retry found no
        -- lines to return. Whether the line that raised moved first cannot
        -- be known from here, so the row names it for staff to check.
        if raised then
            Audit.financial('escrow_take_raised', actor.cid, contractId, {
                source = line.source, item = line.item, amount = line.amount,
                quantity = line.quantity, error = raised,
            })
        end
        if not ok then
            rollback()
            return false, CH.ERR.INSUFFICIENT
        end
        taken[#taken + 1] = line
    end

    -- A write that failed may or may not have landed — a connection can drop
    -- after the commit, which a single statement reports by raising and a
    -- transaction by answering false — so it is not refunded blind: that
    -- paid the creator back and left the lines to be returned to them a
    -- second time. What the store holds decides, below. One that raised with
    -- nothing stored used to keep the creator's money with nothing held for it.
    local wrote, ok = pcall(Storage.writeEscrow, contractId, records)
    if not wrote or not ok then
        Audit.rejected('escrow_write_failed', actor.cid, contractId,
            { error = not wrote and tostring(ok) or nil })
        local read, rows = pcall(Storage.readEscrow, contractId)
        if not read then
            -- Nothing says whether it landed: the store that refused the
            -- write is refusing the read too. Refunded blind, a copy that
            -- did land is paid back a second time (above; a stake by
            -- Contracts.recoverJoining), so the raise goes on to the caller
            -- as before — but no longer with nothing to say what was taken.
            -- The row names every line, so staff can return one the store
            -- does not have.
            local charged = {}
            for i = 1, #records do
                local r = records[i]
                charged[i] = { id = r.id, source = r.source, amount = r.amount,
                    item = r.item, quantity = r.quantity }
            end
            Audit.financial('escrow_take_unverified', actor.cid, contractId,
                { lines = charged, error = tostring(rows) })
            error(rows, 0)
        end
        local present = {}
        for _, line in ipairs(rows or {}) do present[line.id] = true end
        local any = false
        for i = 1, #records do
            if present[records[i].id] then any = true end
        end
        if not any then
            rollback()
            return false, CH.ERR.BAD_STATE
        end
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
    --
    -- A read-back that raises is not a collision. The lines are stored —
    -- the write said so, or the read above saw them — and `taking` keeps a
    -- second take off these ids, so they are kept rather than refunded on
    -- top of being held.
    local read, rows = pcall(Storage.readEscrow, contractId)
    if read then
        local stored = {}
        for _, line in ipairs(rows or {}) do stored[line.id] = line end

        for i = 1, #records do
            local mine = records[i]
            local found = stored[mine.id]
            if not found
                or found.source ~= mine.source
                or found.portion ~= mine.portion
                -- Whose it is, too: two stakes of the same figure agree on
                -- everything else.
                or found.staker ~= mine.staker
                or found.item ~= mine.item
                or (found.amount or 0) ~= (mine.amount or 0)
                or (found.quantity or 0) ~= (mine.quantity or 0) then
                Audit.rejected('escrow_id_collision', actor.cid, contractId, { line = mine.id })
                rollback()
                return false, CH.ERR.LOCKED
            end
        end
    else
        Audit.rejected('escrow_readback_failed', actor.cid, contractId, { error = tostring(rows) })
    end

    Audit.financial('escrow_taken', actor.cid, contractId, { lines = #records })

    -- The ids the new lines were stored under, as a set a release filter
    -- takes. A caller that finds the contract closed under it once the take
    -- has landed needs to hand exactly these back, and nothing else.
    local ids = {}
    for i = 1, #records do ids[records[i].id] = true end
    return true, nil, ids
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
    forget()
    if type(filter) == 'string' then filter = { portion = filter } end
    local lines = Storage.readEscrow(contractId)
    local result = { settled = 0, pending = 0, skipped = 0, refused = 0 }

    --- Line ids already waiting in this recipient's retry queue.
    ---
    --- A cancel, an expiry or a buyout releases to the creator and then
    --- finalise() sweeps the "unclaimed remainder" to the SAME creator. For a
    --- creator who is offline the first pass queues every line, and the second
    --- re-claims each one — it is owed to them, not to somebody else, so the
    --- filter lets it through — fails to deliver again, and queued it a second
    --- time. No backend de-duplicates the queue. Measured: nine entries for
    --- five lines, and on login a retry budget of five spent partly on
    --- duplicates, so which part of the payout actually arrived depended on
    --- the order the store handed the rows back, while the app told the player
    --- their outstanding payment had been delivered.
    ---
    --- Read once, and only when a delivery has actually failed.
    local queuedAlready
    local function isQueued(lineId)
        if not queuedAlready then
            queuedAlready = {}
            for _, entry in ipairs(Storage.readPending(recipientCid) or {}) do
                queuedAlready[entry.line_id] = true
            end
        end
        return queuedAlready[lineId] == true
    end

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
                and (line.portion == CH.PORTION.STAKE or line.portion == CH.PORTION.OWED) then
                -- A release that names no portion is a general refund. It
                -- must not sweep up a hitman's stake, nor money already
                -- promised to a named person.
                matches = false
            end
        elseif line.portion == CH.PORTION.STAKE or line.portion == CH.PORTION.OWED then
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
            local claimed = Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)

            -- And paid as it stands now it is ours, not as it was read. The
            -- read above is an await before the claim on mysql, and a stake
            -- lowered in between (Escrow.reduceStake, guarded on `held`)
            -- was paid at its old figure on top of the difference the cut
            -- had already paid out: 2,000 + 1,500 from a 2,000 stake. Once
            -- it is `releasing` nothing else can change it.
            if claimed then
                line = Storage.readEscrowLine(line.id) or line
                if line.owed_to and line.owed_to ~= recipientCid
                    and not (filter and (filter.line or filter.lines)) then
                    -- Owed to somebody else in the same window: theirs.
                    Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD)
                    claimed = false
                end
            end

            if not claimed then
                result.skipped = result.skipped + 1
            elseif guard and not guard(line) then
                -- A release the caller wanted to make conditional on
                -- something it could only check once the line was already
                -- out of `held`.
                --
                -- A creator reducing a reward may not do it to a hitman who
                -- has accepted, and checking that before calling here is not
                -- enough: every storage read between the check and the money
                -- moving is a yield, and an acceptance can land in any of
                -- them. Claiming the line first and asking afterwards makes
                -- the answer binding — nothing else can pay this line while
                -- it sits in `releasing`, so a refusal can put it straight
                -- back with nothing moved.
                Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD)
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
                    -- would sweep a hitman's undelivered payout to the
                    -- creator, quietly paying the wrong person.
                    local alreadyQueued = line.owed_to == recipientCid
                        and isQueued(line.id)

                    line.owed_to = recipientCid
                    Storage.writeEscrow(contractId, { line })
                    Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD)
                    if Escrow.parked(line) then
                        -- Its give kept raising (Escrow.deliver): still
                        -- theirs, and left for staff rather than queued for
                        -- another try. An entry already queued is cleared by
                        -- the retry that next reads it.
                        result.parked = (result.parked or 0) + 1
                    else
                        if not alreadyQueued then
                            Storage.queuePending(recipientCid, contractId, line.id)
                            -- Kept current if it has been read, so a second
                            -- line in this same pass sees the first one's entry.
                            if queuedAlready then queuedAlready[line.id] = true end
                        end
                        -- After the entry exists, so a retry that reads the
                        -- queue on this wake-up finds it there.
                        Escrow.noteWaiting(recipientCid, not alreadyQueued)
                    end
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

--- The metadata a weapon is handed over with.
---
--- ox_inventory writes the owner's character name into a weapon's
--- `registered`, and keeps it wherever the weapon goes. A weapon an
--- anonymous client put up reached the hitman registered to the client by
--- name, in inventory data their own game holds. Paid to anyone but the
--- client it goes unregistered — false, which ox_inventory leaves as it is
--- rather than writing the new holder's name in. The serial and everything
--- else go with it unchanged, and the stored snapshot is not touched, so a
--- refund is the weapon exactly as it was taken. A contract that can no
--- longer be read is treated as anonymous — except by the one the line came
--- from, who gets back what they put up: a contract that was never stored
--- cannot be read, and its client's own weapon went back to them unregistered.
---@return table|nil metadata
local function handedOver(recipientCid, line)
    local meta = line.metadata
    if type(meta) ~= 'table' or type(meta.registered) ~= 'string' then return meta end
    if line.taken_from ~= nil and line.taken_from == recipientCid then return meta end
    local contract = line.contract_id and Storage.readContract(line.contract_id)
    if contract and (not contract.anon_creator or contract.creator_cid == recipientCid) then
        return meta
    end
    local copy = Util.copy(meta)
    copy.registered = false
    return copy
end

--- How many times in a row a line's give may raise before it is left for
--- staff. A delivery that succeeds settles the line, so every raise on a
--- line still owed is one more in the same row.
Escrow.DELIVER_RAISE_LIMIT = 3

--- Whether a line's give has raised DELIVER_RAISE_LIMIT times and it now
--- waits for staff (/ch-stuck, /ch-settle) rather than another try.
---@param line table
---@return boolean
function Escrow.parked(line)
    return type(line) == 'table'
        and (tonumber(line.deliver_raises) or 0) >= Escrow.DELIVER_RAISE_LIMIT
end

--- Hand a single escrow line to a player. Returns false when it cannot be
--- delivered right now — never destroys the property to force success.
---@return boolean
function Escrow.deliver(recipientCid, line)
    -- Left for staff: nothing gives it again until they have looked.
    if Escrow.parked(line) then return false end

    local recipient = exports.qbx_core:GetPlayerByCitizenId(recipientCid)
    if not recipient or not recipient.PlayerData then return false end

    local src = recipient.PlayerData.source

    if line.source == 'cash' or line.source == 'bank' then
        local account, amount = line.source, line.amount
        -- Paid in the account it was taken from, always (§14.10). There is
        -- no conversion to dirty money: clean money paid out as dirty is a
        -- laundering rail, and the setting that claimed to offer it was
        -- never wired to anything.
        --
        -- The answer matters. qbx_core's AddMoney returns false for an
        -- account it will not credit, and servers commonly patch a balance
        -- ceiling into it. Reporting success regardless settled the line
        -- with nothing delivered: gone from escrow, never arrived, and no
        -- record that anyone was still owed it.
        return Util.credit(recipient, account, amount)
    end

    -- Each call inside guarded, so a raise never leaves the line in
    -- `releasing` until the next restart's recovery: the release goes on to
    -- keep its books. A CanCarryItem that raised gave nothing, so the line
    -- is not delivered and the caller keeps it owed.
    --
    -- An AddItem that raised is not delivered either. It was settled as
    -- delivered (§14.12's unknown give), but a raise is almost always one
    -- that gave nothing: a hook or a dependency failing before the item
    -- moved. Settled, the property was gone for good with nobody owed it,
    -- which is the one thing this function exists not to do; and a hook
    -- that kept raising lost every line it touched. So it stays owed, with
    -- a row naming it. A raise that came after the item was given would
    -- give it again on the next try, so the tries are bounded: after
    -- DELIVER_RAISE_LIMIT raises in a row the line is left for staff
    -- (/ch-stuck), held and owed to the same player, and nothing gives it
    -- again until staff settle it. At most that many copies, and the rows
    -- say which line and how many times.
    local name, count, metadata
    if line.source == 'dirty' then
        name, count = dirtyItemOf(line), line.amount
    elseif line.source == CH.SOURCE.ITEM then
        -- The snapshot goes back exactly as it was taken. Without it a worn
        -- item returns pristine and a container returns as a fresh empty
        -- one, which mints value in the first case and destroys it in the
        -- second (§9.4).
        name, count, metadata = line.item, line.quantity, line.metadata
    elseif line.source == CH.SOURCE.WEAPON then
        -- The snapshot goes back exactly as it was taken: serial, attachments
        -- and durability all restored (§9.4). Bar the name of an anonymous
        -- client, to anybody else (handedOver).
        name, count, metadata = line.item, 1, handedOver(recipientCid, line)
    else
        return false
    end

    -- CanCarryItem answers nil for an item it does not know.
    local fits = guarded(function()
        return exports.ox_inventory:CanCarryItem(src, name, count)
    end)
    if not fits then return false end

    local gave, raised = guarded(function()
        return exports.ox_inventory:AddItem(src, name, count, metadata)
    end)
    if raised then
        -- Counted on the line, so the bound holds across restarts too.
        line.deliver_raises = (tonumber(line.deliver_raises) or 0) + 1
        Storage.writeEscrow(line.contract_id, { line })
        Audit.financial('escrow_deliver_raised', recipientCid, line.contract_id, {
            line = line.id, source = line.source, item = name, count = count, error = raised,
            raises = line.deliver_raises,
        })
        if Escrow.parked(line) then
            Audit.financial('escrow_deliver_parked', recipientCid, line.contract_id, {
                line = line.id, source = line.source, item = name, count = count,
                raises = line.deliver_raises, review = true,
            })
            print(('[crimson-hitman] escrow line %s: giving %s x%s raised %d times; left for '
                .. 'staff (/ch-stuck) — check whether they already have it')
                :format(tostring(line.id), tostring(name), tostring(count), line.deliver_raises))
        end
        return false
    end
    return gave
end

--- What a contract holds, split by money source.
---
--- moneyValue adds the three together, which is what the board showed: one
--- dollar figure covering cash, bank and black money alike. Those are not
--- the same thing — black money sells for a fraction of its face value —
--- so a hitman deciding on "$250,000" could be looking at a quarter of a
--- million black_money items and have no way to tell.
---@param contractId string
---@param filter table|string|nil
---@return table { cash = n, bank = n, dirty = n }
function Escrow.moneyBySource(contractId, filter)
    if type(filter) == 'string' then filter = { portion = filter } end

    local lines = readLines(contractId)
    local out = { cash = 0, bank = 0, dirty = 0 }

    for i = 1, #lines do
        local line = lines[i]
        local matches = true
        if filter then
            if filter.portion and line.portion ~= filter.portion then matches = false end
            if filter.slot and line.slot ~= filter.slot then matches = false end
        end

        -- The same exclusions moneyValue applies, so the parts add up to it.
        if matches and line.portion ~= CH.PORTION.STAKE
            and line.portion ~= CH.PORTION.OWED
            and not line.owed_to
            and CH.MONEY_SOURCES[line.source]
            and line.state ~= CH.ESCROW_STATE.SETTLED then
            out[line.source] = (out[line.source] or 0) + (line.amount or 0)
        end
    end

    return out
end

--- The extra escrow needed to move a derived kidnapping bonus from one
--- percentage to another.
---
--- The bonus is real escrow, taken at creation, not a number on the
--- contract: the payout releases bonus lines, so a raise that only stored a
--- bigger percentage told every hitman the terms had improved and paid them
--- exactly what it did before.
---
--- Only slots whose bonus this resource derived are topped up. A slot where
--- the creator named their own bonus is theirs, and recomputing it from a
--- percentage would overwrite a figure they chose.
---@param contractId string
---@param fromPercent integer
---@param toPercent integer
---@return table[] lines  empty when there is nothing to top up
function Escrow.bonusTopUp(contractId, fromPercent, toPercent, nextSlot)
    local held = Storage.readEscrow(contractId)
    nextSlot = nextSlot or 1

    -- Slots the creator funded a bonus on by hand, and slots already settled.
    local explicit, settled = {}, {}
    for i = 1, #held do
        local line = held[i]
        -- A named money bonus only, as at creation: alive-only goods sit
        -- beside the percentage rather than replacing it.
        if line.portion == CH.PORTION.BONUS and not line.derived
            and CH.MONEY_SOURCES[line.source] then
            explicit[line.slot] = true
        end
        -- A collection is paid when its baseline is. Any settled line used
        -- to count, so a top-up handed back to the client marked the
        -- collection paid and refused every later raise on it.
        if line.state == CH.ESCROW_STATE.SETTLED and line.portion == CH.PORTION.BASELINE then
            settled[line.slot] = true
        end
    end

    local extra = {}
    for i = 1, #held do
        local line = held[i]
        -- Only a collection still to be paid. One the payout has reached is
        -- paid even while its baseline is held: queued for a hitman whose
        -- pockets were full, it is owed to them and no later claim reaches
        -- a bonus added beside it. A baseline owed back to the client is not
        -- the contract's to pay either. Topping up either locked the new
        -- money away until the contract ended and counted it against the
        -- value ceiling meanwhile.
        if line.portion == CH.PORTION.BASELINE
            and CH.MONEY_SOURCES[line.source]
            and line.state ~= CH.ESCROW_STATE.SETTLED
            and not line.owed_to
            and (line.slot or 1) >= nextSlot
            and not explicit[line.slot]
            and not settled[line.slot] then

            -- The same arithmetic as creation, and the same order of
            -- operations: multiply before dividing, because a binary
            -- fraction of a percentage is not the percentage.
            local was = math.floor(line.amount * fromPercent / 100)
            local now = math.floor(line.amount * toPercent / 100)
            if now > was then
                extra[#extra + 1] = {
                    slot = line.slot, portion = CH.PORTION.BONUS,
                    source = line.source, amount = now - was, derived = true,
                    -- Denominated in whatever the baseline it derives from
                    -- is, so a rename cannot make the top-up and the line it
                    -- was computed from into two different currencies.
                    item = line.item,
                }
            end
        end
    end

    return extra
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
    local lines = readLines(contractId)
    local total = 0
    for i = 1, #lines do
        local line = lines[i]
        local matches = true
        if filter then
            if filter.portion and line.portion ~= filter.portion then matches = false end
            if filter.slot and line.slot ~= filter.slot then matches = false end
        end
        -- `owed_to` as well as the OWED portion. A line marked for one named
        -- person is already spoken for: the release a hitman's claim runs
        -- skips it, so counting it here advertises a reward bigger than
        -- anything that will ever be paid — and prices a bailout off money
        -- the target could never have won back. A withdrawal that could not
        -- be handed over, because the creator's pockets were full, leaves a
        -- line in exactly that state on a live contract.
        if matches and line.portion ~= CH.PORTION.STAKE
            and line.portion ~= CH.PORTION.OWED
            and not line.owed_to
            and CH.MONEY_SOURCES[line.source] then
            if line.state ~= CH.ESCROW_STATE.SETTLED then
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
--- kitted rifle as $0. A hitman needs to know the goods are there to
--- decide, without being told a number nobody can defend.
---@return table { items = n, weapons = n, labels = { name, ... } }
function Escrow.goodsIn(contractId, filter)
    if type(filter) == 'string' then filter = { portion = filter } end

    local lines = readLines(contractId)
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
        if matches and line.state ~= CH.ESCROW_STATE.SETTLED
            and not line.owed_to
            and line.portion ~= CH.PORTION.STAKE and line.portion ~= CH.PORTION.OWED then

            if line.source == CH.SOURCE.ITEM then
                out.items = out.items + (line.quantity or 0)
            elseif line.source == CH.SOURCE.WEAPON then
                out.weapons = out.weapons + 1
            end

            -- Names only. A serial is an identifier and never crosses, and
            -- metadata is nobody's business but the parties'.
            if (line.source == CH.SOURCE.ITEM or line.source == CH.SOURCE.WEAPON)
                and line.item and not seen[line.item] then
                seen[line.item] = true
                out.labels[#out.labels + 1] = line.item
            end
        end
    end

    table.sort(out.labels)
    return out
end

--- Undo a write-ahead owed line whose stake was never lowered: nothing is
--- owed, so it is emptied and closed against its would-be recipient.
local function voidSplit(line)
    if (line.amount or 0) > 0 then
        if not Storage.setEscrowAmount(line.id, CH.ESCROW_STATE.HELD, 0, line.amount) then
            return false
        end
    end
    if Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING) then
        Storage.settleEscrowLine(line.id, line.owed_to)
    end
    return true
end

--- Lower a held stake and owe the difference to the hitman who staked it.
---
--- Two writes, and a process can die between any two. Lowering the stake
--- first and then minting and writing the owed line lost the difference
--- when it died in between: the stake already at the new figure, the rest
--- in no line, no queue and no pocket. So the owed line is written first —
--- unqueued, which nothing pays, and marked with the stake it comes from
--- and the figures either side — and the stake is lowered after it. Boot
--- recovery settles the one case a crash can leave (Escrow.recoverSplits):
--- a stake still at its old figure means the owed line never became owed.
---@param contractId string
---@param line table the stake line, as read
---@param amount integer what the stake becomes
---@param reason string
---@return string|nil owedLineId nil when the stake could not be lowered
---@return boolean delivered whether the difference reached them now
function Escrow.reduceStake(contractId, line, amount, reason)
    local original = line.amount or 0
    local returned = original - amount
    if returned <= 0 or not line.staker then return nil, false end

    local lineId = Util.mintId(Storage.nextId, 'owe', Storage.readEscrowLine)
    if not lineId then return nil, false end

    local owed = {
        id = lineId,
        contract_id = contractId,
        slot = 0,
        portion = CH.PORTION.OWED,
        owed_to = line.staker,
        source = line.source == 'cash' and 'cash' or 'bank',
        amount = returned,
        state = CH.ESCROW_STATE.HELD,
        metadata = { splitFrom = line.id, stakeWas = original, stakeNow = amount },
    }
    Storage.writeEscrow(contractId, { owed })

    -- Guarded: the stake must still be exactly as it was read.
    if not Storage.setEscrowAmount(line.id, CH.ESCROW_STATE.HELD, amount, original) then
        voidSplit(owed)
        return nil, false
    end

    -- And the owed half must still be there. Anything that voided it in
    -- between — boot recovery, which reads an owed line whose stake is still
    -- whole as a split that never happened — would leave the difference in
    -- neither line: put the stake back rather than lose it.
    local check = Storage.readEscrowLine(lineId)
    if not check or check.state ~= CH.ESCROW_STATE.HELD or (check.amount or 0) ~= returned then
        Storage.setEscrowAmount(line.id, CH.ESCROW_STATE.HELD, original, amount)
        return nil, false
    end

    Storage.queuePending(line.staker, contractId, lineId)
    Escrow.noteWaiting(line.staker, true)
    local _, result = Escrow.release(contractId, line.staker, { line = lineId }, reason)
    return lineId, result ~= nil and (result.settled or 0) > 0
end

--- Finish, at boot, whatever a crash left between owing and queuing.
---
--- Two shapes. A stake reduction interrupted between its two writes (see
--- Escrow.reduceStake): the owed line written ahead of its stake is owed
--- only if the stake was lowered, which the stake's own amount says. And
--- any line owed to somebody that no queue entry points at — written, and
--- the process gone before the entry was: nothing pays an owed line that is
--- not queued, so it would have waited for ever.
---@param lines table[] one contract's escrow lines
---@return integer finished
function Escrow.recoverOwed(lines)
    local finished = 0
    local queuedFor = {}
    local function isQueuedFor(cid, lineId)
        if not queuedFor[cid] then
            queuedFor[cid] = {}
            for _, entry in ipairs(Storage.readPending(cid) or {}) do
                queuedFor[cid][entry.line_id] = true
            end
        end
        return queuedFor[cid][lineId] == true
    end

    for _, l in ipairs(lines or {}) do
        -- A line whose give kept raising is left for staff, not queued again
        -- (Escrow.deliver).
        if l.state == CH.ESCROW_STATE.HELD and l.owed_to and not Escrow.parked(l)
            and not isQueuedFor(l.owed_to, l.id) then
            local mark = type(l.metadata) == 'table' and l.metadata or nil
            local voided, doubtful = false, false
            if l.portion == CH.PORTION.OWED and mark and mark.splitFrom then
                -- Owed only if the stake stands exactly where this split
                -- left it, void only if it stands where the split found it.
                -- "Moved at all" was the old test, and a split whose guard
                -- lost to another cut on the same stake — the stake moved,
                -- by somebody else — was paid as well as the one that won.
                local stake = Storage.readEscrowLine(mark.splitFrom)
                if stake == nil or stake.amount == mark.stakeWas then
                    voided = voidSplit(l)
                    if voided then finished = finished + 1 end
                elseif stake.amount ~= mark.stakeNow then
                    -- Neither: not something one cut at a time can leave.
                    -- Neither paid nor voided, and put in front of staff.
                    doubtful = true
                    print(('[crimson-hitman] owed line %s splits stake %s, which is at '
                        .. 'neither figure it knew; left for review')
                        :format(tostring(l.id), tostring(mark.splitFrom)))
                    if Audit then
                        Audit.financial('split_unresolved', l.owed_to, l.contract_id,
                            { line = l.id, stake = mark.splitFrom, review = true })
                    end
                end
            end
            if not voided and not doubtful then
                Storage.queuePending(l.owed_to, l.contract_id, l.id)
                queuedFor[l.owed_to][l.id] = true
                Escrow.noteWaiting(l.owed_to, true)
                finished = finished + 1
            end
        end
    end
    return finished
end

--- Retry queued deliveries for a player who has just come online (§9.3).
---@param cid string
---@return integer delivered
function Escrow.retryPending(cid)
    local queued = Storage.readPending(cid) or {}
    local delivered = 0
    local tried = lastTried[cid] or {}

    -- Least recently tried first; among entries tried equally long ago
    -- (never, to begin with), the oldest first, as before.
    local order = {}
    for i = 1, #queued do order[i] = i end
    table.sort(order, function(a, b)
        local ta, tb = tried[queued[a].id] or 0, tried[queued[b].id] or 0
        if ta ~= tb then return ta < tb end
        return a < b
    end)

    local gone, stillTried, left = {}, {}, 0
    for k = 1, math.min(#queued, Config.PendingEscrow.MaxRetriesPerLogin or 0) do
        local entry = queued[order[k]]
        local line = Storage.readEscrowLine(entry.line_id)
        local theirs = line ~= nil and (line.owed_to == nil or line.owed_to == cid)
        if theirs and line.state == CH.ESCROW_STATE.RELEASING then
            -- Another pass has it — the tick's and a login's run side by
            -- side for one player, and a release sweep can be mid-delivery.
            -- The entry is that pass's to settle or keep. Cleared here, a
            -- delivery that then failed put the line back owed with nothing
            -- queued for it, and no retry, login or recovery ever read it
            -- again.
            if tried[entry.id] ~= nil then stillTried[entry.id] = tried[entry.id] end
        elseif theirs and line.state == CH.ESCROW_STATE.HELD and Escrow.parked(line) then
            -- Its give kept raising: left for staff (/ch-stuck), so off the
            -- queue rather than tried every thirty seconds for nothing.
            Storage.clearPending(entry.id)
            gone[entry.id] = true
        elseif theirs and line.state == CH.ESCROW_STATE.HELD then
            local claimed = Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
            local handed = false
            if claimed then
                if Escrow.deliver(cid, line) then
                    if not Storage.settleEscrowLine(line.id, cid) then
                        Audit.financial('escrow_settle_lost', cid, line.contract_id,
                            { line = line.id })
                    end
                    Storage.clearPending(entry.id)
                    delivered = delivered + 1
                    handed = true
                    gone[entry.id] = true
                else
                    Storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD)
                    -- That was its last raise: left for staff, off the queue.
                    if Escrow.parked(line) then
                        Storage.clearPending(entry.id)
                        gone[entry.id] = true
                    end
                end
            end
            if not handed and not gone[entry.id] then
                attempts = attempts + 1
                stillTried[entry.id] = attempts
            end
        else
            Storage.clearPending(entry.id)
            gone[entry.id] = true
        end
    end

    -- Carried forward for entries this pass did not reach; forgotten for
    -- the ones no longer queued, so this is bounded by the queue.
    for i = 1, #queued do
        local id = queued[i].id
        if not gone[id] then
            left = left + 1
            if stillTried[id] == nil and tried[id] ~= nil then stillTried[id] = tried[id] end
        end
    end
    lastTried[cid] = next(stillTried) ~= nil and stillTried or nil

    -- Whatever is still owed is tried again while they are online, not only
    -- at their next login. Only what this process queued was ever in that
    -- set, so pockets still full at login — or a queue longer than one pass
    -- — waited for a relog nobody had asked for.
    if left > 0 then Escrow.noteWaiting(cid) end

    if delivered > 0 then
        Audit.financial('pending_delivered', cid, nil, { count = delivered })
    end
    return delivered
end

local RETRY_SECONDS = 30

--- Try again for players still online with something queued.
---
--- The queue was only ever read at login. A payout that would not fit told
--- the player "make room and it will be handed over", and making room did
--- nothing: the goods waited for a relog nobody had told them to do. A
--- withdrawal that would not fit said the same, and so did a cancel.
---
--- Walks only the players something was queued for in this process, not
--- every player online, and tries each at most every RETRY_SECONDS so full
--- pockets do not become a store read per tick. A player who is offline is
--- dropped: their login runs the same retry.
---@param isOnline fun(cid: string): boolean
---@return table<string, integer> delivered per citizen id, where anything was
function Escrow.retryWaiting(isOnline)
    local now = os.time()
    local out = {}

    -- A snapshot: retryPending yields on mysql, and a release queuing for a
    -- new player mid-walk would otherwise be a table modified under pairs.
    local due = {}
    for cid, at in pairs(waiting) do
        if now >= at then due[#due + 1] = cid end
    end

    for i = 1, #due do
        local cid = due[i]
        if not isOnline(cid) then
            waiting[cid] = nil
        else
            local woken = wakes[cid]
            local delivered = Escrow.retryPending(cid)
            if delivered > 0 then out[cid] = delivered end
            local left = #(Storage.readPending(cid) or {})
            if wakes[cid] ~= woken then
                -- Something was queued for them while this ran, and the
                -- read above may have been answered before it was written.
                -- Due now; the next pass reads the queue afresh.
                waiting[cid] = 0
            elseif left == 0 then
                waiting[cid] = nil
            else
                waiting[cid] = now + RETRY_SECONDS
            end
        end
    end

    return out
end

return Escrow
