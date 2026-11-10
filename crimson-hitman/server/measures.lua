--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/measures.lua                    ║
    ║   Staff measures on a player: freeze, suspend, protect, own target limits ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The one place the admin panel reads and changes the measures staff put
--- on one player (Players, Measures):
---
---   freeze    their live contracts on hold (server/freeze.lua; its clocks,
---             holds and give-backs stay there), kept for their history
---             card too (Sanctions.noteFreeze / noteUnfreeze)
---   suspend   barred from placing and accepting (server/sanctions.lua)
---   protect   no new contract may name them (server/sanctions.lua)
---   limit     their own target limits, or exempt (server/targetlimits.lua,
---             the player override)
---
--- One list of every measure in force (filter by kind), one handle per
--- player for its rows (so Lift names them without the page holding a
--- citizen id), one view of a measure, one apply and one lift that hand each
--- kind to its own module, which keeps its rules, its audit actions and
--- what the player is told. Who set a measure, and the citizen id, only to
--- staff with the identity ACE.

local Measures = {}

local deps = {}

--- The kinds, in the order the list shows them.
Measures.KINDS = { 'freeze', 'suspend', 'protect', 'limit' }
local KNOWN = { freeze = true, suspend = true, protect = true, limit = true }

--- The handles the list gives its rows: [ref] = cid, and the reverse.
--- Kept for the life of the process ('f' handles).
local Refs, RefOf, RefSeq = {}, {}, 0

---@param d table the panel's wiring { freeze, sanctions, targetLimits, identity }
function Measures.init(d)
    deps = d or {}
    Refs, RefOf, RefSeq = {}, {}, 0
end

--- Whether a kind is one of the four.
function Measures.known(kind) return KNOWN[kind] == true end

--- A player's handle in the list.
---@param cid string
---@return string
function Measures.ref(cid)
    local ref = RefOf[cid]
    if not ref then
        RefSeq = RefSeq + 1
        ref = 'f' .. RefSeq
        RefOf[cid], Refs[ref] = ref, cid
    end
    return ref
end

--- Whether a handle is a list's ('f'), and the player it names (nil: gone).
---@param ref any
---@return boolean listed
---@return string|nil cid
function Measures.fromRef(ref)
    if type(ref) ~= 'string' or ref:sub(1, 1) ~= 'f' then return false, nil end
    return true, Refs[ref:sub(1, 16)]
end

-- ============================================================================
--                              READING
-- ============================================================================

--- The row in force of one kind on one player, as each module keeps it, or nil.
local function rowOf(kind, cid)
    if kind == 'freeze' then return deps.freeze and deps.freeze.of(cid) or nil end
    if kind == 'suspend' then return deps.sanctions and deps.sanctions.suspended(cid) or nil end
    if kind == 'protect' then return deps.sanctions and deps.sanctions.protected(cid) or nil end
    if kind == 'limit' then return deps.targetLimits and deps.targetLimits.overrideOf
        and deps.targetLimits.overrideOf(cid) or nil end
    return nil
end

--- One measure as the panel shows it: since, until, reason; who set it only
--- with the identity ACE; a limit's exempt and limits.
local function shown(kind, row, canIdentify)
    if not row then return nil end
    if kind == 'freeze' then
        return { since = row.frozen_at, reason = row.reason, by = canIdentify and row.by_cid or nil }
    end
    if kind == 'limit' then
        return { since = row.at, ['until'] = row.until_at, reason = row.reason, exempt = row.exempt == true or nil,
            limits = row.limits, by = canIdentify and row.by_cid or nil }
    end
    return { since = row.created_at, ['until'] = row.until_at, reason = row.reason,
        by = canIdentify and row.by_cid or nil }
end

--- One kind on one player, as the panel shows it, or nil.
---@param kind string
---@param cid string
---@param canIdentify boolean
---@return table|nil
function Measures.view(kind, cid, canIdentify)
    if not KNOWN[kind] or type(cid) ~= 'string' then return nil end
    return shown(kind, rowOf(kind, cid), canIdentify)
end

