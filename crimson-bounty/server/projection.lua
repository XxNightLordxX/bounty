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
        -- The listing carries a live headshot of the target (§7.2). Asking
        -- for it here is what schedules the refresh; the cached image is
        -- returned immediately and a newer one arrives on a later poll.
        targetImage   = Mugshot and Mugshot.request(contract.target_cid) or nil,
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
                    -- A record, not an identity: a creator can judge who
                    -- took their contract without learning who they are.
                    record = Progression and Progression.record(h.hunter_cid) or nil,
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

    local out = { page = page, pages = math.max(1, math.ceil(#visible / pageSize)), contracts = {} }
    local from = ((page - 1) * pageSize) + 1
    for i = from, math.min(from + pageSize - 1, #visible) do
        out.contracts[#out.contracts + 1] = Projection.contract(visible[i], viewerCid)
    end
    return out
end

--- Contracts the viewer holds as creator.
function Projection.mine(viewerCid)
    local all = Storage.allContracts()
    local out = {}
    for i = 1, #all do
        local c = all[i]
        if c.creator_cid == viewerCid and not CB.TERMINAL[c.state] then
            out[#out + 1] = Projection.contract(c, viewerCid)
        end
    end
    return out
end

--- Contracts the viewer holds as hunter.
function Projection.accepted(viewerCid)
    local all = Storage.allContracts()
    local out = {}
    for i = 1, #all do
        local c = all[i]
        local hunter = Storage.readHunter(c.id, viewerCid)
        if hunter and hunter.state == 'active' and not CB.TERMINAL[c.state] then
            out[#out + 1] = Projection.contract(c, viewerCid)
        end
    end
    return out
end

--- Contracts naming the viewer as target — their Cleanse tab.
function Projection.onMe(viewerCid)
    local all = Storage.allContracts()
    local out = {}
    for i = 1, #all do
        local c = all[i]
        if c.target_cid == viewerCid and not CB.TERMINAL[c.state] then
            local row = Projection.contract(c, viewerCid)
            -- A target learns a price exists on them and what freedom costs.
            -- They do not learn who placed it, and never the hunter roster.
            row.creatorName = nil
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
        targetProtected = true, deadline = true, role = true, targetImage = true,
        creatorName = true, creatorAnonymous = true,
    },
    creator = { bailoutAmount = true, penaltyAmount = true, hunters = true },
    hunter  = { myAlias = true, myClaims = true, kidnapProgress = true },
    target  = { bailoutAmount = true, bailoutAvailable = true },
    public  = {},
}

return Projection
