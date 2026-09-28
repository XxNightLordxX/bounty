--- Financial and conduct logging (§9.8, §14.31).
--- Writes are queued and flushed on a timer so no log write sits on a payout
--- path. Identity is recorded in full here regardless of anonymity — the log
--- is for staff, and anonymity was never meant to survive a dispute.

local Audit = {}

local Util = require_shared('util')

local Storage
local queue = {}
local head, tail = 1, 0
local dropped = 0

function Audit.init(storage)
    Storage = storage
    queue, head, tail, dropped = {}, 1, 0, 0
end

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
        actor_cid = actorCid, contract_id = contractId, detail = detail or {},
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

--- Mirror a line to a staff webhook.
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
    local url = Config.Audit.Webhook
    if not url or url == false or url == '' then return false end
    if Util.monotonicMs() < backoffUntil then return false end

    local lines, more, noise = {}, 0, 0
    for i = 1, #rows do
        local entry = rows[i]
        local kind = mirrored(entry)
        if kind == 'noise' then
            noise = noise + 1
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
function Audit.flush()
    -- An overflow is reported even when there is nothing else to write.
    if tail < head then
        if dropped > 0 then
            local count = dropped
            dropped = 0
            pcall(Storage.writeAudit, {
                ts = os.time(), kind = 'system', action = 'audit_overflow',
                detail = { dropped = count },
            })
        end
        return 0
    end

    local batch, first, last = queue, head, tail
    queue, head, tail = {}, 1, 0

    local written, drained = 0, {}
    for i = first, last do
        local entry = batch[i]
        if entry then
            if pcall(Storage.writeAudit, entry) then
                written = written + 1
            else
                dropped = dropped + 1
            end
            drained[#drained + 1] = entry
            batch[i] = nil
        end
    end
    pcall(mirrorBatch, drained)

    -- A silent drop is worse than a noisy one: if the queue overflowed, the
    -- server owner needs to know their log has gaps.
    if dropped > 0 then
        local count = dropped
        dropped = 0
        pcall(Storage.writeAudit, {
            ts = os.time(), kind = 'system', action = 'audit_overflow',
            detail = { dropped = count },
        })
    end

    return written
end

function Audit.pending() return math.max(0, tail - head + 1) end
function Audit.droppedCount() return dropped end

return Audit
