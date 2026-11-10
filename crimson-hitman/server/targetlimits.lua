--- Target limits: how often one person may have a contract placed on them.
---
--- Three layers, the most specific winning for each limit on its own:
---
---   1. the global defaults, Config.Limits (the panel's Target limits >
---      Defaults, live settings like every other);
---   2. per-job overrides staff add for targets who hold that job (the qbx
---      job they are working when the contract is placed, or any other job
---      they hold: Identity.heldJobs): police waiting longer between
---      contracts, say. Where more than one of their jobs has an override,
---      the strictest value wins, limit by limit (Stricter), so switching
---      the active job steps round none of them;
---   3. per-player adjustments staff make from a lookup: a cooldown reset
---      or extended, the day and week counts reset, and an override of
---      their own (custom limits, or exempt from them all).
---
--- Everything here is held in memory, read from the store once at the start
--- (crimson_rp_rows on mysql, the json and memory stores' rp rows), so a
--- placement asks nothing more of the store than it did: Contracts.canCreate
--- asks TargetLimits.forTarget, which reads only these tables.
---
--- A player is never told anything here: a refusal is the band wording the
--- target rules already use (CH.ERR.TARGET_RECENTLY_ON, TARGET_HAS_ENOUGH),
--- with no time beyond what they are shown today, and nothing that says a
--- job or a staff member is behind it.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local TargetLimits = {}

local Storage, Audit, Identity

-- ============================================================================
--                              THE LIMITS
-- ============================================================================

--- Every limit a job or a player override may set, in the order the panel
--- lists them, with the range a value must be in. 0 is off for every one
--- but the cap on live contracts, which is at least 1.
TargetLimits.KEYS = {
    { key = 'TargetCooldownAfterResolveSeconds', label = 'Wait after a contract on them ends', unit = 's',
      min = 0, max = 604800 },
    { key = 'SameCreatorSameTargetCooldownSeconds', label = 'Wait before the same placer names them again',
      unit = 's', min = 0, max = 604800 },
    { key = 'TargetCooldownAfterCompletionSeconds', label = 'Wait after a completed contract on them',
      unit = 's', min = 0, max = 2592000 },
    { key = 'MaxActiveContractsPerTarget', label = 'Live contracts on them at once', unit = 'contracts',
      min = 1, max = 50 },
    { key = 'MaxContractsPerTargetPerDay', label = 'Contracts placed on them in 24 hours', unit = 'contracts',
      min = 0, max = 100 },
    { key = 'MaxContractsPerTargetPerWeek', label = 'Contracts placed on them in 7 days', unit = 'contracts',
      min = 0, max = 500 },
}
local KEY = {}
for _, entry in ipairs(TargetLimits.KEYS) do KEY[entry.key] = entry end

TargetLimits.JOB_MAX = 32          -- longest job name, in characters
TargetLimits.JOBS_MAX = 100        -- job overrides at most
TargetLimits.REASON_MAX = 120
TargetLimits.EXTEND_MAX_MINUTES = 43200   -- 30 days at most at once
TargetLimits.OVERRIDE_MAX_HOURS = 24 * 365
TargetLimits.DAY, TargetLimits.WEEK = 86400, 604800
--- How long a reset stays meaningful: the longest cooldown any limit takes.
local HORIZON = 2592000

local JOB_KIND, PLAYER_KIND = 'tl_job', 'tl_player'

-- ============================================================================
--                              STATE
-- ============================================================================

local Jobs = {}        -- { [job] = { job, limits = { [key] = n }, by_cid, at } }
local Players = {}     -- { [cid] = row } (see writePlayer for the shape)
local Ignored = {}     -- { { id, why } } rows the store held that were not applied
local InFlight = {}    -- { [cid or 'job:'..name] = true } a write awaiting the store

--- A whole number in a limit's range, or nil.
---@param key string
---@param value any
---@return integer|nil
local function LimitValue(key, value)
    local entry = KEY[key]
    local n = tonumber(value)
    if not entry or not n or n ~= math.floor(n) or n < entry.min or n > entry.max then return nil end
    return math.floor(n)
end

--- A set of limits checked whole: every key known and in range. nil and
--- what is wrong otherwise.
---@param limits any
---@param allowEmpty boolean|nil
---@return table|nil clean
---@return string|nil why
function TargetLimits.cleanLimits(limits, allowEmpty)
    if type(limits) ~= 'table' then return nil, 'limits are not a table' end
    local out, count = {}, 0
    for key, value in pairs(limits) do
        if type(key) ~= 'string' or not KEY[key] then return nil, ('unknown limit %s'):format(tostring(key)) end
        local n = LimitValue(key, value)
        if n == nil then
            return nil, ('%s must be a whole number from %d to %d'):format(key, KEY[key].min, KEY[key].max)
        end
        out[key] = n
        count = count + 1
    end
    if count == 0 and not allowEmpty then return nil, 'no limits given' end
    return out
end

--- A qbx job name as staff may give one: [a-z0-9_]+, at most JOB_MAX.
---@param name any
---@return string|nil
function TargetLimits.jobName(name)
    if type(name) ~= 'string' then return nil end
    local text = name:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if #text == 0 or #text > TargetLimits.JOB_MAX or not text:match('^[a-z0-9_]+$') then return nil end
    return text
end

--- The start-up check of the two limits config.lua added for this
--- (Config.Limits.MaxContractsPerTargetPerDay, PerWeek): 0 (off) where a
--- config from before has none, a whole number in range otherwise.
---@param warn string[]
function TargetLimits.checkConfig(warn)
    if type(Config.Limits) ~= 'table' then return end
    for _, key in ipairs({ 'MaxContractsPerTargetPerDay', 'MaxContractsPerTargetPerWeek' }) do
        local value = Config.Limits[key]
        if value == nil then
            Config.Limits[key] = 0
        elseif LimitValue(key, value) == nil or type(value) ~= 'number' then
            warn[#warn + 1] = ('Limits.%s is %s; it has to be a whole number from 0 to %d. Using 0 (off).')
                :format(key, tostring(value), KEY[key].max)
            Config.Limits[key] = 0
        end
    end
end

-- ============================================================================
--                              LOADING
-- ============================================================================

--- When a player row stops mattering: the latest of its facts' horizons,
--- or nil for a row with an override for good.
local function ExpiryOf(row)
    local latest = 0
    local function at(v, plus) if tonumber(v) then latest = math.max(latest, v + (plus or 0)) end end
    at(row.cleared_at, HORIZON)
    at(row.buyout_cleared_at, HORIZON)
    at(row.same_cleared_at, HORIZON)
    at(row.counts_reset_at, TargetLimits.WEEK)
    at(row.until_at)
    if row.override then
        if not row.override.until_at then return nil end
        at(row.override.until_at)
    end
    return latest
end

--- A player row as the store held it, checked; nil and why for one that is
--- not applied.
local function CleanPlayer(row)
    if type(row) ~= 'table' or type(row.cid) ~= 'string' or row.cid == '' then return nil, 'no citizen id' end
    for _, f in ipairs({ 'cleared_at', 'same_cleared_at', 'buyout_cleared_at', 'counts_reset_at', 'until_at',
        'at' }) do
        if row[f] ~= nil and not tonumber(row[f]) then return nil, f .. ' is not a time' end
    end
    if row.override ~= nil then
        if type(row.override) ~= 'table' then return nil, 'override is not a table' end
        local limits, why = TargetLimits.cleanLimits(row.override.limits or {}, true)
        if not limits then return nil, why end
        if row.override.until_at ~= nil and not tonumber(row.override.until_at) then
            return nil, 'override until is not a time'
        end
        if not row.override.exempt and next(limits) == nil then return nil, 'override sets nothing' end
        row.override = { exempt = row.override.exempt == true, limits = limits,
                         until_at = tonumber(row.override.until_at), reason = row.override.reason }
    end
    return row
end

--- Read every job override and player adjustment from the store again,
--- applying those that check out; the rest are listed (TargetLimits.view)
--- and left in the store as they are. Rows run out are deleted.
function TargetLimits.reload()
    Jobs, Players, Ignored, InFlight = {}, {}, {}, {}
    if not (Storage and Storage.readRpRows) then return end
    local okJobs, jobRows = pcall(Storage.readRpRows, JOB_KIND)
    if not okJobs then
        Log.always(('target limit job overrides could not be read (%s); the global defaults apply '
            .. 'to every job until the next start'):format(Util.dbError(jobRows)))
        jobRows = {}
    end
    for _, row in ipairs(jobRows or {}) do
        local job = TargetLimits.jobName(row.job)
        local limits, why = TargetLimits.cleanLimits(row.limits)
        if not job then why = 'job name is not [a-z0-9_]+' end
        if job and limits then
            Jobs[job] = { job = job, limits = limits, by_cid = row.by_cid, at = tonumber(row.at) }
        else
            Ignored[#Ignored + 1] = { id = tostring(row.id), why = why }
            Log.always(('target limit job override %s was not applied: %s'):format(tostring(row.id), why))
        end
    end
    local okPlayers, playerRows = pcall(Storage.readRpRows, PLAYER_KIND)
    if not okPlayers then
        Log.always(('target limit player adjustments could not be read (%s); none applies until the '
            .. 'next start'):format(Util.dbError(playerRows)))
        playerRows = {}
    end
    local now = os.time()
    for _, row in ipairs(playerRows or {}) do
        local clean, why = CleanPlayer(row)
        if not clean then
            Ignored[#Ignored + 1] = { id = tostring(row.id), why = why }
            Log.always(('target limit player adjustment %s was not applied: %s'):format(tostring(row.id), why))
        else
            local expires = ExpiryOf(clean)
            if expires and expires <= now then
                pcall(Storage.deleteRpRow, clean.id)
            else
                clean.expires_at = expires
                Players[clean.cid] = clean
            end
        end
    end
end

---@param deps table { storage, audit, contracts, identity }
function TargetLimits.init(deps)
    Storage, Audit, Identity = deps.storage, deps.audit, deps.identity
    TargetLimits.reload()
    if deps.contracts then deps.contracts.targetLimitsFor = TargetLimits.forTarget end
end

-- ============================================================================
--                              READING
-- ============================================================================

--- A player's adjustment row in force now, or nil.
local function PlayerRow(cid)
    local row = cid and Players[cid]
    if not row then return nil end
    if row.expires_at and row.expires_at <= os.time() then return nil end
    return row
end

--- The override in force on a player's row, or nil.
local function OverrideOf(row)
    local o = row and row.override
    if not o then return nil end
    if o.until_at and o.until_at <= os.time() then return nil end
    return o
end

--- Of two values one limit takes, the stricter: the longer wait, the
--- smaller cap. A day or week cap of 0 is off, so the least strict.
local function Stricter(key, a, b)
    if a == nil then return b end
    if b == nil then return a end
    local entry = KEY[key]
    if entry.unit == 's' then return math.max(a, b) end
    if entry.min == 0 then
        if a == 0 then return b end
        if b == 0 then return a end
    end
    return math.min(a, b)
end
TargetLimits.stricter = Stricter

--- Job names as given: one, a list, or none; lower case, each once.
local function JobList(job)
    local out, seen = {}, {}
    local list = type(job) == 'table' and job or { job }
    for _, name in ipairs(list) do
        if name ~= nil then
            local text = tostring(name):lower()
            if not seen[text] then
                seen[text] = true
                out[#out + 1] = text
            end
        end
    end
    return out
end

--- The limits that apply to one target now, each with where it came from:
--- { values = { [key] = n }, source = { [key] = 'global'|'job'|'player' },
--- exempt, adj (the player's row, or nil), job (the first of their jobs
--- with an override), jobOverrides (every one) }. Memory only.
---@param cid string|nil
---@param job string|string[]|nil the target's job name, or every job they hold (primary first)
---@return table
function TargetLimits.effective(cid, job)
    local values, source = {}, {}
    local jobRows = {}
    for _, name in ipairs(JobList(job)) do
        if Jobs[name] then jobRows[#jobRows + 1] = Jobs[name] end
    end
    local adj = PlayerRow(cid)
    local override = OverrideOf(adj)
    for _, entry in ipairs(TargetLimits.KEYS) do
        local key = entry.key
        local v, from = tonumber(Config.Limits[key]) or 0, 'global'
        local fromJobs
        for i = 1, #jobRows do fromJobs = Stricter(key, fromJobs, jobRows[i].limits[key]) end
        if fromJobs ~= nil then v, from = fromJobs, 'job' end
        if override and override.limits[key] ~= nil then v, from = override.limits[key], 'player' end
        values[key], source[key] = v, from
    end
    local names = {}
    for i = 1, #jobRows do names[i] = jobRows[i].job end
    return { values = values, source = source, exempt = override ~= nil and override.exempt == true,
             adj = adj, job = names[1], jobOverrides = names }
end

--- Every job a player holds, primary first: the one they are working and
--- every other (Identity.heldJobs), as names. The one rule placing, the
--- status card and the job-wide actions share: an override read off the
--- primary job alone was stepped round by switching to a second one.
---@param actor table|nil
---@return string[]
function TargetLimits.jobsOf(actor)
    local out = {}
    if not actor then return out end
    if type(actor.job) == 'table' and actor.job.name then out[1] = tostring(actor.job.name) end
    local held
    if Identity and Identity.heldJobs then
        local ok, list = pcall(Identity.heldJobs, actor)
        held = ok and type(list) == 'table' and list or nil
    end
    if not held then
        held = {}
        local data = actor.player and actor.player.PlayerData
        if data and type(data.jobs) == 'table' then
            for name in pairs(data.jobs) do
                if type(name) == 'string' then held[#held + 1] = { name = name } end
            end
        end
    end
    local rest = {}
    for _, j in ipairs(held) do
        if type(j) == 'table' and type(j.name) == 'string' and j.name ~= out[1] then rest[#rest + 1] = j.name end
    end
    table.sort(rest)
    for i = 1, #rest do out[#out + 1] = rest[i] end
    return out
end

--- The limits for a target actor at placement: by every job they hold.
---@param targetActor table
---@return table
function TargetLimits.forTarget(targetActor)
    return TargetLimits.effective(targetActor and targetActor.cid, TargetLimits.jobsOf(targetActor))
end

--- Whether a resolved contract still counts toward a target's cooldowns
--- after staff reset them: one resolved at or before a reset does not.
---@param adj table|nil
---@param resolvedAt number
---@param samePlacer boolean the same-placer wait, which only Reset all clears
---@return boolean
function TargetLimits.cooldownCounts(adj, resolvedAt, samePlacer)
    if not adj then return true end
    local cleared = samePlacer and adj.same_cleared_at or adj.cleared_at
    return not (cleared and resolvedAt <= cleared)
end

--- Whether a contract placed at `createdAt` counts toward the day and week
--- limits after staff reset the counts.
function TargetLimits.countCounts(adj, createdAt)
    return not (adj and adj.counts_reset_at and createdAt <= adj.counts_reset_at)
end

--- Whether a buyout's immunity still holds after staff actions: only a
--- Reset all on the player (buyout_cleared_at) lifts it.
function TargetLimits.buyoutCounts(adj, resolvedAt)
    return not (adj and adj.buyout_cleared_at and resolvedAt <= adj.buyout_cleared_at)
end

--- A staff-extended cooldown still running, as an os.time(), or nil.
function TargetLimits.extendedUntil(adj)
    local u = adj and tonumber(adj.until_at)
    return (u and u > os.time()) and u or nil
end

--- Every job override, by name, sorted.
function TargetLimits.jobs()
    local out = {}
    for _, row in pairs(Jobs) do out[#out + 1] = row end
    table.sort(out, function(a, b) return a.job < b.job end)
    return out
end

--- The rows the store held that were not applied at the start.
function TargetLimits.ignored() return Ignored end


-- ============================================================================
--                              STATUS
-- ============================================================================

--- One target's standing, exactly, for staff: counts, the cooldown left and
--- the rule that sets it. `contracts` are those naming them (unfinished, and
--- finished in the last week: Storage.contractsNaming(cid, now - WEEK)).
---@param cid string
---@param job string|string[]|nil their job, or every job they hold (primary first)
---@param contracts table[]
---@param everTakenUp function(contractId) -> boolean, as canCreate asks
---@return table
function TargetLimits.status(cid, job, contracts, everTakenUp)
    local now = os.time()
    local jobs = JobList(job)
    local eff = TargetLimits.effective(cid, jobs)
    local v, adj = eff.values, eff.adj
    local live, day, week, dayAll, weekAll = 0, 0, 0, 0, 0
    local left, rule, ruleKey = 0, nil, nil
    local buyoutLeft = 0
    local immunity = tonumber(Config.Immunity.AfterBailoutSeconds) or 0
    local LIVE = { active = true, accepted = true, completing = true }
    for _, c in ipairs(contracts or {}) do
        if c.target_cid == cid then
            if LIVE[c.state] then live = live + 1 end
            local created = tonumber(c.created_at) or 0
            -- Withdrawn or run out before anybody took it: not counted, as
            -- placing does not count it (Contracts.canCreate).
            local untaken = (c.state == 'cancelled' or c.state == 'expired') and everTakenUp
                and not everTakenUp(c.id)
            if c.state ~= 'voided' and not untaken then
                if now - created < TargetLimits.DAY then
                    dayAll = dayAll + 1
                    if TargetLimits.countCounts(adj, created) then day = day + 1 end
                end
                if now - created < TargetLimits.WEEK then
                    weekAll = weekAll + 1
                    if TargetLimits.countCounts(adj, created) then week = week + 1 end
                end
            end
            local resolved = tonumber(c.resolved_at)
            -- The buyout's immunity, whatever else is reset or exempt.
            if c.state == 'bailed_out' and resolved and now - resolved < immunity
                and TargetLimits.buyoutCounts(adj, resolved) then
                local held = immunity - (now - resolved)
                if held > buyoutLeft then buyoutLeft = held end
                if held > left then left, rule, ruleKey = held, 'Immunity.AfterBailoutSeconds', nil end
            end
            if not LIVE[c.state] and resolved and not eff.exempt and c.state ~= 'bailed_out'
                and TargetLimits.cooldownCounts(adj, resolved, false) then
                local since = now - resolved
                local wait, key = v.TargetCooldownAfterResolveSeconds, 'TargetCooldownAfterResolveSeconds'
                if c.state == 'completed' and v.TargetCooldownAfterCompletionSeconds > wait then
                    wait, key = v.TargetCooldownAfterCompletionSeconds, 'TargetCooldownAfterCompletionSeconds'
                end
                local free = (c.state == 'cancelled' or c.state == 'expired') and everTakenUp
                    and not everTakenUp(c.id)
                if not free and since < wait and wait - since > left then
                    left, rule, ruleKey = wait - since, key, key
                end
            end
        end
    end
    local untilAt = TargetLimits.extendedUntil(adj)
    if untilAt and untilAt - now > left then left, rule, ruleKey = untilAt - now, 'staff', nil end
    local from = rule == 'staff' and 'player'
        or (ruleKey and eff.source[ruleKey]) or (rule and 'global') or nil
    return {
        live = live, day = day, week = week, dayAll = dayAll, weekAll = weekAll,
        cooldownLeft = left, cooldownRule = rule, cooldownFrom = from,
        -- The immunity a buyout paid for, left: only Reset all lifts it.
        buyoutLeft = buyoutLeft > 0 and buyoutLeft or nil,
        exempt = eff.exempt, limits = v, source = eff.source, job = jobs[1], jobs = jobs,
        jobOverride = eff.job, jobOverrides = eff.jobOverrides,
        adjustment = adj and {
            cleared_at = adj.cleared_at, same_cleared_at = adj.same_cleared_at,
            buyout_cleared_at = adj.buyout_cleared_at,
            counts_reset_at = adj.counts_reset_at, until_at = adj.until_at,
            override = OverrideOf(adj), reason = adj.reason, at = adj.at, expires_at = adj.expires_at,
        } or nil,
    }
end

-- ============================================================================
--                              WRITES
-- ============================================================================

--- Store a player's row and keep it, or keep the old one: nil and the error.
local function WritePlayer(row)
    row.id, row.kind = 'tl_player:' .. row.cid, PLAYER_KIND
    row.expires_at = ExpiryOf(row)
    local ok, err = pcall(Storage.writeRpRow, row)
    if not ok or err == false then return nil, 'store_failed' end
    Players[row.cid] = row
    return row
end

--- A copy of the player's row to change, or a new one.
local function Draft(cid, name)
    local was = PlayerRow(cid)
    local row = was and Util.copy(was) or { cid = cid }
    row.name = name or row.name
    -- An override that ran out is gone from the copy.
    if row.override and not OverrideOf(row) then row.override = nil end
    return row
end

--- Run one write per subject at a time: a second while one awaits the
--- store is refused as busy.
local function Serial(key, fn)
    if InFlight[key] then return false, CH.ERR.BUSY end
    InFlight[key] = true
    local ran, ok, err, extra = pcall(fn)
    InFlight[key] = nil
    if not ran then
        Log.always(('a target limit write raised: %s'):format(tostring(ok)))
        return false, 'store_failed'
    end
    return ok, err, extra
end

--- Apply one staff action to a player. `action` is 'reset' (resolve and
--- completion cooldowns; `all` the same-placer wait too, a staff
--- extension, and a buyout's immunity unless `keepBuyout`, which a job-wide
--- action sends: Config.Immunity.AfterBailoutSeconds is what the target
--- paid for, lifted for one player at a time or not at all), 'extend' ({ minutes } added to whichever is later, now or
--- the cooldown left; or { untilAt }), 'counts' (day and week counts from
--- now), 'override' ({ exempt, limits, hours (0 for good) }) or 'clear'
--- (the override lifted). Audited by the caller's audit action.
---@param staffCid string|nil
---@param cid string
---@param action string
---@param args table
---@return boolean ok
---@return string|nil err
---@return table|nil row
function TargetLimits.adjust(staffCid, cid, action, args, quiet)
    args = args or {}
    if type(cid) ~= 'string' or cid == '' then return false, CH.ERR.INVALID_INPUT end
    local reason = type(args.reason) == 'string' and args.reason:sub(1, TargetLimits.REASON_MAX) or nil
    return Serial(cid, function()
        local now = os.time()
        local row = Draft(cid, args.name)
        local detail = { subject = cid, reason = reason }
        if action == 'reset' then
            row.cleared_at = now
            if args.all then
                row.same_cleared_at = now
                row.until_at = nil
                if not args.keepBuyout then row.buyout_cleared_at = now end
            end
            detail.all = args.all == true or nil
        elseif action == 'extend' then
            local base = math.max(now, tonumber(args.from) or 0, TargetLimits.extendedUntil(row) or 0)
            local untilAt
            if args.untilAt then
                untilAt = tonumber(args.untilAt)
                if not untilAt or untilAt <= now or untilAt > now + TargetLimits.EXTEND_MAX_MINUTES * 60 then
                    return false, CH.ERR.INVALID_INPUT
                end
            else
                local minutes = tonumber(args.minutes)
                if not minutes or minutes < 1 or minutes > TargetLimits.EXTEND_MAX_MINUTES
                    or minutes ~= math.floor(minutes) then
                    return false, CH.ERR.INVALID_INPUT
                end
                untilAt = math.min(base + minutes * 60, now + TargetLimits.EXTEND_MAX_MINUTES * 60)
            end
            row.until_at = untilAt
            detail.until_at, detail.minutes = untilAt, args.minutes
        elseif action == 'counts' then
            row.counts_reset_at = now
        elseif action == 'override' then
            local limits, why = TargetLimits.cleanLimits(args.limits or {}, args.exempt == true)
            if not limits then return false, CH.ERR.INVALID_INPUT, { why = why } end
            local hours = tonumber(args.hours) or 0
            if hours < 0 or hours > TargetLimits.OVERRIDE_MAX_HOURS or hours ~= math.floor(hours) then
                return false, CH.ERR.INVALID_INPUT
            end
            row.override = { exempt = args.exempt == true, limits = args.exempt == true and {} or limits,
                             until_at = hours > 0 and now + hours * 3600 or nil, reason = reason }
            detail.exempt, detail.limits, detail.until_at = row.override.exempt or nil, row.override.limits,
                row.override.until_at
        elseif action == 'clear' then
            if not OverrideOf(row) then return false, 'not_active' end
            row.override = nil
        else
            return false, CH.ERR.INVALID_INPUT
        end
        row.reason, row.by_cid, row.at = reason or row.reason, staffCid, now
        local kept, err = WritePlayer(row)
        if not kept then return false, err end
        if not quiet then Audit.staff('staff_target_' .. action, staffCid, nil, detail) end
        return true, nil, kept
    end)
end

--- Add or replace a job's override.
---@return boolean ok
---@return string|nil err
---@return table|nil detail
function TargetLimits.setJob(staffCid, name, limits)
    local job = TargetLimits.jobName(name)
    if not job then return false, CH.ERR.INVALID_INPUT, { why = 'job' } end
    local clean, why = TargetLimits.cleanLimits(limits)
    if not clean then return false, CH.ERR.INVALID_INPUT, { why = why } end
    if not Jobs[job] and #TargetLimits.jobs() >= TargetLimits.JOBS_MAX then
        return false, 'too_many', { max = TargetLimits.JOBS_MAX }
    end
    return Serial('job:' .. job, function()
        local row = { id = 'tl_job:' .. job, kind = JOB_KIND, job = job, limits = clean, by_cid = staffCid,
                      at = os.time() }
        local ok, err = pcall(Storage.writeRpRow, row)
        if not ok or err == false then return false, 'store_failed' end
        local was = Jobs[job]
        Jobs[job] = row
        Audit.staff('staff_target_job_set', staffCid, nil,
            { job = job, limits = clean, before = was and was.limits or nil })
        return true, nil, row
    end)
end

--- Remove a job's override.
function TargetLimits.removeJob(staffCid, name)
    local job = TargetLimits.jobName(name)
    if not job then return false, CH.ERR.INVALID_INPUT end
    if not Jobs[job] then return false, 'not_active' end
    return Serial('job:' .. job, function()
        local ok = pcall(Storage.deleteRpRow, 'tl_job:' .. job)
        if not ok then return false, 'store_failed' end
        local was = Jobs[job]
        Jobs[job] = nil
        Audit.staff('staff_target_job_removed', staffCid, nil, { job = job, before = was.limits })
        return true
    end)
end

--- One action on every player in `cids` (a job action): each written as a
--- player action would be, and one audit row for the whole, with the count.
---@return boolean ok
---@return string|nil err
---@return table detail { done, failed }
function TargetLimits.adjustMany(staffCid, job, cids, action, args)
    local done, failed = 0, 0
    for _, cid in ipairs(cids) do
        local ok = TargetLimits.adjust(staffCid, cid, action, args, true)
        if ok then done = done + 1 else failed = failed + 1 end
    end
    Audit.staff('staff_target_job_' .. action, staffCid, nil, {
        job = job, players = done, failed = failed > 0 and failed or nil,
        minutes = args and args.minutes or nil, all = args and args.all or nil,
        reason = args and args.reason or nil,
        subjects = (#cids <= 50) and cids or nil,
    })
    return true, nil, { done = done, failed = failed }
end

--- The maintenance pass: player rows whose every fact has run out, taken
--- out of memory and the store. Nothing while there are none.
---@return integer pruned
function TargetLimits.prune()
    local now, pruned = os.time(), 0
    for cid, row in pairs(Players) do
        if row.expires_at and row.expires_at <= now and not InFlight[cid] then
            if pcall(Storage.deleteRpRow, row.id) then
                Players[cid] = nil
                pruned = pruned + 1
            end
        end
    end
    return pruned
end

return TargetLimits
