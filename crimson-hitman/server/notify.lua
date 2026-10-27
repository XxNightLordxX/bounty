--- Outbound player notifications (§7.3) and the law enforcement threat
--- advisory (§7.5).
---
--- Every send passes a per-recipient budget so a contract storm cannot be
--- used to flood phones (§14.40).

local Notify = {}

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Identity
local Storage
--- What the whitelisted-job view lists, for its Notify me notices
--- (Projection.whitelistedListing).
local Projection
local budgets = {}
--- [cid] = the same counters as `budgets`, for messages and call requests
--- alone (opts.relay). One budget for both let a handover arranged by
--- message, which the alive-only rule makes everybody do, silence
--- "Handover starting" and "Contract accepted" for the minute or the hour.
local relayBudgets = {}
local advisorySent = {}

--- [contractId .. ':' .. hitmanCid] = true once the person who placed the
--- contract was told that hitman took it (§14.40: one who leaves and comes
--- back is not news twice). Cleared with the contract (clearContract).
local announced = {}

--- [contractId] = true once its target was told it exists: their alert
--- went or was kept for them, or, as an officer, their own advisory did.
--- What the lapse notice reads (targetWasTold), never the switches as they
--- are now. In memory, like the wait: see Notify.rearm for a restart.
local told = {}

--- [cid] = { { title, content, opts }, ... } kept for a player who was
--- offline when one of their contracts ended (see tellOrKeep), or kept past
--- their notice budget and sent when the minute opens (Notify.deliverKept).
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

--- [contractId] = os.time() before which the contract is kept from its
--- target (Notify.shownToTarget). In memory only: a restart forgets it, and
--- the start draws it again for a contract placed inside the longest wait
--- before it (Notify.rearm).
local revealAt = {}

--- [targetCid] = the paranoid alert waiting out its delay, and the
--- contracts it stands for: { ids = { [contractId] = os.time() it falls due
--- for that one }, due = the earliest of them }. It goes only while one of
--- them is still out (Notify.clearContract), at the earliest reveal among
--- those left. One withdrawn inside the wait rang the target with "A price
--- has been put on your head" for a contract their On me tab and /cleanse
--- never showed; and with the first of two withdrawn, it went at the
--- first one's time while On me still showed nothing.
local pendingAlert = {}

--- [cid] = whether that character turned on the whitelisted-job view's
--- Notify me (Notify.viewAlertsOn): as the store answered the first time it
--- was asked this session, or as they set it since. Forgotten with the
--- player (clearPlayer).
local viewOptIn = {}

--- [contractId .. ':' .. cid] = true once that viewer was sent, or kept,
--- the Notify me notice for that contract's entry: one per contract.
--- Cleared with the contract (clearContract).
local viewTold = {}

--- [contractId] = { [targetCid] = token }: the Notify me notice for a
--- contract on that viewer, waiting out the same wait as their own alert
--- (armViewOnYou). Let go with the contract (clearContract).
local viewWaiting = {}

function Notify.init(deps)
    Identity = deps.identity
    Storage = deps.storage
    Projection = deps.projection
    budgets, relayBudgets, advisorySent = {}, {}, {}
    announced, told = {}, {}
    lastPush, trailing = {}, {}
    waiting = {}
    paranoidUntil = {}
    revealAt = {}
    pendingAlert = {}
    viewOptIn, viewTold, viewWaiting = {}, {}, {}
end

---@param book table|nil budgets (contract notices) or relayBudgets
local function withinBudget(cid, book)
    book = book or budgets
    local bucket = book[cid]
    local now = os.time()
    if not bucket or now - bucket.minuteStart >= 60 then
        bucket = { minuteStart = now, minute = 0, hourStart = bucket and bucket.hourStart or now, hour = bucket and bucket.hour or 0 }
        book[cid] = bucket
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

--- The number of the phone this player has equipped, as lb-phone answers
--- by their server id. nil with no phone (yet); and a second false where
--- the export itself could not be asked.
---
--- Never by citizen id, which lb-phone would answer with the phone they
--- last had equipped: that phone may be in somebody else's pocket now, and
--- a notice saved on it would tell whoever holds it what this player is
--- part of.
local function equippedNumber(src)
    local ok, number = pcall(function()
        return exports['lb-phone']:GetEquippedPhoneNumber(src)
    end)
    if not ok then return nil, false end
    if type(number) ~= 'string' and type(number) ~= 'number' then return nil, true end
    number = tostring(number)
    if number == '' or #number > 32 then return nil, true end
    return number, true
end

--- How long a notification waits for the player's phone, in steps: a
--- notice kept for their next login (deliverWaiting) is handed over while
--- they are still choosing a character or a spawn, before lb-phone has
--- loaded the phone it would be saved on.
local PHONE_WAIT_MS, PHONE_WAITS = 2000, 60

