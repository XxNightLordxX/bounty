--- Flat-file backend (§10.2).
---
--- For servers that do not want to run MySQL. Financial transitions bypass
--- the debounce, and a malformed data file halts the resource rather than
--- starting with empty escrow. A file is written whole under <file>.new and
--- renamed over <file> (see writeRaw), so a crash mid-write tears the copy,
--- not the file, and the next start puts back the last complete one when
--- <file> is missing or torn (see recoverFile). Where renames are refused it
--- is written in place after the copy. A torn index with nothing to put
--- back halts the boot too, and store.json.prev holds the one the last start
--- read; records.json and records.json.prev the same for the records (see
--- RECORDS). The audit log is not in the index: it is a file per day, added
--- to rather than rewritten (see writeAudit).

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local JsonStore = {}

local db, dirty, seq = nil, false, 0
local resource = GetCurrentResourceName and GetCurrentResourceName() or 'crimson-hitman'

local EMPTY = {
    contracts = {}, escrow = {}, hitmen = {}, amendments = {},
    messages = {}, ledger = {}, pending = {}, audit = {}, stats = {}, reveals = {}, mutes = {},
    photos = {}, reviews = {}, settings = {}, alerts = {}, viewAlerts = {}, seq = 0,
}

--- Which contracts have unwritten changes, and whether the index itself has.
---
--- The store used to be re-serialised and rewritten whole on every financial
--- write. With a few thousand contracts that is a multi-megabyte write every
--- time a coin moves. Everything a contract owns — its row, its escrow, its
--- hitmen, its amendments, its messages — lives in one file per contract,
--- and only the contracts that actually changed are written.
local dirtyShards = {}
local indexDirty = false

--- The records: everything that is not per-contract and is not the index's
--- own bookkeeping. The ledger, pending payouts, the stats, the informant
--- reveals, the kill photo records, the review queue, the settings staff
--- changed from the admin panel, the admin panel's alerts, and who turned on
--- the whitelisted-job view's Notify me.
---
--- They were fields of store.json, and store.json was rewritten whole on
--- every financial write, even one that changed only a contract's own file.
--- The ledger keeps up to Ledger.Depth rows for every character ever party
--- to a finished contract and is never aged out, so on a server some months
--- old every kill payout encoded, wrote and read back a multi-megabyte
--- index a dozen times over, on the main thread, with every player waiting
--- on it. So they are a file of their own, records.json, written only when
--- one of them changed: a money write on a contract writes that contract's
--- file and, at most, a store.json small enough not to matter.
local RECORDS = { 'ledger', 'pending', 'stats', 'reveals', 'photos', 'reviews', 'settings',
                  'alerts', 'viewAlerts' }
local recordsDirty = false

--- An alert changed (server/alerts.lua) since records.json was written.
--- Apart from recordsDirty, so a money write's save never writes the file
--- for an alert: only the flush and the close take it in (or a save that
--- writes the records for something else anyway). An alert is said on the
--- way out of a money path that failed, and must not slow the next one.
local alertsDirty = false

--- The playtime the built-in tracker counts (server/playtime.lua), and
--- when it first started: { since, players_id, rows = { [cid] = row } },
--- read from playtime.json the first time it is asked for. A file of its
--- own, written by the flush and the close only: it changes once a minute
--- while anybody is in the city, and records.json, which holds the ledger,
--- is far too big to rewrite that often.
local playtime = nil
local playtimeDirty = false
--- Each playtime row as it was last encoded, by citizen id: the file holds
--- every character ever counted and a minute changes only those in the
--- city, so the minute's write encodes only the rows that changed.
local playtimeText = {}

--- When this store last wrote the heartbeat (os.time()), nil before the
--- first (JsonStore.heartbeat).
local heartbeatWrittenAt = nil

--- Whether records.json is known to be on disk: read at this start, or
--- written since. The index says so (`records = true`), so a later start
--- that finds the file missing knows it is missing rather than not yet
--- made, and refuses as it does for a missing index.
local recordsOnDisk = false

--- Every contract id that owns a file. Kept separately from db.contracts
--- because a shard can hold escrow whose contract row is missing — an
--- orphan is exactly the case where money must not be allowed to vanish,
--- and the index is the only record of which files exist.
local shardIds = {}

--- How many times an index has been built: carried in store.json as
--- `generation`, read back at each start, and one more for every index
--- written. A start takes a whole store.json.new over store.json only where
--- its count is higher (newerIndex), and takes back a contract file the
--- index does not name only where that file was written after the index on
--- disk, while no index had named it yet (adoptable).
local generation = 0

--- The contract ids the index on disk names: the one this start read, or
--- the last one written. A contract file written while its id is not in it
--- carries `unindexed = generation` (shardOf).
local indexedIds = {}

--- Contracts a money write changed whose file is not on disk yet. A money
--- write writes these, and any contract the index on disk does not name
--- yet, rather than every changed file (JsonStore.save).
local urgentShards = {}

--- Contracts the index names but whose file could not be read.
---
--- Kept, rather than forgotten: the id is the only handle anybody has on
--- what was lost, and an operator restoring a backup needs to know which
--- files to look for. Reported at boot, and by the diagnosis command, until
--- the index no longer names them.
local quarantined = {}

--- The audit log, one file per day (UTC), kept out of the index.
---
--- It used to be a field of the index, and the index is rewritten whole on
--- every financial write. With a month of rows that was several megabytes
--- encoded and written, and read back, for every coin moved: a single kill
--- payout wrote store.json a dozen times. So the log is its own files now,
--- written on the flush and at close, and a money write never touches it.
---
--- `lines` is each day's rows, encoded once as they are written: what its
--- file holds, or will. `onDisk` is how many of them are in the file, so a
--- flush adds only the rest. `rewrite` marks a file to write whole: one
--- that ended torn, or an add that failed part-way. `named` is the days an
--- index on disk lists, since there is no directory listing native and the
--- index is the only record of which files exist. `unread` is the named
--- days whose file read back empty at the start (see auditKey).
local auditLog = { lines = {}, onDisk = {}, rewrite = {}, named = {}, unread = {} }

--- What could not be loaded, for the boot report and ch-diag.
---@return table[] entries
function JsonStore.quarantined()
    return quarantined
end

local function directory()
    return Config.Database.Json.Directory or 'data'
end

local function path()
    return directory() .. '/store.json'
end

local function recordsPath()
    return directory() .. '/records.json'
end

--- The UTC day a row belongs to, as its file names it.
local function auditDay(ts)
    return os.date('!%Y-%m-%d', math.floor(tonumber(ts) or os.time()))
end

--- Only a day this store would name: it read the name from the index, and
--- the index is a file anybody can edit. A day, or a day with `.<n>` after
--- it, which is where its rows went while its own file could not be read
--- (auditKey).
local function isAuditDay(day)
    return type(day) == 'string' and (day:match('^%d%d%d%d%-%d%d%-%d%d$') ~= nil
        or day:match('^%d%d%d%d%-%d%d%-%d%d%.%d+$') ~= nil)
end

--- Which file a day's new rows go to: its own, unless the index names that
--- file and it read back empty at the start.
---
--- Empty may be a failed read rather than an empty file, and there is no
--- telling which. Added to, a file that did not end cleanly would have the
--- next row glued onto its torn one; written whole, as a day's first write
--- is, it lost every row it held for good, among them the
--- release_interrupted rows /ch-stuck and /ch-settle are built from. The
--- index will not start over an empty read and a shard is quarantined, not
--- overwritten; a day's file is left alone the same way, and its rows go to
--- audit-<day>.1.jsonl instead (or .2, if that read back empty too). Both
--- are named in the index and read at every start.
local function auditKey(day)
    local key, n = day, 0
    while auditLog.unread[key] do
        n = n + 1
        key = day .. '.' .. n
    end
    return key
end

--- In data/ itself rather than a directory of its own: SaveResourceFile
--- cannot create one, and an upgraded server would not have it.
local function auditPath(day)
    return directory() .. '/audit-' .. day .. '.jsonl'
end

--- The oldest moment a kept row may be from, or nil when the log is kept
--- forever. 0 keeps it, as the retention settings beside it do.
local function auditCutoff()
    local days = tonumber(Config.Audit.RetentionDays) or 0
    if days <= 0 then return nil end
    return os.time() - (days * 86400)
end

--- Contract ids are minted by nextId as a fixed prefix and digits, so they
--- are safe as a filename. Checked anyway: a value that reached here from
--- anywhere else must never become a path fragment.
local function shardPath(contractId)
    if type(contractId) ~= 'string' or not contractId:match('^[%w_%-]+$') then
        return nil
    end
    return directory() .. '/contracts/' .. contractId .. '.json'
end

--- Escrow lines and hitman rows by contract: [contract_id][id] = row.
--- See the memory backend. Here they also serve shardOf, which gathered a
--- contract's rows by walking every row in the store, on every shard write
--- (a kill payout writes its shard several times).
local escrowBy, hitmenBy = {}, {}

--- Messages by contract: [contract_id] = { row, ... }, in the order
--- db.messages holds them, kept as each is written, trimmed or pruned.
---
--- shardOf walked every message in the store for each shard it wrote, and a
--- money write wrote every dirty shard at once (SyncOnFinancialWrite; it
--- writes only its own now, JsonStore.save): with 300 contracts dirtied by a
--- message each over 30,000 messages, one coin moving walked them all 300
--- times, about a second inside the request that moved it. The prune did the
--- same once per contract it removed.
local messagesBy = {}

