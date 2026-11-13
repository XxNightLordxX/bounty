CrimsonBoot.define('server.mugshot', function() --- Live target mugshots (§7.2, §14.26).
---
--- A headshot can only be rendered by a client whose game has the ped, so
--- the *target's own* client renders it and the server caches the result.
--- That works whatever the distance, and means one render serves every
--- viewer rather than one per listing.
---
--- Refreshes are event-driven — the target's client reports an appearance
--- change — with a floor so a player toggling clothing cannot force renders
--- in a loop.
---
--- And none at all with Config.Mugshot.Enabled off: no render is asked
--- for, none is taken, none is kept, and every card shows the usual
--- placeholder. Read at every use, so the admin panel's switch applies at
--- once.

local Feature = CrimsonBoot.require('server.lib.feature')
local Integrations = CrimsonBoot.require('server.adapters.init')

local Mugshot = {}

local Identity, Audit

--- [cid] = { data = base64, id = handle, at = os.time(), pending = bool }
local cache = {}

--- [handle] = cid, so an image can be served by reference.
local byHandle = {}

local handleSeq = 0

--- Mint an opaque handle for a freshly stored image.
---
--- Opaque, not the citizen id: a listing row carries this to every viewer,
--- and a citizen id there would be an identifier leak and an enumeration
--- surface. A new image gets a new handle, which is also how the app's cache
--- invalidates — it never has to be told an image changed.
local function mintHandle(cid)
    handleSeq = handleSeq + 1
    local handle = ('mg%d_%d'):format(handleSeq, math.random(100000, 999999))
    byHandle[handle] = cid
    return handle
end

local function dropHandle(entry)
    if entry and entry.id then byHandle[entry.id] = nil end
end

function Mugshot.init(deps)
    Identity, Audit = deps.identity, deps.audit
    cache = {}
    byHandle = {}
    handleSeq = 0
end

--- The cached image for a citizen, or nil if none has been rendered yet.
function Mugshot.get(cid)
    if not Feature.on('Mugshot') then return nil end
    local entry = cache[cid]
    return entry and entry.data or nil
end

--- The handle of the citizen's current image, or nil if there is none.
--- This is what a projection carries instead of forty kilobytes of base64.
function Mugshot.handleFor(cid)
    if not Feature.on('Mugshot') then return nil end
    local entry = cache[cid]
    return entry and entry.data and entry.id or nil
end

--- Resolve a handle to the image it names. Returns nil for a handle that has
--- been replaced by a newer render or dropped — the app then simply shows no
--- headshot, which is what it does before the first render anyway.
function Mugshot.byHandle(handle)
    if not Feature.on('Mugshot') or type(handle) ~= 'string' then return nil end
    local cid = byHandle[handle]
    if not cid then return nil end
    local entry = cache[cid]
    -- A handle that is no longer the current one must not resolve: it would
    -- serve an image the owner has already replaced.
    if not entry or entry.id ~= handle then return nil end
    return entry.data
end

--- Whether the headshot renderer is running on this server.
---
--- Read here, on the server, and not left to the client. Without it the
--- server still asked every target's client for a face and took whatever
--- came back: an honest client gives up when the renderer is absent, and a
--- modified one answered with any picture it liked, which every viewer of
--- a contract on that target was then shown, on a server that expected no
--- faces at all. A resource the clients load is started on the server.
local function rendererRunning()
    return Integrations.has('mugshot')
end

--- How soon to ask again for a face that has never arrived, per request
--- that went unanswered: the client's own floor between renders. The
--- refresh floor (Config.Mugshot.MinRefreshMinutes) is for replacing an
--- image somebody already has. Applied to an entry with none, one first
--- render that failed (a ped still loading, a slow upload) left the board
--- without a headshot for five minutes. After three quick tries unanswered,
--- it waits the refresh floor, as before.
local NO_IMAGE_RETRY_SECONDS = 30
local NO_IMAGE_QUICK_TRIES = 3

--- How soon after its last render a face whose clothes changed is asked
--- for again (Mugshot.invalidate): sooner than the refresh floor, never on
--- demand.
local CHANGED_FLOOR_SECONDS = 60

--- How long an entry waits before it is asked for again, and from when.
local function nextAsk(entry, floor)
    if entry.data and entry.changed then return math.min(floor, CHANGED_FLOOR_SECONDS), entry.at end
    if entry.data then return floor, entry.at end
    local misses = entry.misses or 0
    local since = entry.askedAt or entry.at
    if misses >= NO_IMAGE_QUICK_TRIES then return floor, since end
    return math.min(floor, NO_IMAGE_RETRY_SECONDS * math.max(1, misses)), since
end

--- Ask a player's own client for a fresh headshot, subject to the refresh
--- floor. Returns whatever is cached right now; the new image arrives later.
function Mugshot.request(cid)
    -- Switched off: nobody's game is asked for anything.
    if not Feature.on('Mugshot') then return nil end
    local entry = cache[cid]
    if not rendererRunning() then return entry and entry.data or nil end
    local floor = (Config.Mugshot.MinRefreshMinutes or 5) * 60
    local timeout = (Config.Mugshot.RenderTimeoutMs or 8000) / 1000

    -- A request that was never answered must not pin the entry forever: the
    -- client may have disconnected, or simply chosen not to reply.
    if entry and entry.pending then
        if (os.time() - (entry.pendingSince or 0)) < timeout then return entry.data end
        entry.pending = false
        entry.misses = (entry.misses or 0) + 1
        -- After repeated silence, stop serving an image nobody is refreshing.
        -- An entry with no image serves nothing, and is kept: it is what
        -- spaces out the asking (nextAsk).
        if entry.misses >= 3 and entry.data then
            dropHandle(entry)
            cache[cid] = nil
            entry = nil
        end
    end

    if entry then
        local wait, since = nextAsk(entry, floor)
        if (os.time() - since) < wait then return entry.data end
    end

    local actor = Identity.byCitizenId(cid)
    if not actor then return entry and entry.data or nil end

    cache[cid] = {
        data = entry and entry.data or nil,
        -- The handle survives a pending refresh: the old image is still the
        -- current one until a new one arrives, and changing the handle here
        -- would make every viewer re-fetch the same bytes.
        id = entry and entry.id or nil,
        at = entry and entry.at or os.time(),
        misses = entry and entry.misses or 0,
        -- Still out of date until a new face arrives (Mugshot.invalidate).
        changed = entry and entry.changed or nil,
        pending = true,
        pendingSince = os.time(),
        -- When it was last asked, for an entry with no image yet (nextAsk).
        askedAt = os.time(),
    }
    TriggerClientEvent('crimson-hitman:renderMugshot', actor.source)

    return cache[cid].data
end

--- Store an image a client rendered of itself.
---
--- The payload is bounded and shape-checked: it is a base64 data URI from a
--- client, so it is untrusted content that ends up in other players' phones.
---@param cid string resolved from the event source, never from the payload
---@param image any
---@return boolean accepted
function Mugshot.store(cid, image)
    -- Only an image the server asked for is accepted. Without this a client
    -- can push a picture of its choosing into every viewer's listing without
    -- anything ever having requested a render.
    local entry = cache[cid]
    if not Feature.on('Mugshot') then return false end
    if not rendererRunning() then
        Audit.rejected('mugshot_no_renderer', cid, nil, {})
        return false
    end
    if not entry or not entry.pending then
        Audit.rejected('mugshot_unsolicited', cid, nil, {})
        return false
    end

    if type(image) ~= 'string' then return false end
    if #image > (Config.Mugshot.MaxImageBytes or 32768) then
        Audit.rejected('mugshot_too_large', cid, nil, { bytes = #image })
        return false
    end

    -- An explicit MIME allowlist, not a character class: 'image/svg+xml' and
    -- 'image/x-anything' both satisfy a pattern and neither is a headshot.
    local mime, payload = image:match('^data:(image/[%w%+%-%.]+);base64,([%w%+/=]+)$')
    if not mime or not Config.Mugshot.AllowedMime[mime] then
        Audit.rejected('mugshot_bad_format', cid, nil, { mime = mime })
        return false
    end

    -- Check the decoded prefix really is the format it claims, so the MIME
    -- label alone is not what decides what viewers are shown.
    local MAGIC = {
        ['image/png']  = 'iVBORw0KGgo',
        ['image/jpeg'] = '/9j/',
        ['image/webp'] = 'UklGR',
    }
    local expected = MAGIC[mime]
    if expected and payload:sub(1, #expected) ~= expected then
        Audit.rejected('mugshot_magic_mismatch', cid, nil, { mime = mime })
        return false
    end

    -- A new image gets a new handle, so a viewer holding the old one asks
    -- once and gets the new bytes rather than caching a stale face forever.
    dropHandle(entry)
    cache[cid] = {
        data = image, id = mintHandle(cid),
        at = os.time(), pending = false, misses = 0,
    }
    return true
end

--- Mark a cached image as out of date, so the next request re-renders it
--- sooner than the refresh floor: a minute after its last render
--- (CHANGED_FLOOR_SECONDS). Called when the target's appearance changes.
--- The old face is kept and served until the new one arrives. It used to be
--- refused inside the floor (so a change of clothes brought nothing
--- sooner) and, past it, dropped, which only blanked the face meanwhile.
function Mugshot.invalidate(cid)
    local entry = cache[cid]
    if not entry then return false end
    -- To a face somebody has: an entry with none is spaced out by its own
    -- wait (nextAsk), and keeping it is what does so.
    if not entry.data then return false end
    entry.changed = true
    return true
end

--- Age every cached image past the refresh floor, for the staff timer
--- refresh. The image is kept — dropping it would blank every board until
--- each client answered — but the next request re-renders instead of being
--- served the same face for the rest of the floor.
---@return integer aged
function Mugshot.clearRefreshFloor()
    local floor = (Config.Mugshot.MinRefreshMinutes or 5) * 60
    local aged = 0
    for _, entry in pairs(cache) do
        entry.at = os.time() - (floor + 1)
        aged = aged + 1
    end
    return aged
end

--- Forget every headshot kept, for headshots being switched off from the
--- admin panel (Bridges' settings hook): none is kept while they are off.
---@return integer forgotten
function Mugshot.clearAll()
    local forgotten = 0
    for cid, entry in pairs(cache) do
        dropHandle(entry)
        cache[cid] = nil
        forgotten = forgotten + 1
    end
    return forgotten
end

function Mugshot.clearPlayer(cid)
    dropHandle(cache[cid])
    cache[cid] = nil
end

function Mugshot.count()
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    return n
end

return Mugshot
end)
