--- Verification photo (§7.4, §14.20, §14.35).
---
--- The photo authenticates a claim that the server already believes: a
--- pending completion must exist before a token is issued, and the token is
--- what binds the eventual image to that specific contract, hunter and death
--- scene. An image URL on its own proves nothing and is never enough.

local Util = require_shared('util')

local Photo = {}

local Storage, Identity, Contracts, Audit, Death, Notify, Ledger

--- [token] = { contractId, hunterCid, victimCid, coords, issuedAt, used }
local tokens = {}
--- Hosts a photo may legitimately come from, learned from lb-phone's own
--- upload configuration at boot plus anything the owner adds.
local allowedHosts = {}

function Photo.init(deps)
    Storage, Identity, Contracts, Audit, Death, Notify, Ledger =
        deps.storage, deps.identity, deps.contracts, deps.audit,
        deps.death, deps.notify, deps.ledger
    tokens = {}
    Photo.loadAllowedHosts()
end

--- Read the upload host from lb-phone's config so the allowlist matches
--- wherever the phone actually uploads to on this server.
function Photo.loadAllowedHosts()
    allowedHosts = {}

    for _, host in ipairs(Config.Completion.ExtraPhotoHosts or {}) do
        allowedHosts[tostring(host):lower()] = true
    end

    local ok, phoneConfig = pcall(function()
        return exports['lb-phone']:GetConfig()
    end)
    if ok and type(phoneConfig) == 'table' then
        local upload = phoneConfig.Upload or phoneConfig.upload
        if type(upload) == 'table' then
            for _, value in pairs(upload) do
                if type(value) == 'string' then
                    local host = Util.urlHost(value)
                    if host then allowedHosts[host] = true end
                elseif type(value) == 'table' then
                    for _, inner in pairs(value) do
                        local host = type(inner) == 'string' and Util.urlHost(inner) or nil
                        if host then allowedHosts[host] = true end
                    end
                end
            end
        end
    end

    return allowedHosts
end

function Photo.hostAllowed(url)
    local host = Util.urlHost(url)
    if not host then return false end
    if allowedHosts[host] then return true end
    -- A subdomain of an allowed host is allowed; an unrelated host is not.
    for allowed in pairs(allowedHosts) do
        if #host > #allowed and host:sub(-(#allowed + 1)) == '.' .. allowed then return true end
    end
    return false
end

function Photo.allowedHosts() return allowedHosts end

--------------------------------------------------------------------------
-- Tokens
--------------------------------------------------------------------------

local counter = 0

--- Issue a capture token for a pending completion. One live token per
--- hunter-contract pair: requesting another invalidates the first, so a
--- hunter cannot bank tokens for later.
---@return string|nil token
---@return string|nil err
function Photo.issue(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CB.ERR.INVALID_INPUT end

    local record = Death.getPending(contractId, actor.cid)
    if not record then return nil, CB.ERR.BAD_STATE end

    for token, existing in pairs(tokens) do
        if existing.contractId == contractId and existing.hunterCid == actor.cid then
            tokens[token] = nil
        end
    end

    counter = counter + 1
    local token = ('tk%s%08d'):format(contractId:gsub('[^%w]', ''), counter)

    tokens[token] = {
        contractId = contractId,
        hunterCid  = actor.cid,
        victimCid  = record.victimCid,
        coords     = record.coords,
        diedAt     = record.at,
        issuedAt   = GetGameTimer(),
        used       = false,
    }

    Audit.action('photo_token_issued', actor.cid, contractId, {})
    return token
end

--------------------------------------------------------------------------
-- Submission
--------------------------------------------------------------------------

--- Verify a submitted photo and, if everything holds, claim a payout slot.
---
--- Four factors are checked together, and all of them are server-side facts:
---   * the token exists, is unused, unexpired, and was issued to this hunter
---   * the image URL came from the host lb-phone uploads to
---   * the hunter is standing at the death scene
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
        return false, CB.ERR.TOKEN_INVALID
    end

    local record = tokens[token]
    if not record or record.used then
        Audit.rejected('photo_token_unknown_or_used', actor.cid, nil, {})
        return false, CB.ERR.TOKEN_INVALID
    end

    -- The token belongs to whoever it was issued to, and to nobody else.
    if record.hunterCid ~= actor.cid then
        Audit.rejected('photo_token_foreign', actor.cid, record.contractId, {})
        return false, CB.ERR.TOKEN_INVALID
    end

    if GetGameTimer() - record.issuedAt > (Config.Completion.PhotoTokenLifetimeSeconds * 1000) then
        tokens[token] = nil
        return false, CB.ERR.TOKEN_INVALID
    end

    if type(rawUrl) ~= 'string' or #rawUrl > Util.MAX_URL_LENGTH or not Photo.hostAllowed(rawUrl) then
        Audit.rejected('photo_host_not_allowed', actor.cid, record.contractId,
            { host = Util.urlHost(rawUrl) })
        return false, CB.ERR.PHOTO_REJECTED
    end

    -- The hunter must be at the scene. Position is read server-side; a
    -- client claiming to be somewhere is not consulted.
    local hunterCoords = GetEntityCoords(GetPlayerPed(actor.source))
    local radius = Config.Completion.PhotoRadius
    if Util.dist2(hunterCoords, record.coords) > (radius * radius) then
        Audit.rejected('photo_out_of_range', actor.cid, record.contractId, {})
        return false, CB.ERR.PHOTO_REJECTED
    end

    -- Still dead? A target revived between the kill and the photo was not
    -- eliminated (§7.4) — but a short proof window follows the death itself,
    -- because players respawn in seconds and the hunter standing over the
    -- body should not lose a kill they made to the respawn button.
    local victim = Identity.byCitizenId(record.victimCid)
    if victim and not Identity.isTrulyDead(victim.source) then
        local sinceDeath = (GetGameTimer() - (record.diedAt or record.issuedAt)) / 1000
        if sinceDeath > (Config.Completion.ProofWindowSeconds or 0) then
            Audit.rejected('photo_target_revived', actor.cid, record.contractId,
                { since = math.floor(sinceDeath) })
            Death.clearPending(record.contractId, actor.cid)
            tokens[token] = nil
            return false, CB.ERR.PHOTO_REJECTED
        end
    end

    -- The token is spent only once the slot is actually claimed. Burning it
    -- first meant a transient refusal — a lock held elsewhere, a cooldown —
    -- destroyed the proof of a kill the server itself had attributed.
    local ok, err, result = Contracts.claimSlot(
        record.contractId, actor.cid, CB.FULFILMENT.ELIMINATION,
        { deathAt = record.diedAt })

    if not ok then
        Audit.rejected('photo_claim_failed', actor.cid, record.contractId, { reason = err })
        return false, err
    end

    record.used = true
    tokens[token] = nil

    Death.clearPending(record.contractId, actor.cid)

    local contract = Storage.readContract(record.contractId)
    Ledger.record(contract, actor.cid, rawUrl, CB.FULFILMENT.ELIMINATION, result)
    Notify.contractCompleted(contract, actor, rawUrl)

    return true, nil, result
end

--- Drop tokens belonging to a player who disconnected, so the table cannot
--- grow across a long uptime.
function Photo.clearPlayer(cid)
    for token, record in pairs(tokens) do
        if record.hunterCid == cid then tokens[token] = nil end
    end
end

function Photo.sweep()
    local cutoff = GetGameTimer() - (Config.Completion.PhotoTokenLifetimeSeconds * 1000)
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
