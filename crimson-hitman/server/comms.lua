--- Masked relay between creator and hitmen (§11).
---
--- Messages are relayed server-side and rendered under a per-contract alias.
--- No phone number, character name, citizen id or source ever crosses to the
--- other participant; anonymity is enforced by what is *not* in the payload.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Comms = {}

--- The phone's own word blacklist, where this build has one.
---
--- lb-phone ships its server code escrowed and its export surface has moved
--- across releases, so indexing an export that is not there throws — and
--- both call sites are inside handlers, which makes that not a degraded
--- feature but every contract refused with server_error and every message
--- the same. The resource states this rule in two places and enforced it
--- only on the client.
---
--- Open rather than closed when the export is missing: refusing everything
--- would be the same outage with a tidier message, and the rules this
--- resource owns — the length cap, the digit cap, the pattern denylist —
--- are applied either way. Which build this is gets reported at startup.
---@param source integer
---@param text string
---@return boolean blocked
local function phoneRefuses(source, text)
    local ok, blocked = pcall(function()
        return exports['lb-phone']:ContainsBlacklistedWord(source, text)
    end)
    return ok and blocked == true
end

local Storage, Identity, Audit, Notify, RateLimit

--- Opaque thread handles issued to clients, so a citizen id never leaves the
--- server. [handle] = { contractId, hitmanCid, ownerCid }
local handles = {}
local handleSeq = 0

function Comms.init(deps)
    Storage, Identity, Audit, Notify, RateLimit =
        deps.storage, deps.identity, deps.audit, deps.notify, deps.ratelimit
    handles = {}
end

--- Mint (or reuse) a handle that stands in for a hitman on one contract, for
--- one viewer. Handing the creator a hitman's citizen id would defeat
--- Anonymous Mode outright, and a citizen id is an internal key in any case.
local function handleFor(ownerCid, contractId, hitmanCid)
    for handle, entry in pairs(handles) do
        if entry.ownerCid == ownerCid and entry.contractId == contractId
            and entry.hitmanCid == hitmanCid then
            return handle
        end
    end

    handleSeq = handleSeq + 1
    local handle = ('th%s%06d'):format(contractId:gsub('[^%w]', ''), handleSeq)
    handles[handle] = { contractId = contractId, hitmanCid = hitmanCid, ownerCid = ownerCid }
    return handle
end

--- Resolve a handle back to a hitman, for one viewer only. A handle minted
--- for someone else is not accepted.
local function resolveHandle(ownerCid, contractId, handle)
    if type(handle) ~= 'string' then return nil end
    local entry = handles[handle]
    if not entry then return nil end
    if entry.ownerCid ~= ownerCid or entry.contractId ~= contractId then return nil end
    return entry.hitmanCid
end

function Comms.clearContract(contractId)
    for handle, entry in pairs(handles) do
        if entry.contractId == contractId then handles[handle] = nil end
    end
end

--- A player has gone: the handles they were given go with them.
---
--- Only theirs. It also dropped every handle that NAMED them, so when an
--- anonymous operative logged off, the client's handle for their thread
--- stopped working and the next `threads` minted a new one — a message,
--- a call or a re-read told the client the moment their anonymous operative
--- left the city and came back. A handle naming a hitman lasts while that
--- hitman is on the contract (Comms.clearHitman) and the contract lives.
function Comms.clearPlayer(cid)
    for handle, entry in pairs(handles) do
        if entry.ownerCid == cid then handles[handle] = nil end
    end
end

--- A hitman has left a contract: nobody's handle for their thread on it
--- means anything now.
function Comms.clearHitman(contractId, hitmanCid)
    for handle, entry in pairs(handles) do
        if entry.contractId == contractId and entry.hitmanCid == hitmanCid then
            handles[handle] = nil
        end
    end
end

--- What a hitman sees the person who placed the contract called: in the
--- thread, on every message they sign, and in the phone notice of a message
--- or a call. Never "Client": a player new to the app did not know who that
--- was, on the one rule this server runs on (the target is brought to this
--- person, alive).
local PLACER_ALIAS = 'The person who placed it'
Comms.PLACER_ALIAS = PLACER_ALIAS

