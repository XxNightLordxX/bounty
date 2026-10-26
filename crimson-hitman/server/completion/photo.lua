--- Verification photo (§7.4, §14.20, §14.35).
---
--- The photo authenticates a claim that the server already believes: a
--- pending completion must exist before a token is issued, and the token is
--- what binds the eventual image to that specific contract, hitman and death
--- scene. An image on its own proves nothing and is never enough.
---
--- Two ways a photo arrives, by Config.Completion.PhotoStorage. On 'host'
--- lb-phone's camera uploads it to the phone's image host and the client
--- sends the link, which must come from a host on the allowlist below. On
--- 'server' the app's own viewfinder takes it and the client sends the
--- picture itself, which is checked here and kept as a file on this server;
--- no image host and no allowlist are involved.

local Util = require_shared('util')

local Photo = {}

local Storage, Identity, Contracts, Audit, Death, Notify, Ledger

--- [token] = { contractId, hitmanCid, victimCid, coords, issuedAt, used }
local tokens = {}
--- Where a photo may come from. Two kinds, as lb-phone itself keeps them:
--- domains, which also cover every subdomain (lb-phone's
--- Config.UploadWhitelistedDomains, plus Config.Completion.ExtraPhotoHosts),
--- and hostname patterns, matched whole, where '*' stands for one label
--- (lb-phone's Config.UploadWhitelistedHostnames).
local allowedDomains, hostPatterns = {}, {}

--- lb-phone's default media allowlist includes whole public clouds. Taken
--- over as they stand, a photo from anybody's own bucket would pass. Left
--- out unless the owner names them in ExtraPhotoHosts.
local SHARED_CLOUDS = {
    ['amazonaws.com'] = true, ['cloudfront.net'] = true, ['r2.dev'] = true,
    ['storage.googleapis.com'] = true, ['googleusercontent.com'] = true,
    ['blob.core.windows.net'] = true, ['digitaloceanspaces.com'] = true,
}

function Photo.init(deps)
    Storage, Identity, Contracts, Audit, Death, Notify, Ledger =
        deps.storage, deps.identity, deps.contracts, deps.audit,
        deps.death, deps.notify, deps.ledger
    tokens = {}
    Photo.loadAllowedHosts()
end

--- Where kill photos go: 'server' or 'host'. Checked at startup, so
--- anything else here is a config changed under a running server, read as
--- the default the startup check would have made it.
---@return string
function Photo.storage()
    return Config.Completion.PhotoStorage == 'host' and 'host' or 'server'
end

--- A host as somebody might write it — 'https://cdn.fivemanage.com/',
--- '*.fivemanage.com', 'FiveManage.com:443' — reduced to the bare name.
--- Taken as written, none of those ever matched a photo, while /ch-diag
--- listed them as allowed.
local function bareHost(entry)
    if type(entry) ~= 'string' then return nil end
    local host = entry:lower():gsub('^%s+', ''):gsub('%s+$', '')
    host = host:gsub('^%a[%w+.-]*://', '')
    host = host:match('^([^/?#]*)') or ''
    host = host:gsub(':%d+$', ''):gsub('^%*%.', ''):gsub('^%.+', ''):gsub('%.+$', '')
    if host == '' or not host:find('.', 1, true) or host:find('[^%w.-]') then return nil end
    return host
end

--- lb-phone's hostname entry as a whole-name pattern: '*' is one label.
local function hostnamePattern(entry)
    if type(entry) ~= 'string' then return nil end
    local name = entry:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' or name:find('[^%w.*-]') then return nil end
    return '^' .. name:gsub('[%.%-]', '%%%0'):gsub('%*', '[^.]+') .. '$', name
end

--- Build the allowlist from lb-phone's own media allowlist, so photos are
--- accepted from wherever the phone is allowed to upload, plus anything the
--- owner adds.
---
--- It used to read an Upload table of URLs from lb-phone's config. lb-phone
--- has no such table — its UploadMethod holds method names, and every
--- built-in method uploads to a presigned URL — so nothing was ever learned,
--- ExtraPhotoHosts shipped empty, and every kill photo on a stock install
--- was refused.
---
--- Re-read on the maintenance tick: an owner who changes upload provider
--- would otherwise have to restart this resource too. A change is logged.
---@return table allowedDomains
function Photo.loadAllowedHosts()
    local previous = {}
    for _, entry in ipairs(Photo.allowedHosts()) do previous[entry] = true end
    allowedDomains, hostPatterns = {}, {}

    local extra = {}
    for _, entry in ipairs(Config.Completion.ExtraPhotoHosts or {}) do
        local host = bareHost(entry)
        if host then
            allowedDomains[host] = true
            extra[host] = true
        end
    end

    local ok, phoneConfig = pcall(function()
        return exports['lb-phone']:GetConfig()
    end)
    if ok and type(phoneConfig) == 'table' then
        if type(phoneConfig.UploadWhitelistedDomains) == 'table' then
            for _, entry in pairs(phoneConfig.UploadWhitelistedDomains) do
                local host = bareHost(entry)
                if host and (not SHARED_CLOUDS[host] or extra[host]) then allowedDomains[host] = true end
            end
        end
        if type(phoneConfig.UploadWhitelistedHostnames) == 'table' then
            for _, entry in pairs(phoneConfig.UploadWhitelistedHostnames) do
                local pattern, name = hostnamePattern(entry)
                if pattern then hostPatterns[name] = pattern end
            end
        end
    end

    -- Only report a set that actually differs. On the tick this runs
    -- constantly and an unchanged allowlist is not news.
    local now = {}
    for _, entry in ipairs(Photo.allowedHosts()) do now[entry] = true end
    local added, removed = {}, {}
    for entry in pairs(now) do
        if not previous[entry] then added[#added + 1] = entry end
    end
    for entry in pairs(previous) do
        if not now[entry] then removed[#removed + 1] = entry end
    end

    if #added > 0 or #removed > 0 then
        table.sort(added)
        table.sort(removed)
        -- next(previous) is nil only on the very first load, which is not a
        -- change worth reporting as one.
        if next(previous) ~= nil then
            print(('[crimson-hitman] photo host allowlist changed: %s%s%s'):format(
                #added > 0 and ('+' .. table.concat(added, ' +')) or '',
                (#added > 0 and #removed > 0) and ' ' or '',
                #removed > 0 and ('-' .. table.concat(removed, ' -')) or ''))
        end

        Photo.hostsChangedAt = os.time()
    end

    -- Outside the change block. On the first load an empty list is "no
    -- change" from nothing, so the one warning that says every kill photo
    -- will be refused was never printed on the server it was written for.
    -- Once, and again only after hosts have come and gone.
    --
    -- Only where photos come from a host. On 'server' storage the list is
    -- never consulted, and a warning that every kill photo will be refused
    -- would send the owner to fix an image host they do not use.
    if Photo.storage() ~= 'host' then
        Photo.warnedEmpty = false
    elseif next(now) == nil then
        if not Photo.warnedEmpty then
            Photo.warnedEmpty = true
            print('[crimson-hitman] warning: no photo upload host is allowed, so every kill photo '
                .. 'will be refused. Add your phone\'s image host to Config.Completion.ExtraPhotoHosts '
                .. '(for Fivemanage: \'fivemanage.com\', \'fmfile.com\').')
        end
    else
        Photo.warnedEmpty = false
    end

    return allowedDomains
end

--- Every entry currently accepted, sorted: domains as written, hostname
--- patterns with their '*'. For the admin command and tests.
function Photo.allowedHosts()
    local out = {}
    for host in pairs(allowedDomains or {}) do out[#out + 1] = host end
    for name in pairs(hostPatterns or {}) do
        if not (allowedDomains or {})[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

function Photo.hostAllowed(url)
    local host = Util.urlHost(url)
    if not host then return false end
    if allowedDomains[host] then return true end
    -- A subdomain of an allowed domain is allowed; an unrelated host is not.
    for allowed in pairs(allowedDomains) do
        if #host > #allowed and host:sub(-(#allowed + 1)) == '.' .. allowed then return true end
    end
    for _, pattern in pairs(hostPatterns) do
        if host:match(pattern) then return true end
    end
    return false
end

--------------------------------------------------------------------------
-- A photo kept on this server
--------------------------------------------------------------------------

--- How each kind of picture begins, checked on the decoded bytes so the
--- label the client put on it is not what decides what the client's page
--- is later shown (the mugshot's rule, server/mugshot.lua).
local SIGNATURES = {
    ['image/png']  = function(b) return b:sub(1, 8) == '\137PNG\r\n\26\n' end,
    ['image/jpeg'] = function(b) return b:sub(1, 3) == '\255\216\255' end,
    ['image/webp'] = function(b) return b:sub(1, 4) == 'RIFF' and b:sub(9, 12) == 'WEBP' end,
}

--- The picture a client sent for 'server' storage, checked, decoded once
--- and ready to keep: { kind = 'file', data = bytes, mime }.
---
--- A data URI, as the page makes it, of one of CH.PHOTO_MIME's three types
--- and no bigger than Config.Completion.PhotoMaxBytes once decoded.
---
--- Every way it can be refused is judged before the decode, which is the
--- one costly step: base64 in pure Lua, about 60ms for a picture of the
--- default size and half a second for the largest an owner may allow, on
--- the server's main thread. The checks ran on the decoded bytes, so a
--- picture of the right size and the wrong kind cost a whole decode to
--- refuse, as many times as it was sent. Now the size comes from the
--- length of the text, the kind from its first sixteen characters, and
--- whether the rest is base64 at all from one native pattern scan; only a
--- picture that will be kept is decoded.
---@param raw any
---@return table|nil capture
---@return string|nil err
---@return string|nil why for the audit row
---@return table|nil detail for the audit row, never the picture
function Photo.readImage(raw)
    if type(raw) ~= 'string' then return nil, CH.ERR.PHOTO_BAD_IMAGE, 'photo_not_an_image', {} end
    local max = tonumber(Config.Completion.PhotoMaxBytes) or 600000

    -- Read without a pattern over the whole text first: the prefix is
    -- short, and the bound on the rest is what keeps a huge upload cheap.
    local comma = raw:find(',', 1, true)
    local head = comma and comma <= 40 and raw:sub(1, comma) or nil
    local mime = head and head:match('^data:(image/[%w%+%-%.]+);base64,$')
    if not mime or not CH.PHOTO_MIME[mime] then
        return nil, CH.ERR.PHOTO_BAD_IMAGE, 'photo_bad_format',
            { mime = mime and mime:sub(1, 32) or nil }
    end
    local encoded = #raw - comma
    if encoded > math.ceil(max / 3) * 4 then
        return nil, CH.ERR.PHOTO_TOO_LARGE, 'photo_too_large', { bytes = encoded }
    end
    if encoded == 0 or encoded % 4 ~= 0 then
        return nil, CH.ERR.PHOTO_BAD_IMAGE, 'photo_bad_format', { mime = mime }
    end

    -- The exact size it decodes to: three bytes for every four characters,
    -- less one for each '=' that pads the end.
    local pad = raw:sub(-2) == '==' and 2 or raw:sub(-1) == '=' and 1 or 0
    local bytes = encoded // 4 * 3 - pad
    if bytes > max then
        return nil, CH.ERR.PHOTO_TOO_LARGE, 'photo_too_large', { bytes = bytes }
    end

    -- What kind of picture it is, from the first twelve bytes alone: the
    -- longest signature (webp's) ends at the twelfth.
    local first = Util.fromBase64(raw:sub(comma + 1, comma + math.min(encoded, 16)))
    if not first or not SIGNATURES[mime](first) then
        return nil, CH.ERR.PHOTO_BAD_IMAGE, 'photo_magic_mismatch', { mime = mime }
    end

    -- Base64 to the end, '=' only as the last one or two. Anchored, so the
    -- scan runs once along the text and never backs up: a few milliseconds
    -- where the decode would have spent its whole length finding the one
    -- bad character at the end.
    local _, last = raw:find('^[A-Za-z0-9+/]*', comma + 1)
    if #raw - (last or comma) ~= pad then
        return nil, CH.ERR.PHOTO_BAD_IMAGE, 'photo_bad_format', { mime = mime }
    end

    -- The decoder still has the last word on what it can read, and on the
    -- size worked out above.
    local data = Util.fromBase64(raw:sub(comma + 1))
    if not data or #data ~= bytes then
        return nil, CH.ERR.PHOTO_BAD_IMAGE, 'photo_bad_format', { mime = mime }
    end
    return { kind = 'file', data = data, mime = mime }
end

--------------------------------------------------------------------------
-- Tokens
--------------------------------------------------------------------------

local counter = 0

--- How long a hit of this hitman's counts as recent, for telling them their
--- target is down rather than dead. Roughly a last stand: a hit older than
--- that is not what put them on the ground now.
local DOWNED_HIT_SECONDS = 300

--- Whether this hitman's target is down but not dead, asked of a hitman
--- with no kill to prove. Right after downing the target is the commonest
--- moment to tap Verify kill, and a downed target never opens a kill, so
--- the answer was "take the target down" to somebody who just had.
---
--- Answered only to a hitman on the contract who is within weapon range of
--- the target or hit them lately. Anyone else would have a remote "is my
--- target down right now" check, which tracking refuses to be.
local function downedInReach(actor, contractId)
    local contract = Storage.readContract(contractId)
    if not contract or contract.state ~= CH.STATE.ACCEPTED or not contract.target_cid then
        return false
    end
    local hitman = Storage.readHitman(contractId, actor.cid)
    if not hitman or hitman.state ~= 'active' then return false end

    local victim = Identity.byCitizenId(contract.target_cid)
    if not victim then return false end
    local _, down, known = Identity.deathState(victim.source)
    if not (known and down) or Identity.isTrulyDead(victim.source) then return false end

    local hitAt = Death.lastHit(actor.cid, contract.target_cid)
    if hitAt and os.time() - hitAt <= DOWNED_HIT_SECONDS then return true end
    local range = Config.Completion.MaxWeaponRange
    return Util.dist2(GetEntityCoords(GetPlayerPed(actor.source)),
        GetEntityCoords(GetPlayerPed(victim.source))) <= range * range
end

--- Issue a capture token for a pending completion. One live token per
--- hitman-contract pair: requesting another invalidates the first, so a
--- hitman cannot bank tokens for later.
---@return string|nil token
---@return string|nil err
function Photo.issue(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CH.ERR.INVALID_INPUT end

    -- A contract placed for a live delivery only has no kill to verify, ever.
    -- Said first and plainly to a hitman on it: "no kill is waiting, finish
    -- them and take the photo" is the one thing that can never pay on it.
    -- Its rule is a term they were shown when they took it. Anybody else is
    -- told what they were always told, that there is no kill of theirs, so
    -- an id is not a way to ask whether a contract still exists.
    local contract = Storage.readContract(contractId)
    if contract and Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE then
        local hitman = Storage.readHitman(contractId, actor.cid)
        if hitman and hitman.state == 'active' then return nil, CH.ERR.KILL_NOT_ALLOWED end
        return nil, CH.ERR.NO_KILL_TO_VERIFY
    end

    -- Its own code. This is the ordinary outcome of tapping Verify kill at
    -- any moment other than standing over a body the server saw this hitman
    -- put there, and it needs to say so.
    local record = Death.getPending(contractId, actor.cid)
    if not record then
        -- Killed, by their own game's word, with nothing the server can see
        -- land: a blast, fire, a car. Only the hitman it named is told.
        if Death.unobservedKill(contractId, actor.cid) then return nil, CH.ERR.KILL_UNOBSERVED end
        if downedInReach(actor, contractId) then return nil, CH.ERR.PHOTO_STILL_DOWN end
        return nil, CH.ERR.NO_KILL_TO_VERIFY
    end

    for token, existing in pairs(tokens) do
        if existing.contractId == contractId and existing.hitmanCid == actor.cid then
            tokens[token] = nil
        end
    end

    counter = counter + 1
    local token = ('tk%s%08d'):format(contractId:gsub('[^%w]', ''), counter)

    tokens[token] = {
        contractId = contractId,
        hitmanCid  = actor.cid,
        victimCid  = record.victimCid,
        coords     = record.coords,
        diedAt     = record.at,
        issuedAt   = Util.monotonicMs(),
        used       = false,
    }
    -- The kill this token proves is kept as long as the token is good, and
    -- the token is good no longer than the kill is kept. A token asked for
    -- late outlived its kill, and the photograph was refused as a revive
    -- with the body still on the ground.
    local lifetimeMs = Config.Completion.PhotoTokenLifetimeSeconds * 1000
    tokens[token].expiresAt = Death.holdPending(contractId, actor.cid,
        tokens[token].issuedAt + lifetimeMs) or (tokens[token].issuedAt + lifetimeMs)

    Audit.action('photo_token_issued', actor.cid, contractId, {})
    return token
end

--------------------------------------------------------------------------
-- Submission
--------------------------------------------------------------------------

--- Verify a submitted photo and, if everything holds, claim a payout slot.
---
--- Four factors are checked together, and all of them are server-side facts.
--- In this order, the photo last, because reading a picture is the one that
--- costs the server anything:
---   * the token exists, is unused, unexpired, and was issued to this hitman
---   * the hitman is standing at the death scene
---   * the target is still dead — a revive invalidates the claim
---   * the photo is one this server takes: on 'host' storage a link from
---     the host lb-phone uploads to, on 'server' a real picture of a size
---     it keeps
---
--- Only the form the configured storage takes is accepted. A link sent to a
--- server that keeps its photos itself is refused, not stored: the owner
--- chose 'server' so that no image host is involved.
---
---@param actor table resolved from the event source
---@param rawToken any
---@param rawUrl any the link, on 'host' storage
---@param rawImage any the picture as a data URI, on 'server' storage
---@return boolean ok
---@return string|nil err
---@return table|nil result
---@return boolean|nil read on a refusal, true where the picture was read
function Photo.submit(actor, rawToken, rawUrl, rawImage)
    local token = Util.toId(rawToken)
    if not token then
        Audit.rejected('photo_bad_token', actor.cid, nil, {})
        return false, CH.ERR.TOKEN_INVALID
    end

    local record = tokens[token]
    if not record or record.used then
        Audit.rejected('photo_token_unknown_or_used', actor.cid, nil, {})
        return false, CH.ERR.TOKEN_INVALID
    end

    -- The token belongs to whoever it was issued to, and to nobody else.
    if record.hitmanCid ~= actor.cid then
        Audit.rejected('photo_token_foreign', actor.cid, record.contractId, {})
        return false, CH.ERR.TOKEN_INVALID
    end

    -- Never for a contract that pays only for a live delivery. Photo.issue
    -- mints no token for one, and the rule cannot change once placed, so a
    -- token here for one is a fault somewhere else: refused, and spent,
    -- before the picture costs anything to read.
    local placed = Storage.readContract(record.contractId)
    if placed and Util.fulfilmentRule(placed) == CH.FULFILMENT_RULE.ALIVE then
        tokens[token] = nil
        Audit.rejected('photo_kill_not_allowed', actor.cid, record.contractId, {})
        return false, CH.ERR.KILL_NOT_ALLOWED
    end

    if Util.monotonicMs() - record.issuedAt > (Config.Completion.PhotoTokenLifetimeSeconds * 1000)
        or (record.expiresAt and Util.monotonicMs() > record.expiresAt) then
        tokens[token] = nil
        -- A token is never good past the kill it proves, so an expired one
        -- usually means the kill has lapsed too, and "take the photo again"
        -- sent the hitman back for a kill that could no longer be claimed.
        -- Only a newer kill of theirs standing in its place still can.
        if Death.getPending(record.contractId, actor.cid) then
            return false, CH.ERR.TOKEN_INVALID
        end
        Audit.rejected('photo_proof_expired', actor.cid, record.contractId, {})
        return false, CH.ERR.PROOF_EXPIRED
    end

    -- The server's own facts first, and the photo only once they hold. On
    -- 'server' storage reading the photo is a decode in pure Lua, and it
    -- used to come first: a picture sent from nowhere near the body, or for
    -- a kill already undone, was decoded in full and only then refused, as
    -- often as it was sent. Now only a hitman standing at a kill that still
    -- stands gets that far.
    --
    -- The hitman must be at the scene. Position is read server-side; a
    -- client claiming to be somewhere is not consulted.
    --
    -- The scene is where the body was when the death was recorded, or where
    -- it is now. A body keeps moving after that: a dead driver's car rolls
    -- on, a passenger is driven off, friends carry it, a stretcher takes it.
    -- Measured only from the first, a hitman standing over the body was told
    -- to stand over the body. Where it is now is read only for a victim who
    -- is online and still dead, and the kill must still stand (below), so
    -- nothing can be claimed that could not be before.
    local hitmanCoords = GetEntityCoords(GetPlayerPed(actor.source))
    local radius = Config.Completion.PhotoRadius
    local near = Util.dist2(hitmanCoords, record.coords) <= radius * radius
    if not near then
        local body = Identity.byCitizenId(record.victimCid)
        near = body ~= nil and Identity.isTrulyDead(body.source)
            and Util.dist2(hitmanCoords, GetEntityCoords(GetPlayerPed(body.source))) <= radius * radius
    end
    if not near then
        Audit.rejected('photo_out_of_range', actor.cid, record.contractId, {})
        return false, CH.ERR.PHOTO_TOO_FAR
    end

    -- The kill this token was issued for must still stand: a revive clears
    -- it (Death.onRevived), and the token outlived it. A target revived and
    -- then gone offline, or dead again of something else, passed the check
    -- below, and the hitman was paid for a kill that had been undone.
    local stillPending = Death.getPending(record.contractId, actor.cid)
    if not stillPending then
        Audit.rejected('photo_kill_undone', actor.cid, record.contractId, {})
        tokens[token] = nil
        return false, CH.ERR.PHOTO_REVIVED
    end
    -- A newer kill of theirs took its place: the target got up and this
    -- hitman put them down again. That one needs its own photograph, and
    -- being told they had been brought back read as the kill being lost.
    if record.diedAt and stillPending.at ~= record.diedAt then
        Audit.rejected('photo_kill_replaced', actor.cid, record.contractId, {})
        tokens[token] = nil
        return false, CH.ERR.TOKEN_INVALID
    end

    -- Still dead? A target revived between the kill and the photo was not
    -- eliminated (§7.4) — but a short proof window follows the death itself,
    -- because players respawn in seconds and the hitman standing over the
    -- body should not lose a kill they made to the respawn button.
    local victim = Identity.byCitizenId(record.victimCid)
    if victim and not Identity.isTrulyDead(victim.source) then
        local sinceDeath = (Util.monotonicMs() - (record.diedAt or record.issuedAt)) / 1000
        -- On the ground again, not on their feet: a defibrillator takes
        -- them from dead to last stand. Not a kill until they are finished,
        -- and not a revive either, so the kill is kept and the hitman told
        -- what to do. Refused as revived, the kill was thrown away with the
        -- target still lying there.
        local _, down, known = Identity.deathState(victim.source)
        if sinceDeath > (Config.Completion.ProofWindowSeconds or 0) and known and down then
            Audit.rejected('photo_target_down', actor.cid, record.contractId, {})
            return false, CH.ERR.PHOTO_STILL_DOWN
        end
        -- Up, but not yet for long enough to be a revive: the moment a
        -- defibrillator leaves before last stand reads the same way. The
        -- kill is the revive's to void, once it is one; thrown away here,
        -- on one reading, it went with the target still on the ground.
        if sinceDeath > (Config.Completion.ProofWindowSeconds or 0)
            and Death.wasSeenDead(record.victimCid) then
            Audit.rejected('photo_target_not_dead', actor.cid, record.contractId, {})
            return false, CH.ERR.PHOTO_NOT_DEAD
        end
        if sinceDeath > (Config.Completion.ProofWindowSeconds or 0) then
            Audit.rejected('photo_target_revived', actor.cid, record.contractId,
                { since = math.floor(sinceDeath) })
            Death.clearPending(record.contractId, actor.cid)
            tokens[token] = nil
            return false, CH.ERR.PHOTO_REVIVED
        end
    end

    -- The token is spent only once the slot is actually claimed. Burning it
    -- first meant a transient refusal — a lock held elsewhere, a cooldown —
    -- destroyed the proof of a kill the server itself had attributed.
    --
    -- But one claim on it at a time. The claim awaits on mysql, and the same
    -- token sent again in that gap passed every check above and claimed
    -- too: with no slot cooldown, one kill paid one collection per send.
    -- Asked before the photo is read, so a second send in that gap is not
    -- a second decode; nothing between here and the claim yields.
    if record.used then return false, CH.ERR.TOKEN_INVALID end
    if record.claiming then return false, CH.ERR.BUSY end

    -- The photo itself. On 'server' storage a refusal from here on read the
    -- picture, and says so fourth: the allowance it was sent under is kept,
    -- not given back (App's submitPhoto). Given back, one token bought as
    -- many decodes as the flood guard let through. A link costs a string
    -- match, and its refusal is given back like any other.
    local capture
    if Photo.storage() == 'host' then
        if type(rawUrl) ~= 'string' or #rawUrl > Util.MAX_URL_LENGTH or not Photo.hostAllowed(rawUrl) then
            Audit.rejected('photo_host_not_allowed', actor.cid, record.contractId,
                { host = Util.urlHost(rawUrl) })
            return false, CH.ERR.PHOTO_BAD_HOST
        end
        capture = { kind = 'url', url = rawUrl }
    else
        local image, imageErr, why, detail = Photo.readImage(rawImage)
        if not image then
            Audit.rejected(why, actor.cid, record.contractId, detail)
            return false, imageErr, nil, true
        end
        capture = image
    end

    record.claiming = true
    local ran, ok, err, result = pcall(Contracts.claimSlot,
        record.contractId, actor.cid, CH.FULFILMENT.ELIMINATION,
        { deathAt = record.diedAt })
    record.claiming = nil
    if not ran then error(ok, 0) end

    if not ok then
        Audit.rejected('photo_claim_failed', actor.cid, record.contractId, { reason = err })
        return false, err, nil, capture.kind == 'file'
    end

    record.used = true
    tokens[token] = nil

    Death.clearPending(record.contractId, actor.cid)

    -- The photo goes to the client's photo record and nowhere else: not to
    -- the hitman's ledger row, and not back to the hitman's page, which is
    -- answered with the claim's result alone.
    local contract = Storage.readContract(record.contractId)
    local handle = Ledger.record(contract, actor.cid, capture,
        CH.FULFILMENT.ELIMINATION, result)
    Notify.contractCompleted(contract, actor, { photo = handle }, result)

    return true, nil, result
end

--- Drop a hitman's token on one contract: they are no longer on it.
---
--- The spec invalidates a token on abandonment (§14 capture token rule), and
--- nothing did. It did not matter while a hitman who walked away could never
--- come back; now they can, and a token minted during the first stint would
--- otherwise still claim a payout during the second.
function Photo.forget(contractId, hitmanCid)
    for token, record in pairs(tokens) do
        if record.contractId == contractId and record.hitmanCid == hitmanCid then
            tokens[token] = nil
        end
    end
end

--- Drop tokens belonging to a player who disconnected, so the table cannot
--- grow across a long uptime.
function Photo.clearPlayer(cid)
    for token, record in pairs(tokens) do
        if record.hitmanCid == cid then tokens[token] = nil end
    end
end

function Photo.sweep()
    local cutoff = Util.monotonicMs() - (Config.Completion.PhotoTokenLifetimeSeconds * 1000)
    local removed = 0
    for token, record in pairs(tokens) do
        if record.issuedAt < cutoff then
            tokens[token] = nil
            removed = removed + 1
        end
    end
    return removed
end

function Photo.tokenCount()
    local n = 0
    for _ in pairs(tokens) do n = n + 1 end
    return n
end

return Photo
