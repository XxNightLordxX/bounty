--- Per-recipient payload building (§14.4).
---
--- Anonymity is enforced by omission, not by masking: an anonymous creator's
--- identity is never placed in the payload at all, so there is nothing for a
--- client-side inspector to find. Every send point in the resource builds its
--- payload here and nowhere else.

local Projection = {}

local Util = CrimsonBoot.requireShared('util')

local Storage, Identity, Escrow, Kidnap, Mugshot, Progression, Comms, Informant, Notify
--- Informant tips (server/locationtip.lua): a hitman's own, on their card,
--- and when the target was told, on theirs.
local LocationTip

function Projection.init(deps)
    Storage, Identity, Escrow, Kidnap, Mugshot, Progression, Comms, Informant, Notify =
        deps.storage, deps.identity, deps.escrow, deps.kidnap, deps.mugshot, deps.progression,
        deps.comms, deps.informant, deps.notify
    LocationTip = deps.locationTip
end

--- Roles a viewer can hold relative to a contract. The role decides the key
--- set, and the key set is asserted in the test suite so a refactor cannot
--- widen it silently.
local function roleOf(contract, viewerCid)
    if contract.creator_cid == viewerCid then return 'creator' end
    if contract.target_cid == viewerCid then return 'target' end
    local hitman = Storage.readHitman(contract.id, viewerCid)
    if hitman and hitman.state == 'active' then return 'hitman' end
    return 'public'
end

--- Is this contract listed for this viewer right now?
--- Both parties must be online (§7.1), and a viewer never sees a contract
--- they are barred from.
local function listedFor(contract, viewerCid)
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then return false end

    -- Except that an anonymous creator's presence is not asked at all
    -- (§14.32). Hiding their contract whenever they logged off made the
    -- board a record of their session: every viewer could watch it vanish
    -- and come back, set that beside who left and rejoined the city, and
    -- after a few evenings the intersection is one person. The target's
    -- presence is theirs to reveal, and the contract is about them anyway.
    local creatorOnline = contract.anon_creator == true
        or Identity.byCitizenId(contract.creator_cid) ~= nil
    local targetOnline = Identity.byCitizenId(contract.target_cid) ~= nil
    if not (creatorOnline and targetOnline) then return false end

    -- A target is not shown their own contract in the public list; they see
    -- it in their own Cleanse tab, which is a different projection.
    if contract.target_cid == viewerCid then return false end

    return true
end

--- Money-equivalent of the slot currently being competed for, which is what
--- a hitman is deciding on.
local function currentReward(contract)
    local slot = contract.next_slot or 1
    return {
        baseline = Escrow.moneyValue(contract.id, { slot = slot, portion = CH.PORTION.BASELINE }),
        bonus    = Escrow.moneyValue(contract.id, { slot = slot, portion = CH.PORTION.BONUS }),
        -- Items and weapons are not priced, so a contract paying a kitted
        -- rifle and nothing else showed as $0. The counts and the item names
        -- cross; serials and metadata do not.
        goods    = Escrow.goodsIn(contract.id, { slot = slot, portion = CH.PORTION.BASELINE }),
        bonusGoods = Escrow.goodsIn(contract.id, { slot = slot, portion = CH.PORTION.BONUS }),
        -- Split by source, because the three are not worth the same. Black
        -- money sells for a fraction of its face value, and adding it into
        -- the headline figure told a hitman a contract paid a quarter of a
        -- million when a quarter of a million of it was black_money items.
        sources  = Escrow.moneyBySource(contract.id, { slot = slot, portion = CH.PORTION.BASELINE }),
        bonusSources = Escrow.moneyBySource(contract.id, { slot = slot, portion = CH.PORTION.BONUS }),
    }
end

--- What the viewer's own informant purchase on this contract came back
--- with, as the words to show. Only ever the viewer's own: the record is
--- keyed by buyer, so a creator and a target who both bought each see theirs.
---
--- Whatever Config.Informant.Enabled says: a name already bought was paid
--- for under the rules of the moment it was bought, and stays shown for as
--- long as it would have (Informant.answerFor). Turning the informant off
--- refuses new purchases (Informant.buy); hiding what was paid for took
--- from the target what Config.Informant.Cost had bought.
---
--- With it, how many purchases the viewer has left on the contract, where
--- the server runs informants: their own count, so their card can drop the
--- button once none are left and say when this is the last.
---@return string|nil answer
---@return integer|nil left
local function informantFor(contractId, viewerCid)
    if not Informant then return nil, nil end
    local answer, left = Informant.answerFor(contractId, viewerCid)
    if Config.Informant.Enabled ~= true then left = nil end
    if type(answer) ~= 'table' then return nil, left end
    return answer.name or answer.description, left
end

