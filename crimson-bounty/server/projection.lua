--- Per-recipient payload building (§14.4).
---
--- Anonymity is enforced by omission, not by masking: an anonymous creator's
--- identity is never placed in the payload at all, so there is nothing for a
--- client-side inspector to find. Every send point in the resource builds its
--- payload here and nowhere else.

local Projection = {}

local Storage, Identity, Escrow, Kidnap, Mugshot, Progression

function Projection.init(deps)
    Storage, Identity, Escrow, Kidnap, Mugshot, Progression =
        deps.storage, deps.identity, deps.escrow, deps.kidnap, deps.mugshot, deps.progression
end

--- Roles a viewer can hold relative to a contract. The role decides the key
--- set, and the key set is asserted in the test suite so a refactor cannot
--- widen it silently.
local function roleOf(contract, viewerCid)
    if contract.creator_cid == viewerCid then return 'creator' end
    if contract.target_cid == viewerCid then return 'target' end
    local hunter = Storage.readHunter(contract.id, viewerCid)
    if hunter and hunter.state == 'active' then return 'hunter' end
    return 'public'
end

--- Is this contract listed for this viewer right now?
--- Both parties must be online (§7.1), and a viewer never sees a contract
--- they are barred from.
local function listedFor(contract, viewerCid)
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then return false end

    local creatorOnline = Identity.byCitizenId(contract.creator_cid) ~= nil
    local targetOnline = Identity.byCitizenId(contract.target_cid) ~= nil
    if not (creatorOnline and targetOnline) then return false end

    -- A target is not shown their own contract in the public list; they see
    -- it in their own Cleanse tab, which is a different projection.
    if contract.target_cid == viewerCid then return false end

    return true
end

--- Money-equivalent of the slot currently being competed for, which is what
--- a hunter is deciding on.
local function currentReward(contract)
    local slot = contract.next_slot or 1
    return {
        baseline = Escrow.moneyValue(contract.id, { slot = slot, portion = CB.PORTION.BASELINE }),
        bonus    = Escrow.moneyValue(contract.id, { slot = slot, portion = CB.PORTION.BONUS }),
        -- Items and weapons are not priced, so a contract paying a kitted
        -- rifle and nothing else showed as $0. The counts and the item names
        -- cross; serials and metadata do not.
        goods    = Escrow.goodsIn(contract.id, { slot = slot, portion = CB.PORTION.BASELINE }),
        bonusGoods = Escrow.goodsIn(contract.id, { slot = slot, portion = CB.PORTION.BONUS }),
    }
end

--- A single contract, projected for one viewer.
---@param contract table
---@param viewerCid string
---@return table|nil
function Projection.contract(contract, viewerCid)
    local role = roleOf(contract, viewerCid)
    local hunters = Storage.readHunters(contract.id)

    local activeHunters = 0
    for i = 1, #hunters do
        if hunters[i].state == 'active' then activeHunters = activeHunters + 1 end
    end

    local reward = currentReward(contract)

    local out = {
        id            = contract.id,
        reason        = contract.reason,
        mode          = contract.mode,
        state         = contract.state,
        reward        = reward,
        bonusPercent  = contract.bonus_percent,
        slots         = contract.payout_slots or 1,
        slotsClaimed  = contract.slots_claimed or 0,
        currentSlot   = contract.next_slot or 1,
        huntersActive = activeHunters,
        huntersMax    = Config.Limits.MaxHuntersPerContract,
        targetName    = contract.target_name,
        -- The listing carries a *reference* to the target's live headshot
        -- (§7.2), not the image. Inlining the base64 put a whole image in
        -- every row of every page for every viewer — a 40 KB face across a
        -- 15-row listing is 600 KB per tab change, re-sent every time. The
        -- app fetches an image once per handle and caches it, and a new
        -- render mints a new handle, so nothing has to be invalidated.
        --
        -- The call is still made here, because asking is what schedules the
        -- refresh; only its return value is discarded.
        targetImageId = Mugshot and (function()
            Mugshot.request(contract.target_cid)
            return Mugshot.handleFor(contract.target_cid)
        end)() or nil,
        targetProtected = contract.target_protected or false,
        deadline      = contract.deadline_at,
        role          = role,
    }

    -- The creator's identity is present only when they chose to be seen.
    -- When anonymous, no key carrying it exists on the payload.
    if not contract.anon_creator then
        out.creatorName = contract.creator_name
    else
        out.creatorAnonymous = true
    end

    if role == 'creator' then
        out.bailoutAmount = contract.bailout_amount
        out.penaltyAmount = contract.penalty_amount
        -- The creator learns how many operatives are on it, never who they
        -- are, unless a hunter chose to be seen.
        out.hunters = {}
        for i = 1, #hunters do
            local h = hunters[i]
            if h.state == 'active' then
                out.hunters[#out.hunters + 1] = {
                    alias = h.alias,
                    name  = (not h.anon) and h.hunter_name or nil,
                    claims = h.claims or 0,
                    -- A record, not an identity. For an anonymous hunter
                    -- only the coarse standing crosses: exact counters are a
                    -- stable fingerprint that links the same person across
                    -- contracts, which is the thing anonymity is for.
                    record = Progression and (h.anon
                        and { standing = Progression.record(h.hunter_cid).standing }
                        or Progression.record(h.hunter_cid)) or nil,
                }
            end
        end
    elseif role == 'hunter' then
        local mine = Storage.readHunter(contract.id, viewerCid)
        out.myAlias = mine and mine.alias or nil
        out.myClaims = mine and mine.claims or 0
        if Kidnap then
            out.kidnapProgress = Kidnap.progress(contract.id, viewerCid)
        end
    elseif role == 'target' then
        out.bailoutAmount = contract.bailout_amount
        out.bailoutAvailable = (contract.bailout_amount or 0) > 0
    end

    return out
