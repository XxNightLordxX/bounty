--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/org/extras2.lua                  ║
    ║   Organisation extras 2: the armory, the record and leaderboard,          ║
    ║   discipline and recruitment (each its own switch, off)                   ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The plan's R9, R11, R12 and R13 (README, Organisation extras;
--- docs/developer.md). Each is one switch under Config.Organisation, off as
--- shipped, and each needs the organisation itself on. Off, nothing here
--- reads a row, keeps a timer or calls another resource: the record's
--- observer compares one switch, the application path one more, and there
--- is no tick.
---
---   * Armory (R9): an ox_inventory stash of the organisation's, reached
---     only through the Organisation tab (registered under a group nobody
---     holds, so ox_inventory's own screen never opens it). Members put in
---     the items staff allow (ArmoryItems) and take out up to their role's
---     limit a day (A2 sets it, within Limits.ArmoryWithdrawMax); a boss
---     holding A1 reads the armory's log and takes out more, up to
---     Limits.ArmoryManagePerDay. At the boss office where ArmoryAtOffice
---     says so. Every move is audited. The inventory adapter set to 'none'
---     (or none answering) turns it off with one console line.
---   * Stats (R11): each member's completions, failures, earnings and
---     reliability in the organisation, counted from the record's outcomes
---     (server/record/init.lua's observer) from when it was switched on;
---     an organisation leaderboard. Players see time bands, never exact
---     times (StatsBandShort, StatsBandMid, StatsBandLong); a boss holding M10 sees every member's
---     numbers; staff see all of it, and may reset it.
---   * Discipline (R12): strikes and written warnings with a reason (M11,
---     Limits.StrikesPerDay a day), shown to the member and told to them.
---     Strikes decay after StrikeDecayDays; StrikeSuspendAt active strikes
---     bar the member from contracts for StrikeSuspendHours, and
---     StrikeDemoteAt move them one role down. Suspension and demotion by
---     hand stay the boss powers they are (M5, M4). Only staff overturn a
---     strike or warning, and the member is told.
---   * Recruitment (R13): the application form's questions are set by a
---     boss holding N4 (RecruitQuestions at most); an applicant answers
---     them (RecruitAnswerMax each). A boss holding N2 reads the answers,
---     writes an interview note, and hires or declines through the
---     existing application flow (Org.decide). Anti-spam: a declined
---     applicant waits RecruitCooldownHours, and the organisation takes at
---     most RecruitPerHour applications an hour.
---
--- Every write is audited (org_*), staff may do every one of them from the
--- panel (server/org/staff_ops.lua), and every boss power is its own row in
--- Boss permissions (server/org/powers.lua), off until staff allow it. The
--- anonymity rules are unchanged: nothing here shows a placer or a target.

local Util = CrimsonBoot.requireShared('util')
local Window = CrimsonBoot.require('server.lib.window')
local Feature = CrimsonBoot.require('server.lib.feature')
local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t

local Extras2 = {}

--- What the organisation gains (Org.armoryView, Org.discipline, ...),
--- copied onto the organisation's own table (server/org/init.lua) by
--- Extras2.attach; inside these functions the organisation is O.
local Org = {}
Extras2.API = Org

-- ============================================================================
--                              STATE
-- ============================================================================

--- Items each member took out of the armory in the last day, one entry a
--- unit (their role's limit), and those a boss holding A1 took beyond it.
local Taken = Window.new(86400)
local Managed = Window.new(86400)

--- Strikes and warnings one boss issued in the last day (StrikesPerDay).
local Issued = Window.new(86400)

--- Applications the organisation took in the last hour (RecruitPerHour).
local Applied = Window.new(3600)

--- One armory move at a time: nothing two moves read can change between.
local Busy = false

--- Ids for strikes and warnings made in this process.
local Seq = 0

local O, kit

local function now() return os.time() end
local function deps() return kit.deps() end
local function fail(...) return kit.fail(...) end

--- Whether one of the extras is on: the organisation on, and its switch.
---@param name string a Config.Organisation key
---@return boolean
local function on(name)
    return Feature.on('Organisation') and Config.Organisation[name] == true
end
Extras2.on = on

local function whole(key, fallback, lo, hi)
    local n = math.floor(tonumber(Config.Organisation[key]) or fallback)
    return math.max(lo, math.min(hi, n))
end

local function tell(cid, text)
    local d = deps()
    if d.notify and d.notify.toCitizen and d.identity.byCitizenId(cid) then
        pcall(d.notify.toCitizen, cid, (O.current() and O.current().label) or L('org_extras2.organisation'), text)
    end
end

--- The member a boss may act on (rank, lock, self): nil, or the refusal.
local function mayActOn(org, who, cid)
    if who.staff then return nil end
    local why = O.Engine.mayActOn(org, who.cid, cid)
    if not why then return nil end
    local ERR = O.ERR
    return why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or why == 'not_member' and ERR.NOT_FOUND
        or ERR.RANK
end

--- Plain text from a player (Extras.plain): nil when empty, too long, or
--- holding markup or a link. Refused, never cut.
local function plain(text, max)
    return O.Extras.plain(text, max)
end

local function shownName(m)
    return (O.codenamesOn() and m.codename) or m.name
end

-- ============================================================================
--                              R9: THE ARMORY
-- ============================================================================

--- The stash's name in ox_inventory.
local function stashId(org) return ('crimson_armory_%s'):format(org.id):sub(1, 64) end
Extras2.stashId = stashId

--- A group no player holds: ox_inventory's own screen never opens the
--- stash, so every move goes through the limits here.
Extras2.LOCKED_GROUP = 'crimson_armory_locked'

--- The inventory adapter answering now, or nil (Config.Integrations.Inventory
--- 'none', or no inventory script started).
local function inventory()
    return Integrations.get('inventory')
end

--- The items staff allow in the armory: [name] = true.
local function allowed()
    local out = {}
    for _, name in ipairs(type(Config.Organisation.ArmoryItems) == 'table' and Config.Organisation.ArmoryItems or {}) do
        if type(name) == 'string' and name:match('^[%w_%-]+$') then out[name:lower()] = true end
    end
    return out
end

--- Make sure ox_inventory knows the stash: asked before every read and
--- move (a table set there), so a restart of the inventory script is
--- taken in at the next use.
---@return boolean
local function ensureStash(org)
    local inv = inventory()
    if not (inv and inv.RegisterStash) then return false end
    local ok = Integrations.call('inventory', 'RegisterStash', stashId(org), (org.label or L('org_extras2.organisation')) .. ' armory',
        whole('ArmorySlots', 50, 1, 500), whole('ArmoryWeight', 100000, 1000, 10000000), false,
        { [Extras2.LOCKED_GROUP] = 0 })
    return ok == true
end

--- An inventory's slots as ox_inventory keeps them (keyed by slot), as a
--- list sorted by slot: { slot, name, label, count, metadata }.
local function slotsOf(inv)
    local ok, items = Integrations.call('inventory', 'GetInventoryItems', inv)
    local out = {}
    if not ok or type(items) ~= 'table' then return out end
    for key, s in pairs(items) do
        if type(s) == 'table' and type(s.name) == 'string' and (tonumber(s.count) or 0) > 0 then
            out[#out + 1] = { slot = tonumber(s.slot) or tonumber(key), name = s.name, label = s.label,
                count = math.floor(tonumber(s.count) or 0), metadata = s.metadata }
        end
    end
    table.sort(out, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    return out
end

local function slotAt(list, slot)
    for _, s in ipairs(list) do if s.slot == slot then return s end end
    return nil
end

--- A role's limit a day (A2 sets it): items each member of it takes out.
local function roleLimit(org, grade)
    return math.max(0, math.floor(tonumber(org.settings.armory.limits[tostring(grade)]) or 0))
end

--- The armory's own short log (newest last): the audit keeps every move.
local LOG_KEEP = 100
local function logMove(org, entry)
    local log = org.settings.armory.log
    log[#log + 1] = entry
    while #log > LOG_KEEP do table.remove(log, 1) end
end

--- Why the armory cannot be used now: nil, or the refusal.
local function armoryRefusal(org)
    local ERR = O.ERR
    if not on('Armory') then return ERR.FEATURE_OFF end
    if not inventory() then
        return ERR.RULE, { message = L('org_extras2.the_armory_needs_an_inventory_script') }
    end
    if not ensureStash(org) then
        return ERR.RULE, { message = L('org_extras2.the_inventory_script_would_not_open') }
    end
    return nil
end

--- Where a member stands for a move: at the office where ArmoryAtOffice says.
local function atArmory(org, actor)
    if Config.Organisation.ArmoryAtOffice == false then return nil end
    if not O.hasOffice(org) then
        return O.ERR.OFFICE, { message = L('org_extras2.the_armory_is_at_the_boss') }
    end
    if not O.inOffice(org, actor.source) then
        return O.ERR.OFFICE, { message = L('org_extras2.the_armory_is_at_the_boss_2') }
    end
    return nil
end

--- What a member may still take out today: by their role's limit, and
--- (A1) beyond it.
local function leftToday(org, cid, member)
    local left = math.max(0, roleLimit(org, member.grade) - Taken.count(cid, now()))
    local manage = O.Engine.holds(org, cid, 'A1') and math.max(0, O.Powers.limit(org, 'ArmoryManagePerDay')
        - Managed.count(cid, now())) or 0
    return left, manage
end

--- The armory: its contents, the member's own allowed items (to put in),
--- what they may take out today, the role limits, and (A1, staff) its log.
function Org.armoryView(who)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    local member = not who.staff and org.members[who.cid]
    if not who.staff and not member then return fail(ERR.NOT_MEMBER) end
    local err, data = armoryRefusal(org)
    if err then return fail(err, data) end
    local allow = allowed()
    local out = { items = {}, own = nil, limits = {}, log = nil, allowed = {},
        atOffice = Config.Organisation.ArmoryAtOffice ~= false or nil }
    for _, s in ipairs(slotsOf(stashId(org))) do
        out.items[#out.items + 1] = { slot = s.slot, name = s.name, label = s.label or s.name, count = s.count }
    end
    for name in pairs(allow) do out.allowed[#out.allowed + 1] = name end
    table.sort(out.allowed)
    for grade in pairs(org.roles) do out.limits[tostring(grade)] = roleLimit(org, grade) end
    out.withdrawMax = O.Powers.limit(org, 'ArmoryWithdrawMax')
    if member then
        out.own = {}
        if who.source then
            for _, s in ipairs(slotsOf(who.source)) do
                if allow[s.name:lower()] then
                    out.own[#out.own + 1] = { slot = s.slot, name = s.name, label = s.label or s.name, count = s.count }
                end
            end
        end
        out.left, out.manageLeft = leftToday(org, who.cid, member)
        out.here = atArmory(org, who) == nil or nil
    end
    if who.staff or O.Engine.holds(org, who.cid, 'A1') then
        out.log = {}
        local viewer = who.staff and (who.cid or 'staff') or who.cid
        for i = #org.settings.armory.log, 1, -1 do
            local e = org.settings.armory.log[i]
            local m = org.members[e.cid]
            out.log[#out.log + 1] = { at = e.at, dir = e.dir, item = e.item, count = e.count,
                who = e.cid == 'staff' and L('org_extras2.staff') or (m and shownName(m)) or L('org_extras2.a_former_member'),
                member = (who.staff and m and O.refFor(viewer, e.cid)) or nil }
        end
    end
    return true, nil, out
end

local function count(v)
    v = tonumber(v)
    if not v or v ~= math.floor(v) or v < 1 or v > 1000 then return nil end
    return v
end

--- Put items in: a member, an allowed item from a slot of their own
--- inventory (read here, never the client's word), at the armory.
function Org.armoryDeposit(actor, slot, n)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if type(actor) ~= 'table' or not org.members[actor.cid] then return fail(ERR.NOT_MEMBER) end
    local err, data = armoryRefusal(org)
    if err then return fail(err, data) end
    slot, n = tonumber(slot), count(n)
    if not slot or slot ~= math.floor(slot) or not n then return fail(ERR.INVALID) end
    err, data = atArmory(org, actor)
    if err then return fail(err, data) end
    if Busy then return fail(ERR.BUSY) end
    local s = slotAt(slotsOf(actor.source), slot)
    if not s then return fail(ERR.NOT_FOUND) end
    if not allowed()[s.name:lower()] then
        return fail(ERR.RULE, { message = L('org_extras2.staff_do_not_allow_that_item') })
    end
    if n > s.count then return fail(ERR.BOUNDS) end
    local stash = stashId(org)
    local _, room = Integrations.call('inventory', 'CanCarryItem', stash, s.name, n, s.metadata)
    if not room then return fail(ERR.LIMIT, { message = L('org_extras2.the_armory_has_no_room_for') }) end
    Busy = true
    local okOut, removed = Integrations.call('inventory', 'RemoveItem', actor.source, s.name, n, s.metadata, slot)
    if not (okOut and removed) then
        Busy = false
        return fail(ERR.REFUSED, { message = L('org_extras2.the_inventory_would_not_take_it') })
    end
    local okIn, added = Integrations.call('inventory', 'AddItem', stash, s.name, n, s.metadata)
    if not (okIn and added) then
        -- Back to whoever put it in: nothing lost.
        local back, given = Integrations.call('inventory', 'AddItem', actor.source, s.name, n, s.metadata)
        Busy = false
        if not (back and given) then
            deps().audit.financial('org_armory_refund_failed', actor.cid, nil, { org = org.id, item = s.name,
                count = n, dir = 'in' })
        end
        return fail(ERR.REFUSED, { message = L('org_extras2.the_armory_would_not_take_it') })
    end
    Busy = false
    logMove(org, { at = now(), dir = 'in', item = s.name, count = n, cid = actor.cid })
    kit.save()
    kit.record('org_armory_deposit', { cid = actor.cid }, { item = s.name, count = n })
    return true, nil, { item = s.name, count = n }
end

--- Take items out: a member within their role's limit a day; a boss
--- holding A1 beyond it, up to Limits.ArmoryManagePerDay. Never while
--- suspended from contracts.
function Org.armoryWithdraw(who, slot, n)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    local member = type(who) == 'table' and org.members[who.cid]
    if not member then return fail(ERR.NOT_MEMBER) end
    local err, data = armoryRefusal(org)
    if err then return fail(err, data) end
    slot, n = tonumber(slot), count(n)
    if not slot or slot ~= math.floor(slot) or not n then return fail(ERR.INVALID) end
    if member.suspended_until and member.suspended_until > now() then
        return fail(ERR.RULE, { message = L('org_extras2.suspended_members_take_nothing_from_the') })
    end
    err, data = atArmory(org, who)
    if err then return fail(err, data) end
    local left, manage = leftToday(org, who.cid, member)
    local beyond = math.max(0, n - left)
    if beyond > 0 then
        -- Beyond the role's limit only with A1 (and at the office where it
        -- needs it), within what A1 leaves today.
        local noA1 = O.authorize(org, who, 'A1')
        if noA1 or beyond > manage then
            return fail(ERR.LIMIT, { message = (L('org_extras2.you_may_take_more_today')):format(left + (noA1 and 0 or manage)),
                left = left })
        end
    end
    if Busy then return fail(ERR.BUSY) end
    local stash = stashId(org)
    local s = slotAt(slotsOf(stash), slot)
    if not s then return fail(ERR.NOT_FOUND) end
    if n > s.count then return fail(ERR.BOUNDS) end
    local _, room = Integrations.call('inventory', 'CanCarryItem', who.source, s.name, n, s.metadata)
    if not room then return fail(ERR.LIMIT, { message = L('org_extras2.you_cannot_carry_that') }) end
    Busy = true
    local okOut, removed = Integrations.call('inventory', 'RemoveItem', stash, s.name, n, s.metadata, slot)
    if not (okOut and removed) then
        Busy = false
        return fail(ERR.REFUSED, { message = L('org_extras2.the_armory_would_not_give_it') })
    end
    local okIn, added = Integrations.call('inventory', 'AddItem', who.source, s.name, n, s.metadata)
    if not (okIn and added) then
        local back, kept = Integrations.call('inventory', 'AddItem', stash, s.name, n, s.metadata)
        Busy = false
        if not (back and kept) then
            deps().audit.financial('org_armory_refund_failed', who.cid, nil, { org = org.id, item = s.name,
                count = n, dir = 'out' })
        end
        return fail(ERR.REFUSED, { message = L('org_extras2.you_could_not_take_it_it') })
    end
    Busy = false
    local t = now()
    for _ = 1, n - beyond do Taken.add(who.cid, t) end
    for _ = 1, beyond do Managed.add(who.cid, t) end
    logMove(org, { at = t, dir = 'out', item = s.name, count = n, cid = who.cid })
    kit.save()
    kit.record('org_armory_withdraw', who, { item = s.name, count = n, beyond = beyond > 0 and beyond or nil,
        grade = member.grade })
    return true, nil, { item = s.name, count = n }
end

--- A role's limit a day (A2: a role below the boss's own, within
--- Limits.ArmoryWithdrawMax; staff any).
function Org.armoryLimit(who, grade, n)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Armory') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'A2')
    if err then return fail(err) end
    grade = tonumber(grade)
    n = tonumber(n)
    if not grade or not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    if not n or n ~= math.floor(n) or n < 0 or n > 1000 then return fail(ERR.INVALID) end
    if not who.staff then
        if grade >= org.members[who.cid].grade then return fail(ERR.RANK) end
        if n > O.Powers.limit(org, 'ArmoryWithdrawMax') then return fail(ERR.BOUNDS) end
    end
    local from = roleLimit(org, grade)
    org.settings.armory.limits[tostring(grade)] = n > 0 and n or nil
    kit.save()
    kit.record('org_armory_limit', who, { grade = grade, from = from, to = n })
    return true, nil, { grade = grade, limit = n }
end

--- Staff stock the armory with an allowed item (made, as a reward is), or
--- take items out of it (confiscated: they leave the game).
---@param dir string 'in' | 'out'
function Org.armoryStaff(who, dir, spec)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    local err, data = armoryRefusal(org)
    if err then return fail(err, data) end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    local n = count(spec.count)
    if not n then return fail(ERR.INVALID) end
    local stash = stashId(org)
    if dir == 'in' then
        local name = type(spec.item) == 'string' and spec.item:lower() or nil
        if not name or not allowed()[name] then
            return fail(ERR.RULE, { message = L('org_extras2.only_an_item_in_the_armorys') })
        end
        local _, room = Integrations.call('inventory', 'CanCarryItem', stash, name, n)
        if not room then return fail(ERR.LIMIT, { message = L('org_extras2.the_armory_has_no_room_for_2') }) end
        local ok, added = Integrations.call('inventory', 'AddItem', stash, name, n)
        if not (ok and added) then return fail(ERR.REFUSED, { message = L('org_extras2.the_inventory_would_not_add_it') }) end
        logMove(org, { at = now(), dir = 'in', item = name, count = n, cid = 'staff' })
        kit.save()
        kit.record('org_armory_stocked', who, { item = name, count = n })
        return true, nil, { item = name, count = n }
    elseif dir == 'out' then
        local slot = tonumber(spec.slot)
        local s = slot and slotAt(slotsOf(stash), slot)
        if not s then return fail(ERR.NOT_FOUND) end
        if n > s.count then return fail(ERR.BOUNDS) end
        local ok, removed = Integrations.call('inventory', 'RemoveItem', stash, s.name, n, s.metadata, slot)
        if not (ok and removed) then return fail(ERR.REFUSED, { message = L('org_extras2.the_inventory_would_not_remove_it') }) end
        logMove(org, { at = now(), dir = 'out', item = s.name, count = n, cid = 'staff' })
        kit.save()
        kit.record('org_armory_removed', who, { item = s.name, count = n })
        return true, nil, { item = s.name, count = n }
    end
    return fail(ERR.INVALID)
end

-- ============================================================================
--                              R11: THE RECORD AND THE LEADERBOARD
-- ============================================================================

--- The edges a time to complete is banded at (StatsBandShort, StatsBandMid,
--- StatsBandLong, minutes): one not above the one before is left out.
local function bandEdges()
    local out = {}
    for _, key in ipairs({ 'StatsBandShort', 'StatsBandMid', 'StatsBandLong' }) do
        local n = math.floor(tonumber(Config.Organisation[key]) or 0)
        if n > 0 and (#out == 0 or n > out[#out]) then out[#out + 1] = n end
    end
    return out
end

local function minutesText(m)
    if m < 60 or m % 60 ~= 0 then return (L('org_extras2.min')):format(m) end
    return ('%d h'):format(m // 60)
end

--- A time to complete, in seconds, as a band: never the exact time.
---@return string|nil
function Extras2.band(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds < 0 then return nil end
    local edges = bandEdges()
    if #edges == 0 then return nil end
    local m = seconds / 60
    if m < edges[1] then return 'under ' .. minutesText(edges[1]) end
    for i = 2, #edges do
        if m < edges[i] then return minutesText(edges[i - 1]) .. ' to ' .. minutesText(edges[i]) end
    end
    return 'over ' .. minutesText(edges[#edges])
end

local function statsOf(org, cid)
    local s = org.settings.stats[cid]
    if type(s) ~= 'table' then return nil end
    return s
end

--- A member's numbers: completed, failed, earned, reliability (once
--- StatsMinForRate outcomes are in) and the average time to complete
--- (seconds, for staff; the band for anybody else).
local function numbers(org, cid)
    local s = statsOf(org, cid) or {}
    local done, failed = math.floor(tonumber(s.c) or 0), math.floor(tonumber(s.f) or 0)
    local timed = math.floor(tonumber(s.n) or 0)
    local avg = timed > 0 and math.floor((tonumber(s.t) or 0) / timed) or nil
    local min = whole('StatsMinForRate', 3, 1, 1000)
    return { completed = done, failed = failed, earned = math.floor(tonumber(s.e) or 0),
        rate = (done + failed) >= min and math.floor(done * 100 / (done + failed)) or nil,
        avgSeconds = avg, band = avg and Extras2.band(avg) or nil, since = s.since, last = s.at }
end

--- An outcome on the record (Record.observer): counted for a member of
--- the organisation while Stats is on. kind 'completed' | 'failed'. Not one
--- they held anonymously: every member reads the leaderboard, and a count
--- that moved as an anonymous contract ended would name its operative.
---@param info table|nil { earned, seconds, anonymous }
function Extras2.observe(kind, cid, info)
    if not on('Stats') then return end
    if type(info) == 'table' and info.anonymous == true then return end
    local org = O.current()
    if not org or type(cid) ~= 'string' or not org.members[cid] then return end
    local s = statsOf(org, cid)
    if not s then
        s = { c = 0, f = 0, e = 0, t = 0, n = 0, since = now() }
        org.settings.stats[cid] = s
    end
    if kind == 'completed' then
        s.c = (tonumber(s.c) or 0) + 1
        local earned = type(info) == 'table' and tonumber(info.earned) or nil
        if earned and earned > 0 and earned == earned then s.e = (tonumber(s.e) or 0) + math.floor(earned) end
        local secs = type(info) == 'table' and tonumber(info.seconds) or nil
        if secs and secs >= 0 and secs == secs then
            s.t, s.n = (tonumber(s.t) or 0) + math.floor(secs), (tonumber(s.n) or 0) + 1
        end
    elseif kind == 'failed' then
        s.f = (tonumber(s.f) or 0) + 1
    else
        return
    end
    s.at = now()
    kit.save()
end

--- The leaderboard: members by completions, then reliability. A player
--- sees each one's name (codename where on), completions, reliability and
--- time band; a boss holding M10 sees failures and earnings too; staff
--- the average minutes as well.
function Org.leaderboard(who)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Stats') then return fail(ERR.FEATURE_OFF) end
    local member = not who.staff and org.members[who.cid]
    if not who.staff and not member then return fail(ERR.NOT_MEMBER) end
    local full = who.staff or O.Engine.holds(org, who.cid, 'M10')
    if not full and Config.Organisation.StatsLeaderboard == false then
        return fail(ERR.NO_POWER, { message = L('org_extras2.staff_show_the_leaderboard_only_to') })
    end
    local viewer = who.staff and (who.cid or 'staff') or who.cid
    local rows = {}
    for cid, m in pairs(org.members) do
        local n = numbers(org, cid)
        local row = { name = shownName(m), completed = n.completed, rate = n.rate, band = n.band,
            mine = (not who.staff and cid == who.cid) or nil }
        if full then
            row.failed, row.earned, row.ref = n.failed, n.earned, O.refFor(viewer, cid)
            row.role = org.roles[m.grade] and org.roles[m.grade].label or nil
        end
        if who.staff then row.avgMinutes = n.avgSeconds and math.floor(n.avgSeconds / 60) or nil end
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
        if a.completed ~= b.completed then return a.completed > b.completed end
        if (a.rate or -1) ~= (b.rate or -1) then return (a.rate or -1) > (b.rate or -1) end
        return tostring(a.name) < tostring(b.name)
    end)
    for i, r in ipairs(rows) do r.rank = i end
    return true, nil, { rows = rows, full = full or nil }
end

--- Staff reset the counts: one member's (cid), or everybody's (nil).
function Org.statsReset(who, cid)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Stats') then return fail(ERR.FEATURE_OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    if cid ~= nil then
        if type(cid) ~= 'string' or not org.members[cid] then return fail(ERR.NOT_FOUND) end
        org.settings.stats[cid] = nil
    else
        org.settings.stats = {}
    end
    kit.save()
    kit.record('org_stats_reset', who, { member = cid, all = cid == nil or nil })
    return true
end

-- ============================================================================
--                              R12: DISCIPLINE
-- ============================================================================

local KINDS = { strike = true, warning = true }

local function recordOf(org, cid)
    local list = org.settings.discipline[cid]
    if type(list) ~= 'table' then return {} end
    return list
end

local function active(entry)
    if entry.overturned or entry.kind ~= 'strike' then return false end
    return (tonumber(entry.at) or 0) + whole('StrikeDecayDays', 30, 1, 3650) * 86400 > now()
end

--- How many strikes stand against a member now (decayed and overturned ones
--- left out).
---@return integer
function Extras2.strikes(org, cid)
    local n = 0
    for _, e in ipairs(recordOf(org, cid)) do if active(e) then n = n + 1 end end
    return n
end

--- A member's record as `full` (a boss, staff) or the member reads it.
local function entriesView(org, cid, staffView)
    local out = {}
    local decay = whole('StrikeDecayDays', 30, 1, 3650) * 86400
    for i = #recordOf(org, cid), 1, -1 do
        local e = recordOf(org, cid)[i]
        out[#out + 1] = { id = e.id, kind = e.kind, reason = e.reason, at = e.at,
            expiresAt = e.kind == 'strike' and not e.overturned and (e.at + decay) or nil,
            active = active(e) or nil, overturned = e.overturned and true or nil,
            overturnReason = e.overturnReason, by = e.by == 'staff' and L('org_extras2.staff') or L('org_extras2.a_boss'),
            consequence = e.consequence, byCid = staffView and e.byCid or nil }
    end
    return out
end

--- What follows from the strikes standing now: barred from contracts at
--- StrikeSuspendAt, one role down at StrikeDemoteAt. Said on the entry.
local function consequences(org, member, entry)
    local n = Extras2.strikes(org, member.cid)
    local suspendAt = whole('StrikeSuspendAt', 3, 0, 100)
    local demoteAt = whole('StrikeDemoteAt', 0, 0, 100)
    local said = {}
    if suspendAt > 0 and n >= suspendAt then
        local hours = whole('StrikeSuspendHours', 48, 1, 720)
        local untilAt = now() + hours * 3600
        if not member.suspended_until or member.suspended_until < untilAt then
            member.suspended_until = untilAt
            kit.saveMember(member)
            org.settings.strikeSuspended[member.cid] = untilAt
            said[#said + 1] = (L('org_extras2.suspended_h')):format(hours)
        end
    end
    if demoteAt > 0 and n == demoteAt then
        local lower
        for g in pairs(org.roles) do if g < member.grade and (not lower or g > lower) then lower = g end end
        if lower and not O.Engine.wouldLeaveNoBoss(org, member.cid, lower) and kit.setGrade(org, member.cid, lower) then
            said[#said + 1] = 'demoted'
        end
    end
    entry.consequence = #said > 0 and table.concat(said, ', ') or nil
end

--- A strike or a written warning (M11; staff any), with a reason. A boss:
--- on a member below them, Limits.StrikesPerDay a day. The member is told.
function Org.discipline(who, cid, kind, reason)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Discipline') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'M11')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    if type(kind) ~= 'string' or not KINDS[kind] then return fail(ERR.INVALID) end
    reason = plain(reason, 200)
    if not reason then return fail(ERR.INVALID, { message = L('org_extras2.a_reason_plain_text_up_to') }) end
    local why = mayActOn(org, who, cid)
    if why then return fail(why) end
    if not who.staff and not Issued.take(who.cid, O.Powers.limit(org, 'StrikesPerDay'), now()) then
        return fail(ERR.LIMIT)
    end
    Seq = Seq + 1
    local entry = { id = ('dc%d_%d'):format(Seq, math.random(1000, 9999)), kind = kind, reason = reason, at = now(),
        by = who.staff and 'staff' or 'boss', byCid = who.cid }
    local list = org.settings.discipline[cid]
    if type(list) ~= 'table' then
        list = {}
        org.settings.discipline[cid] = list
    end
    list[#list + 1] = entry
    while #list > 50 do table.remove(list, 1) end
    if kind == 'strike' then consequences(org, member, entry) end
    kit.save()
    kit.record(kind == 'strike' and 'org_strike' or 'org_warning', who, { member = cid, id = entry.id,
        strikes = Extras2.strikes(org, cid), consequence = entry.consequence })
    tell(cid, (kind == 'strike' and L('org_extras2.you_were_given_a_strike') or L('org_extras2.you_were_given_a_written_warning')) .. reason
        .. (entry.consequence and (' (' .. entry.consequence .. ')') or ''))
    return true, nil, { id = entry.id, strikes = Extras2.strikes(org, cid), consequence = entry.consequence }
end

--- Staff overturn a strike or a warning: kept on the record, marked, and no
--- longer counted; a suspension the strikes made is lifted once they fall
--- below the mark. The member is told.
function Org.overturn(who, cid, id, reason)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Discipline') then return fail(ERR.FEATURE_OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    reason = plain(reason, 200)
    if not reason then return fail(ERR.INVALID, { message = L('org_extras2.a_reason_plain_text_up_to') }) end
    local entry
    for _, e in ipairs(recordOf(org, cid)) do if e.id == id then entry = e end end
    if not entry then return fail(ERR.NOT_FOUND) end
    if entry.overturned then return fail(ERR.ALREADY) end
    entry.overturned, entry.overturnReason = now(), reason
    local lifted
    local suspendAt = whole('StrikeSuspendAt', 3, 0, 100)
    local madeUntil = tonumber(org.settings.strikeSuspended[cid])
    if madeUntil and (suspendAt == 0 or Extras2.strikes(org, cid) < suspendAt) then
        org.settings.strikeSuspended[cid] = nil
        if member.suspended_until and member.suspended_until <= madeUntil then
            member.suspended_until = nil
            kit.saveMember(member)
            lifted = true
        end
    end
    kit.save()
    kit.record('org_discipline_overturned', who, { member = cid, id = id, kind = entry.kind, reason = reason,
        lifted = lifted })
    tell(cid, L('org_extras2.staff_overturned_a') .. (entry.kind == 'strike' and 'strike' or L('org_extras2.written_warning'))
        .. L('org_extras2.on_your_record') .. (lifted and L('org_extras2.your_suspension_is_lifted') or '.'))
    return true, nil, { lifted = lifted }
end

--- A member's discipline record: their own (any member), anybody's for a
--- boss holding M11 or M5 (below them or not: reading only), staff any.
function Org.disciplineRead(who, cid)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Discipline') then return fail(ERR.FEATURE_OFF) end
    if not who.staff and not org.members[who.cid] then return fail(ERR.NOT_MEMBER) end
    cid = cid or who.cid
    if not who.staff and cid ~= who.cid and not (O.Engine.holds(org, who.cid, 'M11')
        or O.Engine.holds(org, who.cid, 'M5')) then
        return fail(ERR.NO_POWER)
    end
    if type(cid) ~= 'string' or not org.members[cid] then return fail(ERR.NOT_FOUND) end
    return true, nil, { rows = entriesView(org, cid, who.staff), strikes = Extras2.strikes(org, cid),
        decayDays = whole('StrikeDecayDays', 30, 1, 3650), suspendAt = whole('StrikeSuspendAt', 3, 0, 100),
        demoteAt = whole('StrikeDemoteAt', 0, 0, 100) }
end

-- ============================================================================
--                              R13: RECRUITMENT
-- ============================================================================

--- An application's body with the answers to the form: a marker no
--- plain text can hold (control characters are folded out of it), then
--- JSON.
local FORM_MARK = '\2'

--- The form's questions, as the boss set them.
local function questions(org)
    local q = org.settings.recruit.questions
    return type(q) == 'table' and q or {}
end

--- Set the form's questions (N4; staff), RecruitQuestions at most, each
--- plain text up to 200 characters. An empty list clears the form.
function Org.recruitForm(who, list)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Recruitment') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'N4')
    if err then return fail(err) end
    if type(list) ~= 'table' then return fail(ERR.INVALID) end
    local most = whole('RecruitQuestions', 5, 0, 20)
    if #list > most then return fail(ERR.BOUNDS, { message = (L('org_extras2.at_most_questions')):format(most) }) end
    local out = {}
    for i = 1, #list do
        local q = plain(list[i], 200)
        if not q then return fail(ERR.INVALID, { message = L('org_extras2.each_question_plain_text_up_to') }) end
        out[#out + 1] = q
    end
    for k in pairs(list) do
        if type(k) ~= 'number' or k > #list then return fail(ERR.INVALID) end
    end
    org.settings.recruit.questions = out
    kit.save()
    kit.record('org_recruit_form', who, { questions = #out })
    return true, nil, { questions = out }
end

--- Asked by Org.apply while Recruitment is on: the cooldown and the
--- organisation's hourly cap, then the answers checked against the form.
--- Answers the body to keep, or the refusal.
---@return string|nil body
---@return string|nil err
---@return table|nil data
function Extras2.applyBody(org, actor, text, answers)
    local ERR = O.ERR
    local untilAt = tonumber(org.settings.recruit.cooldowns[actor.cid])
    if untilAt and untilAt > now() then
        return nil, ERR.COOLDOWN, { message = L('org_extras2.your_last_application_was_declined_you'),
            retryAfter = untilAt - now() }
    end
    local qs = questions(org)
    local max = whole('RecruitAnswerMax', 300, 1, 2000)
    local form = {}
    if #qs > 0 then
        if type(answers) ~= 'table' or #answers ~= #qs then
            return nil, ERR.INVALID, { message = L('org_extras2.answer_every_question_on_the_form') }
        end
        for i, q in ipairs(qs) do
            local a = plain(answers[i], max)
            if not a then
                return nil, ERR.INVALID, { message = (L('org_extras2.each_answer_plain_text_up_to')):format(max) }
            end
            form[#form + 1] = { q = q, a = a }
        end
    end
    if not Applied.take(org.id, whole('RecruitPerHour', 10, 1, 1000), now()) then
        return nil, ERR.COOLDOWN, { message = L('org_extras2.the_organisation_takes_no_more_applications') }
    end
    if #form == 0 then return text, nil end
    local ok, encoded = pcall(json.encode, { form = form, text = text })
    if not ok or type(encoded) ~= 'string' then return nil, ERR.INVALID end
    return FORM_MARK .. encoded, nil
end

--- An application's body read back: the free text and the answers.
---@return string|nil text
---@return table|nil form { { q, a } }
function Extras2.readBody(body)
    if type(body) ~= 'string' or body:sub(1, 1) ~= FORM_MARK then return body, nil end
    local ok, t = pcall(json.decode, body:sub(2))
    if not ok or type(t) ~= 'table' then return nil, nil end
    local form = {}
    for _, row in ipairs(type(t.form) == 'table' and t.form or {}) do
        if type(row) == 'table' then form[#form + 1] = { q = tostring(row.q or ''), a = tostring(row.a or '') } end
    end
    return type(t.text) == 'string' and t.text or nil, form
end

--- An interview note on an open application (N2; staff), plain text up to
--- RecruitNoteMax; false clears it. Kept until it is decided.
function Org.interviewNote(who, id, text)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Recruitment') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'N2')
    if err then return fail(err) end
    local row = type(id) == 'string' and org.applications[id]
    if not row then return fail(ERR.NOT_FOUND) end
    if row.cid == who.cid then return fail(ERR.SELF) end
    if text == false then
        org.settings.recruit.notes[id] = nil
    else
        local note = plain(text, whole('RecruitNoteMax', 500, 1, 2000))
        if not note then return fail(ERR.INVALID, { message = L('org_extras2.plain_text_no_links') }) end
        org.settings.recruit.notes[id] = { text = note, at = now(), by = who.staff and L('org_extras2.staff') or L('org_extras2.a_boss') }
    end
    kit.save()
    kit.record('org_interview_note', who, { member = row.cid, cleared = text == false or nil })
    return true
end

--- An application as a boss reads it (Org.applications adds this).
function Extras2.applicationView(org, row, out)
    local text, form = Extras2.readBody(row.body)
    out.body = text
    if form then out.form = form end
    if on('Recruitment') then
        local note = org.settings.recruit.notes[row.id]
        out.note = note and { text = note.text, at = note.at, by = note.by } or nil
    end
end

--- An application decided (Org.decide): the note goes, and a declined
--- applicant waits RecruitCooldownHours before they apply again.
function Extras2.decided(org, row, accept)
    local changed = org.settings.recruit.notes[row.id] ~= nil
    org.settings.recruit.notes[row.id] = nil
    if on('Recruitment') and not accept then
        org.settings.recruit.cooldowns[row.cid] = now() + whole('RecruitCooldownHours', 24, 0, 8760) * 3600
        changed = true
    end
    -- Old cooldowns forgotten as they run out.
    for cid, untilAt in pairs(org.settings.recruit.cooldowns) do
        if (tonumber(untilAt) or 0) <= now() then
            org.settings.recruit.cooldowns[cid] = nil
            changed = true
        end
    end
    if changed then kit.save() end
    if on('Recruitment') then
        tell(row.cid, accept and L('org_extras2.your_application_was_accepted_welcome_to')
            or L('org_extras2.your_application_was_declined'))
    end
end

-- ============================================================================
--                              READS
-- ============================================================================

--- What a member's own tab adds, each only while its switch is on.
---@param out table Org.mine's reply, added to
function Extras2.mine(org, member, out)
    if not member then return end
    if on('Stats') then
        out.statsOn = true
        local n = numbers(org, member.cid)
        local _, _, board = O.leaderboard({ cid = member.cid, source = nil })
        local rank
        for _, r in ipairs(board and board.rows or {}) do if r.mine then rank = r.rank end end
        out.stats = { completed = n.completed, failed = n.failed, earned = n.earned, rate = n.rate, band = n.band,
            since = n.since, rank = rank, of = board and #board.rows or nil,
            leaderboard = (Config.Organisation.StatsLeaderboard ~= false or O.Engine.holds(org, member.cid, 'M10'))
                or nil }
    end
    if on('Discipline') then
        out.discipline = { strikes = Extras2.strikes(org, member.cid),
            warnings = 0, decayDays = whole('StrikeDecayDays', 30, 1, 3650) }
        for _, e in ipairs(recordOf(org, member.cid)) do
            if e.kind == 'warning' and not e.overturned then out.discipline.warnings = out.discipline.warnings + 1 end
        end
        out.discipline.rows = entriesView(org, member.cid, false)
    end
    if on('Armory') then
        out.armory = true
        out.armoryReady = inventory() ~= nil or nil
    end
    if on('Recruitment') then
        out.recruitment = true
        if O.Engine.holds(org, member.cid, 'N4') then
            out.recruitForm = Util.copy(questions(org))
            out.recruitMax = whole('RecruitQuestions', 5, 0, 20)
        end
    end
end

--- What a non-member's tab adds: the form to answer, and how long a
--- declined applicant waits.
function Extras2.outside(org, cid, out)
    if not on('Recruitment') then return end
    out.form = Util.copy(questions(org))
    out.answerMax = whole('RecruitAnswerMax', 300, 1, 2000)
    local untilAt = tonumber(org.settings.recruit.cooldowns[cid])
    if untilAt and untilAt > now() then out.cooldownUntil = untilAt end
end

--- What a member is in the roster, each only while its switch is on.
function Extras2.memberView(org, m, out, full)
    if on('Discipline') then out.strikes = Extras2.strikes(org, m.cid) end
    if on('Stats') and full then
        local n = numbers(org, m.cid)
        out.stats = { completed = n.completed, failed = n.failed, earned = n.earned, rate = n.rate }
    end
end

--- What the panel's orgGet adds: each feature on, and its state.
function Extras2.staffView(org, viewer, out)
    local view, any = {}, false
    for _, name in ipairs({ 'Armory', 'Stats', 'Discipline', 'Recruitment' }) do
        view[name] = on(name) or nil
        any = any or on(name)
    end
    if not any then return end
    local who = { staff = true, cid = viewer }
    if on('Armory') then
        local ok, err, armory = O.armoryView(who)
        view.armory = ok and armory or { error = armory and armory.message or O.message(err) }
    end
    if on('Stats') then
        local _, _, board = O.leaderboard(who)
        view.leaderboard = board and board.rows or {}
    end
    if on('Discipline') then
        view.discipline = {}
        for cid, m in pairs(org.members) do
            local list = recordOf(org, cid)
            if #list > 0 then
                view.discipline[#view.discipline + 1] = { ref = O.refFor(viewer, cid), name = shownName(m),
                    strikes = Extras2.strikes(org, cid), rows = entriesView(org, cid, true) }
            end
        end
        table.sort(view.discipline, function(a, b) return tostring(a.name) < tostring(b.name) end)
        view.disciplineRules = { decayDays = whole('StrikeDecayDays', 30, 1, 3650),
            suspendAt = whole('StrikeSuspendAt', 3, 0, 100), suspendHours = whole('StrikeSuspendHours', 48, 1, 720),
            demoteAt = whole('StrikeDemoteAt', 0, 0, 100) }
    end
    if on('Recruitment') then
        view.form = Util.copy(questions(org))
        view.formMax = whole('RecruitQuestions', 5, 0, 20)
    end
    out.extras2 = view
end

-- ============================================================================
--                              WIRING
-- ============================================================================

--- Wire into the organisation (server/org/init.lua): `k` is its own
--- helpers (fail, record, save, saveMember, setGrade, deps).
function Extras2.attach(o, k)
    O, kit = o, k
    for name, fn in pairs(Org) do o[name] = fn end
end

--- A fresh start (Org.init): the record's outcomes observed.
function Extras2.init(d)
    Taken.reset()
    Managed.reset()
    Issued.reset()
    Applied.reset()
    Busy, Seq = false, 0
    if d.record then d.record.observer = Extras2.observe end
end

--- The start-up check of the extras' settings (Feature.check: a value it
--- cannot take is put back to the shipped one, and said).
Extras2.CHECKS = {
    Armory = { kind = 'switch' }, ArmoryAtOffice = { kind = 'switch' },
    ArmoryItems = { kind = 'list', pattern = '^[%w_%-]+$', max = 64, most = 200,
        says = L('org_extras2.a_list_of_item_names_letters') },
    ArmorySlots = { kind = 'number', integer = true, min = 1, max = 500 },
    ArmoryWeight = { kind = 'number', integer = true, min = 1000, max = 10000000 },
    Stats = { kind = 'switch' }, StatsLeaderboard = { kind = 'switch' },
    StatsMinForRate = { kind = 'number', integer = true, min = 1, max = 1000 },
    StatsBandShort = { kind = 'number', integer = true, min = 1, max = 100000 },
    StatsBandMid = { kind = 'number', integer = true, min = 1, max = 100000 },
    StatsBandLong = { kind = 'number', integer = true, min = 1, max = 100000 },
    Discipline = { kind = 'switch' },
    StrikeDecayDays = { kind = 'number', integer = true, min = 1, max = 3650 },
    StrikeSuspendAt = { kind = 'number', integer = true, min = 0, max = 100 },
    StrikeSuspendHours = { kind = 'number', integer = true, min = 1, max = 720 },
    StrikeDemoteAt = { kind = 'number', integer = true, min = 0, max = 100 },
    Recruitment = { kind = 'switch' },
    RecruitQuestions = { kind = 'number', integer = true, min = 0, max = 20 },
    RecruitAnswerMax = { kind = 'number', integer = true, min = 1, max = 2000 },
    RecruitNoteMax = { kind = 'number', integer = true, min = 1, max = 2000 },
    RecruitCooldownHours = { kind = 'number', integer = true, min = 0, max = 8760 },
    RecruitPerHour = { kind = 'number', integer = true, min = 1, max = 1000 },
}

---@param warn string[]
function Extras2.validate(warn)
    Feature.check('Organisation', Extras2.CHECKS, warn)
end

return Extras2
