--- The Hitman's Ledger (§6.3, §14.43).
--- Keeps the last N completed contracts per participant. Bounded by config
--- so the footprint stays small.
---
--- The kill photo is the client's alone (Photos). Their row carries
--- the photo's handle, never the link; the hitman's row and the target's
--- carry no photo at all.

local Ledger = {}

local Storage, Photos, Notify

function Ledger.init(deps)
    Storage, Photos, Notify = deps.storage, deps.photos, deps.notify
end

--- Record a completed fulfilment for the creator, the hitman and the target.
---
--- The target gets an entry too — surviving a contract is worth
--- remembering — and nobody but the creator gets the photo. It used to go
--- on the hitman's row as well, so the hitman's own Ledger tab showed them
--- the body they had just photographed for as long as the row lasted, and
--- the link sat in their history for anybody holding their phone.
---@param contract table
---@param hitmanCid string
---@param capture table|nil the kill photo, { kind = 'url', url }; nil for a live delivery
---@param fulfilment string
---@param result table|nil the claim's own answer (Contracts.claimSlot)
---@return string|nil handle the client's photo, when one was kept
function Ledger.record(contract, hitmanCid, capture, fulfilment, result)
    if not contract then return nil end

    local slot = result and result.slot or 1
    local handle = capture and Photos and Photos.keep(contract, slot, capture) or nil

    local base = {
        contract_id = contract.id,
        target_name = contract.target_name,
        reason      = contract.reason,
        fulfilment  = fulfilment,
        slot        = slot,
        resolved_at = os.time(),
        kind        = 'paid',
    }
    -- What this payout was worth in money: paid to the hitman, out of what
    -- the client put up. The figure alone, never who; the target's row has
    -- none (nothing of theirs moved).
    local paid = math.max(0, math.floor(tonumber(result and result.money) or 0))

    local function entry(cid, role, photoRef, amount)
        local row = {}
        for k, v in pairs(base) do row[k] = v end
        row.cid = cid
        row.role = role
        row.photo_ref = photoRef
        row.amount = amount or 0
        Storage.writeLedger(row)
    end

    -- Depth is enforced by the storage backends on write, so there is no
    -- separate trim step to forget to call.
    entry(contract.creator_cid, 'creator', handle, paid)
    entry(hitmanCid, 'hitman', nil, paid)
    entry(contract.target_cid, 'target', nil, 0)

    -- A row any of the three just pushed off the end of their ledger may
    -- have named a photo of theirs. Each, not only the creator: somebody
    -- who placed contracts and then works one pushes out their own client
    -- rows with the hitman row this writes.
    if Photos then
        local seen = {}
        for _, cid in ipairs({ contract.creator_cid, hitmanCid, contract.target_cid }) do
            if cid and not seen[cid] then
                seen[cid] = true
                Photos.evict(cid)
            end
        end
    end

    -- The client's row exists only now. The pushes that told their app the
    -- contract had been paid went out from inside the claim, before these
    -- rows were written, so a refresh they caused could read the ledger
    -- without the new row and show nothing to open until something else
    -- moved it.
    if Notify and contract.creator_cid then
        Notify.push(contract.creator_cid, 'ledger', contract.id)
    end

    return handle
end

