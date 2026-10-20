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
--- Saving to Photos takes a link: lb-phone's gallery keeps links of at most
--- 500 characters, never a picture. A photo on an image host has one. A
--- photo kept on this server gets one of two ways: a link this server
--- serves itself (Photos.publish and Photos.serveHttp, where it has a
--- public https address), or lb-phone's own upload, which the page does.
--- Where neither can work, the photo is KEPT for its client in this app
--- instead, to open again whenever they like until they delete it
--- (Config.Completion.KeptPhotoDays can put a limit on that). A phone that
--- cannot take the photo is no reason to lose it.
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

--- Where a photo kept for its client in the app is moved to, so what the
--- app holds on to for good sits apart from what it deletes within days.
--- Where the server cannot make that folder, the file stays beside the
--- others with KEPT_PREFIX in front of its name.
local KEPT_DIR = PHOTO_DIR .. '/kept'
local KEPT_PREFIX = 'kept-'

--- Which storage mode's records name the files here (Photos.sweepFiles).
local MODE_FILE = PHOTO_DIR .. '/.mode'

--- The longest link lb-phone's gallery keeps (phone_photos.link is
--- VARCHAR(500)). A longer one would be cut short and point at nothing.
local LINK_MAX = 500

--- A photo's file is named after its own handle and nothing else. Never
--- from a link, a label or anything else a client sent: SaveResourceFile
--- does not refuse '..', so a name taken from outside could write over any
--- file in the resource.
---
--- The three places one may be, the more particular first: a kept- name
--- also matches the plain pattern, as the handle "kept-ph...", which is no
--- record's.
local function under(dir) return '^' .. dir:gsub('%p', '%%%0') .. '/' end
local FILE_NAMES = {
    under(KEPT_DIR) .. '([%w_-]+)%.(%a+)$',
    under(PHOTO_DIR) .. KEPT_PREFIX:gsub('%p', '%%%0') .. '([%w_-]+)%.(%a+)$',
    under(PHOTO_DIR) .. '([%w_-]+)%.(%a+)$',
}

--- What a request for a served photo looks like once its query string is
--- dropped: '/p/<name>.<extension>', and nothing else. The name is only
--- ever looked up in the store; it never becomes part of a path.
local SERVED_PATH = '^/p/([%w_-]+)%.(%a+)$'

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

local function knownExtension(ext)
    for _, known in pairs(CH.PHOTO_MIME) do
        if ext == known then return true end
    end
    return false
end

--- The handle a photo file is named for, read the way this resource names
--- its files, or nil for a name it never gives.
local function handleIn(file)
    for i = 1, #FILE_NAMES do
        local id, ext = file:match(FILE_NAMES[i])
        if id and knownExtension(ext) then return id end
    end
    return nil
end

--- The file a record's picture lives in, checked: inside data/photos/,
--- named for the record and of a kind this resource keeps. nil for
--- anything else, so a damaged record can never name some other file to
--- be read out or deleted.
---@return string|nil file
local function fileOf(record)
    if type(record) ~= 'table' or type(record.file) ~= 'string' then return nil end
    for i = 1, #FILE_NAMES do
        local id, ext = record.file:match(FILE_NAMES[i])
        if id and id == record.id and knownExtension(ext) then return record.file end
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

--- Move one photo file to another name inside the resource, which FiveM's
--- os.rename allows as its os.remove does. false where it could not.
local function moveFile(from, to)
    local base = resourceRoot()
    if not base or type(os.rename) ~= 'function' then return false end
    local ok, moved = pcall(os.rename, base .. '/' .. from, base .. '/' .. to)
    return ok and moved == true
end

--- SaveResourceFile writes a file and not the folder above it, and an
--- upgraded server has no data/photos/ until something makes it. Asked
--- once a process for each folder; "already there" is an answer like any
--- other.
local madeFolders = {}
local function makeFolder(dir)
    if madeFolders[dir] then return end
    madeFolders[dir] = true
    local base = resourceRoot()
    if base and os.createdir then pcall(os.createdir, base .. '/' .. dir) end
end

