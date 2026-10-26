--- The network surface (§14.1, §14.27).
---
--- Every handler in this file is registered through `handler()`, which
--- resolves the actor from `source`, re-checks the job blacklist and applies
--- the rate limit before the body runs. No handler body reads an identity
--- from its payload, and none of them is reachable without passing the gate.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local App = {}

local deps

--- Whether requests are answered yet.
---
--- The handlers are registered before boot recovery runs, and on mysql every
--- step of recovery is a yield that lets a player's request run in the
--- middle of it. Recovery takes back any acceptance it finds part-way, as
--- the dead process's — so one a player had just started in this process was
--- taken back under them, its stake returned while they went on to hold the
--- contract; and a penalty being lowered had half its work undone. Held off
--- until recovery has finished (StartCrimsonHitman), and answered as busy
--- meanwhile. True outside that window, as a stack built without a boot has
--- nothing to recover.
App.ready = true

--- Set when boot recovery raised (StartCrimsonHitman): App.ready then stays
--- down for the life of the process, and the staff commands say that a
--- restart, once the logged cause is fixed, is what opens it. Every app
--- request is answered CH.ERR.RECOVERY_FAILED then, not busy.
App.recoveryFailed = false

function App.init(d)
    deps = d
    App.register()
end

--------------------------------------------------------------------------
-- The gate
--------------------------------------------------------------------------

--- Wrap a handler so it can only run for a resolved, permitted, non-flooding
--- player. `fn` receives (actor, payload) and never sees `source`.
---@param name string event suffix
---@param action string|nil rate-limit bucket
---@param fn fun(actor: table, payload: table): any
--- Cheap per-source counter, consulted BEFORE identity resolution.
---
--- A caller who cannot pass the gate never consumes a rate-limit token,
--- because tokens are keyed on a citizen id they never get. Without this,
--- a blocked player can flood the gate path — each call resolving identity,
--- writing an audit row and sending a reply — and evict genuine rows from
--- the audit queue.
local floodCounters = {}

--- Raw requests one client may make in ten seconds.
---
--- Twenty was below what the app asks for by itself. Opening the board is
--- three requests and then one headshot per contract on it, so a board of
--- eight is eleven before the player has touched anything — and every
--- render, every refresh and every push adds more. A guard that trips on
--- ordinary use is a guard against the app.
local FLOOD_WINDOW_MS = 10000
local FLOOD_LIMIT = 90

--- Whether a gate refusal for this source is worth writing down.
---
--- The gate refuses blocked jobs and players it cannot resolve, and it
--- refuses them on every request they send. One row each fills the audit
--- queue with the same fact repeated, pushing out the rows somebody would
--- actually want.
local gateLogged = {}

local function shouldLogGate(src)
    local now = Util.monotonicMs()
    local last = gateLogged[src]
    if last and now - last < FLOOD_WINDOW_MS then return false end
    gateLogged[src] = now
    return true
end

--- Whether a rate-limit refusal for this player and bucket is worth writing
--- down: once per window, as the gate's are. One row per refused request
--- let a single client write hundreds of rows a minute, and on the json
--- store every row is kept for the retention period in a file rewritten in
--- full on each flush.
local ratelimitLogged = {}

local function shouldLogRatelimit(cid, name)
    local key = tostring(cid) .. ':' .. tostring(name)
    local now = Util.monotonicMs()
    local last = ratelimitLogged[key]
    if last and now - last < FLOOD_WINDOW_MS then return false end
    ratelimitLogged[key] = now
    return true
end

local function floodCheck(src)
    local now = Util.monotonicMs()
    local entry = floodCounters[src]

    if not entry or now - entry.since > FLOOD_WINDOW_MS then
        floodCounters[src] = { since = now, count = 1, warned = false }
        return true, false
    end

    entry.count = entry.count + 1
    if entry.count <= FLOOD_LIMIT then return true, false end

    -- Past the threshold. Logged once per window rather than once per call,
    -- so a flood cannot blind the log it is recorded in.
    local shouldLog = not entry.warned
    entry.warned = true
    return false, shouldLog
end

--- [source] = { handle, at, earliest, arrived } for the kill photo on its
--- way to that player as a latent event (openPhoto), until their client
--- says it is there (photoArrived) and it could have been, PHOTO_SEND_MS
--- passes, or they leave (App.forgetSource).
---
--- One at a time. Each open of a photo kept in the app queued another send
--- of the whole photo with nothing to say one was already going: FXServer
--- moves a latent event no faster than the client's acknowledgements, which
--- it caps at 75 packets a second, so a client tapping View photo, or one
--- scripting the page, piled sends up faster than they drained — hundreds
--- of megabytes held for one player in ten minutes.
local photoSending = {}

--- How long a photo is taken to be on its way at most: as long as the
--- client waits for one (PHOTO_WAIT_MS, client/main.lua).
local PHOTO_SEND_MS = 60000

--- Bytes a second a latent event actually drains at: FXServer's cap on the
--- client's acknowledgements (App.PHOTO_BPS says why). A photo cannot have
--- landed sooner than its size at this rate, whatever the client says. The
--- client's word was enough on its own, and a modified client saying it at
--- once, the moment openPhoto answered, had a whole photo re-sent on every
--- open the limit allowed: queued several times faster than it drained.
local PHOTO_DRAIN_BPS = 150000

--- [source] = true (masked) | false (bare face): what each player's own
--- client last said about their mask (crimson-hitman:maskState), for the
--- nearby list (nearbyNameable).
---
--- The server cannot see clothes. GetPedDrawableVariation is a client
--- native, nil on FXServer, so reading it here failed for every candidate
--- and the nearby list was always empty when switched on. Each client reads
--- its own ped instead and says so when it changes (client/main.lua). It is
--- the sender's word about the sender alone: a lie can hide them from the
--- list or put them on it, as taking the mask off would. A player whose
--- client has said nothing counts as masked, and is left off.
---
--- Forgotten when they leave (App.forgetSource), log out or switch
--- character (App.forgetMask): whoever has the source next has said nothing.
local masks = {}

--- Forget what a player's client said about their mask. Their character
--- has gone, and the next one on this source has not said yet.
function App.forgetMask(src)
    masks[tonumber(src) or src] = nil
end

--- Forget what was on its way to a player who has left, and what their
--- client said about their mask. A source is reused.
function App.forgetSource(src)
    photoSending[src] = nil
    App.forgetMask(src)
end

function App.sweepFloodCounters()
    local now = Util.monotonicMs()
    for src, sending in pairs(photoSending) do
        if now - sending.at > PHOTO_SEND_MS
            or (sending.arrived and now >= sending.earliest) then
            photoSending[src] = nil
        end
    end
    for src, entry in pairs(floodCounters) do
        if now - entry.since > 60000 then floodCounters[src] = nil end
    end
    for src, at in pairs(gateLogged) do
        if now - at > 60000 then gateLogged[src] = nil end
    end
    for key, at in pairs(ratelimitLogged) do
        if now - at > 60000 then ratelimitLogged[key] = nil end
    end
end

--- Forget every flood counter, for the staff timer refresh.
---
--- Separate from the sweep above, which only forgets windows that have
--- already lapsed. A tester who has just tripped the guard is inside a live
--- window, which is the one the sweep will not touch.
---@return integer forgotten
function App.resetFloodCounters()
    local forgotten = 0
    for src in pairs(floodCounters) do
        floodCounters[src] = nil
        forgotten = forgotten + 1
    end
    for src in pairs(gateLogged) do gateLogged[src] = nil end
    for key in pairs(ratelimitLogged) do ratelimitLogged[key] = nil end
    return forgotten
end

--- The flood gate, exposed for the events registered outside handler().
--- Those are the highest-frequency events in the resource and skipping the
--- gate on them defeats the point of having one.
function App.floodOk(src, name)
    local allowed, shouldLog = floodCheck(src)
    if not allowed then
        if shouldLog then deps.audit.rejected('flood_' .. name, nil, nil, { source = src }) end
        return false
    end
    return true
end

--- Whether a reward source is switched on.
---
--- Read through a helper because a config that predates a source has it
--- absent rather than false, and indexing the absent one throws — inside a
--- handler, where it becomes a request that never answers. Absent reads as
--- off here, and startup fills in the shipped default so it should never
--- come to this.
---@param name string
---@return boolean
local function sourceEnabled(name)
    local source = Config.Sources and Config.Sources[name]
    return (source and source.enabled) == true
end

--------------------------------------------------------------------------
-- Who the nearby list may name
--------------------------------------------------------------------------

--- Metres per distance band in the nearby list. A row says "under 10m",
--- "under 20m", never the figure itself.
local NEARBY_BAND = 10