--- The alias messages were signed with before, still on stored rows.
local OLD_PLACER_ALIAS = 'Client'

--- A thread is one creator-hitman pair. In competitive mode the creator has
--- a separate thread per hitman, and hitmen never see each other.
local function threadId(contractId, hitmanCid)
    return contractId .. '|' .. hitmanCid
end

--- Resolve the caller's role and thread, or refuse.
---@return table|nil ctx { contract, role, hitmanCid, threadId, alias }
---@return string|nil err
--- @param threadHandle string|nil an opaque handle from Comms.threads
function Comms.context(actor, contractId, threadHandle)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CH.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CH.ERR.NOT_FOUND end

    -- A thread lives as long as its contract (§11.2). Nothing here asked,
    -- and a hitman's row stays 'active' when a contract ends — only the
    -- creator's handles are dropped — so a hitman could go on writing to
    -- the client of a finished contract indefinitely, every message a
    -- notification on their phone, while the client could no longer answer
    -- and was told "That is not yours" about the conversation instead.
    if CH.TERMINAL[contract.state] then return nil, CH.ERR.ALREADY_SETTLED end

    if contract.creator_cid == actor.cid then
        -- The creator names a thread by its handle, never by a citizen id.
        local hitmanCid = resolveHandle(actor.cid, contractId, threadHandle)
        local hitman = hitmanCid and Storage.readHitman(contractId, hitmanCid)
        if not hitman or hitman.state ~= 'active' then return nil, CH.ERR.NOT_PARTICIPANT end
        return {
            contract = contract, role = 'creator', hitmanCid = hitman.hitman_cid,
            threadId = threadId(contractId, hitman.hitman_cid), alias = PLACER_ALIAS,
        }
    end

    local hitman = Storage.readHitman(contractId, actor.cid)
    if hitman and hitman.state == 'active' then
        return {
            contract = contract, role = 'hitman', hitmanCid = actor.cid,
            threadId = threadId(contractId, actor.cid), alias = hitman.alias,
        }
    end

    return nil, CH.ERR.NOT_PARTICIPANT
end

--- Send a message into a contract thread.
---@return boolean ok
---@return string|nil err
function Comms.send(actor, contractId, threadHandle, rawBody)
    if not Config.Relay.Enabled then return false, CH.ERR.RELAY_OFF end

    local ctx, err = Comms.context(actor, contractId, threadHandle)
    if not ctx then return false, err end

    -- This module owns the message bucket, so every caller is throttled and
    -- a message never costs two tokens.
    if not RateLimit.check(actor, 'message') then return false, CH.ERR.RATE_LIMITED end

    local body = Util.sanitizeText(rawBody, Config.Relay.MaxLength)
    if not body then return false, CH.ERR.INVALID_INPUT end

    if phoneRefuses(actor.source, body) then
        Audit.rejected('relay_blacklisted_word', actor.cid, contractId, {})
        return false, CH.ERR.INVALID_INPUT
    end

    Storage.writeMessage({
        contract_id = contractId,
        thread_id   = ctx.threadId,
        from_cid    = actor.cid,     -- server-side only, for the audit trail
        from_alias  = ctx.alias,     -- the only identity the other side sees
        body        = body,
        sent_at     = os.time(),
    })

    local recipient = ctx.role == 'creator' and ctx.hitmanCid or ctx.contract.creator_cid
    -- Not a ring when they muted this thread (§11.4). The message is kept
    -- and the push below still redraws a thread they have open; only the
    -- phone notification is silenced, and it is charged to their notice
    -- budget all the same so the sender cannot tell (Notify.toCitizen).
    Notify.toCitizen(recipient, 'Contract message', ('%s: %s'):format(ctx.alias, body),
        { muted = Storage.readMute(ctx.threadId, recipient) == true })
    -- And the thread, if they have it open: a buzz does not change a page,
    -- so two people in the same conversation never saw each other's replies.
    Notify.push(recipient, 'message')

    Audit.action('relay_message', actor.cid, contractId, { role = ctx.role })
    return true
