CrimsonBoot.define('shared.text', function() --- Crimson Hitman System — cleaning text a player or staff member typed.
---
--- Over Util.sanitizeText, which does the work (one line, no control
--- characters, cut by characters and never through one). These are the
--- shapes the modules ask it in.

local Util = CrimsonBoot.requireShared('util')

local Text = {}

--- The most a staff reason is kept to, in characters.
Text.REASON_MAX = 120

--- A staff reason (a freeze, a sanction, a payment): one clean line of at
--- most `max` characters (Text.REASON_MAX), or nil for none.
---
--- By characters, never through one: a cut UTF-8 character is refused by
--- utf8mb4 (error 1366), and the whole write with it.
---@param reason any
---@param max integer|nil
---@return string|nil
function Text.reason(reason, max)
    if type(reason) ~= 'string' then return nil end
    return Util.sanitizeText(reason, max or Text.REASON_MAX)
end

--- A string field of a request, as sent, when it is at most `max` bytes;
--- nil for anything else (not a string, too long). Never cut: a value too
--- long is refused, not shortened into a different one.
---@param value any
---@param max integer
---@return string|nil
function Text.field(value, max)
    return type(value) == 'string' and #value <= max and value or nil
end

return Text
end)