--- Write a photo's bytes to its file.
---
--- With the length given. SaveResourceFile's -1 means "up to the first NUL
--- byte", which suits the JSON the store writes and cuts a picture short:
--- a JPEG has a NUL in its fifth byte.
---@return boolean written
local function writeFile(file, data)
    makeFolder(PHOTO_DIR)
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
--- by staff, deleted from the phone's Photos — does the same thing.
---
--- A link needs nothing more: the file is on lb-phone's image host, which
--- gives a resource no way to delete it, so forgetting the link (closePhoto
--- clears it, deletePhoto takes the whole record) is all that can be done.
--- A file on this server is removed. A link this server served it under
--- goes in the same step as the record lets go (closePhoto clears the
--- name it was served by), so it is not served again even where the
--- removal fails.
local forgetUri

local function release(held)
    if type(held) == 'table' then forgetUri(held.id) end
    if type(held) ~= 'table' or held.kind ~= 'file' then return end
    local file = fileOf(held)
    if file then removeFile(file) end
end

--- Close a record from the state it is in, and let go of what it held.
---@return boolean closed false when something else moved it first
local function close(record, next_)
    local held, state = holding(record), record.state
    if not Storage.closePhoto(record.id, state, next_, nil) then return false end
    release(held)
    return true
end

--- Whether this server serves a record's photo to a phone's Photos. Such a
--- photo stays for as long as the phone keeps it (lb-phone tells us when it
--- is deleted there), so the retention and the ledger leave it be.
local function served(record)
    return type(record) == 'table' and type(record.public_id) == 'string'
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

--- A photo kept on this server, read whole, or nil.
---
--- Shorter than it was written is a file cut short, or a server build that
--- does not read binary files whole. Shown, it would be a broken picture,
--- and the one look spent on it; served, a broken one in the client's
--- Photos.
local function readBytes(record)
    local file = fileOf(record)
    if not file or not CH.PHOTO_MIME[record.mime] then return nil end
    local ok, bytes = pcall(LoadResourceFile, GetCurrentResourceName(), file)
    if not ok or type(bytes) ~= 'string' or bytes == '' then return nil end
    if record.size and #bytes ~= tonumber(record.size) then
        print(('[crimson-hitman] the kill photo %s reads back as %d bytes, not the %s '
            .. 'written. It cannot be shown.'):format(file, #bytes, tostring(record.size)))
        return nil
    end
    return bytes
end

--- A photo kept on this server, as the client's page shows it: a data URI.
--- nil when its file cannot be read whole.
local function dataUri(record)
    local bytes = readBytes(record)
    if not bytes then return nil end
    return 'data:' .. record.mime .. ';base64,' .. Util.toBase64(bytes)
end

--- The data URIs of the photos kept in the app opened most recently:
--- [id] = { key, uri, used }. A kept photo opens as often as its owner
--- likes, and each open read its file and encoded it again, in Lua on the
--- main thread: tens of milliseconds a time at the default size, half a
--- second at the largest, as fast as the open limit allows. Only ever read
--- for its owner, after the ownership check, and dropped when the photo
--- is let go of (release) or its file moves (the key names the file).
local KEPT_URIS = 4
local keptUris, uriUses = {}, 0

forgetUri = function(id)
    if id ~= nil then keptUris[id] = nil end
end

local function keptDataUri(record)
    local key = tostring(record.file) .. ':' .. tostring(record.size) .. ':' .. tostring(record.mime)
    uriUses = uriUses + 1
    local hit = keptUris[record.id]
    if hit and hit.key == key then
        hit.used = uriUses
        return hit.uri
    end
    local uri = dataUri(record)
    if not uri then return nil end
    local count, oldest = 0, nil
    for id, entry in pairs(keptUris) do
        count = count + 1
        if not oldest or entry.used < keptUris[oldest].used then oldest = id end
    end
    if count >= KEPT_URIS and oldest then keptUris[oldest] = nil end
    keptUris[record.id] = { key = key, uri = uri, used = uriUses }
    return uri
end

--------------------------------------------------------------------------
-- A link for the phone's Photos, served by this server
--------------------------------------------------------------------------
--
-- Route A1 of Save to Photos, for a photo kept on this server: no image
-- host at all. The photo is served read-only at
-- https://<public address>/p/<name>.<ext>, the client's page hands that
-- link to lb-phone's gallery, and the file stays for as long as the
-- gallery holds it. The name is the only thing between the photo and
-- anybody who asks for it — a phone's image cannot carry a password — so
-- it is new for the save, unrelated to the handle, and unguessable.

--- A web address as Config.Completion.PhotoPublicUrl may give it, checked:
--- https:// only (the phone's page is https, and lb-phone's gallery is a
--- phone's, not a server console's), a plain host, no query, no fragment,
--- no trailing slash, short enough to leave room for the photo's name
--- inside lb-phone's 500 characters. nil for anything else.
---@param value any
---@return string|nil base
function Photos.checkBase(value)
    if type(value) ~= 'string' or #value > 400 then return nil end
    local base = value:gsub('^%s+', ''):gsub('%s+$', ''):gsub('/+$', '')
    if not base:find('^https://') or base:find('[%s?#\\]') then return nil end
    if not Util.urlHost(base) then return nil end
    return base
end

--- Where a server's web_baseUrl would serve photos from, or nil and why
--- not. It is a host name with no scheme, set by FXServer itself where
--- Cfx.re's proxy answered, or by the owner (Qbox's Nucleus replacement
--- tells you to `set web_baseUrl "<name>.server.qbox.re"`).
local function baseFromWeb()
    local ok, value = pcall(GetConvar, 'web_baseUrl', '')
    local host = ok and type(value) == 'string' and value or ''
    host = host:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^%a[%w+.-]*://', ''):gsub('/+$', '')
    if host == '' then return nil, 'web_baseUrl is not set' end
    local name = host:match('^([%w%.%-]+)') or ''
    if name ~= host:match('^([^:]+)') or not name:find('%.') or name:find('%.%.')
        or not host:match('^[%w%.%-]+:?%d*$') then
        return nil, ('web_baseUrl "%s" is not a host name'):format(host)
    end
    -- Cfx.re switched its own *.users.cfx.re proxy off on 30 June 2026. A
    -- server that still carries such an address would hand phones links
    -- that lead nowhere, and the photo would be lost from their Photos.
    if name:lower():find('users%.cfx%.re$') then
        return nil, ('web_baseUrl "%s" is a users.cfx.re address, which Cfx.re shut down '
            .. 'on 30 June 2026'):format(host)
    end
    -- A bare address has no certificate a phone accepts for https.
    if name:match('^%d+%.%d+%.%d+%.%d+$') then
        return nil, ('web_baseUrl "%s" is an IP address, which a phone cannot load a photo '
            .. 'from over https'):format(host)
    end
    return 'https://' .. host .. '/' .. GetCurrentResourceName()
