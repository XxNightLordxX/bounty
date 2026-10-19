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
    }

    local function entry(cid, role, photoRef)
        local row = {}
        for k, v in pairs(base) do row[k] = v end
        row.cid = cid
        row.role = role
        row.photo_ref = photoRef
        Storage.writeLedger(row)
    end

    -- Depth is enforced by the storage backends on write, so there is no
    -- separate trim step to forget to call.
    entry(contract.creator_cid, 'creator', handle)
    entry(hitmanCid, 'hitman', nil)
    entry(contract.target_cid, 'target', nil)

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

--- Forget kill photos past the retention window (§14.43).
---
--- The row stays — a hitman's record of what they finished is the point of
--- the ledger — but the photo does not. One the client never opened is
--- deleted, and a reference left on an older row (a link, from before the
--- client's one view existed) is dropped with it.
---
--- On 'host' storage only the link is forgotten: the image lives wherever
--- lb-phone uploaded it, which is not this resource's to delete.
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
---@param cid string
---@return table[]
function Ledger.entries(cid)
    local rows = Ledger.read(cid) or {}
    local states
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
        }
        if row.role == 'creator' and type(row.photo_ref) == 'string' and Photos then
            -- Read once, and only for a ledger that names a photo at all:
            -- this runs on every refresh of every page.
            states = states or Photos.statesOf(cid)
            local state = states[row.photo_ref]
            if state then entry.photo = { handle = row.photo_ref, state = state } end
        end
        out[#out + 1] = entry
    end
    return out
end

return Ledger
