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
--- lb-phone's image host ('url'); 'server' keeps the file on this server
--- ('file', in data/photos/). What differs is what a record points at, and
--- that is handled where the record is made (keep), shown (open) and let
--- go of (release).

local Util = require_shared('util')

local Photos = {}

local Storage, Audit

--- At most this many records per pass of the expiry and retention jobs, so
--- a backlog cannot turn one maintenance tick into a long stall. What is
--- left waits for the next tick.
local PER_PASS = 200

--- Where photos kept on this server live, inside the resource folder.
local PHOTO_DIR = 'data/photos'

--- A photo's file is named after its own handle and nothing else. Never
--- from a link, a label or anything else a client sent: SaveResourceFile
--- does not refuse '..', so a name taken from outside could write over any
--- file in the resource.
local FILE_NAME = '^' .. PHOTO_DIR:gsub('%p', '%%%0') .. '/([%w_-]+)%.(%a+)$'

function Photos.init(deps)
    Storage, Audit = deps.storage, deps.audit
end

--- The resource's folder on disk, or nil where this server cannot say.
local function resourceRoot()
    local ok, base = pcall(function()
        return GetResourcePath and GetResourcePath(GetCurrentResourceName())
    end)
    if ok and type(base) == 'string' and base ~= '' then return base end
    return nil
end

--- The file a record's picture lives in, checked: inside data/photos/,
--- named for the record and of a kind this resource keeps. nil for
--- anything else, so a damaged record can never name some other file to
--- be read out or deleted.
---@return string|nil file
local function fileOf(record)
    if type(record) ~= 'table' or type(record.file) ~= 'string' then return nil end
    local id, ext = record.file:match(FILE_NAME)
    if not id or id ~= record.id then return nil end
    for _, known in pairs(CH.PHOTO_MIME) do
        if ext == known then return record.file end
    end
    return nil
end

--- Remove one photo file. os.remove resolves a relative path against the
--- server's working directory, not the resource (json.lua's prune learnt
--- that), so it is given the whole path. A file it could not remove is
--- left for the next start's sweep (Photos.sweepFiles), which removes every
--- file no record still points at.
local function removeFile(file)
    local base = resourceRoot()
    if not base then return false end
    local ok, removed = pcall(os.remove, base .. '/' .. file)
    return ok and removed == true
end

--- SaveResourceFile writes a file and not the folder above it, and an
--- upgraded server has no data/photos/ until something makes it. Asked
--- once a process; "already there" is an answer like any other.
local madeFolder = false
local function makeFolder()
    if madeFolder then return end
    madeFolder = true
    local base = resourceRoot()
    if base and os.createdir then pcall(os.createdir, base .. '/' .. PHOTO_DIR) end
end

