--- Identity resolution and access control.
---
--- This is the only module that may read `source`. Every other server module
--- receives an already-resolved actor table. No handler anywhere reads an
--- identity out of a client payload (§14.1) — if it is in the payload, it is
--- a claim, and claims are discarded here rather than validated.

local Util = CrimsonBoot.requireShared('util')

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

--- How recently resolve() must have noticed somebody for a login event to
--- count as the start of that same session.
local FRESH_LOGIN_SECONDS = 60

--- Confirm a login, without ever moving a session's clock back to now.
---
--- Called from the login bridges. The bridge used to end the session and
--- begin a new one, which restarted the new-player clock every time a login
--- event arrived — and one of those events, QBCore:Server:OnPlayerLoaded, is
--- a net event any client can fire. A target who fired it every nine minutes
--- stayed "just arrived" for as long as they liked, and because immunity is
--- re-checked on every payout, no kill or handover on them ever paid.
---
--- A real login follows a disconnect or a character unload, and both of
--- those end the session. So a real login finds either no record at all, or
--- the observed one resolve() noted moments before the event arrived — and
--- that one is taken as watched, from the moment it was noted. A record
--- that is already watched, or observed long ago, belongs to somebody who
--- has been in the city all along, and a login event does not change that.
---@param cid string
---@return boolean changed
---
--- `untrusted` for the net event. It may still note somebody the resource
--- has never seen, but only as observed — length unknown, no floor — and it
--- never turns an observed session into a watched one. That upgrade, from a
--- client, was one more way to be "just arrived": fired within a minute of
--- the resource first noticing them after a restart, it bought ten minutes
--- of immunity. The server's own loaded event still makes the upgrade, so a
--- real arrival is protected either way round the two events land.
---@param cid string
---@param untrusted boolean|nil
function Identity.confirmSession(cid, untrusted)
    if not cid then return false end
    local began = sessionStart[cid]
    if not began then
        sessionStart[cid] = { at = os.time(), observed = untrusted == true }
        return not untrusted
    end
    if untrusted then return false end
    if began.observed and (os.time() - began.at) <= FRESH_LOGIN_SECONDS then
        began.observed = false
        return true
    end
    return false
end

--- Backdate every watched session, for the staff timer refresh.
---
--- A character who has just walked in cannot be named as a target for ten
--- minutes, which on a test server is the wait before anything can be
--- tested at all. `observed` is left as it is: it records that we did not
--- watch this session begin, and that is a fact about the session, not a
--- clock.
---@return integer aged
function Identity.ageSessions()
    local window = (Config.Immunity.MinTargetSessionMinutes or 0) * 60
    local aged = 0
    for _, began in pairs(sessionStart) do
        began.at = os.time() - (window + 60)
        aged = aged + 1
    end
    return aged
end

--- Minutes this player has been connected, or nil if we never saw them
--- arrive (a resource restart mid-session, for instance).
--- Seconds since a watched session began, for comparing against the time
--- of a death: minutes floored to a whole number cannot say which came
--- first. Nil exactly when sessionMinutes is.
---@param cid string
---@return number|nil
function Identity.sessionSeconds(cid)
    local began = sessionStart[cid]
    if not began or began.observed then return nil end
    return os.time() - began.at
end

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

--- The actor for a player record qbx_core has already handed back.
---@param src number
---@param player table|nil
---@return table|nil actor
---@return string|nil err
local function actorOf(src, player)
    if not player or not player.PlayerData then return nil, CH.ERR.NO_PLAYER end

    local data = player.PlayerData
    local cid = Util.toCitizenId(data.citizenid)
    if not cid then return nil, CH.ERR.NO_PLAYER end

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

--- Resolve the acting player from the engine-supplied event source.
---@param source number
---@return table|nil actor { source, cid, account, name, job, player }
---@return string|nil err
function Identity.resolve(source)
    local src = tonumber(source)
    if not src or src <= 0 then return nil, CH.ERR.NO_PLAYER end
    return actorOf(src, exports.qbx_core:GetPlayer(src))
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
--- alts, and no contract could be accepted because every hitman read as
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
    -- Not gated on the advisory being switched on. Whether officers are
    -- told is one setting; whether an officer is who they are is not a
    -- setting at all. Gated, turning the bulletins off also turned off
    -- Targeting.AllowProtectedJobTargets = false and every warning and
    -- listing flag, and put officers back on the board without a word.
    if type(job) ~= 'table' then return false end
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

