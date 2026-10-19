--- Outbound player notifications (§7.3) and the law enforcement threat
--- advisory (§7.5).
---
--- Every send passes a per-recipient budget so a contract storm cannot be
--- used to flood phones (§14.40).

local Notify = {}

local Util = require_shared('util')

local Identity
local budgets = {}
local advisorySent = {}

--- [cid] = { { title, content, opts }, ... } kept for a player who was
--- offline when one of their contracts ended. See tellOrKeep.
local waiting = {}

--- How many a player can have waiting. Enough for every contract they could
--- be on; past it the oldest goes, so the table stays bounded however long
--- somebody stays away.
local WAITING_CAP = 10

--- [cid] = os.time() of the last push, so a burst of state changes on one
--- contract does not become a burst of refreshes.
local lastPush = {}

--- [cid] = the push held back by the floor, waiting to go: the reason it
--- will carry, and the contracts the pushes it stands for were about.
--- { reason = string, ids = { [contractId] = true }, all = boolean }
local trailing = {}

--- [cid] = os.time() before which that target's paranoid alert is not sent
--- again (Config.Notifications.ParanoidCooldownMinutes).
local paranoidUntil = {}

function Notify.init(deps)
    Identity = deps.identity
    budgets, advisorySent = {}, {}
    lastPush, trailing = {}, {}
    waiting = {}
    paranoidUntil = {}
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
---
--- opts.muted: the recipient muted the thread this came from (§11.4). It is
--- charged to their budget exactly as a sent one is, and then not sent.
--- Left uncharged, a muted thread would leave room in the budget that an
--- unmuted one fills, and the next notice — a call request, whose sender is
--- told when it could not get through — would tell the sender which it was.
function Notify.toCitizen(cid, title, content, opts)
    if not cid then return false end
    if not (opts and opts.bypassBudget) and not withinBudget(cid) then return false end
    if opts and opts.muted then return false end

    local actor = Identity.byCitizenId(cid)
    if not actor then return false end

    TriggerClientEvent('crimson-hitman:notify', actor.source, {
        title = title,
        content = content,
    })
    return true
end

--------------------------------------------------------------------------
-- App pushes
--------------------------------------------------------------------------
--
-- A phone notification tells a player something happened; it does not move
-- an app they already have open. The app deliberately refreshes only on an
-- unsolicited push, because refreshing on every mirrored reply was an
-- exponential storm — so nothing sending a push meant a creator watching
-- their own contract never saw it get accepted.
--
-- A push carries no contract data, only a reason and which contracts it is
-- about. The app re-reads through the normal projections, so a push can
-- never become a channel that leaks what a projection would have withheld.
--
-- The ids are so the page re-reads only those contracts' proposals: every
-- push re-read every one, three placed and three taken were nine reads from
-- the bucket the board, Mine and the ledger share, and a few acceptances in
-- a row ran an open Mine tab into its own rate limit. An id goes only to a
-- player who already has it — the client who placed the contract, and a
-- hitman who took it — and never to the target (Notify.pushParties), who is
-- not told which contract, or that one exists, by anything but the
-- projection they are shown.