end

--- The public bounty list for one viewer.
---@param viewerCid string
---@param page integer|nil
---@return table
function Projection.listing(viewerCid, page)
    page = math.max(1, math.floor(tonumber(page) or 1))
    local pageSize = Config.Listing.PageSize

    local all = Storage.allContracts()
    local visible = {}
    for i = 1, #all do
        if listedFor(all[i], viewerCid) then visible[#visible + 1] = all[i] end
    end

    -- Sorted by reward rather than creation order: creation order leaks when
    -- an anonymous contract was placed, which is half of a timing attack on
    -- anonymity (§14.32).
    --
    -- The sort key is computed up front and the comparator only reads that
    -- table. A comparator that queried storage would run a database call per
    -- comparison — and under oxmysql that call yields, which is not allowed
    -- inside table.sort's C frame and would fail the whole listing.
    local score = {}
    for i = 1, #visible do
        local c = visible[i]
        score[c.id] = Escrow.moneyValue(c.id, { slot = c.next_slot or 1 })
    end

    table.sort(visible, function(a, b)
        local ra, rb = score[a.id] or 0, score[b.id] or 0
        if ra == rb then return a.id < b.id end
        return ra > rb
    end)

    local out = {
        page = page,
        pages = math.max(1, math.ceil(#visible / pageSize)),
        contracts = {},
        -- The app asks the server how loudly to warn about law enforcement
        -- targets, rather than deciding for itself (§7.5).
        settings = {
            warnCreator = Config.Advisory.WarnCreator ~= false,
            warnHunter  = Config.Advisory.WarnHunter ~= false,
            flagListing = Config.Advisory.FlagListing ~= false,
            minQueryLength = Config.Targeting.MinQueryLength,
            -- Which ways of browsing the app should offer, rather than
            -- offering a button that always comes back empty.
            allowBrowseAll = Config.Targeting.AllowBrowseAll == true,
            allowNearby = Config.Targeting.AllowNearby == true,
            nearbyRadius = Config.Targeting.NearbyRadius,
            -- Whether the app should offer a call at all. Off, the button
            -- is not drawn rather than drawn and refused.
            calls = Config.Relay.Enabled and Config.Relay.AllowMaskedCalls,
        },
    }
    local from = ((page - 1) * pageSize) + 1
    for i = from, math.min(from + pageSize - 1, #visible) do
        out.contracts[#out.contracts + 1] = Projection.contract(visible[i], viewerCid)
    end
    return out
end

--- Contracts the viewer holds as creator.
---
--- These three all ask storage for the contracts this player is involved in
--- rather than for every contract on the server: on a real database the
--- difference is an indexed lookup against a full table scan, once per app
--- request.
function Projection.mine(viewerCid)
    local involved = Storage.contractsBy(viewerCid)
    local out = {}
    for i = 1, #involved do
        local c = involved[i]
        if not CB.TERMINAL[c.state] then
            out[#out + 1] = Projection.contract(c, viewerCid)
        end
    end
    return out
end

--- What a contract's reward is actually made of, line by line, for the
--- creator who put it there.
---
--- The listing carries a money total and a count of goods, which is what a
--- hunter needs to decide. A creator changing their own reward needs the
--- opposite: the individual things, each with the id that names it, so they
--- can hand one back without touching the rest.
---
--- Only the creator, and only their own property. A hunter's stake and a
--- line already owed to somebody are neither shown nor named — a client
--- that cannot see an id cannot ask to withdraw it, and Contracts.withdraw
--- refuses those ids regardless.
---
--- Line ids cross to the client. They identify an escrow row and nothing
--- else: they carry no citizen id, are useless on any other contract, and
--- every path that accepts one re-checks that the caller owns it.
---@param contractId string
---@param viewerCid string
---@return table|nil { editable = boolean, reason?: string, lines = { ... } }
function Projection.rewardLines(contractId, viewerCid)
    local contract = Storage.readContract(contractId)
    if not contract then return nil end
    if contract.creator_cid ~= viewerCid then return nil end

    -- Why the withdraw controls are absent, rather than only that they are.
    -- A creator looking at a reward they cannot change should be told which
    -- rule is holding it, not left to guess.
    local editable, why = true, nil
    if CB.TERMINAL[contract.state] then
        editable, why = false, 'This contract is closed.'
    else
        local hunters = Storage.readHunters(contractId)
        for i = 1, #hunters do
            if hunters[i].state == 'active' then
                editable = false
                why = 'Somebody is hunting this. You can add to the reward, '
                    .. 'but not take from it.'
                break
            end
        end
    end

    local out = {}
    local lines = Storage.readEscrow(contractId)

    for i = 1, #lines do
        local line = lines[i]
        local mine = (line.portion == CB.PORTION.BASELINE
                      or line.portion == CB.PORTION.BONUS)
            and not line.owed_to
            and line.state ~= CB.ESCROW_STATE.SETTLED

        if mine then
            local row = {
                slot    = line.slot or 1,
                portion = line.portion,
                source  = line.source,
                -- Only a line still `held` may be withdrawn. One caught
                -- mid-release is on its way to somebody already, and is
                -- shown so the totals add up rather than hidden so they
                -- do not.
                withdrawable = editable and line.state == CB.ESCROW_STATE.HELD,
            }
            if row.withdrawable then row.id = line.id end

            if CB.MONEY_SOURCES[line.source] then
                row.amount = line.amount or 0
            else
                -- The name of an item crosses, as it already does in the
                -- listing. A serial does not, and neither does metadata:
                -- what a creator needs to pick a line out is what it is
                -- and how much of it, not the identity of the object.
                row.item = line.item
                row.quantity = line.quantity or 1
            end

            out[#out + 1] = row
        end
    end

    table.sort(out, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        if a.portion ~= b.portion then return a.portion < b.portion end
        return tostring(a.item or a.source) < tostring(b.item or b.source)
    end)

    return { editable = editable, reason = why, lines = out,
             slots = contract.payout_slots or 1,
             currentSlot = contract.next_slot or 1 }
end

--- Contracts the viewer holds as hunter.
function Projection.accepted(viewerCid)
    local involved = Storage.contractsInvolving(viewerCid)
    local out = {}
    for i = 1, #involved do
        local c = involved[i]
        if not CB.TERMINAL[c.state] then
            local hunter = Storage.readHunter(c.id, viewerCid)
            if hunter and hunter.state == 'active' then
                out[#out + 1] = Projection.contract(c, viewerCid)
            end
        end
    end
    return out
end

--- Contracts naming the viewer as target — their Cleanse tab.
function Projection.onMe(viewerCid)
    local naming = Storage.contractsNaming(viewerCid)
    local out = {}
    for i = 1, #naming do
        local c = naming[i]
        if not CB.TERMINAL[c.state] then
            local row = Projection.contract(c, viewerCid)
            -- A target learns a price exists on them and what freedom costs.
            -- They do not learn who placed it, and never the hunter roster.
            -- The target learns there is a client, never which one.
            row.creatorName = nil
            row.creatorAnonymous = true
            row.hunters = nil
            out[#out + 1] = row
        end
    end
    return out
end

--- The exact key set each role may receive. Exported so the test suite can
--- assert it; widening it is then a visible, deliberate change.
Projection.ALLOWED_KEYS = {
    common = {
        id = true, reason = true, mode = true, state = true, reward = true,
        bonusPercent = true, slots = true, slotsClaimed = true, currentSlot = true,
        huntersActive = true, huntersMax = true, targetName = true,
        targetProtected = true, deadline = true, role = true,
        targetImageId = true,
        creatorName = true, creatorAnonymous = true,
    },
    creator = { bailoutAmount = true, penaltyAmount = true, hunters = true },
    hunter  = { myAlias = true, myClaims = true, kidnapProgress = true },
    target  = { bailoutAmount = true, bailoutAvailable = true },
    public  = {},
}

return Projection
