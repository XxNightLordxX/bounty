--- Hitman heat (Config.Improvements.HitmanHeat, README, Optional
--- features). Off as shipped.
---
--- A hitman gathers heat from what the police hear of their work, each
--- piece kept for DecayHours and then gone:
---   * ProtectedCompletionHeat for a completion (a kill or a handover) on a
---     whitelisted-job target (Contracts.afterClaim);
---   * WitnessHeat for a witness report on their completion
---     (Config.Roleplay.WitnessHeat, RpConsequences.afterWitness);
---   * AdvisoryHeat for each police bulletin about their work: taking a
---     contract on a whitelisted-job target while acceptance bulletins go
---     (Config.Advisory.OnAccept), and buying an informant tip on one while
---     tip bulletins go (Config.Advisory.OnLocationTip).
--- At or above Threshold a hitman is "known":
---   * each contract they take warns its target with the paranoid alert
---     ("You feel eyes on you", Notify.paranoid, its own wait and cooldown)
---     at WarnTargetChancePercent (100 = always);
---   * while a known hitman holds a live contract, law enforcement get a
---     vague bulletin ("a known contract killer is believed active in the
---     city"), at most every BulletinEveryMinutes, on their phones and in
---     sc-dispatch with no position.
--- Nothing names anybody: not the hitman, not a contract, not where. The
--- heat itself is never shown to a player. Kept in the store
--- (crimson_rp_rows, kind 'imp_heat'), so a restart does not cool anybody.

local Util = CrimsonBoot.requireShared('util')

local Heat = {}

local Storage, Identity, Notify, Audit, Board, Projection

local KIND = 'imp_heat'

--- [cid] = { { at = os.time(), points = n }, ... }
local events = {}
--- When the last bulletin went, os.time().
local lastBulletin = -math.huge
--- When the oldest heat kept cools, os.time(): the tick prunes nothing
--- before then. math.huge: none kept.
local coolsAt = math.huge

--- Drawn for the target's warning. A test may replace it.
Heat.random = math.random

local function rules()
    return Board and Board.on('HitmanHeat') or nil
end

local num = Util.num

--- Drop what has cooled from one hitman's heat.
---@return boolean changed
local function prune(cid, now)
    local list = events[cid]
    if not list then return false end
    local cfg = rules() or {}
    local since = now - num(cfg.DecayHours, 24) * 3600
    local kept = {}
    for i = 1, #list do
        if list[i].at > since then kept[#kept + 1] = list[i] end
    end
    local changed = #kept ~= #list
    events[cid] = #kept > 0 and kept or nil
    return changed
end

--- Keep one hitman's heat in the store, or take it away when none is left.
local function keep(cid)
    if not Storage or not Storage.writeRpRow then return end
    local id = KIND .. ':' .. cid
    if not events[cid] then
        pcall(Storage.deleteRpRow, id)
        return
    end
    pcall(Storage.writeRpRow, { id = id, kind = KIND, cid = cid, events = events[cid] })
end

--- A hitman's heat now.
---@param cid string
---@return integer
function Heat.of(cid)
    if type(cid) ~= 'string' then return 0 end
    local now = os.time()
    local cfg = rules() or {}
    local since = now - num(cfg.DecayHours, 24) * 3600
    local sum = 0
    for _, e in ipairs(events[cid] or {}) do
        if e.at > since then sum = sum + e.points end
    end
    return sum
end

--- Whether a hitman is at or above the threshold (always false while off).
---@param cid string
---@return boolean
function Heat.known(cid)
    local cfg = rules()
    if not cfg then return false end
    return Heat.of(cid) >= num(cfg.Threshold, 5)
end

--- Give a hitman heat, kept, audited (for staff, never shown to players).
---@param cid string
---@param points number
---@param why string
function Heat.add(cid, points, why)
    if not rules() or type(cid) ~= 'string' then return end
    points = math.floor(num(points))
    if points <= 0 then return end
    local now = os.time()
    prune(cid, now)
    local list = events[cid] or {}
    list[#list + 1] = { at = now, points = points }
    events[cid] = list
    coolsAt = math.min(coolsAt, now + num((rules() or {}).DecayHours, 24) * 3600)
    keep(cid)
    Audit.action('imp_heat_added', cid, nil, { points = points, why = why, heat = Heat.of(cid) })
end

--- A completion that paid (Contracts.afterClaim): on a whitelisted-job
--- target, heat.
function Heat.onClaimed(contractId, hitmanCid)
    local cfg = rules()
    if not cfg then return end
    local contract = Storage.readContract(contractId)
    if contract and contract.target_protected == true then
        Heat.add(hitmanCid, cfg.ProtectedCompletionHeat, 'protected_completion')
    end
end

--- A witness report on a completion went out (RpConsequences.afterWitness).
function Heat.onWitness(_, hitmanCid)
    local cfg = rules()
    if not cfg then return end
    Heat.add(hitmanCid, cfg.WitnessHeat, 'witness')
end

--- After a request went through (App's roleplay after-steps): a bulletin
--- about an acceptance or a tip on a whitelisted-job target is heat, and a
--- known hitman's acceptance may warn the target.
function Heat.after(name, actor, payload)
    local cfg = rules()
    if not cfg or (name ~= 'accept' and name ~= 'locationTip') or type(actor) ~= 'table' then return end
    local id = type(payload) == 'table' and Util.toId(payload.id) or nil
    local contract = id and Storage.readContract(id) or nil
    if not contract then return end
    local stage = name == 'accept' and 'accepted' or 'tip'
    if contract.target_protected == true and Notify.advises(stage) then
        Heat.add(actor.cid, cfg.AdvisoryHeat, stage == 'tip' and 'tip_bulletin' or 'accept_bulletin')
    end
    if name ~= 'accept' or not Heat.known(actor.cid) then return end
    -- Only once the target may be shown the contract at all: inside its
    -- wait, a warning would date it.
    if not Notify.shownToTarget(contract) then return end
    local chance = math.floor(num(cfg.WarnTargetChancePercent))
    if chance <= 0 or Heat.random(1, 100) > chance then return end
    Notify.paranoid(contract.target_cid)
    Audit.action('imp_heat_warned', actor.cid, contract.id, {})
end

--- The police jobs sc-dispatch is asked to show a bulletin to.
local function policeJobs()
    local jobs = {}
    for name, yes in pairs(Config.Advisory and Config.Advisory.RecipientJobNames or {}) do
        if yes == true and type(name) == 'string' then jobs[#jobs + 1] = name end
    end
    table.sort(jobs)
    if #jobs == 0 then jobs = { 'police' } end
    return jobs
end

--- Whether this hitman holds a live contract now, from the snapshot of
--- what is running the other loops share (Projection.liveSnapshot): no
--- read of its own while nothing was written.
local function working(cid)
    local contracts, rosters
    if Projection and Projection.liveSnapshot then contracts, rosters = Projection.liveSnapshot() end
    if not contracts then
        for _, c in ipairs(Storage.contractsInvolving(cid, true) or {}) do
            if (c.state == CH.STATE.ACCEPTED or c.state == CH.STATE.COMPLETING) and c.creator_cid ~= cid
                and c.target_cid ~= cid then
                local row = Storage.readHitman(c.id, cid)
                if row and row.state == 'active' then return true end
            end
        end
        return false
    end
    for _, c in ipairs(contracts) do
        if (c.state == CH.STATE.ACCEPTED or c.state == CH.STATE.COMPLETING) and c.creator_cid ~= cid
            and c.target_cid ~= cid then
            local roster = rosters and rosters[c.id] or Storage.readHitmen(c.id) or {}
            for _, row in ipairs(roster) do
                if row.hitman_cid == cid and row.state == 'active' then return true end
            end
        end
    end
    return false
end

--- The vague bulletin, when a known hitman is working and the last one is
--- old enough. Names nobody; no position.
---@return boolean sent
function Heat.bulletin(now)
    local cfg = rules()
    if not cfg then return false end
    local every = math.floor(num(cfg.BulletinEveryMinutes))
    if every <= 0 or now - lastBulletin < every * 60 then return false end
    local any = false
    for cid in pairs(events) do
        if not any and Heat.known(cid) and working(cid) then any = true end
    end
    if not any then return false end
    lastBulletin = now
    local title = Util.sanitizeText(tostring(cfg.BulletinTitle or 'Intelligence bulletin'), 60)
    local text = Util.sanitizeText(tostring(cfg.BulletinText or ''), 160)
    local told = 0
    -- To every officer alike, a known hitman who holds a police job too:
    -- sc-dispatch shows it them anyway, and leaving them out of the phone
    -- bulletin told whoever compared notes which officer was the hitman.
    for _, actor in ipairs(Identity.online() or {}) do
        if Identity.isAdvisoryRecipient(actor.job) then
            Notify.toCitizen(actor.cid, title, text, { bypassBudget = true })
            told = told + 1
        end
    end
    local dispatched = false
    if Config.Advisory and Config.Advisory.UseDispatch ~= false
        and GetResourceState('sc-dispatch') == 'started' then
        dispatched = pcall(function()
            exports['sc-dispatch']:AddNotification({
                title = title, message = text, caller = 'Criminal Intelligence',
                priority = math.floor(num(Config.Advisory.DispatchPriority, 2)),
                job_table = policeJobs(),
                unique_id = ('ch-heat-%d'):format(now):sub(1, 60),
            })
        end)
    end
    Audit.action('imp_heat_bulletin', nil, nil, { told = told, dispatched = dispatched or nil })
    return true
end

--- The tick: heat that cooled dropped (and its row), once the oldest kept
--- has cooled and not before, then the bulletin (its own wait).
function Heat.tick()
    if not rules() then return end
    local now = os.time()
    if now >= coolsAt then
        local decay = num(rules().DecayHours, 24) * 3600
        coolsAt = math.huge
        for cid in pairs(events) do
            if prune(cid, now) then keep(cid) end
            for _, e in ipairs(events[cid] or {}) do coolsAt = math.min(coolsAt, e.at + decay) end
        end
    end
    Heat.bulletin(now)
end

--- Test seam.
function Heat.reset()
    events, lastBulletin, coolsAt = {}, -math.huge, math.huge
end

function Heat.init(deps, board)
    Storage, Identity, Notify, Audit, Board = deps.storage, deps.identity, deps.notify, deps.audit, board
    Projection = deps.projection
    Heat.reset()
    if Storage and Storage.readRpRows then
        local ok, rows = pcall(Storage.readRpRows, KIND)
        for _, row in ipairs(ok and type(rows) == 'table' and rows or {}) do
            if type(row.cid) == 'string' and type(row.events) == 'table' then
                local list = {}
                for _, e in ipairs(row.events) do
                    local at, points = tonumber(e.at), tonumber(e.points)
                    if at and points then list[#list + 1] = { at = at, points = points } end
                end
                if #list > 0 then events[row.cid] = list end
                -- Cooled while the server was down: dropped on the first tick.
                if #list > 0 then coolsAt = math.min(coolsAt, list[1].at) end
            end
        end
    end
    if deps.contracts and deps.contracts.afterClaim then
        deps.contracts.afterClaim.impHeat = Heat.onClaimed
    end
    if deps.rpConsequences then deps.rpConsequences.afterWitness = Heat.onWitness end
end

return Heat
