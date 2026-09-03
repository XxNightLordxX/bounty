--- Masked relay between creator and hunters (§11).
---
--- Messages are relayed server-side and rendered under a per-contract alias.
--- No phone number, character name, citizen id or source ever crosses to the
--- other participant; anonymity is enforced by what is *not* in the payload.

local Util = require_shared('util')

local Comms = {}

local Storage, Identity, Audit, Notify, RateLimit

function Comms.init(deps)
    Storage, Identity, Audit, Notify, RateLimit =
        deps.storage, deps.identity, deps.audit, deps.notify, deps.ratelimit
end

--- A thread is one creator-hunter pair. In competitive mode the creator has
--- a separate thread per hunter, and hunters never see each other.
local function threadId(contractId, hunterCid)
    return contractId .. '|' .. hunterCid
end

--- Resolve the caller's role and thread, or refuse.
---@return table|nil ctx { contract, role, hunterCid, threadId, alias }
---@return string|nil err
function Comms.context(actor, contractId, hunterCid)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CB.ERR.NOT_FOUND end

    if contract.creator_cid == actor.cid then
        -- The creator must name which hunter's thread they mean.
        local hunter = hunterCid and Storage.readHunter(contractId, hunterCid)
        if not hunter or hunter.state ~= 'active' then return nil, CB.ERR.NOT_PARTICIPANT end
        return {
            contract = contract, role = 'creator', hunterCid = hunter.hunter_cid,
            threadId = threadId(contractId, hunter.hunter_cid), alias = 'Client',
        }
    end

    local hunter = Storage.readHunter(contractId, actor.cid)
    if hunter and hunter.state == 'active' then
        return {
            contract = contract, role = 'hunter', hunterCid = actor.cid,
            threadId = threadId(contractId, actor.cid), alias = hunter.alias,
        }
    end

    return nil, CB.ERR.NOT_PARTICIPANT
end

--- Send a message into a contract thread.
---@return boolean ok
---@return string|nil err
function Comms.send(actor, contractId, hunterCid, rawBody)
    if not Config.Relay.Enabled then return false, CB.ERR.BAD_STATE end

    local ctx, err = Comms.context(actor, contractId, hunterCid)
    if not ctx then return false, err end

    if not RateLimit.check(actor.cid, 'message') then return false, CB.ERR.RATE_LIMITED end

    local body = Util.sanitizeText(rawBody, Config.Relay.MaxLength)
    if not body then return false, CB.ERR.INVALID_INPUT end

    if exports['lb-phone']:ContainsBlacklistedWord(actor.source, body) then
        Audit.rejected('relay_blacklisted_word', actor.cid, contractId, {})
        return false, CB.ERR.INVALID_INPUT
    end

    Storage.writeMessage({
        contract_id = contractId,
        thread_id   = ctx.threadId,
        from_cid    = actor.cid,     -- server-side only, for the audit trail
        from_alias  = ctx.alias,     -- the only identity the other side sees
        body        = body,
        sent_at     = os.time(),
    })

    local recipient = ctx.role == 'creator' and ctx.hunterCid or ctx.contract.creator_cid
    Notify.toCitizen(recipient, 'Contract message', ('%s: %s'):format(ctx.alias, body))

    Audit.action('relay_message', actor.cid, contractId, { role = ctx.role })
    return true
end

--- Read a thread. Returns only alias-attributed messages: the caller cannot
--- learn who the other party is from what comes back.
---@return table[]|nil messages
---@return string|nil err
function Comms.read(actor, contractId, hunterCid)
    local ctx, err = Comms.context(actor, contractId, hunterCid)
    if not ctx then return nil, err end

    local rows = Storage.readMessages(contractId, ctx.threadId)
    local out = {}
    for i = 1, #rows do
        out[#out + 1] = {
            alias = rows[i].from_alias,
            body  = rows[i].body,
            at    = rows[i].sent_at,
            mine  = rows[i].from_cid == actor.cid,
        }
    end
    return out
end

--- Threads visible to the caller, for the app's inbox.
function Comms.threads(actor, contractId)
    local contract = Storage.readContract(Util.toId(contractId) or '')
    if not contract then return {} end

    if contract.creator_cid == actor.cid then
        local hunters = Storage.readHunters(contract.id)
        local out = {}
        for i = 1, #hunters do
            if hunters[i].state == 'active' then
                out[#out + 1] = {
                    hunterCid = hunters[i].hunter_cid,   -- opaque handle for the next call
                    alias     = hunters[i].alias,
                }
            end
        end
        return out
    end

    local hunter = Storage.readHunter(contract.id, actor.cid)
    if hunter and hunter.state == 'active' then
        return { { hunterCid = actor.cid, alias = 'Client' } }
    end

    return {}
end

--- Request a masked voice call. Refuses rather than degrading: a call that
--- would reveal a number an anonymous participant paid to hide is not placed
--- at all (§11.3).
---@return boolean ok
---@return string|nil err
function Comms.requestCall(actor, contractId, hunterCid)
    if not Config.Relay.AllowMaskedCalls then return false, CB.ERR.BAD_STATE end

    local ctx, err = Comms.context(actor, contractId, hunterCid)
    if not ctx then return false, err end

    local otherAnon
    if ctx.role == 'creator' then
        local hunter = Storage.readHunter(contractId, ctx.hunterCid)
        otherAnon = hunter and hunter.anon
    else
        otherAnon = ctx.contract.anon_creator
    end

    if otherAnon and not Comms.maskingAvailable() then
        return false, CB.ERR.BAD_STATE
    end

    local recipient = ctx.role == 'creator' and ctx.hunterCid or ctx.contract.creator_cid
    Notify.toCitizen(recipient, 'Call request',
        ('%s wants to speak with you about a contract.'):format(ctx.alias))

    Audit.action('call_requested', actor.cid, contractId, {})
    return true
end

--- Whether this lb-phone build can suppress caller identity. Checked once at
--- boot and cached; when it cannot, masked calls stay disabled.
local maskingChecked, maskingOk = false, false
function Comms.maskingAvailable()
    if maskingChecked then return maskingOk end
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
