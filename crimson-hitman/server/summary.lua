--- The daily summary to the staff Discord (Config.Staff.DailySummary).
---
--- One post a day, at Config.Staff.DailySummaryHour (server time), through
--- the alerts' Discord poster and its webhook convars (Alerts.post): the
--- contracts placed, completed and refunded in the last day, the money in
--- escrow, the review items open, and how many players are frozen and
--- suspended. Counts only: no name, citizen id, contract id or amount that
--- belongs to one person is ever in it.
---
--- At most once a day, a restart included: the day it was last posted is
--- kept by the store (Storage.writeStaffMeta 'staff_summary_day', as
--- yyyymmdd). A start after the hour on a day it has not been posted posts
--- it then. Without a webhook nothing is posted and the day is not marked,
--- so one set later the same day still gets that day's post.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local Summary = {}

local deps
local lastDay = nil     -- yyyymmdd last posted, as the store had it at the start
local DAY_META = 'staff_summary_day'

--- What counts as refunded: a contract that ended with its reward handed
--- back to the placer.
local REFUNDED = { [CH.STATE.CANCELLED] = true, [CH.STATE.EXPIRED] = true, [CH.STATE.VOIDED] = true }

---@param d table { storage, review, freeze, audit, alerts?, sanctions? (Sanctions.count) }
function Summary.init(d)
    deps = d
    lastDay = nil
    if deps.storage and deps.storage.readStaffMeta then
        local ok, meta = pcall(deps.storage.readStaffMeta)
        if ok and type(meta) == 'table' then lastDay = tonumber(meta[DAY_META]) end
        if not ok then
            Log.debug(('the day the daily summary was last posted could not be read (%s)')
                :format(Util.dbError(meta)))
        end
    end
end

--- Today as yyyymmdd, and the hour, in server time.
---@param now integer
---@return integer day
---@return integer hour
local function dayOf(now)
    local t = os.date('*t', now)
    return t.year * 10000 + t.month * 100 + t.day, t.hour
end

--- The counts, over the day up to `now`. Counts only.
---@param now integer|nil
---@return table { placed, completed, refunded, escrow = { cash, bank, dirty, goods }, reviews, frozen, suspended }
function Summary.counts(now)
    now = now or os.time()
    local since = now - 86400
    local out = { placed = 0, completed = 0, refunded = 0,
                  escrow = { cash = 0, bank = 0, dirty = 0, goods = 0 },
                  reviews = 0, frozen = 0, suspended = nil }
    local Storage = deps.storage
    for _, contract in ipairs(Storage.allContracts() or {}) do
        local created = tonumber(contract.created_at) or 0
        local resolved = tonumber(contract.resolved_at) or 0
        if created > since and created <= now then out.placed = out.placed + 1 end
        if resolved > since and resolved <= now then
            if contract.state == CH.STATE.COMPLETED then out.completed = out.completed + 1 end
            if REFUNDED[contract.state] then out.refunded = out.refunded + 1 end
        end
    end
    for _, line in ipairs(Storage.unsettledEscrow and Storage.unsettledEscrow() or {}) do
        if CH.MONEY_SOURCES[line.source] then
            out.escrow[line.source] = out.escrow[line.source] + math.max(0, tonumber(line.amount) or 0)
        else
            out.escrow.goods = out.escrow.goods + 1
        end
    end
    out.reviews = deps.review and deps.review.openCount() or 0
    out.frozen = deps.freeze and deps.freeze.count() or 0
    -- Suspensions are server/sanctions.lua's (Sanctions.count, wired in by
    -- main.lua): counted where it is, and said not tracked where it is not.
    if deps.sanctions and type(deps.sanctions.count) == 'function' then
        local ok, n = pcall(deps.sanctions.count)
        out.suspended = ok and tonumber(n) or nil
    end
    return out
end

local function money(n)
    local text = tostring(math.floor(n))
    local formatted = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return '$' .. formatted:gsub('^,', '')
end

--- The post, from the counts: one line each, nothing else.
---@param counts table
---@param day integer yyyymmdd
---@return string
function Summary.text(counts, day)
    local e = counts.escrow
    local total = e.cash + e.bank + e.dirty
    return table.concat({
        ('**Crimson Hitman: daily summary** (%04d-%02d-%02d, the last 24 hours)')
            :format(day // 10000, (day // 100) % 100, day % 100),
        ('- Contracts placed: %d'):format(counts.placed),
        ('- Contracts completed: %d'):format(counts.completed),
        ('- Contracts refunded (cancelled, expired or voided): %d'):format(counts.refunded),
        ('- Money in escrow: %s (cash %s, bank %s, dirty %s), and %d goods line(s)')
            :format(money(total), money(e.cash), money(e.bank), money(e.dirty), e.goods),
        ('- Open review items: %d'):format(counts.reviews),
        ('- Frozen players: %d'):format(counts.frozen),
        counts.suspended and ('- Suspended players: %d'):format(counts.suspended)
            or '- Suspended players: not tracked on this server',
    }, '\n')
end

--- Post today's summary if it is due: switched on, at or past the hour,
--- and not posted today. From the maintenance tick.
---@return boolean posted
---@return string|nil why 'off' | 'early' | 'done' | 'no_webhook' | 'unavailable'
function Summary.tick()
    if not (type(Config.Staff) == 'table' and Config.Staff.DailySummary == true) then return false, 'off' end
    local now = os.time()
    local day, hour = dayOf(now)
    local at = math.floor(tonumber(Config.Staff.DailySummaryHour) or 6)
    if hour < at then return false, 'early' end
    if lastDay == day then return false, 'done' end
    local alerts = deps.alerts
    if not (alerts and alerts.post) then return false, 'unavailable' end
    local text = Summary.text(Summary.counts(now), day)
    local queued, err = alerts.post(text)
    if not queued then return false, err end
    lastDay = day
    local wrote, writeErr = pcall(deps.storage.writeStaffMeta, DAY_META, day)
    if not wrote then
        Log.always(('the daily summary was posted, but the day could not be kept by the store (%s): '
            .. 'a restart today may post it again'):format(Util.dbError(writeErr)))
    end
    pcall(deps.audit.staff, 'daily_summary_posted', nil, nil, { day = day })
    return true
end

return Summary
