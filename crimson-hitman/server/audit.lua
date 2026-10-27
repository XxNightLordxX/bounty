--- Financial and conduct logging (§9.8, §14.31).
--- Writes are queued and flushed on a timer so no log write sits on a payout
--- path. Identity is recorded in full here regardless of anonymity — the log
--- is for staff, and anonymity was never meant to survive a dispute.

local Audit = {}

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Storage
local queue = {}
local head, tail = 1, 0
local dropped = 0
--- Rows whose write the database never answered (mysql): each may or may
--- not be in the log, and is not sent again. /ch-diag says how many.
local unconfirmed = 0

--- Rows per INSERT where the store can write several at once (mysql).
local BATCH_ROWS = 200

--------------------------------------------------------------------------
-- Kept on this machine across a stop (resource KVP)
--------------------------------------------------------------------------

--- A stop while the database is not answering (mysql) cannot hand the queue
--- to oxmysql: a statement it cannot send is never run and never comes back
--- (docs/oxmysql.md §6, §7), and every queued row, financial ones among them, was
--- lost on the restart staff make for an outage. So the queue goes to
--- FXServer's KVP store instead, `auditKept:<mode>:<n>`, KEPT_CHUNK rows a
--- key, and the next start in that mode puts it back at the front of the
--- queue, each row with its own time.
local KEPT = 'auditKept:'
local KEPT_CHUNK = 200

--- The keys this start put back into the queue: deleted once a flush has
--- written their rows, or a stop has handed them on.
local keptKeys = {}

---@param mode string|nil
---@return string
local function keptPrefix(mode)
    return KEPT .. tostring(mode or Config.Database.Mode) .. ':'
end

