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

--- Same, for an escrow line id.
---
--- A line id is either a store sequence ('owe00000001') or a contract id
--- and an index joined by a colon ('ct00000001:3'), so it needs the colon
--- that Util.toId deliberately refuses. Exactly one, and never at either
--- end, so the shape stays as narrow as the ids the store actually mints.
---@param id any
---@return string|nil
function Util.toLineId(id)
    if type(id) ~= 'string' then return nil end
    if #id < 8 or #id > 80 then return nil end
    if not id:match('^[A-Za-z0-9_%-]+:?[A-Za-z0-9_%-]*$') then return nil end
    local _, colons = id:gsub(':', '')
    if colons > 1 then return nil end
    if id:sub(-1) == ':' then return nil end
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

--- Keep only well-formed UTF-8, dropping any byte that is not part of a
--- complete, legal sequence.
---
--- Two things produce broken text here. A payload can carry any bytes at
--- all, and the length cap below counts bytes rather than characters — so a
--- four-byte emoji sitting across the cap used to leave two of its bytes
--- behind. Either way the result reaches a utf8mb4 column, which refuses
--- it, and a JSON message the page has to parse: an invalid sequence there
--- drops the whole reply, and the app sits waiting for an answer that was
--- thrown away.
---
--- "Complete" is not enough on its own. Three shapes are structurally fine
--- and still illegal, and every one of them is a way to smuggle something
--- past a check that is looking for it:
---   * an overlong encoding — a character written in more bytes than it
---     needs, so `/` can arrive as two bytes and pass a check for `/`;
---   * a surrogate half, which is not a character at all;
---   * anything above U+10FFFF, which is outside Unicode.
--- The second byte of a sequence is what separates these from the real
--- thing, so its allowed range depends on the byte that led it.
---
--- Written by hand rather than with the utf8 library so it behaves the same
--- on a build without it.
---@param text string
---@return string
function Util.toValidUtf8(text)
    local out, i, n = {}, 1, #text

    while i <= n do
        local lead = text:byte(i)
        local length, secondLow, secondHigh

        if lead < 0x80 then
            length = 1
        elseif lead >= 0xC2 and lead <= 0xDF then
            length, secondLow, secondHigh = 2, 0x80, 0xBF
        elseif lead == 0xE0 then
            -- 0x80..0x9F here would be an overlong two-byte character.
            length, secondLow, secondHigh = 3, 0xA0, 0xBF
        elseif lead == 0xED then
            -- 0xA0.. would be a surrogate half.
            length, secondLow, secondHigh = 3, 0x80, 0x9F
        elseif lead >= 0xE1 and lead <= 0xEF then
            length, secondLow, secondHigh = 3, 0x80, 0xBF
        elseif lead == 0xF0 then
            -- 0x80..0x8F here would be an overlong three-byte character.
            length, secondLow, secondHigh = 4, 0x90, 0xBF
        elseif lead == 0xF4 then
            -- Anything past 0x8F is above U+10FFFF.
            length, secondLow, secondHigh = 4, 0x80, 0x8F
        elseif lead >= 0xF1 and lead <= 0xF3 then
            length, secondLow, secondHigh = 4, 0x80, 0xBF
        end
        -- Everything else — 0x80..0xC1 and 0xF5..0xFF — can never lead a
        -- sequence: a stray continuation byte, or an overlong or
        -- out-of-range lead.

        if not length or i + length - 1 > n then
            i = i + 1
        else
            local complete = true
            for j = i + 1, i + length - 1 do
                local byte = text:byte(j)
                local low = (j == i + 1) and secondLow or 0x80
                local high = (j == i + 1) and secondHigh or 0xBF
                if byte < low or byte > high then complete = false end
            end

            if complete then
                out[#out + 1] = text:sub(i, i + length - 1)
                i = i + length
            else
                -- Only the lead byte is dropped. What follows is examined
                -- on its own terms, so a good character immediately after a
                -- bad one is not swallowed with it.
                i = i + 1
            end
        end
    end

    return table.concat(out)
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
    -- After the cut, not before: the cap counts bytes, so this is also what
    -- removes the half of a character the cut left behind.
    text = Util.toValidUtf8(text)
    -- Trailing space can be exposed by dropping a character off the end.
    text = text:gsub('^%s*(.-)%s*$', '%1')
    if text == '' then return nil end
    return text
end

--- Count digits, used to blunt phone numbers and addresses in free text (§14.30).
function Util.digitCount(text)
    local n = 0
    for _ in tostring(text):gmatch('%d') do n = n + 1 end
    return n
end

--- Extract the host from a URL, for checking a photo URL against the upload
--- provider allowlist.
---
--- The naive pattern `^https://([%w%.%-]+)` is unsafe: it stops at the `@` in
--- `https://trusted.example@198.51.100.7/x.png` and reports the *userinfo*
--- as the host, while a browser fetches 198.51.100.7. Any URL carrying
--- userinfo is therefore rejected outright rather than parsed — no
--- legitimate upload provider uses it.
---@param url any
---@return string|nil
function Util.urlHost(url)
    if type(url) ~= 'string' then return nil end
    if #url < 8 or #url > Util.MAX_URL_LENGTH then return nil end

    local rest = url:match('^https://(.*)$') or url:match('^http://(.*)$')
    if not rest or rest == '' then return nil end

    -- The authority ends at the first path, query or fragment delimiter.
    -- A backslash is treated as a delimiter too: some parsers normalise it
    -- to a slash, which is another way to smuggle a different host.
    local authority = rest:match('^([^/?#\\]+)')
    if not authority or authority == '' then return nil end

    if authority:find('@', 1, true) then return nil end

    local host = authority:match('^([^:]+)')
    if not host or host == '' then return nil end
    if #host > 253 then return nil end
    if not host:match('^[%w%.%-]+$') then return nil end
    if host:find('%.%.') then return nil end

    return host:lower()
end

--- Photo URLs are stored, so they are bounded to what the column holds.
Util.MAX_URL_LENGTH = 512

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

--------------------------------------------------------------------------
-- Ids
--------------------------------------------------------------------------

--- Mint an id nothing is using yet.
---
--- Ids carry a per-process counter, so they are unique within one run of one
--- server and not beyond it. Two instances sharing a database mint the same
--- sequence, and the MySQL backend writes contracts and escrow with
--- ON DUPLICATE KEY UPDATE — a repeat does not fail, it overwrites. That is
--- a contract rewritten under its creator, or a payout landing on top of an
--- escrow line and taking its money with it.
---
--- Escrow.take already reads back and confirms its own lines for exactly
--- this reason. This is the same defence for everything else that mints one.
---
--- Kept here rather than in the store so it is the same check for every
--- backend, and so it can be tested without one.
---@param nextId fun(prefix: string): string
---@param prefix string
---@param exists fun(id: string): any truthy when the id is already in use
---@param attempts integer|nil
---@return string|nil id nil when no free id could be found
function Util.mintId(nextId, prefix, exists, attempts)
    for _ = 1, (attempts or 5) do
        local id = nextId(prefix)
        if not id then return nil end
        if not exists(id) then return id end
    end
    -- Refusing is the only safe answer: every id on offer is in use, and
    -- writing to one of them would destroy whatever is already there.
    return nil
end

--------------------------------------------------------------------------
-- A clock that only goes forward
--------------------------------------------------------------------------

--- Milliseconds since this resource started, guaranteed non-decreasing.
---
--- GetGameTimer wraps. A server that has been up long enough sees it fall
--- back to near zero, and every elapsed-time calculation in this resource
--- then goes negative — which is not a cosmetic problem: the rate limiter
--- computes a refill from it, so a negative elapsed drives every player's
--- token count deeply negative and refuses them for good, while the sweep
--- that would clear the bucket also tests an elapsed and never fires. One
--- wrap would lock every player out of the app until the next restart.
---
--- Everything that measures a duration reads this instead. A wrap is
--- absorbed once, here, rather than guarded at a dozen call sites where the
--- next one added would forget.
local lastRaw, carried = 0, 0

function Util.monotonicMs()
    local raw = GetGameTimer and GetGameTimer() or 0
    if raw < lastRaw then
        -- Carry what the timer had reached, so the clock this resource sees
        -- steps past the wrap rather than back through it.
        carried = carried + lastRaw
    end
    lastRaw = raw
    return carried + raw
end

--- Test seam: put the clock back where it started.
function Util.resetMonotonic()
    lastRaw, carried = 0, 0
end

--- The client has no module loader — server/boot.lua's require_shared is a
--- server-side stand-in for one — so the client half reaches these helpers
--- through a global. The file is listed in client_scripts and loaded exactly
--- once on each side, so there is still only one clock per process.
CrimsonUtil = Util

return Util
