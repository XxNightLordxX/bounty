--- Outbound player notifications (§7.3) and the law enforcement threat
--- advisory (§7.5).
---
--- Every send passes a per-recipient budget so a contract storm cannot be
--- used to flood phones (§14.40).

local Notify = {}

local Identity
local budgets = {}
local advisorySent = {}

function Notify.init(deps)
    Identity = deps.identity
    budgets, advisorySent = {}, {}
end

local function withinBudget(cid)
    local bucket = budgets[cid]
    local now = os.time()
    if not bucket or now - bucket.minuteStart >= 60 then
        bucket = { minuteStart = now, minute = 0, hourStart = bucket and bucket.hourStart or now, hour = bucket and bucket.hour or 0 }
        budgets[cid] = bucket
    end
    if now - bucket.hourStart >= 3600 then
        bucket.hourStart, bucket.hour = now, 0
    end
    if bucket.minute >= Config.Notifications.MaxPerRecipientPerMinute then return false end
    if bucket.hour >= Config.Notifications.MaxPerRecipientPerHour then return false end
    bucket.minute = bucket.minute + 1
    bucket.hour = bucket.hour + 1
    return true
end

--- Send to one player by citizen id. Silently no-ops when they are offline.
---
--- lb-phone's SendNotification is a *client* export — there is no server-side
--- equivalent — so the server hands the notification to that player's client,
--- which calls the export locally.
function Notify.toCitizen(cid, title, content, opts)
    if not cid then return false end
    if not (opts and opts.bypassBudget) and not withinBudget(cid) then return false end

    local actor = Identity.byCitizenId(cid)
    if not actor then return false end

    TriggerClientEvent('crimson-bounty:notify', actor.source, {
        title = title,
        content = content,
    })
    return true
end

--------------------------------------------------------------------------
-- Contract lifecycle notifications
--------------------------------------------------------------------------

function Notify.contractCreated(contract, targetActor)
    -- The target's paranoid alert. Deliberately vague: it tells them
    -- something is wrong, not who or how much.
    if Config.Notifications.ParanoidAlert and not contract.target_protected then
        Notify.toCitizen(contract.target_cid, 'Unsettling',
            'You feel eyes on you. A price has been put on your head.')
    end

    if contract.target_protected then
        Notify.advisory(contract, 'posted', targetActor)
    end
end

function Notify.contractAccepted(contract, hunterRecord, activeHunters)
    local who = hunterRecord.anon and 'an operative' or hunterRecord.hunter_name
    Notify.toCitizen(contract.creator_cid, 'Contract accepted',
        ('Your contract on %s has been accepted by %s. %d operative%s now active.')
            :format(contract.target_name, who, activeHunters, activeHunters == 1 and ' is' or 's are'))

    -- Every acceptance raises an advisory carrying the running count, so law
    -- enforcement can judge the scale of the threat and not just its
    -- existence. The per-contract hunter cap bounds the total (§7.5).
    if contract.target_protected then
        Notify.advisory(contract, 'accepted', activeHunters)
    end
end

function Notify.contractCompleted(contract, hunterRecord, photoRef)
    Notify.toCitizen(contract.creator_cid, 'Contract fulfilled',
        'Contract Fulfilled. Verification photo attached. Check your archives.')
end

--------------------------------------------------------------------------
-- Law enforcement threat advisory (§7.5)
--------------------------------------------------------------------------

--- Advise every online law enforcement player, and the officer themselves,
--- that a contract exists or has gone live.
---
--- The creator is never named, even when they are not anonymous: the advisory
--- says a threat exists and who it is against. Finding out who ordered it is
--- police work.
---@param contract table
---@param stage string 'posted' | 'accepted'
---@param activeHunters integer|nil count of hunters now on the contract
function Notify.advisory(contract, stage, activeHunters)
    if not Config.Advisory.Enabled then return end
    if stage == 'posted' and not Config.Advisory.OnCreate then return end
    if stage == 'accepted' and not Config.Advisory.OnAccept then return end

    -- One advisory per contract per stage; acceptances are keyed by count so
    -- each new operative raises exactly one bulletin.
    local key = contract.id .. ':' .. stage .. ':' .. tostring(activeHunters or 0)
    if advisorySent[key] then return end
    advisorySent[key] = true

    local rank = contract.target_job and (contract.target_job:upper() .. ' ') or ''
    local title, content

    if stage == 'posted' then
        title = 'THREAT ADVISORY'
        content = ('A contract has been placed on %s%s.'):format(rank, contract.target_name)
    else
        title = 'THREAT ADVISORY — ACTIVE'
        local n = activeHunters or 1
        content = ('The contract on %s%s has been accepted. %d operative%s active.')
            :format(rank, contract.target_name, n, n == 1 and ' is' or 's are')
    end

    local recipients = 0
    local online = Identity.online()
    for i = 1, #online do
        local actor = online[i]
        -- The targeted officer is skipped here: they are law enforcement and
        -- would otherwise match the recipient filter, receiving both this
        -- broadcast and their own direct alert below.
        if actor.cid ~= contract.target_cid and Identity.isAdvisoryRecipient(actor.job) then
            Notify.toCitizen(actor.cid, title, content, { bypassBudget = true })
            recipients = recipients + 1
        end
    end

    -- The targeted officer cannot open the app to check for themselves, so
    -- they are told directly whatever the paranoid-alert setting says.
    if Config.Advisory.AlwaysAlertTarget then
        Notify.toCitizen(contract.target_cid, title,
            stage == 'posted'
                and 'A contract has been placed on you. Your department has been advised.'
                or  ('The contract on you has been accepted. %d operative%s active.')
                        :format(activeHunters or 1, (activeHunters or 1) == 1 and ' is' or 's are'),
            { bypassBudget = true })
    end

    -- The same advisory goes to dispatch so it lands in the MDT alongside
    -- other calls, not just on phones.
    if Config.Advisory.UseDispatch and GetResourceState('sc-dispatch') == 'started' then
        pcall(function()
            exports['sc-dispatch']:AddNotification({
                title = title,
                message = content,
                priority = Config.Advisory.DispatchPriority,
                caller = 'Criminal Intelligence',
                job_table = { 'police', 'sheriff', 'bcso', 'fib', 'trooper', 'sasp' },
                unique_id = 'cb-' .. contract.id .. '-' .. stage,
            })
        end)
    end

    return recipients
end

function Notify.clearContract(contractId)
    for key in pairs(advisorySent) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then advisorySent[key] = nil end
    end
end

return Notify