--- A single contract, projected for one viewer.
---@param contract table
---@param viewerCid string
---@return table|nil
function Projection.contract(contract, viewerCid)
    local role = roleOf(contract, viewerCid)
    local hitmen = Storage.readHitmen(contract.id)

    local activeHitmen = 0
    for i = 1, #hitmen do
        if hitmen[i].state == 'active' then activeHitmen = activeHitmen + 1 end
    end

    local reward = currentReward(contract)

    local out = {
        id            = contract.id,
        reason        = contract.reason,
        mode          = contract.mode,
        state         = contract.state,
        reward        = reward,
        -- How it may be completed, as it was placed: 'alive', only by a live
        -- handover, or 'either', a kill too. A term like the reward, the
        -- same for every viewer, so the page can say what pays and draw
        -- Verify kill only where a kill can.
        fulfilment    = Util.fulfilmentRule(contract),
        bonusPercent  = contract.bonus_percent,
        slots         = contract.payout_slots or 1,
        slotsClaimed  = contract.slots_claimed or 0,
        currentSlot   = contract.next_slot or 1,
        hitmenActive = activeHitmen,
        hitmenMax    = Config.Limits.MaxHitmenPerContract,
        targetName    = contract.target_name,
        -- The listing carries a *reference* to the target's live headshot
        -- (§7.2), not the image. Inlining the base64 put a whole image in
        -- every row of every page for every viewer — a 40 KB face across a
        -- 15-row listing is 600 KB per tab change, re-sent every time. The
        -- app fetches an image once per handle and caches it, and a new
        -- render mints a new handle, so nothing has to be invalidated.
        --
        -- The call is still made here, because asking is what schedules the
        -- refresh; only its return value is discarded.
        --
        -- Not before the target is shown the contract (Notify.shownToTarget).
        -- Asking is an event to the target's own client, and the first ask
        -- was the creator's own reply to placing it, so a client that logs
        -- its events learned the second it was placed, which the alert's
        -- wait exists to hide. A face already cached is still shown: reading
        -- it sends nothing.
        targetImageId = Mugshot and (function()
            if Notify.shownToTarget(contract) then Mugshot.request(contract.target_cid) end
            return Mugshot.handleFor(contract.target_cid)
        end)() or nil,
        targetProtected = contract.target_protected or false,
        -- What kind of protected job ('law', 'emergency', 'legal', 'other'),
        -- so the page words a medic as a medic: every protected target was
        -- "a sworn officer". The kind of job only, never which force, and
        -- only where the flag above is already set.
        targetProtectedAs = contract.target_protected
            and Identity.protectedCategory(contract.target_job) or nil,
        deadline      = contract.deadline_at,
        -- The clock as the server reads it, the same sum stakeTimeRefusal
        -- makes. deadline_at stands still while a contract is paused and is
        -- pushed on when the pause ends, so a page counting down to it
        -- alone ran through every pause and could tell a hitman their
        -- stake was gone on a contract that was not running at all. For an
        -- anonymous client the pause follows the target alone (§14.32), so
        -- whether it is stopped says nothing about the client. The target's
        -- own card is read differently, below.
        secondsLeft   = contract.deadline_at
            and math.max(0, contract.deadline_at - (contract.paused_since or os.time()))
            or nil,
        clockStopped  = contract.paused_since ~= nil,
        role          = role,
        -- What accepting costs, to everyone who can see the contract.
        --
        -- This was emitted for the creator alone, and acceptance debits it
        -- anyway — so a hitman tapped Accept on a board listing and watched
        -- a stake they had never been shown leave their bank, forfeit to
        -- the creator if they later abandoned or ran out of clock. §3.6
        -- says a hitman who cannot cover it "is told so", and §14.18 that
        -- "the required stake is shown prominently on the listing before
        -- the accept button"; the comment above the debit in contracts.lua
        -- claims "the hitman is told the amount before this point", which
        -- was a description of a rule rather than of the code. The app can
        -- only word its own warning vaguely for the same reason.
        --
        -- Always present, including zero: "no stake" and "not told" are
        -- different things and the page has to be able to tell them apart.
        penaltyAmount = contract.penalty_amount or 0,
    }

    -- Why this viewer can never take it, where that is so. The board drew
    -- Accept on these and acceptance refused every time: a hold released
    -- for sitting on it (on this character or another of the account's),
    -- and a contract another of the viewer's own characters placed or is
    -- the target of. Only the reason is sent, never whose account matched.
    if role == 'public' then
        local viewer = Identity.byCitizenId(viewerCid)
        local account = viewer and viewer.account
        for i = 1, #hitmen do
            local h = hitmen[i]
            if h.state == 'released' and (h.hitman_cid == viewerCid
                or Identity.sameAccount(h.hitman_account, account)) then
                out.barred = 'hold_released'
                break
            end
        end
        if not out.barred and Config.AntiCollusion.BlockSameAccount and account then
            local target = Identity.byCitizenId(contract.target_cid)
            if Identity.sameAccount(contract.creator_account, account)
                or (target and Identity.sameAccount(target.account, account)) then
                out.barred = 'same_account'
            end
        end
    end

    -- The creator's identity is present only when they chose to be seen.
    -- When anonymous, no key carrying it exists on the payload.
    if not contract.anon_creator then
        out.creatorName = contract.creator_name
    else
        out.creatorAnonymous = true
    end

    if role == 'creator' then
        out.bailoutAmount = contract.bailout_amount
        -- Whether anybody ever took it up, as Contracts.canCreate counts it
        -- (everTakenUp): one who walked away or was released did. Their own
        -- contract, and every acceptance and walk-away was told to them as
        -- it happened, so it says nothing new. Withdraw told them "Nobody
        -- has taken it" after an operative had and walked away, and left
        -- out that withdrawing it then starts the wait on the target for
        -- every client.
        out.everTaken = false
        for i = 1, #hitmen do
            local state = hitmen[i].state
            if state ~= 'refused' and state ~= 'joining' then
                out.everTaken = true
                break
            end
        end
        -- What the contract holds in money, against the ceiling on what one
        -- contract may be worth: the add-to-reward box offered amounts the
        -- server could only refuse, as a reward that did not add up.
        out.valueHeld = Escrow.moneyValue(contract.id)
        out.informantAnswer, out.informantLeft = informantFor(contract.id, viewerCid)
        -- The creator learns how many operatives are on it, never who they
        -- are, unless a hitman chose to be seen.
        out.hitmen = {}
        for i = 1, #hitmen do
            local h = hitmen[i]
            if h.state == 'active' then
                out.hitmen[#out.hitmen + 1] = {
                    alias = h.alias,
                    name  = (not h.anon) and h.hitman_name or nil,
                    claims = h.claims or 0,
                    -- A record, not an identity. For an anonymous hitman
                    -- only the coarse standing crosses: exact counters are a
                    -- stable fingerprint that links the same person across
                    -- contracts, which is the thing anonymity is for.
                    record = Progression and (h.anon
                        and { standing = Progression.record(h.hitman_cid).standing }
                        or Progression.record(h.hitman_cid)) or nil,
                    -- The newest message from them in their thread, for the
                    -- unread dot on Threads: a time already in that thread.
                    lastMessageAt = Comms and Config.Relay.Enabled
                        and Comms.lastMessageAt(contract.id, h.hitman_cid, viewerCid) or nil,
                }
            end
        end
        -- The handover's meeting point (server/meeting.lua): whether one is
        -- set, for the controls on an alive-only contract a hitman holds,
        -- while Config.Kidnap.MeetingPoint is on. Absent, no controls. Never
        -- where it is: they stood there, and the page does not need it.
        if Config.Kidnap.MeetingPoint == true
            and Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE
            and (contract.state == CH.STATE.ACCEPTED or contract.state == CH.STATE.COMPLETING)
            and activeHitmen > 0 then
            out.meetingSet = contract.meeting_x ~= nil
        end
    elseif role == 'hitman' then
        local mine = Storage.readHitman(contract.id, viewerCid)
        out.myAlias = mine and mine.alias or nil
        -- Their own, so nothing is disclosed. The page worded "accepted,
        -- anonymously" from the button pressed, not from what was recorded.
        out.myAnonymous = mine and mine.anon == true or false
        out.myClaims = mine and mine.claims or 0
        -- The newest message to them in their thread, for the unread dot on
        -- Message: a time already in that thread.
        out.lastMessageAt = Comms and Config.Relay.Enabled
            and Comms.lastMessageAt(contract.id, viewerCid, viewerCid) or nil
        if Kidnap then
            out.kidnapProgress = Kidnap.progress(contract.id, viewerCid)
        end
        -- That the person who placed it set a meeting point for the
        -- handover, and nothing of where: Set GPS asks the server for it
        -- (Meeting.waypoint) and their game marks it on the map, so the
        -- coordinates are never on a card. An active hitman of a live
        -- contract only (role 'hitman'), and only while the feature is on.
        if Config.Kidnap.MeetingPoint == true and contract.meeting_x ~= nil
            and not CH.TERMINAL[contract.state] then
            out.meetingSet = true
        end
        -- The target's buyout waiting out its delay, counted down on their
        -- card. Their one word of it was a phone notice (Notify.buyoutQueued)
        -- that a full budget, a logoff or an acceptance inside the delay
        -- missed, and the delay is there for them to finish first. Says
        -- nothing that notice does not: when it was paid, to the second.
        if contract.bailout_queued_at then
            out.buyoutClosesIn = math.max(0, contract.bailout_queued_at
                + (Config.Bailout.ProcessingDelaySeconds or 0) - os.time())
        end
        -- Their own informant tips on it (server/locationtip.lua): how many
        -- are left, when the next may be bought, how long the one bought is
        -- still on their map. Never the area, which only their game holds.
        out.locationTip = LocationTip and LocationTip.cardFor(contract, viewerCid) or nil
    elseif role == 'target' then
        -- The target is in the city to read this, and knows whether they
        -- are in prison, so a stopped clock on their card could only mean a
        -- named client had logged off: their session, live, to the one
        -- person most keen to know who the client is. So the target's clock
        -- is read from the deadline as if it were always running, the same
        -- for every contract on them whether the client is named or not —
        -- keying it on that would tell them which.
        out.clockStopped = nil
        out.secondsLeft = contract.deadline_at
            and math.max(0, contract.deadline_at - os.time()) or nil
        out.bailoutAmount = contract.bailout_amount
        -- Both questions, not one. A price stored before the owner switched
        -- buyouts off stays on the row, and the switch was read only when
        -- the button was pressed — so the On me tab offered a buyout, at a
        -- price, on a server that refuses every one.
        out.bailoutAvailable = Config.Bailout.Enabled == true
            and (contract.bailout_amount or 0) > 0
        -- A buyout already paid for, waiting out its processing delay.
        --
        -- The projection carried no sign of it, so the app could not draw
        -- one: a target who had just paid saw the same "Buy out" button at
        -- the same price, on a card identical to the one before their money
        -- left. No money is lost — the second attempt is refused as
        -- buyout_pending — but the player has no way to tell a payment that
        -- went through from one that did not, and the only thing they can do
        -- about it is pay again.
        out.bailoutPaid = contract.bailout_queued_at ~= nil or nil
        -- And how long the hitman on it still has, on the server's clock as
        -- the deadline is. "It closes shortly and your money is already
        -- gone" was wrong on both counts: it stays live for the delay, and
        -- the money comes back if a hitman finishes it first.
        if contract.bailout_queued_at then
            out.bailoutSecondsLeft = math.max(0, contract.bailout_queued_at
                + (Config.Bailout.ProcessingDelaySeconds or 0) - os.time())
        end
        out.informantAnswer, out.informantLeft = informantFor(contract.id, viewerCid)
        -- When they were last told somebody was tipped off about their rough
        -- area (server/locationtip.lua). Never who, never where.
        out.tippedAt = LocationTip and LocationTip.toldAt(contract.id) or nil
    end

    return out
end

--- The public contract list for one viewer.
---@param viewerCid string
---@param page integer|nil
---@return table
local function buildListing(viewerCid, page)
    -- Bounded before it is multiplied: a page of 2^62 wrapped the offset
    -- negative and indexed past the list, and a NaN or an infinity went
    -- straight back to the page. Clamped to the real last page below.
    page = tonumber(page) or 1
    if page ~= page or page < 1 or page > 100000 then page = 1 end
    page = math.floor(page)
    local pageSize = Config.Listing.PageSize

    -- Live contracts only: nothing else is ever listed (listedFor).
    local all = Storage.liveContracts()
    local visible = {}
    for i = 1, #all do
        if listedFor(all[i], viewerCid) then visible[#visible + 1] = all[i] end
    end

    -- Sorted by reward rather than creation order: creation order leaks when
    -- an anonymous contract was placed, which is half of a timing attack on
    -- anonymity (§14.32).
    --
    -- The sort key is computed up front and the comparator only reads that
    -- table. A comparator that queried storage would run a database call per
    -- comparison — and under oxmysql that call yields, which is not allowed
    -- inside table.sort's C frame and would fail the whole listing.
    local score = {}
    for i = 1, #visible do
        local c = visible[i]
        score[c.id] = Escrow.moneyValue(c.id, { slot = c.next_slot or 1 })
    end

    table.sort(visible, function(a, b)
        local ra, rb = score[a.id] or 0, score[b.id] or 0
        if ra == rb then return a.id < b.id end
        return ra > rb
    end)

    local out = {
        page = page,
        pages = math.max(1, math.ceil(#visible / pageSize)),
        contracts = {},
        -- The app asks the server how loudly to warn about law enforcement
        -- targets, rather than deciding for itself (§7.5).
        settings = {
            warnCreator = Config.Advisory.WarnCreator ~= false,
            warnHitman  = Config.Advisory.WarnHitman ~= false,
            flagListing = Config.Advisory.FlagListing ~= false,
            minQueryLength = Config.Targeting.MinQueryLength,
            -- Under this much time a staked hitman's card says the stake is
            -- at risk: the same window acceptance refuses to open inside.
            stakeWindowMinutes = Config.Penalty.MinWindowMinutes,
            -- The ceiling a stake is held to (Contracts.clampPenalty), so
            -- raising one offers only figures that will stand rather than
            -- applying a lower one than the creator typed.
            stakeCeiling = {
                amount = Config.Penalty.MaxAmount or 0,
                fraction = Config.Penalty.MaxFractionOfEscrow,
            },
            -- Which ways of browsing the app should offer, rather than
            -- offering a button that always comes back empty.
            allowBrowseAll = Config.Targeting.AllowBrowseAll == true,
            allowNearby = Config.Targeting.AllowNearby == true,
            nearbyRadius = Config.Targeting.NearbyRadius,
            -- Whether the app should offer a call at all. Off, the button
            -- is not drawn rather than drawn and refused. That includes a
            -- server where nothing can place a call: a button there could
            -- only send requests the other side had no way to answer.
            calls = Comms ~= nil and Comms.canCall(),
            -- Whether a call with an anonymous party on it can be made as
            -- the server requires (Comms.canMask). Off, the page draws no
            -- Call on such a thread: it could only be refused.
            canMask = Comms == nil or Comms.canMask(),
            -- Whether messaging exists at all. Absent, the page drew Message
            -- and Threads on a server with the relay switched off, and every
            -- message was refused.
            relay = Config.Relay.Enabled == true,
            -- How close a handover has to be and how long it is held, for
            -- the line that tells a new hitman how to deliver alive. Each
            -- rule was otherwise learned from a refusal.
            kidnap = {
                radius = Config.Kidnap.Radius,
                seconds = Config.Kidnap.CountdownSeconds,
                -- Whether the target has to be cuffed or in the hitman's
                -- vehicle too (Config.Kidnap.RequireCoercion, off as
                -- shipped). Off, nothing the hitman reads tells them to
                -- restrain anybody: alive, conscious and there is all a
                -- handover needs.
                restrain = Config.Kidnap.RequireCoercion and true or false,
            },
            -- How a contract placed now may be completed: 'alive' (live
            -- transfer only, with no bonus, so the Place form offers none)
            -- or 'either'. Each contract carries its own as `fulfilment`,
            -- which is what decides it once placed.
            fulfilment = Util.placingRule(),
            -- Whether a kill is verified with a photo at all
            -- (Config.Completion.KillPhotos). Off, Verify kill asks the
            -- server to check the scene and opens no camera, and nothing
            -- the hitman reads says to photograph anything.
            killPhotos = Util.killPhotos(),
            -- Whether officers are really told, at each stage. A contract on
            -- an officer is marked whatever this says, and the page's warnings
            -- said "their department has been advised" on a server that
            -- advises nobody.
            advisory = {
                posted = Util.advises('posted'),
                accepted = Util.advises('accepted'),
            },
            -- The message box's limit. The page hard-coded 200 whatever the
            -- server held messages to.
            messageMaxLength = Config.Relay.MaxLength,
            -- What anonymity costs, shown before it is chosen (§14.44).
            -- Charged, but never shown anywhere, on a server that set one.
            anonymityFees = {
                creator = Config.Anonymity.CreatorFee or 0,
                hitman = Config.Anonymity.HitmanFee or 0,
                account = Config.Anonymity.FeeAccount or 'bank',
            },
            -- Whether this server runs buyouts at all, so the page can tell
            -- "the client offered none" from "there are none here".
            buyouts = Config.Bailout.Enabled == true,
            -- How long a buyout paid while a hitman is on the contract waits
            -- before it closes. The confirmation said "close this contract"
            -- and the target read it as safe at once, when a hitman had two
            -- more minutes to finish it.
            buyoutDelaySeconds = Config.Bailout.ProcessingDelaySeconds or 0,
            -- The two ways an exclusive hold is taken back, each only when
            -- it is on. Nothing said so until the hitman had been barred
            -- from the contract for good.
            exclusiveIdleMinutes = (Config.Limits.ExclusiveIdleReleaseSeconds or 0) > 0
                and math.floor(Config.Limits.ExclusiveIdleReleaseSeconds / 60) or nil,
            exclusiveAttemptMinutes = (Config.Limits.ExclusiveAttemptWindowSeconds or 0) > 0
                and math.floor(Config.Limits.ExclusiveAttemptWindowSeconds / 60) or nil,
            -- The waits a withdrawal starts, for the dialog that asks first.
            -- A creator withdrawing to fix the reward found them out only
            -- when placing it again was refused. On the same person it is
            -- whichever of the two waits ends later. Nobody else waits on a
            -- contract nobody took up: withdrawing it starts no wait on the
            -- target for anyone but its creator (Contracts.canCreate). One an
            -- operative took and walked away from starts everyoneMinutes for
            -- every client (the creator projection's everTaken).
            relistWaits = {
                anyMinutes = math.floor((Config.Amendments.CancelCooldownSeconds or 0) / 60),
                sameTargetMinutes = math.floor(math.max(
                    Config.Limits.SameCreatorSameTargetCooldownSeconds or 0,
                    Config.Limits.TargetCooldownAfterResolveSeconds or 0) / 60),
                everyoneMinutes = math.floor(
                    (Config.Limits.TargetCooldownAfterResolveSeconds or 0) / 60),
            },
            -- Whether changes can be proposed at all. Absent, the page drew
            -- Propose change on every card of a server with amendments off,
            -- and every proposal was refused.
            amendments = Config.Amendments.Enabled == true,
            -- What buying informant data costs, and whether it is offered
            -- at all. The app was asking a player to spend money without
            -- telling them how much, on a purchase that is deliberately
            -- non-refundable.
            -- Which reason control the app should draw, and the list to
            -- draw it from. Policy rather than wallet: the Place form and
            -- the Edit dialog both need it, and the Edit dialog is reachable
            -- without ever having read a wallet. Keeping a second copy in
            -- the wallet's caps would be two sources to drift apart.
            reasonMode = Config.Reason.Mode,
            reasonPresets = Config.Reason.Mode == 'preset'
                and Config.Reason.Presets or nil,
            reasonMaxLength = Config.Reason.MaxLength,
            -- The most a deadline can be moved by in one go, in minutes.
            -- The server refuses anything larger, and the box asking for it
            -- had no ceiling to hold the player to.
            deadlineMaxMinutes = math.floor((Config.Limits.ContractLifetimeSeconds or 0) / 60),
            -- How long a new contract runs before anyone extends it, held to
            -- the lifetime the same way Contracts.create holds it. The Place
            -- form has no deadline field, and without this it could not say
            -- that every contract lapses after three hours.
            defaultDeadlineMinutes = math.floor(math.min(Config.Limits.DefaultDeadlineSeconds or 0,
                Config.Limits.ContractLifetimeSeconds or 0) / 60),
            -- And the least a shortening may leave on it: the server refuses
            -- a cut that leaves less, so the box stops short of it.
            deadlineMinLeftMinutes = math.floor(Util.CLOCK_STEP / 60),
            informant = Config.Informant.Enabled == true and {
                cost = Config.Informant.Cost,
                account = Config.Informant.Account,
                maxPerContract = Config.Informant.MaxPurchasesPerContract,
                needsProximity = Config.Informant.RequireProximity == true,
                -- When asking again is free: after the rate limit lets a
                -- second request through, and inside the reroll lock, which
                -- repeats the answer already bought. Sent so the dialog can
                -- say so rather than quote the full fee for a repeat.
                repeatFreeMinutes = Config.Informant.RerollLockMinutes,
                askEverySeconds = Config.Cooldowns.informant
                    and Config.Cooldowns.informant.per or nil,
            } or nil,
            -- What an informant tip costs and shows (Config.LocationTip), so
            -- the button can quote the price and the size of the area, and
            -- say why it cannot be bought while the server sells none.
            locationTip = type(Config.LocationTip) == 'table' and {
                enabled = Config.LocationTip.Enabled == true,
                cost = Config.LocationTip.Cost,
                account = Config.LocationTip.Account,
                radius = Config.LocationTip.RadiusMeters,
                showMinutes = Config.LocationTip.ShowMinutes,
                cooldownMinutes = Config.LocationTip.CooldownMinutes,
                maxPerContract = Config.LocationTip.MaxPurchasesPerContract,
                tellsTarget = Config.LocationTip.NotifyTarget ~= false,
            } or nil,
        },
    }
    local from = ((page - 1) * pageSize) + 1
    for i = from, math.min(from + pageSize - 1, #visible) do
        local row = Projection.contract(visible[i], viewerCid)
        -- Never on the board, not even to its placer or a hitman on it:
        -- their own cards under Mine carry it.
        row.meetingSet = nil
        row.locationTip = nil
        out.contracts[#out.contracts + 1] = row
    end
    return out
end

--- Contracts the viewer holds as creator.
---
--- These three all ask storage for the contracts this player is involved in
--- rather than for every contract on the server: on a real database the
--- difference is an indexed lookup against a full table scan, once per app
--- request.
local function buildMine(viewerCid)
    local involved = Storage.contractsBy(viewerCid)
    local out = {}
    for i = 1, #involved do
        local c = involved[i]
        if not CH.TERMINAL[c.state] then
            out[#out + 1] = Projection.contract(c, viewerCid)
        end
    end
    return out
end

--- What a contract's reward is actually made of, line by line, for the
--- creator who put it there.
---
--- The listing carries a money total and a count of goods, which is what a
--- hitman needs to decide. A creator changing their own reward needs the
--- opposite: the individual things, each with the id that names it, so they
--- can hand one back without touching the rest.
---
--- Only the creator, and only their own property. A hitman's stake and a
--- line already owed to somebody are neither shown nor named — a client
--- that cannot see an id cannot ask to withdraw it, and Contracts.withdraw
--- refuses those ids regardless.
---
--- Line ids cross to the client. They identify an escrow row and nothing
--- else: they carry no citizen id, are useless on any other contract, and
--- every path that accepts one re-checks that the caller owns it.
---@param contractId string
---@param viewerCid string
---@return table|nil { editable = boolean, reason?: string, lines = { ... } }
function Projection.rewardLines(contractId, viewerCid)
    local contract = Storage.readContract(contractId)
    if not contract then return nil end
    if contract.creator_cid ~= viewerCid then return nil end

    -- Why the withdraw controls are absent, rather than only that they are.
    -- A creator looking at a reward they cannot change should be told which
    -- rule is holding it, not left to guess.
    local editable, why = true, nil
    if CH.TERMINAL[contract.state] then
        editable, why = false, 'This contract is closed.'
    else
        local hitmen = Storage.readHitmen(contractId)
        for i = 1, #hitmen do
            if hitmen[i].state == 'active' then
                editable = false
                why = 'A hitman is working this. You can add to the reward, '
                    .. 'but not take from it.'
                break
            end
        end
    end

    local out = {}
    local lines = Storage.readEscrow(contractId)

    for i = 1, #lines do
        local line = lines[i]
        local mine = (line.portion == CH.PORTION.BASELINE
                      or line.portion == CH.PORTION.BONUS)
            and not line.owed_to
            and line.state ~= CH.ESCROW_STATE.SETTLED

        if mine then
            local row = {
                slot    = line.slot or 1,
                portion = line.portion,
                source  = line.source,
                -- Only a line still `held` may be withdrawn. One caught
                -- mid-release is on its way to somebody already, and is
                -- shown so the totals add up rather than hidden so they
                -- do not.
                withdrawable = editable and line.state == CH.ESCROW_STATE.HELD,
            }
            if row.withdrawable then row.id = line.id end

            if CH.MONEY_SOURCES[line.source] then
                row.amount = line.amount or 0
            else
                -- The name of an item crosses, as it already does in the
                -- listing. A serial does not, and neither does metadata:
                -- what a creator needs to pick a line out is what it is
                -- and how much of it, not the identity of the object.
                row.item = line.item
                row.quantity = line.quantity or 1
            end

            out[#out + 1] = row
        end
    end

    table.sort(out, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        if a.portion ~= b.portion then return a.portion < b.portion end
        return tostring(a.item or a.source) < tostring(b.item or b.source)
    end)

    return { editable = editable, reason = why, lines = out,
             slots = contract.payout_slots or 1,
             currentSlot = contract.next_slot or 1 }
end

--- Contracts the viewer holds as hitman.
local function buildAccepted(viewerCid)
    local involved = Storage.contractsInvolving(viewerCid)
    local out = {}
    for i = 1, #involved do
        local c = involved[i]
        if not CH.TERMINAL[c.state] then
            local hitman = Storage.readHitman(c.id, viewerCid)
            if hitman and hitman.state == 'active' then
                out[#out + 1] = Projection.contract(c, viewerCid)
            end
        end
    end
    return out
end

--- Contracts naming the viewer as target — their Cleanse tab.
local function buildOnMe(viewerCid)
    local naming = Storage.contractsNaming(viewerCid)
    local out = {}
    for i = 1, #naming do
        local c = naming[i]
        -- Not until the alert's wait is over (Notify.shownToTarget): listed
        -- at once, the tab dated the placement for a target who looked.
        if not CH.TERMINAL[c.state] and Notify.shownToTarget(c) then
            local row = Projection.contract(c, viewerCid)
            -- A target learns a price exists on them and what freedom costs.
            -- They do not learn who placed it, and never the hitman roster.
            -- The target learns there is a client, never which one.
            row.creatorName = nil
            row.creatorAnonymous = true
            row.hitmen = nil
            out[#out + 1] = row
        end
    end
    return out
end

--- One entry of the whitelisted-job view: what the law enforcement advisory
--- already says about a contract, and nothing else. Who it is on and their
--- job, when it was posted, whether a hitman has it and how many, and when
--- it runs out.
---
--- Built key by key from the row rather than from Projection.contract, so
--- what is left out (the person who placed it, named or not, every hitman,
--- the reason, a headshot, the reward) is left out by never being read:
--- there is nothing on the payload for a client-side inspector to find.
---
--- When it was posted to the five minutes (Util.CLOCK_STEP), as every other
--- time a viewer is sent about a placement. When it runs out at the latest:
--- its lifetime (expires_at), which runs through every pause and is moved
--- by nobody's presence. Not the deadline, even read as if the clock always
--- ran (the target's own card, Projection.contract): a pause for a named
--- placer who logged off ends by moving the deadline on by exactly how long
--- they were away, so its countdown jumped up the second they came back —
--- to every officer, on every colleague's contract — saying the placer is
--- named, when they reconnected and how long they had been gone.
---
--- A colleague's entry (`advised`) carries what the bulletins about it
--- said, and only what they said, as each was kept on the contract when it
--- went out (Notify.advisory: advised_posted_at, advised_hitmen), and only
--- while that stage's bulletins still go out: read from the setting alone, a
--- contract placed and taken while they were off was listed as posted and
--- taken once they were back on. When it was posted only where a posting
--- bulletin went; taken by the count the latest acceptance bulletin carried
--- (one walking away is not announced, so it is not shown either), or open
--- where a posting one went and no acceptance one has, with acceptance ones
--- going out all the while (neither, after a time they were off). When it runs out only
--- with when it was posted: the lifetime runs from the end of the five
--- minutes it was placed in and is the same for every contract, so the time
--- left gives the posted time back.
---@param contract table
---@param job string the job the target is shown under
---@param advised table|nil { posted = boolean, accepted = boolean } for a
--- colleague's contract; nil for one on the viewer
---@return table
local function whitelistedEntry(contract, job, advised)
    local posted, active = tonumber(contract.created_at), nil
    if advised then
        posted = advised.posted and tonumber(contract.advised_posted_at) or nil
        -- Open only where acceptance bulletins went out for its whole life
        -- since it was posted: a contract live while they were off is
        -- marked unknown (Notify.forgetAcceptances) until a bulletin says
        -- its count, and is shown neither open nor taken.
        local said = tonumber(contract.advised_hitmen)
        if advised.accepted then
            if said == nil then
                active = posted and 0 or nil
            elseif said >= 0 then
                active = said
            end
        end
    else
        active = 0
        local hitmen = Storage.readHitmen(contract.id)
        for i = 1, #hitmen do
            if hitmen[i].state == 'active' then active = active + 1 end
        end
    end
    return {
        targetName   = contract.target_name,
        targetJob    = job,
        postedAt     = posted and (posted - (posted % Util.CLOCK_STEP)) or nil,
        state        = active and (active > 0 and 'taken' or 'open') or nil,
        hitmenActive = active,
        secondsLeft  = (posted and contract.expires_at)
            and math.max(0, contract.expires_at - os.time()) or nil,
    }
end

--- A colleague's entry, where the view lists one: a member of a whitelisted
--- job by the contract, and only where a bulletin said something of it.
---@param contract table
---@param advised table { posted = boolean, accepted = boolean }
---@return table|nil
local function colleagueEntry(contract, advised)
    local member, job = Identity.whitelistedTarget(contract)
    local entry = member and whitelistedEntry(contract, job, advised)
    -- Only where a bulletin said something of it.
    if entry and (entry.postedAt or entry.hitmenActive) then return entry end
    return nil
end

--- Which advisory bulletins go out now, where the colleagues' list is sent
--- to this viewer at all: one the law enforcement advisory reaches, while
--- a stage of it goes out. nil where there is no such list.
---@param viewerJob table|nil
---@return table|nil { posted = boolean, accepted = boolean }
local function advisedFor(viewerJob)
    local advised = { posted = Util.advises('posted'), accepted = Util.advises('accepted') }
    if Identity.isAdvisoryRecipient(viewerJob) and (advised.posted or advised.accepted) then
        return advised
    end
    return nil
end

--- What the whitelisted-job view lists for this viewer of one contract as it
--- stands, or nil where it lists nothing: the rule the view itself reads
--- (Projection.whitelistedView), for its Notify me notices (Notify), so a
--- notice is never sent for an entry the screen would not show, or say more
--- than it. Never the buyout fields a contract on them carries on screen.
---@param contract table
---@param viewerCid string
---@param viewerJob table|nil the job the viewer is working
---@return table|nil entry
---@return boolean|nil own true for a contract on the viewer
function Projection.whitelistedListing(contract, viewerCid, viewerJob)
    if type(contract) ~= 'table' or type(viewerCid) ~= 'string' then return nil end
    if contract.target_cid == viewerCid then
        if CH.TERMINAL[contract.state] or not Notify.shownToTarget(contract) then return nil end
        local member, job = Identity.whitelistedTarget(contract)
        return whitelistedEntry(contract, member and job or nil), true
    end
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then
        return nil
    end
    local advised = advisedFor(viewerJob)
    if not advised or not Notify.shownToTarget(contract) then return nil end
    local entry = colleagueEntry(contract, advised)
    if entry then return entry, false end
    return nil
end

--- The whitelisted-job view (Config.WhitelistedView), for a player the app
--- bars: every live contract naming them ("Contracts on you"), and every
--- live contract naming another member of a whitelisted job, as the
--- contract recorded them when it was placed (Identity.whitelistedTarget).
--- Never the board, and nothing about a contract on anybody else, not even
--- how many there are.
---
--- The colleagues' list only for a viewer the law enforcement advisory goes
--- to (Identity.isAdvisoryRecipient, as Notify.advisory asks it), and only
--- while bulletins go out (Util.advises), each entry no more than the
--- bulletins that went out for it said (whitelistedEntry), and none for a
--- contract no bulletin was sent for. For anybody else, and with the
--- advisory off, there is no list at all (`colleagues` absent), not an
--- empty one.
---
--- Each one only once its target may be shown it (Notify.shownToTarget), as
--- On me: listed at once, it dated the placement to the target, or to a
--- colleague who could tell them.
---
--- A contract on the viewer also carries its buyout, exactly as On me
--- carries it to a civilian target: the price, whether one can be bought,
--- and a buyout already paid with how long the hitman on it still has. Its
--- id goes with it, for the buyout and nothing else; a colleague's does not.
---
--- And, where a job they hold but are not working is what puts them here,
--- that job (`heldJob`), for the banner to name with how to get the whole
--- app back: their own job, which nothing on the page hides from them.
---
--- And their own Notify me (`alerts`, Config.WhitelistedView.Alerts):
--- whether they turned it on, which is off until they do. Absent while the
--- server does not allow it, and the page draws no toggle.
---@param viewerCid string
---@param viewerJob table|nil the job the viewer is working, which decides
--- whether the advisory reaches them
---@param heldJob string|nil the held job that bars them (Identity.barredBy)
---@return table { onYou = entry[], colleagues = entry[]|nil, settings = table, heldJob = string|nil, alerts = table|nil }
function Projection.whitelistedView(viewerCid, viewerJob, heldJob)
    local onYou, colleagues = {}, nil

    local naming = Storage.contractsNaming(viewerCid)
    for i = 1, #naming do
        local c = naming[i]
        if not CH.TERMINAL[c.state] and Notify.shownToTarget(c) then
            local member, job = Identity.whitelistedTarget(c)
            local entry = whitelistedEntry(c, member and job or nil)
            entry.id = c.id
            entry.bailoutAmount = c.bailout_amount
            entry.bailoutAvailable = Config.Bailout.Enabled == true
                and (c.bailout_amount or 0) > 0
            entry.bailoutPaid = c.bailout_queued_at ~= nil or nil
            if c.bailout_queued_at then
                entry.bailoutSecondsLeft = math.max(0, c.bailout_queued_at
                    + (Config.Bailout.ProcessingDelaySeconds or 0) - os.time())
            end
            -- As On me says it: when they were told somebody was tipped off
            -- about their rough area. Never who, never where.
            entry.tippedAt = LocationTip and LocationTip.toldAt(c.id) or nil
            onYou[#onYou + 1] = entry
        end
    end

    local advised = advisedFor(viewerJob)
    if advised then
        colleagues = {}
        local live = Storage.liveContracts()
        for i = 1, #live do
            local c = live[i]
            if c.target_cid ~= viewerCid and Notify.shownToTarget(c) then
                local entry = colleagueEntry(c, advised)
                if entry then colleagues[#colleagues + 1] = entry end
            end
        end
    end

    -- By who it is on, then by when it was posted: nothing about the order
    -- the store keeps them in.
    local function byTarget(a, b)
        if a.targetName ~= b.targetName then
            return tostring(a.targetName) < tostring(b.targetName)
        end
        return (a.postedAt or 0) < (b.postedAt or 0)
    end
    table.sort(onYou, byTarget)
    if colleagues then table.sort(colleagues, byTarget) end

    return {
        onYou = onYou,
        colleagues = colleagues,
        heldJob = type(heldJob) == 'string' and heldJob or nil,
        -- What the buyout dialog reads, which the page otherwise takes from
        -- the board it is never sent here.
        settings = {
            buyouts = Config.Bailout.Enabled == true,
            buyoutDelaySeconds = Config.Bailout.ProcessingDelaySeconds or 0,
        },
        alerts = Notify.viewAlertsAllowed() and { on = Notify.viewAlertsOn(viewerCid) } or nil,
    }
end

--- The exact key set of a whitelisted-job view entry, asserted by the suite
--- like ALLOWED_KEYS: `entry` for every one, `own` added to a contract on
--- the viewer.
Projection.WHITELISTED_KEYS = {
    entry = { targetName = true, targetJob = true, postedAt = true, state = true,
              hitmenActive = true, secondsLeft = true },
    own   = { id = true, bailoutAmount = true, bailoutAvailable = true,
              bailoutPaid = true, bailoutSecondsLeft = true, tippedAt = true },
}

--- The four reads a player's app makes, each with escrow memoised for the
--- length of the call.
---
--- Every one of them asks what a contract is worth several times over: the
--- listing once for the sort key and again for each figure on the row, and
--- all of those were separate reads of the same rows. On the mysql backend
--- each is an awaited SELECT that yields, so one player opening a
--- 500-contract board issued hundreds of round trips to answer the same
--- question. None of these writes anything, which is what makes memoising
--- them safe.
function Projection.listing(viewerCid, page)
    return Escrow.cached(buildListing, viewerCid, page)
end

function Projection.mine(viewerCid)
    return Escrow.cached(buildMine, viewerCid)
end

function Projection.accepted(viewerCid)
    return Escrow.cached(buildAccepted, viewerCid)
end

function Projection.onMe(viewerCid)
    return Escrow.cached(buildOnMe, viewerCid)
end

--- How many readings of a player's retry queue count toward what their
--- Ledger says is waiting. The queue is a handful of rows at most; this
--- only bounds the reads behind one Ledger load on mysql.
local WAITING_READ = 20

--- How many payments wait for the viewer to make room: lines owed to them,
--- in their retry queue, not left for staff (Escrow.parked, which no retry
--- gives). Shown on their Ledger, so a receipt missed or a page closed is
--- not the only word of a payout that would not fit. A count of their own
--- payments and nothing else: no contract, no party, no figure, so it says
--- nothing they were not owed already.
---@param viewerCid string
---@return integer
function Projection.waitingForRoom(viewerCid)
    local count, seen = 0, {}
    local entries = Storage.readPending(viewerCid) or {}
    for i = 1, math.min(#entries, WAITING_READ) do
        local id = entries[i].line_id
        if id and not seen[id] then
            seen[id] = true
            local line = Storage.readEscrowLine(id)
            if line and line.state == CH.ESCROW_STATE.HELD and line.owed_to == viewerCid
                and not Escrow.parked(line) then
                count = count + 1
            end
        end
    end
    return count
end

--- The exact key set each role may receive. Exported so the test suite can
--- assert it; widening it is then a visible, deliberate change.
Projection.ALLOWED_KEYS = {
    common = {
        id = true, reason = true, mode = true, state = true, reward = true,
        fulfilment = true,
        bonusPercent = true, slots = true, slotsClaimed = true, currentSlot = true,
        hitmenActive = true, hitmenMax = true, targetName = true,
        targetProtected = true, targetProtectedAs = true, deadline = true, secondsLeft = true,
        clockStopped = true, role = true,
        targetImageId = true, penaltyAmount = true,
        creatorName = true, creatorAnonymous = true,
    },
    creator = { bailoutAmount = true, hitmen = true, valueHeld = true,
                informantAnswer = true, informantLeft = true, meetingSet = true },
    hitman  = { myAlias = true, myAnonymous = true, myClaims = true, kidnapProgress = true,
                buyoutClosesIn = true, lastMessageAt = true, meetingSet = true,
                locationTip = true },
    target  = { bailoutAmount = true, bailoutAvailable = true,
                bailoutPaid = true, bailoutSecondsLeft = true, informantAnswer = true,
                informantLeft = true, tippedAt = true },
    public  = { barred = true },
}

return Projection
