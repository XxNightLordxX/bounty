--- Progression and reputation.
---
--- Two things live here: the per-player record the app shows, and the hook
--- that feeds a completed contract into the server's existing criminal
--- progression rather than making the bounty board a parallel economy.

local Progression = {}

local Storage, Identity, Audit

function Progression.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
end

--------------------------------------------------------------------------
-- Reputation
--------------------------------------------------------------------------

--- A hunter's record, as the app shows it.
---@param cid string
---@return table
function Progression.record(cid)
    local stats = Storage.readStats(cid)
    local completed = stats.completed or 0
    local failed = stats.failed or 0
    local total = completed + failed

    return {
        completed = completed,
        failed    = failed,
        placed    = stats.placed or 0,
        survived  = stats.survived or 0,
        -- Shown only once there is enough history for it to mean anything;
        -- a single completed contract is not a 100% record.
        rate      = total >= 3 and math.floor((completed / total) * 100) or nil,
        standing  = Progression.standing(completed, failed),
    }
end

--- A short label for the record. Deliberately vague at the low end: a new
--- hunter should not be visibly marked as one.
function Progression.standing(completed, failed)
    if completed >= 50 then return 'Notorious' end
    if completed >= 20 then return 'Established' end
    if completed >= 5  then return 'Known' end
    return 'Unproven'
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

function Progression.onContractPlaced(cid)
    Storage.bumpStat(cid, 'placed')
end

--- A hunter finished a contract. This is where the bounty board pays into
--- the server's wider criminal progression.
---@param cid string
---@param fulfilment string
function Progression.onCompleted(cid, fulfilment)
    Storage.bumpStat(cid, 'completed')

    if not Config.Progression.Enabled then return end

    local amount = fulfilment == CB.FULFILMENT.KIDNAPPING
        and Config.Progression.TrustPerKidnapping
        or Config.Progression.TrustPerElimination

    if not amount or amount <= 0 then return end

    local resource = Config.Progression.Resource
    if not resource or GetResourceState(resource) ~= 'started' then return end

    -- A progression resource being absent or shaped differently must never
    -- break a payout that has already happened.
    local ok, err = pcall(function()
        exports[resource]:AddTrust(cid, amount)
    end)

    if ok then
        Audit.action('progression_awarded', cid, nil, { amount = amount, fulfilment = fulfilment })
    else
        Audit.rejected('progression_failed', cid, nil, { error = tostring(err) })
    end
end

function Progression.onFailed(cid)
    Storage.bumpStat(cid, 'failed')
end

--- The target outlived the contract: bought out, expired, or cancelled.
function Progression.onSurvived(cid)
    Storage.bumpStat(cid, 'survived')
end

return Progression
