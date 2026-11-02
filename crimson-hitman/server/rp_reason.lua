--- Reason quality (Config.Roleplay.ReasonQuality, README, Optional
--- features). Off as shipped, and off it changes nothing.
---
--- On, a free-text reason (Config.Reason.Mode 'freetext') must be at least
--- MinLength characters and MinWords words, on top of every existing reason
--- rule (Contracts.reasonFor runs those first, then this). A reason holding a
--- phrase from LowEffort, as whole words and in any case, is refused, or,
--- with LowEffortAction 'review', placed all the same and put in the staff
--- review queue as 'low-effort reason' with its contract. Wherever a reason
--- is set: placing, Edit, and an agreed change of reason. A refusal answers
--- reason_refused with the rule ('short', 'words', 'low_effort'), before
--- anything is taken.

local Util = CrimsonBoot.requireShared('util')
local Places = CrimsonBoot.require('server.rp_places')

local Reason = {}

local deps

function Reason.on()
    return Places.on('ReasonQuality')
end

local function rules()
    return Places.block('ReasonQuality')
end

--- The reason as words: lower case, anything but letters and digits a gap.
local function words(text)
    local out = {}
    for word in text:lower():gsub('[^%w]+', ' '):gmatch('%S+') do out[#out + 1] = word end
    return out
end

--- The LowEffort phrase a reason holds, as whole words, or nil.
---@param text string
---@return string|nil
function Reason.lowEffort(text)
    local padded = ' ' .. table.concat(words(text), ' ') .. ' '
    for _, phrase in ipairs(type(rules().LowEffort) == 'table' and rules().LowEffort or {}) do
        local wanted = table.concat(words(tostring(phrase)), ' ')
        if wanted ~= '' and padded:find(' ' .. wanted .. ' ', 1, true) then return tostring(phrase) end
    end
    return nil
end

--- Run on a free-text reason that passed every other rule
--- (Contracts.reasonQuality).
---@param reason string
---@return string|nil err
---@return table|nil refusal { rule }
function Reason.check(reason)
    if not Reason.on() or type(reason) ~= 'string' then return nil end
    if utf8.len(reason) < (tonumber(rules().MinLength) or 0) then
        return CH.ERR.REASON_REFUSED, { rule = 'short', min = rules().MinLength }
    end
    if #words(reason) < (tonumber(rules().MinWords) or 0) then
        return CH.ERR.REASON_REFUSED, { rule = 'words', min = rules().MinWords }
    end
    if rules().LowEffortAction ~= 'review' and Reason.lowEffort(reason) then
        return CH.ERR.REASON_REFUSED, { rule = 'low_effort' }
    end
    return nil
end

--- After a placing or an Edit went through: a low-effort reason let
--- through under 'review' goes to the staff review queue, once per contract
--- and wording. Nothing in it but the contract, its placer (shown to staff
--- without the identity ACE by their role only) and the phrase it matched.
local queued = {}
function Reason.after(name, actor, payload, result)
    if (name ~= 'create' and name ~= 'revise') or not Reason.on() then return end
    if rules().LowEffortAction ~= 'review' or Config.Reason.Mode ~= 'freetext' then return end
    local id = name == 'create' and type(result) == 'table' and result.id or payload.id
    local contract = id and deps.storage.readContract(Util.toId(id))
    if not contract or type(contract.reason) ~= 'string' then return end
    local matched = Reason.lowEffort(contract.reason)
    if not matched then return end
    local key = contract.id .. '\0' .. contract.reason
    if queued[key] then return end
    queued[key] = true
    deps.review.open({
        kind = 'low_effort_reason', contract_id = contract.id,
        cids = { creator = contract.creator_cid },
        known = { matched = matched, request = name },
    })
end

function Reason.init(d)
    deps = d
    -- Contracts.reasonFor asks this after its own rules, wherever a reason
    -- is set.
    if deps.contracts then deps.contracts.reasonQuality = Reason.check end
end

Reason.RULES = {
    Enabled = { kind = 'switch', default = false },
    MinLength = { kind = 'number', min = 0, max = 255, integer = true, default = 15 },
    MinWords = { kind = 'number', min = 0, max = 50, integer = true, default = 3 },
    LowEffort = { kind = 'phrases', default = {} },
    LowEffortAction = { kind = 'choice', choices = { 'refuse', 'review' }, default = 'refuse' },
}

---@param warn string[]
function Reason.validate(warn)
    Places.checkBlock('ReasonQuality', Reason.RULES, warn)
    -- A least length over the most a reason may be refuses every reason.
    local block = Config.Roleplay.ReasonQuality
    local most = Config.Reason and tonumber(Config.Reason.MaxLength)
    if most and block.MinLength > most then
        warn[#warn + 1] = ('Roleplay.ReasonQuality.MinLength is %d, above Reason.MaxLength (%d): no '
            .. 'reason could be given. Using %d.'):format(block.MinLength, most, most)
        block.MinLength = math.floor(most)
    end
end

return Reason
