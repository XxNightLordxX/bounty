--- The Hitman's Ledger (§6.3, §14.43).
--- Keeps the last N completed contracts per participant, with the
--- verification photo. Bounded by config so the footprint stays small.

local Ledger = {}

local Storage

function Ledger.init(storage) Storage = storage end

--- Record a completed fulfilment for both the creator and the hunter.
--- The target gets an entry too — surviving a contract is worth remembering —
--- but never the photo of their own corpse.
function Ledger.record(contract, hunterCid, photoRef, fulfilment, result)
    if not contract then return end

    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    local photo = Config.Ledger.StorePhotos and photoRef or nil
    local base = {
        contract_id = contract.id,
        target_name = contract.target_name,
        reason      = contract.reason,
        fulfilment  = fulfilment,
        slot        = result and result.slot or 1,
        resolved_at = os.time(),
    }

    local function entry(cid, role, includePhoto)
        local row = {}
        for k, v in pairs(base) do row[k] = v end
        row.cid = cid
        row.role = role
        row.photo_ref = includePhoto and photo or nil
        Storage.writeLedger(row)
    end

    -- Depth is enforced by the storage backends on write, so there is no
    -- separate trim step to forget to call.
    entry(contract.creator_cid, 'creator', true)
    entry(hunterCid, 'hunter', true)
    entry(contract.target_cid, 'target', Config.Ledger.ShowPhotoToTarget)
end

function Ledger.read(cid)
    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    return Storage.readLedger(cid, depth)
end

return Ledger
