--- The placer's record on a board card (Config.Improvements.PlacerRecord,
--- README, Optional features). Off as shipped.
---
--- With it on, a board card (to anybody who is not its placer or target)
--- carries how many contracts its placer placed, had paid out (completed)
--- and cancelled over the last LookbackDays, not counting this one. Never
--- who they are: three counts, and the days they cover.
---
--- An anonymous placer is the hard case. Exact counts are a fingerprint:
--- two anonymous contracts showing "placed 7, paid 3, cancelled 1" are
--- almost certainly one person, and a count that moves the moment a named
--- contract completes ties the anonymous one to that name. So:
---   * an anonymous placer's record is shown only with ShowForAnonymous on;
---   * it counts only their anonymous contracts, and a named placer's only
---     their named ones, so neither ever moves with the other;
---   * it is shown in rough bands ('0', '1-4', '5-9', '10+'), which many
---     placers share;
---   * it is worked out once, the first time the card is drawn, and then
---     kept for the contract's life (in memory: a restart works them all out
---     again at once). A band that moved when another anonymous contract of
---     theirs completed would say both were theirs.
--- A named placer's record is exact and current: worked out once per change
--- to the contracts (Projection.keptVersion: every write, and the prune that
--- removes finished ones, which the board's generation leaves) and kept for
--- every viewer until the next, or for at most NAMED_KEEP_SECONDS, as the
--- days counted move on.

local Record = {}

local Storage, Projection, Board

--- [placer cid .. '|' .. days] = record, for one generation of the
--- contracts, worked out at `at` (os.time).
local named = { gen = nil, at = 0, by = {} }

--- The longest a named record is kept with nothing written: a contract
--- leaves the LookbackDays window as time passes, with no write to say so.
local NAMED_KEEP_SECONDS = 60
--- [contract id .. '|' .. days] = banded record, kept for the contract's life.
local anon = {}

local function rules()
    return Board and Board.on('PlacerRecord') or nil
end

--- The bands an anonymous placer's counts are shown in.
---@param n integer
---@return string
function Record.band(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return '0' end
    if n < 5 then return '1-4' end
    if n < 10 then return '5-9' end
    return '10+'
end

--- A placer's counts over the last `days`, of their contracts placed the
--- same way (anonymously, or not) as `anonymous`, leaving out `exceptId`.
---@return table { placed, paidOut, cancelled }
function Record.count(creatorCid, anonymous, exceptId, days, now)
    local since = (now or os.time()) - days * 86400
    local out = { placed = 0, paidOut = 0, cancelled = 0 }
    for _, c in ipairs(Storage.contractsBy(creatorCid) or {}) do
        if c.id ~= exceptId and (c.anon_creator == true) == (anonymous == true)
            and (tonumber(c.created_at) or 0) >= since then
            out.placed = out.placed + 1
            if c.state == CH.STATE.COMPLETED then
                out.paidOut = out.paidOut + 1
            elseif c.state == CH.STATE.CANCELLED then
                out.cancelled = out.cancelled + 1
            end
        end
    end
    return out
end

--- What a board card shows of its placer's record, or nil (off; an
--- anonymous placer with ShowForAnonymous off).
---@param contract table
---@return table|nil { placed, paidOut, cancelled, days, banded }
function Record.forCard(contract)
    local cfg = rules()
    if not cfg or type(contract) ~= 'table' or type(contract.creator_cid) ~= 'string' then return nil end
    local days = math.floor(tonumber(cfg.LookbackDays) or 30)
    if contract.anon_creator == true then
        if cfg.ShowForAnonymous ~= true then return nil end
        local key = tostring(contract.id) .. '|' .. days
        local kept = anon[key]
        if not kept then
            local counts = Record.count(contract.creator_cid, true, contract.id, days)
            kept = { placed = Record.band(counts.placed), paidOut = Record.band(counts.paidOut),
                     cancelled = Record.band(counts.cancelled), days = days, banded = true }
            anon[key] = kept
        end
        return { placed = kept.placed, paidOut = kept.paidOut, cancelled = kept.cancelled,
                 days = kept.days, banded = true }
    end
    -- One read per placer per change, every named contract of theirs
    -- counted; this card's own taken off after.
    local gen = Projection.keptVersion()
    local now = os.time()
    if named.gen ~= gen or now - named.at >= NAMED_KEEP_SECONDS then
        named = { gen = gen, at = now, by = {} }
    end
    local key = contract.creator_cid .. '|' .. days
    local hit = named.by[key]
    if not hit then
        hit = Record.count(contract.creator_cid, false, nil, days, now)
        -- Kept only if nothing was written while it was read.
        if Projection.keptVersion() == gen and named.gen == gen then named.by[key] = hit end
    end
    local out = { placed = hit.placed, paidOut = hit.paidOut, cancelled = hit.cancelled, days = days }
    if (tonumber(contract.created_at) or 0) >= now - days * 86400 then
        out.placed = math.max(0, out.placed - 1)
        if contract.state == CH.STATE.COMPLETED then out.paidOut = math.max(0, out.paidOut - 1) end
        if contract.state == CH.STATE.CANCELLED then out.cancelled = math.max(0, out.cancelled - 1) end
    end
    return out
end

--- Forget the anonymous records of contracts that are no longer live (the
--- tick, once a minute, only while anything is kept).
function Record.sweep()
    if next(anon) == nil then return end
    local live = {}
    -- The snapshot the other loops share (Projection.liveSnapshot).
    local list = Projection and Projection.liveSnapshot and Projection.liveSnapshot()
        or Storage.liveContracts()
    for _, c in ipairs(list or {}) do live[tostring(c.id)] = true end
    for key in pairs(anon) do
        if not live[key:match('^(.-)|') or key] then anon[key] = nil end
    end
end

--- Test seam: forget everything kept.
function Record.reset()
    named, anon = { gen = nil, at = 0, by = {} }, {}
end

function Record.init(deps, board)
    Storage, Projection, Board = deps.storage, deps.projection, board
    Record.reset()
    if Projection and Projection.extenders then
        -- On a card the viewer may take, or holds: never the placer's own
        -- (they know it) or the target's.
        Projection.extenders.impRecord = function(out, contract, _, role)
            if role ~= 'public' and role ~= 'hitman' then return end
            out.placerRecord = Record.forCard(contract)
        end
    end
end

return Record