--- Job definitions by name, as qbx_core holds them. A job a player holds
--- but is not working is only a name and a grade in their player data; its
--- type is in the framework's job list. Job definitions change when an
--- owner edits them, which is rare, so a read is kept for a few minutes
--- rather than asked for on every request.
local JOB_CACHE_SECONDS = 300
local jobDefinitions = {}

local function jobDefinition(name)
    local now = os.time()
    local cached = jobDefinitions[name]
    if cached and now - cached.at < JOB_CACHE_SECONDS then return cached.job end
    local ok, job = pcall(function() return exports.qbx_core:GetJob(name) end)
    job = ok and type(job) == 'table' and job or nil
    jobDefinitions[name] = { at = now, job = job }
    return job
end

--- Every job a player holds besides the one they are working, as job tables
--- the checks here can read, each off duty.
---
--- qbx_core keeps a player's jobs as { [name] = grade }, and sc-multijob and
--- its kind let them pick which one is primary. Only the primary was read,
--- so an officer with a second job switched to it and was a civilian: into
--- the app, and on the board as a target.
---@param actor table
---@return table[]
function Identity.heldJobs(actor)
    local data = actor and actor.player and actor.player.PlayerData
    local jobs = data and data.jobs
    local out = {}
    if type(jobs) ~= 'table' then return out end
    local primary = actor.job and actor.job.name
    for name in pairs(jobs) do
        if type(name) == 'string' and name ~= primary then
            local definition = jobDefinition(name)
            out[#out + 1] = {
                name = name,
                type = definition and definition.type or nil,
                onduty = false,
            }
        end
    end
    return out
end

--- Whether a player is barred from the app: by the job they are working,
--- or by any other job they hold. Switching primary job is clocking off by
--- another route, so a held job is read as off duty, and it bars them
--- exactly when BlockOffDuty would.
---@param actor table
---@return boolean
function Identity.isBarred(actor)
    return Identity.barredBy(actor) ~= nil
end

--- What bars a player, if anything: the job's name, and whether it is one
--- they hold rather than the one they are working. A held job can be put
--- on a player by somebody else (a department's boss hiring them through
--- the MDT), so they are told which one and that quitting it gives the app
--- back.
---@param actor table
---@return string|nil jobName
---@return boolean held
function Identity.barredBy(actor)
    if not actor then return nil, false end
    if Identity.isBlockedJob(actor.job) then
        return tostring(actor.job.label or actor.job.name or 'job'), false
    end
    local held = Identity.heldJobs(actor)
    for i = 1, #held do
        if Identity.isBlockedJob(held[i]) then return held[i].name, true end
    end
    return nil, false
end

--- Whether a player is law enforcement, by any job they hold. Being an
--- officer is not a matter of which job is primary today, any more than of
--- being on duty (isProtectedJob does not read duty either).
---@param actor table
---@return boolean
function Identity.isProtected(actor)
    return Identity.protectedBy(actor) ~= nil
end

--- The job that makes a player law enforcement, or nil: the one they are
--- working if it does, otherwise the first held job that does.
---@param actor table
---@return table|nil job
function Identity.protectedBy(actor)
    if not actor then return nil end
    if Identity.isProtectedJob(actor.job) then return actor.job end
    local held = Identity.heldJobs(actor)
    for i = 1, #held do
        if Identity.isProtectedJob(held[i]) then return held[i] end
    end
    return nil
end

--- Job types and names that are not law enforcement, by what they are.
local EMERGENCY_JOBS = { ems = true, fire = true, ambulance = true, firefighter = true, medical = true }
local LEGAL_JOBS = { doj = true, lawyer = true, judge = true, attorney = true, legal = true }

--- What kind of protected job this is, for the words the page and the
--- target's own notice use: 'law' (a job the advisory goes to), 'emergency'
--- (EMS and fire), 'legal' (the DOJ and lawyers), or 'other' for a job
--- added to the trigger lists that is none of these. A medic was called a
--- sworn officer and told their department had been advised, when only law
--- enforcement is told. The kind of job only, never which force.
---@param job table|string|nil a job table, or the job name a contract keeps (target_job)
---@return string
function Identity.protectedCategory(job)
    if type(job) == 'string' then
        local definition = jobDefinition(job)
        job = { name = job, type = definition and definition.type or nil }
    end
    if type(job) ~= 'table' then return 'other' end
    if Identity.isAdvisoryRecipient(job) then return 'law' end
    local jobType = job.type and tostring(job.type):lower() or ''
    local name = job.name and tostring(job.name):lower() or ''
    if EMERGENCY_JOBS[jobType] or EMERGENCY_JOBS[name] then return 'emergency' end
    if LEGAL_JOBS[jobType] or LEGAL_JOBS[name] then return 'legal' end
    return 'other'