--- Write a photo's bytes to its file.
---
--- With the length given. SaveResourceFile's -1 means "up to the first NUL
--- byte", which suits the JSON the store writes and cuts a picture short:
--- a JPEG has a NUL in its fifth byte.
---@return boolean written
local function writeFile(file, data)
    makeFolder()
    local ok, wrote = pcall(SaveResourceFile, GetCurrentResourceName(), file, data, #data)
    if ok and wrote ~= false then return true end
    print(('[crimson-hitman] could not write the kill photo %s. Make sure the folder %s '
        .. 'exists in this resource and the server can write to it. The kill was paid; '
        .. 'its client has no photo to open.'):format(file, PHOTO_DIR))
    return false
end

--- What a record points at, read before the store lets go of it: closing a
--- record clears its link and file name, and on the memory store a record
--- read a moment ago is the stored one, cleared with it.
local function holding(record)
    if type(record) ~= 'table' then return nil end
    return { id = record.id, kind = record.kind, file = record.file }
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
--- A file on this server is removed.
local function release(held)
    if type(held) ~= 'table' or held.kind ~= 'file' then return end
    local file = fileOf(held)
    if file then removeFile(file) end
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
--- the contract was fulfilled and there is nothing to open. A picture for
--- this server is then never written at all.
---
--- On 'server' storage the file is written before its record, so a record
--- never names a file that is not there. A crash between the two leaves a
--- file no record names, which the next start's sweep removes.
---@param contract table
---@param slot integer|nil the collection it proves
---@param capture table { kind = 'url', url } or { kind = 'file', data, mime }
---@return string|nil handle nil when no photo is kept
function Photos.keep(contract, slot, capture)
    if type(contract) ~= 'table' or not contract.creator_cid or type(capture) ~= 'table' then
        return nil
    end
    if not (Config.Ledger and Config.Ledger.StorePhotos) then return nil end

    local record = {
        contract_id = contract.id, slot = tonumber(slot) or 1,
        owner_cid = contract.creator_cid, kind = capture.kind,
        state = CH.PHOTO.PENDING, created_at = os.time(),
    }

    -- Checked again here though Photo.submit checked them already: this is
    -- what reaches the store and, once opened, the client's page.
    if capture.kind == 'url' then
        if type(capture.url) ~= 'string' or capture.url == ''
            or #capture.url > Util.MAX_URL_LENGTH then
            return nil
        end
        record.url = capture.url
    elseif capture.kind == 'file' then
        if not CH.PHOTO_MIME[capture.mime] or type(capture.data) ~= 'string'
            or #capture.data == 0 then
            return nil
        end
        record.mime, record.size = capture.mime, #capture.data
    else
        return nil
    end

    local id = Util.mintId(Util.randomId, 'ph', Storage.readPhoto)
    if not id then return nil end
    record.id = id

    if record.kind == 'file' then
        record.file = PHOTO_DIR .. '/' .. id .. '.' .. CH.PHOTO_MIME[record.mime]
        if not fileOf(record) or not writeFile(record.file, capture.data) then return nil end
    end

    Storage.writePhoto(record)
    return id
end

--- A photo kept on this server, as the client's page shows it: a data URI.
--- nil when its file cannot be read whole.
local function dataUri(record)
    local file = fileOf(record)
    if not file or not CH.PHOTO_MIME[record.mime] then return nil end
    local ok, bytes = pcall(LoadResourceFile, GetCurrentResourceName(), file)
    if not ok or type(bytes) ~= 'string' or bytes == '' then return nil end
    -- Shorter than it was written is a file cut short, or a server build
    -- that does not read binary files whole. Shown, it would be a broken
    -- picture, and the one look spent on it.
    if record.size and #bytes ~= tonumber(record.size) then
        print(('[crimson-hitman] the kill photo %s reads back as %d bytes, not the %s '
            .. 'written. It cannot be shown.'):format(file, #bytes, tostring(record.size)))
        return nil
    end
    return 'data:' .. record.mime .. ';base64,' .. Util.toBase64(bytes)
end

--- The client's one look at a photo.
---
--- Spent before anything is handed back: a second request that read the
--- same unseen record a moment earlier loses the race in the store and is
--- answered as gone.
---
--- A photo on this server comes back as `image`, a data URI of a few
--- hundred kilobytes, which the caller sends on to the client's phone on
--- its own (App's openPhoto) rather than in the ordinary reply. Read before
--- the look is spent: a file that cannot be read is not something to spend
--- the client's one look on, and nothing will ever show it, so it is
--- deleted there and then.
---@param actor table
---@param rawHandle any
---@return table|nil view { handle, url } or { handle, image }
---@return string|nil err
function Photos.open(actor, rawHandle)
    local record = owned(actor, rawHandle)
    if not record or record.state ~= CH.PHOTO.PENDING then return nil, CH.ERR.PHOTO_GONE end

    local view
    if record.kind == 'url' and type(record.url) == 'string' then
        view = { handle = record.id, url = record.url }
    elseif record.kind == 'file' then
        local image = dataUri(record)
        if not image then
            local held = holding(record)
            if Storage.closePhoto(record.id, CH.PHOTO.PENDING, CH.PHOTO.DELETED, nil) then
                release(held)
                Audit.action('photo_unreadable', actor.cid, record.contract_id, {})
            end
            return nil, CH.ERR.PHOTO_GONE
        end
        view = { handle = record.id, image = image }
    else
        return nil, CH.ERR.PHOTO_GONE
    end

    if not Storage.openPhoto(record.id, os.time()) then return nil, CH.ERR.PHOTO_GONE end

    Audit.action('photo_opened', actor.cid, record.contract_id, {})
    return view
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
    local held = holding(record)
    if not Storage.closePhoto(record.id, CH.PHOTO.OPEN, next_, nil) then
        return nil, CH.ERR.PHOTO_GONE
    end
    release(held)

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
        local held = holding(due[i])
        if Storage.closePhoto(due[i].id, CH.PHOTO.OPEN, CH.PHOTO.DELETED, nil) then
            release(held)
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
        local held = holding(old[i])
        Storage.deletePhoto(old[i].id)
        release(held)
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
            local held = holding(record)
            Storage.deletePhoto(record.id)
            release(held)
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
        local held = holding(record)
        if (record.state == CH.PHOTO.PENDING or record.state == CH.PHOTO.OPEN)
            and Storage.closePhoto(record.id, record.state, CH.PHOTO.DELETED, nil) then
            release(held)
            deleted = deleted + 1
        end
    end
    return deleted
end

--- Remove every photo file no record points at any more. Run at start,
--- before the app answers anybody, so nothing is being kept while it runs.
---
--- A file outlives its record when the server stopped between writing the
--- file and its record, when the store lost the record (the memory store
--- loses them all at every start; the json store loses what it had not
--- flushed), or when removing it failed. Nothing else would ever remove
--- it, and each is a photograph of a body. Removing again what is already
--- gone does nothing, so running this twice is the same as once.
---
--- Only names this resource gives its files: anything else in the folder
--- is left alone. Needs io.readdir, which older server builds lack; there
--- it says so once and the files wait.
---@return integer removed
function Photos.sweepFiles()
    local base = resourceRoot()
    if not base then return 0 end
    local readdir = io and io.readdir
    if type(readdir) ~= 'function' then
        print('[crimson-hitman] this server build cannot list a folder (io.readdir), so kill '
            .. 'photo files left in ' .. PHOTO_DIR .. ' by a crash are not swept at start. '
            .. 'Update the server to have them removed.')
        return 0
    end

    local ok, dir = pcall(readdir, base .. '/' .. PHOTO_DIR)
    if not ok or not dir then return 0 end
    local names = {}
    pcall(function()
        for name in dir:lines() do names[#names + 1] = name end
    end)
    pcall(function() dir:close() end)

    local removed = 0
    for i = 1, #names do
        local file = PHOTO_DIR .. '/' .. names[i]
        local id = file:match(FILE_NAME)
        local candidate = id and { id = id, file = file }
        if candidate and fileOf(candidate) then
            local record = Storage.readPhoto(id)
            if not (record and record.file == file) and removeFile(file) then
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        print(('[crimson-hitman] removed %d kill photo file(s) no record named any more.')
            :format(removed))
    end
    return removed
end

return Photos
