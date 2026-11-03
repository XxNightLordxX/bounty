--- Weapon serial scrubbing (Config.Improvements.SerialScrub, README
--- Optional features). Off as shipped, and off it changes nothing.
---
--- On, a weapon an anonymous placer put up reaches anybody but that placer
--- (the hitman paid with it) with a new random serial in its ox_inventory
--- metadata ('serial'), in ox_inventory's own form (six digits, three
--- letters, six digits), so the gun in the hitman's hands cannot be traced
--- back to the placer by its number. It already goes unregistered
--- (Escrow's handedOver). The stored escrow line is not touched: a refund
--- to the placer is their own weapon exactly as it was put up.
---
--- Each scrub is audited for staff as 'weapon_serial_scrubbed' with the
--- new serial and the original one; the original is shown only to staff
--- with IdentityAce (server/panel.lua IDENTITY_ONLY), since it can name the
--- placer. One line keeps one new serial for as long as the server runs,
--- so a give that is tried again hands over the same number.

local Imp = CrimsonBoot.require('server.imp_staffeco')

local Scrub = {}

local deps

--- [escrow line id] = the serial minted for it.
local minted = {}

function Scrub.init(d)
    deps = d
    minted = {}
end

function Scrub.on()
    return Imp.on('SerialScrub')
end

Scrub.RULES = {
    Enabled = { kind = 'switch', default = false },
}

---@param warn string[]
function Scrub.validate(warn)
    Imp.checkBlock('SerialScrub', Scrub.RULES, warn)
end

--- A serial as ox_inventory makes one (modules/items/server.lua
--- GenerateSerial): six digits, three capital letters but POL or EMS, six
--- digits. Longer than three characters, so ox_inventory keeps it as given.
---@return string
function Scrub.newSerial()
    local letters
    repeat
        letters = string.char(math.random(65, 90), math.random(65, 90), math.random(65, 90))
    until letters ~= 'POL' and letters ~= 'EMS'
    return ('%d%s%d'):format(math.random(100000, 999999), letters, math.random(100000, 999999))
end

--- The metadata a weapon is handed over with, scrubbed where this applies;
--- nil to leave it as Escrow made it. Asked by Escrow's handedOver
--- (Escrow.scrubSerial) for every weapon it gives.
---@param recipientCid string
---@param line table the escrow line
---@param meta table|nil the metadata Escrow would hand over
---@return table|nil
function Scrub.scrub(recipientCid, line, meta)
    if not Scrub.on() then return nil end
    if type(line) ~= 'table' or line.source ~= CH.SOURCE.WEAPON then return nil end
    if type(meta) ~= 'table' or type(meta.serial) ~= 'string' or meta.serial == '' then return nil end
    if line.taken_from ~= nil and line.taken_from == recipientCid then return nil end
    local read, contract = pcall(function()
        return line.contract_id and deps.storage.readContract(line.contract_id) or nil
    end)
    -- Only an anonymous placer's weapon, and never back to them. A contract
    -- that cannot be read is treated as anonymous, as Escrow's unregistered
    -- treats it: a weapon is never handed over traceable for want of a read.
    if read and contract and (contract.anon_creator ~= true or contract.creator_cid == recipientCid) then
        return nil
    end
    local serial = line.id and minted[line.id]
    local fresh = serial == nil
    if fresh then
        serial = Scrub.newSerial()
        if line.id then minted[line.id] = serial end
    end
    local copy = {}
    for k, v in pairs(meta) do copy[k] = v end
    local original = copy.serial
    copy.serial = serial
    if fresh then
        pcall(deps.audit.financial, 'weapon_serial_scrubbed', recipientCid, line.contract_id,
            { line = line.id, item = line.item, serial = serial, original = original })
    end
    return copy
end

return Scrub
