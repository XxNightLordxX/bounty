--- Per-recipient payload building (§14.4).
---
--- Anonymity is enforced by omission, not by masking: an anonymous creator's
--- identity is never placed in the payload at all, so there is nothing for a
--- client-side inspector to find. Every send point in the resource builds its
--- payload here and nowhere else.

local Projection = {}

local Util = CrimsonBoot.requireShared('util')

local Storage, Identity, Escrow, Kidnap, Mugshot, Progression, Comms, Informant, Notify

function Projection.init(deps)
    Storage, Identity, Escrow, Kidnap, Mugshot, Progression, Comms, Informant, Notify =
        deps.storage, deps.identity, deps.escrow, deps.kidnap, deps.mugshot, deps.progression,
        deps.comms, deps.informant, deps.notify
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
local function informantAnswer(contractId, viewerCid)
    if not Informant then return nil end
    local answer = Informant.answerFor(contractId, viewerCid)
    if type(answer) ~= 'table' then return nil end
    return answer.name or answer.description
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
        -- What the contract holds in money, against the ceiling on what one
        -- contract may be worth: the add-to-reward box offered amounts the
        -- server could only refuse, as a reward that did not add up.
        out.valueHeld = Escrow.moneyValue(contract.id)
        out.informantAnswer = informantAnswer(contract.id, viewerCid)
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
                }
            end
        end
    elseif role == 'hitman' then
        local mine = Storage.readHitman(contract.id, viewerCid)
        out.myAlias = mine and mine.alias or nil
        -- Their own, so nothing is disclosed. The page worded "accepted,
        -- anonymously" from the button pressed, not from what was recorded.
        out.myAnonymous = mine and mine.anon == true or false
        out.myClaims = mine and mine.claims or 0
        if Kidnap then
            out.kidnapProgress = Kidnap.progress(contract.id, viewerCid)
        end
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
        out.informantAnswer = informantAnswer(contract.id, viewerCid)
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
            -- whichever of the two waits ends later. Nobody else waits:
            -- withdrawing a contract nobody took up starts no wait on the
            -- target for anyone but its creator (Contracts.canCreate).
            relistWaits = {
                anyMinutes = math.floor((Config.Amendments.CancelCooldownSeconds or 0) / 60),
                sameTargetMinutes = math.floor(math.max(
                    Config.Limits.SameCreatorSameTargetCooldownSeconds or 0,
                    Config.Limits.TargetCooldownAfterResolveSeconds or 0) / 60),
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
        },
    }
    local from = ((page - 1) * pageSize) + 1
    for i = from, math.min(from + pageSize - 1, #visible) do
        out.contracts[#out.contracts + 1] = Projection.contract(visible[i], viewerCid)
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
---@param contract table
---@param job string the job the target is shown under
---@return table
local function whitelistedEntry(contract, job)
    local hitmen = Storage.readHitmen(contract.id)
    local active = 0
    for i = 1, #hitmen do
        if hitmen[i].state == 'active' then active = active + 1 end
    end
    local posted = tonumber(contract.created_at)
    return {
        targetName   = contract.target_name,
        targetJob    = job,
        postedAt     = posted and (posted - (posted % Util.CLOCK_STEP)) or nil,
        state        = active > 0 and 'taken' or 'open',
        hitmenActive = active,
        secondsLeft  = contract.expires_at
            and math.max(0, contract.expires_at - os.time()) or nil,
    }
end

--- The whitelisted-job view (Config.WhitelistedView), for a player the app
--- bars: every live contract naming them ("Contracts on you"), and every
--- live contract naming another member of a whitelisted job
--- (Identity.whitelistedTarget: their jobs now when they are in the city,
--- otherwise the job recorded on the contract). Never the board, and
--- nothing about a contract on anybody else, not even how many there are.
---
--- Each one only once its target may be shown it (Notify.shownToTarget), as
--- On me: listed at once, it dated the placement to the target, or to a
--- colleague who could tell them.
---
--- A contract on the viewer also carries its buyout, exactly as On me
--- carries it to a civilian target: the price, whether one can be bought,
--- and a buyout already paid with how long the hitman on it still has. Its
--- id goes with it, for the buyout and nothing else; a colleague's does not.
---@param viewerCid string
---@return table { onYou = entry[], colleagues = entry[], settings = table }
function Projection.whitelistedView(viewerCid)
    local onYou, colleagues = {}, {}

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
            onYou[#onYou + 1] = entry
        end
    end

    local live = Storage.liveContracts()
    for i = 1, #live do
        local c = live[i]
        if c.target_cid ~= viewerCid and Notify.shownToTarget(c) then
            local member, job = Identity.whitelistedTarget(c)
            if member then colleagues[#colleagues + 1] = whitelistedEntry(c, job) end
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
    table.sort(colleagues, byTarget)

    return {
        onYou = onYou,
        colleagues = colleagues,
        -- What the buyout dialog reads, which the page otherwise takes from
        -- the board it is never sent here.
        settings = {
            buyouts = Config.Bailout.Enabled == true,
            buyoutDelaySeconds = Config.Bailout.ProcessingDelaySeconds or 0,
        },
    }
end

--- The exact key set of a whitelisted-job view entry, asserted by the suite
--- like ALLOWED_KEYS: `entry` for every one, `own` added to a contract on
--- the viewer.
Projection.WHITELISTED_KEYS = {
    entry = { targetName = true, targetJob = true, postedAt = true, state = true,
              hitmenActive = true, secondsLeft = true },
    own   = { id = true, bailoutAmount = true, bailoutAvailable = true,
              bailoutPaid = true, bailoutSecondsLeft = true },
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

--- The exact key set each role may receive. Exported so the test suite can
--- assert it; widening it is then a visible, deliberate change.
Projection.ALLOWED_KEYS = {
    common = {
        id = true, reason = true, mode = true, state = true, reward = true,
        fulfilment = true,
        bonusPercent = true, slots = true, slotsClaimed = true, currentSlot = true,
        hitmenActive = true, hitmenMax = true, targetName = true,
        targetProtected = true, deadline = true, secondsLeft = true,
        clockStopped = true, role = true,
        targetImageId = true, penaltyAmount = true,
        creatorName = true, creatorAnonymous = true,
    },
    creator = { bailoutAmount = true, hitmen = true, valueHeld = true,
                informantAnswer = true },
    hitman  = { myAlias = true, myAnonymous = true, myClaims = true, kidnapProgress = true },
    target  = { bailoutAmount = true, bailoutAvailable = true,
                bailoutPaid = true, bailoutSecondsLeft = true, informantAnswer = true },
    public  = { barred = true },
}

return Projection
