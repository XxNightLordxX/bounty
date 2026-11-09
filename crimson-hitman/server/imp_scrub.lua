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
--- placer. One line always gets the same new serial, across restarts too,
--- so a give that is tried again (a retry, a queued give at the next login,
--- a recovery after a restart) hands over the same number: it is worked out
--- from the line's id and a secret the server keeps (Storage staff meta
--- 'imp_serial_secret_1' to '_5', 140 random bits made once at the first
--- scrub), never stored per line. Without the secret nobody can work a
--- serial out from a line, or a line from a serial.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')
local Imp = CrimsonBoot.require('server.imp_staffeco')

local Scrub = {}

local deps

--- [escrow line id] = the serial worked out for it, this process.
local minted = {}

--- The secret the serials are worked out with, once read or made: hex.
local secret = nil
--- Kept by the store as SECRET_WORDS staff meta rows,
--- 'imp_serial_secret_1' and on, each a random 28-bit word (the store's
--- meta column is an INT): 140 bits in all. The single 'imp_serial_secret'
--- of earlier versions, one draw of math.random, is no longer read.
Scrub.SECRET_META = 'imp_serial_secret'
local SECRET_WORDS = 5
local WORD_MASK = 0xFFFFFFF

function Scrub.init(d)
    deps = d
    minted = {}
    secret = nil
end

local fnv

--- One random 28-bit word, never 0 (0 is none to the store): math.random
--- mixed with what else this process can see changing (the clocks and a
--- fresh table's address). The resource has no cryptographic source.
---@param i integer
---@return integer
local function randomWord(i)
    local timer = Util.monotonicMs()
    local stir = fnv(('%s:%s:%s:%s:%d'):format(tostring({}), tostring(os.clock()), tostring(timer),
        tostring(os.time()), i))
    local word = (math.random(0, WORD_MASK) ~ stir ~ (math.random(0, WORD_MASK) << 4)) & WORD_MASK
    return word ~= 0 and word or 1
end

--- The server's secret: read from the store, or made and kept there the
--- first time. Each word is kept only where the store has none yet, and
--- read back (Storage.claimStaffMeta), so two first uses landing together
--- both use what the store kept, never each their own. A store that
--- cannot be read gives one for this process only, said in the console,
--- and is asked again at the next start: never written over a secret it
--- could not read.
---@return string
local function serverSecret()
    if secret then return secret end
    local storage = deps and deps.storage
    local read, meta = false, nil
    if storage and storage.readStaffMeta then read, meta = pcall(storage.readStaffMeta) end
    local words = {}
    local claimed, err = read and storage.claimStaffMeta ~= nil, nil
    for i = 1, SECRET_WORDS do
        local key = Scrub.SECRET_META .. '_' .. i
        local kept = read and type(meta) == 'table' and math.tointeger(tonumber(meta[key])) or nil
        if not (kept and kept > 0) and claimed then
            local ok, got = pcall(storage.claimStaffMeta, key, randomWord(i))
            kept = ok and math.tointeger(tonumber(got)) or nil
            if not ok then claimed, err = false, got end
        end
        if not (kept and kept > 0) then
            claimed = false
            kept = randomWord(i)
        end
        words[i] = ('%07x'):format(kept)
    end
    -- Another first use may have finished meanwhile: what it worked out
    -- is the store's too, the same.
    if secret then return secret end
    secret = table.concat(words)
    if not read then
        Log.always('serial scrub: the store\'s secret could not be read; serials are this '
            .. 'process\'s own until the next start')
    elseif not claimed then
        Log.always(('serial scrub: the secret could not be kept by the store (%s); a weapon '
            .. 'given again after the next restart gets another serial'):format(Util.dbError(err)))
    end
    return secret
end

--- FNV-1a, 32 bits.
fnv = function(text)
    local hash = 2166136261
    for i = 1, #text do
        hash = ((hash ~ text:byte(i)) * 16777619) & 0xffffffff
    end
    return hash
end

--- The serial for one escrow line: the same for the same line and secret,
--- in ox_inventory's form (Scrub.newSerial).
---@param lineId string
---@return string
function Scrub.serialFor(lineId)
    local state = fnv(('%s:%s'):format(serverSecret(), tostring(lineId)))
    local function nextValue()
        state = (state * 1103515245 + 12345) & 0x7fffffff
        return state >> 8
    end
    local letters
    repeat
        local a, b, c = nextValue(), nextValue(), nextValue()
        letters = string.char(65 + a % 26, 65 + b % 26, 65 + c % 26)
    until letters ~= 'POL' and letters ~= 'EMS'
    return ('%d%s%d'):format(100000 + nextValue() % 900000, letters, 100000 + nextValue() % 900000)
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
        serial = line.id and Scrub.serialFor(line.id) or Scrub.newSerial()
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