--- This mode's kept keys, in the order they were written.
---@return string[]
local function keptInOrder()
    local keys = {}
    if type(StartFindKvp) ~= 'function' or type(FindKvp) ~= 'function' then return keys end
    local prefix = keptPrefix()
    local ok, handle = pcall(StartFindKvp, prefix)
    if not ok or not handle or handle == -1 then return keys end
    while true do
        local key = FindKvp(handle)
        if not key then break end
        if tonumber(key:sub(#prefix + 1)) then keys[#keys + 1] = key end
    end
    if type(EndFindKvp) == 'function' then pcall(EndFindKvp, handle) end
    table.sort(keys, function(a, b)
        return tonumber(a:sub(#prefix + 1)) < tonumber(b:sub(#prefix + 1))
    end)
    return keys
end

local function forgetKept()
    if type(DeleteResourceKvp) == 'function' then
        for i = 1, #keptKeys do pcall(DeleteResourceKvp, keptKeys[i]) end
    end
    keptKeys = {}
end

function Audit.init(storage)
    Storage = storage
    queue, head, tail, dropped, unconfirmed, keptKeys = {}, 1, 0, 0, 0, {}
    -- What a stop kept on this machine for this mode, written by the next
    -- flush that can (Audit.flush).
    for _, key in ipairs(keptInOrder()) do
        keptKeys[#keptKeys + 1] = key
        local text = type(GetResourceKvpString) == 'function' and GetResourceKvpString(key) or nil
        local decoded, rows = pcall(json.decode, text or '')
        for _, row in ipairs(decoded and type(rows) == 'table' and rows or {}) do
            if type(row) == 'table' and row.action then
                row.detail = type(row.detail) == 'table' and row.detail or {}
                tail = tail + 1
                queue[tail] = row
            end
        end
    end
end

--- Detail fields that hold an error's text, at any depth (and any key that
--- ends in `_error`).
local ERROR_KEYS = { error = true, err = true }

--- A row's detail with every error's text as it is kept (Util.dbError): the
--- server's own words and the start of the statement, never the values it
--- was sent. oxmysql's message carries every parameter as JSON, and a write
--- of a contract sends the client's citizen id, licence and name with it:
--- kept whole, an anonymous client was named to every staff member who read
--- the log, the contract's timeline or the review history. Cleaned here, in
--- the one place every row passes, so no caller can keep one whole; the
--- console still prints the whole of it where it was raised. Copied where it
--- changes, never the caller's table.
---@param detail any
---@param depth integer|nil
---@return any
local function cleaned(detail, depth)
    if type(detail) ~= 'table' or (depth or 0) > 3 then return detail end
    local out
    for key, value in pairs(detail) do
        local clean = value
        if type(value) == 'string' and (ERROR_KEYS[key]
            or (type(key) == 'string' and key:find('_error$') ~= nil)) then
            clean = Util.dbError(value)
        elseif type(value) == 'table' then
            clean = cleaned(value, (depth or 0) + 1)
        end
        if clean ~= value then
            if not out then
                out = {}
                for k, v in pairs(detail) do out[k] = v end
            end
            out[key] = clean
        end
    end
    return out or detail
end

--- The same, for a row already in the store: one written before its error
--- was cleaned here still holds the values, and the admin panel shows staff
--- who may not see who is behind an anonymous party the cleaned form.
Audit.cleaned = cleaned

--- Append to the queue.
---
--- Eviction advances a head index rather than shifting the whole table:
--- table.remove(queue, 1) is O(n), which turns a flood of rejected events
--- into quadratic work at exactly the moment the server is under load.
local function push(kind, action, actorCid, contractId, detail)
    -- At least one. A size of 0 moved the head past every row as it was
    -- pushed, so flush found nothing, not even the overflow row, and the
    -- log went silent while the rows it never wrote stayed in memory.
    local cap = math.max(1, math.floor(tonumber(Config.Audit.MaxQueueSize) or 5000))
    if (tail - head + 1) >= cap then
        queue[head] = nil
        head = head + 1
        dropped = dropped + 1
    end

    tail = tail + 1
    queue[tail] = {
        ts = os.time(), kind = kind, action = action,
        actor_cid = actorCid, contract_id = contractId, detail = cleaned(detail) or {},
    }
end

--- Money moved. Always logged, even when Config.Audit.LogAllActions is off.
function Audit.financial(action, actorCid, contractId, detail)
    push('financial', action, actorCid, contractId, detail)
end

--- A staff member acted. Always logged, whatever Config.Audit.LogAllActions
--- says: that switch is there to keep ordinary player conduct out of a busy
--- log, and a staff write is not ordinary player conduct. An unmasking or a
--- server-wide timer reset that vanishes because a switch is off is the one
--- row somebody reviewing the server later actually needs.
function Audit.staff(action, actorCid, contractId, detail)
    push('conduct', action, actorCid, contractId, detail)
end

--- Player conduct: creations, acceptances, rejected claims, blocked attempts.
function Audit.action(action, actorCid, contractId, detail)
    if not Config.Audit.LogAllActions then return end
    push('conduct', action, actorCid, contractId, detail)
end

--- A rejected exploit attempt. Always logged — these are the rows a server
--- owner actually needs when deciding whether someone is probing the script.
function Audit.rejected(action, actorCid, contractId, detail)
    push('rejected', action, actorCid, contractId, detail)
end

--- Hits on a target whose damage never showed, or showed and could not be
--- put down to one shooter: every round into somebody already down, every
--- second gun in a fight. Routine in any firefight on a target, and listed
--- they buried the lines the channel is for. Counted with the rest of the
--- noise; the rows themselves are still in the log.
local DAMAGE_NOISE = {
    damage_unsupported = true, damage_ambiguous = true, damage_unattributed = true,
}

--- Mirror a line to the staff webhook (the crimson_hitman_webhook convar).
---
--- Identity is deliberately absent: the webhook is a heads-up that something
--- happened, and anything sent to a third party outlives the server's own
--- retention rules. The full record stays in the database, where staff can
--- look it up under the ACE that gates identity lookups.
--- Whether a row is one the webhook carries.
local function mirrored(entry)
    if entry.kind ~= 'rejected' and entry.kind ~= 'financial' then return false end
    -- Refusal noise is counted, not listed: a player hammering a button
    -- would otherwise fill the channel with the same line.
    local action = tostring(entry.action or '')
    if action:sub(1, 10) == 'ratelimit_' or action:sub(1, 6) == 'flood_'
        or action:sub(1, 5) == 'gate_' then
        return 'noise'
    end
    if DAMAGE_NOISE[action] then return 'hit' end
    return true
end

-- Held back after Discord answers 429, until this moment.
local backoffUntil = 0
local MAX_LINES, MAX_CHARS = 15, 1900

--- One POST per flush, however many rows it drained.
---
--- It sent one per row. Discord takes about five requests every two seconds
--- per webhook and answers the rest with 429; enough of those and its edge
--- bans the server's address for every integration on the box, not only
--- this one. A single message carries the flush: up to fifteen lines, then
--- how many more, with the refusal noise as a count.
local function mirrorBatch(rows)
    -- A server convar, never config.lua. That file is a shared script, so
    -- every player's game downloads it, and a URL written there let anyone
    -- post forged lines into the staff channel or delete the hook. `set`
    -- keeps a convar on the server; `setr` would send it to every player
    -- too, so the README says set. Read on every flush, so it can be
    -- changed from the console without a restart.
    local url = GetConvar('crimson_hitman_webhook', '')
    if type(url) ~= 'string' or url == '' then return false end
    if Util.monotonicMs() < backoffUntil then return false end

    local lines, more, noise, hits = {}, 0, 0, 0
    for i = 1, #rows do
        local entry = rows[i]
        local kind = mirrored(entry)
        if kind == 'noise' then
            noise = noise + 1
        elseif kind == 'hit' then
            hits = hits + 1
        elseif kind then
            if #lines < MAX_LINES then
                lines[#lines + 1] = ('`%s` · %s · contract %s'):format(
                    entry.kind, entry.action, entry.contract_id or 'n/a')
            else
                more = more + 1
            end
        end
    end
    if more > 0 then lines[#lines + 1] = ('…and %d more'):format(more) end
    if noise > 0 then lines[#lines + 1] = ('%d refused request(s)'):format(noise) end
    if hits > 0 then lines[#lines + 1] = ('%d hit(s) on targets not confirmed'):format(hits) end
    if #lines == 0 then return false end

    local content = table.concat(lines, '\n')
    if #content > MAX_CHARS then content = content:sub(1, MAX_CHARS) end

    PerformHttpRequest(url, function(status, _, headers)
        if tonumber(status) == 429 then
            local wait = headers and tonumber(headers['Retry-After'] or headers['retry-after']) or 5
            backoffUntil = Util.monotonicMs() + math.max(1, wait) * 1000
        end
    end, 'POST', json.encode({ content = content }),
        { ['Content-Type'] = 'application/json' })
    return true
end

--- Drain the queue.
---
--- Every write is guarded, and the queue is emptied whatever happens. A row
--- the database will not take — a connection that has gone away, a detail a
--- future caller managed to make unencodable — used to throw out of here
--- with the queue still holding it, so the next flush hit the same row and
--- threw again, forever. The tick that calls this runs the audit flush
--- first, so that one row also stopped amendment expiry, the bailout queue,
--- contract expiry and the storage flush: the resource kept running and
--- quietly did nothing.
---
--- A row that will not write is counted as dropped, which is reported.
---
--- The queue is detached before the first write. On mysql every write is an
--- await, and anything that happens while it waits pushes onto the queue:
--- the loop's bounds were fixed when it started, and resetting head and tail
--- afterwards orphaned every row pushed in between — never written, never
--- counted as dropped. A second flush started meanwhile (the staff commands
--- flush before they read) walked the same rows and wrote them twice.
---
--- `stopping` is the resource going away. A backend whose writes wait for a
--- database answer (mysql) hands each row over without waiting instead
--- (writeAuditNoWait): waiting there yields the stop handler, and nothing
--- resumes it before this resource's Lua is torn down.
---
--- A store that is not answering (mysql: Storage.healthy) keeps its rows
--- queued rather than sending them into the outage, bounded by
--- Config.Audit.MaxQueueSize as ever, and at a stop keeps them on this
--- machine for the next start (spill). A batch the store never sent goes
--- back to the front of the queue in order; one sent and never answered may
--- have been written, so it is not sent again but counted
--- (Audit.unconfirmed). Either way the flush stops there, and what it had
--- not reached goes back too.
---@param stopping boolean|nil
function Audit.flush(stopping)
    if Storage.healthy and not Storage.healthy() then
        if not stopping then return 0 end
        if type(SetResourceKvp) == 'function' then return Audit.spill() end
    end
    local write = (stopping and Storage.writeAuditNoWait) or Storage.writeAudit

    -- An overflow is reported even when there is nothing else to write.
    if tail < head then
        if dropped > 0 then
            local count = dropped
            dropped = 0
            pcall(write, {
                ts = os.time(), kind = 'system', action = 'audit_overflow',
                detail = { dropped = count },
            })
        end
        return 0
    end

    local batch, first, last = queue, head, tail
    queue, head, tail = {}, 1, 0

    local drained = {}
    for i = first, last do
        local entry = batch[i]
        if entry then
            drained[#drained + 1] = entry
            batch[i] = nil
        end
    end

    local written = 0
    -- Where the flush stopped on a database that did not answer: the rows
    -- from here on go back to the front of the queue.
    local stoppedAt
    local function unanswered(err)
        return Storage.timedOut and Storage.timedOut(err)
    end
    --- One row on its own; false when the store did not answer it.
    local function one(entry)
        local ok, err = pcall(write, entry)
        if ok then
            written = written + 1
        elseif Storage.notSent and Storage.notSent(err) then
            return false
        elseif unanswered(err) then
            unconfirmed = unconfirmed + 1
            return false, true
        else
            dropped = dropped + 1
        end
        return true
    end

    -- Many rows a statement where the store can (mysql: one awaited round
    -- trip a row held up every job behind this one). A batch the store
    -- refuses wrote none of itself, so its rows go one at a time, and only
    -- the row that will not write is dropped. Not at a stop: those rows are
    -- handed over without waiting, one by one (writeAuditNoWait).
    local several = not stopping and Storage.writeAuditBatch or nil
    if several then
        for from = 1, #drained, BATCH_ROWS do
            local last = math.min(#drained, from + BATCH_ROWS - 1)
            local chunk = table.move(drained, from, last, 1, {})
            local ok, err = pcall(several, chunk)
            if ok then
                written = written + #chunk
            elseif Storage.notSent and Storage.notSent(err) then
                stoppedAt = from
            elseif unanswered(err) then
                unconfirmed = unconfirmed + #chunk
                stoppedAt = last + 1
            else
                for k = 1, #chunk do
                    local went, sent = one(chunk[k])
                    if not went then
                        stoppedAt = from + k - (sent and 0 or 1)
                        break
                    end
                end
            end
            if stoppedAt then break end
        end
    else
        for k = 1, #drained do
            local went, sent = one(drained[k])
            if not went then
                stoppedAt = k + (sent and 1 or 0)
                break
            end
        end
    end

    if stoppedAt then
        -- In order, ahead of anything pushed meanwhile, and held to the
        -- queue's size as push holds it: the oldest go first.
        for i = #drained, stoppedAt, -1 do
            head = head - 1
            queue[head] = drained[i]
        end
        local cap = math.max(1, math.floor(tonumber(Config.Audit.MaxQueueSize) or 5000))
        while (tail - head + 1) > cap do
            queue[head] = nil
            head = head + 1
            dropped = dropped + 1
        end
        for i = #drained, stoppedAt, -1 do drained[i] = nil end
        pcall(mirrorBatch, drained)
        return written
    end
    pcall(mirrorBatch, drained)
    -- Every row this start put back from the last stop has been through a
    -- flush that ran to the end, or been handed on at this one.
    if #keptKeys > 0 then forgetKept() end

    -- A silent drop is worse than a noisy one: if the queue overflowed, the
    -- server owner needs to know their log has gaps.
    if dropped > 0 then
        local count = dropped
        dropped = 0
        pcall(write, {
            ts = os.time(), kind = 'system', action = 'audit_overflow',
            detail = { dropped = count },
        })
    end

    return written
end

--- At a stop with the store not answering (Audit.flush): the queue, financial
--- rows first, to this machine's KVP store in chunks of KEPT_CHUNK, for the
--- next start in this mode (Audit.init). What this start had put back from
--- the last stop is in the queue still, so its keys are replaced. Without
--- KVP here the flush hands the rows over as before (writeAuditNoWait).
---@return integer kept
function Audit.spill()
    local rows = {}
    for i = head, tail do
        if queue[i] and queue[i].kind == 'financial' then rows[#rows + 1] = queue[i] end
    end
    for i = head, tail do
        if queue[i] and queue[i].kind ~= 'financial' then rows[#rows + 1] = queue[i] end
    end
    if dropped > 0 then
        rows[#rows + 1] = { ts = os.time(), kind = 'system', action = 'audit_overflow',
                            detail = { dropped = dropped } }
    end
    queue, head, tail, dropped = {}, 1, 0, 0
    forgetKept()

    local cap = math.max(1, math.floor(tonumber(Config.Audit.MaxQueueSize) or 5000))
    local kept, n = 0, 0
    for from = 1, math.min(#rows, cap), KEPT_CHUNK do
        local chunk = table.move(rows, from, math.min(#rows, cap, from + KEPT_CHUNK - 1), 1, {})
        local encoded, text = pcall(json.encode, chunk)
        n = n + 1
        if encoded and pcall(SetResourceKvp, keptPrefix() .. n, text) then kept = kept + #chunk end
    end
    if kept > 0 then
        Log.debug(('the database is not answering at this stop: %d audit row(s) are kept on this '
            .. 'machine and written at the next start'):format(kept))
    end
    return kept
end

function Audit.pending() return math.max(0, tail - head + 1) end
function Audit.droppedCount() return dropped end
--- Rows sent to the store that it never answered (mysql): they may be
--- missing from the log.
function Audit.unconfirmed() return unconfirmed end

return Audit
