CrimsonBoot.define('server.reports', function() --- A player's report to staff: the Report button on a contract card and on
--- a message thread in the app.
---
--- Each report is an item in the review queue (server/review.lua, kind
--- player_report), so staff read and dismiss it where they work through
--- everything else that waits for them. It carries the contract id, the
--- reporter's role on it (placer, target, hitman, or viewer for a contract
--- on the board), an optional note, and for a thread the last
--- Reports.EXCERPT messages as stored, each with the alias it was sent
--- under and nothing else.
---
--- Who: the reporter and the party they report are kept as citizen ids on
--- the item, which the review queue shows whole only to staff with
--- Config.Admin.IdentityAce; everybody else reads each as their place on
--- the contract (the client, operative <alias>, the target) and an
--- anonymous party's name as Anonymous (Admin.reviews). The reported party
--- is told nothing, and the reporter is told only that it was sent.
---
--- Rate-limited by its own bucket (Config.Cooldowns.report), and refused,
--- as a stranger is, on a contract the reporter cannot see.

local Util = CrimsonBoot.requireShared('util')

local Reports = {}

--- Messages kept from a thread, newest last.
Reports.EXCERPT = 20
--- The most characters a note may hold (more is refused, never cut).
Reports.NOTE_MAX = 200

local deps

---@param d table { storage, identity, audit, review, comms, notify }
function Reports.init(d)
    deps = d
end

--- The reporter's role on a contract, or nil and why when it is not one
--- they can see: the placer; the target, once shown it (before then it is
--- not found, as any contract they cannot see); an operative on it, now or
--- before; anybody for a live contract, which the board lists.
---@return string|nil role
---@return string|nil err
local function roleOn(contract, cid)
    if contract.creator_cid == cid then return 'placer' end
    if contract.target_cid == cid then
        if deps.notify.shownToTarget(contract) then return 'target' end
        return nil, CH.ERR.NOT_FOUND
    end
    if deps.storage.readHitman(contract.id, cid) then return 'hitman' end
    if contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED then return 'viewer' end
    return nil, CH.ERR.NOT_PARTICIPANT
end

--- The last Reports.EXCERPT messages of the reporter's own thread on the
--- contract, as stored, by alias; and who is at its other end. nil where
--- they have no thread on it (or the relay is off).
---@return table[]|nil excerpt { alias, body, at }
---@return string|nil otherCid
local function threadOf(actor, contract, handle)
    local ctx = deps.comms.context(actor, contract.id, handle)
    if not ctx then return nil, nil end
    local rows = deps.comms.read(actor, contract.id, handle)
    if type(rows) ~= 'table' then return nil, nil end
    local out = {}
    for i = math.max(1, #rows - Reports.EXCERPT + 1), #rows do
        out[#out + 1] = { alias = rows[i].alias, body = rows[i].body, at = rows[i].at }
    end
    local other = ctx.role == 'creator' and ctx.hitmanCid or contract.creator_cid
    return out, other
end

--- File a report.
---@param actor table the reporter, resolved by the gate
---@param payload table { id, thread?, note? }
---@return boolean ok
---@return string|nil err
---@return table|nil detail
function Reports.file(actor, payload)
    local contractId = Util.toId(payload.id)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if payload.thread ~= nil and (type(payload.thread) ~= 'string' or #payload.thread > 64) then
        return false, CH.ERR.INVALID_INPUT
    end
    local note
    if payload.note ~= nil and payload.note ~= '' then
        if type(payload.note) ~= 'string' then return false, CH.ERR.INVALID_INPUT end
        note = Util.sanitizeText(payload.note, Reports.NOTE_MAX + 1)
        if note and utf8.len(note) > Reports.NOTE_MAX then return false, CH.ERR.INVALID_INPUT end
    end

    local contract = deps.storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    local role, refused = roleOn(contract, actor.cid)
    if not role then return false, refused end

    -- A thread named is one of the reporter's own, or nothing is sent.
    local excerpt, other
    if payload.thread ~= nil or role == 'hitman' then
        excerpt, other = threadOf(actor, contract, payload.thread)
        if payload.thread ~= nil and not excerpt then return false, CH.ERR.NOT_PARTICIPANT end
    end
    local reported = other
    if not reported and role ~= 'placer' then reported = contract.creator_cid end

    local id = deps.review.open({
        kind = 'player_report',
        contract_id = contract.id,
        cids = { from = actor.cid, reported = reported },
        known = { role = role, note = note, thread = excerpt ~= nil or nil, excerpt = excerpt },
    })
    deps.audit.action('player_report', actor.cid, contract.id,
        { review = id, role = role, thread = excerpt ~= nil or nil })
    return true, nil, { reported = true }
end

return Reports
end)
