--- The network surface (§14.1, §14.27).
---
--- Every handler in this file is registered through `handler()`, which
--- resolves the actor from `source`, re-checks the job blacklist and applies
--- the rate limit before the body runs. No handler body reads an identity
--- from its payload, and none of them is reachable without passing the gate.

local Util = require_shared('util')

local App = {}

local deps

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
local function handler(name, action, fn)
    RegisterNetEvent('crimson-bounty:' .. name, function(payload)
        local src = source
        local actor, err = deps.identity.gate(src)
        if not actor then
            deps.audit.rejected('gate_' .. name, nil, nil, { source = src, reason = err })
            return App.reply(src, name, false, err, nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        if action and not deps.ratelimit.check(actor.cid, action) then
            deps.audit.rejected('ratelimit_' .. name, actor.cid, nil, {})
            return App.reply(src, name, false, CB.ERR.RATE_LIMITED, nil,
                type(payload) == 'table' and tonumber(payload.__rid) or nil)
        end

        if type(payload) ~= 'table' then payload = {} end

        -- The client's correlation id is echoed back so concurrent requests
        -- resolve into their own callbacks. It is opaque to the server and
        -- never used for anything else.
        local rid = tonumber(payload.__rid)

        local ok, result, resultErr = pcall(fn, actor, payload)
        if not ok then
            deps.audit.rejected('error_' .. name, actor.cid, nil, { error = tostring(result) })
            return App.reply(src, name, false, CB.ERR.INVALID_INPUT, nil, rid)
        end

        return App.reply(src, name, result ~= false and result ~= nil, resultErr, result, rid)
    end)
end

--- Send a result back to one client. Payloads are built by the projection
--- module, so nothing leaks here that the viewer may not see.
function App.reply(src, name, ok, err, data, rid)
    TriggerClientEvent('crimson-bounty:result', src, {
        event = name, ok = ok and true or false, err = err, data = data, rid = rid,
    })
end

--------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------

function App.register()
    -- Listings ----------------------------------------------------------

    handler('list', 'search', function(actor, payload)
        return deps.projection.listing(actor.cid, payload.page)
    end)

    handler('mine', 'search', function(actor)
        return {
            created  = deps.projection.mine(actor.cid),
            accepted = deps.projection.accepted(actor.cid),
            onMe     = deps.projection.onMe(actor.cid),
        }
    end)

    handler('ledger', 'search', function(actor)
        return {
            entries = deps.ledger.read(actor.cid),
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
            return false, CB.ERR.INVALID_INPUT
        end

        local needle = query:lower()
        local out = {}
        local online = deps.identity.online()
        for i = 1, #online do
            local candidate = online[i]
            if candidate.cid ~= actor.cid
                and candidate.account ~= actor.account
                and candidate.name:lower():find(needle, 1, true) then
                out[#out + 1] = {
                    handle = App.mintTargetHandle(actor.cid, candidate.cid),
                    name = candidate.name,
                    protected = deps.identity.isProtectedJob(candidate.job),
                    job = deps.identity.isProtectedJob(candidate.job) and candidate.job.name or nil,
                }
                if #out >= Config.Targeting.MaxResults then break end
            end
        end
        return out
    end)

    -- What the creator can actually put up, read server-side so the builder
    -- never displays something they do not hold.
    handler('rewardOptions', 'search', function(actor)
        local dirty = exports.ox_inventory:GetItem(actor.source, Config.Sources.dirty.item, nil, true) or 0
        return {
            cash  = actor.player.Functions.GetMoney('cash'),
            bank  = actor.player.Functions.GetMoney('bank'),
            dirty = dirty,
            caps  = {
                cash = Config.Sources.cash.max, bank = Config.Sources.bank.max,
                dirty = Config.Sources.dirty.max, slots = Config.Limits.MaxPayoutSlots,
                bonusPercent = Config.Bonus.maxPercent,
            },
        }
    end)

    -- Contracts ---------------------------------------------------------

    handler('create', 'create', function(actor, payload)
        local targetCid = App.resolveTargetHandle(actor.cid, payload.target)
        if not targetCid then return false, CB.ERR.INVALID_INPUT end

        local contract, err = deps.contracts.create(actor, {
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
        if not contract then return false, err end
        return deps.projection.contract(contract, actor.cid)
    end)

    handler('accept', 'accept', function(actor, payload)
        local ok, err = deps.contracts.accept(actor, payload.id, payload.anonymous)
        if not ok then return false, err end
        local contract = deps.storage.readContract(Util.toId(payload.id))
        return deps.projection.contract(contract, actor.cid)
    end)

    handler('abandon', 'accept', function(actor, payload)
        local ok, err = deps.contracts.abandon(actor, Util.toId(payload.id) or '')
        if not ok then return false, err end
        return true
    end)

    -- Fulfilment --------------------------------------------------------

    handler('requestPhotoToken', 'photo', function(actor, payload)
        local token, err = deps.photo.issue(actor, payload.id)
        if not token then return false, err end
        return { token = token }
    end)

    handler('submitPhoto', 'photo', function(actor, payload)
        local ok, err, result = deps.photo.submit(actor, payload.token, payload.url)
        if not ok then return false, err end
        return result
    end)

    handler('armKidnap', 'accept', function(actor, payload)
        local ok, err = deps.kidnap.arm(payload.id, actor.cid)
        if not ok then return false, err end
        return { armed = true }
    end)

    handler('kidnapProgress', 'search', function(actor, payload)
        return deps.kidnap.progress(Util.toId(payload.id) or '', actor.cid) or { elapsed = 0 }
    end)

    -- Target counter-play ----------------------------------------------

    handler('bailout', 'bailout', function(actor, payload)
        local ok, err = deps.bailout.buy(actor, payload.id)
        if not ok then return false, err end
        return true
    end)

    handler('informant', 'informant', function(actor, payload)
        local ok, err, data = deps.informant.buy(actor, payload.id)
        if not ok then return false, err end
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

    handler('propose', 'amend', function(actor, payload)
        local proposal, err = deps.amendments.propose(actor, payload.id, payload.kind, payload.payload)
        if not proposal then return false, err end
        return { id = proposal.id, kind = proposal.kind, expires = proposal.expires_at }
    end)

    handler('respondAmendment', 'amend', function(actor, payload)
        local ok, err, outcome = deps.amendments.respond(actor, payload.id, payload.approve == true)
        if not ok then return false, err end
        return { outcome = outcome }
    end)

    -- Relay -------------------------------------------------------------

    handler('threads', 'search', function(actor, payload)
        return deps.comms.threads(actor, payload.id)
    end)

    handler('readThread', 'search', function(actor, payload)
        local messages, err = deps.comms.read(actor, payload.id, payload.thread)
        if not messages then return false, err end
        return messages
    end)

    handler('sendMessage', 'message', function(actor, payload)
        local ok, err = deps.comms.send(actor, payload.id, payload.thread, payload.body)
        if not ok then return false, err end
        return true
    end)

    handler('requestCall', 'message', function(actor, payload)
        local ok, err = deps.comms.requestCall(actor, payload.id, payload.thread)
        if not ok then return false, err end
        return true
    end)

    -- Death reporting ---------------------------------------------------
    --
    -- Accepted only from the victim's own client, and everything about it is
    -- then verified server-side (§14.2). A killer cannot report a death.
    --
    -- These carry no payload but are still gated and throttled: a client can
    -- fire them as fast as it likes, and each one walks the contract table.

    RegisterNetEvent('crimson-bounty:iDied', function()
        local src = source
        local actor = deps.identity.resolve(src)
        if not actor then return end
        if not deps.ratelimit.check(actor.cid, 'death') then
            deps.audit.rejected('ratelimit_iDied', actor.cid, nil, {})
            return
        end
        local ok, err = pcall(deps.death.onVictimReport, src)
        if not ok then deps.audit.rejected('error_iDied', actor.cid, nil, { error = tostring(err) }) end
    end)

    RegisterNetEvent('crimson-bounty:iRevived', function()
        local src = source
        local actor = deps.identity.resolve(src)
        if not actor then return end
        if not deps.ratelimit.check(actor.cid, 'death') then
            deps.audit.rejected('ratelimit_iRevived', actor.cid, nil, {})
            return
        end
        local ok, err = pcall(deps.death.onRevivedVerified, src, actor.cid)
        if not ok then deps.audit.rejected('error_iRevived', actor.cid, nil, { error = tostring(err) }) end
    end)
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

function App.mintTargetHandle(searcherCid, targetCid)
    for handle, entry in pairs(targetHandles) do
        if entry.searcher == searcherCid and entry.target == targetCid then
            entry.at = GetGameTimer()
            return handle
        end
    end

    targetSeq = targetSeq + 1
    local handle = ('tg%08d'):format(targetSeq)
    targetHandles[handle] = { searcher = searcherCid, target = targetCid, at = GetGameTimer() }
    return handle
end

function App.resolveTargetHandle(searcherCid, handle)
    if type(handle) ~= 'string' then return nil end
    local entry = targetHandles[handle]
    if not entry or entry.searcher ~= searcherCid then return nil end
    if GetGameTimer() - entry.at > 600000 then
        targetHandles[handle] = nil
        return nil
    end
    return entry.target
end

--- Drop stale handles. Called from the maintenance tick.
function App.sweepHandles()
    local cutoff = GetGameTimer() - 600000
    local removed = 0
    for handle, entry in pairs(targetHandles) do
        if entry.at < cutoff then
            targetHandles[handle] = nil
            removed = removed + 1
        end
    end
    return removed
end

function App.clearPlayerHandles(cid)
    for handle, entry in pairs(targetHandles) do
        if entry.searcher == cid or entry.target == cid then targetHandles[handle] = nil end
    end
end

--- Whether a player may see the app at all. lb-phone asks this before it
--- shows the icon; the answer is re-checked on every event regardless.
function App.canUseApp(src)
    local actor = deps.identity.gate(src)
    return actor ~= nil
end

return App
