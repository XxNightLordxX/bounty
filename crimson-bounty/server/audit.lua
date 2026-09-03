--- Financial and conduct logging (§9.8, §14.31).
--- Writes are queued and flushed on a timer so no log write sits on a payout
--- path. Identity is recorded in full here regardless of anonymity — the log
--- is for staff, and anonymity was never meant to survive a dispute.

local Audit = {}

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
    if (tail - head + 1) >= Config.Audit.MaxQueueSize then
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
local function mirror(entry)
    local url = Config.Audit.Webhook
    if not url or url == false or url == '' then return false end
    if entry.kind ~= 'rejected' and entry.kind ~= 'financial' then return false end

    local body = json.encode({
        content = ('`%s` · %s · contract %s'):format(
            entry.kind, entry.action, entry.contract_id or 'n/a'),
    })

    PerformHttpRequest(url, function() end, 'POST', body,
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
function Audit.flush()
    if tail < head then return 0 end

    local written = 0
    for i = head, tail do
        local entry = queue[i]
        if entry then
            if pcall(Storage.writeAudit, entry) then
                written = written + 1
            else
                dropped = dropped + 1
            end
            pcall(mirror, entry)
            queue[i] = nil
        end
    end
    head, tail = 1, 0

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
