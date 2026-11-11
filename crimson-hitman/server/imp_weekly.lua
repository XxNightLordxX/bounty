--- Weekly stats to Discord (Config.Improvements.WeeklyStats, README
--- Optional features). Off as shipped, and off it posts nothing.
---
--- On, once a week, on Day at Hour (server time), one post of the last
--- seven days' totals: contracts placed, contracts completed, and the money
--- paid out of rewards to hitmen. Totals only. A leaderboard of hitmen was
--- asked for, by alias only; but an alias is per contract, and any handle
--- that stays the same for one hitman across the week would let a reader
--- tie that hitman's contracts together (a client who knows their own
--- contract's operative did three that week learns which others were his).
--- With any doubt about anonymity the owner's rule is counts only, so no
--- hitman, placer or target is named, counted or ranked on their own.
---
--- Posted to the convar crimson_hitman_stats_webhook where it is set (a
--- public channel, say), else to the alerts' webhook as the daily summary
--- is, both through the one sender (Discord.post 'stats', server/discord.lua). At most once a week, a restart included: the date of
--- the post it last made is kept by the store (Storage.writeStaffMeta
--- 'imp_weekly_day', yyyymmdd), in every backend. A start inside the day
--- after the hour, with that week's post not made, posts it then; a week
--- the server was down for the whole day after the hour is not caught up.

local Log = CrimsonBoot.requireShared('log')
local Words = CrimsonBoot.requireShared('words')
local Db = CrimsonBoot.require('server.lib.db')
local Feature = CrimsonBoot.require('server.lib.feature')
local Discord = CrimsonBoot.require('server.discord')
local L = CrimsonBoot.requireShared('locale').t

--- This feature's block of config (server/lib/feature.lua reads and checks it).
local BLOCK = 'Improvements.WeeklyStats'

local Weekly = {}

local deps
local lastDay = nil
--- Asleep until the next post falls due: { untilAt, why, key }, key being
--- the Day and Hour it was worked out for (a change wakes it). nil: awake.
local asleep = nil
--- A send refused after the totals were read (a webhook was set): they are
--- not read again until this (os.time()), or every tick of a due day read
--- every contract for a post that went nowhere. { untilAt, why }; nil: try
--- on the next tick. With no webhook at all the tick answers first and
--- nothing is read.
local backoff = nil
--- How long a refused send waits before the totals are read again.
Weekly.BACKOFF_SECONDS = 600
Weekly.META = 'imp_weekly_day'
--- The stats webhook's own convar (Discord.CHANNELS.stats, first).
Weekly.CONVAR = Discord.CHANNELS.stats[1][1]
local WEEK = 7 * 86400

--- The days of the week, as os.date's wday counts them (1 = Sunday).
Weekly.DAYS = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' }

Weekly.RULES = {
    Enabled = { kind = 'switch', default = false },
    Day = { kind = 'choice', choices = Weekly.DAYS, default = 'sunday' },
    Hour = { kind = 'number', integer = true, min = 0, max = 23, default = 18 },
}

---@param warn string[]
function Weekly.validate(warn)
    Feature.check(BLOCK, Weekly.RULES, warn)
end

---@param d table { storage, audit }
function Weekly.init(d)
    deps = d
    lastDay, asleep, backoff = nil, nil, nil
    if deps.storage and deps.storage.readStaffMeta then
        local ok, meta = Db.quiet('the day the weekly stats were last posted could not be read (%s)',
            deps.storage.readStaffMeta)
        if ok and type(meta) == 'table' then lastDay = tonumber(meta[Weekly.META]) end
    end
end

local function dayNumber(at)
    local t = os.date('*t', at)
    return t.year * 10000 + t.month * 100 + t.day
end

--- The last time the post fell due at or before `now`: Day at Hour.
---@param now integer
---@return integer
function Weekly.lastDue(now)
    local rules = Feature.block(BLOCK)
    local want = 1
    for i, name in ipairs(Weekly.DAYS) do if name == rules.Day then want = i end end
    local hour = math.floor(tonumber(rules.Hour) or 18)
    -- Counted back from now in seconds, from the clock's own fields: the
    -- start of today's hour moved to Hour, then back to the day.
    local t = os.date('*t', now)
    local back = (t.wday - want) % 7
    local due = now - back * 86400 - ((t.hour - hour) * 3600 + t.min * 60 + t.sec)
    if due > now then due = due - 7 * 86400 end
    return due
end

