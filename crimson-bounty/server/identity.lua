--- Identity resolution and access control.
---
--- This is the only module that may read `source`. Every other server module
--- receives an already-resolved actor table. No handler anywhere reads an
--- identity out of a client payload (§14.1) — if it is in the payload, it is
--- a claim, and claims are discarded here rather than validated.

local Util = require_shared('util')

local Identity = {}

--- When each connected player's session began, stamped by this resource.
--- Session length is measurable without any framework support, so it is
--- never the thing that blocks a contract.
local sessionStart = {}

--- Record a player's arrival. Called from the connection bridge.
---
--- `observed` marks a session we merely noticed rather than watched begin —
--- a player who was already connected when the resource started. Their real
--- session length is unknown, so the new-player rule must not treat them as
--- having just walked in.
function Identity.beginSession(cid, observed)
    if not cid or sessionStart[cid] then return false end
    sessionStart[cid] = { at = os.time(), observed = observed == true }
    return true
end

function Identity.endSession(cid)
    sessionStart[cid] = nil
end

--- Minutes this player has been connected, or nil if we never saw them
--- arrive (a resource restart mid-session, for instance).
function Identity.sessionMinutes(cid)
    local began = sessionStart[cid]
    -- Nil for a session we did not watch start: unknown, not zero. Treating
    -- a restart as everyone having just arrived would make the whole server
    -- untargetable for ten minutes.
    if not began or began.observed then return nil end
    return math.floor((os.time() - began.at) / 60)
end

--- Total playtime in hours, from whichever provider the server configures.
--- Returns nil when nothing can answer, which callers must treat as
--- "unknown" rather than "zero".
function Identity.playtimeHours(actor)
    local provider = Config.Immunity.PlaytimeProvider
    if provider and provider.resource and GetResourceState(provider.resource) == 'started' then
        local ok, minutes = pcall(function()
            return exports[provider.resource][provider.export](nil, actor.cid)
        end)
        if ok and type(minutes) == 'number' then return minutes / 60 end
    end

    -- QBox keeps playtime in character metadata on most builds.
    local meta = actor.player and actor.player.PlayerData and actor.player.PlayerData.metadata
    if meta and type(meta.playtime) == 'number' then return meta.playtime / 60 end

    return nil
end

--- A player's name, fit to store and to show.
---
--- Read straight out of the framework's own character record, which on most
--- servers is whatever the player typed at creation — so it is no more
--- trustworthy than a contract reason, and it goes to the same places: a
--- VARCHAR(64) column and every client's screen.
---
--- Missing pieces are not fatal. resolve runs on nearly every handler, so a
--- nil firstname concatenated here used to throw out of all of them, and one
--- malformed row in the framework's table locked that player out of the
--- whole resource.
---@param data table PlayerData
---@return string
local function nameOf(data)
    local info = data and data.charinfo
    local first = info and type(info.firstname) == 'string' and info.firstname or nil
    local last = info and type(info.lastname) == 'string' and info.lastname or nil

    local whole
    if first and last then whole = first .. ' ' .. last
    else whole = first or last end

    -- 64 to match the column. sanitizeText also drops control characters and
    -- anything a utf8mb4 column would refuse, including the half of a
    -- character its own cap would otherwise leave behind.
    return Util.sanitizeText(whole, 64) or 'Unknown'
end

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

    -- Note anyone we have not seen before, so their state is tracked even
    -- if this resource started after they connected.
    Identity.beginSession(cid, true)

    return {
        source  = src,
        cid     = cid,
        account = Identity.accountOf(src),
        name    = nameOf(data),
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

--- Whether two players are the same account.
---
--- Only when both accounts are known and equal. An account this server
--- could not read is nil, and `nil == nil` is true — which made every
--- player look like another character of whoever was asking. The target
--- list came back empty, with the whole city filtered out as one person's
--- alts, and no contract could be accepted because every hunter read as
--- their own creator.
---
--- Two unknowns are not the same person. They are two unknowns, and the
--- citizen id is what separates them.
---@param a string|nil
---@param b string|nil
---@return boolean
function Identity.sameAccount(a, b)
    if a == nil or b == nil then return false end
    return a == b
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
--- Everyone connected that this resource can describe.
---
--- Guarded per player, not per call. resolve reads the framework's own
--- character record, and on a live server somebody is always mid-join — a
--- source that is connected but whose record is not there yet, or an export
--- that raises for it. One of those used to throw out of here and take the
--- whole roster with it: the browse handler caught it, replied with an
--- error, and the target list came back empty for everybody because one
--- person was still loading.
---
--- A player who cannot be described is left out. Everyone else is still
--- there.
function Identity.online()
    local out = {}
    local players = GetPlayers() or {}
    for i = 1, #players do
        local ok, actor = pcall(Identity.resolve, tonumber(players[i]))
        if ok and actor then out[#out + 1] = actor end
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

    -- GTA health runs 100..200, where 100 is dead — so the percentage is
    -- the health above 100, directly. Computing it as ((health - 100) / 100)
    -- * 100 went through a binary fraction on the way and came back as
    -- 28.999999999999996 for a health of 129: a target sitting exactly on a
    -- floor of 29% was refused, and no amount of healing to that number
    -- would ever have let the delivery start.
    local health = GetEntityHealth(GetPlayerPed(source)) or 0
    local percent = health - 100
    if percent < (Config.Kidnap.MinTargetHealthPercent or 0) then return false end

    return true
end

return Identity