--- Whether somebody standing near the browser may be named to them.
---
--- Not anybody the server can see (§14.33). Out: a player in another
--- routing bucket (an instanced interior, a staff session); an invisible
--- one (noclip, spectating staff); and anyone wearing a mask, whose face is
--- exactly what the list would have put a name to. Whether they wear one is
--- their own client's word (`masks`): the mask component (1) not being the
--- bare face (0), as on the freemode peds Qbox players use, so an add-on
--- ped model that draws something there counts as masked. A client that
--- has said nothing, and a native that cannot answer, leave the person
--- off: an unlisted person costs a search by name, and a listed masked one
--- cannot be taken back.
---@param src number
---@param ped number
---@param bucket number the browser's own routing bucket
---@return boolean
local function nearbyNameable(src, ped, bucket)
    if not ped or ped == 0 then return false end
    local ok, theirs = pcall(GetPlayerRoutingBucket, src)
    if not ok or theirs ~= bucket then return false end
    -- A BOOL native: 1 or false, so read for truth.
    local seen, visible = pcall(IsEntityVisible, ped)
    if not seen or not visible then return false end
    return masks[tonumber(src) or src] == false
end

--- Whether this player is on a live contract: placed it, holds it as a
--- hitman, or is named on one they have been shown (Notify.shownToTarget,
--- so the nearby list closing cannot date a placement the target's On me
--- tab does not show yet). One indexed read of their own contracts.
---
--- Or was, on one that ended inside Config.Targeting.NearbyClosedAfterSeconds.
--- A handover keeps client, hitman and target within a few metres until it
--- pays, and the contract closes in that same moment: open again then, the
--- list named the anonymous hitman and the anonymous client to the others
--- still standing beside them. A target counts only for an ending they were
--- told of: a completion (their history shows it), their own buyout, or one
--- that outlived the longest reveal wait. One withdrawn inside the wait
--- closing their list would tell them it had existed.
---@param actor table
---@return boolean
local function onLiveContract(actor)
    local involved = deps.storage.contractsInvolving(actor.cid) or {}
    local now = os.time()
    local after = tonumber(Config.Targeting.NearbyClosedAfterSeconds) or 0
    local wait = Config.Notifications.ParanoidAlertJitter
    local longestWait = type(wait) == 'table' and tonumber(wait.max) or 0
    for i = 1, #involved do
        local c = involved[i]
        local live = not CH.TERMINAL[c.state]
        local recent = not live and c.resolved_at ~= nil and now - c.resolved_at < after
        if live or recent then
            if c.creator_cid == actor.cid then return true end
            if c.target_cid == actor.cid then
                if live and deps.notify.shownToTarget(c) then return true end
                if recent and (c.state == CH.STATE.COMPLETED or c.state == CH.STATE.BAILED_OUT
                    or c.resolved_at - (c.created_at or c.resolved_at) >= longestWait) then
                    return true
                end
            else
                local mine = deps.storage.readHitman(c.id, actor.cid)
                if mine and (recent or mine.state == 'active') then return true end
            end
        end
    end
    return false
end

--- Every handler body, by name.
---
--- So the diagnosis can run the real thing rather than a reconstruction of
--- it. A report that reads every config value a handler reads, and calls
--- every export it calls, and still misses the one line where it actually
--- throws, is a report that says "healthy" about a server whose app is
--- empty — which is exactly what happened, for days.
App.handlers = {}

--- The kill photo's requests, refused unread while kill photos are switched
--- off (Config.Completion.KillPhotos): a token, a photo sent with one, and
--- opening or deciding on a photo kept for the client. Answered as a photo
--- nobody has (PHOTO_GONE), the same to everyone, before the gate or the
--- payload is looked at; only the request's own id is read, to answer it.
---
--- Opening and deciding stay open while any photo is still kept from
--- before (Photos.inUse): such a photo keeps its expiry, and its client can
--- still open it once. A token and a photo are refused whatever is kept:
--- nothing new is taken.
local PHOTO_REQUESTS = {
    requestPhotoToken = 'new', submitPhoto = 'new',
    openPhoto = 'kept', photoDecision = 'kept',
}

---@param name string
---@return boolean refused
local function photosOff(name)
    local kind = PHOTO_REQUESTS[name]
    if not kind or Util.killPhotos() then return false end
    if kind == 'kept' and deps.photos and deps.photos.inUse() then return false end
    return true
end

--- The requests that move money, or start what does (an ending, a
--- handover). One that raises may have moved some of it before it did:
--- printed whatever Config.Debug says (Log.raised), as the admin panel's
--- own writes are. A read that raises is said with Debug on.
local MONEY_REQUESTS = {
    create = true, accept = true, cancel = true, abandon = true, withdrawReward = true,
    addEscrow = true, improve = true, propose = true, respondAmendment = true,
    bailout = true, informant = true, submitPhoto = true, verifyKill = true,
    armKidnap = true,
}