local function indexMessage(m)
    if type(m) ~= 'table' or m.contract_id == nil then return end
    local rows = messagesBy[m.contract_id]
    if not rows then
        rows = {}
        messagesBy[m.contract_id] = rows
    end
    rows[#rows + 1] = m
end

--- Under the key db holds the row by, which is its id wherever this store
--- wrote it; a row read from an older file is indexed by its key all the
--- same, so nothing db holds is left out of a read.
local function indexRow(index, row, key)
    if type(row) ~= 'table' or row.contract_id == nil or key == nil then return end
    local rows = index[row.contract_id]
    if not rows then
        rows = {}
        index[row.contract_id] = rows
    end
    rows[key] = row
end

local function unindexRow(index, row, key)
    local rows = type(row) == 'table' and row.contract_id ~= nil and index[row.contract_id]
    if rows and rows[key] == row then
        rows[key] = nil
        if next(rows) == nil then index[row.contract_id] = nil end
    end
end

--- Built from db itself, once a load is done. Not kept by absorb alone: the
--- single-file layout from an older version puts escrow and hitmen straight
--- into db, and then writes them out as shards through shardOf. An index
--- that missed them wrote those shards with no escrow in them.
local function reindexRows()
    escrowBy, hitmenBy, messagesBy = {}, {}, {}
    for key, line in pairs(db.escrow or {}) do indexRow(escrowBy, line, key) end
    for key, h in pairs(db.hitmen or {}) do indexRow(hitmenBy, h, key) end
    for i = 1, #(db.messages or {}) do indexMessage(db.messages[i]) end
end

--- Everything belonging to one contract, gathered for writing.
local function shardOf(contractId)
    local shard = {
        contract = db.contracts[contractId],
        escrow = {}, hitmen = {}, amendments = {}, messages = {}, mutes = {},
    }

    for id, line in pairs(escrowBy[contractId] or {}) do
        if db.escrow[id] == line then shard.escrow[id] = line end
    end
    for id, hitman in pairs(hitmenBy[contractId] or {}) do
        if db.hitmen[id] == hitman then shard.hitmen[id] = hitman end
    end
    for id, amendment in pairs(db.amendments) do
        if amendment.contract_id == contractId then shard.amendments[id] = amendment end
    end
    local messages = messagesBy[contractId] or {}
    for i = 1, #messages do shard.messages[i] = messages[i] end
    for key, row in pairs(db.mutes) do
        if row.contract_id == contractId then shard.mutes[key] = row end
    end
    -- Written before any index on disk named it: a start that finds it with
    -- an index no newer than this takes it back in (adoptable).
    if not indexedIds[contractId] then shard.unindexed = generation end

    return shard
end

--- Fold a shard back into the in-memory store.
local function absorb(shard)
    if type(shard) ~= 'table' then return false end
    if type(shard.contract) == 'table' then
        db.contracts[shard.contract.id] = shard.contract
    end
    for id, line in pairs(shard.escrow or {}) do db.escrow[id] = line end
    for id, hitman in pairs(shard.hitmen or {}) do db.hitmen[id] = hitman end
    for id, amendment in pairs(shard.amendments or {}) do db.amendments[id] = amendment end
    for i = 1, #(shard.messages or {}) do
        db.messages[#db.messages + 1] = shard.messages[i]
    end
    -- Absent from a file written before threads could be muted.
    for key, row in pairs(type(shard.mutes) == 'table' and shard.mutes or {}) do
        db.mutes[key] = row
    end
    return true
end

--------------------------------------------------------------------------
-- Load and save
--------------------------------------------------------------------------

--- How many times a read-back has disagreed with what was just written.
--- Kept so the warning is said once and then counted, rather than printed
--- on every flush forever — which is what the production log became, one
--- line repeating until it buried everything after it.
local mismatches = 0

--- The names a whole file is written through: the complete copy, and where
--- the file itself is moved while the copy takes its name on a system whose
--- rename will not replace a file (Windows). Not '.bak', which is taken:
--- store.json.bak is the single-file layout's own copy from the migration
--- (open), and moving store.json aside under that name would delete it.
local NEW, OLD = '.new', '.old'

--- Said once a process: renames refused, so files are written in place.
local renameRefusedSaid = false

--- Whether this server's rename refuses a name that is taken (Windows),
--- learned from the first swap that had to move the file aside: from then
--- on the plain rename, which can only fail there, is not tried first.
local renameKeepsTaken = false

--- Files whose `.old` this store removed after its own last swap, so the
--- next swap need not try to remove one first: [to] = true.
local asideGone = {}

--- The resource's folder on disk, for os.rename and os.remove. Both resolve
--- a path against the server's working directory rather than the resource,
--- as SaveResourceFile does (see JsonStore.prune), so they are handed the
--- whole path. nil where this server cannot say.
local function folderOnDisk()
    local base = GetResourcePath and GetResourcePath(resource)
    if type(base) ~= 'string' or base == '' or type(os.rename) ~= 'function' then return nil end
    return base
end

--- Rename `from` over `to`, both inside the resource.
---
--- A plain rename first, which replaces `to` where the system allows it
--- (Linux, and an `to` that does not exist yet). Where it will not
--- (Windows refuses a name that is taken), `to` is moved aside to
--- `to`.old, the rename made, and the old one removed. A stopped server can
--- leave any of those steps half done, and none of them tears a file: the
--- next start finds `to`, or `to`.new whole beside a missing `to`
--- (recoverFile). A stale `to`.old from a swap stopped before its last step
--- is removed first, or Windows would refuse the move aside as well. Once a
--- swap has shown that the rename keeps a taken name, the plain rename is
--- not tried first again, and an `.old` this store removed itself is not
--- removed again before the next swap.
---@return boolean moved
local function moveOver(from, to)
    local base = folderOnDisk()
    if not base then return false end
    local source, target, aside = base .. '/' .. from, base .. '/' .. to, base .. '/' .. to .. OLD

    local ok, moved
    local tried = not renameKeepsTaken
    if tried then
        ok, moved = pcall(os.rename, source, target)
        if ok and moved == true then return true end
    end

    -- Not where this store removed it itself after the last swap: two of
    -- the seven file operations a write cost on Windows were this and the
    -- plain rename above, each failing every time.
    if not asideGone[to] and type(os.remove) == 'function' then pcall(os.remove, aside) end
    asideGone[to] = nil
    local asideOk, setAside = pcall(os.rename, target, aside)
    setAside = asideOk and setAside == true
    ok, moved = pcall(os.rename, source, target)
    if ok and moved == true then
        if setAside then
            if tried then renameKeepsTaken = true end
            if type(os.remove) == 'function' then
                local removedOk, removed = pcall(os.remove, aside)
                asideGone[to] = removedOk and removed == true or nil
            end
        end
        return true
    end
    -- Neither worked: the file goes back where it was, as it was.
    if setAside then pcall(os.rename, aside, target) end
    return false
end

--- Write one file.
---
--- This used to write the whole thing to `target.tmp`, read that back, and
--- then write the whole thing again to `target`. Two complete writes per
--- file per flush, and no rename between them — so nothing was made atomic
--- by it, and the read-back only ever proved the temp file had landed.
---
--- Worse, it ignored what SaveResourceFile said and judged the write by
--- that read-back alone. On a live server the read-back disagreed on every
--- flush, so a write that had succeeded was discarded and the store
--- persisted nothing at all while reporting that it was keeping things
--- safe.
---
--- SaveResourceFile's own answer is the authority now. The read-back is
--- kept as a second opinion, and where the two disagree the write is
--- retried once — but a write the engine confirmed is never thrown away on
--- the strength of a read that may be cached, buffered, or simply behind.
---
--- And the copy is renamed now (moveOver), which is what the temp file
--- never was: written in place, a crash part-way through left a torn file,
--- and a torn index or records file refuses the start while a torn shard
--- quarantines that contract and its escrow. Written whole as `target`.new
--- and renamed over `target`, the crash tears the copy and the file is the
--- last one written whole. One write a file, as before, and a rename.
---
--- On a server that refuses the rename the file is written in place after
--- the copy, as it was before there was one, and the copy is left: it is
--- the whole file, written first, so a crash that tears the file in place
--- leaves the next start a complete one to put back (recoverFile).
---
--- `quiet` leaves a refused write unsaid, for a caller that says it once
--- for all of them (JsonStore.save, the contract files) or never did (the
--- heartbeat).
---@return boolean written
local function writeRaw(target, encoded, quiet)
    local fresh = target .. NEW
    local wrote = SaveResourceFile(resource, fresh, encoded, -1)
    if wrote == false then
        if not quiet then
            Log.always(('could not write %s. Check that the directory exists '
                .. 'and the server can write to it.'):format(target))
        end
        return false
    end

    -- A second opinion, not a verdict.
    local verify = LoadResourceFile(resource, fresh)
    if not (verify and #verify == #encoded) then
        -- Once more, in case the read caught the write mid-flight.
        SaveResourceFile(resource, fresh, encoded, -1)
        verify = LoadResourceFile(resource, fresh)
    end
    if not (verify and #verify == #encoded) then
        mismatches = mismatches + 1
        if mismatches <= 3 then
            Log.always(('%s reads back as %s bytes after writing %d; the write '
                .. 'was accepted anyway. If contracts do not survive a restart, this is '
                .. 'where to look.')
                :format(target, verify and tostring(#verify) or 'missing', #encoded))
            if mismatches == 3 then
                Log.always('further read-back mismatches will not be printed.')
            end
        end
        -- The engine said it wrote it. Discarding on a disagreeing read is
        -- how "probably fine" became "certainly lost".
    end

    if moveOver(fresh, target) then return true end

    if not renameRefusedSaid then
        renameRefusedSaid = true
        Log.always(('this server would not rename %s over %s, so the json store '
            .. 'writes its files in place, each after a whole copy beside it (<file>%s) that '
            .. 'the next start puts back if a crash tears the file. Check that the server can '
            .. 'rename and remove files in %s.'):format(fresh, target, NEW, directory()))
    end
    if SaveResourceFile(resource, target, encoded, -1) == false then
        if not quiet then
            Log.always(('could not write %s. Check that the directory exists '
                .. 'and the server can write to it.'):format(target))
        end
        return false
    end
    return true
end

--- The decoded table a json file holds, or nil for one missing, empty or
--- torn. A write cut short is never valid JSON: it stops before the brace
--- that closes it.
local function decodeTable(raw)
    if type(raw) ~= 'string' or raw == '' then return nil end
    local ok, value = pcall(json.decode, raw)
    if ok and type(value) == 'table' then return value end
    return nil
end

--- An audit day's file written whole, as writeRaw writes one: something in
--- it, ending on a line's end. Only ever asked of a copy (recoverFile).
local function wholeLines(raw)
    return type(raw) == 'string' and raw ~= '' and raw:sub(-1) == '\n' and raw or nil
end

--- The last complete write of `file`, for a start that found it missing or
--- torn: `file`.new, then `file`.old, whichever holds one `complete` takes.
---
--- Only ever asked when the file itself will not do. Beside a good file a
--- copy is a write that never finished its rename, and the file is the one
--- the store last finished writing. Beside a missing or torn one it is the
--- newest whole write there is: `.new` is written whole before anything
--- moves (writeRaw), and `.old` is the file as it was before a swap that
--- stopped part-way (moveOver).
---
--- `place` puts it back as `file`, by rename where the server allows it, so
--- the copy that was found is never written over on the way: a crash while
--- rewriting the only complete copy would tear that too. A torn `file` is
--- kept as `file`.torn rather than lost. Read-only callers (inspect) leave
--- the disk as it is.
---@param file string
---@param complete function raw -> value or nil
---@param place boolean
---@param torn string|nil what `file` itself read as, kept if there is any
---@return string|nil raw
---@return any value what `complete` made of it
---@return string|nil from the copy's name
local function recoverFile(file, complete, place, torn)
    local raw, value, from
    for _, suffix in ipairs({ NEW, OLD }) do
        local candidate = LoadResourceFile(resource, file .. suffix)
        local made = candidate and complete(candidate)
        if made then
            raw, value, from = candidate, made, file .. suffix
            break
        end
    end
    if not raw or not place then return raw, value, from end

    local hadFile = type(torn) == 'string' and torn ~= ''
    if hadFile then SaveResourceFile(resource, file .. '.torn', torn, -1) end
    local base = folderOnDisk()
    local placed = false
    if base then
        local ok, moved = pcall(os.rename, base .. '/' .. from, base .. '/' .. file)
        placed = ok and moved == true
        if not placed and hadFile and type(os.remove) == 'function' then
            -- Windows will not rename over the torn file; its copy is kept.
            pcall(os.remove, base .. '/' .. file)
            ok, moved = pcall(os.rename, base .. '/' .. from, base .. '/' .. file)
            placed = ok and moved == true
        end
    end
    if not placed then
        -- Written in place, and the copy left where it is: a crash in this
        -- write leaves it for the next start, as it was for this one.
        SaveResourceFile(resource, file, raw, -1)
    end
    Log.always(('%s was %s, as a write the server stopped part-way leaves it; '
        .. 'put back the last complete write of it, from %s.%s')
        :format(file, hadFile and 'torn' or 'missing', from,
            hadFile and (' The torn one is kept as ' .. file .. '.torn.') or ''))
    return raw, value, from
end

local function writeFile(target, value, quiet)
    return writeRaw(target, json.encode(value), quiet)
end

--- How many writes have read back differently. Reported by the diagnosis,
--- since the warning above stops after the third.
function JsonStore.readBackMismatches() return mismatches end

--- Add lines to the end of a file, leaving what is already there alone.
---
--- SaveResourceFile cannot append, so this goes through the resource's own
--- folder, as the prune's unlink does. Binary mode, so a Windows host does
--- not turn each newline into two characters. nil where that folder is not
--- known: the caller writes the whole file instead.
---@return boolean|nil written
local function appendFile(target, lines, from)
    local base = GetResourcePath and GetResourcePath(resource)
    if not base or base == '' or not (io and io.open) then return nil end
    local handle = io.open(base .. '/' .. target, 'ab')
    if not handle then return false end
    local ok = handle:write(table.concat(lines, '\n', from) .. '\n')
    handle:close()
    return ok ~= nil
end

--- One day's audit file: its rows, encoded and decoded, whether it ended
--- cleanly, and whether it read back empty. A line that will not parse is
--- the tail of a write a crash cut short; the rows before it are kept, and
--- the file is marked to be written whole so the next row is not added onto
--- the torn one.
local function readAuditDay(day)
    local file = auditPath(day)
    -- Twice, as a shard is, before believing it is empty.
    local raw = LoadResourceFile(resource, file)
    if not raw or raw == '' then raw = LoadResourceFile(resource, file) end
    -- Missing, where a whole write of it stopped between its two renames
    -- (moveOver): its copy is the day as last written whole. Only when it is
    -- missing: rows are added to the end of the file itself (appendFile), so
    -- beside a file that has any, a copy may hold fewer of them.
    if not raw or raw == '' then raw = recoverFile(file, wholeLines, true) or raw end

    local lines, rows, bad = {}, {}, 0
    if not raw or raw == '' then return lines, rows, true, true end
    for line in raw:gmatch('[^\n]+') do
        line = line:gsub('\r$', '')
        local ok, row = pcall(json.decode, line)
        if ok and type(row) == 'table' then
            lines[#lines + 1], rows[#rows + 1] = line, row
        else
            bad = bad + 1
        end
    end
    if bad > 0 then
        Log.always(('%d line(s) of %s could not be read and were left out; '
            .. 'the rest of that day\'s audit log is kept.'):format(bad, file))
    end
    return lines, rows, bad == 0 and raw:sub(-1) == '\n'
end

--- Shard and audit files a prune is waiting to remove until the index
--- without them is safely on disk (JsonStore.prune, dropAuditDay).
local pendingUnlinks = {}

--- Remove them, once an index that no longer names them has been written.
--- Any index written after the prune qualifies, since the prune already
--- took them off it. Only the prune used to do this, and it returned early
--- when it found nothing new to prune, so an index write that failed once
--- left the files on disk for good.
local function unlinkPending()
    if #pendingUnlinks == 0 then return end
    local base = GetResourcePath and GetResourcePath(resource)
    if base and base ~= '' then
        for i = 1, #pendingUnlinks do os.remove(base .. '/' .. pendingUnlinks[i]) end
    end
    pendingUnlinks = {}
end

--- Everything the index file holds: the sequence, which contracts own a
--- shard, and the small tables that are not per-contract.
---
--- Built in one place because both the flush and the writability probe write
--- it, and an index missing a field here is a store that loses whatever the
--- field held.
local function buildIndex()
    local index = { seq = seq, contractIds = {} }
    local named = {}
    for id in pairs(shardIds) do
        named[id] = true
        index.contractIds[#index.contractIds + 1] = id
    end

    -- A contract whose shard could not be read stays named here.
    --
    -- There is no directory listing native, so this index is the only record
    -- of which shards exist: an id it does not name is a file nothing will
    -- ever open again. And open() ends by writing this index — assertWritable
    -- proves the directory is writable by writing the real thing — so an id
    -- left out here was erased from disk by the very boot that quarantined
    -- it, before the banner naming it had even been printed.
    --
    -- That made the banner's own instruction impossible to follow. An
    -- operator restoring the file from a backup and restarting, exactly as
    -- told, got nothing back: the contract, its held escrow and the warning
    -- itself were already gone, and they had every reason to believe it had
    -- worked. Refusing to start, which this replaced, at least left the id
    -- on disk.
    --
    -- Removing the id is still the operator's to do, by taking it out of
    -- this file. It is not put back once they have.
    for i = 1, #quarantined do
        local id = quarantined[i].id
        if id and not named[id] then
            named[id] = true
            index.contractIds[#index.contractIds + 1] = id
        end
    end

    table.sort(index.contractIds)

    -- Not the records, which are a file of their own (RECORDS): only
    -- whether that file has been written, so a start that cannot find it
    -- knows something is missing.
    index.records = recordsOnDisk or nil

    -- Not the audit log itself, which is files of its own: only which days
    -- have one, since nothing else records that.
    index.auditDays = {}
    for day in pairs(auditLog.lines) do index.auditDays[#index.auditDays + 1] = day end
    table.sort(index.auditDays)

    -- When it was written: the server was running then, which is the last
    -- resort a start has for dating the downtime before it where the
    -- heartbeat file did not survive (JsonStore.lastHeartbeat).
    index.saved_at = os.time()
    -- Which index this is (generation). Not saved_at, whose second is too
    -- coarse: two indexes written in one second are told apart by this.
    generation = generation + 1
    index.generation = generation
    return index
end

--- Write the index, and then what waited on it: every day it lists may
--- now have its file written, and every file it no longer lists may go.
local function writeIndex()
    local index = buildIndex()
    if not writeFile(path(), index) then return false end
    indexedIds = {}
    for i = 1, #index.contractIds do indexedIds[index.contractIds[i]] = true end
    for day in pairs(auditLog.lines) do auditLog.named[day] = true end
    unlinkPending()
    return true
end

--- Write the records file whole. It is the one file that grows with the
--- server's history, which is why it is written only when a record changed.
local function writeRecords()
    local records = {}
    for i = 1, #RECORDS do records[RECORDS[i]] = db[RECORDS[i]] end
    if not writeFile(recordsPath(), records) then return false end
    recordsOnDisk, recordsDirty, alertsDirty = true, false, false
    return true
end

--- Whether a decoded index still carries the records, as every index did
--- before they had a file of their own.
local function carriesRecords(decoded)
    for i = 1, #RECORDS do
        if decoded[RECORDS[i]] ~= nil then return true end
    end
    return false
end

--- Read the records back.
---
--- Moved out of an index that still carries them first, writing
--- records.json before anything writes an index without them, so a start
--- interrupted part-way still has them in store.json and moves them again.
--- An index that carries them is newer than any records.json beside it, or
--- the same: an interrupted move left both, and a store downgraded to a
--- version from before the move and back wrote the newer ones there.
---
--- A missing or unreadable records.json that the index says was written is
--- refused, as a missing or unreadable index is: it holds the payouts owed
--- to players who were offline, and starting without them loses those.
local function loadRecords(decoded)
    if carriesRecords(decoded) then
        if not writeRecords() then
            error(('[crimson-hitman] cannot write %s while moving the records (ledger, pending '
                .. 'payouts, stats, reveals, kill photos) out of %s. Refusing to start: %s '
                .. 'still holds them, unchanged, and the move is tried again on the next start.')
                :format(recordsPath(), path(), path()))
        end
        Log.debug(('moved the records out of %s into %s, so a money write no '
            .. 'longer rewrites them.'):format(path(), recordsPath()))
        return
    end

    -- Read twice, as the index is, before believing there is nothing.
    local raw = LoadResourceFile(resource, recordsPath())
    if raw == nil or raw == '' then raw = LoadResourceFile(resource, recordsPath()) end
    -- Missing or torn, the last complete write of it is put back first
    -- (recoverFile), and refused below only where there is none.
    if not decodeTable(raw) then
        raw = recoverFile(recordsPath(), decodeTable, true, raw) or raw
    end

    if raw == nil or raw == '' then
        if decoded.records then
            error(('[crimson-hitman] %s is missing or empty, but %s says it was written. '
                .. 'Refusing to start: it holds the payouts owed to players who were offline, '
                .. 'and starting without them would lose those. Restore it from %s.prev, the '
                .. 'records as of the last start, or from a backup. To start without them on '
                .. 'purpose, take "records":true out of %s.')
                :format(recordsPath(), path(), recordsPath(), path()))
        end
        -- Never written: an index from the moment between a first start
        -- writing it and writing this.
        recordsDirty = true
        return
    end

    local ok, records = pcall(json.decode, raw)
    if not ok or type(records) ~= 'table' then
        error(('[crimson-hitman] %s is unreadable. Refusing to start: it holds the payouts '
            .. 'owed to players who were offline. Restore it from %s.prev or a backup, or '
            .. 'move it aside deliberately.'):format(recordsPath(), recordsPath()))
    end
    for i = 1, #RECORDS do
        local key = RECORDS[i]
        db[key] = type(records[key]) == 'table' and records[key] or {}
    end
    recordsOnDisk = true
    -- As the index is: once per start, so a start that finds this torn has
    -- something to restore from.
    SaveResourceFile(resource, recordsPath() .. '.prev', raw, -1)
end

--- Write the audit rows that are not on disk yet.
---
--- Only a day an index on disk already names. Written first, a crash before
--- the index left a file nothing would ever read; named first, the worst a
--- crash leaves is a name with no file, which reads back as an empty day
--- whose rows go on in a file of their own (auditKey).
---@return boolean ok
---@return string|nil file the first day's file that could not be written
local function saveAudit()
    local ok, failedFile = true, nil
    for day, lines in pairs(auditLog.lines) do
        local done = auditLog.onDisk[day] or 0
        -- Never a day whose file read back empty: see auditKey.
        if auditLog.named[day] and not auditLog.unread[day]
            and (#lines > done or auditLog.rewrite[day]) then
            local file = auditPath(day)
            -- Added to where it can be, so a busy day is not rewritten whole
            -- every flush; written whole the first time, and where the add
            -- failed or the file ended torn.
            local wrote
            if done > 0 and not auditLog.rewrite[day] then
                wrote = appendFile(file, lines, done + 1)
            end
            if not wrote then
                wrote = writeRaw(file, #lines > 0 and (table.concat(lines, '\n') .. '\n') or '')
            end
            if wrote then
                auditLog.onDisk[day], auditLog.rewrite[day] = #lines, nil
            else
                ok, failedFile = false, failedFile or file
            end
        end
    end
    return ok, failedFile
end

--- A whole day past the retention age: off the index, and its file removed
--- once an index without it is on disk, as a pruned contract's is.
local function dropAuditDay(day)
    auditLog.lines[day], auditLog.onDisk[day] = nil, nil
    auditLog.rewrite[day], auditLog.named[day], auditLog.unread[day] = nil, nil, nil
    pendingUnlinks[#pendingUnlinks + 1] = auditPath(day)
    indexDirty, dirty = true, true
end

--- Read the audit log back, moving one an older version kept in the index
--- out of it first.
---
--- The move writes each day's file before anything writes an index without
--- the rows, so a start interrupted part-way still has them in store.json
--- and simply moves them again. A day whose file already holds at least as
--- many rows as the index has for it was written by that earlier attempt,
--- or since, and is kept as it is, so a second move adds nothing twice.
local function loadAudit(decoded)
    auditLog = { lines = {}, onDisk = {}, rewrite = {}, named = {}, unread = {} }
    local rowsByDay = {}
    local cutoff = auditCutoff()
    local cutoffDay = cutoff and auditDay(cutoff)

    local named = type(decoded.auditDays) == 'table' and decoded.auditDays or {}
    for i = 1, #named do
        local day = named[i]
        if isAuditDay(day) and not auditLog.lines[day] then
            local lines, rows, clean, empty = readAuditDay(day)
            auditLog.lines[day], auditLog.onDisk[day] = lines, #lines
            auditLog.rewrite[day] = (not clean) or nil
            auditLog.named[day] = true
            auditLog.unread[day] = empty or nil
            rowsByDay[day] = rows
        end
    end
    for day in pairs(auditLog.unread) do
        if not (cutoffDay and day < cutoffDay) then
            Log.always(('%s is named in %s but is missing or read back empty. '
                .. 'It is left as it is, in case it was the read that failed; that day\'s new '
                .. 'audit rows go to %s instead. Restore it from a backup if it should hold '
                .. 'rows.'):format(auditPath(day), path(), auditPath(auditKey(day:sub(1, 10)))))
        end
    end

    local legacy = type(decoded.audit) == 'table' and decoded.audit or {}
    if #legacy > 0 then
        local moving, moved = {}, 0
        for i = 1, #legacy do
            local row = legacy[i]
            local encoded, line = pcall(json.encode, row)
            local day = type(row) == 'table' and encoded and auditDay(row.ts)
            -- A day already past the retention age would only be written to
            -- be deleted.
            if day and not (cutoffDay and day < cutoffDay) then
                moving[day] = moving[day] or { lines = {}, rows = {} }
                moving[day].lines[#moving[day].lines + 1] = line
                moving[day].rows[#moving[day].rows + 1] = row
            end
        end
        for day, set in pairs(moving) do
            local lines, rows, clean = auditLog.lines[day], rowsByDay[day], not auditLog.rewrite[day]
            if not lines then lines, rows, clean = readAuditDay(day) end
            if #lines < #set.lines then
                lines, rows, clean = set.lines, set.rows, true
                if not writeRaw(auditPath(day), table.concat(lines, '\n') .. '\n') then
                    error(('[crimson-hitman] cannot write %s while moving the audit log out of %s. '
                        .. 'Refusing to start: %s still holds it, unchanged, and the move is tried '
                        .. 'again on the next start.'):format(auditPath(day), path(), path()))
                end
            end
            auditLog.lines[day], auditLog.onDisk[day] = lines, #lines
            auditLog.rewrite[day] = (not clean) or nil
            rowsByDay[day] = rows
            moved = moved + #set.lines
        end
        Log.debug(('moved %d audit row(s) out of %s into one file per day '
            .. '(%s/audit-<day>.jsonl).'):format(moved, path(), directory()))
    end

    -- Oldest first, as they were written, and the retention age applied as
    -- the writes apply it.
    local days = {}
    for day in pairs(auditLog.lines) do days[#days + 1] = day end
    table.sort(days)
    db.audit = {}
    for _, day in ipairs(days) do
        if cutoffDay and day < cutoffDay then
            dropAuditDay(day)
        else
            local rows = rowsByDay[day] or {}
            for i = 1, #rows do
                if not cutoff or (tonumber(rows[i].ts) or 0) >= cutoff then
                    db.audit[#db.audit + 1] = rows[i]
                end
            end
        end
    end
end

--- The server's own record that this store has run, kept outside the
--- resource folder.
---
--- contracts/.writable says the same, but it lives in data/, and the usual
--- way to update a FiveM resource is to delete its folder and extract the
--- new one. That took data/ with it — every open contract's escrow, every
--- payout owed to somebody offline, the ledger, the kill photos — and left
--- exactly the signature of a first install, so the store started empty
--- without a word. A resource KVP lives in the server's own database, not
--- in the folder, and survives the folder being replaced.
local function kvpKey()
    return 'jsonStoreRan:' .. directory()
end

local function ranHereBefore()
    if type(GetResourceKvpInt) ~= 'function' then return false end
    local ok, value = pcall(GetResourceKvpInt, kvpKey())
    return ok and value == 1
end

local function markRan()
    if type(SetResourceKvpInt) == 'function' then pcall(SetResourceKvpInt, kvpKey(), 1) end
end

--- Starting empty on purpose, over a store that has run: set from the
--- server console (`set crimson_hitman_new_store 1`) for one start. A
--- convar rather than a setting, so it is not left in config.lua to wave
--- the next lost folder through as well.
local function startEmptyAllowed()
    local value = GetConvar and GetConvar('crimson_hitman_new_store', '') or ''
    return value == '1' or value == 'true'
end

--- Confirm the store's directories are actually writable.
---
--- SaveResourceFile writes a file; it does not create the directories above
--- it. Without data/ and data/contracts/ already present every write fails
--- and returns nothing useful, so escrow would be taken from players and
--- never recorded — and the first anyone would know is a restart with the
--- contracts gone.
---
--- Refusing to start is the only honest answer: a store that silently drops
--- everything is worse than no store.
function JsonStore.assertWritable()
    -- The index is the probe: writing it proves data/ is writable and leaves
    -- the store in exactly the state a flush would, rather than dropping a
    -- stray file next to it.
    if not writeIndex() then
        error(('[crimson-hitman] cannot write %s. Create the directory %s and make it ' ..
               'writable by the server, or switch Config.Database.Mode away from json. ' ..
               'Refusing to start: escrow taken from players would not be recorded.')
               :format(path(), directory()))
    end

    -- The shard directory is separate, and just as fatal. Nothing reads this
    -- file; it exists so a missing contracts/ is found at startup rather than
    -- the first time a contract is created and its escrow disappears.
    local file = directory() .. '/contracts/.writable'
    SaveResourceFile(resource, file, json.encode({ at = os.time() }), -1)
    if not LoadResourceFile(resource, file) then
        error(('[crimson-hitman] cannot write %s/contracts/. Create that directory and ' ..
               'make it writable by the server. Refusing to start: every contract would ' ..
               'be taken and none of them stored.'):format(directory()))
    end

    -- Outside the folder, so a replaced folder is told from a first install.
    markRan()
    return true
end

--- A whole store.json.new beside a whole store.json, and newer.
---
--- A new contract is written as its file first and then the index naming
--- it, through store.json.new renamed over store.json (writeRaw). A server
--- stopped between the two left an index on disk that named the contract,
--- whole, beside the one that did not, and the start kept the old one:
--- the contract, its escrow and the client's money were gone, with nothing
--- said. Every whole file is written as its .new before anything moves, so
--- a whole .new written after store.json is the index that rename was for.
---
--- Newer only by its count (generation), strictly. Where renames are refused
--- the .new is the same index as store.json and stays beside it, so one
--- taken at the same count undid every hand edit of store.json at the next
--- start (an id taken out came back) and said the server had stopped mid
--- write. Between two indexes from before the count, only a higher `seq`
--- says the copy is newer; at the same one the index stands, and a new
--- contract's file is still taken back in by the scan of contracts/.
---@param raw string store.json as read, whole
---@return string|nil fresh the copy's text, where it is to be used
local function newerIndex(raw)
    local fresh = LoadResourceFile(resource, path() .. NEW)
    if fresh == nil or fresh == '' or fresh == raw then return nil end
    local copy, current = decodeTable(fresh), decodeTable(raw)
    if not (copy and current and type(copy.contractIds) == 'table') then return nil end
    local copyCount, currentCount = tonumber(copy.generation), tonumber(current.generation)
    if copyCount or currentCount then
        -- One written by a version before the count is the older of the two.
        if not copyCount or (currentCount and copyCount <= currentCount) then return nil end
        return fresh
    end
    if (tonumber(copy.seq) or 0) <= (tonumber(current.seq) or 0) then return nil end
    return fresh
end

--- The contract files in contracts/ that `named` does not name, by id: a
--- file of its own, or only its whole copy (<id>.json.new). Not one with only
--- a <id>.json.old: that is the file as it was before a later write of it
--- (moveOver), and never the only whole copy of a contract no index has
--- named yet. Empty where this server cannot list a folder (io.readdir), as
--- photos' sweepFiles finds it.
---@param named table<string, boolean>
---@return string[] ids
local function unnamedShards(named)
    local base, readdir = folderOnDisk(), io and io.readdir
    if not base or type(readdir) ~= 'function' then return {} end
    local ok, listing = pcall(readdir, base .. '/' .. directory() .. '/contracts')
    if not ok or not listing then return {} end
    local ids, seen = {}, {}
    pcall(function()
        for name in listing:lines() do
            local id = type(name) == 'string' and (name:match('^([%w_%-]+)%.json$')
                or name:match('^([%w_%-]+)%.json%.new$'))
            if id and not named[id] and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end)
    pcall(function() listing:close() end)
    table.sort(ids)
    return ids
end

--- A contract file the index does not name, as a start reads it: the file,
--- or else its whole .new copy (read only, nothing moved). Never its .old,
--- which is the file before a write that came after it (unnamedShards).
local function readShard(id)
    local file = shardPath(id)
    if not file then return nil end
    return decodeTable(LoadResourceFile(resource, file))
        or decodeTable(LoadResourceFile(resource, file .. NEW))
end

--- Whether a contract file the index does not name has to be taken back
--- in: it holds escrow not yet settled (held, owed or mid-release), or its
--- contract is still running. One that holds neither is a finished
--- contract's file a prune had not yet removed, and stays where it is.
local function holdsMoneyOrRuns(shard, id)
    if type(shard) ~= 'table' then return false end
    local contract = shard.contract
    if type(contract) == 'table' and contract.id ~= nil and contract.id ~= id then return false end
    if type(contract) == 'table' and not CH.TERMINAL[contract.state] then return true end
    for _, line in pairs(type(shard.escrow) == 'table' and shard.escrow or {}) do
        if type(line) == 'table' and line.state ~= CH.ESCROW_STATE.SETTLED then return true end
    end
    return false
end

--- Whether a contract file the index on disk does not name is taken back in:
--- written while no index had named it (`unindexed`, shardOf) and after the
--- index on disk was (its count no lower than that index's), and holding
--- money or a running contract. That is exactly what a server stopped
--- between writing a new contract's file and the index naming it leaves.
---
--- Any other is a contract some earlier index named and a later one does
--- not: pruned, or taken off store.json by hand, which is how staff drop one
--- for good. Taking those back in too, as a plain scan of contracts/ did,
--- brought a cancelled contract back from a stale copy and refunded it a
--- second time, and undid every contract staff had dropped. A file from a
--- version before the count carries no mark and is never taken back in.
---@param index table the index this start read
local function adoptable(shard, id, index)
    if type(shard) ~= 'table' then return false end
    local writtenAt = tonumber(shard.unindexed)
    if not writtenAt or writtenAt < (tonumber(index.generation) or 0) then return false end
    return holdsMoneyOrRuns(shard, id)
end

--- What this start read that says when the server was last running, for a
--- heartbeat file a crash did not leave whole (JsonStore.lastHeartbeat):
--- the newest audit row, and when the index it found was written.
local lastKnown = {}

--- Read the store.
---
--- A file that exists but will not parse is fatal: starting fresh would
--- silently delete every open contract's escrow. The same goes for a shard
--- the index names and cannot be read — that is one contract's money
--- missing, which is not something to start up and hope about.
function JsonStore.open()
    -- Read again from its own file when it is next asked for.
    playtime, playtimeDirty, heartbeatWrittenAt, playtimeText = nil, false, nil, {}
    renameKeepsTaken, asideGone = false, {}
    -- Read twice, as a shard is, before believing there is no index.
    local raw = LoadResourceFile(resource, path())
    if raw == nil or raw == '' then raw = LoadResourceFile(resource, path()) end
    -- Missing or torn, the last complete write of it is put back first: a
    -- write the server stopped between its renames leaves store.json missing
    -- and store.json.new whole (recoverFile). Only where there is none do
    -- the refusals below decide.
    if not decodeTable(raw) then
        raw = recoverFile(path(), decodeTable, true, raw) or raw
    else
        -- Whole, beside a whole newer copy: the server stopped before the
        -- copy's rename (newerIndex). Put in place as that rename would have.
        local fresh = newerIndex(raw)
        if fresh then
            if not moveOver(path() .. NEW, path()) then
                SaveResourceFile(resource, path(), fresh, -1)
            end
            Log.always(('%s was not yet renamed over %s when the server stopped; it is the '
                .. 'newer of the two, whole, and is used.'):format(path() .. NEW, path()))
            raw = fresh
        end
    end
    lastKnown = {}

    if raw == nil or raw == '' then
        -- Empty is a first install only where this store has never run.
        -- assertWritable leaves contracts/.writable behind on every boot, so
        -- finding it means there was an index and it is now missing or
        -- empty: store.json is rewritten in place, and a crash mid-write
        -- leaves it zero-length. Starting empty here wrote an index naming
        -- no contracts over it, and every open contract and the escrow it
        -- held were gone without a word. The server's own record (kvpKey)
        -- says the same where the whole folder was replaced.
        local writable = LoadResourceFile(resource, directory() .. '/contracts/.writable')
        local folderSays = writable ~= nil and writable ~= ''
        if (folderSays or ranHereBefore()) and not startEmptyAllowed() then
            local how = folderSays
                and ('Restore it from %s.prev, the index as of the last start (a contract '
                    .. 'created since still has its file in %s/contracts/), or from a backup.')
                    :format(path(), directory())
                or ('The %s folder is gone or empty, which is what replacing the resource '
                    .. 'folder in an update does: put the old %s/ back (all of it: store.json, '
                    .. 'records.json, contracts/, photos/), or restore it from a backup.')
                    :format(directory(), directory())
            error(('[crimson-hitman] %s is missing or empty, but this server has run this store '
                   .. 'before. Refusing to start: starting empty would drop every open contract '
                   .. 'and its escrow, and every payout owed to a player who is offline. %s To '
                   .. 'start empty on purpose, run `set crimson_hitman_new_store 1` in the server '
                   .. 'console and start the resource again.')
                   :format(path(), how))
        end
        if folderSays or ranHereBefore() then
            Log.always(('starting with an empty store over one that has run here, '
                .. 'because crimson_hitman_new_store is set. Unset it now: left set, the next '
                .. 'lost %s/ starts empty without a word too.'):format(directory()))
        end

        db = json.decode(json.encode(EMPTY))
        escrowBy, hitmenBy, messagesBy = {}, {}, {}
        dirtyShards, shardIds, quarantined, indexDirty = {}, {}, {}, true
        generation, indexedIds, urgentShards = 0, {}, {}
        recordsDirty, recordsOnDisk, alertsDirty = true, false, false
        auditLog = { lines = {}, onDisk = {}, rewrite = {}, named = {}, unread = {} }
        JsonStore.save(true)
        JsonStore.assertWritable()
        return true
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        error(('[crimson-hitman] %s is unreadable. Refusing to start: continuing would ' ..
               'discard every open contract and its escrow. Restore the file from %s.prev ' ..
               'or a backup, or move it aside deliberately.'):format(path(), path()))
    end

    db = json.decode(json.encode(EMPTY))
    dirtyShards, shardIds, quarantined = {}, {}, {}
    recordsDirty, recordsOnDisk, alertsDirty = false, false, false
    -- The index on disk: which it is, and which contracts it names.
    generation, indexedIds, urgentShards = tonumber(decoded.generation) or 0, {}, {}
    for _, id in ipairs(type(decoded.contractIds) == 'table' and decoded.contractIds or {}) do
        indexedIds[tostring(id)] = true
    end
    for key, value in pairs(decoded) do
        -- The audit log is read from its own files, below, and the records
        -- from theirs. `records` is only the index saying that file exists.
        if key ~= 'contractIds' and key ~= 'audit' and key ~= 'auditDays'
            and key ~= 'records' and key ~= 'saved_at' then
            db[key] = value
        end
    end
    lastKnown.index = tonumber(decoded.saved_at)
    for key, value in pairs(EMPTY) do
        if db[key] == nil then db[key] = type(value) == 'table' and {} or value end
    end
    seq = tonumber(db.seq) or 0
    -- The single-file layout below put escrow and hitmen straight into db.
    reindexRows()

    -- Before either layout below writes an index: one that still carries the
    -- audit log, or the records, has to have them on disk elsewhere first.
    if type(decoded.contractIds) == 'table' or type(decoded.contracts) == 'table' then
        loadAudit(decoded)
        loadRecords(decoded)
        for i = 1, #db.audit do
            local ts = tonumber(db.audit[i].ts)
            if ts and (lastKnown.audit == nil or ts > lastKnown.audit) then lastKnown.audit = ts end
        end
    end

    if type(decoded.contractIds) == 'table' then
        -- The index as this start found it, so a later start that finds it
        -- torn has something to restore from. Once per start rather than on
        -- every write, which would double the cost of the commonest write.
        SaveResourceFile(resource, path() .. '.prev', raw, -1)

        -- Sharded layout. There is no directory listing native, so the index
        -- is the only record of which shards exist; a named shard that will
        -- not load is a missing contract, not a missing file.
        for i = 1, #decoded.contractIds do
            local id = decoded.contractIds[i]
            local file = shardPath(id)

            -- Read twice before believing it is gone. A single failed read is
            -- as likely to be the file being written, or a disk hiccup, as it
            -- is to be a genuinely missing shard — and treating a transient
            -- failure as a lost contract is how a live contract gets dropped.
            local shardRaw = file and LoadResourceFile(resource, file)
            if not shardRaw or shardRaw == '' then
                shardRaw = file and LoadResourceFile(resource, file)
            end

            local shard = decodeTable(shardRaw)
            -- Missing or torn, the last complete write of it before it is
            -- set aside (recoverFile).
            if not shard and file then
                local recovered, value = recoverFile(file, decodeTable, true, shardRaw)
                if recovered then shardRaw, shard = recovered, value end
            end

            if shard then
                absorb(shard)
                shardIds[id] = true
            else
                -- Set aside, not discarded, and not a reason to refuse to
                -- start.
                --
                -- This used to abort the boot, on the grounds that the
                -- contract held escrow nobody could return. It does — but
                -- refusing to start returns it no better: the shard that
                -- recorded the escrow is the thing that is missing, so the
                -- money is equally unreachable either way. All the refusal
                -- added was the whole resource being down for everybody, on
                -- a server where the only way out was to edit the store by
                -- hand and guess which line to remove.
                --
                -- What the refusal was really buying was the operator's
                -- attention. That is bought here instead, by a warning that
                -- names the contract and comes back every single boot until
                -- somebody deals with it, and by keeping the id where it can
                -- be read rather than dropping it silently.
                quarantined[#quarantined + 1] = {
                    id = tostring(id),
                    file = file,
                    reason = (shardRaw and shardRaw ~= '')
                        and 'unreadable' or 'missing or empty',
                    at = os.time(),
                }
            end
        end

        -- A contract file the index does not name: a server stopped after a
        -- new contract's file was whole and before an index naming it was
        -- (newerIndex covers the copy that was whole; this the one that was
        -- not). Nothing else would ever read it, so one written since this
        -- index, before any index named it, and holding money or a running
        -- contract is taken back in (adoptable). Any other is one an earlier
        -- index named, pruned or taken off store.json by hand, or a finished
        -- one a prune had not yet removed: said once and left where it is,
        -- never deleted, never read again.
        local named = {}
        for i = 1, #decoded.contractIds do named[tostring(decoded.contractIds[i])] = true end
        local adopted, left = {}, {}
        for _, id in ipairs(unnamedShards(named)) do
            local shard = readShard(id)
            if adoptable(shard, id, decoded) then
                absorb(shard)
                shardIds[id], dirtyShards[id] = true, true
                indexDirty, dirty = true, true
                adopted[#adopted + 1] = id
            else
                left[#left + 1] = id
            end
        end
        if #adopted > 0 then
            Log.always(('%d contract file(s) in %s/contracts/ were not named in %s and hold '
                .. 'money or a running contract, as a server stopped between writing a new contract '
                .. 'and the index leaves them; taken back in: %s.')
                :format(#adopted, directory(), path(), table.concat(adopted, ', ')))
        end
        if #left > 0 then
            Log.debug(('%d contract file(s) in %s/contracts/ are not named in %s and are not a '
                .. 'new contract the index had yet to name (pruned, taken off it by hand, or '
                .. 'holding nothing); left as they are and not read: %s.')
                :format(#left, directory(), path(), table.concat(left, ', ')))
        end

        -- Everything the shards brought in.
        reindexRows()
    elseif type(decoded.contracts) == 'table' then
        -- The old single-file layout, from a version before this one. Load
        -- it as it stands and write it out sharded, keeping the original
        -- where it is: a migration that deletes the only copy of the data it
        -- is migrating is not one worth having.
        local migrated = 0
        for id in pairs(db.contracts) do
            dirtyShards[id] = true
            shardIds[id] = true
            migrated = migrated + 1
        end

        -- Escrow whose contract row did not survive still belongs to
        -- somebody. It gets a file of its own rather than being left out of
        -- the migration.
        for _, line in pairs(db.escrow) do
            if line.contract_id and not shardIds[line.contract_id] then
                dirtyShards[line.contract_id] = true
                shardIds[line.contract_id] = true
                migrated = migrated + 1
            end
        end
        indexDirty = true
        SaveResourceFile(resource, path() .. '.bak', raw, -1)
        JsonStore.save(true)
        Log.debug(('migrated %d contract(s) to one file each; the original ' ..
               'store is kept at %s.bak'):format(migrated, path()))
    else
        error(('[crimson-hitman] %s has neither a contract index nor contracts. ' ..
               'Refusing to start on a store this file does not understand.'):format(path()))
    end

    JsonStore.assertWritable()

    local count = 0
    for _ in pairs(db.contracts) do count = count + 1 end
    if count > (Config.Database.Json.WarnContractCount or 2000) then
        -- Moving to mysql is a fresh start there: nothing is carried over,
        -- and mysql mode refuses to start while this store still holds
        -- money (README, Changing storage mode).
        Log.debug(('json store holds %d contracts; a server this busy is better on '
            .. 'mysql mode, which starts empty: let the open contracts here finish first (see '
            .. 'the README, Changing storage mode)'):format(count))
    end

    return true
end

--- What a json store on disk holds, read without opening it, for a server
--- started in another mode (main.lua's refuseModeSwitch): how many contracts
--- it names, how many escrow lines are not yet settled, how many payouts it
--- still owes players who were offline, the files it could not read, and
--- every contract holding money, with its lines. nil where there is no
--- store here.
---
--- Reads the files only; nothing in this module is touched, so the store it
--- describes is exactly as it was left.
---
--- A contract file the index names and cannot read is not a contract that
--- holds nothing: nobody can tell what it holds, and the start in this mode
--- would quarantine it and say so every boot until the file is restored. It
--- is listed in `unreadable`, and a payout queued against it counts as owed
--- (restoring the file brings its line back, and the queue entry is what
--- delivers it). A queued payout whose line was read and is settled, or is
--- not there, is not owed: a payout handed over at once leaves its entry
--- behind until the player's next login (Escrow.retryPending drops it).
---@return table|nil { contracts, lines, owed, unreadable = { { id, file } }, holding = { { id, contract, lines, hitmen } } }
--- The review items still waiting for staff (open, or left part-way
--- resolved), as inspect lists them for a start in another mode: each one's
--- id, kind, contract, state, the money it records (its own amount and every
--- line of money it names) and how many goods, oldest first.
---@param reviews table|nil the store's reviews, by id
---@return table[]
local function openReviews(reviews)
    local out = {}
    for key, item in pairs(type(reviews) == 'table' and reviews or {}) do
        if type(item) == 'table' and (item.state == 'open' or item.state == 'resolving') then
            local money, goods = tonumber(item.amount) or 0, 0
            for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
                if type(entry) == 'table' then
                    if entry.source == 'item' or entry.source == 'weapon' then
                        goods = goods + 1
                    else
                        money = money + (tonumber(entry.amount) or 0)
                    end
                end
            end
            out[#out + 1] = { id = tostring(item.id or key), kind = item.kind,
                contract_id = item.contract_id, state = item.state, account = item.account,
                money = math.floor(money), goods = goods, created_at = tonumber(item.created_at) or 0 }
        end
    end
    table.sort(out, function(a, b)
        if a.created_at ~= b.created_at then return a.created_at < b.created_at end
        return a.id < b.id
    end)
    return out
end

function JsonStore.inspect()
    -- Each file as open() would find it: the last complete write of one
    -- that is missing or torn (recoverFile), read where it lies.
    local function readJson(file)
        local value = decodeTable(LoadResourceFile(resource, file))
        if value then return value end
        local _, copy = recoverFile(file, decodeTable, false)
        return copy
    end

    local raw = LoadResourceFile(resource, path())
    local index = decodeTable(raw)
    if index then
        -- The newer whole copy open() would use (newerIndex).
        local fresh = newerIndex(raw)
        index = fresh and decodeTable(fresh) or index
    else
        index = readJson(path())
    end
    if not index then
        if raw == nil or raw == '' then return nil end
        -- Nobody can tell what it holds, so it is not taken to hold nothing.
        return { contracts = 0, lines = 0, owed = 0, unreadable = { { file = path() } },
                 holding = {} }
    end

    local out = { contracts = 0, lines = 0, owed = 0, holding = {} }
    local unreadable, unreadIds, lines, byId = {}, {}, {}, {}
    -- `contractOf(id)` is the contract row a line's contract id names.
    local function held(id, contractOf, escrow, hitmen)
        for key, line in pairs(type(escrow) == 'table' and escrow or {}) do
            if type(line) == 'table' then
                local lineId = line.id or key
                -- A line of the single-file layout that names no contract is
                -- still money, listed under no contract.
                local owner = id or line.contract_id or '(no contract)'
                lines[lineId] = line
                if line.state ~= CH.ESCROW_STATE.SETTLED then
                    out.lines = out.lines + 1
                    local entry = byId[owner]
                    if not entry then
                        local who = {}
                        for _, h in pairs(type(hitmen) == 'table' and hitmen or {}) do
                            if type(h) == 'table' and h.hitman_cid
                                and (h.contract_id == nil or h.contract_id == owner) then
                                who[h.hitman_cid] = true
                            end
                        end
                        local row = contractOf(owner)
                        entry = { id = owner, contract = type(row) == 'table' and row or nil,
                                  lines = {}, hitmen = who }
                        byId[owner] = entry
                        out.holding[#out.holding + 1] = entry
                    end
                    entry.lines[#entry.lines + 1] = line
                end
            end
        end
    end

    -- The single-file layout of an older version holds it all in the index.
    if type(index.contracts) == 'table' then
        for _ in pairs(index.contracts) do out.contracts = out.contracts + 1 end
        held(nil, function(id) return index.contracts[id] end, index.escrow, index.hitmen)
    end
    local named = {}
    for _, id in ipairs(type(index.contractIds) == 'table' and index.contractIds or {}) do
        named[tostring(id)] = true
        out.contracts = out.contracts + 1
        local file = shardPath(id)
        local shard = file and readJson(file)
        if shard then
            held(id, function() return shard.contract end, shard.escrow, shard.hitmen)
        else
            unreadable[#unreadable + 1] = { id = tostring(id), file = file or tostring(id) }
            unreadIds[tostring(id)] = true
        end
    end
    -- And a contract file the index does not name that a start would take
    -- back in (W158, adoptable): money there is money here.
    if type(index.contractIds) == 'table' then
        for _, id in ipairs(unnamedShards(named)) do
            local shard = readShard(id)
            if adoptable(shard, id, index) then
                out.contracts = out.contracts + 1
                held(id, function() return shard.contract end, shard.escrow, shard.hitmen)
            end
        end
    end
    table.sort(out.holding, function(a, b) return tostring(a.id) < tostring(b.id) end)

    local pending, reviews = index.pending, index.reviews
    if pending == nil or reviews == nil then
        local records = readJson(recordsPath())
        if pending == nil then pending = records and records.pending or nil end
        if reviews == nil then reviews = records and records.reviews or nil end
    end
    -- Money waiting for staff in the review queue (W155): an item is the only
    -- record of a payment no rule could settle, and the new mode's queue
    -- starts empty.
    out.reviews = openReviews(reviews)
    for _, p in pairs(type(pending) == 'table' and pending or {}) do
        if type(p) == 'table' then
            local line = lines[p.line_id]
            if line ~= nil then
                if line.state ~= CH.ESCROW_STATE.SETTLED then out.owed = out.owed + 1 end
            elseif (p.contract_id ~= nil and unreadIds[tostring(p.contract_id)])
                or (p.contract_id == nil and #unreadable > 0) then
                out.owed = out.owed + 1
            end
        end
    end
    if #unreadable > 0 then out.unreadable = unreadable end
    return out
end

--- When the console last said contract files were left unwritten, so it
--- says so at most every UNWRITTEN_SAY_SECONDS while they stay that way.
local unwrittenSaidAt = nil
local UNWRITTEN_SAY_SECONDS = 300

--- Say which contract files could not be written, once for all of them.
local function sayUnwritten(ids)
    local now = os.time()
    if unwrittenSaidAt and now - unwrittenSaidAt < UNWRITTEN_SAY_SECONDS then return end
    unwrittenSaidAt = now
    table.sort(ids)
    local shown = {}
    for i = 1, math.min(#ids, 5) do shown[i] = ids[i] end
    Log.always(('%d contract file(s) could not be written and are kept in memory: %s%s; '
        .. 'the next flush retries. Check that the server can write to %s/contracts/ and that '
        .. 'nothing (a backup tool, an antivirus, an editor) holds those files open.')
        :format(#ids, table.concat(shown, ', '), #ids > #shown and ' and others' or '',
            directory()))
end

--- Write what changed.
---
--- `force` writes every dirty shard; an ordinary flush writes at most
--- MaxDirtyShardsPerFlush of them and leaves the rest for the next one, so a
--- burst of activity cannot turn one flush into an unbounded stall.
---
--- `money` is a money write's save (touch): the contract files money writes
--- changed (urgentShards) and every changed one the index on disk does not
--- name yet, then the index and the records, and nothing else. It used to
--- write every changed file, so one coin moving after 275 contracts had a
--- message each wrote 275 files inside the player's request. The others are
--- the flush's. And the index never names a file that is not on disk: one
--- it does not name yet is written by every save, budget or not, since the
--- index written with it names it.
---
--- Not the audit log: a financial write calls this, and the log waits for
--- the flush (JsonStore.flush, JsonStore.close).
---
--- One contract file the disk refuses (an antivirus, a backup tool or an
--- editor holding it on Windows) is skipped, and every other one is still
--- written. It used to stop the walk, so the contracts after it in pairs()
--- order had their escrow in memory only, on every save while that one file
--- stayed locked, and the save still answered true: a crash then lost that
--- money with nothing having said so. A save that left any dirty file
--- unwritten answers false, with the first file it could not write.
---@return boolean saved nothing it was asked to write was left unwritten
---@return string|nil file the first file that could not be written
function JsonStore.save(force, money)
    if not db then return false end
    -- Nothing changed, so nothing is left unwritten.
    if not force and not dirty then return true end

    local budget = (force and not money) and math.huge
        or (Config.Database.Json.MaxDirtyShardsPerFlush or 25)
    local written, failed = 0, {}

    for id in pairs(dirtyShards) do
        -- Never left out of an index naming it (any write of the index), nor
        -- out of the money write that changed it.
        local must = not indexedIds[id] or (money and urgentShards[id])
        if must or (not money and written < budget) then
            local file = shardPath(id)
            if not file then
                -- Not a shape this store mints, so not something to name a
                -- file after. Dropped rather than written.
                dirtyShards[id], urgentShards[id] = nil, nil
            elseif writeFile(file, shardOf(id), true) then
                -- The index is not marked for this. A contract it does not
                -- name yet marked it when it was touched (touch); one it
                -- already names has nothing new to say there. Marking it here
                -- rewrote the index on every money write, which is the write
                -- that used to carry the whole ledger.
                dirtyShards[id], urgentShards[id] = nil, nil
                written = written + 1
            else
                -- Left dirty deliberately: a shard that did not land is
                -- retried on the next flush rather than forgotten. And the
                -- walk goes on.
                failed[#failed + 1] = id
            end
        end
    end
    local failedFile = failed[1] and shardPath(failed[1]) or nil
    if #failed > 0 then sayUnwritten(failed) end

    -- Only when something in it changed: `force` means every dirty shard,
    -- not every file whatever it holds.
    local indexOk = true
    if indexDirty then
        db.seq = seq
        indexOk = writeIndex()
        if indexOk then indexDirty = false end
    end
    if not indexOk then failedFile = failedFile or path() end

    -- After the index, and only once it is on disk. A pending payout's id is
    -- minted from the sequence the index holds; written ahead of it, a crash
    -- in between would leave a row on disk whose id the next start mints
    -- again, and the next payout queued under it would land on top of it.
    local recordsOk = true
    if recordsDirty and indexOk then
        recordsOk = writeRecords()
        if not recordsOk then failedFile = failedFile or recordsPath() end
    end

    if not next(dirtyShards) and not indexDirty and not recordsDirty then
        dirty = false
    end
    -- A flush that could not write the index did not flush. Saying it did
    -- is what let the store report success while persisting nothing.
    if #failed == 0 and indexOk and recordsOk then return true end
    return false, failedFile
end

--- Mark the store dirty.
---
--- `contractId` names which shard changed; without one the change is in the
--- records (the ledger, a pending payout, a stat, a reveal, a kill photo).
--- Financial writes flush immediately; everything else rides the debounce
--- (§10.2).
local function touch(financial, contractId)
    dirty = true
    if contractId then
        dirtyShards[contractId] = true
        if financial then urgentShards[contractId] = true end
        if not shardIds[contractId] then
            shardIds[contractId] = true
            -- A contract the index does not list is a file nothing will ever
            -- read back.
            indexDirty = true
        end
    else
        recordsDirty = true
    end
    if financial and Config.Database.Json.SyncOnFinancialWrite then
        JsonStore.save(true, true)
    end
end

--- Finished contracts past the retention age that hold nobody's money.
---
--- Nothing pruned contracts, so every full scan in the resource walked the
--- server's whole history rather than its live board and grew without bound
--- for the life of the database.
---
--- Five conditions, and the last three are the ones that matter: terminal,
--- older than the cutoff, holding no escrow line that is not settled, owing
--- nobody anything on their next login, and named by no review item staff
--- have not resolved. A contract whose creator was offline when it closed
--- holds their money in a `held` OWED line with a pending row pointing at
--- it, and removing either would take that money with it.
---
--- A pending row owes something only while the line it names is held or
--- mid-release. A payout handed over at once leaves its row behind until
--- the player's next login (Escrow.retryPending drops it then), and one who
--- never came back held the contract here for good, and every mode switch
--- after it. The line is one of the contract's own, read whole with it.
---
--- A review item's advice is read against the contract ("if it shows the
--- buyout, dismiss"); pruned under an open one, the item read "contract
--- none" and staff refunded a buyout that had already been used. Kept until
--- the item is resolved, and pruned at the first tick after.
local function prunableContracts(cutoff, limit)
    local TERMINAL = {
        completed = true, bailed_out = true, expired = true,
        cancelled = true, voided = true,
    }

    -- The old enough ones first. Nearly every tick there are none, and the
    -- escrow and pending walks below were done before finding that out.
    local aged = {}
    for id, c in pairs(db.contracts) do
        if TERMINAL[c.state] and c.resolved_at and c.resolved_at < cutoff then
            aged[id] = true
        end
    end
    if next(aged) == nil then return {} end

    local holding, owing = {}, {}
    for id in pairs(aged) do
        for lineId, line in pairs(escrowBy[id] or {}) do
            if db.escrow[lineId] == line and line.state ~= 'settled' then holding[id] = true end
        end
    end
    for _, p in pairs(db.pending) do
        if p.contract_id and aged[p.contract_id] then
            local line = db.escrow[p.line_id]
            if line and line.state ~= 'settled' then owing[p.contract_id] = true end
        end
    end
    for _, item in pairs(db.reviews or {}) do
        if type(item) == 'table' and item.contract_id and aged[item.contract_id]
            and (item.state == 'open' or item.state == 'resolving') then
            owing[item.contract_id] = true
        end
    end

    local out = {}
    for id in pairs(aged) do
        if not holding[id] and not owing[id] then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    if limit and #out > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = out[i] end
        return trimmed
    end
    return out
end

function JsonStore.prune()
    local days = Config.Audit.ContractRetentionDays or 0
    if days <= 0 then return true end

    local ids = prunableContracts(os.time() - (days * 86400),
        Config.Audit.ContractsPrunedPerTick or 200)
    if #ids == 0 then return true end

    -- What belongs to them that is not indexed by contract goes in one walk
    -- of each table below, not one walk per contract: with every message
    -- scanned (and shifted, for each one removed) once per contract pruned,
    -- a backlog of 3,000 took over a second of the main thread a tick.
    local gone = {}
    for i = 1, #ids do
        local id = ids[i]
        gone[id] = true
        for lineId, line in pairs(escrowBy[id] or {}) do
            if db.escrow[lineId] == line then db.escrow[lineId] = nil end
        end
        escrowBy[id] = nil
        for hitmanId, hitman in pairs(hitmenBy[id] or {}) do
            if db.hitmen[hitmanId] == hitman then db.hitmen[hitmanId] = nil end
        end
        hitmenBy[id] = nil
        messagesBy[id] = nil
        db.contracts[id] = nil

        -- Off the index first, so a crash between here and the unlink
        -- leaves a file nothing reads rather than an index entry pointing
        -- at a file that is gone.
        shardIds[id] = nil
        dirtyShards[id], urgentShards[id] = nil, nil
        -- Through the resource's own folder. SaveResourceFile resolves a
        -- path against the resource; os.remove resolves it against the
        -- server process's working directory, which is the server-data
        -- folder. So the relative path named a file that does not exist
        -- there, the unlink failed in silence, and every pruned contract's
        -- file stayed on disk for good.
        local file = shardPath(id)
        if file then
            pendingUnlinks[#pendingUnlinks + 1] = file
            -- And every copy beside it, which nothing would read again
            -- either: the .new a server that refuses renames keeps
            -- (writeRaw), the .old a Windows swap could not remove
            -- (moveOver), and a torn one set aside (recoverFile).
            pendingUnlinks[#pendingUnlinks + 1] = file .. NEW
            pendingUnlinks[#pendingUnlinks + 1] = file .. OLD
            pendingUnlinks[#pendingUnlinks + 1] = file .. '.torn'
        end
    end

    for amendmentId, amendment in pairs(db.amendments) do
        if gone[amendment.contract_id] then db.amendments[amendmentId] = nil end
    end
    local messages, kept = db.messages, 0
    for j = 1, #messages do
        local m = messages[j]
        if not gone[m.contract_id] then
            kept = kept + 1
            messages[kept] = m
        end
    end
    for j = #messages, kept + 1, -1 do messages[j] = nil end
    for key, row in pairs(db.reveals) do
        if gone[row.contract_id] then
            db.reveals[key] = nil
            recordsDirty = true
        end
    end
    for key, row in pairs(db.mutes) do
        if gone[row.contract_id] then db.mutes[key] = nil end
    end

    -- The index that no longer names them goes to disk first, and the files
    -- only after it has. Unlinked first, a crash before the next flush left
    -- store.json naming a file that was gone, and the contract was
    -- quarantined as missing, with its warning, on every boot after.
    if #pendingUnlinks > 0 then
        if writeIndex() then
            indexDirty = false
        else
            indexDirty = true
        end
    end
    dirty = true
    return true
end

--- The audit log is written here and at close, and nowhere else: the queue
--- in server/audit.lua already holds rows until the tick, and a coin moving
--- is no reason to write the log.
---
--- Answers whether everything it was asked to write is on disk, and the
--- first file that is not (the admin panel names it).
---@return boolean saved
---@return string|nil file
local function playtimePath()
    return directory() .. '/playtime.json'
end

--- The tracker's file, read once. Missing is a tracker that has not started
--- on this store yet. Torn, its last whole write is put back (recoverFile);
--- with none, the torn one is kept as playtime.json.torn, said, and the
--- tracker starts again from nothing: counted time is not money, and
--- refusing to start over it would stop every contract.
local function playtimeData()
    if playtime then return playtime end
    local raw = LoadResourceFile(resource, playtimePath())
    local decoded = decodeTable(raw)
    if not decoded then
        local _, copy = recoverFile(playtimePath(), decodeTable, true, raw)
        decoded = copy
    end
    if not decoded and type(raw) == 'string' and raw ~= '' then
        SaveResourceFile(resource, playtimePath() .. '.torn', raw, -1)
        Log.always(('%s could not be read and there is no whole copy of it; it is kept as %s.torn, '
            .. 'and playtime is counted again from nothing, as at its first start.')
            :format(playtimePath(), playtimePath()))
    end
    decoded = decoded or {}
    playtimeText = {}
    playtime = {
        since = tonumber(decoded.since),
        players_id = tonumber(decoded.players_id),
        rows = type(decoded.rows) == 'table' and decoded.rows or {},
    }
    return playtime
end

--- Write the tracker's file whole, when something in it changed.
---@return boolean written
---@return string|nil file the file, when it could not be written
local function savePlaytime()
    if not playtimeDirty or not playtime then return true end
    local rows = {}
    for cid, row in pairs(playtime.rows) do
        local text = playtimeText[cid]
        if not text then
            text = json.encode(tostring(cid)) .. ':' .. json.encode(row)
            playtimeText[cid] = text
        end
        rows[#rows + 1] = text
    end
    local fields = {}
    if playtime.since ~= nil then fields[#fields + 1] = '"since":' .. json.encode(playtime.since) end
    if playtime.players_id ~= nil then
        fields[#fields + 1] = '"players_id":' .. json.encode(playtime.players_id)
    end
    fields[#fields + 1] = '"rows":{' .. table.concat(rows, ',') .. '}'
    if not writeRaw(playtimePath(), '{' .. table.concat(fields, ',') .. '}') then
        return false, playtimePath()
    end
    playtimeDirty = false
    return true
end

function JsonStore.flush()
    -- The alerts changed since the records were written, which only this
    -- and the close take in (alertsDirty).
    if alertsDirty then dirty, recordsDirty = true, true end
    local ok, file = JsonStore.save(false)
    local logged, day = saveAudit()
    local counted, playtimeFile = savePlaytime()
    return ok and logged and counted, file or day or playtimeFile
end

function JsonStore.close()
    if alertsDirty then dirty, recordsDirty = true, true end
    local ok, file = JsonStore.save(true)
    local logged, day = saveAudit()
    local counted, playtimeFile = savePlaytime()
    return ok and logged and counted, file or day or playtimeFile
end

--------------------------------------------------------------------------
-- Playtime
--------------------------------------------------------------------------

--- See the memory backend. In playtime.json, written by the next flush or
--- the close, never by a money write's save.
function JsonStore.readPlaytime(cid)
    local row = playtimeData().rows[cid]
    return type(row) == 'table' and Util.copy(row) or nil
end

function JsonStore.writePlaytime(rows)
    local data = playtimeData()
    for i = 1, #rows do
        data.rows[rows[i].cid] = Util.copy(rows[i])
        playtimeText[rows[i].cid] = nil
    end
    playtimeDirty = true
    return true
end

function JsonStore.readPlaytimeInstall()
    local data = playtimeData()
    if not data.since then return nil end
    return { since = data.since, players_id = data.players_id }
end

function JsonStore.writePlaytimeInstall(since, playersId)
    local data = playtimeData()
    data.since, data.players_id = since, playersId
    playtimeDirty = true
    return true
end

--- What one buyer's informant purchases on one contract have bought; see the
--- memory backend. Financial: it is the record of a fee that is never given
--- back, and what stops the next purchase charging it again.
function JsonStore.readReveal(contractId, buyerCid)
    return db.reveals[contractId .. ':' .. buyerCid]
end

function JsonStore.writeReveal(contractId, buyerCid, record)
    local row = {}
    for k, v in pairs(record) do row[k] = v end
    row.contract_id, row.buyer_cid = contractId, buyerCid
    db.reveals[contractId .. ':' .. buyerCid] = row
    touch(true)
    return true
end

function JsonStore.clearReveals(contractId)
    local cleared = false
    for key, row in pairs(db.reveals) do
        if row.contract_id == contractId then
            db.reveals[key] = nil
            cleared = true
        end
    end
    if cleared then touch(false) end
    return true
end

--------------------------------------------------------------------------
-- The review queue
--------------------------------------------------------------------------

--- See the memory backend. In records.json, and every write is financial:
--- an item is the only record of money no rule settles, and a resolution
--- the only record that it was.
function JsonStore.writeReview(item)
    if db.reviews[item.id] then return true end
    local row = {}
    for k, v in pairs(item) do row[k] = v end
    db.reviews[row.id] = row
    touch(true)
    return true
end

function JsonStore.readReview(id)
    return db.reviews[id]
end

function JsonStore.reviewItems(open, limit)
    local out = {}
    for _, row in pairs(db.reviews) do
        if not open or row.state == 'open' or row.state == 'resolving' then
            out[#out + 1] = row
        end
    end
    table.sort(out, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then
            if open then return (a.created_at or 0) < (b.created_at or 0) end
            return (a.created_at or 0) > (b.created_at or 0)
        end
        return a.id < b.id
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function JsonStore.setReviewState(id, expected, next_, fields)
    local row = db.reviews[id]
    if not row or row.state ~= expected then return false end
    row.state = next_
    row.resolution, row.resolved_by, row.resolved_at =
        fields.resolution, fields.resolved_by, fields.resolved_at
    touch(true)
    return true
end

--------------------------------------------------------------------------
-- Settings changed from the admin panel
--------------------------------------------------------------------------

--- See the memory backend. In records.json, and written at once as a money
--- write is: a staff member who turns a feature off and restarts the
--- server a moment later expects it to be off when it comes back.
function JsonStore.readSettings()
    local out = {}
    for key, row in pairs(db.settings or {}) do
        if type(row) == 'table' then
            out[key] = { value = Util.copy(row.value), by = row.by, at = row.at }
        end
    end
    return out
end

function JsonStore.writeSetting(key, value, by, at)
    db.settings = db.settings or {}
    db.settings[key] = { value = Util.copy(value), by = by, at = at }
    touch(true)
    return true
end

function JsonStore.deleteSetting(key)
    if db.settings then db.settings[key] = nil end
    touch(true)
    return true
end

function JsonStore.clearSettings()
    db.settings = {}
    touch(true)
    return true
end

--------------------------------------------------------------------------
-- The admin panel's alerts
--------------------------------------------------------------------------

--- See the memory backend. In records.json, written by the next flush or
--- the close, never by a money write's save (alertsDirty).
function JsonStore.readAlerts()
    local out = {}
    for _, row in pairs(db.alerts or {}) do
        if type(row) == 'table' then out[#out + 1] = Util.copy(row) end
    end
    return out
end

function JsonStore.writeAlert(row)
    db.alerts = db.alerts or {}
    db.alerts[row.id] = Util.copy(row)
    alertsDirty = true
    return true
end

function JsonStore.deleteAlert(id)
    if db.alerts and db.alerts[id] ~= nil then
        db.alerts[id] = nil
        alertsDirty = true
    end
    return true
end

--------------------------------------------------------------------------
-- The whitelisted-job view's Notify me
--------------------------------------------------------------------------

--- See the memory backend. In records.json with the stats, and written at
--- once, as a setting staff change is: a crash in the seconds before the
--- next save lost a choice the player had just been told was made. A
--- change is rare, and rate-limited (Config.Cooldowns.message).
function JsonStore.readViewAlerts(cid)
    return (db.viewAlerts or {})[cid] ~= nil
end

function JsonStore.setViewAlerts(cid, on, at)
    db.viewAlerts = db.viewAlerts or {}
    if on then
        db.viewAlerts[cid] = { cid = cid, set_at = at }
    else
        db.viewAlerts[cid] = nil
    end
    touch(true)
    return true
end

--- When this process was last known to be running.
---
--- A file of its own rather than a field in the index: the index is
--- rewritten only when something in it changed (a new contract, the
--- sequence, a new day of audit log), and this changes on every tick.
local function heartbeatPath()
    return directory() .. '/heartbeat.json'
end

--- How often the tick's heartbeat is written, in seconds. The start and a
--- stop write it whatever this says (`force`).
JsonStore.HEARTBEAT_EVERY = 60

---
--- One plain SaveResourceFile, at most once every HEARTBEAT_EVERY seconds.
--- It was written whole and renamed over on every tick, as the files that
--- hold money are (writeRaw): four file operations every ten seconds, and
--- some 34 ms a tick on a Windows host, for seventeen bytes. A crash that
--- tears it costs nothing: the start then dates the downtime from what else
--- it read (JsonStore.lastHeartbeat), as it does for a missing one. The
--- coarser stamp dates a downtime up to a minute early, which pauses the
--- running contracts for that much longer, never shorter: no deadline is
--- charged for time nobody could play. Quiet, as it always was: a server
--- that cannot write here cannot write the index either, and that is said.
---@param at integer os.time()
---@param force boolean|nil written whatever the interval says: the start, a stop
---@return boolean
function JsonStore.heartbeat(at, force)
    at = tonumber(at)
    if not at then return false end
    if not force and heartbeatWrittenAt and at >= heartbeatWrittenAt
        and at - heartbeatWrittenAt < JsonStore.HEARTBEAT_EVERY then
        return true
    end
    if SaveResourceFile(resource, heartbeatPath(), json.encode({ at = at }), -1) ~= false then
        heartbeatWrittenAt = at
    end
    return true
end

--- When the server was last known to be running, and, where the heartbeat
--- file itself was not whole, what that was read from instead.
---
--- The latest of everything this start read that the server wrote while it
--- ran: the heartbeat (or, torn, its last whole copy a version that renamed
--- it left), the newest audit row, and when the index was written. Each is
--- a moment the server was running, so the downtime is dated from no later
--- than it began, and a contract is paused for at least as long as nobody
--- could play. The heartbeat is written once a minute, so a row or an index
--- written after it dates the end more closely.
---@return integer|nil at
---@return string|nil from nil when the heartbeat file itself was whole
function JsonStore.lastHeartbeat()
    local function at(raw)
        local decoded = decodeTable(raw)
        return decoded and tonumber(decoded.at) or nil
    end
    local found = at(LoadResourceFile(resource, heartbeatPath()))
    local best, from = found, nil
    if not found then
        local _, copy, copyName = recoverFile(heartbeatPath(), at, false)
        if copy then best, from = copy, copyName end
    end
    local audit, index = lastKnown.audit, lastKnown.index
    if audit and (best == nil or audit > best) then
        best, from = audit, (not found) and 'the newest audit row' or nil
    end
    if index and (best == nil or index > best) then
        best, from = index, (not found) and ('the last time %s was written'):format(path()) or nil
    end
    return best, from
end

--- The sequence is the index's, so this marks the index, not the records.
function JsonStore.nextId(prefix)
    seq = seq + 1
    indexDirty, dirty = true, true
    return string.format('%s%08d', prefix, seq)
end

--------------------------------------------------------------------------
-- Contracts
--------------------------------------------------------------------------

--- Contracts this player is involved in, as creator, target or hitman.
function JsonStore.contractsInvolving(cid)
    local seen, out = {}, {}

    for _, c in pairs(db.contracts) do
        if c.creator_cid == cid or c.target_cid == cid then
            seen[c.id] = true
            out[#out + 1] = c
        end
    end

    for _, h in pairs(db.hitmen) do
        if h.hitman_cid == cid and not seen[h.contract_id] then
            local c = db.contracts[h.contract_id]
            if c then
                seen[c.id] = true
                out[#out + 1] = c
            end
        end
    end

    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function JsonStore.contractsNaming(cid)
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.target_cid == cid then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts with a buyout waiting out its delay.
function JsonStore.queuedBailouts()
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.bailout_queued_at then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function JsonStore.contractsBy(cid)
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.creator_cid == cid then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts created by any character on this account. The creator-side
--- limits belong to the player, not to whichever character they are on.
function JsonStore.contractsByAccount(account)
    local out = {}
    if account == nil then return out end
    for _, c in pairs(db.contracts) do
        if c.creator_account == account then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- State is not written here: it changes only through
--- compareSetContractState, so a stale copy cannot revert a transition.
--- The buyout queue columns, which move ONLY through setBailoutQueue.
---
--- Any caller that reads a contract, works, and writes it back carries the
--- queue fields it read. Between that read and that write a target can pay for
--- a buyout — on mysql every read is an await, so another handler runs in the
--- gap — and the stale copy then lands on top of it: the premium charged, the
--- queue erased, nothing that will ever settle or refund it. Eight callers
--- have that read-work-write shape. The codebase had already found this hazard
--- twice and fixed it for one of them (advanceSlot, for claimSlot); the queue
--- itself got nothing. So these fields leave writeContract entirely, the way
--- `state` moves only through compareSetContractState.
local BAILOUT_QUEUE = {
    'bailout_queued_at', 'bailout_paid_by', 'bailout_paid_amount',
    'bailout_paid_account', 'bailout_attempts',
}

--- The payout counters, which move ONLY through advanceSlot; see the memory
--- backend.
local SLOT_COUNTERS = { 'next_slot', 'slots_claimed', 'payout_slots' }

--- The clock, which moves only through the narrow writes below; see the
--- memory backend.
local CLOCK = { 'deadline_at', 'paused_ms', 'paused_since' }

--- The terms a contract was placed under and never changes; see the memory
--- backend.
local TERMS = { 'fulfilment_rule' }

--- What the law enforcement advisory said of a contract, which moves only
--- through setAdvised; see the memory backend.
local ADVISED = { 'advised_posted_at', 'advised_hitmen' }

--- The handover's meeting point, which moves only through setMeeting,
--- clearMeeting and dropMeeting; see the memory backend.
local MEETING = { 'meeting_x', 'meeting_y', 'meeting_at' }

function JsonStore.writeContract(c)
    local existing = db.contracts[c.id]
    if existing and existing ~= c then
        c.state = existing.state
        for i = 1, #BAILOUT_QUEUE do
            c[BAILOUT_QUEUE[i]] = existing[BAILOUT_QUEUE[i]]
        end
        for i = 1, #SLOT_COUNTERS do
            c[SLOT_COUNTERS[i]] = existing[SLOT_COUNTERS[i]]
        end
        for i = 1, #CLOCK do
            c[CLOCK[i]] = existing[CLOCK[i]]
        end
        for i = 1, #TERMS do
            c[TERMS[i]] = existing[TERMS[i]]
        end
        for i = 1, #ADVISED do
            c[ADVISED[i]] = existing[ADVISED[i]]
        end
        for i = 1, #MEETING do
            c[MEETING[i]] = existing[MEETING[i]]
        end
    end
    db.contracts[c.id] = c
    touch(true, c.id)
    return true
end

--- Store a new contract, and never write over one already there; see the
--- memory backend.
function JsonStore.insertContract(c)
    if db.contracts[c.id] then return true end
    return JsonStore.writeContract(c)
end

--- End a contract as expired only if it is still due: past its lifetime,
--- or past a deadline whose clock is running. The expiry pass decides on
--- a read, and a deadline the client extended in the await after it was
--- expired all the same, forfeiting the stake of the hitman it was
--- extended for.
function JsonStore.expireIfDue(id, expected, next_, now, byLifetime)
    local c = db.contracts[id]
    if not c or c.state ~= expected then return false end
    if byLifetime then
        if not (c.expires_at and now > c.expires_at) then return false end
    elseif c.paused_since ~= nil or not (c.deadline_at and now > c.deadline_at) then
        return false
    end
    c.state = next_
    touch(true, id)
    return true
end

--- Take the last collection off sale, guarded on everything the decision
--- rested on: the count, that the collection is still unclaimed, and that
--- no claim holds the contract. On the count alone, a claim landing between
--- the decision and this write advanced onto the very collection being
--- removed, and the contract was left selling a collection past its end.
function JsonStore.reduceSlots(id, expected)
    local c = db.contracts[id]
    if not c or (c.payout_slots or 1) ~= expected or expected <= 1 then return false end
    if (c.next_slot or 1) >= expected then return false end
    if c.state ~= 'active' and c.state ~= 'accepted' then return false end
    c.payout_slots = expected - 1
    touch(true, id)
    return true
end

function JsonStore.setDeadline(id, expected, deadline)
    local c = db.contracts[id]
    if not c then return false end
    if expected ~= nil and c.deadline_at ~= expected then return false end
    c.deadline_at = deadline
    touch(true, id)
    return true
end

--- Write only the named fields of a contract. Every other writer used to
--- read the row, await, and write the whole copy back, undoing whatever
--- changed in between: a re-clamp of the buyout and stake, a bonus raise,
--- an ending's resolution. Only these columns, and never the state, the
--- slot counters, the clock or the buyout queue, which have their own.
local SETTABLE = { reason = true, mode = true, bonus_percent = true, bailout_amount = true,
    penalty_amount = true, resolved_at = true, resolution = true, expires_at = true }
function JsonStore.setContractFields(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for k, v in pairs(fields) do
        if not SETTABLE[k] then error('setContractFields: not a settable field: ' .. tostring(k)) end
        c[k] = v
    end
    touch(true, id)
    return true
end

function JsonStore.setReason(id, reason)
    local c = db.contracts[id]
    if not c then return false end
    c.reason = reason
    touch(true, id)
    return true
end

function JsonStore.startPause(id, at)
    local c = db.contracts[id]
    if not c or c.paused_since ~= nil then return false end
    c.paused_since = at
    touch(true, id)
    return true
end

function JsonStore.endPause(id, since, seconds)
    local c = db.contracts[id]
    if not c or c.paused_since ~= since then return false end
    c.deadline_at = (c.deadline_at or 0) + seconds
    c.paused_ms = (c.paused_ms or 0) + seconds * 1000
    c.paused_since = nil
    touch(true, id)
    return true
end

--- Set or clear the buyout queue on one contract. nil clears it.
function JsonStore.setBailoutQueue(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for i = 1, #BAILOUT_QUEUE do
        c[BAILOUT_QUEUE[i]] = fields and fields[BAILOUT_QUEUE[i]] or nil
    end
    touch(true, id)
    return true
end

--- Record a paid buyout, a compare-and-set; see the memory backend.
function JsonStore.recordBailout(id, fields)
    local c = db.contracts[id]
    if not c or (c.state ~= 'active' and c.state ~= 'accepted') then return false end
    if c.bailout_queued_at ~= nil and (c.bailout_queued_at ~= fields.bailout_queued_at
        or c.bailout_paid_by ~= fields.bailout_paid_by) then
        return false
    end
    return JsonStore.setBailoutQueue(id, {
        bailout_queued_at = fields.bailout_queued_at, bailout_paid_by = fields.bailout_paid_by,
        bailout_paid_amount = fields.bailout_paid_amount,
        bailout_paid_account = fields.bailout_paid_account, bailout_attempts = 0,
    })
end

--- Clear the buyout queue only while it holds the buyout recorded at
--- `queuedAt`; see the memory backend.
function JsonStore.clearBailout(id, queuedAt)
    local c = db.contracts[id]
    if not c or c.bailout_queued_at == nil or c.bailout_queued_at ~= queuedAt then return false end
    return JsonStore.setBailoutQueue(id, nil)
end

--- Keep what an advisory bulletin said of one contract; see the memory
--- backend.
local ADVISED_FIELD = { advised_posted_at = true, advised_hitmen = true }
function JsonStore.setAdvised(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for k, v in pairs(fields) do
        if not ADVISED_FIELD[k] then error('setAdvised: not an advisory field: ' .. tostring(k)) end
        c[k] = v
    end
    touch(true, id)
    return true
end

--- Set the meeting point, a compare-and-set; see the memory backend.
--- Written to disk at once, as an advisory's record is: a restart keeps it.
function JsonStore.setMeeting(id, x, y, at, notBefore)
    local c = db.contracts[id]
    if not c or c.state ~= 'accepted' then return false end
    if c.meeting_at ~= nil and c.meeting_at > notBefore then return false end
    c.meeting_x, c.meeting_y, c.meeting_at = x, y, at
    touch(true, id)
    return true
end

--- The placer clears it; see the memory backend.
function JsonStore.clearMeeting(id, at, notBefore)
    local c = db.contracts[id]
    if not c or c.meeting_x == nil then return false end
    if c.meeting_at ~= nil and c.meeting_at > notBefore then return false end
    c.meeting_x, c.meeting_y, c.meeting_at = nil, nil, at
    touch(true, id)
    return true
end

--- Take it off a contract nobody can meet on any more; see the memory
--- backend. Nothing is written for a contract that has none, so an ending
--- costs no save for it.
function JsonStore.dropMeeting(id)
    local c = db.contracts[id]
    if not c or c.meeting_x == nil then return false end
    c.meeting_x, c.meeting_y = nil, nil
    touch(true, id)
    return true
end

function JsonStore.readContract(id) return db.contracts[id] end

function JsonStore.allContracts()
    local out = {}
    for _, c in pairs(db.contracts) do out[#out + 1] = c end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- How many contracts are in each state. See the memory backend.
function JsonStore.countContractsByState()
    local out = {}
    for _, c in pairs(db.contracts) do out[c.state] = (out[c.state] or 0) + 1 end
    return out
end

--- Contracts still running, active or accepted. See the memory backend.
function JsonStore.liveContracts()
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.state == 'active' or c.state == 'accepted' then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Advance the payout slot, only if it is still the one the caller acted on.
--- See the memory backend for why claimSlot may not write back a snapshot.
function JsonStore.advanceSlot(id, expectedSlot)
    local c = db.contracts[id]
    if not c or (c.next_slot or 1) ~= expectedSlot then return false end
    c.next_slot = expectedSlot + 1
    c.slots_claimed = (c.slots_claimed or 0) + 1
    touch(true, id)
    return true
end

--- No yield between the read and the write, so this is atomic with respect
--- to other handlers on the same tick (§14.3).
function JsonStore.compareSetContractState(id, expected, next_)
    local c = db.contracts[id]
    if not c or c.state ~= expected then return false end
    c.state = next_
    touch(true, id)
    return true
end

--------------------------------------------------------------------------
-- Escrow
--------------------------------------------------------------------------

--- State and amount are preserved from the stored row; see the memory
--- backend for why.
function JsonStore.writeEscrow(contractId, lines)
    for i = 1, #lines do
        local incoming = lines[i]
        local existing = db.escrow[incoming.id]
        if existing and existing ~= incoming then
            existing.owed_to = incoming.owed_to
            existing.releasing_to = incoming.releasing_to
            if incoming.deliver_raises ~= nil then
                existing.deliver_raises = incoming.deliver_raises
            end
            if incoming.deliver_before ~= nil then
                existing.deliver_before = incoming.deliver_before
            end
            if incoming.deliver_arrived ~= nil then
                existing.deliver_arrived = incoming.deliver_arrived
            end
        else
            if existing then unindexRow(escrowBy, existing, incoming.id) end
            db.escrow[incoming.id] = incoming
            indexRow(escrowBy, incoming, incoming.id)
        end
    end
    touch(true, contractId)
    return true
end

--- Store a take's lines, each only where its id is not there yet; see the
--- memory backend.
function JsonStore.insertEscrow(contractId, lines)
    local fresh = {}
    for i = 1, #lines do
        if db.escrow[lines[i].id] == nil then fresh[#fresh + 1] = lines[i] end
    end
    if #fresh == 0 then return true end
    return JsonStore.writeEscrow(contractId, fresh)
end

function JsonStore.readEscrow(contractId)
    local out = {}
    for id, line in pairs(escrowBy[contractId] or {}) do
        if db.escrow[id] == line then out[#out + 1] = line end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function JsonStore.readEscrowLine(id) return db.escrow[id] end

--- Escrow not yet settled whose contract does not exist; see the memory
--- backend. A shard holding escrow and no contract row loads as exactly
--- that. A contract whose shard could not be read is not here: its lines
--- were in the file that could not be read.
function JsonStore.orphanEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state ~= CH.ESCROW_STATE.SETTLED and not db.contracts[line.contract_id] then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Escrow not yet settled whose give has raised `limit` times or more; see
--- the memory backend.
function JsonStore.parkedEscrow(limit)
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state ~= CH.ESCROW_STATE.SETTLED
            and (tonumber(line.deliver_raises) or 0) >= limit then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Held escrow owed to somebody; see the memory backend.
function JsonStore.owedHeldEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.HELD and line.owed_to ~= nil then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Escrow `releasing`; see the memory backend.
function JsonStore.releasingEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.RELEASING then out[#out + 1] = line end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Every escrow line not settled yet, held or mid-release. See the memory
--- backend.
function JsonStore.unsettledEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.HELD or line.state == CH.ESCROW_STATE.RELEASING then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Every contract holding an escrow line that is not settled, as a set.
--- See the memory backend.
function JsonStore.unsettledEscrowContracts()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state ~= CH.ESCROW_STATE.SETTLED and line.contract_id ~= nil then
            out[line.contract_id] = true
        end
    end
    return out
end

--- Held escrow owed to nobody and naming no give, of a closed contract; see
--- the memory backend.
---@param limit integer
function JsonStore.strandedEscrow(limit)
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.HELD and line.owed_to == nil
            and line.releasing_to == nil then
            local contract = db.contracts[line.contract_id]
            if contract and CH.TERMINAL[contract.state] then out[#out + 1] = line end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    for i = #out, (tonumber(limit) or #out) + 1, -1 do out[i] = nil end
    return out
end

function JsonStore.claimEscrowLine(id, expected, next_)
    local line = db.escrow[id]
    if not line or line.state ~= expected then return false end
    line.state = next_
    touch(true, line.contract_id)
    return true
end

--- Guarded amount change; state is never written here.
function JsonStore.setEscrowAmount(id, expectedState, amount, expectedAmount)
    local line = db.escrow[id]
    if not line or line.state ~= expectedState then return false end
    if expectedAmount ~= nil and line.amount ~= expectedAmount then return false end
    line.amount = amount
    touch(true, line.contract_id)
    return true
end

--- Settle a line this caller holds.
---
--- Guarded on `releasing`, because both callers settle only after claiming
--- held -> releasing. Without the guard the write was `WHERE id = ?`: it
--- would settle a line something else had taken back — restart recovery
--- returning a stuck `releasing` line to `held`, or a second server
--- instance on the same database — which is a line paid twice and recorded
--- once.
--- `staff`: see the memory backend.
function JsonStore.settleEscrowLine(id, recipientCid, staff)
    local line = db.escrow[id]
    if not line or line.state ~= CH.ESCROW_STATE.RELEASING then return false end
    line.state = CH.ESCROW_STATE.SETTLED
    line.settled_to = recipientCid
    line.settled_at = os.time()
    if staff then
        line.settled_by_staff = staff.disposition
        line.settled_staff = staff.by
    end
    touch(true, line.contract_id)
    return true
end

--------------------------------------------------------------------------
-- Hitmen
--------------------------------------------------------------------------

--- Financial, like the stake it records. The stake is taken, and flushed,
--- before this row is written; with the row riding the debounce, a process
--- that died inside the flush interval came back with the stake on disk and
--- no hitman it belonged to. Nothing returns a stake without its hitman row,
--- and an exclusive contract left `accepted` with nobody on it refused every
--- later acceptance as locked.
function JsonStore.addHitman(record)
    local existing = db.hitmen[record.id]
    if existing then unindexRow(hitmenBy, existing, record.id) end
    db.hitmen[record.id] = record
    indexRow(hitmenBy, record, record.id)
    touch(true, record.contract_id)
    return true
end

function JsonStore.readHitmen(contractId)
    local out = {}
    for id, h in pairs(hitmenBy[contractId] or {}) do
        if db.hitmen[id] == h then out[#out + 1] = h end
    end
    table.sort(out, function(a, b)
        if a.accepted_at == b.accepted_at then return a.id < b.id end
        return a.accepted_at < b.accepted_at
    end)
    return out
end

--- Every running contract's hitmen, by contract id. See the mysql backend:
--- one read for the death sampler's pass instead of one per contract.
function JsonStore.liveHitmen()
    local out = {}
    for id, c in pairs(db.contracts) do
        if c.state == 'active' or c.state == 'accepted' then
            local list = {}
            for hid, h in pairs(hitmenBy[id] or {}) do
                if db.hitmen[hid] == h then list[#list + 1] = h end
            end
            table.sort(list, function(a, b)
                if a.accepted_at == b.accepted_at then return a.id < b.id end
                return a.accepted_at < b.accepted_at
            end)
            out[id] = list
        end
    end
    return out
end

function JsonStore.readHitman(contractId, cid)
    for id, h in pairs(hitmenBy[contractId] or {}) do
        if db.hitmen[id] == h and h.hitman_cid == cid then return h end
    end
    return nil
end

--- One hitman row by its own id.
---
--- Used to confirm an id is free before minting onto it: the stake is taken
--- before the row is written, so an id already in use is a duplicate-key
--- error with the money already gone and no record naming who staked it.
function JsonStore.readHitmanById(id)
    return db.hitmen[id]
end

--- Financial for the same reason as addHitman: a hitman taking a contract up
--- again is `active` here after a fresh stake was already flushed, and which
--- hitmen are active decides where every stake goes when the contract ends.
function JsonStore.updateHitman(id, fields)
    local h = db.hitmen[id]
    if not h then return false end
    for k, v in pairs(fields) do h[k] = v end
    touch(true, h.contract_id)
    return true
end

--- Confirm an acceptance: the row goes active only if it is still the
--- acceptance that wrote it. Anything that moved it off joining since — boot
--- recovery, a throw's unwind — is not reversed.
function JsonStore.confirmHitman(id, anon, acceptedAt)
    local h = db.hitmen[id]
    if not h or (h.state ~= 'joining' and h.state ~= 'rejoining') then return false end
    h.state, h.anon, h.accepted_at = 'active', anon == true, acceptedAt
    touch(true, h.contract_id)
    return true
end

--- A hitman walks away: the row goes abandoned only while it is active, on
--- this contract, and the contract is still open (MySQLStore.abandonHitman).
function JsonStore.abandonHitman(id, contractId, leftAt)
    local h = db.hitmen[id]
    if not h or h.state ~= 'active' or h.contract_id ~= contractId then return false end
    local c = db.contracts[contractId]
    if not c or (c.state ~= CH.STATE.ACTIVE and c.state ~= CH.STATE.ACCEPTED) then return false end
    h.state, h.left_at = 'abandoned', leftAt
    touch(true, h.contract_id)
    return true
end

--- Contracts a player is on, mid-acceptance included: two acceptances in
--- flight must each see the other against the cap.
function JsonStore.countHitmanContracts(cid, states)
    local n = 0
    for _, h in pairs(db.hitmen) do
        if h.hitman_cid == cid and (h.state == 'active' or h.state == 'joining' or h.state == 'rejoining') then
            local c = db.contracts[h.contract_id]
            if c and states[c.state] then n = n + 1 end
        end
    end
    return n
end

--------------------------------------------------------------------------
-- Amendments, messages, ledger, pending, audit
--------------------------------------------------------------------------

--- An answered proposal is written at once, as a financial write is. What
--- it changed already was: apply moved the deadline or the reward with a
--- financial write, which flushed the proposal too, still open and holding
--- every approval. With 'applied' left on the debounce, a crash in between
--- brought it back open after the restart, and one more Agree applied the
--- same change a second time.
function JsonStore.writeAmendment(a)
    db.amendments[a.id] = a
    touch(a.outcome ~= 'open', a.contract_id)
    return true
end
function JsonStore.readAmendment(id) return db.amendments[id] end

--- Every contract with a proposal still open, as a set. See the memory
--- backend.
function JsonStore.openAmendmentContracts()
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.outcome == 'open' and a.contract_id ~= nil then out[a.contract_id] = true end
    end
    return out
end

function JsonStore.readOpenAmendments(contractId)
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.contract_id == contractId and a.outcome == 'open' then out[#out + 1] = a end
    end
    return out
end

--- Proposals a start finds still being applied. See the memory backend.
function JsonStore.applyingAmendments()
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.outcome == 'applying' then out[#out + 1] = a end
    end
    return out
end

function JsonStore.writeMessage(m)
    db.messages[#db.messages + 1] = m
    indexMessage(m)
    -- Pruned to the newest Config.Relay.MaxMessagesPerThread, so the
    -- contract's file — rewritten whole on every message — stays small.
    local keep = tonumber(Config.Relay.MaxMessagesPerThread) or 0
    if keep > 0 then
        local seen, dropped = 0, {}
        for i = #db.messages, 1, -1 do
            local row = db.messages[i]
            if row.contract_id == m.contract_id and row.thread_id == m.thread_id then
                seen = seen + 1
                if seen > keep then
                    dropped[row] = true
                    table.remove(db.messages, i)
                end
            end
        end
        -- And from the contract's own list (messagesBy), as it stands now.
        if next(dropped) and messagesBy[m.contract_id] then
            local rows, kept = messagesBy[m.contract_id], {}
            for i = 1, #rows do
                if not dropped[rows[i]] then kept[#kept + 1] = rows[i] end
            end
            messagesBy[m.contract_id] = kept
        end
    end
    touch(false, m.contract_id)
    return true
end

function JsonStore.readMessages(contractId, threadId)
    local out = {}
    for _, m in ipairs(db.messages) do
        if m.contract_id == contractId and m.thread_id == threadId then out[#out + 1] = m end
    end
    return out
end

--- Threads somebody has muted; see the memory backend. In the contract's
--- own file, beside the messages they silence.
function JsonStore.readMute(threadId, cid)
    return db.mutes[threadId .. ':' .. cid] ~= nil
end

function JsonStore.setMute(contractId, threadId, cid, muted, at)
    local key = threadId .. ':' .. cid
    if muted then
        db.mutes[key] = { contract_id = contractId, thread_id = threadId, cid = cid, muted_at = at }
    else
        db.mutes[key] = nil
    end
    touch(false, contractId)
    return true
end

function JsonStore.writeLedger(entry)
    db.ledger[#db.ledger + 1] = entry
    -- Prune to the configured depth per player so the file stays small.
    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    local seen = 0
    for i = #db.ledger, 1, -1 do
        if db.ledger[i].cid == entry.cid then
            seen = seen + 1
            if seen > depth then table.remove(db.ledger, i) end
        end
    end
    touch(false)
    return true
end

--- Drop the photo reference from rows older than the cutoff (§14.43).
function JsonStore.forgetLedgerPhotos(cutoff)
    local forgotten = 0
    for i = 1, #db.ledger do
        local row = db.ledger[i]
        if row.photo_ref and (row.resolved_at or 0) < cutoff then
            row.photo_ref = nil
            forgotten = forgotten + 1
        end
    end
    if forgotten > 0 then touch(false) end
    return forgotten
end

function JsonStore.readLedger(cid, depth)
    local out = {}
    for i = #db.ledger, 1, -1 do
        if db.ledger[i].cid == cid then
            out[#out + 1] = db.ledger[i]
            if #out >= depth then break end
        end
    end
    return out
end

--------------------------------------------------------------------------
-- Kill photos kept for a contract's client; see the memory backend.
--------------------------------------------------------------------------
--
-- In the records beside the ledger rows that name them: a handle, a state
-- and at most a link or a file name each, never the image itself. A change
-- of state is written at once, as a financial write is: a photo the client
-- chose to delete, or one they have already seen, must not come back as
-- unseen because the process stopped before the next flush.

function JsonStore.writePhoto(record)
    local row = {}
    for k, v in pairs(record) do row[k] = v end
    db.photos[row.id] = row
    touch(false)
    return true
end

function JsonStore.readPhoto(id)
    return db.photos[id]
end

--- Whether any photo record is kept at all, in any state (Photos.anyStored).
function JsonStore.anyPhoto()
    return next(db.photos) ~= nil
end

--- Records matching `keep`, oldest first, at most `limit` of them.
local function photosWhere(keep, limit)
    local out = {}
    for _, row in pairs(db.photos) do
        if keep(row) then out[#out + 1] = row end
    end
    table.sort(out, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then
            return (a.created_at or 0) < (b.created_at or 0)
        end
        return tostring(a.id) < tostring(b.id)
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function JsonStore.photosOf(ownerCid)
    return photosWhere(function(row) return row.owner_cid == ownerCid end)
end

function JsonStore.photosForContract(contractId)
    return photosWhere(function(row) return row.contract_id == contractId end)
end

function JsonStore.photosOpenedBefore(cutoff, limit, state)
    state = state or CH.PHOTO.OPEN
    return photosWhere(function(row)
        return row.state == state and (tonumber(row.opened_at) or 0) < cutoff
    end, limit)
end

function JsonStore.readPhotoByPublic(publicId)
    if type(publicId) ~= 'string' then return nil end
    for _, row in pairs(db.photos) do
        if row.public_id == publicId then return row end
    end
    return nil
end

function JsonStore.photoTotals()
    local out = {}
    for _, row in pairs(db.photos) do
        if row.file then
            local total = out[row.state] or { count = 0, bytes = 0 }
            total.count = total.count + 1
            total.bytes = total.bytes + (tonumber(row.size) or 0)
            out[row.state] = total
        end
    end
    return out
end

function JsonStore.photosCreatedBefore(cutoff, limit)
    return photosWhere(function(row)
        return (tonumber(row.created_at) or 0) < cutoff and row.state ~= CH.PHOTO.KEPT
            and row.public_id == nil
    end, limit)
end

function JsonStore.openPhoto(id, at)
    local row = db.photos[id]
    if not row or row.state ~= CH.PHOTO.PENDING then return false end
    row.state, row.opened_at = CH.PHOTO.OPEN, at
    touch(true)
    return true
end

function JsonStore.closePhoto(id, expected, next_, savedLink)
    local row = db.photos[id]
    if not row or row.state ~= expected then return false end
    row.state, row.url, row.file, row.saved_link = next_, nil, nil, savedLink
    row.public_id, row.saved_phone = nil, nil
    touch(true)
    return true
end

function JsonStore.publishPhoto(id, expected, publicId, link, phone)
    local row = db.photos[id]
    if not row or row.state ~= expected or not row.file then return false end
    row.public_id, row.saved_link, row.saved_phone = publicId, link, phone
    touch(true)
    return true
end

function JsonStore.movePhoto(id, expected, next_)
    local row = db.photos[id]
    if not row or row.state ~= expected then return false end
    row.state = next_
    touch(true)
    return true
end

function JsonStore.keepPhoto(id, expected, file)
    local row = db.photos[id]
    if not row or row.state ~= expected then return false end
    row.state, row.public_id, row.saved_link, row.saved_phone = CH.PHOTO.KEPT, nil, nil, nil
    if file then row.file = file end
    touch(true)
    return true
end

function JsonStore.deletePhoto(id)
    if db.photos[id] == nil then return true end
    db.photos[id] = nil
    touch(true)
    return true
end

--- See the memory backend. The records file is written once for the lot.
function JsonStore.photosNotOpen(limit)
    return photosWhere(function(row) return row.state ~= CH.PHOTO.OPEN end, limit)
end

function JsonStore.deletePhotosIn(list)
    local gone, any = {}, false
    for _, wanted in ipairs(list or {}) do
        local row = db.photos[wanted.id]
        if row and row.state == wanted.state then
            db.photos[wanted.id] = nil
            gone[wanted.id] = true
            any = true
        end
    end
    if any then touch(true) end
    return gone
end

function JsonStore.photoCounts()
    local out = { total = 0, open = 0, links = 0, files = 0 }
    for _, row in pairs(db.photos) do
        out.total = out.total + 1
        if row.state == CH.PHOTO.OPEN then out.open = out.open + 1 end
        if row.kind == 'url' then out.links = out.links + 1 end
        if row.file then out.files = out.files + 1 end
    end
    return out
end

function JsonStore.queuePending(cid, contractId, lineId)
    local id = JsonStore.nextId('pnd')
    db.pending[id] = {
        id = id, cid = cid, contract_id = contractId,
        line_id = lineId, queued_at = os.time(),
    }
    touch(true)
    return true
end

function JsonStore.readPending(cid)
    local out = {}
    for _, p in pairs(db.pending) do
        if p.cid == cid then out[#out + 1] = p end
    end
    return out
end

function JsonStore.clearPending(id)
    db.pending[id] = nil
    touch(true)
    return true
end

function JsonStore.bumpStat(cid, field, amount)
    db.stats = db.stats or {}
    local row = db.stats[cid]
    if not row then
        row = { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
        db.stats[cid] = row
    end
    row[field] = (row[field] or 0) + (amount or 1)
    touch(false)
    return row[field]
end

function JsonStore.readStats(cid)
    db.stats = db.stats or {}
    return db.stats[cid] or { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
end

--- How many rows the retention age has dropped from the front of db.audit
--- since it was this table: what a page's cursor counts from
--- (JsonStore.queryAudit). Kept against the table itself, so a store opened
--- or read back again starts counting again.
local auditDropped = { log = nil, rows = 0 }

local function droppedFrom(log)
    if auditDropped.log ~= log then auditDropped.log, auditDropped.rows = log, 0 end
    return auditDropped.rows
end

--- Into its day's file, on the next flush; see auditLog.
---
--- Encoded here, once. The file is these lines, so a flush adds them as
--- they are, and a row that will not encode is refused now rather than
--- failing every write after it.
function JsonStore.writeAudit(entry)
    local line = json.encode(entry)
    db.audit[#db.audit + 1] = entry

    local day = auditKey(auditDay(entry.ts))
    local lines = auditLog.lines[day]
    if not lines then
        lines = {}
        auditLog.lines[day], auditLog.onDisk[day] = lines, 0
        -- A new day is a new name in the index, which goes to disk before
        -- the day's file does (saveAudit).
        indexDirty, dirty = true, true
    end
    lines[#lines + 1] = line

    -- 0 keeps it, as the retention settings beside it do. Read as a number
    -- of days, 0 made the cutoff now, and every row older than the current
    -- second went, including the ones /ch-stuck is built from.
    local cutoff = auditCutoff()
    if cutoff then
        -- The aged rows are at the front, in the order they were written:
        -- counted, then gone in one move. Removed one at a time from the
        -- front, each shifted the whole log, and a flush that aged out a
        -- hundred rows of a busy month's log took a hundred of those.
        local log = db.audit
        local n, aged = #log, 0
        while aged < n and log[aged + 1].ts < cutoff do aged = aged + 1 end
        if aged > 0 then
            table.move(log, aged + 1, n, 1)
            for i = n - aged + 1, n do log[i] = nil end
            auditDropped.rows = droppedFrom(log) + aged
        end
        -- A file goes once the whole of its day is past the age. The day
        -- the cutoff falls in keeps its older rows on disk until then; a
        -- start reads them back and leaves them out.
        local cutoffDay = auditDay(cutoff)
        for kept in pairs(auditLog.lines) do
            if kept < cutoffDay then dropAuditDay(kept) end
        end
    end
    return true
end

function JsonStore.readAudit() return db.audit end

--- Every audit row with one action, oldest first, the newest `limit` of them.
function JsonStore.auditByAction(action, limit)
    local out = {}
    for i = 1, #db.audit do
        if db.audit[i].action == action then out[#out + 1] = db.audit[i] end
    end
    if limit and #out > limit then
        local trimmed = {}
        for i = #out - limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
        return trimmed
    end
    return out
end

--- A page of the audit log for the admin panel, newest first. See the
--- memory backend: the rows within the retention age are all in memory
--- here too (db.audit), whichever day's file they are written in, and the
--- cursor is a position counted from the first row written, the aged ones
--- included (droppedFrom). Every write here ages rows off the front, so
--- counted from what was left, the page after one written meanwhile
--- started too new and showed rows again.
function JsonStore.queryAudit(filter, cursor, limit)
    local log = db.audit
    local base = droppedFrom(log)
    local at = math.tointeger(tonumber(cursor))
    local start = at and (at - base) or #log
    -- Everything from there back has aged out since.
    if start < 1 then return {}, nil end
    local out = {}
    for i = math.min(start, #log), 1, -1 do
        if Util.auditMatches(log[i], filter) then
            if #out >= limit then return out, base + i end
            out[#out + 1] = log[i]
        end
    end
    return out, nil
end

--- Every audit row naming one contract, oldest first.
function JsonStore.auditForContract(contractId, limit)
    local out = {}
    for i = 1, #db.audit do
        if db.audit[i].contract_id == contractId then out[#out + 1] = db.audit[i] end
    end
    if limit and #out > limit then
        local trimmed = {}
        for i = #out - limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
        return trimmed
    end
    return out
end

function JsonStore._raw() return db end

return JsonStore