--- Every one of a kind in force, as each module lists them.
local function inForce(kind)
    if kind == 'freeze' then return deps.freeze and deps.freeze.list() or {} end
    if kind == 'suspend' or kind == 'protect' then
        return deps.sanctions and deps.sanctions.listOpen and deps.sanctions.listOpen(kind) or {}
    end
    if kind == 'limit' then
        return deps.targetLimits and deps.targetLimits.overrides and deps.targetLimits.overrides() or {}
    end
    return {}
end

--- Every measure in force, newest first: { kind, ref, name, cid?, online,
--- since, until, reason, by?, exempt?, limits? }. `kind` filters to one.
---@param kind string|nil
---@param canIdentify boolean
---@return table[]
function Measures.list(kind, canIdentify)
    local out = {}
    for _, k in ipairs(Measures.KINDS) do
        if kind == nil or kind == k then
            for _, row in ipairs(inForce(k)) do
                local actor = deps.identity and deps.identity.byCitizenId(row.cid)
                local view = shown(k, row, canIdentify)
                view.kind, view.ref = k, Measures.ref(row.cid)
                view.name = (actor and actor.name) or row.name
                view.cid = canIdentify and row.cid or nil
                view.online = actor ~= nil
                out[#out + 1] = view
            end
        end
    end
    table.sort(out, function(a, b)
        local x, y = tonumber(a.since) or 0, tonumber(b.since) or 0
        if x ~= y then return x > y end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return tostring(a.ref) < tostring(b.ref)
    end)
    return out
end

--- How many of each are in force, for the overview: { freeze, unknown,
--- suspend, protect, limit }. A count a module could not give is nil.
---@return table
function Measures.counts()
    local out = {}
    if deps.freeze then out.freeze, out.unknown = deps.freeze.count() end
    for _, k in ipairs({ 'suspend', 'protect', 'limit' }) do
        local ok, rows = pcall(inForce, k)
        out[k] = ok and #rows or nil
    end
    return out
end

-- ============================================================================
--                              APPLY AND LIFT
-- ============================================================================

--- Put a measure on a player, by its own module and its rules.
--- args: freeze { reason, name }; suspend/protect { seconds, reason, name };
--- limit { exempt, limits, hours, reason, name }.
---@return boolean ok
---@return string|nil err
---@return table|nil detail
function Measures.apply(kind, staffCid, cid, args)
    args = args or {}
    if kind == 'freeze' then
        if not deps.freeze then return false, 'unavailable' end
        local ok, err = deps.freeze.freeze(staffCid, cid, args.reason, args.name)
        -- Kept for their history card too: the freeze's own row goes when it is lifted.
        if ok and deps.sanctions then pcall(deps.sanctions.noteFreeze, staffCid, cid, args.reason, args.name) end
        return ok, err
    end
    if kind == 'suspend' or kind == 'protect' then
        if not deps.sanctions then return false, 'unavailable' end
        return deps.sanctions.place(kind, staffCid, cid, args.seconds, args.reason, args.name)
    end
    if kind == 'limit' then
        if not deps.targetLimits then return false, 'unavailable' end
        return deps.targetLimits.adjust(staffCid, cid, 'override', args)
    end
    return false, CH.ERR.INVALID_INPUT
end

--- Lift a measure now, by its own module (a freeze gives back the time on
--- hold there).
---@return boolean ok
---@return string|nil err
---@return table|nil detail
function Measures.lift(kind, staffCid, cid, reason, name)
    if kind == 'freeze' then
        if not deps.freeze then return false, 'unavailable' end
        local ok, err = deps.freeze.unfreeze(staffCid, cid, reason)
        if ok and deps.sanctions then pcall(deps.sanctions.noteUnfreeze, staffCid, cid) end
        return ok, err
    end
    if kind == 'suspend' or kind == 'protect' then
        if not deps.sanctions then return false, 'unavailable' end
        return deps.sanctions.lift(kind, staffCid, cid, reason)
    end
    if kind == 'limit' then
        if not deps.targetLimits then return false, 'unavailable' end
        return deps.targetLimits.adjust(staffCid, cid, 'clear', { reason = reason, name = name })
    end
    return false, CH.ERR.INVALID_INPUT
end

return Measures