--- The totals over the seven days up to `now`. Counts and sums only.
---@param now integer|nil
---@return table { placed, completed, paid }
function Weekly.totals(now)
    now = now or os.time()
    local since = now - WEEK
    local out = { placed = 0, completed = 0, paid = 0 }
    local Storage = deps.storage
    local ids = {}
    local byId = {}
    for _, contract in ipairs(Storage.allContracts() or {}) do
        local created = tonumber(contract.created_at) or 0
        local resolved = tonumber(contract.resolved_at) or 0
        if created > since and created <= now then out.placed = out.placed + 1 end
        if resolved > since and resolved <= now and contract.state == CH.STATE.COMPLETED then
            out.completed = out.completed + 1
        end
        -- A payout of the week can be on any contract still live, or one
        -- that ended within it.
        if resolved == 0 or resolved > since then
            ids[#ids + 1] = contract.id
            byId[contract.id] = contract
        end
    end
    -- Money paid out of a reward: a money line settled within the week to
    -- somebody other than who put it up and the placer (a stake given back,
    -- a refund, a buyout to the placer are none of them a payout).
    local lines = #ids > 0 and Storage.readEscrowMany and Storage.readEscrowMany(ids) or {}
    for id, list in pairs(lines) do
        local contract = byId[id]
        for _, line in ipairs(list or {}) do
            local at = tonumber(line.settled_at) or 0
            if contract and CH.MONEY_SOURCES[line.source] and line.state == CH.ESCROW_STATE.SETTLED
                and at > since and at <= now and line.settled_to ~= nil
                and line.settled_to ~= contract.creator_cid and line.settled_to ~= line.taken_from
                and line.settled_to ~= line.staker then
                out.paid = out.paid + math.max(0, tonumber(line.amount) or 0)
            end
        end
    end
    return out
end


--- The post, from the totals: one line each, nothing else.
---@param totals table
---@param day integer yyyymmdd
---@return string
function Weekly.text(totals, day)
    return table.concat({
        (L('imp_weekly.crimson_hitman_the_week_in_numbers'))
            :format(day // 10000, (day // 100) % 100, day % 100),
        (L('imp_weekly.contracts_placed')):format(totals.placed),
        (L('imp_weekly.contracts_completed')):format(totals.completed),
        (L('imp_weekly.paid_out_to_hitmen')):format(Words.dollars(totals.paid)),
    }, '\n')
end

--- Send the text through the one sender (server/discord.lua), on the
--- 'stats' channel: the stats webhook where its convar is set, tried once,
--- as it always was; else the alerts' webhook, tried as the daily summary is.
---@return boolean queued
---@return string|nil err 'no_webhook' | 'held' | 'unavailable'
local function send(text)
    local _, which = Discord.url('stats')
    if which ~= 'stats' then return Discord.post('stats', text) end
    return Discord.post('stats', text, { tries = 1, done = function(ok, code)
        if not ok and code then
            Log.debug(('the weekly stats could not be posted to Discord (HTTP %d)'):format(code))
        end
    end })
end

--- Post this week's totals if due: switched on, inside the day after Day at
--- Hour, and not posted for it yet. From the maintenance tick.
---@return boolean posted
---@return string|nil why 'off' | 'early' | 'done' | 'no_webhook' | 'unavailable'
function Weekly.tick()
    if not Feature.on(BLOCK) then
        asleep = nil
        return false, 'off'
    end
    local now = os.time()
    -- It knows when the next post falls due, and sleeps until then: a
    -- comparison a tick, not the calendar worked out again.
    local rules = Feature.block(BLOCK)
    local key = tostring(rules.Day) .. '@' .. tostring(rules.Hour)
    if asleep and asleep.key == key and now < asleep.untilAt then return false, asleep.why end
    asleep = nil
    local due = Weekly.lastDue(now)
    if now - due >= 86400 then
        asleep = { untilAt = due + WEEK, why = 'early', key = key }
        return false, 'early'
    end
    local day = dayNumber(due)
    if lastDay == day then
        asleep = { untilAt = due + WEEK, why = 'done', key = key }
        return false, 'done'
    end
    if backoff and now < backoff.untilAt then return false, backoff.why end
    backoff = nil
    -- A convar read, not a store read: a webhook set later posts on the
    -- next tick, and a tick with none reads no contract.
    if not Discord.url('stats') then return false, 'no_webhook' end
    local queued, err = send(Weekly.text(Weekly.totals(now), day))
    if not queued then
        backoff = { untilAt = now + Weekly.BACKOFF_SECONDS, why = err }
        return false, err
    end
    lastDay = day
    Db.try('the weekly stats were posted, but the day could not be kept by the store (%s): a restart '
        .. 'today may post them again', deps.storage.writeStaffMeta, Weekly.META, day)
    pcall(deps.audit.staff, 'weekly_stats_posted', nil, nil, { day = day })
    return true
end

return Weekly