--- What a contract that ended without a payout leaves on the Ledger
--- (Contracts' resolve): the client's own row when they withdrew it, when it
--- ran out (or was cancelled by agreement) and what they put up came back,
--- and on a buyout the client's row and the target's, with what moved. The
--- money figure only: who paid, who held it and who was on it are never on
--- a row. Written as the contract closes, before its parties are pushed.
---@param contract table as it was read before it closed
---@param terminal string the CH.STATE it ended in
---@param held integer the money it held as it closed (Escrow.moneyValue)
---@return integer written
function Ledger.ended(contract, terminal, held)
    if not contract or not contract.creator_cid then return 0 end
    held = math.max(0, math.floor(tonumber(held) or 0))
    local now = os.time()
    local written = 0
    local function entry(cid, role, kind, amount)
        if not cid then return end
        Storage.writeLedger({
            cid = cid, role = role, kind = kind, amount = amount,
            contract_id = contract.id, target_name = contract.target_name,
            reason = contract.reason, fulfilment = kind, slot = contract.next_slot or 1,
            resolved_at = now,
        })
        written = written + 1
    end
    if terminal == CH.STATE.CANCELLED then
        entry(contract.creator_cid, 'creator',
            contract.resolution == 'cancelled_by_creator' and 'withdrawn' or 'refunded', held)
    elseif terminal == CH.STATE.EXPIRED then
        entry(contract.creator_cid, 'creator', 'refunded', held)
    elseif terminal == CH.STATE.BAILED_OUT then
        local premium = math.max(0, math.floor(tonumber(contract.bailout_paid_amount) or 0))
        entry(contract.creator_cid, 'creator', 'buyout', held + premium)
        entry(contract.target_cid, 'target', 'buyout', premium)
    end
    -- A row these pushed off the end may have named a photo of theirs, as
    -- in Ledger.record.
    if written > 0 and Photos then
        Photos.evict(contract.creator_cid)
        if terminal == CH.STATE.BAILED_OUT and contract.target_cid then Photos.evict(contract.target_cid) end
    end
    -- No push of its own: the ending's own push to every party (finalise)
    -- follows these rows, and its refresh reads the Ledger too.
    return written
end

--- Forget kill photos past the retention window (§14.43).
---
--- The row stays — a hitman's record of what they finished is the point of
--- the ledger — but the photo does not. One the client never opened is
--- deleted, and a reference left on an older row (a link, from before the
--- client's one view existed) is dropped with it.
---
--- On 'host' storage only the link is forgotten: the image lives wherever
--- lb-phone uploaded it, which is not this resource's to delete.
---
--- A photo kept for its client in the app, or in their phone's Photos
--- through a link this server serves, is not the retention's to forget
--- (Photos.forgetBefore). Its row may lose the reference all the same; the
--- Ledger then lists it on its own (Ledger.entries).
---@return integer forgotten ledger references dropped
---@return integer photos photo records forgotten
function Ledger.forgetOldPhotos()
    local days = Config.Ledger.PhotoRetentionDays or 0
    if days <= 0 then return 0, 0 end
    local cutoff = os.time() - (days * 86400)

    -- One call, so on mysql this is a single indexed UPDATE rather than
    -- reading the whole ledger into Lua to write most of it back.
    local forgotten = Storage.forgetLedgerPhotos(cutoff) or 0
    local photos = Photos and Photos.forgetBefore(cutoff) or 0
    return forgotten, photos
end

function Ledger.read(cid)
    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    return Storage.readLedger(cid, depth)
end

--- One player's ledger as their page is shown it.
---
--- Built field by field rather than handed over as stored. A stored row
--- carries its owner's cid, and on mysql its row id, and its photo_ref is
--- a handle the page must only ever see as { handle, state } — and only on
--- the client's own row, for a photo that is theirs. A link on a row from
--- before the client's one view existed is not a handle, matches no
--- record, and is never sent.
---
--- And, second, the photos kept for them in the app whose row is no longer
--- among these: pushed off by newer rows, or stripped of its photo by the
--- retention. A kept photo outlives its row (Photos.evict), and this is
--- the only place its owner could find it again. { handle, state,
--- taken_at } each, newest first.
---@param cid string
---@return table[] entries
---@return table[] kept
function Ledger.entries(cid)
    local rows = Ledger.read(cid) or {}
    -- Every photo of theirs, read once a refresh, and not only for a
    -- ledger that names one: a photo kept in the app can outlive its row.
    -- One indexed read by owner on mysql.
    local photos = Photos and Photos.ofOwner(cid) or {}
    local named = {}
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        local entry = {
            contract_id = row.contract_id,
            target_name = row.target_name,
            reason      = row.reason,
            fulfilment  = row.fulfilment,
            slot        = row.slot,
            resolved_at = row.resolved_at,
            role        = row.role,
            -- What kind of row ('paid', 'withdrawn', 'refunded', 'buyout';
            -- a row from before there were kinds is a payout) and the money
            -- it moved, as written.
            kind        = row.kind or 'paid',
            amount      = math.max(0, math.floor(tonumber(row.amount) or 0)),
        }
        local record = row.role == 'creator' and type(row.photo_ref) == 'string'
            and photos[row.photo_ref] or nil
        if record then
            entry.photo = { handle = row.photo_ref, state = record.state }
            named[row.photo_ref] = true
        end
        out[#out + 1] = entry
    end

    local kept = {}
    for handle, record in pairs(photos) do
        if record.state == CH.PHOTO.KEPT and not named[handle] then
            kept[#kept + 1] = { handle = handle, state = record.state,
                                taken_at = tonumber(record.created_at) }
        end
    end
    table.sort(kept, function(a, b)
        local at, bt = a.taken_at or 0, b.taken_at or 0
        if at ~= bt then return at > bt end
        return a.handle < b.handle
    end)
    return out, kept
end

return Ledger
