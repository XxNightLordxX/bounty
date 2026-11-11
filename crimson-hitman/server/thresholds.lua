--- Staff alert thresholds (Config.Staff, under Staff & permissions).
---
--- Three counts, each kept in memory per player over a sliding window, and
--- a staff Alert (server/alerts.lua, so Discord too where it is on) the
--- moment one goes past its threshold:
---
---   * one player placing more than Staff.AlertPlacedPerHour contracts in an
---     hour;
---   * one target getting more than Staff.AlertTargetPerDay contracts in a
---     day;
---   * one player being refused more than Staff.AlertRefusalsPer10Min times
---     in ten minutes (every request the app answered with a refusal,
---     rate limits included).
---
--- 0 turns one off. Each fires once per window per player: past the
--- threshold again in the same window says nothing more, and the count goes
--- on from there.
---
--- The alert names the player by citizen id and nothing else. Alerts are
--- shown whole only to staff with Config.Admin.IdentityAce: everybody else,
--- and Discord, read the citizen id as '(a player)' (Panel.scrubText, the
--- scrub every alert goes through). Never a name, never which contract.

local Log = CrimsonBoot.requireShared('log')
local Window = CrimsonBoot.require('server.lib.window')
local L = CrimsonBoot.requireShared('locale').t

local Thresholds = {}

--- The windows, in seconds.
Thresholds.HOUR, Thresholds.DAY, Thresholds.TEN_MINUTES = 3600, 86400, 600


local RULES = {
    placed = { setting = 'AlertPlacedPerHour', window = Thresholds.HOUR,
               text = L('thresholds.staff_alert_player_placed_contracts_in') },
    target = { setting = 'AlertTargetPerDay', window = Thresholds.DAY,
               text = L('thresholds.staff_alert_target_had_contracts_placed') },
    refused = { setting = 'AlertRefusalsPer10Min', window = Thresholds.TEN_MINUTES,
                text = L('thresholds.staff_alert_player_was_refused_times') },
}

--- One window per kind (Window.new), each entry { times, alertedAt|nil }.
local books

local function freshBooks()
    local out = {}
    for kind, rule in pairs(RULES) do out[kind] = Window.new(rule.window) end
    return out
end
books = freshBooks()

---@param deps table|nil { audit }
function Thresholds.init(deps)
    local _ = deps
    books = freshBooks()
end

local function limitOf(rule)
    local staff = type(Config.Staff) == 'table' and Config.Staff or {}
    local n = math.floor(tonumber(staff[rule.setting]) or 0)
    return n > 0 and n or 0
end

--- Count one event for `cid`, and alert when it goes past the threshold.
---@param kind string 'placed' | 'target' | 'refused'
---@param cid string|nil
---@return boolean alerted
local function count(kind, cid)
    local rule = RULES[kind]
    if not rule or type(cid) ~= 'string' or cid == '' then return false end
    local limit = limitOf(rule)
    if limit == 0 then return false end
    local now = os.time()
    local book = books[kind]
    -- Only the ones still inside the window, and never more than one past
    -- the threshold: that is all a verdict needs.
    local n = book.add(cid, now, limit + 1)
    if n <= limit then return false end
    local entry = book.get(cid)
    if entry.alertedAt and now - entry.alertedAt < rule.window then return false end
    entry.alertedAt = now
    Log.always(rule.text:format(cid, n, limit))
    return true
end

--- A contract placed: by `creatorCid`, on `targetCid`.
---@return boolean alerted
function Thresholds.placed(creatorCid, targetCid)
    local a = count('placed', creatorCid)
    local b = count('target', targetCid)
    return a or b
end

--- A request of `cid`'s the app refused.
---@return boolean alerted
function Thresholds.refused(cid)
    return count('refused', cid)
end

--- Forget whoever has nothing left inside their window. From the
--- maintenance tick, so the books hold the last day's players at most.
---@return integer dropped
function Thresholds.sweep()
    local now, dropped = os.time(), 0
    for kind, book in pairs(books) do
        local window = RULES[kind].window
        dropped = dropped + book.sweep(now, function(entry)
            return entry.alertedAt ~= nil and now - entry.alertedAt < window
        end)
    end
    return dropped
end

return Thresholds