end

--- Mute or unmute a thread, for the caller alone (§11.4).
---
--- Muting silences the phone notification a message into this thread would
--- send the caller, and nothing else. Messages still arrive and the thread
--- still shows them; contract notices (proposals, completion, expiry) are
--- not thread messages and still reach them; the contract is not touched.
---
--- Invisible to the other side. Nothing they send or read changes, and a
--- muted message is charged to the notice budget as a rung one is, so not
--- even "could not be reached" on a call request tells them.
---@param muted boolean
---@return boolean ok
---@return string|nil err
---@return table|nil result { muted = boolean }
function Comms.mute(actor, contractId, threadHandle, muted)
    if not Config.Relay.Enabled then return false, CH.ERR.RELAY_OFF end

    local ctx, err = Comms.context(actor, contractId, threadHandle)
    if not ctx then return false, err end
    if type(muted) ~= 'boolean' then return false, CH.ERR.INVALID_INPUT end

    -- Written only when it changes: a second tap of the same answer is the
    -- answer already given, not another row or another audit entry.
    if (Storage.readMute(ctx.threadId, actor.cid) == true) ~= muted then
        Storage.setMute(ctx.contract.id, ctx.threadId, actor.cid, muted, os.time())
        Audit.action(muted and 'relay_muted' or 'relay_unmuted', actor.cid, ctx.contract.id,
            { role = ctx.role })
    end
    return true, nil, { muted = muted }
end

