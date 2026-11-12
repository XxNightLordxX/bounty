CrimsonBoot.define('shared.words', function() --- Crimson Hitman System — numbers as players and staff read them.
---
--- Money, hours, waits and distances, in the words every notice, command
--- answer and panel line uses. Pure: nothing here reads game state.

local Words = {}

--- The words: locales/en.lua (words.*), in the language in force.
local L = CrimsonBoot.requireShared('locale').t

--- One of a pair of keys by the count: key_one for 1, key_other otherwise.
local function plural(key, n)
    return L(key .. (n == 1 and '_one' or '_other')):format(n)
end

--- Whole dollars with thousands grouped: $15,000.
---
--- `sign` says what a negative amount reads as: nil '$-1,500' (staff
--- lines and summaries), 'before' '-$1,500' (a player's notice), 'none'
--- '$1,500' (the amount alone, where the sentence says which way it went).
---@param amount any a number; anything else reads as 0
---@param sign string|nil nil | 'before' | 'none'
---@return string
function Words.dollars(amount, sign)
    local n = tonumber(amount) or 0
    if sign == 'before' or sign == 'none' then
        local digits = tostring(math.floor(math.abs(n)))
        local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
        return ((sign == 'before' and n < 0) and '-$' or '$') .. grouped
    end
    local text = tostring(math.floor(n))
    local formatted = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return '$' .. formatted:gsub('^,', ''):gsub('^%-,', '-')
end

--- Hours to a tenth: '3 h', '2.5 h'.
---
--- Rounded to the nearest tenth first, so 2.96 reads '3 h'. With `exact`,
--- not rounded first: a whole number reads '3 h' and anything else to one
--- decimal ('3.0 h' for 2.96), as the playtime panel has always said it.
---@param hours any
---@param exact boolean|nil
---@return string
function Words.hours(hours, exact)
    if exact then
        local whole = math.floor(hours)
        if whole == hours then return tostring(whole) .. ' h' end
        return ('%.1f h'):format(hours)
    end
    local tenths = math.floor((tonumber(hours) or 0) * 10 + 0.5)
    if tenths % 10 == 0 then return ('%d h'):format(tenths // 10) end
    return ('%.1f h'):format(tenths / 10)
end

--- A length of time: '45 seconds', '3 minutes' (minutes rounded up).
---@param seconds any
---@return string
function Words.duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 60 then return plural('words.seconds', seconds) end
    return plural('words.minutes', math.ceil(seconds / 60))
end

--- When something can be tried again: 'in a moment', 'in 45 seconds',
--- 'in about 3 minutes' (seconds and minutes rounded up).
---@param seconds any
---@return string
function Words.inAbout(seconds)
    local s = math.ceil(tonumber(seconds) or 0)
    if not (s > 0) then return L('words.in_a_moment') end
    if s < 60 then return plural('words.in_seconds', s) end
    return plural('words.in_about_minutes', math.ceil(s / 60))
end

--- A distance in metres: '10', '7.5' (no unit).
---@param metres any anything that is not a number reads as 0
---@return string
function Words.metres(metres)
    local r = tonumber(metres) or 0
    if r > -1e9 and r < 1e9 and r == math.floor(r) then return ('%d'):format(math.floor(r)) end
    return ('%.1f'):format(r)
end

return Words
end)