end

--- Whether a player's record holds a sentence ('injail' metadata above 0),
--- wherever they are standing. Not whether they are in prison: that is
--- Identity.isJailed, which also needs them inside the prison grounds.
---@param actor table
---@return boolean
function Identity.serving(actor)
    local data = actor and actor.player and actor.player.PlayerData
    local meta = data and data.metadata
    local left = type(meta) == 'table' and tonumber(meta.injail) or nil
    return left ~= nil and left > 0
end

--- Whether a player is in prison: serving a sentence, and inside the prison.
---
--- sc-police and the QBox prison scripts keep the time left in the 'injail'
--- metadata, and sc-police lets a client write it for themselves with a net
--- event. Read alone, a target could declare a sentence and stop the
--- hitman's clock while walking around the city. So the sentence counts only
--- where the server can see them inside the prison grounds
--- (Config.Limits.JailZone); with no zone configured, it never counts.
---@param actor table
---@return boolean
function Identity.isJailed(actor)
    if not Identity.serving(actor) then return false end

    local zone = Config.Limits.JailZone
    if type(zone) ~= 'table' or not tonumber(zone.x) or not tonumber(zone.y)
        or not tonumber(zone.radius) then
        return false
    end
    local ok, coords = pcall(function() return GetEntityCoords(GetPlayerPed(actor.source)) end)
    if not ok or not coords then return false end
    local dx, dy = coords.x - zone.x, coords.y - zone.y
    return dx * dx + dy * dy <= zone.radius * zone.radius
end

--- Resolve and gate in one call. Every net event handler starts with this.
---@param source number
---@return table|nil actor
---@return string|nil err
function Identity.gate(source)
    local actor, err = Identity.resolve(source)
    if not actor then return nil, err end
    if Identity.isBarred(actor) then return nil, CH.ERR.BLACKLISTED_JOB end
    return actor
end

--- Whether the whitelisted-job view is on (Config.WhitelistedView.Enabled):
--- a player the app bars (isBarred) installs and opens it, and sees one
--- read-only screen instead of an app that answers nothing. Read at every
--- use, so the admin panel's switch applies to the next request.
---@return boolean
function Identity.whitelistedViewOn()
    local view = Config.WhitelistedView
    return type(view) == 'table' and view.Enabled == true
end

--- The gate for the two requests the whitelisted-job view makes.
---
--- 'view', its one read: only a player the app bars, and only while the
--- view is on. With it off they are refused as the app has always refused
--- them (BLACKLISTED_JOB). A player the app is open to is refused with
--- NOT_WHITELISTED: the whole app is theirs, and the page goes back to it.
---
--- 'target', the buyout: as Identity.gate, and a player the app bars as
--- well while the view is on. Bailout.buy acts only on a contract naming the
--- caller, so this opens the one move a target has and nothing else.
---
--- 'report', the page's own fault report and the log the diagnosis asks it
--- for (pageError): the same people as 'target'. It changes nothing and
--- answers nothing about anybody; what it carries is cleaned and its
--- allowance is its own.
---@param source number
---@param access string 'view' | 'target' | 'report'
---@return table|nil actor
---@return string|nil err
function Identity.gateFor(source, access)
    local actor, err = Identity.resolve(source)
    if not actor then return nil, err end
    local barred = Identity.isBarred(actor)
    if access == 'view' then
        if not barred then return nil, CH.ERR.NOT_WHITELISTED end
        if not Identity.whitelistedViewOn() then return nil, CH.ERR.BLACKLISTED_JOB end
        return actor
    end
    if barred and not ((access == 'target' or access == 'report')
        and Identity.whitelistedViewOn()) then
        return nil, CH.ERR.BLACKLISTED_JOB
    end
    return actor
end

--- The job a target is shown under in the whitelisted-job view, by its
--- label where qbx_core gives one.
---@param job table
---@return string
local function shownJob(job)
    if type(job.label) == 'string' and job.label ~= '' then return job.label end
    local definition = type(job.name) == 'string' and jobDefinition(job.name) or nil
    if definition and type(definition.label) == 'string' and definition.label ~= '' then
        return definition.label
    end
    return tostring(job.name or 'job')
end

