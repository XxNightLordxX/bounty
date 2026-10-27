--- Crimson Hitman System — pure helpers.
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
    -- The cap counts characters, which is what the page's box counts and
    -- what a VARCHAR holds. It counted bytes: a reason the box allowed, in
    -- Polish or Russian, was cut to half its length after the creator had
    -- paid for the contract, with nothing to say so.
    --
    -- A character is at most four bytes, so nothing past that many can
    -- survive the cap; cutting there first bounds the work on a payload of
    -- any size. The cut can split a character, which the pass that follows
    -- removes.
    if #text > maxLength * 4 then text = text:sub(1, maxLength * 4) end
    text = Util.toValidUtf8(text)
    local cut = utf8.offset(text, maxLength + 1)
    if cut and cut <= #text then text = text:sub(1, cut - 1) end
    -- Trailing space can be exposed by dropping a character off the end.
    text = text:gsub('^%s*(.-)%s*$', '%1')
    if text == '' then return nil end
    return text
end

--- The most of a database error that is kept or printed.
Util.DB_ERROR_MAX = 300

--- A database error short enough to keep on a record and to print, with
--- none of the values the statement was sent.
---
--- oxmysql's await raises its whole message (docs/oxmysql.md §5): the statement,
--- then every parameter as JSON on a line of its own, then the server's own
--- words. The parameters are players' data (citizen ids, character names, a
--- reason, an item's whole metadata), and a review item kept that whole
--- message in the store, where 70 KB of metadata made the item itself too big
--- for its column. Kept: the server's words (the last line) and the first 60
--- characters of the statement, at most DB_ERROR_MAX characters, never the
--- parameters line. Anything else is cut to the same length.
---@param err any
---@return string
function Util.dbError(err)
    local text = tostring(err)
    local query = text:find('\nQuery: ', 1, true)
    local last = text:match('.*()\n')
    local before = last and text:sub(1, last - 1):match('.*()\n')
    if query and text:find('was unable to execute a query!', 1, true)
        and before and before > query then
        local statement = text:sub(query + 8, before - 1):gsub('%s+', ' ')
            :gsub('^%s+', ''):sub(1, 60)
        text = ('%s (statement: %s)'):format(text:sub(last + 1), statement)
    end
    text = text:gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s*(.-)%s*$', '%1')
    if #text > Util.DB_ERROR_MAX then
        text = Util.toValidUtf8(text:sub(1, Util.DB_ERROR_MAX))
    end
    return text
end

--- A console line with a database error inside it, as Util.dbError keeps
--- the error: the words before it kept whole, then the server's words and
--- the start of the statement, never the values it was sent. A line that
--- printed oxmysql's message as it came (`raised: <err>`) carried every
--- parameter, a client's citizen id, licence and name among them. Any other
--- line is given back as it is.
---@param text any
---@return string
function Util.dbErrorIn(text)
    text = tostring(text)
    local query = text:find('\nQuery: ', 1, true)
    if not query or not text:find('was unable to execute a query!', 1, true) then return text end
    return text:sub(1, query - 1) .. ' ' .. Util.dbError(text)
end

--- A time on the clock rounded up to the next five minutes.
---
--- A deadline set from the moment something happened carries that moment
--- to the second, and every viewer is sent the deadline: on an anonymous
--- contract, when its client placed or edited it (§14.32). Rounded up, so
--- nobody is given less time than they were promised.
---@param at integer os.time()
---@return integer
function Util.roundClock(at)
    local step = Util.CLOCK_STEP
    return at + ((step - (at % step)) % step)
end

