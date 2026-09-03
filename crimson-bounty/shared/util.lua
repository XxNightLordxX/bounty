--- Crimson Bounty System — pure helpers.
--- Nothing in here touches game state, so every function is directly unit-testable.

local Util = {}

--- Coerce an untrusted value to a non-negative integer.
--- Every number that arrives from a client passes through here before any
--- comparison, so NaN, inf, negatives, strings and tables can never reach
--- arithmetic or a database write (§14.14).
---@param value any
---@param max integer|nil upper bound; values above it are rejected, not clamped
---@return integer|nil
function Util.toCount(value, max)
    if type(value) == 'string' then value = tonumber(value) end
    if type(value) ~= 'number' then return nil end
    if value ~= value then return nil end           -- NaN
    if value == math.huge or value == -math.huge then return nil end
    if value < 0 then return nil end
    local int = math.floor(value)
    if int ~= value then return nil end             -- no fractional money or quantities
    if max and int > max then return nil end
    return int
end

--- Same coercion but requires a positive value.
function Util.toPositive(value, max)
    local n = Util.toCount(value, max)
    if not n or n == 0 then return nil end
    return n
end

--- Validate an opaque server-issued identifier coming back from a client.
--- Rejects anything that is not our own id shape, so an id can never be used
--- as a path fragment, a format string or a SQL identifier.
---@param id any
---@return string|nil
function Util.toId(id)
    if type(id) ~= 'string' then return nil end
    if #id < 8 or #id > 64 then return nil end
    if not id:match('^[A-Za-z0-9_%-]+$') then return nil end
    return id
end

--- Validate a citizen id shape (QBox ids are alphanumeric).
function Util.toCitizenId(cid)
    if type(cid) ~= 'string' then return nil end
    if #cid < 3 or #cid > 32 then return nil end
    if not cid:match('^[A-Za-z0-9]+$') then return nil end
    return cid
end

--- Squared distance between two {x,y,z} tables. Squared so callers compare
--- against a squared radius and never pay for a square root on a hot tick.
function Util.dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

--- Clean a player-supplied string: trim, collapse whitespace, cap length and
--- strip control characters. Returns nil when nothing usable remains.
---@param text any
---@param maxLength integer
---@return string|nil
function Util.sanitizeText(text, maxLength)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s*(.-)%s*$', '%1')
    if text == '' then return nil end
    if #text > maxLength then text = text:sub(1, maxLength) end
    return text
end

--- Count digits, used to blunt phone numbers and addresses in free text (§14.30).
function Util.digitCount(text)
    local n = 0
    for _ in tostring(text):gmatch('%d') do n = n + 1 end
    return n
end

--- Extract the host from a URL. Used to check a photo URL against the upload
--- provider allowlist — a photo may only come from where lb-phone uploads.
---@param url any
---@return string|nil
function Util.urlHost(url)
    if type(url) ~= 'string' or #url > 2048 then return nil end
    local host = url:match('^https://([%w%.%-]+)') or url:match('^http://([%w%.%-]+)')
    if not host or host == '' then return nil end
    return host:lower()
end

--- Deterministic shallow copy; used so stored records are never aliased by
--- callers that might mutate them.
function Util.copy(tbl)
    if type(tbl) ~= 'table' then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = type(v) == 'table' and Util.copy(v) or v
    end
    return out
end

--- Sum the money value of a set of escrow lines, per source.
---@param lines table[] escrow lines
---@param portion string|nil restrict to a portion, or nil for all
---@return table totals keyed by source
function Util.escrowTotals(lines, portion)
    local totals = { cash = 0, bank = 0, dirty = 0, items = 0, weapons = 0 }
    for i = 1, #lines do
        local line = lines[i]
        if not portion or line.portion == portion then
            if line.source == 'cash' or line.source == 'bank' or line.source == 'dirty' then
                totals[line.source] = totals[line.source] + (line.amount or 0)
            elseif line.source == 'item' then
                totals.items = totals.items + (line.quantity or 0)
            elseif line.source == 'weapon' then
                totals.weapons = totals.weapons + 1
            end
        end
    end
    return totals
end

--- True when the escrow set holds nothing at all.
function Util.escrowIsEmpty(lines, portion)
    local t = Util.escrowTotals(lines, portion)
    return t.cash == 0 and t.bank == 0 and t.dirty == 0 and t.items == 0 and t.weapons == 0
end

return Util
