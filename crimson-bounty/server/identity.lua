--- Identity resolution and access control.
---
--- This is the only module that may read `source`. Every other server module
--- receives an already-resolved actor table. No handler anywhere reads an
--- identity out of a client payload (§14.1) — if it is in the payload, it is
--- a claim, and claims are discarded here rather than validated.

local Util = require_shared('util')

local Identity = {}

--- Resolve the acting player from the engine-supplied event source.
---@param source number
---@return table|nil actor { source, cid, account, name, job, player }
---@return string|nil err
function Identity.resolve(source)
    local src = tonumber(source)
    if not src or src <= 0 then return nil, CB.ERR.NO_PLAYER end

    local player = exports.qbx_core:GetPlayer(src)
    if not player or not player.PlayerData then return nil, CB.ERR.NO_PLAYER end

    local data = player.PlayerData
    local cid = Util.toCitizenId(data.citizenid)
    if not cid then return nil, CB.ERR.NO_PLAYER end

    return {
        source  = src,
        cid     = cid,
        account = Identity.accountOf(src),
        name    = (data.charinfo and (data.charinfo.firstname .. ' ' .. data.charinfo.lastname)) or 'Unknown',
        job     = data.job or { name = 'unemployed', type = 'none' },
        player  = player,
    }
end

--- Account-level identifier, used for the anti-alt checks (§13.1).
--- The license is stable across a player's characters, which is exactly the
--- boundary those checks care about — citizenid is per character and would
--- miss every alt.
---@param source number
---@return string|nil
function Identity.accountOf(source)
    local identifiers = GetPlayerIdentifiers(source) or {}
    for i = 1, #identifiers do
        local id = identifiers[i]
        if type(id) == 'string' and id:sub(1, 8) == 'license:' then return id end
    end
    -- No license (rare, and only in odd deployments): fall back to the first
    -- identifier so the check still separates accounts rather than passing.
    return identifiers[1]
end

--- The connection identifier, used only to *flag* a shared household for
--- staff review. Never used to block: families and roommates share an IP.
function Identity.householdOf(source)
    local identifiers = GetPlayerIdentifiers(source) or {}
    for i = 1, #identifiers do
        local id = identifiers[i]
        if type(id) == 'string' and id:sub(1, 3) == 'ip:' then return id end
    end
    return nil
end

--- True when a job is barred from the app (§2). Checked by type first so a
--- newly added LEO job is blocked without a config edit.
---@param job table
---@return boolean
function Identity.isBlockedJob(job)
    if type(job) ~= 'table' then return false end

    local jobType = job.type and tostring(job.type):lower() or nil
    if jobType and Config.BlockedJobTypes[jobType] then
        if Config.BlockOffDuty then return true end
        return job.onduty ~= false
    end

    local name = job.name and tostring(job.name):lower() or nil
    if name and Config.BlockedJobNames[name] then
        if Config.BlockOffDuty then return true end
        return job.onduty ~= false
    end

    return false
end

--- True when a job triggers a law enforcement threat advisory (§7.5).
function Identity.isProtectedJob(job)
    if type(job) ~= 'table' or not Config.Advisory.Enabled then return false end
    local jobType = job.type and tostring(job.type):lower() or nil
    if jobType and Config.Advisory.TriggerJobTypes[jobType] then return true end
    local name = job.name and tostring(job.name):lower() or nil
    return (name and Config.Advisory.TriggerJobNames[name]) == true
end

--- True when a job should receive advisories.
function Identity.isAdvisoryRecipient(job)
    if type(job) ~= 'table' then return false end
    local jobType = job.type and tostring(job.type):lower() or nil
    if jobType and Config.Advisory.RecipientJobTypes[jobType] then return true end
    local name = job.name and tostring(job.name):lower() or nil
    return (name and Config.Advisory.RecipientJobNames[name]) == true
end

--- Resolve and gate in one call. Every net event handler starts with this.
---@param source number
---@return table|nil actor
---@return string|nil err
function Identity.gate(source)
    local actor, err = Identity.resolve(source)
    if not actor then return nil, err end
    if Identity.isBlockedJob(actor.job) then return nil, CB.ERR.BLACKLISTED_JOB end
    return actor
end

--- Look up an online player by citizen id. Returns nil when offline, which
--- callers must treat as "not available", never as "does not exist".
---
--- qbx_core's lookup export is used when present; if it is missing or its
--- signature differs on this build, the scan below still finds the player.
--- Identity resolution is load-bearing for every payout, so it does not get
--- to depend on one export existing.
---@param cid string
---@return table|nil actor
function Identity.byCitizenId(cid)
    cid = Util.toCitizenId(cid)
    if not cid then return nil end

    local ok, player = pcall(function()
        return exports.qbx_core:GetPlayerByCitizenId(cid)
    end)

    if ok and player and player.PlayerData and player.PlayerData.source then
        -- Trust but verify: the returned record must still be the citizen we
        -- asked for, and still connected.
        if player.PlayerData.citizenid == cid then
            return Identity.resolve(player.PlayerData.source)
        end
    end

    local players = GetPlayers() or {}
    for i = 1, #players do
        local candidate = exports.qbx_core:GetPlayer(tonumber(players[i]))
        if candidate and candidate.PlayerData and candidate.PlayerData.citizenid == cid then
            return Identity.resolve(candidate.PlayerData.source)
        end
    end

    return nil
end

--- Every online player, resolved. Used for advisories and presence checks.
---@return table[] actors
function Identity.online()
    local out = {}
    local players = GetPlayers() or {}
    for i = 1, #players do
        local actor = Identity.resolve(tonumber(players[i]))
        if actor then out[#out + 1] = actor end
    end
    return out
end

--- Server-side death state, read from whichever medical resource is present.
--- Never trusts a client for this (§14.2).
---@param source number
---@return boolean dead, boolean lastStand, boolean resolved
function Identity.deathState(source)
    for _, provider in ipairs(Config.Completion.DeathStateProviders) do
        if GetResourceState(provider.resource) == 'started' then
            local ok, dead = pcall(function() return exports[provider.resource][provider.dead](nil, source) end)
            local ok2, last = pcall(function() return exports[provider.resource][provider.lastStand](nil, source) end)
            if ok and ok2 then
                return dead == true, last == true, true
            end
        end
    end

    -- Fall back to QBox metadata, which the medical resources write anyway.
    local player = exports.qbx_core:GetPlayer(source)
    local meta = player and player.PlayerData and player.PlayerData.metadata
    if meta then
        return meta.isdead == true, meta.inlaststand == true, true
    end

    return false, false, false
end

--- True when the player is genuinely dead — not downed, not bleeding out.
--- An elimination pays only on this (§7.4).
function Identity.isTrulyDead(source)
    local dead, lastStand, resolved = Identity.deathState(source)
    if not resolved then return false end
    if Config.Completion.RejectLastStand and lastStand then return false end
    return dead
end

--- True when the player is alive and conscious — the state a kidnapping
--- delivery requires for its whole countdown (§7.4).
function Identity.isAliveAndConscious(source)
    local dead, lastStand, resolved = Identity.deathState(source)
    if not resolved then return false end
    if Config.Kidnap.RejectDead and dead then return false end
    if Config.Kidnap.RejectLastStand and lastStand then return false end

    local health = GetEntityHealth(GetPlayerPed(source)) or 0
    local percent = ((health - 100) / 100) * 100
    if percent < (Config.Kidnap.MinTargetHealthPercent or 0) then return false end

    return true
end

return Identity