end

--- The public https address photos kept on this server are served from,
--- for a phone's Photos to load them by: Config.Completion.PhotoPublicUrl
--- as the owner wrote it, or else the server's web_baseUrl with this
--- resource's name after it. Read each time it is needed: FXServer sets
--- web_baseUrl a while after it starts, when it hears back from Cfx.re.
---@return string|nil base
---@return string where 'Config.Completion.PhotoPublicUrl', 'web_baseUrl', or why there is none
function Photos.publicBase()
    local explicit = Config.Completion.PhotoPublicUrl
    if explicit ~= nil and explicit ~= '' then
        local base = Photos.checkBase(explicit)
        if base then return base, 'Config.Completion.PhotoPublicUrl' end
        return nil, 'Config.Completion.PhotoPublicUrl is not an https:// address'
    end
    local base, why = baseFromWeb()
    if base then return base, 'web_baseUrl' end
    return nil, why
end

--- A name for a served photo that nobody can guess: the 128-bit salt of a
--- bcrypt hash, which FXServer draws from Botan's AutoSeeded_RNG, the
--- operating system's cryptographic random source. Never math.random,
--- which is seeded from the clock and is no secret. Its '.' and '/' are
--- turned into '_' and '-', so it reads as an id and needs no escaping in
--- a link. nil on a server build without GetPasswordHash: then there is
--- no link, rather than a guessable one.
---
--- Costly, by design of bcrypt — a tenth of a second or so — and asked for
--- once a save, never per request.
---@return string|nil
function Photos.secureId()
    if type(GetPasswordHash) ~= 'function' then return nil end
    local ok, hash = pcall(GetPasswordHash, 'crimson-hitman')
    if not ok or type(hash) ~= 'string' then return nil end
    local salt = hash:match('^%$2%a?%$%d%d%$([%./%w]+)$')
    salt = salt and salt:sub(1, 22)
    if not salt or #salt ~= 22 then return nil end
    return (salt:gsub('[%./]', { ['.'] = '_', ['/'] = '-' }))