--- An id that says nothing about when it was made.
---
--- The store's ids are a sequence, and on mysql the clock to the second as
--- well, and a contract's id goes to everybody who sees it on the board: an
--- anonymous client's placement could be read off it (§14.32), or bracketed
--- between two ids the viewer minted themselves. Random instead, and minted
--- through Util.mintId so a collision is tried again rather than written.
---@param prefix string
---@return string
local ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789'
function Util.randomId(prefix)
    local out = { prefix }
    for i = 2, 13 do
        local k = math.random(1, #ID_ALPHABET)
        out[i] = ID_ALPHABET:sub(k, k)
    end
    return table.concat(out)
end

--- The step a deadline is rounded to, in seconds. Also the least one may be
--- left with when it is brought in (Contracts.bringDeadlineIn).
Util.CLOCK_STEP = 300

--- Whether law enforcement is told at this stage: 'posted' or 'accepted'.
---
--- The one answer to that question, asked by the advisory itself and by the
--- projection that tells the page. They asked it two ways — the advisory by
--- truthiness, the page's flag with `~= false` — so a config without
--- OnCreate told players the department had been advised while no bulletin
--- went. Absent is on; both have shipped on since the first release.
---@param stage string
---@return boolean
function Util.advises(stage)
    local advisory = Config and Config.Advisory
    if type(advisory) ~= 'table' or advisory.Enabled ~= true then return false end
    local key = stage == 'posted' and 'OnCreate' or 'OnAccept'
    return advisory[key] ~= false
end

--- How a contract may be completed: CH.FULFILMENT_RULE.ALIVE, only by a
--- live handover, or EITHER, by a kill or a live handover.
---
--- Read off the contract, never off the config: the rule is a term it was
--- placed under, like its reward, and a server switching the setting must
--- not change what a hitman already took on. A contract stored before the
--- rule existed carries none and reads as 'either', the terms it was
--- accepted under. Anything else is read as the stricter rule.
---@param contract table
---@return string
function Util.fulfilmentRule(contract)
    local rule = contract and contract.fulfilment_rule
    if rule == nil or rule == CH.FULFILMENT_RULE.EITHER then return CH.FULFILMENT_RULE.EITHER end
    return CH.FULFILMENT_RULE.ALIVE
end

--- The rule a contract placed now is placed under
--- (Config.Completion.Fulfilment). Checked at boot, so anything else here is
--- a config changed under a running server, read as the default the boot
--- check would have made it: live transfer only.
---@return string
function Util.placingRule()
    local completion = Config and Config.Completion
    if type(completion) == 'table' and completion.Fulfilment == CH.FULFILMENT_RULE.EITHER then
        return CH.FULFILMENT_RULE.EITHER
    end
    return CH.FULFILMENT_RULE.ALIVE
end

--- Whether kill photos exist on this server at all
--- (Config.Completion.KillPhotos). Read at every use, so the admin panel's
--- switch applies to the next action. Checked at boot, so anything but true
--- here is a config changed under a running server, read as off, as the
--- boot check reads it.
---@return boolean
function Util.killPhotos()
    local completion = Config and Config.Completion
    return type(completion) == 'table' and completion.KillPhotos == true
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

--------------------------------------------------------------------------
-- Base64
--------------------------------------------------------------------------
--
-- A kill photo kept on this server arrives from the page as base64 and goes
-- back to the client's page the same way, and the server's Lua has no
-- decoder or encoder of its own (no library, no native). Each photo is
-- decoded once, when it is sent, and encoded once, when it is opened: some
-- tens of milliseconds for a few hundred kilobytes.

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64_BYTE, B64_VALUE = {}, {}
for i = 1, #B64 do
    B64_BYTE[i - 1] = B64:byte(i)
    B64_VALUE[B64:byte(i)] = i - 1
end
local PAD = ('='):byte()

--- Bytes from base64, or nil for anything that is not strict base64:
--- whole groups of four, the 64 characters and nothing else, '=' only as
--- the padding at the very end. Strict, because this reads what a client
--- sent, and a decoder that skips what it does not know decodes something
--- other than what was checked.
---@param text any
---@return string|nil bytes
function Util.fromBase64(text)
    if type(text) ~= 'string' or #text % 4 ~= 0 then return nil end
    local byte, char = string.byte, string.char
    local len = #text
    local out, n = {}, 0
    for i = 1, len, 4 do
        local a, b, c, d = byte(text, i, i + 3)
        local va, vb, vc, vd = B64_VALUE[a], B64_VALUE[b], B64_VALUE[c], B64_VALUE[d]
        if not va or not vb then return nil end
        if vd then
            if not vc then return nil end
            local v = (va << 18) | (vb << 12) | (vc << 6) | vd
            n = n + 1
            out[n] = char(v >> 16, (v >> 8) & 255, v & 255)
        elseif d ~= PAD or i + 3 ~= len then
            return nil
        elseif vc then
            n = n + 1
            out[n] = char(((va << 2) | (vb >> 4)) & 255, ((vb << 4) | (vc >> 2)) & 255)
        elseif c == PAD then
            n = n + 1
            out[n] = char(((va << 2) | (vb >> 4)) & 255)
        else
            return nil
        end
    end
    return table.concat(out)
end

--- Base64 of any bytes, NULs and all.
---@param bytes string
---@return string|nil
function Util.toBase64(bytes)
    if type(bytes) ~= 'string' then return nil end
    local byte, char = string.byte, string.char
    local len = #bytes
    local out, n = {}, 0
    for i = 1, len - 2, 3 do
        local a, b, c = byte(bytes, i, i + 2)
        local v = (a << 16) | (b << 8) | c
        n = n + 1
        out[n] = char(B64_BYTE[v >> 18], B64_BYTE[(v >> 12) & 63],
            B64_BYTE[(v >> 6) & 63], B64_BYTE[v & 63])
    end
    local rest = len % 3
    if rest == 1 then
        local a = byte(bytes, len)
        out[n + 1] = char(B64_BYTE[a >> 2], B64_BYTE[(a & 3) << 4], PAD, PAD)
    elseif rest == 2 then
        local a, b = byte(bytes, len - 1, len)
        local v = (a << 8) | b
        out[n + 1] = char(B64_BYTE[v >> 10], B64_BYTE[(v >> 4) & 63],
            B64_BYTE[(v & 15) << 2], PAD)
    end
    return table.concat(out)
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

--- Whether an audit row passes the admin panel's log filters
--- (Storage.queryAudit): its kind, a piece of its action, the contract it
--- names, the citizen id that acted, and a time range in os.time seconds.
--- A filter left out passes everything. One test for every backend, so a
--- page of the log reads the same whichever store keeps it.
---@param row table { ts, kind, action, actor_cid, contract_id }
---@param filter table|nil { kind, action, contract, actor, from, to }
---@return boolean
function Util.auditMatches(row, filter)
    if type(row) ~= 'table' then return false end
    if type(filter) ~= 'table' then return true end
    if filter.kind and row.kind ~= filter.kind then return false end
    if filter.contract and row.contract_id ~= filter.contract then return false end
    if filter.actor and row.actor_cid ~= filter.actor then return false end
    local ts = tonumber(row.ts) or 0
    if filter.from and ts < filter.from then return false end
    if filter.to and ts > filter.to then return false end
    -- A plain substring, never a pattern: the text comes from a staff
    -- member's search box, and a stray % or [ in it is not a request to
    -- run Lua pattern matching over the whole log.
    if filter.action and not tostring(row.action or ''):find(filter.action, 1, true) then
        return false
    end
    return true
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

--- The reason qbx_core is given for every balance change this resource
--- makes. It is what its money log and the banking resource's own records
--- show against the line; left out, they read "unknown", and staff looking
--- into a player's missing money had nothing to follow.
Util.MONEY_REASON = 'crimson-hitman'

--- Write a player's money to the database now, not at qbx_core's next save.
---
--- AddMoney and RemoveMoney change the player in memory only. qbx_core
--- writes them every updateInterval (five minutes as shipped) and when they
--- leave, while this resource writes its escrow at once. A hard crash in
--- between came back with the escrow on disk and the balance it was taken
--- from as it was before, and a refund later paid it a second time; or with
--- a payout marked settled here and gone from the balance it was paid into.
--- One upsert of the player's row narrows that to the write itself. Items
--- and dirty money are ox_inventory's, which has no save to call per
--- player, so their five minutes stay (README, after a crash).
---
--- Only an online player: one qbx_core holds offline is saved by AddMoney
--- itself. A Save that throws is not a payment that failed.
local function persist(player)
    -- The framework's own player object, never anything a client sent.
    local playerData = type(player) == 'table' and player.PlayerData
    local src = type(playerData) == 'table' and tonumber(playerData.source)
    if not src or player.Offline then return end
    pcall(function() exports.qbx_core:Save(src) end)
end

--- Take money from a player, refusing rather than overdrawing them.
---
--- RemoveMoney's return is not an affordability check. qbx_core applies its
--- floor only to the accounts listed in config.money.dontAllowMinus, which
--- ships as cash and crypto — bank is deliberately allowed to go negative,
--- the overdraft behaviour it inherited from QBCore. So
--- RemoveMoney('bank', n) returns true on an empty account and leaves the
--- player owing it.
---
--- Four call sites read that return as "could they pay?": buying out a
--- contract, buying informant data, and both anonymity fees. On a shipped
--- server every one of them succeeded on an empty bank. The escrow path was
--- never exposed, because it reads GetMoney through validate() before it
--- removes anything; these did not.
---
--- The balance is read first here, so this is right whatever an operator
--- has put in dontAllowMinus.
---
--- RemoveMoney runs inside pcall, as AddMoney does in Util.credit below.
--- qbx_core takes the money off before its update and log hooks run, so a
--- raise may come after the money moved. The balance read again decides:
--- down by the amount is paid, anything else is not. A raise that left
--- this function used to unwind its caller past the code that gives back
--- what it had already taken.
---@param player table qbx_core player
---@param account string
---@param amount number
---@return boolean paid
function Util.charge(player, account, amount)
    if not player or not player.Functions then return false end
    amount = tonumber(amount) or 0
    if amount <= 0 then return true end
    local before = tonumber(player.Functions.GetMoney(account)) or 0
    if before < amount then return false end
    local ran, removed = pcall(player.Functions.RemoveMoney, account, amount, Util.MONEY_REASON)
    if not ran then
        local read, after = pcall(player.Functions.GetMoney, account)
        removed = read and (tonumber(after) or 0) <= before - amount
    end
    if not removed then return false end
    persist(player)
    return true
end

--- Give money to a player, never letting a raise out, and say whether it
--- arrived.
---
--- Every caller already handles AddMoney returning false: the credit did
--- not happen, so the money is owed rather than lost. None of them handled
--- it throwing, and a patched AddMoney — a balance ceiling, a logging
--- wrapper, an anticheat — can do that on exactly the edge cases that
--- matter.
---
--- The difference destroys money. A buyout charges the target first and
--- pays the creator second; a refusal on that second step queues the
--- premium as owed, while a raise unwinds out of the function before the
--- queueing runs, and the target's payment is simply gone.
---
--- Found by breaking one call at a time under a conservation check rather
--- than by reading: 144 pairings of a broken dependency with an operation
--- that moves money, and this was the one that did not add up.
---
--- A raise is not always a credit that did not happen. qbx_core's AddMoney
--- adds to the balance first and only then saves, logs and emits its money
--- events, and for cash those set ox_inventory's 'money' item, which runs
--- AddItem, its hooks and a sync: any of them can raise after the money
--- moved. Read as "not credited", a payout like that stayed owed and was
--- paid again every thirty seconds and at every login. So the balance is
--- read before and, after a raise, again, as Util.charge does: up by the
--- amount is credited; unchanged is not; anything else (a read that fails,
--- or only part of it there) cannot be told apart from a payment, and the
--- caller is told so rather than left to try again blind. A balance that
--- cannot be read before is not credited at all: a raise could not be checked.
---@param player table qbx_core player
---@param account string
---@param amount number
---@return boolean credited
---@return string|nil raised the error, when AddMoney raised
---@return integer|nil arrived after a raise, how much reached the balance: 0
--- for none, nil when that could not be read
---@return integer|nil before the balance before the credit, after a raise
function Util.credit(player, account, amount)
    if not player or not player.Functions then return false end
    local read, before = pcall(player.Functions.GetMoney, account)
    before = read and tonumber(before) or nil
    if not before then return false end
    local ok, gave = pcall(player.Functions.AddMoney, account, amount, Util.MONEY_REASON)
    if ok then
        if not gave then return false end
        persist(player)
        return true
    end
    local readAfter, after = pcall(player.Functions.GetMoney, account)
    after = readAfter and tonumber(after) or nil
    local arrived = after and after - before or nil
    local credited = arrived ~= nil and arrived >= (tonumber(amount) or 0)
    if credited then persist(player) end
    return credited, tostring(gave), arrived, before
end

--- The client has no module loader — server/boot.lua's
--- CrimsonBoot.requireShared is a server-side stand-in for one — so the
--- client half reaches these helpers through a global. The file is listed
--- in client_scripts and loaded exactly once on each side, so there is still
--- only one clock per process.
CrimsonUtil = Util

return Util
