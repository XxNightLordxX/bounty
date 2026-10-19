--- The kill photo kept for a contract's client, and the one look they get
--- at it (§7.4, §14.43).
---
--- A kill photo is the most sensitive thing this resource holds: a picture
--- of somebody's corpse, taken by somebody who may have paid to stay
--- unnamed. So it belongs to one person, the client who placed the
--- contract, and to them once. They open it on purpose from the Ledger, and
--- then save it to their own phone's Photos or delete it. Closing it any
--- other way deletes it too, and so does leaving it open
--- (Config.Completion.PhotoOpenSeconds) or never opening it
--- (Config.Ledger.PhotoRetentionDays).
---
--- Opened never means "the ledger was read". The page reads the ledger on
--- every refresh, on every tab, so a view counted that way would be spent
--- by a push the client never looked at.
---
--- A record names no hitman, and it goes to nobody but its owner. A handle
--- that is not the caller's is answered exactly as one that was never
--- minted, so a handle is no use to anybody else who comes by it, and
--- asking with one says nothing about whose it is.
---
--- Both storage modes share this lifecycle. 'host' keeps a link to
--- lb-phone's image host ('url'); 'server' keeps the file on this server.
--- What differs is what a record points at, and that is handled where the
--- record is made (keep), shown (open) and let go of (release).

local Util = require_shared('util')

local Photos = {}

local Storage, Audit

--- At most this many records per pass of the expiry and retention jobs, so
--- a backlog cannot turn one maintenance tick into a long stall. What is
--- left waits for the next tick.
local PER_PASS = 200

function Photos.init(deps)
    Storage, Audit = deps.storage, deps.audit
end

--- Let go of whatever a record pointed at, once the record no longer does.
---
--- The one place a photo's image is let go of, so every way a photo ends —
--- deleted, saved, left open, never opened, pushed off the ledger, voided
--- by staff — does the same thing.
---
--- A link needs nothing more: the file is on lb-phone's image host, which
--- gives a resource no way to delete it, so forgetting the link (closePhoto
--- clears it, deletePhoto takes the whole record) is all that can be done.
local function release(record)
    if type(record) ~= 'table' or record.kind == 'url' then return end
end

--- The caller's own record for a handle, or nil.
---
--- nil for a handle never minted and for one minted for somebody else
--- alike, so the two cannot be told apart from outside.
local function owned(actor, rawHandle)
    local id = Util.toId(rawHandle)
    if not id or type(actor) ~= 'table' or not actor.cid then return nil end
    local record = Storage.readPhoto(id)
    if not record or record.owner_cid ~= actor.cid then return nil end
    return record
end

--- Keep a kill photo for the contract's client.
---
--- Nothing is kept with Config.Ledger.StorePhotos off: the client is told
--- the contract was fulfilled and there is nothing to open.
---@param contract table
---@param slot integer|nil the collection it proves
---@param capture table { kind = 'url', url = string }
---@return string|nil handle nil when no photo is kept
function Photos.keep(contract, slot, capture)
    if type(contract) ~= 'table' or not contract.creator_cid or type(capture) ~= 'table' then
        return nil
    end
    if not (Config.Ledger and Config.Ledger.StorePhotos) then
        release(capture)
        return nil
    end

    -- Checked again here though Photo.submit allowed the host already: this
    -- is what reaches the store and, once opened, the client's page.
    if capture.kind ~= 'url' or type(capture.url) ~= 'string' or capture.url == ''
        or #capture.url > Util.MAX_URL_LENGTH then
        release(capture)
        return nil
    end

    local id = Util.mintId(Util.randomId, 'ph', Storage.readPhoto)
    if not id then
        release(capture)
        return nil
    end

    Storage.writePhoto({
        id = id, contract_id = contract.id, slot = tonumber(slot) or 1,
        owner_cid = contract.creator_cid,
        kind = capture.kind, url = capture.url,
        state = CH.PHOTO.PENDING, created_at = os.time(),
    })
    return id
end

--- The client's one look at a photo.
---
--- Spent before anything is handed back: a second request that read the
--- same unseen record a moment earlier loses the race in the store and is
--- answered as gone.
---@param actor table
---@param rawHandle any
---@return table|nil view { handle, url }
---@return string|nil err
function Photos.open(actor, rawHandle)
    local record = owned(actor, rawHandle)
    if not record or record.state ~= CH.PHOTO.PENDING
        or record.kind ~= 'url' or type(record.url) ~= 'string' then
        return nil, CH.ERR.PHOTO_GONE
    end
    if not Storage.openPhoto(record.id, os.time()) then return nil, CH.ERR.PHOTO_GONE end

    Audit.action('photo_opened', actor.cid, record.contract_id, {})
    return { handle = record.id, url = record.url }
end

