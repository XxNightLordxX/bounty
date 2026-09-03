--- Live target mugshots (§7.2, §14.26).
---
--- A headshot can only be rendered by a client whose game has the ped, so
--- the *target's own* client renders it and the server caches the result.
--- That works whatever the distance, and means one render serves every
--- viewer rather than one per listing.
---
--- Refreshes are event-driven — the target's client reports an appearance
--- change — with a floor so a player toggling clothing cannot force renders
--- in a loop.

local Mugshot = {}

local Identity, Audit

--- [cid] = { data = base64, at = os.time(), pending = bool }
local cache = {}

function Mugshot.init(deps)
    Identity, Audit = deps.identity, deps.audit
    cache = {}
end

--- The cached image for a citizen, or nil if none has been rendered yet.
function Mugshot.get(cid)
    local entry = cache[cid]
    return entry and entry.data or nil
end

--- Ask a player's own client for a fresh headshot, subject to the refresh
--- floor. Returns whatever is cached right now; the new image arrives later.
function Mugshot.request(cid)
    local entry = cache[cid]
    local floor = (Config.Mugshot.MinRefreshMinutes or 5) * 60

    if entry and entry.pending then return entry.data end
    if entry and (os.time() - entry.at) < floor then return entry.data end

    local actor = Identity.byCitizenId(cid)
    if not actor then return entry and entry.data or nil end

    cache[cid] = { data = entry and entry.data or nil, at = os.time(), pending = true }
    TriggerClientEvent('crimson-bounty:renderMugshot', actor.source)

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
    if type(image) ~= 'string' then return false end
    if #image > (Config.Mugshot.MaxImageBytes or 262144) then
        Audit.rejected('mugshot_too_large', cid, nil, { bytes = #image })
        return false
    end
    if not image:match('^data:image/[%w%+%-%.]+;base64,[%w%+/=]+$') then
        Audit.rejected('mugshot_bad_format', cid, nil, {})
        return false
    end

    cache[cid] = { data = image, at = os.time(), pending = false }
    return true
end

--- Drop a cached image so the next request re-renders. Called when the
--- target's appearance changes, rather than re-rendering on a timer.
function Mugshot.invalidate(cid)
    local entry = cache[cid]
    if not entry then return false end
    -- The floor still applies: an appearance change is a hint, not a licence
    -- to render on demand.
    if (os.time() - entry.at) < ((Config.Mugshot.MinRefreshMinutes or 5) * 60) then
        return false
    end
    cache[cid] = nil
    return true
end

function Mugshot.clearPlayer(cid)
    cache[cid] = nil
end

function Mugshot.count()
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    return n
end

return Mugshot
