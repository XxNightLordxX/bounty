--- Verification photo (§7.4, §14.20, §14.35).
---
--- The photo authenticates a claim that the server already believes: a
--- pending completion must exist before a token is issued, and the token is
--- what binds the eventual image to that specific contract, hitman and death
--- scene. An image URL on its own proves nothing and is never enough.

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
    if next(now) == nil then
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

    -- Its own code. This is the ordinary outcome of tapping Verify kill at
    -- any moment other than standing over a body the server saw this hitman
    -- put there, and it needs to say so.
    local record = Death.getPending(contractId, actor.cid)
    if not record then
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
--- Four factors are checked together, and all of them are server-side facts:
---   * the token exists, is unused, unexpired, and was issued to this hitman
---   * the image URL came from the host lb-phone uploads to
---   * the hitman is standing at the death scene
---   * the target is still dead — a revive invalidates the claim
---
---@param actor table resolved from the event source
---@param rawToken any
---@param rawUrl any
---@return boolean ok
---@return string|nil err
---@return table|nil result
function Photo.submit(actor, rawToken, rawUrl)
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

    if type(rawUrl) ~= 'string' or #rawUrl > Util.MAX_URL_LENGTH or not Photo.hostAllowed(rawUrl) then
        Audit.rejected('photo_host_not_allowed', actor.cid, record.contractId,
            { host = Util.urlHost(rawUrl) })
        return false, CH.ERR.PHOTO_BAD_HOST
    end

    -- The hitman must be at the scene. Position is read server-side; a
    -- client claiming to be somewhere is not consulted.
    local hitmanCoords = GetEntityCoords(GetPlayerPed(actor.source))
    local radius = Config.Completion.PhotoRadius
    if Util.dist2(hitmanCoords, record.coords) > (radius * radius) then
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
    local ok, err, result = Contracts.claimSlot(
        record.contractId, actor.cid, CH.FULFILMENT.ELIMINATION,
        { deathAt = record.diedAt })

    if not ok then
        Audit.rejected('photo_claim_failed', actor.cid, record.contractId, { reason = err })
        return false, err
    end

    record.used = true
    tokens[token] = nil

    Death.clearPending(record.contractId, actor.cid)

    local contract = Storage.readContract(record.contractId)
    Ledger.record(contract, actor.cid, rawUrl, CH.FULFILMENT.ELIMINATION, result)
    Notify.contractCompleted(contract, actor, rawUrl)

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
