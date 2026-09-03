--- Financial and conduct logging (§9.8, §14.31).
--- Writes are queued and flushed on a timer so no log write sits on a payout
--- path. Identity is recorded in full here regardless of anonymity — the log
--- is for staff, and anonymity was never meant to survive a dispute.

local Audit = {}

local Storage
local queue = {}

function Audit.init(storage)
    Storage = storage
    queue = {}
end

local function push(kind, action, actorCid, contractId, detail)
    if #queue >= Config.Audit.MaxQueueSize then
        -- Drop the oldest rather than growing without bound; log the drop so
        -- a flood is visible rather than silent.
        table.remove(queue, 1)
    end
    queue[#queue + 1] = {
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
    if #queue == 0 then return 0 end
    local batch = queue
    queue = {}
    for i = 1, #batch do Storage.writeAudit(batch[i]) end
    return #batch
end

function Audit.pending() return #queue end

return Audit
