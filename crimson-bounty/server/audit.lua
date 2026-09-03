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

function Audit.flush()
    if tail < head then return 0 end

    local written = 0
    for i = head, tail do
        local entry = queue[i]
        if entry then
            Storage.writeAudit(entry)
            queue[i] = nil
            written = written + 1
        end
    end
    head, tail = 1, 0

    -- A silent drop is worse than a noisy one: if the queue overflowed, the
    -- server owner needs to know their log has gaps.
    if dropped > 0 then
        Storage.writeAudit({
            ts = os.time(), kind = 'system', action = 'audit_overflow',
            detail = { dropped = dropped },
        })
        dropped = 0
    end

    return written
end

function Audit.pending() return math.max(0, tail - head + 1) end
function Audit.droppedCount() return dropped end

return Audit