end

--- Whether this server can serve a photo kept on it to a phone's Photos:
--- it has a public address and a source of unguessable names.
---@return boolean
function Photos.linkable()
    return Photos.publicBase() ~= nil and type(GetPasswordHash) == 'function'
end

--- The phone number the client is saving from, so a factory reset of that
--- phone lets go of what was saved on it. nil where lb-phone cannot say.
local function phoneNumberOf(src)
    local ok, number = pcall(function()
        return exports['lb-phone']:GetEquippedPhoneNumber(src)
    end)
    if not ok or (type(number) ~= 'string' and type(number) ~= 'number') then return nil end
    number = tostring(number)
    if number == '' or #number > 32 then return nil end
    return number
end

--- Give the open photo a link the client's phone can save to its Photos.
---
--- Its state does not move: until the page says the phone has it ('save'),
--- the photo is still open, and the time to decide still runs out on it
--- (Photos.expire), which takes the link with it. A link handed to a page
--- that then never answered is served for minutes, not for good.
local function publish(actor, record)
    if record.kind ~= 'file' or not fileOf(record) then return nil, CH.ERR.PHOTO_NO_LINK end
    if served(record) and type(record.saved_link) == 'string' then
        return { handle = record.id, state = record.state, link = record.saved_link }
    end

    local base = Photos.publicBase()
    local name = base and Photos.secureId()
    if not name then return nil, CH.ERR.PHOTO_NO_LINK end
    local link = base .. '/p/' .. name .. '.' .. CH.PHOTO_MIME[record.mime]
    if #link > LINK_MAX then return nil, CH.ERR.PHOTO_NO_LINK end

    if not Storage.publishPhoto(record.id, record.state, name, link, phoneNumberOf(actor.source)) then
        return nil, CH.ERR.PHOTO_GONE
    end
    Audit.action('photo_linked', actor.cid, record.contract_id, {})
    return { handle = record.id, state = record.state, link = link }
end

--- Answer one HTTP request to this resource (SetHttpHandler, wired in
--- bridges.lua): a served photo, read-only, or 404.
---
--- The request is parsed strictly and nothing in it reaches the disk: the
--- path, query dropped, must be '/p/<name>.<ext>'; the name is looked up in
--- the store; the file read is the one the record names (fileOf). GET only.
--- Every other answer is the same 404, so a request learns nothing about
--- which part of it was wrong, and a photo no longer served — deleted from
--- the phone, deleted by its client — is not there.
---@param req table FiveM's request: method, path
---@param res table FiveM's response: writeHead, send
function Photos.serveHttp(req, res)
    local function notFound()
        res.writeHead(404, { ['Content-Type'] = 'text/plain; charset=utf-8' })
        res.send('Not found.')
    end

    if type(req) ~= 'table' or req.method ~= 'GET' or type(req.path) ~= 'string'
        or #req.path > 200 then
        return notFound()
    end
    local name, ext = (req.path:match('^([^?#]*)') or ''):match(SERVED_PATH)
    if not name or #name < 16 or #name > 48 then return notFound() end

    local record = Storage.readPhotoByPublic(name)
    if not record or record.public_id ~= name or record.kind ~= 'file'
        or (record.state ~= CH.PHOTO.OPEN and record.state ~= CH.PHOTO.SAVED)
        or CH.PHOTO_MIME[record.mime] ~= ext then
        return notFound()
    end
    local bytes = readBytes(record)
    if not bytes then return notFound() end

    -- Header values as strings: FiveM throws on a number. No length either:
    -- on HTTP/1.1 it sends the body chunked and drops one. no-store, so a
    -- photo deleted here is not still sitting in a phone's or a proxy's
    -- cache.
    res.writeHead(200, {
        ['Content-Type'] = record.mime,
        ['Cache-Control'] = 'no-store',
        ['X-Content-Type-Options'] = 'nosniff',
        ['Referrer-Policy'] = 'no-referrer',
        ['Access-Control-Allow-Origin'] = '*',
    })
    res.send(bytes)