---@param access string|nil who the gate lets through: nil for everyone the
--- app is open to (Identity.gate); 'view', 'target' or 'report' for the
--- requests of the whitelisted-job view (Identity.gateFor)
local function handler(name, action, fn, access)
    App.handlers[name] = fn

    RegisterNetEvent('crimson-hitman:' .. name, function(payload)
        local src = source

        -- Busy while boot recovery runs, which a moment later fixes. Once it
        -- has raised it never finishes in this process, and every Board,
        -- Mine and On me (its buyout too) answered "busy for a moment" with
        -- a Try again that could never work; /cleanse already said why.
        if not App.ready then
            return App.reply(src, name, false,
                App.recoveryFailed and CH.ERR.RECOVERY_FAILED or CH.ERR.BUSY, nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        local allowed, shouldLog = floodCheck(src)
        if not allowed then
            if shouldLog then
                deps.audit.rejected('flood_' .. name, nil, nil, { source = src })
            end
            -- Answered, not dropped. The page waits on every request it
            -- sends and gives up after fifteen seconds, so a silent drop is
            -- not a refusal anybody sees — it is the app sitting there
            -- doing nothing for a quarter of a minute, once per click.
            return App.reply(src, name, false, CH.ERR.RATE_LIMITED, nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        if photosOff(name) then
            return App.reply(src, name, false, CH.ERR.PHOTO_GONE, nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        -- Guarded: the gate reads the framework, and a throw here is before
        -- the handler's own pcall — so it used to take the whole net event
        -- with it and leave the request with no reply at all. The page waits
        -- fifteen seconds on every request it sends.
        local gateOk, actor, err
        if access then
            gateOk, actor, err = pcall(deps.identity.gateFor, src, access)
        else
            gateOk, actor, err = pcall(deps.identity.gate, src)
        end
        if not gateOk then
            actor, err = nil, CH.ERR.NO_PLAYER
        end

        if not actor then
            -- Once per window per source, not once per request. Somebody the
            -- gate refuses can still send as fast as the flood guard allows,
            -- and a row for each would evict the rows worth keeping from a
            -- queue that has a fixed size.
            if shouldLogGate(src) then
                deps.audit.rejected('gate_' .. name, nil, nil, { source = src, reason = err })
            end
            return App.reply(src, name, false, err, nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        if action and not deps.ratelimit.check(actor, action) then
            if shouldLogRatelimit(actor.cid, name) then
                deps.audit.rejected('ratelimit_' .. name, actor.cid, nil, {})
            end
            -- With the wait, because "slow down" on its own is not something
            -- a player can act on: they cannot tell two seconds from five
            -- minutes, so they tap again, read the same words, and decide
            -- the button is broken.
            local wait = deps.ratelimit.retryAfter and deps.ratelimit.retryAfter(actor, action) or 0
            return App.reply(src, name, false, CH.ERR.RATE_LIMITED,
                wait > 0 and { retryAfter = wait } or nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        if type(payload) ~= 'table' then payload = {} end

        -- The client's correlation id is echoed back so concurrent requests
        -- resolve into their own callbacks. It is opaque to the server and
        -- never used for anything else.
        local rid = tonumber(payload.__rid)

        -- A refusal may say more than its code: what the player was short of
        -- and how much, or the most the server allows. Returned third, as
        -- `false, err, data`, and only by the handlers that build it.
        -- Fourth, `true` where the refusal did the work all the same and
        -- keeps its charge (below).
        local ok, result, resultErr, refusalData, keepCharge = pcall(fn, actor, payload)
        if not ok then
            deps.audit.rejected('error_' .. name, actor.cid, nil, { error = tostring(result) })

            -- Kept for the diagnosis, not only audited. A handler that
            -- throws is a fault in this resource, and the audit queue is not
            -- somewhere an operator looks. For a long time a crashing
            -- handler produced a shrug on the player's screen and nothing
            -- anywhere to read: the diagnosis lists it now. One that moves
            -- money is printed whatever Config.Debug says, once every few
            -- minutes per request (MONEY_REQUESTS); a read with Debug on.
            local text = ('the %s handler threw: %s'):format(name, tostring(result))
            if MONEY_REQUESTS[name] then
                Log.raised('request ' .. name, text)
            else
                Log.debug(text)
            end

            if action then deps.ratelimit.refund(actor, action) end
            -- The database did not answer (mysql): said as that, since a
            -- payment it was recording may still go through or be settled
            -- by the server, and a second tap could pay twice.
            if deps.storage and deps.storage.timedOut and deps.storage.timedOut(result) then
                return App.reply(src, name, false, CH.ERR.DB_TIMEOUT, nil, rid)
            end
            -- Not INVALID_INPUT. Nothing the player typed is wrong, and
            -- telling them to check it sends them searching for a fault they
            -- cannot reach.
            return App.reply(src, name, false, CH.ERR.SERVER_ERROR, nil, rid)
        end

        local succeeded = result ~= false and result ~= nil
        -- The allowance is for work done. A request the handler refused did
        -- none, and charging for it meant a player fixing a typo was told
        -- to slow down.
        --
        -- Unless it did the work and was refused after: a kill photo whose
        -- picture was read (submitPhoto). Given back, the one charge that
        -- bounds how often the server decodes a picture never landed, and a
        -- single token was worth a decode for every send the flood guard let
        -- through.
        if not succeeded and action and keepCharge ~= true then
            deps.ratelimit.refund(actor, action)
        end

        return App.reply(src, name, succeeded, resultErr,
            succeeded and result or refusalData, rid)
    end)
end

--- How fast a kill photo kept on this server is sent to the phone opening
--- it, in bytes a second. FiveM's default for a latent event is 25000.
--- What actually bounds it is lower: FXServer sends a latent event no
--- faster than the client acknowledges its pieces, and caps those at 75
--- packets a second (125 at once) — about 150 KB/s. So a photo at the
--- default PhotoMaxBytes takes about four seconds, and one at the largest
--- allowed (1500000) about ten. Asking for more than the cap is not lost:
--- it is what lets the first 125 pieces go at once, and slower asks make a
--- normal open slower.
App.PHOTO_BPS = 500000

--- How fast a headshot goes to the phone asking for it, in bytes a second.
--- A full-size one is tens of KB; the page asks for five a second.
App.MUGSHOT_BPS = 100000

--- Replies that carry an image, sent as a latent event when they do: a
--- headshot is tens of KB, and FiveM's documentation says a payload that
--- size goes latent rather than holding up the client's reliable channel.
--- The client hears both on the same event.
local LATENT_REPLIES = { mugshotImage = App.MUGSHOT_BPS }

--- Send a result back to one client. Payloads are built by the projection
--- module, so nothing leaks here that the viewer may not see. A refusal's
--- data is built by its handler from the asker's own figures alone.
function App.reply(src, name, ok, err, data, rid)
    local payload = {
        event = name, ok = ok and true or false, err = err, data = data, rid = rid,
    }
    local bps = ok and LATENT_REPLIES[name]
    if bps then
        TriggerLatentClientEvent('crimson-hitman:result', src, bps, payload)
    else
        TriggerClientEvent('crimson-hitman:result', src, payload)
    end
end

--------------------------------------------------------------------------
-- Faults the page reported
--------------------------------------------------------------------------
--
-- Kept here as well as in the audit log, because the audit log is not
-- somewhere an operator looks — or can look, without a command and a
-- database. The diagnosis command reads this, so "the app is broken for my
-- players" has an answer in the same place as every other question about
-- why the app is not working.
--
-- A fixed ring. Diagnostic data with a durable copy already written does
-- not justify growing without bound for the life of the server.

local pageFaults = {}
local PAGE_FAULTS_KEPT = 20

--- The most recent faults, newest first.
---@return table[]
function App.recentPageFaults()
    local out = {}
    for i = #pageFaults, 1, -1 do out[#out + 1] = pageFaults[i] end
    return out
end

--- Pages a staff member has asked for their log, until when the answer is
--- taken, and where it goes: { untilAt = os.time() deadline, deliver =
--- fun(lines: string[]) } by source.
---
--- The page says it was asked, and the page is a browser any player can
--- script: the printed log was a way to write to the server console on
--- demand, several lines at a time. It goes anywhere only for a page that
--- was, and then only to whoever asked: their F8 console, their open admin
--- panel, or the server console that ran the diagnosis.
local dumpsAsked = {}
local DUMP_ANSWER_SECONDS = 30

--- Note that this player's page has been asked for its log, and where its
--- answer goes.
---@param src number|nil the player whose page was asked
---@param deliver fun(lines: string[])|nil where the answer goes: the
--- requester's F8, panel or console (Admin.diagnose). Without it the answer
--- is kept for the diagnosis and printed only with Config.Debug on.
function App.expectDump(src, deliver)
    local now = os.time()
    for asked, entry in pairs(dumpsAsked) do
        if entry.untilAt < now then dumpsAsked[asked] = nil end
    end
    if src then dumpsAsked[src] = { untilAt = now + DUMP_ANSWER_SECONDS, deliver = deliver } end
end

--------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------

function App.register()
    -- Listings ----------------------------------------------------------

    handler('list', 'load', function(actor, payload)
        return deps.projection.listing(actor.cid, payload.page)
    end)

    handler('mine', 'load', function(actor)
        return {
            created  = deps.projection.mine(actor.cid),
            accepted = deps.projection.accepted(actor.cid),
            onMe     = deps.projection.onMe(actor.cid),
        }
    end)

    -- The whitelisted-job view (Config.WhitelistedView): the one screen a
    -- player on a job the app bars is shown. The contracts on them, and, to
    -- a viewer the law enforcement advisory reaches, the contracts on other
    -- whitelisted-job members, each with no more than the advisory carries
    -- (Projection.whitelistedView). Gated the other way round from every
    -- handler here ('view'): only a player the app bars may ask, and only
    -- while the view is on. Rate-limited with the other reads.
    handler('whitelistedView', 'load', function(actor)
        return deps.projection.whitelistedView(actor.cid, actor.job)
    end, 'view')

    -- The rows as the page is shown them (Ledger.entries), not as stored:
    -- a stored row carries cids and, on the client's own row, the handle of
    -- a photo, which crosses only as { handle, state }. With the photos
    -- kept for them in the app whose row is gone, as the same.
    handler('ledger', 'load', function(actor)
        local entries, kept = deps.ledger.entries(actor.cid)
        return {
            entries = entries,
            kept    = kept,
            record  = deps.progression.record(actor.cid),
        }
    end)

    -- Target search: returns opaque handles and capped results, never a
    -- roster of everyone online (§14.33). The handles are minted per
    -- searcher and expire, so a citizen id never reaches a client and one
    -- player's handles are useless to another.
    handler('searchTargets', 'search', function(actor, payload)
        local query = Util.sanitizeText(payload.query, 32)
        if not query or #query < Config.Targeting.MinQueryLength then
            return false, CH.ERR.INVALID_INPUT
        end

        local needle = query:lower()
        local out = {}
        local online = deps.identity.online()
        for i = 1, #online do
            local candidate = online[i]
            if candidate.cid ~= actor.cid
                and not deps.identity.sameAccount(candidate.account, actor.account)
                and candidate.name:lower():find(needle, 1, true) then
                out[#out + 1] = {
                    handle = App.mintTargetHandle(actor.cid, candidate.cid),
                    name = candidate.name,
                    -- Whether the target is law enforcement is disclosed, so
                    -- nobody places a contract on an officer unaware (§7.5).
                    -- Which force they serve is not: that would make search
                    -- a roster of who is on duty tonight.
                    protected = deps.identity.isProtected(candidate),
                }
                if #out >= Config.Targeting.MaxResults then break end
            end
        end
        return out
    end)

    -- Everyone a player could put a contract on, without having to know a
    -- name first.
    --
    -- Two scopes. `all` is every player currently online, paged and
    -- alphabetical: this IS the roster §14.33 originally refused, and it is
    -- here because the server owner asked for it — see
    -- Config.Targeting.AllowBrowseAll, which turns it off. `nearby` is the
    -- narrower one: who is within a few metres, which is the question a
    -- player looking at somebody across a car park actually has. It ships
    -- off (Config.Targeting.AllowNearby), and nearbyNameable and
    -- onLiveContract say what it leaves out when it is on.
    --
    -- Both mint the same opaque, per-searcher, expiring handles as a name
    -- search, so a citizen id still never reaches a client, and both refuse
    -- to name anyone sharing the browser's own account.
    handler('browseTargets', 'search', function(actor, payload)
        payload = payload or {}
        local nearby = payload.scope == 'nearby'

        if nearby and not Config.Targeting.AllowNearby then return { people = {}, total = 0 } end
        if not nearby and not Config.Targeting.AllowBrowseAll then return { people = {}, total = 0 } end

        -- Closed to anyone on a live contract, whoever is standing there.
        -- Every party has somebody on it the app keeps from them: a target
        -- never learns the client or the hitmen, a hitman not an anonymous
        -- client, a client not an anonymous hitman, and the hitman is not
        -- told where the target is. A name and a distance through walls
        -- gave all of it back: the target named the anonymous hitman closing
        -- in, and the hitman named the anonymous client at the handover.
        -- Leaving only those people off the list would not do: somebody
        -- standing in plain sight and missing from it is the answer. Closed
        -- whole, the list cannot depend on who is near.
        if nearby and onLiveContract(actor) then
            return { people = {}, total = 0, closed = true }
        end

        -- A name typed into the browser narrows it without a round trip per
        -- keystroke, and without needing the full length a name search does:
        -- the list is already bounded, so this is a filter rather than a
        -- lookup.
        local needle = Util.sanitizeText(payload.query, 32)
        needle = needle and needle:lower() or nil

        local origin, bucket
        if nearby then
            local ped = GetPlayerPed(actor.source)
            origin = ped and ped ~= 0 and GetEntityCoords(ped) or nil
            if not origin then return { people = {}, total = 0 } end
            local ok, mine = pcall(GetPlayerRoutingBucket, actor.source)
            if not ok then return { people = {}, total = 0 } end
            bucket = mine
        end

        local found = {}
        local online = deps.identity.online()

        for i = 1, #online do
            local candidate = online[i]
            if candidate.cid ~= actor.cid
                and not deps.identity.sameAccount(candidate.account, actor.account)
                and (not needle or candidate.name:lower():find(needle, 1, true)) then

                if nearby then
                    local theirPed = GetPlayerPed(candidate.source)
                    if nearbyNameable(candidate.source, theirPed, bucket) then
                        local metres = math.sqrt(Util.dist2(origin, GetEntityCoords(theirPed)))
                        if metres <= Config.Targeting.NearbyRadius then
                            found[#found + 1] = { actor = candidate,
                                band = math.floor(metres / NEARBY_BAND) + 1 }
                        end
                    end
                else
                    found[#found + 1] = { actor = candidate }
                end
            end
        end

        -- Stable and scannable, so paging through it means something. Nearby
        -- goes by band first and then by name, never by the exact distance:
        -- the order inside a band would otherwise be the rangefinder the
        -- band exists to withhold.
        table.sort(found, function(a, b)
            if (a.band or 0) ~= (b.band or 0) then return (a.band or 0) < (b.band or 0) end
            if a.actor.name == b.actor.name then return a.actor.cid < b.actor.cid end
            return a.actor.name < b.actor.name
        end)

        local total = #found
        local perPage = nearby and Config.Targeting.MaxNearby or Config.Targeting.BrowsePageSize
        local page = Util.toPositive(payload.page, 200) or 1
        local first = ((page - 1) * perPage) + 1

        local people = {}
        for i = first, math.min(first + perPage - 1, total) do
            local entry = found[i]
            people[#people + 1] = {
                handle = App.mintTargetHandle(actor.cid, entry.actor.cid),
                name = entry.actor.name,
                -- Whether the target is law enforcement is disclosed, so
                -- nobody places a contract on an officer unaware (§7.5).
                protected = deps.identity.isProtected(entry.actor),
                -- The far edge of their band, "under 20m": enough to tell
                -- two people with the same name apart. It was the distance
                -- to the metre, and asked again every second it tracked a
                -- moving person through walls.
                metres = entry.band and (entry.band * NEARBY_BAND) or nil,
            }
        end

        return {
            people = people,
            total = total,
            page = page,
            pages = math.max(1, math.ceil(total / perPage)),
        }
    end)

    -- One target headshot, by the reference a projection handed out. The
    -- listing carries references rather than images (§7.2), so a board
    -- refresh re-sends no image bytes at all and the app fetches a face
    -- once per render.
    --
    -- A reference is only learnable from a projection the viewer was
    -- entitled to receive, and it resolves to nothing once a newer render
    -- replaces it, so this serves no more than the listing already showed.
    handler('mugshotImage', 'image', function(actor, payload)
        local image = deps.mugshot.byHandle(payload and payload.id)
        if not image then return false, CH.ERR.NOT_FOUND end
        return { id = payload.id, image = image }
    end)

    -- What the creator can actually put up, read server-side so the builder
    -- never displays something they do not hold.
    handler('rewardOptions', 'wallet', function(actor)
        local dirty = exports.ox_inventory:GetItem(actor.source, Config.Sources.dirty.item, nil, true) or 0

        -- Read once and shared: items and weapons come out of the same
        -- inventory, and asking for it twice per request is one round trip
        -- to ox_inventory more than it takes.
        local carried, readOk = App.readInventory(actor)

        return {
            cash    = actor.player.Functions.GetMoney('cash'),
            bank    = actor.player.Functions.GetMoney('bank'),
            dirty   = dirty,
            items   = App.escrowableItems(actor, carried),
            weapons = App.escrowableWeapons(actor, carried),
            -- False when ox_inventory could not be read at all, which is a
            -- different thing from carrying nothing and has to say so.
            inventoryRead = readOk,
            caps    = {
                cash = Config.Sources.cash.max, bank = Config.Sources.bank.max,
                dirty = Config.Sources.dirty.max, slots = Config.Limits.MaxPayoutSlots,
                bonusPercent = Config.Bonus.maxPercent,
                -- How a contract placed now may be completed, as the board's
                -- settings say it too. The Place form learned it from the
                -- board alone, so with that read failed it offered a
                -- kidnapping bonus under 'alive', which create places as 0,
                -- and told the creator it had taken one. This is read every
                -- time the form opens. The bonus cap stays as it is: a
                -- contract placed under 'either' can still have its raised.
                fulfilment = Util.placingRule(),
                maxStacks = Config.Sources.item.maxStacks,
                maxPerStack = Config.Sources.item.maxPerStack,
                maxWeapons = Config.Sources.weapon.max,
                -- Whether the server takes goods at all. A form that simply
                -- omits the section leaves the player searching for an option
                -- that was switched off.
                itemsEnabled = sourceEnabled('item'),
                weaponsEnabled = sourceEnabled('weapon'),
                -- The same for the three money sources. Each has an
                -- `enabled` flag the server honours when the contract is
                -- submitted, and the form was never told about it — so a
                -- source an operator had switched off was still offered, with
                -- the player's balance printed above it, and the whole
                -- contract was then refused with "That reward does not add
                -- up". The message blames the numbers; the numbers were fine.
                cashEnabled = sourceEnabled('cash'),
                bankEnabled = sourceEnabled('bank'),
                dirtyEnabled = sourceEnabled('dirty'),
                -- The total the server will accept across every payout.
                -- Without it the form could build a contract that is always
                -- refused, and blame the amounts.
                maxLines = Config.Limits.MaxEscrowLines,
                -- And the most one contract may be worth in money, bonus
                -- included. Over it the server refused the contract as not
                -- adding up, about amounts that each sat inside their caps.
                maxValue = Config.MaxContractValue,
                -- And the least, counted the same way, goods not at all
                -- (Config.Limits.MinContractReward; 0 for none). The form
                -- says it before anything is typed rather than after.
                minValue = Config.Limits.MinContractReward or 0,
            },
        }
    end)

    -- Contracts ---------------------------------------------------------

    handler('create', 'create', function(actor, payload)
        -- A handle that no longer resolves is a person who cannot be named
        -- any more — the handle lapsed, or they left and took their handles
        -- with them — not a field the player typed wrong. It answered
        -- INVALID_INPUT, "Check what you entered.", on a form with nothing
        -- wrong in it; NOT_FOUND is what the same person already produces
        -- when they log off between being picked and being placed, and the
        -- page re-reads the list on it.
        local targetCid = App.resolveTargetHandle(actor.cid, payload.target)
        if not targetCid then
            if type(payload.target) ~= 'string' or payload.target == '' then
                return false, CH.ERR.INVALID_INPUT
            end
            return false, CH.ERR.NOT_FOUND
        end

        local contract, err, refusal = deps.contracts.create(actor, {
            targetCid     = targetCid,
            reason        = payload.reason,
            reasonPreset  = payload.reasonPreset,
            mode          = payload.mode,
            reward        = payload.reward,
            bonusPercent  = payload.bonusPercent,
            bailoutAmount = payload.bailoutAmount,
            penaltyAmount = payload.penaltyAmount,
            anonymous     = payload.anonymous,
        })
        if not contract then return false, err, refusal end
        return deps.projection.contract(contract, actor.cid)
    end)

    handler('accept', 'accept', function(actor, payload)
        -- penaltyAmount is what the page had on screen when the player
        -- tapped Accept, echoed back so a stake that has moved since is
        -- refused rather than charged (§14.18).
        local standing = deps.storage.readContract(Util.toId(payload.id))
        if not deps.contracts.stakeWasDisclosed(standing, payload.penaltyAmount) then
            return false, CH.ERR.TERMS_CHANGED
        end

        -- The third is what a refusal says beyond its code: what the hitman
        -- was short of, or how many they may hold. Never on success, where
        -- it is their hitman row.
        local ok, err, refusal = deps.contracts.accept(actor, payload.id, payload.anonymous,
            { checkDisclosure = true, disclosed = payload.penaltyAmount,
              shownDeadline = tonumber(payload.deadline) })
        if not ok then return false, err, refusal end
        local contract = deps.storage.readContract(Util.toId(payload.id))
        return deps.projection.contract(contract, actor.cid)
    end)

    -- Taking a contract back down, and changing one nobody has taken.
    -- Both are creator-only and both are refused the moment somebody is
    -- actually working it.
    handler('cancel', 'accept', function(actor, payload)
        local ok, err, result = deps.contracts.cancel(actor, payload.id)
        -- On a refusal the third is how long a busy key has been held.
        if not ok then return false, err, result end
        -- How much could not be handed back yet, so the page does not say
        -- "everything has been returned" beside a phone notification saying
        -- some of it is waiting.
        return { id = payload.id, queued = result and result.owed or 0 }
    end)

    handler('revise', 'amend', function(actor, payload)
        -- Busy says for how long (Contracts.serialized), for the page's words.
        local ok, err, detail = deps.contracts.revise(actor, payload.id, {
            reason = payload.reason,
            -- The index a preset server takes instead of text. Left out
            -- here, the picker the Edit dialog draws sent a choice that
            -- never arrived, and the edit was refused as invalid input.
            reasonPreset = payload.reasonPreset,
            deadlineSeconds = payload.deadlineSeconds,
        })
        if not ok then return false, err, detail end
        return { id = payload.id }
    end)

    -- What the reward is made of, for the creator who is changing it.
    --
    -- A separate request from the listing on purpose: the listing is a money
    -- total and a count of goods, which is what a hitman decides on, and it
    -- is sent to everyone. This is the individual property, with the ids
    -- that name it, and only ever to the person who put it up.
    handler('rewardBreakdown', 'load', function(actor, payload)
        local breakdown = deps.projection.rewardLines(Util.toId(payload.id) or '', actor.cid)
        -- Not found and not yours are the same answer. Telling them apart
        -- would turn this into a way to ask whether a contract id exists.
        if not breakdown then return false, CH.ERR.NOT_FOUND end
        return breakdown
    end)

    -- Take part of a reward back out. The other half of addEscrow, which
    -- only ever adds.
    handler('withdrawReward', 'amend', function(actor, payload)
        local ids = payload.lines
        if type(ids) ~= 'table' then return false, CH.ERR.INVALID_INPUT end

        -- msgpack hands a client-sent array over as a map when its keys are
        -- not a clean 1..n sequence, and a hand-built payload need not be an
        -- array at all. Flattened to a list here so what follows counts what
        -- was really sent rather than what #ids happens to say — a map's
        -- length operator reports zero, so an unflattened one would look
        -- like an empty request whatever it held.
        --
        -- The ceiling is checked while flattening rather than afterwards:
        -- a client sending a hundred thousand keys must not become a
        -- hundred thousand table appends before anything refuses it. This
        -- is about what a refusal costs, not whether it happens —
        -- Contracts.withdrawReward re-checks the length it is handed, and
        -- that is the check the suite can see. What each entry *is* is not
        -- checked here either: withdrawReward puts every id through
        -- Util.toLineId, and a second shallower version of that rule here
        -- would only be a second place to keep it in step.
        local list = {}
        for _, id in pairs(ids) do
            list[#list + 1] = id
            if #list > Config.Limits.MaxEscrowLines then
                return false, CH.ERR.INVALID_INPUT
            end
        end

        local ok, err, result = deps.contracts.withdrawReward(actor, payload.id, list)
        -- On a refusal the third is what it says beyond the code: the least
        -- the contract may be left worth (Contracts.belowMinReward).
        if not ok then return false, err, result end
        return {
            id = payload.id,
            returned = result and result.settled or 0,
            -- A line that could not be handed back right now is not lost: it
            -- is owed and retried on next login. The page says so rather
            -- than reporting a smaller refund than the creator asked for.
            queued = result and result.pending or 0,
        }
    end)

    handler('abandon', 'accept', function(actor, payload)
        local ok, err, data = deps.contracts.abandon(actor, Util.toId(payload.id) or '')
        if not ok then return false, err, data end
        return true
    end)

    -- Fulfilment --------------------------------------------------------

    -- With how the photo is to be taken. On 'server' storage the client
    -- opens the app's own viewfinder rather than lb-phone's camera, and the
    -- page shrinks the picture to these before sending it. Said here, from
    -- the config the server checked at startup, rather than read by the
    -- client from a config file it never checks.
    handler('requestPhotoToken', 'photo', function(actor, payload)
        local token, err = deps.photo.issue(actor, payload.id)
        if not token then return false, err end
        return {
            token = token,
            storage = deps.photo.storage(),
            maxSide = Config.Completion.PhotoMaxSide,
            maxBytes = Config.Completion.PhotoMaxBytes,
        }
    end)

    -- Its own bucket, not the one requestPhotoToken bills.
    --
    -- Both used to charge `photo`, so one verification spent two of three
    -- allowed attempts — and the second charge lands AFTER the hitman has
    -- lined up and taken the shot. Whether a retry sequence can actually
    -- exhaust it depends on how long the camera is open, because the bucket
    -- refills while it is; the reachability is marginal. What is not
    -- marginal is the shape of the failure when it happens: a confirmed
    -- kill, photographed, refused for going too fast, at the one moment in
    -- the flow where the player has already done the work.
    --
    -- Asking for a token is the act worth limiting — it is what somebody
    -- probing would repeat. A submission is the completion of work the
    -- server itself authorised, against a token it issued and that can only
    -- be used once, so it is limited separately and more loosely.
    --
    -- A link on 'host' storage, the picture itself on 'server' storage; the
    -- client sends the picture as a latent event, which arrives here like
    -- any other. Never from the page: this is not one of the page's events,
    -- and the token it needs stays in the client's Lua.
    --
    -- A refusal about where the hitman is or whether the kill still stands
    -- is given back like any other, since they can move and try again. One
    -- that read the picture keeps its charge (Photo.submit says which): a
    -- page makes a picture the server can read, so one it refused is not
    -- worth trying again at once, and reading it is the work this limit is
    -- for.
    handler('submitPhoto', 'photoSubmit', function(actor, payload)
        local ok, err, result, read = deps.photo.submit(actor, payload.token, payload.url, payload.image)
        if not ok then return false, err, nil, read == true end
        return result
    end)

    -- Verify kill with kill photos switched off (Config.Completion.KillPhotos):
    -- the kill is completed at the scene on the server's own facts, with no
    -- camera and no picture (Photo.verifyAtScene), and answered as a photo
    -- submission is. In the token's bucket, since it is the same act a
    -- token request is. With kill photos on it is refused as
    -- photo_required, and the page opens the camera instead.
    handler('verifyKill', 'photo', function(actor, payload)
        local ok, err, result = deps.photo.verifyAtScene(actor, payload.id)
        if not ok then return false, err end
        return result
    end)

    -- The client's one look at a kill photo, asked for by handle from the
    -- Ledger. Asked for, and never inferred from the ledger being read: the
    -- page reads the ledger on every refresh.
    --
    -- Owner only and once only (Photos.open). A handle that is not the
    -- caller's is answered exactly as one that does not exist.
    --
    -- A photo kept on this server is a few hundred kilobytes of data URI. It
    -- goes to the client's phone alone, as a latent event, which FiveM
    -- sends in pieces at a set rate rather than as one burst. The ordinary
    -- reply only says it is on its way: every reply is also handed to the
    -- open app as a message, and a picture of a body has no business being
    -- passed around twice.
    --
    -- The reply also says how it may be saved: `link` where this server can
    -- serve it to the phone's Photos itself, `kept` for one kept in the
    -- app, which opens as often as its owner likes.
    --
    -- One on its way to a player at a time (photoSending). Asked before the
    -- photo is opened, so a refusal spends no look and reads no file.
    handler('openPhoto', 'photoView', function(actor, payload)
        local sending = photoSending[actor.source]
        if sending then
            -- Said to have landed: free once it could have. Otherwise once
            -- the client itself would have stopped waiting.
            local freeAt = sending.arrived and sending.earliest or (sending.at + PHOTO_SEND_MS)
            local left = freeAt - Util.monotonicMs()
            if left > 0 then
                return false, CH.ERR.RATE_LIMITED, { retryAfter = math.ceil(left / 1000) }
            end
            photoSending[actor.source] = nil
        end
        local view, err = deps.photos.open(actor, payload.handle)
        if not view then return false, err end
        if view.image then
            local now = Util.monotonicMs()
            photoSending[actor.source] = { handle = view.handle, at = now,
                earliest = now + math.ceil(#view.image * 1000 / PHOTO_DRAIN_BPS) }
            TriggerLatentClientEvent('crimson-hitman:photoImage', actor.source, App.PHOTO_BPS,
                { handle = view.handle, src = view.image })
            return { handle = view.handle, latent = true, link = view.link, kept = view.kept,
                     photosOff = view.photosOff }
        end
        return view
    end)

    -- What the client did with the photo they have open: save, delete or
    -- keep it in the app, or ask for the link this server serves it under,
    -- to save it with (Photos.decide). Its own looser bucket, as a photo
    -- submission has: this answers a question the server itself put on the
    -- client's screen, and refused, a photo they had just saved to their
    -- phone was recorded as deleted when it timed out. A save by link is two
    -- of these.
    handler('photoDecision', 'photoDecide', function(actor, payload)
        local result, err = deps.photos.decide(actor, payload.handle, payload.choice)
        if not result then return false, err end
        return result
    end)

    handler('armKidnap', 'accept', function(actor, payload)
        local ok, err = deps.kidnap.arm(payload.id, actor.cid)
        if not ok then return false, err end
        return { armed = true }
    end)

    handler('kidnapProgress', 'progress', function(actor, payload)
        -- Returned unchanged: a fabricated { elapsed = 0 } has no `required`,
        -- which draws a NaN bar and a poller that can never finish.
        local id = Util.toId(payload.id) or ''
        local progress = deps.kidnap.progress(id, actor.cid)
        if not progress then
            -- How it ended, if it ended a moment ago. The poller is what is
            -- watching when a countdown finishes, and every ending looked the
            -- same to it — so a hitman who had just been paid for a handover
            -- was told it had ended and to try again. Keyed by this actor's
            -- own citizen id, so it only ever describes their own handover.
            local ended = deps.kidnap.outcome and deps.kidnap.outcome(id, actor.cid)
            -- Held long enough and being paid right now. Answered as a full
            -- bar rather than as an ending, so the page keeps asking and
            -- hears how the payout went.
            if ended and ended.outcome == 'settling' then
                return { settling = true,
                         elapsed = Config.Kidnap.CountdownSeconds,
                         required = Config.Kidnap.CountdownSeconds }
            end
            if ended then
                return { done = true, outcome = ended.outcome,
                         reason = ended.reason, pending = ended.pending }
            end
            -- Named, rather than left as a bare nil.
            --
            -- A handler returning nil is read as a refusal by App.reply, and
            -- with no second return value the reply carried ok = false and
            -- err = nil — a refusal with no reason in it. The page has
            -- nothing to look up, so a countdown that simply is not running
            -- reached the player as "Lost track of the handover", which
            -- sounds like a fault and is not one. Asking about a handover
            -- that has ended, or was never armed, is an ordinary question.
            return false, CH.ERR.NO_HANDOVER
        end
        return progress
    end)

    -- Target counter-play ----------------------------------------------

    -- The On me button, and the same button on the whitelisted-job view's
    -- "Contracts on you" (Config.WhitelistedView): one path for both, and
    -- for the buyout command (Bridges' cleanse), so every rule of a buyout
    -- is Bailout.buy's alone. Open to a player the app bars while the view
    -- is on ('target'): Bailout.buy acts only on a contract naming the
    -- caller, so a colleague's contract, or an id they made up, is refused
    -- there as it is for anybody.
    handler('bailout', 'bailout', function(actor, payload)
        -- The third is whether it was queued, or on a refusal what the
        -- target was short of.
        local ok, err, third = deps.bailout.buy(actor, payload.id)
        if not ok then return false, err, third end
        -- Whether it closed now or waits on a hitman, so the page can say
        -- which: "closed" while somebody can still finish it is the target
        -- walking into the open thinking they are safe.
        return { queued = third == true }
    end, 'target')

    handler('informant', 'informant', function(actor, payload)
        -- On a refusal the third says more than the code: how long a busy
        -- key has been held, or the minutes until it is sold again.
        local ok, err, data = deps.informant.buy(actor, payload.id)
        if not ok then return false, err, data end
        return data
    end)

    -- Amendments --------------------------------------------------------

    handler('addEscrow', 'amend', function(actor, payload)
        local ok, err = deps.amendments.addEscrow(actor, payload.id, payload.reward)
        if not ok then return false, err end
        return true
    end)

    handler('improve', 'amend', function(actor, payload)
        local ok, err = deps.amendments.improve(actor, payload.id, payload.kind, payload.payload)
        if not ok then return false, err end
        return true
    end)

    -- What is on the table right now. Storage.readOpenAmendments was read
    -- only by the expiry sweep, so a proposal could be made and approved
    -- and nobody could see one waiting.
    handler('amendments', 'load', function(actor, payload)
        local open, err = deps.amendments.openFor(actor, payload.id)
        if not open then return false, err end
        return open
    end)

    handler('propose', 'amend', function(actor, payload)
        local proposal, err, refusal = deps.amendments.propose(actor, payload.id, payload.kind,
            payload.payload)
        if not proposal then return false, err, refusal end
        -- outcome 'applied' when nobody else had to agree and it is in
        -- effect already; 'failed' when it was agreed but no longer fits.
        return { id = proposal.id, kind = proposal.kind, expires = proposal.expires_at,
                 outcome = proposal.outcome, err = proposal.error }
    end)

    handler('respondAmendment', 'amend', function(actor, payload)
        local ok, err, outcome = deps.amendments.respond(actor, payload.id, payload.approve == true)
        -- Agreed by everybody and refused as it went in: said as that, with
        -- the reason, rather than read as a proposal that lapsed.
        if not ok then return false, err, outcome == 'failed' and { outcome = outcome } or nil end
        return { outcome = outcome }
    end)

    -- Relay -------------------------------------------------------------

    handler('threads', 'load', function(actor, payload)
        return deps.comms.threads(actor, payload.id)
    end)

    -- With the reader's own mute, so the thread's Mute button says what is
    -- true for both roles: a hitman opens their thread without a handle and
    -- has no thread entry to carry it on.
    handler('readThread', 'load', function(actor, payload)
        local messages, err, about = deps.comms.read(actor, payload.id, payload.thread)
        if not messages then return false, err end
        return { messages = messages, muted = about and about.muted == true }
    end)

    -- In the relay's bucket, as a call request is: each toggle is a store
    -- write, and one that cost nothing could be tapped into a stream of them.
    handler('muteThread', 'message', function(actor, payload)
        local ok, err, result = deps.comms.mute(actor, payload.id, payload.thread, payload.muted)
        if not ok then return false, err end
        return { muted = result and result.muted == true }
    end)

    -- No bucket here: Comms.send owns the message throttle, and applying it
    -- in both places charged two tokens per message.
    handler('sendMessage', nil, function(actor, payload)
        local ok, err = deps.comms.send(actor, payload.id, payload.thread, payload.body)
        if not ok then return false, err end
        return true
    end)

    handler('requestCall', 'message', function(actor, payload)
        local ok, err, result = deps.comms.requestCall(actor, payload.id, payload.thread)
        if not ok then return false, err end
        -- Whether a call is actually ringing or the other party has merely
        -- been asked to call back. The app says which; implying a call is
        -- connecting when none is, is the worst of the three outcomes.
        return { placed = result and result.placed == true,
                 reason = result and result.reason or nil }
    end)

    -- The Hang up the phone itself does not draw for a call placed from
    -- here. Names no contract: it ends the caller's own call and nobody
    -- else's.
    handler('endCall', 'message', function(actor)
        local ok, err, result = deps.comms.endCall(actor)
        if not ok then return false, err end
        return { ended = result and result.ended == true }
    end)

    -- Diagnostics ---------------------------------------------------------

    --- A fault the page caught, on its way to somewhere an owner can read it.
    ---
    --- The app runs in CEF, which has no console anybody looks at. Until
    --- this existed a JavaScript error in the page reached nothing: not the
    --- client, not this log, not the operator. Every render crash this
    --- resource has shipped was found because a player said "it broke", and
    --- that is the entire diagnostic anyone had.
    ---
    --- Gated, throttled and rate-limited like every other handler, because
    --- it is reachable from any frame the phone draws. Open to a player the
    --- app bars while the whitelisted-job view is on ('report'): that view is
    --- a page of its own whose faults are worth hearing of, and the log the
    --- diagnosis asks a barred subject's page for comes back this way.
    --- Everything in the
    --- payload came from a browser and is treated as such: truncated to
    --- lengths the audit detail can hold, and never interpolated into
    --- anything but a log line.
    handler('pageError', 'diagnostic', function(actor, payload)
        local what = Util.sanitizeText(payload.what, 300) or 'unspecified'
        local where = Util.sanitizeText(payload.where, 200)
        local stack = Util.sanitizeText(payload.stack, 900)
        local build = Util.sanitizeText(payload.build, 40)

        -- The log a staff member asked for with the diagnosis: sent to
        -- whoever asked (App.expectDump), once, as the rest of the
        -- command's answer is. Never Log.always: that is for money and
        -- failed writes, and a page's log is neither.
        local asked = dumpsAsked[actor.source]
        local requested = what == 'page diagnostics' and where == 'requested'
            and asked ~= nil and asked.untilAt >= os.time()
        if requested then dumpsAsked[actor.source] = nil end

        -- Everything here was written by a browser any player can script,
        -- so every line it makes is marked as the page's (shared/log.lua
        -- takes colour codes out of each): a line of its stack could
        -- otherwise read as one of this resource's own.
        local stackLines = {}
        if stack and stack ~= '' then
            for line in (stack .. ' || '):gmatch('(.-) || ') do
                if line ~= '' then stackLines[#stackLines + 1] = line end
            end
        end

        if requested then
            local lines = { ('player %s\'s app sent its log (build %s, %s):')
                :format(tostring(actor.source), build or 'unknown', actor.cid) }
            for i = 1, #stackLines do lines[#lines + 1] = '  page: ' .. stackLines[i] end
            if #stackLines == 0 then lines[#lines + 1] = '  page: nothing recorded' end
            for i = 1, #lines do lines[i] = Log.plain(lines[i]) end
            local sent = false
            if type(asked.deliver) == 'function' then
                sent = pcall(asked.deliver, lines)
            end
            if not sent then
                for i = 1, #lines do Log.debug(lines[i], 'page-log') end
            end
        else
            -- Kept as one counted entry however it is worded: one player
            -- sending reports of their own wording must not push anything
            -- else out of what the diagnosis lists (shared/log.lua).
            Log.debug(('the app reported a fault: %s (%s, build %s, %s)')
                :format(what, where or 'nowhere named', build or 'unknown', actor.cid), 'page-fault')

            -- The stack only under Config.Debug. It is what actually locates
            -- the fault, and it is also several lines of console per report
            -- — which on a busy server, from a page that breaks for everyone
            -- at once, is the console gone. Kept in the audit row either way,
            -- so turning the switch on is about where it is convenient to
            -- read, not about whether it was recorded.
            if Config.Debug then
                for i = 1, #stackLines do
                    Log.debug(('  page stack from %s: %s'):format(actor.cid, stackLines[i]),
                        'page-fault-stack')
                end
            end
        end

        deps.audit.rejected('page_error', actor.cid, nil, {
            what = what, where = where, stack = stack, build = build,
        })

        pageFaults[#pageFaults + 1] = {
            at = os.time(), cid = actor.cid, what = what,
            where = where, build = build,
        }
        if #pageFaults > PAGE_FAULTS_KEPT then table.remove(pageFaults, 1) end

        -- Answered so the page knows it landed. It does nothing with the
        -- reply today, but a report that silently vanishes is the thing
        -- this handler exists to stop happening.
        return { recorded = true }
    end, 'report')

    -- Death reporting ---------------------------------------------------
    --
    -- Accepted only from the victim's own client, and everything about it is
    -- then verified server-side (§14.2). A killer cannot report a death.
    --
    -- These carry no payload but are still gated and throttled: a client can
    -- fire them as fast as it likes, and each one walks the contract table.

    --- Deaths reported while boot recovery runs (App.ready), one per player,
    --- held until it has finished.
    ---
    --- They were dropped, on the word of a comment saying the condition
    --- sampler records the kill anyway. It did not then, and the client
    --- reports a death once and not again while the player stays dead: the
    --- hitman standing over the body was told there was no kill to verify.
    --- The sampler now attributes a death nobody reports, a few seconds on
    --- (Death.UNREPORTED_WAIT_MS), but only from the damage log; the report
    --- is what can name the killer, so it is still held, not dropped.
    local heldDeaths = {}
    local onDied

    local function holdDeath(src, killerServerId)
        local waiting = heldDeaths[src] ~= nil
        heldDeaths[src] = { killer = killerServerId }
        if waiting then return end
        local function later()
            SetTimeout(1000, function()
                if not App.ready then return later() end
                local held = heldDeaths[src]
                heldDeaths[src] = nil
                -- Checked again as it stands now: dead, in range, and on a
                -- contract, as any report is.
                if held then onDied(src, held.killer) end
            end)
        end
        later()
    end

    RegisterNetEvent('crimson-hitman:iDied', function(killerServerId)
        local src = source
        if not App.ready then return holdDeath(src, killerServerId) end
        onDied(src, killerServerId)
    end)

    onDied = function(src, killerServerId)
        if not App.floodOk(src, 'iDied') then return end

        local actor = deps.identity.resolve(src)
        if not actor then return end
        if not deps.ratelimit.check(actor, 'death') then
            if shouldLogRatelimit(actor.cid, 'iDied') then
                deps.audit.rejected('ratelimit_iDied', actor.cid, nil, {})
            end
            return
        end

        -- The killer id is a hint from the victim, not an instruction: the
        -- server still checks they accepted the contract, were in range, and
        -- that the condition loss was observed.
        local ok, err = pcall(deps.death.onVictimReport, src, tonumber(killerServerId))
        if not ok then deps.audit.rejected('error_iDied', actor.cid, nil, { error = tostring(err) }) end
    end

    -- The client saying the photo openPhoto sent it is there, so the next
    -- open need not wait out PHOTO_SEND_MS. Only ever lets go of the
    -- sender's own, and only of the photo named; anything else is ignored.
    -- Never sooner than the photo could have landed (PHOTO_DRAIN_BPS): said
    -- earlier, it is let go of then.
    RegisterNetEvent('crimson-hitman:photoArrived', function(handle)
        local src = source
        -- Nothing is on its way to anybody with kill photos off and none
        -- kept (photosOff): ignored unread.
        if photosOff('openPhoto') and not photoSending[src] then return end
        if not App.floodOk(src, 'photoArrived') then return end
        local sending = photoSending[src]
        if sending and type(handle) == 'string' and sending.handle == handle then
            if Util.monotonicMs() >= (sending.earliest or 0) then
                photoSending[src] = nil
            else
                sending.arrived = true
            end
        end
    end)

    -- What the sender's own game shows about their mask, sent by their
    -- client when it changes (client/main.lua), for the nearby list. About
    -- the sender alone: it names nobody, so a modified client can only hide
    -- itself or show itself. Heard only while the list is on, as the client
    -- sends it, and only from a loaded character: one sent before, or
    -- between characters, was kept for whoever loaded next. Anything but a
    -- yes or no is refused.
    RegisterNetEvent('crimson-hitman:maskState', function(masked)
        local src = source
        if (tonumber(src) or 0) <= 0 then return end
        local rules = Config.Targeting
        local allowed = type(rules) == 'table' and rules.AllowNearby == true
        if allowed then
            local resolved, actor = pcall(deps.identity.resolve, src)
            allowed = resolved and actor ~= nil
        end
        if not allowed then
            if shouldLogGate(src) then
                deps.audit.rejected('gate_maskState', nil, nil, { source = src })
            end
            return
        end
        if not App.floodOk(src, 'maskState') then return end
        if type(masked) ~= 'boolean' then
            if shouldLogGate(src) then
                deps.audit.rejected('mask_bad_format', nil, nil, { source = src })
            end
            return
        end
        masks[tonumber(src) or src] = masked
    end)

    RegisterNetEvent('crimson-hitman:iRevived', function()
        local src = source
        if not App.ready then return end
        if not App.floodOk(src, 'iRevived') then return end

        local actor = deps.identity.resolve(src)
        if not actor then return end
        if not deps.ratelimit.check(actor, 'death') then
            if shouldLogRatelimit(actor.cid, 'iRevived') then
                deps.audit.rejected('ratelimit_iRevived', actor.cid, nil, {})
            end
            return
        end
        local ok, err = pcall(deps.death.onRevivedVerified, src, actor.cid)
        if not ok then deps.audit.rejected('error_iRevived', actor.cid, nil, { error = tostring(err) }) end
    end)
end

--------------------------------------------------------------------------
-- What a creator may put up
--------------------------------------------------------------------------
--
-- The server has always been able to escrow items and weapons — validated,
-- snapshotted and restored. The form could not offer them because nothing
-- told it what the player was carrying. These do.

--- Read a player's inventory, tolerating whichever export this build has.
--- The player's inventory, and whether it could actually be read.
---
--- An empty table and an unreadable inventory used to look identical to
--- every caller, so a build whose export shape neither branch matched
--- produced a Place form with no item or weapon section at all — nothing on
--- screen to say the inventory could not be read, and nothing to try again.
--- The second return distinguishes them.
---@return table slots
---@return boolean read
--- Which read actually answered, so the startup report can say. An empty
--- item picker with no explanation is the symptom; this is how an operator
--- finds out whether their build was even asked the right question.
App.inventorySource = nil

--- The reads a build might answer with, in order.
---
--- ox_inventory's export surface has moved: GetInventory returns a table
--- whose `items` are keyed by slot number rather than listed, and some
--- builds expose GetInventoryItems while others do not. Calling an export
--- that is not there throws rather than returning nil, so each is tried
--- under pcall — and a shape that is not a table of slots is not accepted
--- just because the call did not fail.
---
--- Only exports that exist are listed. Guessing at further names would read
--- as robustness while testing nothing: every entry here is exercised by
--- the suite, and one that is not does not belong.
local INVENTORY_READS = {
    { name = 'GetInventoryItems', read = function(src)
        return exports.ox_inventory:GetInventoryItems(src)
    end },
    { name = 'GetInventory.items', read = function(src)
        local inv = exports.ox_inventory:GetInventory(src)
        return inv and inv.items or nil
    end },
}

--- Whether this looks like a list of inventory slots rather than something
--- else that happens to be a table — an empty inventory and a wrong shape
--- are both `{}` to a type check, and accepting the wrong one means every
--- later read comes back empty for good.
local function looksLikeSlots(value)
    if type(value) ~= 'table' then return false end
    local seen = 0
    for _, slot in pairs(value) do
        seen = seen + 1
        if type(slot) ~= 'table' or type(slot.name) ~= 'string' then return false end
        if seen >= 5 then break end
    end
    return true
end

--- The player's inventory, and whether it could actually be read.
---
--- An empty table and an unreadable inventory used to look identical to
--- every caller, so a build whose export shape neither branch matched
--- produced a Place form with no item or weapon section at all — nothing on
--- screen to say the inventory could not be read, and nothing to try again.
--- The second return distinguishes them.
---@return table slots
---@return boolean read
function App.readInventory(actor)
    for i = 1, #INVENTORY_READS do
        local attempt = INVENTORY_READS[i]
        local ok, inventory = pcall(attempt.read, actor.source)
        if ok and looksLikeSlots(inventory) then
            App.inventorySource = attempt.name
            return inventory, true
        end
    end

    App.inventorySource = false
    return {}, false
end

--- Ask ox_inventory which read this build answers, using somebody who is
--- online. Reported rather than acted on: the answer is for the operator.
---
--- Takes the actor rather than finding one, so it can be called before the
--- app is wired — which is exactly when the startup report runs.
---@param actor table|nil nil when nobody is online to ask about
---@return string|false|nil
function App.probeInventory(actor)
    if not actor then return nil end
    App.readInventory(actor)
    return App.inventorySource
end

local function isWeapon(name)
    return type(name) == 'string' and name:upper():sub(1, 7) == 'WEAPON_'
end

--- Stackable items the creator could escrow, excluding weapons, currency
--- and anything the server forbids.
---@param carried table[]|nil an already-read inventory, to save a round trip
function App.escrowableItems(actor, carried)
    if not sourceEnabled('item') then return {} end

    local totals, order = {}, {}
    local slots = carried or App.readInventory(actor) or {}

    for _, slot in pairs(slots) do
        local name = slot and slot.name
        if type(name) == 'string'
            and not isWeapon(name)
            and not deps.escrow.isDirtyItem(name)
            and not deps.escrow.blacklisted(name) then
            if not totals[name] then
                totals[name] = { name = name, label = slot.label or name, count = 0 }
                order[#order + 1] = totals[name]
            end
            totals[name].count = totals[name].count + (slot.count or 1)
        end
    end

    table.sort(order, function(a, b) return a.label < b.label end)
    return order
end

--- Individual weapons, kept separate because each is one object with its
--- own serial and attachments rather than a stack.
---@param carried table[]|nil an already-read inventory, to save a round trip
function App.escrowableWeapons(actor, carried)
    if not sourceEnabled('weapon') then return {} end

    local out = {}
    local slots = carried or App.readInventory(actor) or {}

    for _, slot in pairs(slots) do
        local name = slot and slot.name
        -- The inventory slot is what identifies the weapon on submit, so a
        -- record without one cannot be escrowed and must not be offered:
        -- picking it would hand the server a payload it can only refuse.
        local invSlot = slot and tonumber(slot.slot)
        if isWeapon(name) and invSlot and not deps.escrow.blacklisted(name) then
            out[#out + 1] = {
                name  = name,
                label = slot.label or name,
                slot  = invSlot,
                -- Enough for the creator to tell two of the same weapon
                -- apart, without publishing the serial to anyone else.
                serial = slot.metadata and slot.metadata.serial
                    and tostring(slot.metadata.serial):sub(-4) or nil,
            }
        end
    end

    table.sort(out, function(a, b)
        if a.label == b.label then return (a.slot or 0) < (b.slot or 0) end
        return a.label < b.label
    end)
    return out
end

--------------------------------------------------------------------------
-- Target handles
--------------------------------------------------------------------------
--
-- A citizen id is an internal key. Search results carry a per-searcher,
-- expiring handle instead, so a client cannot collect ids or reuse another
-- player's results.

local targetHandles = {}
local targetSeq = 0

--- The handle already minted for one searcher and one person:
--- [searcher .. ':' .. target] = handle. Minting walked every live handle
--- to find out whether there was one, and a browse page mints thirty: with
--- a few players paging through the city, thousands of handles walked per
--- page. Kept by dropHandle, the one way a handle goes.
local handleOf = {}

local function pairKey(searcherCid, targetCid)
    return tostring(searcherCid) .. ':' .. tostring(targetCid)
end

local function dropHandle(handle)
    local entry = targetHandles[handle]
    if not entry then return end
    targetHandles[handle] = nil
    local key = pairKey(entry.searcher, entry.target)
    if handleOf[key] == handle then handleOf[key] = nil end
end

function App.mintTargetHandle(searcherCid, targetCid)
    local key = pairKey(searcherCid, targetCid)
    local existing = handleOf[key]
    local entry = existing and targetHandles[existing]
    if entry and entry.searcher == searcherCid and entry.target == targetCid then
        entry.at = Util.monotonicMs()
        return existing
    end

    targetSeq = targetSeq + 1
    local handle = ('tg%08d'):format(targetSeq)
    targetHandles[handle] = { searcher = searcherCid, target = targetCid, at = Util.monotonicMs() }
    handleOf[key] = handle
    return handle
end

function App.resolveTargetHandle(searcherCid, handle)
    if type(handle) ~= 'string' then return nil end
    local entry = targetHandles[handle]
    if not entry or entry.searcher ~= searcherCid then return nil end
    if Util.monotonicMs() - entry.at > 600000 then
        dropHandle(handle)
        return nil
    end
    return entry.target
end

--- Drop stale handles. Called from the maintenance tick.
function App.sweepHandles()
    local cutoff = Util.monotonicMs() - 600000
    local removed = 0
    for handle, entry in pairs(targetHandles) do
        if entry.at < cutoff then
            dropHandle(handle)
            removed = removed + 1
        end
    end
    return removed
end

function App.clearPlayerHandles(cid)
    for handle, entry in pairs(targetHandles) do
        if entry.searcher == cid or entry.target == cid then dropHandle(handle) end
    end
end

--- Whether a player may see the app at all. lb-phone asks this before it
--- shows the icon; the answer is re-checked on every event regardless.
function App.canUseApp(src)
    local actor = deps.identity.gate(src)
    return actor ~= nil
end

return App
