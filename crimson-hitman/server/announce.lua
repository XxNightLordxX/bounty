CrimsonBoot.define('server.announce', function() --- A notice from staff to every hitman (Staff actions > Announce).
---
--- One phone notice, the same words to everybody, to every player in the
--- city holding a contract (an active operative on a live one), or, chosen
--- so, to every player online the app is open to. It comes from 'Staff':
--- the notice never names the staff member who sent it, and nothing a
--- player is sent says who did. The text is held to the rules a contract's
--- reason is: at most Announce.MAX characters (refused, never cut), and
--- none of Config.Reason.PatternDenylist (links, invites, handles). Each
--- one is on the record (staff_announce) with who sent it, to whom, how
--- many it reached and what it said.

local Util = CrimsonBoot.requireShared('util')
--- The words players and staff read (locales/en.lua, Config.Locale).
local L = CrimsonBoot.requireShared('locale').t

local Announce = {}

--- The most characters a notice may hold.
Announce.MAX = 200
--- Who it goes to.
Announce.SCOPES = { active = true, online = true }
--- What players see it as from.
Announce.TITLE = L('announce.staff')

local deps

---@param d table { storage, notify, audit, identity }
function Announce.init(d)
    deps = d
end

--- The text as it is sent, or nil and why: 'empty' | 'length' | 'pattern'.
---@param raw any
---@return string|nil text
---@return string|nil why
function Announce.check(raw)
    if type(raw) ~= 'string' then return nil, 'empty' end
    -- One over the limit kept, so too long is told from one that fits.
    local text = Util.sanitizeText(raw, Announce.MAX + 1)
    if not text then return nil, 'empty' end
    if utf8.len(text) > Announce.MAX then return nil, 'length' end
    local lowered = text:lower()
    for _, pattern in ipairs(type(Config.Reason) == 'table' and Config.Reason.PatternDenylist or {}) do
        local ok, found = pcall(string.find, lowered, pattern)
        if ok and found then return nil, 'pattern' end
    end
    return text
end

--- Every citizen id the notice goes to, each once, all in the city.
---@param scope string 'active' | 'online'
---@return string[]
function Announce.recipients(scope)
    local out, seen = {}, {}
    local function add(cid)
        if cid and not seen[cid] then
            seen[cid] = true
            out[#out + 1] = cid
        end
    end
    if scope == 'online' then
        for _, actor in ipairs(deps.identity.online() or {}) do
            if not deps.identity.isBarred(actor) then add(actor.cid) end
        end
    else
        for _, list in pairs(deps.storage.liveHitmen() or {}) do
            for _, hitman in ipairs(list) do
                if hitman.state == 'active' and deps.identity.byCitizenId(hitman.hitman_cid) then
                    add(hitman.hitman_cid)
                end
            end
        end
    end
    table.sort(out)
    return out
end

--- Send it.
---@param staffCid string|nil who sent it, for the record only
---@param raw any the text
---@param scope any 'active' (the default) | 'online'
---@return boolean ok
---@return string|nil err CH.ERR.INVALID_INPUT | 'text_refused'
---@return table detail { sent, scope } or { rule }
function Announce.send(staffCid, raw, scope)
    scope = scope == nil and 'active' or scope
    if not Announce.SCOPES[scope] then return false, CH.ERR.INVALID_INPUT, {} end
    local text, why = Announce.check(raw)
    if not text then return false, 'text_refused', { rule = why } end
    local sent = 0
    for _, cid in ipairs(Announce.recipients(scope)) do
        if deps.notify.toCitizen(cid, Announce.TITLE, text, { bypassBudget = true }) then
            sent = sent + 1
        end
    end
    deps.audit.staff('staff_announce', staffCid, nil, { scope = scope, sent = sent, text = text })
    return true, nil, { sent = sent, scope = scope }
end

return Announce
end)
