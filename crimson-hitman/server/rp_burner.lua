--- The burner phone (Config.Roleplay.BurnerPhone, README, Optional
--- features). Off as shipped, and off it changes nothing.
---
--- On, every contract action in the app needs the item (Item, an
--- ox_inventory item, 'burner_phone' as shipped) in the player's inventory,
--- counted on the server with ox_inventory's GetItemCount: placing and
--- accepting, and whatever a placer or a hitman then does with a contract.
--- With RequireToOpen on (as shipped) the Board and the placer's and
--- hitman's halves of Mine are not even sent without one; the target's On
--- me always is. Live contracts stay as they are when the item goes (police
--- seized it, somebody robbed them): only the actions wait for a new one.
---
--- ConsumeOnPlace / ConsumeOnAccept use one up after the action went
--- through, never before, so a refusal costs nothing. An item that could not
--- be taken (ox_inventory raised or said no) is audited and the action
--- stands. With ox_inventory not started the feature does nothing at all.

local Feature = CrimsonBoot.require('server.lib.feature')

--- This feature's block of config (server/lib/feature.lua reads and checks it).
local BLOCK = 'Roleplay.BurnerPhone'
local Bridge = CrimsonBoot.require('server.lib.bridge')

local Burner = {}

local deps

function Burner.init(d)
    deps = d
end

--- The app's requests that are contract actions: refused without the item.
--- Not the target's (their buyout, their informant, and hiring, cancelling
--- or moving the pin of a bodyguard: server/rp_protection.lua), not the
--- reads. Taking a bodyguard job is: the guard works for hire like a hitman.
Burner.ACTIONS = {
    create = true, accept = true, abandon = true, cancel = true, revise = true,
    withdrawReward = true, addEscrow = true, improve = true, propose = true,
    respondAmendment = true, armKidnap = true, verifyKill = true, requestPhotoToken = true,
    setMeeting = true, clearMeeting = true, locationTip = true, placerInformant = true,
    sendMessage = true, requestCall = true,
    protectionAccept = true,
    -- Handing over a proof item (Config.Improvements.ProofItems): a hitman
    -- action like Verify kill, so it needs the burner too.
    proofItem = true,
    -- The placer turning contract decay off on their contract
    -- (Config.Improvements.ContractDecay): a placer's contract action like
    -- Edit, so it needs the burner too.
    decayOff = true,
}

--- Whether this player carries a burner now: true, false, or nil where it
--- cannot be told (ox_inventory not started, or it raised), which counts as
--- carrying one: the feature then does nothing rather than lock anyone out.
---@param actor table
---@return boolean|nil
function Burner.has(actor)
    if not Bridge.started('ox_inventory') then return nil end
    local item = tostring(Feature.block(BLOCK).Item or 'burner_phone')
    local ok, count = Bridge.call('ox_inventory', 'GetItemCount', actor.source, item)
    if not ok then return nil end
    return (tonumber(count) or 0) >= 1
end

local function missing(actor)
    return Feature.on(BLOCK) and Burner.has(actor) == false
end

---@return string|nil err
function Burner.gate(name, actor)
    if not Burner.ACTIONS[name] or not missing(actor) then return nil end
    deps.audit.rejected('burner_missing', actor.cid, nil, { request = name })
    -- With the item it takes, so the page can name what to get.
    return CH.ERR.NEED_BURNER, { item = Burner.itemName() }
end

--- The ox_inventory item a burner phone is, as configured.
---@return string|nil
function Burner.itemName()
    local item = Feature.block(BLOCK).Item
    return type(item) == 'string' and item ~= '' and item or nil
end

--- The Board and Mine, without the contracts, for a player with no burner
--- while RequireToOpen is on. Said to the page as burnerMissing.
function Burner.shape(name, actor, result)
    if (name ~= 'list' and name ~= 'mine') or type(result) ~= 'table' then return result end
    if not Feature.on(BLOCK) then return result end
    if Feature.block(BLOCK).RequireToOpen ~= true or not missing(actor) then return result end
    if name == 'list' then
        result.contracts, result.page, result.pages = {}, 1, 1
    else
        result.created, result.accepted = {}, {}
    end
    result.burnerMissing = true
    result.burnerItem = Burner.itemName()
    return result
end

--- One used up after a placing or an acceptance, where the settings say so.
function Burner.after(name, actor)
    if not Feature.on(BLOCK) then return end
    local spend = (name == 'create' and Feature.block(BLOCK).ConsumeOnPlace == true)
        or (name == 'accept' and Feature.block(BLOCK).ConsumeOnAccept == true)
    if not spend or not Bridge.started('ox_inventory') then return end
    local item = tostring(Feature.block(BLOCK).Item or 'burner_phone')
    local ok, removed = Bridge.call('ox_inventory', 'RemoveItem', actor.source, item, 1)
    if ok and removed then
        deps.audit.action('burner_used', actor.cid, nil, { request = name, item = item })
    else
        deps.audit.rejected('burner_not_taken', actor.cid, nil, { request = name, item = item })
    end
end

Burner.RULES = {
    Enabled = { kind = 'switch', default = false },
    Item = { kind = 'text', default = 'burner_phone' },
    ConsumeOnPlace = { kind = 'switch', default = false },
    ConsumeOnAccept = { kind = 'switch', default = false },
    RequireToOpen = { kind = 'switch', default = true },
}

---@param warn string[]
function Burner.validate(warn)
    Feature.check(BLOCK, Burner.RULES, warn)
end

return Burner