--- Put a notification on the player's phone.
---
--- Through lb-phone's server export, by the number of the phone they have
--- equipped: that is the one form of SendNotification lb-phone keeps in
--- the phone's notification list. The client export it used to go through
--- shows a popup that is never saved, so a receipt ("the photo is waiting
--- under Ledger"), a target's alert or a stake forfeited was gone the
--- moment it faded — and a notice kept for a player's next login reached
--- them before their phone had loaded, where it was not seen at all. So a
--- player whose phone is not loaded yet is waited for, a while.
---
--- The popup stays as the fallback: lb-phone not started, an export that
--- throws or says no, or a phone that never loads. The player's client
--- raises it, as it always did.
---
--- In a thread of its own. The export writes to lb-phone's database and
--- waits for it, and this is reached from inside settlements and request
--- handlers that must not yield halfway for the sake of a notification.
--- CreateThreadNow runs it at once up to that wait, so the order things
--- are sent in does not change.
local function raise(actor, cid, title, content)
    local src = actor.source
    Citizen.CreateThreadNow(function()
        if GetResourceState('lb-phone') == 'started' then
            local number, asked = equippedNumber(src)
            for _ = 1, PHONE_WAITS do
                if number or not asked then break end
                Wait(PHONE_WAIT_MS)
                -- Still them on that server id. A source is reused, and a
                -- notice is never saved on, or raised for, whoever has it now.
                local now = Identity.byCitizenId(cid)
                if not now or now.source ~= src then return end
                number, asked = equippedNumber(src)
            end
            if number then
                local ok, id = pcall(function()
                    return exports['lb-phone']:SendNotification(number, {
                        app = 'crimson-hitman', title = title, content = content,
                    })
                end)
                if ok and id ~= false then return end
            end
        end
        TriggerClientEvent('crimson-hitman:notify', src, {
            title = title,
            content = content,
        })
    end)
end

--- A short notice on one player's screen, by server id, never saved on
--- their phone: the popup their client raises (crimson-hitman:notify).
--- For a staff command's "Printed to your F8 console", which is about this
--- moment and nothing to keep; and by server id, since staff run commands
--- before a character is loaded too. Not charged to any budget.
---@param src number
---@param title string
---@param content string
---@return boolean sent
function Notify.onScreen(src, title, content)
    src = tonumber(src)
    if not src or src <= 0 then return false end
    TriggerClientEvent('crimson-hitman:notify', src, { title = title, content = content })
    return true
end

--- Keep a notice that found its player past their budget, to go when the
--- minute opens (Notify.deliverKept) rather than be dropped (§14.40).
---
--- Coalesced by event and contract: one kept per title and contract, the
--- newest in place of the one before ("2 operatives are active" over "1
--- operative is"). Keyed by the contract alone, a "Reward changed" in the
--- same minute replaced "Contract accepted". A notice that names no
--- contract is coalesced only with one saying exactly the same.
local function keepOver(cid, title, content, opts)
    local contractId = opts and opts.contractId
    local key = tostring(title) .. '\0' .. (contractId and ('#' .. tostring(contractId))
        or tostring(content))
    local list = waiting[cid] or {}
    for i = 1, #list do
        if list[i].key == key then table.remove(list, i) break end
    end
    if #list >= WAITING_CAP then table.remove(list, 1) end
    list[#list + 1] = { title = title, content = content, opts = opts,
                        contract_id = contractId, key = key }
    waiting[cid] = list
end

--- Send to one player by citizen id. Silently no-ops when they are offline.
---
--- Saved on their phone through lb-phone's server export where it can be,
--- and raised by their client where it cannot (raise).
---
--- opts.relay: a contract message or a call request (server/comms.lua).
--- Charged to a budget of its own, the same per-minute and per-hour figures
--- as every other notice (Config.Notifications) counted apart, and dropped past
--- it, as before. Every other notice — "Contract accepted", "Handover
--- starting", a proposal — has the other budget to itself, and one past it
--- is kept and sent when the minute opens, never dropped.
---
--- opts.muted: the recipient muted the thread this came from (§11.4). It is
--- charged to their budget exactly as a sent one is, and then not sent.
--- Left uncharged, a muted thread would leave room in the budget that an
--- unmuted one fills, and the next notice — a call request, whose sender is
--- told when it could not get through, and which reads the same relay
--- budget — would tell the sender which it was.
---
--- opts.contractId: the contract it is about, which a notice kept past the
--- budget is coalesced by.
---
--- What it answers does not depend on which way the notice went, or on
--- whether lb-phone took it: only on the budget, the mute and whether the
--- player is here. False for a notice kept past the budget: not sent now.
--- The call request reports the answer to its sender.
function Notify.toCitizen(cid, title, content, opts)
    if not cid then return false end
    if opts and opts.relay then
        if not withinBudget(cid, relayBudgets) then return false end
        if opts.muted then return false end
        local actor = Identity.byCitizenId(cid)
        if not actor then return false end
        raise(actor, cid, title, content)
        return true
    end

    -- Somebody away spends nothing: a notice that never reached them used
    -- up the minute they came back in.
    local actor = Identity.byCitizenId(cid)
    if not actor then return false end
    if not (opts and opts.bypassBudget) and not withinBudget(cid) then
        if not (opts and opts.muted) then keepOver(cid, title, content, opts) end
        return false
    end
    if opts and opts.muted then return false end

    raise(actor, cid, title, content)
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
        -- showed the new operative. Nor anything but a job change behind a
        -- settings change, which is the one that has the page read the
        -- settings again: replaced, the page kept the old fees and prices.
        elseif not (reason == 'message' and held.reason ~= 'message')
            and not (held.reason == 'settings' and reason ~= 'access') then
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
    -- the projection it reads does not already show them. Nor any push at
    -- all inside the wait before they are shown it (Notify.shownToTarget):
    -- a contract withdrawn in the first minute would otherwise have rung a
    -- phone whose On me tab never showed it.
    nudge(contract.creator_cid, contract.id)
    if Notify.shownToTarget(contract) then nudge(contract.target_cid) end
    for i = 1, #(hitmanCids or {}) do nudge(hitmanCids[i], contract.id) end

    return sent
end

function Notify.clearPush(cid)
    lastPush[cid] = nil
    trailing[cid] = nil
end

--------------------------------------------------------------------------
-- The whitelisted-job view's Notify me (Config.WhitelistedView.Alerts)
--------------------------------------------------------------------------
--
-- A player on the whitelisted-job view can turn on Notify me, for that
-- character, off until they do. With it on they are told on their phone
-- when a new entry appears on their view: a contract on them at the end of
-- the same wait their own alert and On me keep (contractCreated draws it,
-- Notify.shownToTarget reads it), never sooner; and a contract on another
-- whitelisted-job member as the advisory bulletin that puts it on their
-- view goes out, never sooner, and only where the view lists it for them
-- (Projection.whitelistedListing). Each says only what the entry shows:
-- who it is on, and a colleague's job; never who placed it or any hitman.
-- Through the notice budget like any other news, once per contract and
-- viewer, one kept past the budget coalesced by its contract (keepOver)
-- and dropped with it (clearContract).

--- Whether the server allows Notify me now: the view on, and its alerts.
--- Read at every use, so the admin panel's switch applies at once, to
--- notices already waiting too.
---@return boolean
function Notify.viewAlertsAllowed()
    local view = Config.WhitelistedView
    return type(view) == 'table' and view.Enabled == true and view.Alerts == true
end

--- Whether this character turned Notify me on. Asked of the store once a
--- session and kept (viewOptIn); a store that does not answer is read as
--- off this time, and asked again the next.
---@param cid string
---@return boolean
function Notify.viewAlertsOn(cid)
    if type(cid) ~= 'string' then return false end
    local known = viewOptIn[cid]
    if known ~= nil then return known end
    if not (Storage and Storage.readViewAlerts) then return false end
    local ok, on = pcall(Storage.readViewAlerts, cid)
    if not ok then
        Log.debug(('could not read a player\'s Notify me choice: %s'):format(Util.dbError(on)))
        return false
    end
    viewOptIn[cid] = on == true
    return viewOptIn[cid]
end

--- Let go of the Notify me notices kept for a player past their budget: one
--- they turned off, or left the city with, is not sent later.
local function dropKeptView(cid)
    local list = waiting[cid]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].opts and list[i].opts.view then table.remove(list, i) end
    end
    if #list == 0 then waiting[cid] = nil end
end

--- Turn Notify me on or off for this character. The store first: a write
--- it refuses raises, and nothing here changes.
---@param cid string
---@param on boolean
---@return boolean changed false where it was so already
function Notify.setViewAlerts(cid, on)
    on = on == true
    local was = Notify.viewAlertsOn(cid)
    if viewOptIn[cid] ~= nil and was == on then return false end
    Storage.setViewAlerts(cid, on, os.time())
    viewOptIn[cid] = on
    if not on then dropKeptView(cid) end
    return true
end

--- The player a Notify me notice may go to now, or nil: the server allows
--- it, they are one the view is for (a player the app bars, as
--- Identity.gateFor lets into it), and they turned it on.
---@param actor table|nil in the city
---@return table|nil actor
local function viewViewer(actor)
    if not actor or not Notify.viewAlertsAllowed() or not Projection then return nil end
    local okBarred, barred = pcall(Identity.isBarred, actor)
    if not (okBarred and barred) then return nil end
    if not Notify.viewAlertsOn(actor.cid) then return nil end
    return actor
end

--- A Notify me notice's words: the entry's own, never more. Who it is on,
--- and the job a colleague is listed under; not when, open or taken, or
--- how long, which the screen says; never who placed it or any hitman,
--- which the entry does not carry.
---@param entry table what the view lists
---@param own boolean a contract on the viewer
---@return string title
---@return string content
local function viewWords(entry, own)
    if own then
        return 'Contract on you', 'A contract on you is now listed in this app.'
    end
    local who = tostring(entry.targetName or 'a whitelisted-job member')
    if type(entry.targetJob) == 'string' and entry.targetJob ~= '' then
        who = ('%s (%s)'):format(who, entry.targetJob)
    end
    return 'Contract on a whitelisted job',
        ('A contract on %s is now listed in this app.'):format(who)
end

--- Send one: once per contract and viewer, through the budget, and kept
--- past it coalesced by the contract.
local function sendView(actor, contractId, entry, own)
    local key = tostring(contractId) .. ':' .. tostring(actor.cid)
    if viewTold[key] then return false end
    viewTold[key] = true
    local title, content = viewWords(entry, own)
    Notify.toCitizen(actor.cid, title, content, { contractId = contractId, view = true })
    return true
end

--- A contract on its target: their Notify me notice at the end of `delay`,
--- the wait drawn for it (contractCreated, rearm), which their own alert
--- and On me keep, never sooner. Checked when it falls due, against the
--- contract as stored then: one that ended inside the wait sends nothing
--- (clearContract lets it go), nor one the view would not list. A bulletin
--- that shows it to them sooner does not bring it forward.
---@param contract table
---@param delay integer seconds
local function armViewOnYou(contract, delay)
    local id, cid = contract and contract.id, contract and contract.target_cid
    if not id or type(cid) ~= 'string' then return end
    local token = {}
    viewWaiting[id] = viewWaiting[id] or {}
    viewWaiting[id][cid] = token
    local function due()
        local held = viewWaiting[id]
        if not held or held[cid] ~= token then return end
        held[cid] = nil
        if next(held) == nil then viewWaiting[id] = nil end
        local actor = viewViewer(Identity.byCitizenId(cid))
        if not actor then return end
        local okRead, row = pcall(Storage.readContract, id)
        if not okRead or type(row) ~= 'table' then return end
        local okList, entry, own = pcall(Projection.whitelistedListing, row, cid, actor.job)
        if okList and entry and own then sendView(actor, id, entry, true) end
    end
    delay = math.max(0, math.floor(tonumber(delay) or 0))
    if delay <= 0 then return due() end
    SetTimeout(delay * 1000, due)
end

--- Before a bulletin's words are kept on its contract: who could be sent a
--- Notify me notice for it (in the city, reached by the advisory, not its
--- target, and with it on), and which of them their view lists it for
--- already. nil where nobody could, so a bulletin nobody asked to hear of
--- costs no read.
---@param contract table
---@return table|nil { viewers = actor[], prior = table, listed = { [cid] = true } }
local function viewBefore(contract)
    if not Notify.viewAlertsAllowed() or not Projection then return nil end
    local viewers = {}
    local online = Identity.online()
    for i = 1, #online do
        local actor = online[i]
        if actor.cid ~= contract.target_cid and Identity.isAdvisoryRecipient(actor.job)
            and viewViewer(actor) then
            viewers[#viewers + 1] = actor
        end
    end
    if #viewers == 0 then return nil end
    local okRead, row = pcall(Storage.readContract, contract.id)
    local prior = Util.copy((okRead and type(row) == 'table') and row or contract)
    local listed = {}
    for i = 1, #viewers do
        local ok, entry = pcall(Projection.whitelistedListing, prior, viewers[i].cid,
            viewers[i].job)
        if ok and entry then listed[viewers[i].cid] = true end
    end
    return { viewers = viewers, prior = prior, listed = listed }
end

--- As the bulletin goes out: each of them whose view lists the contract
--- now, and did not before it, is told. `said` is what the bulletin kept on
--- the contract, nil where keeping it failed: the view reads the store, and
--- does not list it by that bulletin then.
---@param before table|nil viewBefore's
---@param said table|nil
local function viewAfter(before, said)
    if not before then return end
    local after = Util.copy(before.prior)
    for k, v in pairs(said or {}) do after[k] = v end
    for i = 1, #before.viewers do
        local actor = before.viewers[i]
        if not before.listed[actor.cid] then
            local ok, entry, own = pcall(Projection.whitelistedListing, after, actor.cid, actor.job)
            if ok and entry and own == false then sendView(actor, after.id, entry, false) end
        end
    end
end

--------------------------------------------------------------------------
-- Contract lifecycle notifications
--------------------------------------------------------------------------

--- Seconds a new contract is kept from its target, drawn at random from
--- Config.Notifications.ParanoidAlertJitter.
---@return integer
local function revealDelay()
    local jitter = type(Config.Notifications.ParanoidAlertJitter) == 'table'
        and Config.Notifications.ParanoidAlertJitter or {}
    local low = math.max(0, math.floor(tonumber(jitter.min) or 0))
    local high = math.max(low, math.floor(tonumber(jitter.max) or 0))
    if high <= 0 then return 0 end
    return math.random(low, high)
end

function Notify.contractCreated(contract, targetActor)
    -- When the target first learns of it, by any route (§14.40).
    --
    -- The alert waited a few minutes so as not to date the placement, and
    -- everything else told the target at once: the contract was on their
    -- On me tab and in /cleanse the moment it was placed, and the creator's
    -- own reply to placing it asked the target's client for a headshot. A
    -- client that logs its events, or a player polling /cleanse, had the
    -- second, and on an anonymous contract that second says the client was
    -- in the city and acting. One wait, drawn here, now covers all of it,
    -- and the alert arrives as the contract appears.
    --
    -- Except for an officer whose department is told now: the bulletin
    -- dates it to the second for every officer online, so holding back
    -- their own /cleanse would hide nothing and contradict it.
    local delay = (contract.target_protected and Notify.advises('posted')) and 0
        or revealDelay()
    if delay > 0 then revealAt[contract.id] = os.time() + delay end

    -- The whitelisted-job view's Notify me for the target, at the end of
    -- the same wait.
    armViewOnYou(contract, delay)

    -- The target's paranoid alert. Deliberately vague: it tells them
    -- something is wrong, not who or how much.
    -- An officer is told by their own copy of the posting bulletin instead,
    -- but only where one goes to them (Config.Advisory.AlwaysAlertTarget):
    -- with that off, an officer with a price on their head heard nothing at
    -- all, not even the alert a civilian gets.
    if Config.Notifications.ParanoidAlert and not Notify.advisedTarget(contract) then
        Notify.paranoid(contract.target_cid, delay, contract.id)
    end

    if contract.target_protected then
        Notify.advisory(contract, 'posted', targetActor)
    end
end

--- Whether the contract's target may be shown it yet: on their On me tab,
--- in /cleanse, by a headshot asked of their client, or by Nearby closing
--- to them. False only inside the wait contractCreated drew; a contract
--- this process never saw placed is shown at once.
---@param contract table
---@return boolean
function Notify.shownToTarget(contract)
    local at = contract and revealAt[contract.id]
    if not at then return true end
    if os.time() < at then return false end
    revealAt[contract.id] = nil
    return true
end

--- Whether the contract's target, an officer, is told of it by their own
--- copy of the posting bulletin (Notify.advisory) rather than by the
--- paranoid alert: a bulletin goes at posting, and to them too.
---@param contract table
---@return boolean
function Notify.advisedTarget(contract)
    return contract.target_protected == true and Notify.advises('posted')
        and Config.Advisory.AlwaysAlertTarget == true
end

--- Send the alert now: kept for a target who is away, outside the budget
--- (the cooldown rations it), and the cooldown started by it. Not at all
--- once staff have switched alerts off while it waited: the panel says
--- alerts still waiting are checked when they fall due.
---@param ids table<string, any> the contracts it stands for
local function sendAlert(targetCid, ids)
    if Config.Notifications.ParanoidAlert ~= true then return false end
    paranoidUntil[targetCid] = os.time()
        + math.max(0, (tonumber(Config.Notifications.ParanoidCooldownMinutes) or 0) * 60)
    for id in pairs(ids or {}) do told[id] = true end
    Notify.tellOrKeep(targetCid, 'Unsettling',
        'You feel eyes on you. A price has been put on your head.', { bypassBudget = true })
    -- An open On me tab re-reads, and shows the contract as the alert
    -- arrives. Names no contract: the page learns only what On me shows.
    Notify.push(targetCid, 'alert')
    return true
end

--- Set the waiting alert's timer for the earliest of the contracts it still
--- stands for; one set before is let go (its token no longer matches).
local function armAlert(targetCid, alert)
    local due
    for _, at in pairs(alert.ids) do
        if not due or at < due then due = at end
    end
    if not due then
        if pendingAlert[targetCid] == alert then pendingAlert[targetCid] = nil end
        return
    end
    alert.due = due
    local token = {}
    alert.token = token
    SetTimeout(math.max(0, due - os.time()) * 1000, function()
        if pendingAlert[targetCid] ~= alert or alert.token ~= token then return end
        pendingAlert[targetCid] = nil
        if next(alert.ids) then sendAlert(targetCid, alert.ids) end
    end)
end

--- The target's alert, some minutes after the placement and once per
--- cooldown (§14.40).
---
--- It went the second the contract was placed, so the one person never
--- told who the client is, and the most eager to find out, learned to the
--- second when they were online and acting. Everything else dates a
--- placement only roughly (Util.roundClock). And it went once per
--- contract, so the count of alerts was the count of people paying.
---
--- Tied to the contract it is about (pendingAlert): one ended inside the
--- wait takes its alert with it. A second contract placed while the first
--- one's alert is still waiting rides on that alert, which goes at the
--- earliest reveal among those still out, so the first being withdrawn
--- neither silences the second nor rings before On me shows it.
---
--- The cooldown starts when the alert is sent or kept (sendAlert), not at
--- the placement: a target away when it fell due, past their budget, or
--- whose contract was placed just before a restart lost the alert and the
--- next half hour's with it. A contract placed while the cooldown runs
--- counts as told: the alert inside it said a price is on them, and how
--- many is what the cooldown keeps from them.
---@param targetCid string
---@param delay integer|nil seconds to wait; drawn from the jitter when nil
---@param contractId string|nil the contract it is about
function Notify.paranoid(targetCid, delay, contractId)
    local now = os.time()
    local wait = math.max(0, tonumber(delay) or revealDelay())
    local due = now + wait

    local waitingAlert = pendingAlert[targetCid]
    if waitingAlert and contractId then
        waitingAlert.ids[contractId] = due
        if not waitingAlert.due or due < waitingAlert.due then armAlert(targetCid, waitingAlert) end
        return
    end
    if (paranoidUntil[targetCid] or 0) > now then
        if contractId then told[contractId] = true end
        return
    end

    if not contractId then
        if wait <= 0 then return sendAlert(targetCid, {}) end
        SetTimeout(wait * 1000, function() sendAlert(targetCid, {}) end)
        return
    end
    if wait <= 0 then return sendAlert(targetCid, { [contractId] = true }) end

    local alert = { ids = { [contractId] = due } }
    pendingAlert[targetCid] = alert
    armAlert(targetCid, alert)
end

--- A restart forgets the wait, the alert and who was told (all in memory).
--- Every live contract placed less than the longest wait before this start
--- is held back from its target again, for a fresh draw counted from now
--- and never less than the shortest wait, with its alert re-armed and kept
--- for a target who is away: shown at once, it was on On me the moment the
--- server came back, never announced, and a restart dated it no more
--- closely than the wait does. Older ones count as told where the alert or
--- the officer's bulletin was on (On me already listed them), so a lapse
--- notice tells them nothing On me did not. Worst case, one extra alert.
---@param contracts table[] the live contracts (Storage.liveContracts)
---@return integer rearmed
function Notify.rearm(contracts)
    local jitter = type(Config.Notifications.ParanoidAlertJitter) == 'table'
        and Config.Notifications.ParanoidAlertJitter or {}
    local longest = math.max(0, math.floor(tonumber(jitter.max) or 0))
    local now, rearmed = os.time(), 0
    for _, contract in ipairs(contracts or {}) do
        local placed = tonumber(contract.created_at) or 0
        -- What a bulletin already said of it dated it for the officer.
        -- A count of hitmen only where a bulletin carried one: an unknown
        -- one (ACCEPTANCE_UNKNOWN) is no bulletin.
        local bulletin = contract.advised_posted_at ~= nil
            or (tonumber(contract.advised_hitmen) or 0) > 0
        if Notify.advisedTarget(contract) or bulletin then
            -- Shown at once when it was placed, and their bulletin or their
            -- alert went then.
            if (Config.Advisory.AlwaysAlertTarget == true and contract.target_protected)
                or Config.Notifications.ParanoidAlert == true then
                told[contract.id] = true
            end
        elseif now - placed < longest then
            local delay = revealDelay()
            if delay > 0 then revealAt[contract.id] = now + delay end
            if Config.Notifications.ParanoidAlert == true then
                Notify.paranoid(contract.target_cid, delay, contract.id)
            end
            -- Held back from the target again, and appearing on their
            -- whitelisted-job view at the end of it, as a new placement does.
            armViewOnYou(contract, delay)
            rearmed = rearmed + 1
        elseif Config.Notifications.ParanoidAlert == true then
            told[contract.id] = true
        end
    end
    return rearmed
end

---@param returning boolean|nil the hitman is taking it up again after a stint of their own
--- on it (Contracts.accept): not news to officers twice, whatever a restart forgot
function Notify.contractAccepted(contract, hitmanRecord, activeHitmen, returning)
    local who = hitmanRecord.anon and 'an operative' or hitmanRecord.hitman_name
    local body = ('Your contract on %s has been accepted by %s. %d operative%s now active.')
        :format(contract.target_name, who, activeHitmen, activeHitmen == 1 and ' is' or 's are')
    -- Live transfer only: the hitman comes to the person who placed it, so
    -- this is the moment that person learns they have to be in the city to
    -- be met. The page's own card under Mine says the same (placerTakenText).
    -- A contract a kill completes too keeps its words.
    if Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE then
        body = ("A hitman%s took your contract on %s. They'll bring the target to you "
            .. 'alive — stay in the city%s.%s')
            :format(hitmanRecord.anon and '' or (' (' .. tostring(hitmanRecord.hitman_name) .. ')'),
                tostring(contract.target_name),
                Config.Relay.Enabled == true and ' and watch your messages' or '',
                (tonumber(activeHitmen) or 0) > 1
                    and (' %d hitmen are on it now.'):format(activeHitmen) or '')
    end
    -- Once per hitman (§14.40): one taking it, walking away and taking it
    -- again rang the client every time, and filled their notice budget at
    -- no cost to the hitman. Kept for a client who is away: on an alive-only
    -- contract this is their cue to be in the city for the handover.
    local pair = tostring(contract.id) .. ':' .. tostring(hitmanRecord.hitman_cid)
    if not announced[pair] then
        announced[pair] = true
        Notify.tellOrKeep(contract.creator_cid, 'Contract accepted', body, nil, contract.id)
    end

    -- Every acceptance raises an advisory carrying the running count, so law
    -- enforcement can judge the scale of the threat and not just its
    -- existence. The per-contract hitman cap bounds the total (§7.5). Only
    -- on a first stint: one who walks away and comes back is not news, and
    -- the in-memory record of who was announced is gone after a restart.
    if contract.target_protected and not returning then
        Notify.advisory(contract, 'accepted', activeHitmen, hitmanRecord.hitman_cid)
    end

    -- Taken while the target's buyout waits out its delay: told at once, as
    -- the operatives on it when it was paid were, and their card counts it
    -- down (Projection: buyoutClosesIn).
    if contract.bailout_queued_at then
        local left = (tonumber(contract.bailout_queued_at) or 0)
            + (tonumber(Config.Bailout.ProcessingDelaySeconds) or 0) - os.time()
        if left > 0 then Notify.buyoutQueued(contract, { hitmanRecord.hitman_cid }, left) end
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
--- The photo is mentioned only when one was kept. This once took the photo
--- and never read it: the body was a single hardcoded string promising a
--- verification photo, and the live-delivery route has no photograph to
--- take. So the creator of every delivery was sent to an archive row with
--- nothing attached — which reads as the archive having lost the picture
--- rather than as there never having been one.
---
--- And it says how the photo works now, because it is the one thing the
--- client cannot learn by looking: it can be seen once. "It is on your
--- Ledger tab" read as a picture that would be there whenever they cared to
--- look, and the client who opened it to glance at it and closed it lost it.
---@param contract table
---@param hitmanRecord table|string|nil the hitman paid: an actor, or a citizen id
---@param proof table|nil nil for a live delivery; for a kill, { photo = handle }, the handle nil when no photo was kept
---@param result table|nil the claim's own answer (Contracts.claimSlot)
---@param opts table|nil { receipt = send the hitman theirs (hitmanReceipt) }; the client's
--- is kept for their next login when they are away, always
function Notify.contractCompleted(contract, hitmanRecord, proof, result, opts)
    if not contract then return end
    local delivered = type(proof) ~= 'table'
    local kept = not delivered and type(proof.photo) == 'string' and proof.photo ~= ''
    local waiting = 'The photo is waiting under Ledger. You can see it once: save it to '
        .. 'your Photos to keep it.'
    -- A receipt, so outside the budget (§14.40). Relay messages spend the
    -- same budget, so five from the hitman in the minute before the kill
    -- used to mean the creator never heard it had been done.
    -- The photo is mentioned only while there is one: with StorePhotos off,
    -- pointing at the Ledger sent the client looking for a picture that was
    -- never kept.
    -- And with kill photos switched off (Config.Completion.KillPhotos) a
    -- photograph is not mentioned even to say there is none: there never is.
    local body
    if delivered and not Util.killPhotos() then
        body = 'Your contract was fulfilled by live delivery: the target was handed over '
            .. 'in person.'
    elseif delivered then
        body = 'Your contract was fulfilled by live delivery. There is no '
            .. 'photograph — the target was handed over in person.'
    elseif kept then
        body = 'Your contract was fulfilled. ' .. waiting
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
            delivered and ' by live delivery' or '')
        if kept then body = body .. ' ' .. waiting end
        body = body .. (' It is still running, with %d more to collect.')
            :format(tonumber(result.remaining) or 0)
    end
    -- Kept for a client who is away, whichever way it was paid: a kill
    -- verified while they were out of the city (an 'either' contract) told
    -- them nothing, then or at their next login.
    Notify.tellOrKeep(contract.creator_cid, title, body, { bypassBudget = true }, contract.id)

    if opts and opts.receipt then
        local cid = type(hitmanRecord) == 'table' and hitmanRecord.cid or hitmanRecord
        if type(cid) == 'string' then
            local receiptTitle, receiptBody = Notify.hitmanReceipt(contract, delivered, result)
            Notify.tellOrKeep(cid, receiptTitle, receiptBody, { bypassBudget = true }, contract.id)
        end
    end
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
--- Kept with the contract it is about, so the admin panel can leave out one
--- about a contract the player was anonymous on (Notify.waitingFor).
local function tellOrKeep(cid, title, content, opts, contractId)
    if not cid then return false end
    if Identity.byCitizenId(cid) then
        -- With the contract it is about, which one kept past the budget is
        -- coalesced by.
        local sendOpts = { contractId = contractId }
        for k, v in pairs(opts or {}) do sendOpts[k] = v end
        return Notify.toCitizen(cid, title, content, sendOpts)
    end
    local list = waiting[cid] or {}
    if #list >= WAITING_CAP then table.remove(list, 1) end
    list[#list + 1] = { title = title, content = content, opts = opts, contract_id = contractId }
    waiting[cid] = list
    return false
end
--- For the other modules' notices that must not be lost to a logoff: an
--- idle release, an agreed change that ended a contract or was refused.
Notify.tellOrKeep = tellOrKeep

--- One "New message" kept for a player who was away when a message on
--- their contract came (Comms.send), however many come: one per contract,
--- the newest in place of the one before. Never the message itself, which
--- they read in the thread, and never who sent it. Dropped with the
--- contract (Notify.clearContract): its thread closes with it, and a notice
--- sending them to a conversation that is gone would be a dead end.
---@param cid string
---@param contract table
function Notify.keepMessageNotice(cid, contract)
    if not cid or type(contract) ~= 'table' or not contract.id then return end
    local list = waiting[cid] or {}
    for i = #list, 1, -1 do
        if list[i].message and list[i].contract_id == contract.id then table.remove(list, i) end
    end
    if #list >= WAITING_CAP then table.remove(list, 1) end
    list[#list + 1] = {
        title = 'Contract message',
        content = ('New message about your contract on %s. Open it from Mine.')
            :format(contract.target_name or 'your target'),
        contract_id = contract.id, message = true,
    }
    waiting[cid] = list
end

--- How many notices wait for a player's next login, and their titles, for
--- the admin panel's player view. Titles only: the text can name a
--- contract's other parties, and the panel shows those under its own rules.
--- And by those rules not a notice `skip` says to leave out: a 'Contract
--- expired' kept for an offline player, beside an anonymous contract that
--- just expired, said who had placed it.
---@param cid string
---@param skip fun(contractId: string|nil): boolean|nil
---@return integer count
---@return string[] titles
function Notify.waitingFor(cid, skip)
    local list = cid and waiting[cid] or {}
    local titles = {}
    for i = 1, #list do
        if not (skip and skip(list[i].contract_id)) then titles[#titles + 1] = tostring(list[i].title) end
    end
    return #titles, titles
end

--- Hand a player what was kept for them while they were away. Called from
--- Bridges.onPlayerReady, once they can receive it.
---
--- Outside the budget, every one: they were rationed when they were kept.
--- Replayed through it, a player who came back to seven lost the seventh,
--- with the list already cleared.
---@return integer delivered
function Notify.deliverWaiting(cid)
    local list = cid and waiting[cid]
    if not list or not Identity.byCitizenId(cid) then return 0 end
    waiting[cid] = nil
    for i = 1, #list do
        Notify.toCitizen(cid, list[i].title, list[i].content, { bypassBudget = true })
    end
    return #list
end

--- Send what was kept for players in the city, as far as their budget
--- has room: a notice that found its player past the budget (toCitizen),
--- in the order kept. Once a minute from the maintenance tick, when the
--- minute that was full has opened again. One kept outside the budget (a
--- receipt kept for a login that has not come yet) goes as it is.
---@return integer sent
function Notify.deliverKept()
    local cids = {}
    for cid in pairs(waiting) do cids[#cids + 1] = cid end
    table.sort(cids)
    local sent = 0
    for _, cid in ipairs(cids) do
        local actor = Identity.byCitizenId(cid)
        local list = waiting[cid]
        if actor and list then
            local left = {}
            for i = 1, #list do
                local note = list[i]
                -- Notify me, turned off since by them or by the server, or
                -- the view no longer theirs: let go, not sent.
                local unwanted = note.opts and note.opts.view and not viewViewer(actor)
                if not unwanted then
                    if (note.opts and note.opts.bypassBudget) or withinBudget(cid) then
                        raise(actor, cid, note.title, note.content)
                        sent = sent + 1
                    else
                        left[#left + 1] = note
                    end
                end
            end
            waiting[cid] = #left > 0 and left or nil
        end
    end
    return sent
end

--- Tell a player what owed payments just reached them (Escrow.retryPending's
--- summary): by amount, "$5,000 and 2 item(s) you were owed have arrived",
--- and how many still wait. "2 outstanding items have been delivered" called
--- cash an item and named no figure. Outside the budget: a receipt.
---@param cid string
---@param count integer lines delivered
---@param summary table|nil { money, goods, left }
---@return boolean sent
function Notify.outstandingDelivered(cid, count, summary)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return false end
    local body
    if type(summary) == 'table' then
        local money = math.floor(tonumber(summary.money) or 0)
        local goods = math.floor(tonumber(summary.goods) or 0)
        local left = math.floor(tonumber(summary.left) or 0)
        local parts = {}
        if money > 0 then parts[#parts + 1] = Notify.dollars(money) end
        if goods > 0 then parts[#parts + 1] = ('%d item(s)'):format(goods) end
        local what = table.concat(parts, ' and ')
        if what == '' then what = ('%d payment(s)'):format(count) end
        body = ('%s you were owed %s arrived'):format(what,
            (money > 0 and goods == 0) and 'has' or 'have')
            .. (left > 0 and ('; %d more %s still waiting for you.'):format(left,
                left == 1 and 'is' or 'are') or '.')
    else
        body = ('%d outstanding item%s been delivered.')
            :format(count, count == 1 and ' has' or 's have')
    end
    return Notify.toCitizen(cid, 'Outstanding payment', body, { bypassBudget = true })
end

--- Dollars as the page writes them (ui/app.js money()): "$100,000".
---@param amount number
---@return string
local function dollars(amount)
    local digits = tostring(math.floor(math.abs(tonumber(amount) or 0)))
    local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return ((tonumber(amount) or 0) < 0 and '-$' or '$') .. grouped
end
Notify.dollars = dollars

--- The sentence that ends a hitman's notice: where their stake went. Left
--- out when they had none.
local function stakeSentence(outcome)
    if (outcome.stake or 0) <= 0 then return '' end
    if outcome.forfeited then
        return (' Your %s stake went to the person who placed the contract.')
            :format(dollars(outcome.stake))
    end
    -- Its give raised and what arrived could not be read: no retry gives
    -- it, so "handed back as soon as you can take it" was untrue of it.
    if outcome.parked then
        return (' Your %s stake could not be confirmed as handed back; staff have been '
            .. 'asked to check it.'):format(dollars(outcome.stake))
    end
    if outcome.owed then
        return (' Your %s stake is held for you and is handed back as soon as '
            .. 'you can take it.'):format(dollars(outcome.stake))
    end
    return (' Your %s stake has been returned.'):format(dollars(outcome.stake))
end

--- A wait in the words a player reads: seconds under a minute, else
--- minutes, rounded up.
local function waitWords(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 60 then return ('%d second%s'):format(seconds, seconds == 1 and '' or 's') end
    local minutes = math.ceil(seconds / 60)
    return ('%d minute%s'):format(minutes, minutes == 1 and '' or 's')
end

--- The receipt a hitman is sent for a collection paid to them
--- (contractCompleted, `receipt`): outside the budget and kept for their
--- next login. A live delivery is ended by the server, not by a tap, and a
--- hitman holding a target for thirty seconds is the one most likely to
--- have put the phone away: the paid ending was the one that sent them
--- nothing. And a collection recovery found paid (a claim that stopped
--- part-way), whose hitman was told it had failed.
---
--- What reached them and what did not: held until they make room, or left
--- for staff to check (Escrow.parked); on the last collection where their
--- stake went, and otherwise how many remain and when they may collect
--- again (Config.Limits.SlotCooldownSeconds).
---@param contract table
---@param delivered boolean a live delivery, not a kill
---@param result table|nil the claim's answer, or recovery's (creditRecovered)
---@return string title
---@return string body
function Notify.hitmanReceipt(contract, delivered, result)
    result = type(result) == 'table' and result or {}
    local money = math.floor(tonumber(result.money) or 0)
    local goods = math.floor(tonumber(result.goods) or 0)
    local what
    if money > 0 and goods > 0 then
        what = ('%s and %d item(s)'):format(dollars(money), goods)
    elseif money > 0 then
        what = dollars(money)
    elseif goods > 0 then
        what = ('%d item(s)'):format(goods)
    end

    local title, body
    if result.recovered then
        title = 'Payout recorded'
        body = ('Your payout on the contract on %s was recorded after a fault')
            :format(contract.target_name or 'your target')
            .. (what and (': ' .. what .. ' released to you.') or '.')
    else
        title = delivered and 'Handover paid' or 'Kill paid'
        body = (delivered and 'Delivered alive' or 'Kill verified')
            .. (what and (': ' .. what .. ' released to you.') or ': your payout was released.')
    end

    if (tonumber(result.pending) or 0) > 0 then
        body = body .. (result.recovered
            and ' Part of it is held for you and is handed over as soon as you can take it.'
            or ' Part of it is held until you make room: make room and it is handed over.')
    end
    if (tonumber(result.parked) or 0) > 0 then
        body = body .. ' Part of it could not be confirmed; staff have been asked to check it.'
    end

    if result.exhausted == false then
        local left = math.floor(tonumber(result.remaining) or 0)
        body = body .. (' The contract is still running, with %d more to collect')
            :format(left)
        local wait = tonumber(Config.Limits.SlotCooldownSeconds) or 0
        -- Not after a recovery: whether the claim that stopped had started
        -- the wait is not known.
        if wait > 0 and not result.recovered then
            body = body .. ('; you can collect again in %s.'):format(waitWords(wait))
        else
            body = body .. '.'
        end
    elseif type(result.stake) == 'table' then
        body = body .. stakeSentence(result.stake)
    end
    return title, body
end

--- What a hitman still on the contract is told, by how it ended. nil for an
--- ending that already reaches them some other way.
local function hitmanNotice(contract, ending, outcome)
    local target = contract.target_name or 'your target'
    if ending == CH.STATE.EXPIRED then
        -- A payout they collected on it before it ran out is theirs, and said
        -- so: "the deadline passed" alone, beside a stake gone, read as the
        -- contract having paid them nothing.
        local paid = math.floor(tonumber(outcome.claims) or 0)
        local collected = paid > 0
            and (' You were paid for %d collection%s on it.'):format(paid, paid == 1 and '' or 's')
            or ''
        return 'Contract expired', (outcome.forfeited
            and ('The deadline on your contract on %s passed.'):format(target)
            or  ('Your contract on %s ran out before it could be finished.'):format(target))
            .. collected
    elseif ending == CH.STATE.BAILED_OUT then
        return 'Contract closed', ('%s bought their way out of your contract.'):format(target)
    elseif ending == CH.STATE.VOIDED then
        return 'Contract closed', ('Staff closed your contract on %s.'):format(target)
    elseif ending == CH.STATE.COMPLETED then
        return 'Contract closed', ('Another operative finished the contract on %s.'):format(target)
    elseif ending == CH.STATE.CANCELLED and contract.resolution == 'cancelled_by_agreement' then
        -- With a hitman on it, only by a change everybody agreed to. Only the
        -- one who pressed the last Agree heard anything, and the one who had
        -- proposed it never learnt it went through, or where their stake went.
        return 'Contract called off', ('The contract on %s was called off by agreement.')
            :format(target)
    end
    return nil
end

--- Whether the target was ever told this contract existed — by the paranoid
--- alert, or as an officer by their own advisory — as it happened (`told`),
--- not as the switches read now: a contract placed with alerts off and
--- ending after they were turned on told a target who never heard of it
--- that it had lapsed, and the reverse left one who had been told without
--- a word.
local function targetWasTold(contract)
    return told[contract.id] == true
end

--- What a client is told came back on an ending that returns their escrow,
--- by the payouts already collected: "everything you put up has been
--- returned" after a collection was paid was untrue by that collection.
---@return string|nil phrase nil when nothing was collected
local function collectedPhrase(contract)
    local claimed = math.floor(tonumber(contract.slots_claimed) or 0)
    if claimed <= 0 then return nil end
    return ('%d of %d payouts were collected'):format(claimed,
        math.max(claimed, math.floor(tonumber(contract.payout_slots) or 1)))
end
Notify.collectedPhrase = collectedPhrase

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
                    { bypassBudget = true }, contract.id)
            end
        end
    end

    -- An agreed cancel is new to the creator too: nothing else tells them
    -- it closed, what came back, or what still waits for them. Worded as
    -- their own withdrawal words it (Contracts.cancel).
    -- What was left for staff to check is said apart (Escrow.parked): its
    -- give raised and no retry gives it, so "they arrive" was untrue of it.
    local parked = opts.creatorParked or 0
    local staffCheck = parked > 0
        and (' %d thing(s) could not be confirmed as handed back; staff have been asked '
             .. 'to check.'):format(parked) or ''

    if ending == CH.STATE.CANCELLED and contract.resolution == 'cancelled_by_agreement' then
        local waits = opts.creatorOwed or 0
        tellOrKeep(contract.creator_cid, 'Contract called off',
            ('Your contract on %s was called off by agreement. '):format(
                contract.target_name or 'your target')
            .. ((waits > 0 or parked > 0)
                and ('Most of what you put up is back.' .. (waits > 0
                    and (' %d thing(s) would not fit and are waiting for you — they arrive '
                         .. 'when you next have room.'):format(waits) or '') .. staffCheck)
                or 'Everything you put up has been returned.'),
            { bypassBudget = true }, contract.id)
        return
    end

    if ending ~= CH.STATE.EXPIRED then return end

    -- Only an expiry is new to the creator: cancel, void, buyout and
    -- completion each tell them already.
    local owed = opts.creatorOwed or 0
    local collected = collectedPhrase(contract)
    local body = ('Nobody finished your contract on %s in time.')
        :format(contract.target_name or 'your target')
    if owed > 0 then
        body = body .. (collected and (' ' .. collected .. '; the rest of what you put up is '
                .. 'coming back:') or ' What you put up is coming back:')
            .. (' %d thing(s) could not be handed over yet and arrive as soon as you can '
                .. 'take them.'):format(owed)
    elseif parked == 0 then
        body = body .. (collected
            and (' ' .. collected .. '; the rest of what you put up has been returned.')
            or ' Everything you put up has been returned.')
    elseif collected then
        body = body .. ' ' .. collected .. '.'
    end
    body = body .. staffCheck
    if forfeitedCount == 1 then
        body = body .. (" The operative's %s stake is yours."):format(dollars(forfeitedTotal))
    elseif forfeitedCount > 1 then
        body = body .. (" The operatives' stakes, %s in all, are yours."):format(dollars(forfeitedTotal))
    end
    tellOrKeep(contract.creator_cid, 'Contract expired', body, { bypassBudget = true }, contract.id)

    -- The target only when they were told there was a price on their head
    -- at all. Anyone else would learn of a contract from its ending. Worded
    -- as one price, because it may not have been the only one. And only once
    -- it was shown to them (Notify.shownToTarget, read here, before
    -- clearContract forgets it): one that ran out inside the wait, its alert
    -- never sent, was the one notice they had of it, and dated it.
    if targetWasTold(contract) and Notify.shownToTarget(contract) then
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
        { bypassBudget = (stake or 0) > 0 }, contract.id)
end

--- Warn the operatives on a contract that its target has paid to close it.
--- The processing delay exists so they can finish first (§14.17), which a
--- hitman who never hears of it cannot do. Outside the budget and kept for
--- one who is away, as a receipt is: it was lost to a full budget, and it
--- is the one warning the delay exists to give. Their card counts it down
--- too (Projection: buyoutClosesIn).
---@param contract table
---@param hitmanCids string[]
---@param seconds integer what is left of the processing delay
function Notify.buyoutQueued(contract, hitmanCids, seconds)
    if not contract then return end
    seconds = math.floor(tonumber(seconds) or 0)
    -- Never more time than they have: whole minutes from two up, rounded
    -- down, and seconds below that.
    local wait = seconds >= 120 and ('%d minutes'):format(seconds // 60)
        or ('%d seconds'):format(seconds)
    local body = ('%s is buying their way out of your contract. It closes in %s '
        .. 'unless you finish it first.'):format(contract.target_name or 'Your target', wait)
    for i = 1, #(hitmanCids or {}) do
        tellOrKeep(hitmanCids[i], 'Contract challenged', body, { bypassBudget = true }, contract.id)
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

--- What a contract keeps as its acceptance bulletins' count
--- (advised_hitmen) once whether it was taken is unknown: it was live
--- while acceptance bulletins were off. The whitelisted-job view shows it
--- neither open nor taken until a bulletin says its count.
Notify.ACCEPTANCE_UNKNOWN = -1

--- Acceptance bulletins have stopped (Util.advises('accepted') is false):
--- turned off from the admin panel, or off at this start. Every live
--- contract the view would otherwise call open (a posting bulletin and no
--- acceptance one) is marked unknown, so one taken while they are off is
--- not listed as open once they are back on. All of them, whether taken
--- or not: marking only the one taken would say which. One no posting
--- bulletin went out for is never called open, so it is left as it is.
---@param contracts table[] the live contracts (Storage.liveContracts)
---@return integer marked
function Notify.forgetAcceptances(contracts)
    if not Storage then return 0 end
    local marked = 0
    for _, contract in ipairs(contracts or {}) do
        if contract.advised_hitmen == nil and contract.advised_posted_at ~= nil then
            Storage.setAdvised(contract.id, { advised_hitmen = Notify.ACCEPTANCE_UNKNOWN })
            marked = marked + 1
        end
    end
    return marked
end

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

    -- Who has Notify me on their whitelisted-job view, and whether it lists
    -- this contract already, before this bulletin's words are kept on it.
    local viewers = viewBefore(contract)
    local kept

    -- What it says, kept on the contract as it goes out: the whitelisted-job
    -- view lists a colleague's contract from this (Projection.whitelistedView),
    -- never from the advisory as it is set now. Read from the setting, a
    -- contract placed and taken while advisories were off, which no bulletin
    -- announced, was listed as posted and taken the moment they were turned
    -- back on. The count is the one this bulletin carries, so the view never
    -- says more hitmen than a bulletin did. Not a reason to send nothing.
    if Storage then
        local said = stage == 'posted' and { advised_posted_at = os.time() }
            or { advised_hitmen = math.max(1, math.floor(tonumber(activeHitmen) or 1)) }
        -- Posted while acceptance bulletins are off: whether it is taken is
        -- unknown from the start (Notify.forgetAcceptances), not open.
        if stage == 'posted' and not Notify.advises('accepted') then
            said.advised_hitmen = Notify.ACCEPTANCE_UNKNOWN
        end
        local okSaid, errSaid = pcall(Storage.setAdvised, contract.id, said)
        if not okSaid then
            Log.always(('could not keep what the advisory said of contract %s: %s')
                :format(tostring(contract.id), tostring(errSaid)))
        else
            kept = said
        end
    end

    -- The bulletin dates the contract to the second for every officer
    -- online, the one it names included, so the wait has nothing left to
    -- hide (contractCreated skips it for a posting bulletin). With only the
    -- acceptance bulletin on, an officer told "The contract on you has been
    -- accepted" was told by /cleanse that nothing was out on them.
    revealAt[contract.id] = nil

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

    -- With it: Notify me, to each of them whose whitelisted-job view lists
    -- the contract from this bulletin on, and not before it.
    viewAfter(viewers, kept)

    -- The targeted officer is told directly whatever the paranoid-alert
    -- setting says: with the whitelisted-job view off they cannot open the
    -- app to check for themselves, and with it on (as shipped) this is what
    -- tells them to look.
    -- "Your department" only where their job is one the advisory goes to: a
    -- medic or a lawyer was told their department had been advised, and
    -- nobody in it was.
    -- Kept for an officer who is away, as the alert is for anybody else:
    -- this is what they are told instead of it (Notify.advisedTarget).
    if Config.Advisory.AlwaysAlertTarget then
        local whoKnows = Identity.protectedCategory(contract.target_job) == 'law'
            and 'Your department has been advised.' or 'Law enforcement has been advised.'
        told[contract.id] = true
        tellOrKeep(contract.target_cid, title,
            stage == 'posted'
                and ('A contract has been placed on you. ' .. whoKnows)
                or  ('The contract on you has been accepted. %d operative%s active.')
                        :format(activeHitmen or 1, (activeHitmen or 1) == 1 and ' is' or 's are'),
            { bypassBudget = true }, contract.id)
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
    relayBudgets[cid] = nil
    lastPush[cid] = nil
    trailing[cid] = nil
    -- A cooldown still running is kept: relogging must not buy a second
    -- alert, and with it a count.
    if (paranoidUntil[cid] or 0) <= os.time() then paranoidUntil[cid] = nil end
    -- Their Notify me choice is read again next time, and a notice kept
    -- for them past the budget is not sent at their next login, by then
    -- old news their view shows anyway.
    viewOptIn[cid] = nil
    dropKeptView(cid)
end

function Notify.clearContract(contractId, contract)
    revealAt[contractId] = nil
    told[contractId] = nil
    -- A kept "New message" about it (Notify.keepMessageNotice): its thread
    -- has closed. And a Notify me notice kept past the budget, or still
    -- waiting out the wait: its entry has left the view.
    for cid, list in pairs(waiting) do
        for i = #list, 1, -1 do
            if (list[i].message or (list[i].opts and list[i].opts.view))
                and list[i].contract_id == contractId then
                table.remove(list, i)
            end
        end
        if #list == 0 then waiting[cid] = nil end
    end
    viewWaiting[contractId] = nil
    for key in pairs(viewTold) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then viewTold[key] = nil end
    end
    -- An alert still waiting goes only while a contract it stands for is
    -- still out. With none left it never goes (and no cooldown was started:
    -- that starts when it is sent). With some left, it goes at the earliest
    -- reveal among them, never before On me shows one.
    local targets = {}
    for targetCid, alert in pairs(pendingAlert) do
        if alert.ids[contractId] then targets[#targets + 1] = targetCid end
    end
    for i = 1, #targets do
        local alert = pendingAlert[targets[i]]
        alert.ids[contractId] = nil
        if next(alert.ids) then
            armAlert(targets[i], alert)
        else
            pendingAlert[targets[i]] = nil
        end
    end
    for key in pairs(advisorySent) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then advisorySent[key] = nil end
    end
    for key in pairs(announced) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then announced[key] = nil end
    end

    -- Take the threat off the MDT. sc-dispatch files an advisory as an
    -- active call, and nothing closed it: an officer's dispatch list kept a
    -- live threat against a colleague for a contract long since settled.
    -- Every stage that could have been filed is cleared, because what was
    -- sent before a restart is not remembered — and whatever the advisory
    -- settings say now: staff turning Advisory.Enabled, OnCreate, OnAccept
    -- or UseDispatch off while one was up left it there for good. Clearing
    -- an id never filed does nothing. In a thread of its own: the export
    -- waits on the database, and this is the end of a settlement.
    if contract and contract.target_protected and GetResourceState('sc-dispatch') == 'started' then
        local jobs = dispatchJobs()
        for _, stage in ipairs({ 'posted', 'accepted' }) do
            local uid = 'ch-' .. contractId .. '-' .. stage
            CreateThread(function()
                pcall(function() exports['sc-dispatch']:ClearNotification(uid, jobs) end)
            end)
        end
    end
end

return Notify
