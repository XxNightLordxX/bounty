--- Staff suspensions and protections, from Players in the admin panel.
---
--- A suspension bars one player from placing or accepting a contract for a
--- number of days, or until staff lift it, with a reason. They are told
--- "You are suspended from contracts until <date>: <reason>" when they
--- try, and on the app's board. Nothing on their live contracts is touched:
--- the freeze (server/freeze.lua) is the tool for that.
---
--- A protection makes one player untargetable for a number of hours or
--- days, or for good: a new player, a break from roleplay, a staff member
--- off duty. A new contract on them is refused with the answer the target
--- rules already give (CH.ERR.TARGET_PROTECTED, "cannot be listed right
--- now"), and the target search lists them as it lists everybody, as it
--- lists a barred job's member: nothing on the list or in the refusal says
--- staff protect them. Live contracts already on them run on; the freeze
--- is the tool for those too.
---
--- Both end by themselves: read as over the moment their time passes, and
--- marked ended by the maintenance tick (Sanctions.tick). Lifted early with
--- one button. Kept by the store as staff records (crimson_staff_records on
--- mysql, records.json on json), which are never deleted, so an ended one
--- stays in the player's history. The same records keep each freeze's start
--- and end (Sanctions.noteFreeze) and every manual payment
--- (server/payments.lua) for the history card.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local Sanctions = {}

local Storage, Audit, Notify

--- The kinds that bar anything. A 'freeze' or 'payment' record is history.
local KINDS = { suspend = true, protect = true }

--- Every staff record, by id: { id, kind, cid, name, reason, by_cid,
--- created_at, until_at, ended_at, ended_by, ended_why, amount, account }.
local records = {}
--- The suspension and protection not ended, by kind and player: [cid] = row.
--- One whose time has passed is over (current) before the tick ends it.
local open = { suspend = {}, protect = {} }
--- How many are open, so a check costs nothing while nobody has one.
local counts = { suspend = 0, protect = 0 }
--- A placing or lifting of one kind on one player in flight, each awaiting
--- the store: a second one let in meanwhile read the first's stale state.
local inFlight = {}

local REASON_MAX = 120
--- The longest a suspension may be set for, in days, and a protection, in
--- hours; anything longer is until lifted (a suspension) or permanent.
Sanctions.MAX_SUSPEND_DAYS = 365
Sanctions.MAX_PROTECT_HOURS = 24 * 365

--- What a suspended player is told. Never who set it.
Sanctions.TEXT = {
    title  = 'Suspended',
    lifted = 'Your suspension from contracts has been lifted.',
    ended  = 'Your suspension from contracts has ended.',
}

local function recount()
    for kind in pairs(KINDS) do
        local n = 0
        for _ in pairs(open[kind]) do n = n + 1 end
        counts[kind] = n
    end
end

---@param deps table { storage, audit, notify }
function Sanctions.init(deps)
    Storage, Audit, Notify = deps.storage, deps.audit, deps.notify
    Sanctions.reload()
end

--- Read every staff record from the store again. Done once at the start.
function Sanctions.reload()
    records, open, inFlight = {}, { suspend = {}, protect = {} }, {}
    counts = { suspend = 0, protect = 0 }
    if not (Storage and Storage.readStaffRecords) then return end
    local ok, rows = pcall(Storage.readStaffRecords)
    if not ok then
        Log.always(('staff suspensions and protections could not be read (%s); '
            .. 'nobody reads as suspended or protected until the next start'):format(Util.dbError(rows)))
        return
    end
    for _, row in ipairs(rows or {}) do
        if row.id and row.cid then
            records[row.id] = row
            if KINDS[row.kind] and not row.ended_at then
                local was = open[row.kind][row.cid]
                if not was or (tonumber(row.created_at) or 0) >= (tonumber(was.created_at) or 0) then
                    open[row.kind][row.cid] = row
                end
            end
        end
    end
    recount()
end

--- The one in force now, or nil.
---@param kind string 'suspend' | 'protect'
---@param cid string|nil
---@return table|nil
local function current(kind, cid)
    if cid == nil or (counts[kind] or 0) == 0 then return nil end
    local row = open[kind][cid]
    if not row then return nil end
    if row.until_at and os.time() >= row.until_at then return nil end
    return row
end

--- The suspension in force on a player, or nil.
---@param cid string|nil
---@return table|nil
function Sanctions.suspended(cid) return current('suspend', cid) end

--- The protection in force on a player, or nil.
---@param cid string|nil
---@return table|nil
function Sanctions.protected(cid) return current('protect', cid) end

--- Every suspension or protection in force now, newest first: the admin
--- panel's Suspended and Protected lists. One whose time has passed is not
--- listed, before the tick ends it.
---@param kind string 'suspend' | 'protect'
---@return table[] rows as the store keeps them
function Sanctions.listOpen(kind)
    local out = {}
    if not KINDS[kind] or (counts[kind] or 0) == 0 then return out end
    for cid in pairs(open[kind]) do
        local row = current(kind, cid)
        if row then out[#out + 1] = row end
    end
    table.sort(out, function(a, b)
        local x, y = tonumber(a.created_at) or 0, tonumber(b.created_at) or 0
        if x ~= y then return x > y end
        return tostring(a.cid) < tostring(b.cid)
    end)
    return out
end

--- How many players are suspended right now: the daily summary's count
--- (server/summary.lua). One whose time has passed is not, before the tick
--- ends it.
---@return integer
function Sanctions.count()
    if (counts.suspend or 0) == 0 then return 0 end
    local n = 0
    for cid in pairs(open.suspend) do
        if current('suspend', cid) then n = n + 1 end
    end
    return n
end

--- Every staff record about one player, oldest first.
---@param cid string
---@return table[]
function Sanctions.recordsOf(cid)
    local out = {}
    for _, row in pairs(records) do
        if row.cid == cid then out[#out + 1] = row end
    end
    table.sort(out, function(a, b)
        if a.created_at ~= b.created_at then return (a.created_at or 0) < (b.created_at or 0) end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

--- What a suspended player is told, from their own suspension: until when,
--- and the reason staff gave. Dates as the server writes them; the app
--- writes its own from `until_at` in the player's own time.
---@param row table
---@return string
function Sanctions.suspendedText(row)
    local untilText = row.until_at and os.date('%Y-%m-%d %H:%M', row.until_at) or 'staff lift it'
    return ('You are suspended from contracts until %s: %s'):format(untilText,
        tostring(row.reason or 'no reason given'))
end

--- What a refusal for a suspension carries to the player's page.
---@param row table
---@return table { untilAt, reason }
function Sanctions.refusal(row)
    return { untilAt = row.until_at, reason = row.reason }
end

local function cleanReason(reason)
    if type(reason) ~= 'string' then return nil end
    -- By characters, never through one: a cut UTF-8 character is refused
    -- by utf8mb4 (error 1366), and the whole write with it.
    return Util.sanitizeText(reason, REASON_MAX)
end

--- One change of one kind on one player at a time: another while one is in
--- flight is refused as busy, never run alongside it.
local function oneAtATime(key, fn, ...)
    if inFlight[key] then return false, CH.ERR.BUSY end
    inFlight[key] = true
    local out = table.pack(pcall(fn, ...))
    inFlight[key] = nil
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
end

--- Write a record, new or changed. False when the store would not take it.
local function store(row)
    local wrote, err = pcall(Storage.writeStaffRecord, row)
    if not wrote then
        Log.always(('a staff record could not be written (%s); nothing changed')
            :format(Util.dbError(err)))
        return false
    end
    records[row.id] = row
    return true
end

--- A copy of a record with its end written in.
local function ended(row, at, by, why)
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.ended_at, copy.ended_by, copy.ended_why = at, by, why
    return copy
end

--- A fresh id for a staff record, from the store's own sequence and
--- confirmed unused.
local function newId()
    return Util.mintId(Storage.nextId, 'sr', function(id) return records[id] ~= nil end)
end

--- The audit actions, by kind and what happened.
local ACTION = {
    suspend = { placed = 'staff_suspend', lifted = 'staff_suspend_lifted', expired = 'staff_suspend_expired' },
    protect = { placed = 'staff_protect', lifted = 'staff_protect_lifted', expired = 'staff_protect_expired' },
}

local placeUnlocked
--- Suspend or protect a player.
---@param kind string 'suspend' | 'protect'
---@param staffCid string|nil who did it, for the record
---@param cid string the player
---@param seconds integer|nil how long; nil until lifted (a suspension) or for good (a protection)
---@param reason string
---@param name string|nil how staff know them, for the record
---@return boolean ok
---@return string|table err 'already' | CH.ERR.* on a refusal; the row on success
function Sanctions.place(kind, staffCid, cid, seconds, reason, name)
    if not KINDS[kind] or type(cid) ~= 'string' or cid == '' then return false, CH.ERR.INVALID_INPUT end
    if seconds ~= nil and (math.type(seconds) ~= 'integer' or seconds <= 0) then
        return false, CH.ERR.INVALID_INPUT
    end
    reason = cleanReason(reason)
    if not reason then return false, CH.ERR.INVALID_INPUT end
    return oneAtATime(kind .. ':' .. cid, placeUnlocked, kind, staffCid, cid, seconds, reason, name)
end

--- End one whose time has passed, as the tick would: written, audited, and
--- the suspended player told. Before anything new is placed on the player.
local function expire(row, now)
    local done = ended(row, row.until_at or now, nil, 'expired')
    if not store(done) then return false end
    if open[row.kind][row.cid] == row then open[row.kind][row.cid] = nil end
    recount()
    Audit.staff(ACTION[row.kind].expired, nil, nil, { subject = row.cid, record = row.id })
    if row.kind == 'suspend' then
        Notify.tellOrKeep(row.cid, Sanctions.TEXT.title, Sanctions.TEXT.ended, { bypassBudget = true })
        Notify.push(row.cid, 'suspend')
    end
    return true
end

placeUnlocked = function(kind, staffCid, cid, seconds, reason, name)
    if current(kind, cid) then return false, 'already' end
    local now = os.time()
    local stale = open[kind][cid]
    if stale and not expire(stale, now) then return false, CH.ERR.SERVER_ERROR end

    local id = newId()
    if not id then return false, CH.ERR.SERVER_ERROR end
    local row = {
        id = id, kind = kind, cid = cid, name = Util.sanitizeText(name, 128),
        reason = reason, by_cid = staffCid, created_at = now,
        until_at = seconds and (now + seconds) or nil,
    }
    if not store(row) then return false, CH.ERR.SERVER_ERROR end
    open[kind][cid] = row
    recount()

    Audit.staff(ACTION[kind].placed, staffCid, nil, {
        subject = cid, reason = reason, until_at = row.until_at, seconds = seconds,
    })
    Audit.flush()

    -- The suspended player is told now, or at their next login; the
    -- protected player is told nothing, and neither is anybody else.
    if kind == 'suspend' then
        Notify.tellOrKeep(cid, Sanctions.TEXT.title, Sanctions.suspendedText(row), { bypassBudget = true })
        Notify.push(cid, 'suspend')
    end
    return true, row
end

local liftUnlocked
--- Lift a suspension or a protection now.
---@param kind string
---@param staffCid string|nil
---@param cid string
---@param reason string|nil
---@return boolean ok
---@return string|nil err 'not_active' | CH.ERR.*
function Sanctions.lift(kind, staffCid, cid, reason)
    if not KINDS[kind] or type(cid) ~= 'string' then return false, 'not_active' end
    return oneAtATime(kind .. ':' .. cid, liftUnlocked, kind, staffCid, cid, cleanReason(reason))
end

liftUnlocked = function(kind, staffCid, cid, reason)
    local row = open[kind][cid]
    if not row then return false, 'not_active' end
    local now = os.time()
    if not current(kind, cid) then
        -- Run out already: ended as it would have been, and nothing to lift.
        expire(row, now)
        return false, 'not_active'
    end
    if not store(ended(row, now, staffCid, 'lifted')) then return false, CH.ERR.SERVER_ERROR end
    open[kind][cid] = nil
    recount()
    Audit.staff(ACTION[kind].lifted, staffCid, nil, { subject = cid, reason = reason, record = row.id })
    Audit.flush()
    if kind == 'suspend' then
        Notify.tellOrKeep(cid, Sanctions.TEXT.title, Sanctions.TEXT.lifted, { bypassBudget = true })
        Notify.push(cid, 'suspend')
    end
    return true
end

--- From the maintenance tick: each one whose time has passed is ended.
--- Nothing reads it as in force meanwhile (current); this writes it down.
---@return integer how many ended
function Sanctions.tick()
    if counts.suspend == 0 and counts.protect == 0 then return 0 end
    local now, due = os.time(), {}
    for kind in pairs(KINDS) do
        for cid, row in pairs(open[kind]) do
            if row.until_at and now >= row.until_at and not inFlight[kind .. ':' .. cid] then
                due[#due + 1] = row
            end
        end
    end
    local n = 0
    for i = 1, #due do
        local row = due[i]
        if open[row.kind][row.cid] == row and expire(row, now) then n = n + 1 end
    end
    if n > 0 then Audit.flush() end
    return n
end

--------------------------------------------------------------------------
-- History kept beside them
--------------------------------------------------------------------------

--- Keep a record that bars nothing (a freeze's start, a manual payment),
--- for the player's history. False when the store would not take it.
---@param fields table { kind, cid, name, reason, by_cid, amount, account }
---@return table|nil row
function Sanctions.note(fields)
    if type(fields) ~= 'table' or KINDS[fields.kind] or type(fields.cid) ~= 'string' then return nil end
    local id = newId()
    if not id then return nil end
    local row = {
        id = id, kind = fields.kind, cid = fields.cid,
        name = Util.sanitizeText(fields.name, 128),
        reason = cleanReason(fields.reason), by_cid = fields.by_cid, created_at = os.time(),
        amount = fields.amount, account = fields.account,
    }
    if not store(row) then return nil end
    return row
end

--- A freeze put on a player (server/freeze.lua), kept for their history:
--- the freeze itself lives in its own store, and its row is deleted when it
--- is lifted.
function Sanctions.noteFreeze(staffCid, cid, reason, name)
    return Sanctions.note({ kind = 'freeze', cid = cid, reason = reason, by_cid = staffCid, name = name })
end

--- A freeze lifted: the newest one kept for the player that has not ended.
function Sanctions.noteUnfreeze(staffCid, cid)
    local latest
    for _, row in pairs(records) do
        if row.kind == 'freeze' and row.cid == cid and not row.ended_at
            and (not latest or (row.created_at or 0) >= (latest.created_at or 0)) then
            latest = row
        end
    end
    if latest then store(ended(latest, os.time(), staffCid, 'lifted')) end
end

return Sanctions