--- What the client did with the photo they opened: 'save' (their phone has
--- it now) or 'delete'. Either way this resource keeps no image of it from
--- here on, only which of the two it was, for the Ledger to say.
---@param actor table
---@param rawHandle any
---@param choice any
---@return table|nil result { handle, state }
---@return string|nil err
function Photos.decide(actor, rawHandle, choice)
    if choice ~= 'save' and choice ~= 'delete' then return nil, CH.ERR.INVALID_INPUT end

    local record = owned(actor, rawHandle)
    if not record or record.state ~= CH.PHOTO.OPEN then return nil, CH.ERR.PHOTO_GONE end

    local next_ = choice == 'save' and CH.PHOTO.SAVED or CH.PHOTO.DELETED
    if not Storage.closePhoto(record.id, CH.PHOTO.OPEN, next_, nil) then
        return nil, CH.ERR.PHOTO_GONE
    end
    release(record)

    Audit.action(choice == 'save' and 'photo_saved' or 'photo_deleted', actor.cid,
        record.contract_id, {})
    return { handle = record.id, state = next_ }
end

--- What became of each of one client's photos, by handle. The state and
--- nothing else: the Ledger needs to know which button or words to show,
--- not where the photo is.
---@param cid string
---@return table<string, string>
function Photos.statesOf(cid)
    local out = {}
    for _, record in ipairs(Storage.photosOf(cid) or {}) do
        if record.owner_cid == cid then out[record.id] = record.state end
    end
    return out
end

--- Delete every photo left open past Config.Completion.PhotoOpenSeconds,
--- as if the client had tapped Delete. This is what a phone closed
--- mid-view comes to: the page never got to say anything.
---@return integer deleted
function Photos.expire()
    local seconds = tonumber(Config.Completion.PhotoOpenSeconds) or 600
    local due = Storage.photosOpenedBefore(os.time() - seconds, PER_PASS) or {}
    local deleted = 0
    for i = 1, #due do
        if Storage.closePhoto(due[i].id, CH.PHOTO.OPEN, CH.PHOTO.DELETED, nil) then
            release(due[i])
            deleted = deleted + 1
            Audit.action('photo_expired', nil, due[i].contract_id, {})
        end
    end
    return deleted
end

--- Forget every photo kept before the cutoff, whatever became of it: one
--- never opened is deleted, and the record of one saved or deleted goes
--- with the ledger reference that named it (Ledger.forgetOldPhotos).
---@param cutoff integer
---@return integer forgotten
function Photos.forgetBefore(cutoff)
    local old = Storage.photosCreatedBefore(cutoff, PER_PASS) or {}
    for i = 1, #old do
        Storage.deletePhoto(old[i].id)
        release(old[i])
    end
    return #old
end

--- Forget the photos whose ledger rows have been pushed off one player's
--- ledger.
---
--- A ledger keeps Config.Ledger.Depth rows a player, and every new row of
--- any role pushes the oldest out, so a client who goes on to work
--- contracts pushes out their own creator rows too. A photo whose row is
--- gone can never be opened from the page, and was left to wait out the
--- retention days.
---
--- Only photos older than every row still kept. One kept for a row that is
--- still being written — a second collection on the same contract, claimed
--- in the same moment — is newer than all of them, and is not one that was
--- pushed out.
---@param cid string
---@return integer forgotten
function Photos.evict(cid)
    if not cid then return 0 end
    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    local rows = Storage.readLedger(cid, depth) or {}
    -- A ledger that is not full has pushed nothing out.
    if #rows < depth then return 0 end

    local named, oldest = {}, math.huge
    for i = 1, #rows do
        if rows[i].photo_ref then named[rows[i].photo_ref] = true end
        oldest = math.min(oldest, tonumber(rows[i].resolved_at) or 0)
    end

    local forgotten = 0
    for _, record in ipairs(Storage.photosOf(cid) or {}) do
        if not named[record.id] and (tonumber(record.created_at) or 0) < oldest then
            Storage.deletePhoto(record.id)
            release(record)
            forgotten = forgotten + 1
        end
    end
    return forgotten
end

--- Delete the photos of one contract that are still to be seen or still
--- open. For a staff void: a contract staff close is not left with a
--- photo of a body waiting out the retention days. One the client already
--- saved is on their phone, not here.
---@param contractId string
---@return integer deleted
function Photos.forgetContract(contractId)
    local deleted = 0
    for _, record in ipairs(Storage.photosForContract(contractId) or {}) do
        if (record.state == CH.PHOTO.PENDING or record.state == CH.PHOTO.OPEN)
            and Storage.closePhoto(record.id, record.state, CH.PHOTO.DELETED, nil) then
            release(record)
            deleted = deleted + 1
        end
    end
    return deleted
end

return Photos
