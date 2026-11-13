CrimsonBoot.define('server.rp_reason', function() --- Reason quality (Config.Roleplay.ReasonQuality, README, Optional
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
local Feature = CrimsonBoot.require('server.lib.feature')
local L = CrimsonBoot.requireShared('locale').t

--- This feature's block of config (server/lib/feature.lua reads and checks it).
local BLOCK = 'Roleplay.ReasonQuality'

local Reason = {}

local deps

--- Lower case, for the scripts a reason is commonly written in beyond
--- ASCII: Latin-1 letters, Greek and Cyrillic capitals. string.lower knows
--- ASCII alone, so 'ФИГНЯ' never matched a LowEffort 'фигня'. Text that is
--- not valid UTF-8 is lowered as ASCII only.
local function lower(text)
    text = text:lower()
    if not text:find('[\128-\255]') then return text end
    local ok, out = pcall(function()
        local chars = {}
        for _, c in utf8.codes(text) do
            if (c >= 0xC0 and c <= 0xDE and c ~= 0xD7) or (c >= 0x391 and c <= 0x3AB and c ~= 0x3A2)
                or (c >= 0x410 and c <= 0x42F) then
                c = c + 0x20
            elseif c >= 0x400 and c <= 0x40F then
                c = c + 0x50
            end
            chars[#chars + 1] = utf8.char(c)
        end
        return table.concat(chars)
    end)
    return ok and out or text
end

--- The reason as words: lower case, split at spaces and ASCII punctuation.
--- Not at every byte %w does not know: that is every byte of a letter
--- outside ASCII, so a Cyrillic or Greek reason counted no words at all and
--- a Polish one a word at each accented letter.
local function words(text)
    local out = {}
    for word in lower(text):gsub('[%s%p]+', ' '):gmatch('%S+') do out[#out + 1] = word end
    return out
end

--- The LowEffort phrase a reason holds, as whole words, or nil.
---@param text string
---@return string|nil
function Reason.lowEffort(text)
    local padded = ' ' .. table.concat(words(text), ' ') .. ' '
    local phrases = Feature.block(BLOCK).LowEffort
    for _, phrase in ipairs(type(phrases) == 'table' and phrases or {}) do
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
    if not Feature.on(BLOCK) or type(reason) ~= 'string' then return nil end
    if utf8.len(reason) < (tonumber(Feature.block(BLOCK).MinLength) or 0) then
        return CH.ERR.REASON_REFUSED, { rule = 'short', min = Feature.block(BLOCK).MinLength }
    end
    if #words(reason) < (tonumber(Feature.block(BLOCK).MinWords) or 0) then
        return CH.ERR.REASON_REFUSED, { rule = 'words', min = Feature.block(BLOCK).MinWords }
    end
    if Feature.block(BLOCK).LowEffortAction ~= 'review' and Reason.lowEffort(reason) then
        return CH.ERR.REASON_REFUSED, { rule = 'low_effort' }
    end
    return nil
end

--- After a placing or an Edit went through: a low-effort reason let
--- through under 'review' goes to the staff review queue, once per contract
--- and wording. Nothing in it but the contract, its placer (shown to staff
--- without the identity ACE by their role only) and the phrase it matched.
local queued = {}

--- Queue the contract's reason as it stands now, if it is low-effort and
--- let through for review. `request` says what set it: create, revise, or
--- change_reason (an agreed change, server/amendments.lua).
---@param contractId string|nil
---@param request string
function Reason.queue(contractId, request)
    if not Feature.on(BLOCK) then return end
    if Feature.block(BLOCK).LowEffortAction ~= 'review' or Config.Reason.Mode ~= 'freetext' then return end
    local contract = contractId and deps.storage.readContract(Util.toId(contractId))
    if not contract or type(contract.reason) ~= 'string' then return end
    local matched = Reason.lowEffort(contract.reason)
    if not matched then return end
    local key = contract.id .. '\0' .. contract.reason
    if queued[key] then return end
    queued[key] = true
    deps.review.open({
        kind = 'low_effort_reason', contract_id = contract.id,
        cids = { creator = contract.creator_cid },
        known = { matched = matched, request = request },
    })
end

function Reason.after(name, actor, payload, result)
    if name ~= 'create' and name ~= 'revise' then return end
    local id = name == 'create' and type(result) == 'table' and result.id or payload.id
    Reason.queue(id, name)
end

function Reason.init(d)
    deps = d
    -- Contracts.reasonFor asks this after its own rules, wherever a reason
    -- is set.
    if deps.contracts then
        deps.contracts.reasonQuality = Reason.check
        -- And amendments.lua asks this once an agreed change of reason is set.
        deps.contracts.reasonSet = Reason.queue
    end
end

Reason.RULES = {
    Enabled = { kind = 'switch', default = false },
    MinLength = { kind = 'number', min = 0, max = 255, integer = true, default = 15 },
    MinWords = { kind = 'number', min = 0, max = 50, integer = true, default = 3 },
    LowEffort = { kind = 'list', default = {} },
    LowEffortAction = { kind = 'choice', choices = { 'refuse', 'review' }, default = 'refuse' },
}

---@param warn string[]
function Reason.validate(warn)
    Feature.check(BLOCK, Reason.RULES, warn)
    -- A least length over the most a reason may be refuses every reason.
    local block = Config.Roleplay.ReasonQuality
    local most = Config.Reason and tonumber(Config.Reason.MaxLength)
    if most and block.MinLength > most then
        -- %s, not %d: a MaxLength of 0.5 or math.huge raised here.
        local shown = (most == math.floor(most) and most == most and math.abs(most) < 2^53)
            and ('%d'):format(most) or tostring(most)
        warn[#warn + 1] = (L('rp_reason.roleplay_reasonquality_minlength_is_above_reason'))
            :format(tostring(block.MinLength), shown, shown)
        block.MinLength = math.floor(most)
    end
end

return Reason
end)