--- Whether a contract's target is listed in the whitelisted-job view as a
--- member of a whitelisted job, and the job they are shown under: by what
--- the contract recorded when it was placed, the flag the listing and the
--- advisory read (target_protected) and the job the advisory names
--- (target_job). Never by a lookup of the player now. Their job now when
--- they are in the city and the record when they are not made an entry
--- that came and went as they logged in and out, wherever the two differed.
---@param contract table
---@return boolean member
---@return string|nil job the job they are shown under, when they are one
function Identity.whitelistedTarget(contract)
    if type(contract) ~= 'table' or contract.target_protected ~= true then return false end
    local name = contract.target_job
    if type(name) ~= 'string' or name == '' then return true, nil end
    return true, shownJob({ name = name })
end

--- Whether qbx_core's lookup export has handed back a verified player at
--- least once since this resource started.
---
--- Until it has, its nil may be a build whose export does not answer this
--- way, and the scan below is asked. Once it has, its nil is the answer:
--- GetPlayerByCitizenId reads the same online-player table the scan walks
--- (qbx_core server/functions.lua), so the scan can only agree with it.
local lookupProven = false

--- Look up an online player by citizen id. Returns nil when offline, which
--- callers must treat as "not available", never as "does not exist".
---
--- qbx_core's lookup export is used when present; if it is missing or its
--- signature differs on this build, the scan below still finds the player.
--- Identity resolution is load-bearing for every payout, so it does not get
--- to depend on one export existing.
---
--- The scan is not run for somebody the export has said is offline. It asks
--- qbx_core for every connected player, one export each, and each one
--- carries that player's whole record across: for a contract on a target
--- who has logged off, which is a contract's ordinary state for up to two
--- days, the sampler paid that once a second, and the expiry pass and every
--- board open paid it again, for every such contract. On a full server that
--- was thousands of exports a second and a hitch on every one of them.
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
        -- asked for, and still connected. Built from the record in hand:
        -- resolving the source again asked qbx_core for the same player a
        -- second time.
        local src = tonumber(player.PlayerData.source)
        if player.PlayerData.citizenid == cid and src and src > 0 then
            lookupProven = true
            return actorOf(src, player)
        end
    end

    -- Offline, by the export's own word. A missing or throwing export
    -- (not ok), or one never yet seen to work, still falls to the scan.
    if ok and player == nil and lookupProven then return nil end

    local players = GetPlayers() or {}
    for i = 1, #players do
        local candidate = exports.qbx_core:GetPlayer(tonumber(players[i]))
        if candidate and candidate.PlayerData and candidate.PlayerData.citizenid == cid then
            return Identity.resolve(candidate.PlayerData.source)
        end
    end

    return nil
end

--- What qbx_core's offline lookup said of a citizen id, kept a while:
--- [cid] = { exists = boolean, at = Util.monotonicMs() }. The staff tools ask
--- it of every line owed to somebody away while the admin panel's overview
--- is open, and each answer is a read of qbx_core's players table.
local characterSeen = {}
local CHARACTER_KNOWN_MS = 600000   -- a character found: ten minutes
local CHARACTER_NONE_MS = 60000     -- none found: a minute

--- Whether a character with exactly this citizen id exists on the server,
--- in the city or away, by qbx_core's own record: its GetOfflinePlayer
--- export (qbx_core server/player.lua), which reads the players table and
--- answers nil for an id no character has. Exact: the table's collation
--- matches 'creator1' to CREATOR1's row, and the citizen id that row holds
--- is what is compared. nil when qbx_core could not be asked (an export
--- missing on this build, or one that raised), which is never "nobody".
---@param cid string
---@return boolean|nil exists
function Identity.characterExists(cid)
    cid = Util.toCitizenId(cid)
    if not cid then return false end
    local now = Util.monotonicMs()
    local seen = characterSeen[cid]
    if seen and now - seen.at < (seen.exists and CHARACTER_KNOWN_MS or CHARACTER_NONE_MS) then
        return seen.exists
    end
    local ok, player = pcall(function()
        return exports.qbx_core:GetOfflinePlayer(cid)
    end)
    if not ok then return nil end
    local data = type(player) == 'table' and player.PlayerData or nil
    local exists = type(data) == 'table' and data.citizenid == cid
    characterSeen[cid] = { exists = exists, at = now }
    return exists
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

--- Medical resources found running without the death-state exports this
--- server asks them for, until they next start: [resource] = true.
---
--- qbx_medical is one. Its IsDead and IsLaststand are client exports
--- (qbx_medical client/main.lua); its server exports nothing of the kind
--- (server/main.lua: ResetHungerAndThirst, Revive, Heal, HealPartially,
--- GetPlayerStatus), and writes the isdead and inlaststand metadata the
--- fallback below reads instead. It stays in the providers list because the
--- client reads that list to know a medical resource decides when its player
--- is dead. Asked anyway, every read of a target's state, several a second
--- per target from the sampler alone, went through FiveM's lookup for an
--- export that is not there, and failed: the scheduler leaves a callback
--- behind for good on every such miss, so it also leaked.
local noExport = {}