end

--- Whether lb-phone takes a link into a gallery, decided as lb-phone
--- decides it (shared/media.lua, IsMediaLinkAllowed): the host as it reads
--- it, port and all, matched against its Config.UploadWhitelistedHostnames
--- ('*' is one label) and Config.UploadWhitelistedDomains (the domain and
--- every subdomain). Both lists empty lets any link through. For /ch-diag:
--- a gallery that refuses this server's links refuses every photo saved
--- through them.
---@param link string
---@return boolean|nil allowed nil when lb-phone's config cannot be read
---@return string host the host to add to the list, as lb-phone reads it
function Photos.galleryAllows(link)
    local host = type(link) == 'string' and link:match('^https?://([^/]+)') or nil
    if not host then return false, '' end
    if not host:find('%.') then return false, host end

    local ok, phoneConfig = pcall(function()
        return exports['lb-phone']:GetConfig()
    end)
    if not ok or type(phoneConfig) ~= 'table' then return nil, host end
    local hostnames = type(phoneConfig.UploadWhitelistedHostnames) == 'table'
        and phoneConfig.UploadWhitelistedHostnames or {}
    local domains = type(phoneConfig.UploadWhitelistedDomains) == 'table'
        and phoneConfig.UploadWhitelistedDomains or {}
    if next(hostnames) == nil and next(domains) == nil then return true, host end

    local function escape(text) return (text:gsub('(%W)', '%%%1')) end
    for _, entry in pairs(hostnames) do
        if type(entry) == 'string' then
            local parts = {}
            for segment in entry:gmatch('[^%.]+') do
                parts[#parts + 1] = segment == '*' and '[^.]+' or escape(segment)
            end
            if host:find('^' .. table.concat(parts, '%.') .. '$') then return true, host end
        end
    end
    for _, entry in pairs(domains) do
        if type(entry) == 'string' then
            local domain = escape(entry)
            if host:find('^' .. domain .. '$') or host:find('^.+%.' .. domain .. '$') then
                return true, host
            end
        end
    end
    return false, host
end

--------------------------------------------------------------------------
-- The one look, and what the client does with it
--------------------------------------------------------------------------

--- The client's one look at a photo, or another look at one kept for them.
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
---
--- A photo KEPT in the app opens as often as its owner likes and stays
--- kept; it says so (`kept`), so the page offers Delete and Close rather
--- than the one-look choices. An unseen photo on this server says whether
--- this server can give it a link for the phone's Photos (`link`).
---@param actor table
---@param rawHandle any
---@return table|nil view { handle, url | image, kept?, link? }
---@return string|nil err
function Photos.open(actor, rawHandle)
    local record = owned(actor, rawHandle)
    if not record then return nil, CH.ERR.PHOTO_GONE end
    local kept = record.state == CH.PHOTO.KEPT
    if record.state ~= CH.PHOTO.PENDING and not kept then return nil, CH.ERR.PHOTO_GONE end

    local view
    if record.kind == 'url' and type(record.url) == 'string' then
        view = { handle = record.id, url = record.url }
    elseif record.kind == 'file' then
        local image
        if kept then image = keptDataUri(record) else image = dataUri(record) end
        if not image then
            local contractId = record.contract_id
            if close(record, CH.PHOTO.DELETED) then
                Audit.action('photo_unreadable', actor.cid, contractId, {})
            end
            return nil, CH.ERR.PHOTO_GONE
        end
        view = { handle = record.id, image = image }
    else
        return nil, CH.ERR.PHOTO_GONE
    end

    if kept then
        view.kept = true
        return view
    end

    if not Storage.openPhoto(record.id, os.time()) then return nil, CH.ERR.PHOTO_GONE end
    if record.kind == 'file' and Photos.linkable() then view.link = true end

    Audit.action('photo_opened', actor.cid, record.contract_id, {})
    return view
end

--- Where a kept photo's file goes: data/photos/kept/, or failing that a
--- kept- name beside the others, or failing that where it already is. The
--- record says wherever it ended up.
local function keptFile(record)
    local file = fileOf(record)
    if not file then return nil end
    local ext = file:match('%.(%a+)$')
    makeFolder(KEPT_DIR)
    for _, to in ipairs({ KEPT_DIR .. '/' .. record.id .. '.' .. ext,
                          PHOTO_DIR .. '/' .. KEPT_PREFIX .. record.id .. '.' .. ext }) do
        if to == file or moveFile(file, to) then return to end
    end
    return file
end

--- Keep the open photo for its client in the app (route C of Save to
--- Photos): their phone cannot take it, or would not when they tried.
--- Any link this server was serving it under is let go of in the same
--- step: it was for a save that did not happen.
local function keep(actor, record)
    local file
    if record.kind == 'file' then
        if not fileOf(record) then return nil, CH.ERR.PHOTO_GONE end
        file = keptFile(record)
    end
    local from = record.file
    if not Storage.keepPhoto(record.id, CH.PHOTO.OPEN, file) then
        -- Deleted or timed out in the meantime. A file moved for it would
        -- be named by no record; the one it moved from went with that.
        if file and file ~= from then removeFile(file) end
        return nil, CH.ERR.PHOTO_GONE
    end
    Audit.action('photo_kept', actor.cid, record.contract_id, {})
    return { handle = record.id, state = CH.PHOTO.KEPT }
end

--- What the client did with the photo they opened.
---
---   'save'   their phone's Photos has it now. On a host the link is
---            forgotten; a photo this server kept is deleted, unless the
---            phone saved the link this server serves it under ('link'),
---            whose file stays until the phone lets it go.
---   'delete' it goes, now.
---   'keep'   their phone cannot take it: it is kept for them in the app.
---   'link'   the link to save it with, for a photo kept on this server;
---            the photo stays open until 'save' (see publish).
---
--- Every choice needs the photo open, except deleting one kept in the app,
--- which its owner can do whenever they open it.
---@param actor table
---@param rawHandle any
---@param choice any
---@return table|nil result { handle, state, link? }
---@return string|nil err
function Photos.decide(actor, rawHandle, choice)
    if choice ~= 'save' and choice ~= 'delete' and choice ~= 'keep' and choice ~= 'link' then
        return nil, CH.ERR.INVALID_INPUT
    end

    local record = owned(actor, rawHandle)
    if not record then return nil, CH.ERR.PHOTO_GONE end
    local state = record.state
    if not (state == CH.PHOTO.OPEN or (state == CH.PHOTO.KEPT and choice == 'delete')) then
        return nil, CH.ERR.PHOTO_GONE
    end

    if choice == 'link' then return publish(actor, record) end
    if choice == 'keep' then return keep(actor, record) end

    local next_ = choice == 'save' and CH.PHOTO.SAVED or CH.PHOTO.DELETED
    local contractId = record.contract_id
    if choice == 'save' and served(record) then
        if not Storage.movePhoto(record.id, state, next_) then return nil, CH.ERR.PHOTO_GONE end
    elseif not close(record, next_) then
        return nil, CH.ERR.PHOTO_GONE
    end

    Audit.action(choice == 'save' and 'photo_saved' or 'photo_deleted', actor.cid, contractId, {})
    return { handle = record.id, state = next_ }
end

--- Every one of one client's photos, by handle: for the Ledger to say what
--- became of each, and to list the ones kept in the app whose row is gone.
---@param cid string
---@return table<string, table>
function Photos.ofOwner(cid)
    local out = {}
    for _, record in ipairs(Storage.photosOf(cid) or {}) do
        if record.owner_cid == cid then out[record.id] = record end
    end
    return out
end

--------------------------------------------------------------------------
-- Every other way a photo ends
--------------------------------------------------------------------------

--- Delete every photo left open past Config.Completion.PhotoOpenSeconds,
--- as if the client had tapped Delete. This is what a phone closed
--- mid-view comes to: the page never got to say anything.
---@return integer deleted
function Photos.expire()
    local seconds = tonumber(Config.Completion.PhotoOpenSeconds) or 600
    local due = Storage.photosOpenedBefore(os.time() - seconds, PER_PASS) or {}
    local deleted = 0
    for i = 1, #due do
        local contractId = due[i].contract_id
        if close(due[i], CH.PHOTO.DELETED) then
            deleted = deleted + 1
            Audit.action('photo_expired', nil, contractId, {})
        end
    end
    return deleted
end

--- Delete the photos kept in the app longer than
--- Config.Completion.KeptPhotoDays, counted from when they were kept. Unset
--- (the default), a kept photo stays until its owner deletes it.
---@return integer deleted
function Photos.forgetKept()
    local days = tonumber(Config.Completion.KeptPhotoDays)
    if not days or days <= 0 then return 0 end
    local due = Storage.photosOpenedBefore(os.time() - days * 86400, PER_PASS, CH.PHOTO.KEPT) or {}
    local deleted = 0
    for i = 1, #due do
        local contractId = due[i].contract_id
        if close(due[i], CH.PHOTO.DELETED) then
            deleted = deleted + 1
            Audit.action('photo_kept_expired', nil, contractId, {})
        end
    end
    return deleted
end

--- Forget every photo kept before the cutoff, whatever became of it: one
--- never opened is deleted, and the record of one saved or deleted goes
--- with the ledger reference that named it (Ledger.forgetOldPhotos).
---
--- Not one kept in the app, nor one this server serves to a phone's
--- Photos: the store does not offer those (photosCreatedBefore), so a
--- backlog of them cannot fill every pass.
---@param cutoff integer
---@return integer forgotten
function Photos.forgetBefore(cutoff)
    local old = Storage.photosCreatedBefore(cutoff, PER_PASS) or {}
    local forgotten = 0
    for i = 1, #old do
        if old[i].state ~= CH.PHOTO.KEPT and not served(old[i]) then
            local held = holding(old[i])
            Storage.deletePhoto(old[i].id)
            release(held)
            forgotten = forgotten + 1
        end
    end
    return forgotten
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
---
--- Not a photo kept in the app, which outlives its row (the Ledger lists
--- it on its own; Ledger.entries), nor one in the client's Photos through
--- a link this server serves: the ledger's depth is about how much history
--- a player is shown, and a photo its owner chose to keep is not history
--- to be pushed out by the next ten contracts somebody works.
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
        if not named[record.id] and (tonumber(record.created_at) or 0) < oldest
            and record.state ~= CH.PHOTO.KEPT and not served(record) then
            local held = holding(record)
            Storage.deletePhoto(record.id)
            release(held)
            forgotten = forgotten + 1
        end
    end
    return forgotten
end

--- Delete the photos of one contract that this app still holds: to be
--- seen, open, or kept in the app. For a staff void: a contract staff close
--- is not left with a photo of a body waiting out the retention days, or
--- held in the app for good. One the client saved is in their phone's
--- Photos, which is theirs.
---@param contractId string
---@return integer deleted
function Photos.forgetContract(contractId)
    local deleted = 0
    for _, record in ipairs(Storage.photosForContract(contractId) or {}) do
        if (record.state == CH.PHOTO.PENDING or record.state == CH.PHOTO.OPEN
                or record.state == CH.PHOTO.KEPT)
            and close(record, CH.PHOTO.DELETED) then
            deleted = deleted + 1
        end
    end
    return deleted
end

--- The client deleted a photo from their phone's Photos
--- (lb-phone:deletedFromGallery, wired in bridges.lua). If it is one this
--- server serves, its file and link go: the gallery was the only reason to
--- keep it.
---
--- Only for its owner. A link can be passed on — shared to another phone
--- and saved there — and somebody else deleting their copy is not the
--- client letting theirs go.
---@param actor table the player who deleted it
---@param link any what lb-phone says was deleted
---@return boolean released
function Photos.galleryDeleted(actor, link)
    if type(actor) ~= 'table' or not actor.cid or type(link) ~= 'string'
        or #link > Util.MAX_URL_LENGTH then
        return false
    end
    local name = link:match('/p/([%w_-]+)%.%a+$')
    local record = name and Storage.readPhotoByPublic(name)
    if not record or record.public_id ~= name or record.owner_cid ~= actor.cid then
        return false
    end
    local contractId = record.contract_id
    if not close(record, CH.PHOTO.DELETED) then return false end
    Audit.action('photo_gallery_deleted', actor.cid, contractId, {})
    return true
end

--- The client factory reset a phone (lb-phone:factoryReset), which empties
--- its Photos: every photo this server serves that was saved from that
--- phone goes, files and links. One saved where lb-phone could not say
--- from which phone goes too: the reset may well have emptied it.
---@param actor table
---@param phoneNumber any
---@return integer released
function Photos.phoneReset(actor, phoneNumber)
    if type(actor) ~= 'table' or not actor.cid then return 0 end
    local number = phoneNumber ~= nil and tostring(phoneNumber) or nil
    local released = 0
    for _, record in pairs(Photos.ofOwner(actor.cid)) do
        if served(record) and (not record.saved_phone or record.saved_phone == number) then
            local contractId = record.contract_id
            if close(record, CH.PHOTO.DELETED) then
                released = released + 1
                Audit.action('photo_gallery_deleted', actor.cid, contractId, {})
            end
        end
    end
    return released
end

--- How many photos this server holds a file for, and how much disk they
--- take, by what they are: waiting to be seen or open, kept in the app,
--- and served to phones' Photos. For /ch-diag.
---@return table { waiting, kept, served } each { count, bytes }
function Photos.totals()
    local byState = Storage.photoTotals and Storage.photoTotals() or {}
    local function of(...)
        local total = { count = 0, bytes = 0 }
        for _, state in ipairs({ ... }) do
            local t = byState[state]
            if t then
                total.count = total.count + (tonumber(t.count) or 0)
                total.bytes = total.bytes + (tonumber(t.bytes) or 0)
            end
        end
        return total
    end
    return {
        waiting = of(CH.PHOTO.PENDING, CH.PHOTO.OPEN),
        kept = of(CH.PHOTO.KEPT),
        served = of(CH.PHOTO.SAVED),
    }
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
--- Both folders: data/photos/ and the kept/ folder inside it. Only names
--- this resource gives its files: anything else in either is left alone.
--- Needs io.readdir, which older server builds lack; there it says so once
--- and the files wait.
---
--- Only against the store that named them. "No record names it" is only
--- true of the store the files were written for: a server whose
--- Config.Database.Mode was switched started with a store that names none
--- of them, and this removed every kill photo the other mode kept or served
--- — for good, though switching back finds the records again. So the mode
--- the files belong to is written beside them (MODE_FILE), and a start in
--- another mode leaves them all alone and says so. Memory mode's records
--- never outlive a restart, so its files are swept by whatever comes next.
---@return integer removed
function Photos.sweepFiles()
    local base = resourceRoot()
    if not base then return 0 end

    local mode = tostring(Config.Database.Mode)
    local resource = GetCurrentResourceName()
    local owner = LoadResourceFile(resource, MODE_FILE)
    owner = owner and owner:match('^%s*([%w_]+)')
    if owner and owner ~= mode and owner ~= 'memory' then
        print(('[crimson-hitman] the kill photo files in %s were kept for %s mode, and this '
            .. 'server is in %s mode, whose store names none of them. They are left alone: '
            .. 'the start-up sweep of photo files is off until the mode is switched back, or '
            .. 'until %s is deleted once those photos are no longer wanted.')
            :format(PHOTO_DIR, owner, mode, MODE_FILE))
        return 0
    end
    if owner ~= mode then pcall(SaveResourceFile, resource, MODE_FILE, mode, -1) end
    local readdir = io and io.readdir
    if type(readdir) ~= 'function' then
        print('[crimson-hitman] this server build cannot list a folder (io.readdir), so kill '
            .. 'photo files left in ' .. PHOTO_DIR .. ' by a crash are not swept at start. '
            .. 'Update the server to have them removed.')
        return 0
    end

    local files = {}
    for _, dir in ipairs({ PHOTO_DIR, KEPT_DIR }) do
        local ok, listing = pcall(readdir, base .. '/' .. dir)
        if ok and listing then
            pcall(function()
                for name in listing:lines() do files[#files + 1] = dir .. '/' .. name end
            end)
            pcall(function() listing:close() end)
        end
    end

    local removed = 0
    for i = 1, #files do
        local file = files[i]
        local id = handleIn(file)
        if id and fileOf({ id = id, file = file }) then
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