--- Send it now, or hold it behind the floor.
---@param ids table<string, boolean> the contracts it is about
---@param all boolean about something that names no contract
local function deliver(cid, reason, ids, all)
    if not cid or not Config.Notifications.PushEnabled then return false end

    local now = os.time()
    local last = lastPush[cid]
    local floor = Config.Notifications.PushMinIntervalSeconds or 1
    if last and (now - last) < floor then
        -- Held back, not dropped. The app refreshes on the push it already
        -- got, and that refresh can read the contract before this change
        -- lands — two hitmen accepting in the same second left the
        -- creator's open card showing one operative until something else
        -- happened to change. One push goes once the floor has passed, so a
        -- burst still costs one refresh after the first, and the last word
        -- is always seen.
        local held = trailing[cid]
        if not held then
            held = { reason = reason, ids = {}, all = false }
            trailing[cid] = held
            SetTimeout(math.max(1, floor - (now - last)) * 1000, function()
                local due = trailing[cid]
                trailing[cid] = nil
                -- Due by now: the timer waits out the rest of the floor.
                if due then deliver(cid, due.reason, due.ids, due.all) end
            end)
        -- A message re-reads only the thread on the page, and anything else
        -- re-reads the thread as well. So a message held behind an
        -- acceptance must not take its place: the creator's card never
        -- showed the new operative.
        elseif not (reason == 'message' and held.reason ~= 'message') then
            held.reason = reason
        end
        -- One push stands for the whole burst, so it is about every
        -- contract any of them was about, and about everything once any of
        -- them named none.
        for id in pairs(ids) do held.ids[id] = true end
        held.all = held.all or all
        return false
    end

    local actor = Identity.byCitizenId(cid)
    if not actor then return false end

    lastPush[cid] = now
    local payload = { reason = reason }
    -- No ids is "everything": the page re-reads every contract's
    -- proposals, as it did before pushes named any.
    if not all then
        local list = {}
        for id in pairs(ids) do list[#list + 1] = id end
        if #list > 0 then
            table.sort(list)
            payload.ids = list
        end
    end
    TriggerClientEvent('crimson-hitman:push', actor.source, payload)
    return true
end

--- Nudge one player's open app.
---
--- contractId is the contract it is about, and only for a player who
--- already knows that contract's id. Left out, the page re-reads every
--- contract; a message names none and needs none, since the page re-reads
--- only the open thread for it.
---@param cid string
---@param reason string what changed, for the app's own logging
---@param contractId string|nil
---@return boolean sent
function Notify.push(cid, reason, contractId)
    local ids = {}
    if contractId then ids[contractId] = true end
    return deliver(cid, reason, ids, contractId == nil and reason ~= 'message')
end

--- Nudge every party to a contract. Used on the four transitions that change
--- what a card should say: accepted, settled, bought out, expired.
---@param contract table
---@param hitmanCids string[]|nil
---@param reason string
function Notify.pushParties(contract, hitmanCids, reason)
    if not contract then return 0 end

    local seen, sent = {}, 0
    local function nudge(cid, contractId)
        if not cid or seen[cid] then return end
        seen[cid] = true
        if Notify.push(cid, reason, contractId) then sent = sent + 1 end
    end

    -- The target's push names no contract. Their page re-reads everything,
    -- as every push used to make it, and learns nothing from the push that
    -- the projection it reads does not already show them.
    nudge(contract.creator_cid, contract.id)
    nudge(contract.target_cid)
    for i = 1, #(hitmanCids or {}) do nudge(hitmanCids[i], contract.id) end

    return sent
end

function Notify.clearPush(cid)
    lastPush[cid] = nil
    trailing[cid] = nil
end

--------------------------------------------------------------------------
-- Contract lifecycle notifications
--------------------------------------------------------------------------

function Notify.contractCreated(contract, targetActor)
    -- The target's paranoid alert. Deliberately vague: it tells them
    -- something is wrong, not who or how much.
    -- An officer is told by the posting bulletin instead, unless none goes.
    if Config.Notifications.ParanoidAlert
        and (not contract.target_protected or not Notify.advises('posted')) then
        Notify.paranoid(contract.target_cid)
    end

    if contract.target_protected then
        Notify.advisory(contract, 'posted', targetActor)
    end
end

--- The target's alert, some minutes after the placement and once per
--- cooldown (§14.40).
---
--- It went the second the contract was placed, so the one person never
--- told who the client is, and the most eager to find out, learned to the
--- second when they were online and acting. Everything else dates a
--- placement only roughly (Util.roundClock). And it went once per
--- contract, so the count of alerts was the count of people paying.
---@param targetCid string
function Notify.paranoid(targetCid)
    local now = os.time()
    if (paranoidUntil[targetCid] or 0) > now then return end
    paranoidUntil[targetCid] = now
        + math.max(0, (tonumber(Config.Notifications.ParanoidCooldownMinutes) or 0) * 60)

    local jitter = type(Config.Notifications.ParanoidAlertJitter) == 'table'
        and Config.Notifications.ParanoidAlertJitter or {}
    local low = math.max(0, math.floor(tonumber(jitter.min) or 0))
    local high = math.max(low, math.floor(tonumber(jitter.max) or 0))

    local function send()
        Notify.toCitizen(targetCid, 'Unsettling',
            'You feel eyes on you. A price has been put on your head.')
    end
    if high <= 0 then return send() end
    SetTimeout(math.random(low, high) * 1000, send)
end

function Notify.contractAccepted(contract, hitmanRecord, activeHitmen)
    local who = hitmanRecord.anon and 'an operative' or hitmanRecord.hitman_name
    Notify.toCitizen(contract.creator_cid, 'Contract accepted',
        ('Your contract on %s has been accepted by %s. %d operative%s now active.')
            :format(contract.target_name, who, activeHitmen, activeHitmen == 1 and ' is' or 's are'))

    -- Every acceptance raises an advisory carrying the running count, so law
    -- enforcement can judge the scale of the threat and not just its
    -- existence. The per-contract hitman cap bounds the total (§7.5).
    if contract.target_protected then
        Notify.advisory(contract, 'accepted', activeHitmen, hitmanRecord.hitman_cid)
    end

    -- The creator's own card now shows one more operative, and the hitman's
    -- Mine tab has a contract in it that was not there a moment ago. The
    -- target is deliberately not pushed: they are not told a contract exists
    -- unless the paranoid alert or an advisory tells them.
    Notify.push(contract.creator_cid, 'accepted', contract.id)
    Notify.push(hitmanRecord.hitman_cid, 'accepted', contract.id)
end

--- Tell the creator their contract was fulfilled.
---
--- The photograph is mentioned only when there is one. This took photoRef and
--- never read it: the body was a single hardcoded string promising a
--- verification photo, and the live-delivery route passes nil because a
--- handover has no photograph to take. So the creator of every delivery was
--- sent to an archive row with nothing attached — which reads as the archive
--- having lost the picture rather than as there never having been one.
---@param contract table
---@param hitmanRecord table|nil
---@param photoRef string|nil the proof image, where the route produced one
---@param result table|nil the claim's own answer (Contracts.claimSlot)
function Notify.contractCompleted(contract, hitmanRecord, photoRef, result)
    local hasPhoto = type(photoRef) == 'string' and photoRef ~= ''
    -- A receipt, so outside the budget (§14.40). Relay messages spend the
    -- same budget, so five from the hitman in the minute before the kill
    -- used to mean the creator never heard it had been done.
    -- The photograph is where the app shows it, on the Ledger tab, and only
    -- while the ledger keeps photographs: with StorePhotos off, pointing
    -- there sent the client looking for a picture that was never kept.
    local body
    if not hasPhoto then
        body = 'Your contract was fulfilled by live delivery. There is no '
            .. 'photograph — the target was handed over in person.'
    elseif Config.Ledger and Config.Ledger.StorePhotos then
        body = 'Your contract was fulfilled. The verification photograph is '
            .. 'on your Ledger tab.'
    else
        body = 'Your contract was fulfilled.'
    end
    local title = 'Contract fulfilled'

    -- One collection of several is not the contract done. Every claim
    -- came here, so the creator of a three-payout contract read "Your
    -- contract was fulfilled" after the first, with two still on offer
    -- and what pays for them still held.
    if type(result) == 'table' and result.exhausted == false then
        title = 'Collection paid'
        body = ('Collection %d of %d on your contract was paid%s.'):format(
            tonumber(result.slot) or 1, tonumber(contract.payout_slots) or 1,
            hasPhoto and '' or ' by live delivery')
        if hasPhoto and Config.Ledger and Config.Ledger.StorePhotos then
            body = body .. ' The verification photograph is on your Ledger tab.'
        end
        body = body .. (' It is still running, with %d more to collect.')
            :format(tonumber(result.remaining) or 0)
    end
    Notify.toCitizen(contract.creator_cid, title, body,
        { bypassBudget = true })
    local _ = hitmanRecord
end

--------------------------------------------------------------------------
-- Endings (§11.4, §14.8)
--------------------------------------------------------------------------
--
-- Every ending used to send only a push, which moves an app that is already
-- open and nothing else. A hitman with the phone in their pocket saw their
-- stake leave their bank and the contract vanish from Mine with nothing
-- anywhere to say why.
--
-- These are receipts — they say where a stake or a refund went — so they
-- sit outside the budget, as the completion and buyout receipts do (§14.40).
-- Parties another path already tells are left to it: the creator of a
-- cancelled, voided, bought-out or fulfilled contract, and the hitman who
-- fulfilled it.

--- Send now, or keep it for the player's next login.
---
--- An ending is the notice most likely to find its player away: a lifetime
--- expiry runs through every pause, so it lands while the target — and as
--- often as not the hitman — is out of the city, and toCitizen drops a
--- notice for somebody who is not here. Both parties are to be told on next
--- login (§14.8). Kept in memory: a restart loses the notice but not the
--- money it describes, which is in escrow and handed over by the login
--- retry under its own "Outstanding payment".
local function tellOrKeep(cid, title, content, opts)
    if not cid then return false end
    if Identity.byCitizenId(cid) then return Notify.toCitizen(cid, title, content, opts) end
    local list = waiting[cid] or {}
    if #list >= WAITING_CAP then table.remove(list, 1) end
    list[#list + 1] = { title = title, content = content, opts = opts }
    waiting[cid] = list
    return false
end

--- Hand a player what was kept for them while they were away. Called from
--- Bridges.onPlayerReady, once they can receive it.
---@return integer delivered
function Notify.deliverWaiting(cid)
    local list = cid and waiting[cid]
    if not list then return 0 end
    waiting[cid] = nil
    for i = 1, #list do
        Notify.toCitizen(cid, list[i].title, list[i].content, list[i].opts)
    end
    return #list
end

local function dollars(amount)
    return ('$%d'):format(math.floor(tonumber(amount) or 0))
end

--- The sentence that ends a hitman's notice: where their stake went. Left
--- out when they had none.
local function stakeSentence(outcome)
    if (outcome.stake or 0) <= 0 then return '' end
    if outcome.forfeited then
        return (' Your %s stake went to the client.'):format(dollars(outcome.stake))
    end
    if outcome.owed then
        return (' Your %s stake is held for you and is handed back as soon as '
            .. 'you can take it.'):format(dollars(outcome.stake))
    end
    return (' Your %s stake has been returned.'):format(dollars(outcome.stake))
end

--- What a hitman still on the contract is told, by how it ended. nil for an
--- ending that already reaches them some other way.
local function hitmanNotice(contract, ending, outcome)
    local target = contract.target_name or 'your target'
    if ending == CH.STATE.EXPIRED then
        return 'Contract expired', outcome.forfeited
            and ('The deadline on your contract on %s passed.'):format(target)
            or  ('Your contract on %s ran out before it could be finished.'):format(target)
    elseif ending == CH.STATE.BAILED_OUT then
        return 'Contract closed', ('%s bought their way out of your contract.'):format(target)
    elseif ending == CH.STATE.VOIDED then
        return 'Contract closed', ('Staff closed your contract on %s.'):format(target)
    elseif ending == CH.STATE.COMPLETED then
        return 'Contract closed', ('Another operative finished the contract on %s.'):format(target)
    end
    -- CANCELLED: with a hitman on it, only by an amendment they agreed to.
    return nil
end

--- Whether the target was ever told this contract existed — by the paranoid
--- alert, or as an officer by their own advisory. Mirrors contractCreated.
local function targetWasTold(contract)
    if contract.target_protected and Notify.advises('posted') then
        return Config.Advisory.AlwaysAlertTarget == true
    end
    return Config.Notifications.ParanoidAlert == true
end

--- Tell everyone a contract's ending left uninformed.
---@param contract table
---@param ending string the terminal CH.STATE
---@param outcomes table[] { cid, stake, forfeited, owed } per hitman still on it
---@param opts table|nil { winnerCid = string, creatorOwed = integer }
function Notify.contractEnded(contract, ending, outcomes, opts)
    if not contract then return end
    opts = opts or {}

    local forfeitedTotal, forfeitedCount = 0, 0
    for _, outcome in ipairs(outcomes or {}) do
        if outcome.forfeited and (outcome.stake or 0) > 0 then
            forfeitedTotal = forfeitedTotal + outcome.stake
            forfeitedCount = forfeitedCount + 1
        end
        -- The hitman who finished it has the result in front of them.
        if outcome.cid ~= opts.winnerCid then
            local title, body = hitmanNotice(contract, ending, outcome)
            if title then
                tellOrKeep(outcome.cid, title, body .. stakeSentence(outcome),
                    { bypassBudget = true })
            end
        end
    end

    if ending ~= CH.STATE.EXPIRED then return end

    -- Only an expiry is new to the creator: cancel, void, buyout and
    -- completion each tell them already.
    local owed = opts.creatorOwed or 0
    local body = ('Nobody finished your contract on %s in time.')
        :format(contract.target_name or 'your target')
    body = body .. (owed > 0
        and (' What you put up is coming back: %d thing(s) could not be handed '
             .. 'over yet and arrive as soon as you can take them.'):format(owed)
        or ' Everything you put up has been returned.')
    if forfeitedCount == 1 then
        body = body .. (" The operative's %s stake is yours."):format(dollars(forfeitedTotal))
    elseif forfeitedCount > 1 then
        body = body .. (" The operatives' stakes, %s in all, are yours."):format(dollars(forfeitedTotal))
    end
    tellOrKeep(contract.creator_cid, 'Contract expired', body, { bypassBudget = true })

    -- The target only when they were told there was a price on their head
    -- at all. Anyone else would learn of a contract from its ending. Worded
    -- as one price, because it may not have been the only one.
    if targetWasTold(contract) then
        Notify.toCitizen(contract.target_cid, 'Breathing room',
            'A price on your head has lapsed.')
    end
end

--- Tell the client an operative walked away from their contract.
---@param contract table as it stands after they left
---@param stake integer what the operative had staked, now the client's
---@param remaining integer operatives still on it
function Notify.hitmanLeft(contract, stake, remaining)
    if not contract then return end
    local body = ('An operative left your contract on %s.')
        :format(contract.target_name or 'your target')
    if (stake or 0) > 0 then
        body = body .. (' Their %s stake is yours.'):format(dollars(stake))
    end
    if remaining > 0 then
        body = body .. (' %d operative%s still on it.')
            :format(remaining, remaining == 1 and ' is' or 's are')
    elseif contract.state == CH.STATE.ACTIVE then
        body = body .. ' It is back on the board.'
    end
    -- A receipt only when money moved; otherwise it spends the budget like
    -- any other news.
    tellOrKeep(contract.creator_cid, 'Operative walked away', body,
        { bypassBudget = (stake or 0) > 0 })
end

--- Warn the operatives on a contract that its target has paid to close it.
--- The processing delay exists so they can finish first (§14.17), which a
--- hitman who never hears of it cannot do. Spends the budget, as the
--- client's own "Contract challenged" does.
---@param contract table
---@param hitmanCids string[]
---@param seconds integer the processing delay
function Notify.buyoutQueued(contract, hitmanCids, seconds)
    if not contract then return end
    seconds = math.floor(tonumber(seconds) or 0)
    local wait = seconds >= 120 and ('%d minutes'):format(seconds // 60)
        or ('%d seconds'):format(seconds)
    local body = ('%s is buying their way out of your contract. It closes in %s '
        .. 'unless you finish it first.'):format(contract.target_name or 'Your target', wait)
    for i = 1, #(hitmanCids or {}) do
        Notify.toCitizen(hitmanCids[i], 'Contract challenged', body)
    end
end

--------------------------------------------------------------------------
-- Law enforcement threat advisory (§7.5)
--------------------------------------------------------------------------

--- The departments the dispatch entry is for: the job names configured to
--- receive advisories, so the MDT and the phones are told the same people.
--- It was a list of its own, and a department added to one was missing
--- from the other.
local function dispatchJobs()
    local jobs = {}
    for name, on in pairs(Config.Advisory.RecipientJobNames or {}) do
        if on == true and type(name) == 'string' then jobs[#jobs + 1] = name end
    end
    table.sort(jobs)
    if #jobs == 0 then jobs = { 'police' } end
    return jobs
end

--- Advise every online law enforcement player, and the officer themselves,
--- that a contract exists or has gone live.
---
--- The creator is never named, even when they are not anonymous: the advisory
--- says a threat exists and who it is against. Finding out who ordered it is
--- police work.
---@param contract table
---@param stage string 'posted' | 'accepted'
---@param activeHitmen integer|nil count of hitmen now on the contract
--- Whether officers are told at this stage; see Util.advises.
Notify.advises = Util.advises

---@param operative string|nil the hitman whose acceptance this is
function Notify.advisory(contract, stage, activeHitmen, operative)
    if not Notify.advises(stage) then return end

    -- One advisory per contract per stage, and on acceptance one per
    -- operative. Keyed by the running count, a new operative taking up a
    -- contract another had walked away from brought the count back to one
    -- already announced, and no officer, not the officer named, and not the
    -- MDT heard that somebody new was hunting them. One who walks away and
    -- comes back is not news twice.
    local key = contract.id .. ':' .. stage .. ':'
        .. tostring(operative or activeHitmen or 0)
    if advisorySent[key] then return end
    advisorySent[key] = true

    local rank = contract.target_job and (contract.target_job:upper() .. ' ') or ''
    local title, content

    if stage == 'posted' then
        title = 'THREAT ADVISORY'
        content = ('A contract has been placed on %s%s.'):format(rank, contract.target_name)
    else
        title = 'THREAT ADVISORY — ACTIVE'
        local n = activeHitmen or 1
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
                        :format(activeHitmen or 1, (activeHitmen or 1) == 1 and ' is' or 's are'),
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
                job_table = dispatchJobs(),
                unique_id = 'ch-' .. contract.id .. '-' .. stage,
            })
        end)
    end

    return recipients
end

--- Release a player's notification budget when they disconnect, so the
--- table cannot grow across a long uptime.
function Notify.clearPlayer(cid)
    budgets[cid] = nil
    lastPush[cid] = nil
    trailing[cid] = nil
    -- A cooldown still running is kept: relogging must not buy a second
    -- alert, and with it a count.
    if (paranoidUntil[cid] or 0) <= os.time() then paranoidUntil[cid] = nil end
end

function Notify.clearContract(contractId, contract)
    for key in pairs(advisorySent) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then advisorySent[key] = nil end
    end

    -- Take the threat off the MDT. sc-dispatch files an advisory as an
    -- active call, and nothing closed it: an officer's dispatch list kept a
    -- live threat against a colleague for a contract long since settled.
    -- Every stage that could have been filed is cleared, because what was
    -- sent before a restart is not remembered. In a thread of its own: the
    -- export waits on the database, and this is the end of a settlement.
    if contract and contract.target_protected
        and Config.Advisory.UseDispatch and GetResourceState('sc-dispatch') == 'started' then
        local jobs = dispatchJobs()
        for _, stage in ipairs({ 'posted', 'accepted' }) do
            if Notify.advises(stage) then
                local uid = 'ch-' .. contractId .. '-' .. stage
                CreateThread(function()
                    pcall(function() exports['sc-dispatch']:ClearNotification(uid, jobs) end)
                end)
            end
        end
    end
end

return Notify