--- FiveM's own words for an export a resource does not have (scheduler.lua).
local function missingExport(err)
    return tostring(err):find('No such export', 1, true) ~= nil
end

--- A medical resource has started again, perhaps a version that does have
--- the exports: ask it again. Wired from the bridges' onResourceStart.
---@param resource string
function Identity.forgetProvider(resource)
    if resource then noExport[resource] = nil end
end

--- Server-side death state, read from whichever medical resource is present.
--- Never trusts a client for this (§14.2).
---
--- The fourth value names what answered: a provider's resource, or
--- 'metadata' for qbx_core's record. /ch-diag prints it.
---@param source number
---@return boolean dead, boolean lastStand, boolean resolved, string|nil answeredBy
function Identity.deathState(source)
    for _, provider in ipairs(Config.Completion.DeathStateProviders or {}) do
        local resource = provider.resource
        if resource and not noExport[resource] and GetResourceState(resource) == 'started' then
            local ok, dead = pcall(function() return exports[resource][provider.dead](nil, source) end)
            local ok2, last = pcall(function() return exports[resource][provider.lastStand](nil, source) end)
            if ok and ok2 then
                return dead == true, last == true, true, resource
            end
            if (not ok and missingExport(dead)) or (not ok2 and missingExport(last)) then
                noExport[resource] = true
            end
        end
    end

    -- Fall back to QBox metadata, which the medical resources write anyway.
    --
    -- The two flags, asked for by name (qbx_core server/player.lua,
    -- GetMetadata): the same table GetPlayer hands over, without carrying
    -- the whole player record across the export boundary for two booleans,
    -- which the death sampler did once a second for every live target.
    -- qbx_core gives every character both flags when it loads them
    -- (CheckPlayerData sets each to false), so neither answering is nobody
    -- loaded at that source, or a record without them: asked whole then, as
    -- before. A qbx_core without the export is asked whole from then on.
    if not noExport.qbx_core then
        local okDead, isDead = pcall(function()
            return exports.qbx_core:GetMetadata(source, 'isdead')
        end)
        local okLast, isLast = pcall(function()
            return exports.qbx_core:GetMetadata(source, 'inlaststand')
        end)
        if okDead and okLast and (isDead ~= nil or isLast ~= nil) then
            return isDead == true, isLast == true, true, 'metadata'
        end
        if (not okDead and missingExport(isDead)) or (not okLast and missingExport(isLast)) then
            noExport.qbx_core = true
        end
    end

    local player = exports.qbx_core:GetPlayer(source)
    local meta = player and player.PlayerData and player.PlayerData.metadata
    if meta then
        return meta.isdead == true, meta.inlaststand == true, true, 'metadata'
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
---
--- False with 'target_too_hurt' when only the health floor refuses them. A
--- target sitting up and talking under it is neither dead nor down, and was
--- refused as "not conscious", or failed mid-countdown as "went down", in
--- front of a hitman who could see otherwise. Qbox gives no health back on
--- its own, and bleeding takes more, so it is the ordinary case after a
--- rough abduction.
---
--- strict refuses the dead whatever Config.Kidnap.RejectDead says: a
--- contract placed under 'alive' (Kidnap.conditionsMet), where a body
--- handed over would be paid as a live delivery.
---@param source number
---@param strict boolean|nil
---@return boolean ok
---@return string|nil why 'target_too_hurt' for the health floor alone
function Identity.isAliveAndConscious(source, strict)
    local dead, lastStand, resolved = Identity.deathState(source)
    if not resolved then return false end
    if (strict or Config.Kidnap.RejectDead) and dead then return false end
    if Config.Kidnap.RejectLastStand and lastStand then return false end

    -- GTA health runs 100..200, where 100 is dead — so the percentage is
    -- the health above 100, directly. Computing it as ((health - 100) / 100)
    -- * 100 went through a binary fraction on the way and came back as
    -- 28.999999999999996 for a health of 129: a target sitting exactly on a
    -- floor of 29% was refused, and no amount of healing to that number
    -- would ever have let the delivery start.
    local health = GetEntityHealth(GetPlayerPed(source)) or 0
    local percent = health - 100
    if percent < (Config.Kidnap.MinTargetHealthPercent or 0) then return false, 'target_too_hurt' end

    return true
end

return Identity