--- Read a thread. Returns only alias-attributed messages: the caller cannot
--- learn who the other party is from what comes back.
---@return table[]|nil messages
---@return string|nil err
---@return table|nil about { muted = boolean } — the caller's own mute, never the other side's
function Comms.read(actor, contractId, threadHandle)
    -- The switch applies to the whole relay, not only to sending. It was
    -- read by send() alone, so with it off the thread still opened, with a
    -- compose box whose every message was refused.
    if not Config.Relay.Enabled then return nil, CH.ERR.RELAY_OFF end

    local ctx, err = Comms.context(actor, contractId, threadHandle)
    if not ctx then return nil, err end

    local rows = Storage.readMessages(contractId, ctx.threadId)
    local out = {}
    -- The newest only, whatever the store holds: a thread written before
    -- the stores were bounded is pruned only by its next message.
    local keep = tonumber(Config.Relay.MaxMessagesPerThread) or 0
    local first = (keep > 0 and #rows > keep) and (#rows - keep + 1) or 1
    for i = first, #rows do
        -- The placer's, by who sent it: one stored before they were called
        -- this was signed "Client".
        local alias = rows[i].from_alias
        if rows[i].from_cid == ctx.contract.creator_cid or alias == OLD_PLACER_ALIAS then
            alias = PLACER_ALIAS
        end
        out[#out + 1] = {
            alias = alias,
            body  = rows[i].body,
            at    = rows[i].sent_at,
            mine  = rows[i].from_cid == actor.cid,
        }
    end
    return out, nil, { muted = Storage.readMute(ctx.threadId, actor.cid) == true }
end

--- Threads visible to the caller, for the app's inbox.
function Comms.threads(actor, contractId)
    if not Config.Relay.Enabled then return nil, CH.ERR.RELAY_OFF end

    local contract = Storage.readContract(Util.toId(contractId) or '')
    if not contract then return {} end
    -- Closed with its contract, like the threads themselves.
    if CH.TERMINAL[contract.state] then return {} end

    if contract.creator_cid == actor.cid then
        local hitmen = Storage.readHitmen(contract.id)
        local out = {}
        for i = 1, #hitmen do
            local h = hitmen[i]
            if h.state == 'active' then
                out[#out + 1] = {
                    handle = handleFor(actor.cid, contract.id, h.hitman_cid),
                    alias  = h.alias,
                    -- A hitman's real name appears only when they chose to
                    -- be seen; their citizen id never appears at all.
                    name   = (not h.anon) and h.hitman_name or nil,
                }
            end
        end
        return out
    end

    local hitman = Storage.readHitman(contract.id, actor.cid)
    if hitman and hitman.state == 'active' then
        return { { handle = handleFor(actor.cid, contract.id, actor.cid), alias = PLACER_ALIAS } }
    end

    return {}
end

--- Request a masked voice call. Refuses rather than degrading: a call that
--- would reveal a number an anonymous participant paid to hide is not placed
--- at all (§11.3).
---@return boolean ok
---@return string|nil err
function Comms.requestCall(actor, contractId, threadHandle)
    -- Calls are part of the relay. With the relay switched off they used to
    -- be placed anyway: only AllowMaskedCalls was read here, so a server
    -- owner who turned messaging off still had players' phones ringing.
    if not Config.Relay.Enabled then return false, CH.ERR.RELAY_OFF end
    if not Config.Relay.AllowMaskedCalls then return false, CH.ERR.CALLS_OFF end

    local ctx, err = Comms.context(actor, contractId, threadHandle)
    if not ctx then return false, err end

    -- Both parties' choices, not only the callee's. The call is placed from
    -- the caller's phone, so the number a callee would see is the CALLER's:
    -- asking for masking only when the other side was anonymous meant an
    -- anonymous creator ringing a named operative did so with caller id on,
    -- handing over the number they had paid to hide.
    local otherAnon, selfAnon
    local hitman = Storage.readHitman(ctx.contract.id, ctx.hitmanCid)
    if ctx.role == 'creator' then
        otherAnon = hitman and hitman.anon
        selfAnon = ctx.contract.anon_creator
    else
        otherAnon = ctx.contract.anon_creator
        selfAnon = hitman and hitman.anon
    end
    otherAnon, selfAnon = otherAnon == true, selfAnon == true

    if otherAnon and not Comms.maskingAvailable() then
        return false, CH.ERR.CALL_UNMASKED
    end

    local recipient = ctx.role == 'creator' and ctx.hitmanCid or ctx.contract.creator_cid

    -- Place the call for real when this phone build can, rather than only
    -- telling the other party somebody wants to talk. Whether it can is
    -- probed once, not assumed (Comms.callPlacer).
    --
    -- An anonymous caller on a phone that cannot mask is not refused: the
    -- other party is asked to call back instead, which reveals nothing, and
    -- placeCall declines to dial for exactly that case.
    --
    -- Never a live call TO an anonymous party. A call rings only if they are
    -- in the city, so the caller learned whether they were — the one thing
    -- an anonymous client's contract is built never to answer (§14.32), and
    -- for an anonymous operative the same thing set beside who is online.
    -- They are asked to call back instead, which reads the same either way;
    -- calling back is theirs to choose, and is placed masked.
    local placed = false
    if not otherAnon then
        placed = Comms.placeCall(actor, recipient, selfAnon, ctx.alias)
    end

    -- Why it was not placed, so the page can say what is true rather than
    -- one "they will call you back" for every case. Decided from settings
    -- and from who chose anonymity, never from whether the other party is
    -- here — except for a named party, whose presence a ringing phone
    -- would tell anyone anyway.
    local reason
    if not placed then
        if otherAnon and selfAnon then
            -- Neither side can be rung, so there is no call back to ask
            -- for: telling them somebody wants to talk would send them to a
            -- Call button that can only do the same.
            reason = 'both_anonymous'
        elseif not Comms.callPlacer() then
            reason = 'no_calls'
        elseif otherAnon then
            reason = 'callback'
        else
            reason = 'not_placed'
        end
    end

    if reason ~= 'both_anonymous' then
        -- The person who placed it is named as that, with what "it" is: a
        -- hitman told "Client is calling you" did not know who that was.
        local caller = ctx.role == 'creator'
            and 'The person who placed a contract you took' or ctx.alias
        local told = Notify.toCitizen(recipient,
            placed and 'Incoming call' or 'Call request',
            placed
                and ('%s is calling you about %s.'):format(caller,
                    ctx.role == 'creator' and 'it' or 'a contract')
                or  ('%s wants to speak with you about %s.'):format(caller,
                    ctx.role == 'creator' and 'it' or 'a contract'))

        -- A named party who was not told either: logged off, or past their
        -- notice budget. The page said "they have been told you want to
        -- talk" all the same. Their presence is no secret (above), so this
        -- says only what a ringing phone would have. Never for an anonymous
        -- party, whose "asked to call you back" must read the same either
        -- way.
        if reason and not otherAnon and not told then
            reason = 'unreachable'
        end

        Audit.action(placed and 'call_placed' or 'call_requested', actor.cid, contractId,
            { anonymous = otherAnon or selfAnon })
    end

    -- The caller is told which of the two happened, so the app can say
    -- "calling" or "they have been asked to call you" rather than implying
    -- a call is ringing when none is.
    return true, nil, { placed = placed, reason = reason }
end

--- Hang up the caller's own call.
---
--- lb-phone's CreateCall is built for payphones: it starts a call the
--- phone draws no call screen for, so a player who placed one from here had
--- no way to end it but to wait for the other side to. It names no
--- contract, because a contract that closes mid-call must not leave the
--- caller unable to put the phone down, and it can only end the caller's
--- own call.
---@return boolean ok
---@return string|nil err
---@return table|nil result { ended = boolean }
function Comms.endCall(actor)
    if not Config.Relay.Enabled then return false, CH.ERR.RELAY_OFF end
    if not Config.Relay.AllowMaskedCalls then return false, CH.ERR.CALLS_OFF end

    local ok, inCall = pcall(function()
        return exports['lb-phone']:IsInCall(actor.source)
    end)
    -- Already over — the other side hung up or never answered — is not an
    -- error, and the page says so rather than claiming it ended anything.
    -- A build that cannot say is still asked to end it, rather than the
    -- button doing nothing.
    if ok and not inCall then return true, nil, { ended = false } end

    local ended = pcall(function()
        exports['lb-phone']:EndCall(actor.source)
    end)
    return true, nil, { ended = ended }
end

--------------------------------------------------------------------------
-- Placing a call
--------------------------------------------------------------------------

--- How this server places a call, resolved once and remembered: a
--- function (actor, number, anonymous, alias) -> placed. `false` means
--- probed and not available, distinct from `nil` for not yet probed — a
--- phone without the export must not be re-probed per call.
---
--- What is remembered is which export to use, never the export itself.
--- FiveM's export proxy keeps the resource's callback in a cache it empties
--- when that resource stops, and only indexing the export again refills it:
--- a function kept from the first probe threw on every call after lb-phone
--- restarted, while the Call button stayed drawn, until this resource did.
local callPlacer = nil

--- Resolve an export to a function, or nil. lb-phone ships its server code
--- escrowed, so whether an export exists is probed, never assumed: indexing
--- a missing one throws in FiveM, and an invented name would be a call that
--- silently does nothing.
local function resolveExport(resource, name)
    if GetResourceState(resource) ~= 'started' then return nil end
    local ok, fn = pcall(function() return exports[resource][name] end)
    if not ok or type(fn) ~= 'function' then return nil end
    return fn
end

--- An owner's own export, named in Config.Relay.CallExport and called as
--- (callerSource, number, anonymous). Many exports return nothing at all,
--- so only an explicit false counts as a refusal here.
local function overridePlacer(resource, name)
    return function(actor, number, anonymous)
        local fn = resolveExport(resource, name)
        if not fn then return false end
        local ok, result = pcall(fn, nil, actor.source, number, anonymous == true)
        return ok and result ~= false
    end
end

--- lb-phone's own documented export:
---   CreateCall(caller, calleeNumber, options) -> callId, or nil on failure
--- The caller table's phoneNumber is what the callee's phone shows, so the
--- caller's alias goes there and their real number is never read at all
--- (§11.3: the alias is the caller name). The callId is the only proof a
--- call started: nil is a call that did not, however quietly it failed.
local function lbPhonePlacer()
    return function(actor, number, anonymous, alias)
        local createCall = resolveExport('lb-phone', 'CreateCall')
        if not createCall then return false end
        local ok, callId = pcall(createCall, nil,
            { source = actor.source, phoneNumber = alias or 'Unknown' },
            number,
            { requirePhone = true, hideNumber = anonymous == true })
        return ok and callId ~= nil and callId ~= false
    end
end

local function findPlacer()
    -- An owner's override wins outright. One that does not resolve leaves
    -- calls as requests rather than quietly using an export they chose not
    -- to.
    local spec = Config.Relay.CallExport
    if spec and spec.resource and spec.export then
        if not resolveExport(spec.resource, spec.export) then
            if GetResourceState(spec.resource) == 'started' then
                Log.problem(('warning: Relay.CallExport names %s:%s, which this build ' ..
                       'does not export; call requests will be notifications only')
                       :format(spec.resource, spec.export))
            end
            return nil
        end
        return overridePlacer(spec.resource, spec.export)
    end

    return resolveExport('lb-phone', 'CreateCall') and lbPhonePlacer() or nil
end

--- Whether this server can place a call at all, and how.
---
--- With nothing that resolves, call requests stay notifications and the
--- app does not draw a Call button that can only ask.
---@return function|nil
function Comms.callPlacer()
    if callPlacer == nil then callPlacer = findPlacer() or false end
    return callPlacer or nil
end

function Comms.resetCallCache()
    callPlacer = nil
end

--- Whether the app should offer a call at all.
function Comms.canCall()
    return Config.Relay.Enabled == true and Config.Relay.AllowMaskedCalls == true
        and Comms.callPlacer() ~= nil
end

--- Ring the other party's phone.
---
--- Refuses rather than degrading when the callee is anonymous and identity
--- cannot be suppressed: a call that reveals a number somebody paid to hide
--- is not a call worth placing (§11.3).
---@return boolean placed
function Comms.placeCall(actor, recipientCid, anonymous, alias)
    local placer = Comms.callPlacer()
    if not placer then return false end

    if anonymous and Config.Relay.RequireMaskingForAnonymous
        and not Comms.maskingAvailable() then
        return false
    end

    local recipient = Identity.byCitizenId(recipientCid)
    if not recipient then return false end

    -- The callee's number, read server-side. Never from a payload, and
    -- never handed back to the caller: the caller's phone is told to dial,
    -- it is not told what it dialled.
    local ok, number = pcall(function()
        return exports['lb-phone']:GetEquippedPhoneNumber(recipient.source)
    end)
    if not ok or type(number) ~= 'string' or number == '' then return false end

    -- A pcall that merely did not throw is not proof the call was placed;
    -- each placer decides what its export's answer means.
    return placer(actor, number, anonymous == true, alias) == true
end

--- Whether this lb-phone build can suppress caller identity. Asked once
--- lb-phone is running and cached; when it cannot, masked calls stay
--- disabled. Asked again when lb-phone starts (bridges.lua).
---
--- Never cached while lb-phone is not started. Its GetConfig throws then,
--- and that answer, kept, refused every anonymous call until this resource
--- restarted, whatever lb-phone did meanwhile.
local maskingChecked, maskingOk = false, false
function Comms.maskingAvailable()
    if maskingChecked then return maskingOk end
    if GetResourceState('lb-phone') ~= 'started' then return false end
    maskingChecked = true
    local ok, result = pcall(function()
        local config = exports['lb-phone']:GetConfig()
        return type(config) == 'table' and config.AnonymousCalls ~= false
    end)
    maskingOk = ok and result == true
    return maskingOk
end

function Comms.resetMaskingCache()
    maskingChecked, maskingOk = false, false
end

return Comms
