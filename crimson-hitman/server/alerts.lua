--- The admin panel's Alerts, and the same alerts posted to Discord.
---
--- Every line the console prints whatever Config.Debug says (shared/log.lua:
--- Log.always, and each Log.problem, a setting found wrong at start) is kept
--- here as an alert as it is said: money at risk or left for staff, a stuck
--- or parked escrow line, an item opened in the review queue, a write that
--- failed or read back wrong, a money job that keeps failing, the start
--- refusing or recovering, and the Log.raised summaries. Each carries its id,
--- when it was first and last said (first_at, last_at), how many times
--- (count), its level ('always', or 'problem' for a setting), its text, the
--- contract it names if it names one, and who acknowledged it and when.
---
--- The same line again, its numbers aside (a count, a wait in seconds), is
--- counted on the open alert it repeats rather than kept twice; once that
--- one is acknowledged, the next makes a new alert. A block of lines (a
--- header and the indented lines under it, between rules of '=') is one
--- alert, the rules left out.
---
--- Kept in every store, so they outlive a restart where the store does
--- (memory keeps them as long as it keeps anything; json in records.json;
--- mysql in crimson_alerts). At most Alerts.MAX: past it the oldest
--- acknowledged go first, then unacknowledged ones not said for
--- Alerts.KEEP_DAYS, and never one said more recently than that, unless
--- Alerts.BACKSTOP are kept, which only a loop could reach.
---
--- Never on a money path's time. A line is put in memory as it is said and
--- written to the store from there: at once on memory and json, which only
--- change a table (json writes the file at its next flush, never at a money
--- write's save), and on mysql in a thread of its own a moment later. A
--- write that fails leaves the alert in memory, written by the next try; the
--- line was printed either way.
---
--- Discord: posted to the webhook in the server convar
--- crimson_hitman_alert_webhook, or the staff one (crimson_hitman_webhook)
--- where that is not set, while Config.Alerts.ToDiscord is on. Set in
--- server.cfg with `set`, never `setr` (setr sends it to every player), and
--- never in config.lua, which every player's game downloads. At most one post
--- every Alerts.POST_EVERY_MS, carrying what arrived since (the same alert
--- again counted on its line), at most Alerts.PER_POST alerts a post and how
--- many more; the text scrubbed as for a reader with no identity ACE and
--- more (every party's name, every link), because Discord is outside the
--- server. A post Discord refuses is tried again later and given up after
--- Alerts.TRIES tries, which the panel shows. All of it from timers of its
--- own: nothing that prints a line waits for a post.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Alerts = {}

--- At most this many kept (prune).
Alerts.MAX = 500
--- An unacknowledged alert said within this many days is never pruned.
Alerts.KEEP_DAYS = 30
--- Past this many, the oldest goes even unacknowledged: only a loop saying a
--- new line every time could reach it, and memory is not given to that.
Alerts.BACKSTOP = 5000
--- Discord: one post this often at most, this many alerts a post, given up
--- after this many tries.
Alerts.POST_EVERY_MS = 10000
Alerts.PER_POST = 10
Alerts.TRIES = 3
--- mysql: how long after an alert changes it is written, and how long after
--- a write that failed (or a database not answering) it is tried again.
Alerts.FLUSH_MS = 2000
Alerts.RETRY_MS = 30000

--- How much of a line an alert keeps: its first line, and the indented lines
--- of its block after it.
local HEADER_MAX, TEXT_MAX = 500, 1000
--- Discord's: a line of a post, and a post's alert lines (its limit is 2000
--- characters; the heading and the line saying how many more fit in the rest).
local LINE_MAX, CONTENT_MAX = 300, 1800
local LEVELS = { always = true, problem = true }
local LEVEL_WORDS = { always = 'Needs staff', problem = 'Setting', test = 'Test' }
local TEST_TEXT = 'A test alert from the admin panel: alerts reach this channel.'

local deps, Storage

local kept = {}       -- [id] = alert { id, key, level, text, contract_id, first_at, last_at, count, acknowledged_by, acknowledged_at }
local size = 0        -- how many are kept
local openKey = {}    -- [key] = id of the open alert said under it
local unwritten = {}  -- [id] = true: changed since the store last took it
local gone = {}       -- [id] = true: pruned, and not yet deleted from the store
local loaded = false  -- whether the store's alerts were read
local block = nil     -- { id } the alert the last line started, which an indented line continues
local flushTimer = nil
local flushing = false

local outbox = {}     -- { key, level, text, contract_id, count }[] waiting for the next post
local outKey = {}     -- [key] = its entry in outbox
local postTimer = nil
local posting = false -- a post is out, or waiting to be tried again
local lastPostMs = nil
local sent = { posted = 0 } -- { posted, lastOkAt, lastFail = { at, tries, status, alerts } }

--------------------------------------------------------------------------
-- What a line is kept as
--------------------------------------------------------------------------

--- Cut to `max` bytes, on a whole character.
local function cut(text, max)
    if #text <= max then return text end
    return Util.toValidUtf8(text:sub(1, max - 3)) .. '...'
end

--- What makes two lines the same alert: the level, and the line with every
--- number standing on its own (a count, a wait, an attempt) as '#'. Ids are
--- not numbers standing on their own, so two contracts are two alerts.
local function keyOf(level, header)
    return level .. '|' .. (header:gsub('%f[%w]%d+%f[%W]', '#'))
end

--- The first contract id a line names, if it names one.
local function contractIn(text)
    for candidate in text:gmatch('%f[%w](ct[%l%d]+)%f[%W]') do
        if Util.toId(candidate) then return candidate end
    end
    return nil
end

local function mint()
    return Util.mintId(Util.randomId, 'al', function(id) return kept[id] ~= nil end)
        or Util.randomId('al')
end

--- An alert as the store keeps it: everything but its key, which is worked
--- out again from its text.
local function rowOf(a)
    return {
        id = a.id, level = a.level, text = a.text, contract_id = a.contract_id,
        first_at = a.first_at, last_at = a.last_at, count = a.count,
        acknowledged_by = a.acknowledged_by, acknowledged_at = a.acknowledged_at,
    }
end

local function forget(a)
    kept[a.id] = nil
    size = size - 1
    if openKey[a.key] == a.id then openKey[a.key] = nil end
    unwritten[a.id] = nil
    gone[a.id] = true
    if block and block.id == a.id then block = nil end
end

local function oldestFirst(x, y)
    if (x.last_at or 0) ~= (y.last_at or 0) then return (x.last_at or 0) < (y.last_at or 0) end
    return x.id < y.id
end

--- Down to Alerts.MAX: the oldest acknowledged first, then unacknowledged
--- ones not said for Alerts.KEEP_DAYS. One said since is never pruned, but
--- past Alerts.BACKSTOP.
---@param now integer
---@return integer pruned
local function prune(now)
    if size <= Alerts.MAX then return 0 end
    local old = now - Alerts.KEEP_DAYS * 86400
    local acked, stale, recent = {}, {}, {}
    for _, a in pairs(kept) do
        if a.acknowledged_at then
            acked[#acked + 1] = a
        elseif (a.last_at or 0) < old then
            stale[#stale + 1] = a
        else
            recent[#recent + 1] = a
        end
    end
    table.sort(acked, oldestFirst)
    table.sort(stale, oldestFirst)
    local pruned = 0
    for _, list in ipairs({ acked, stale }) do
        for i = 1, #list do
            if size <= Alerts.MAX then break end
            forget(list[i])
            pruned = pruned + 1
        end
    end
    if size > Alerts.BACKSTOP then
        table.sort(recent, oldestFirst)
        for i = 1, #recent do
            if size <= Alerts.BACKSTOP then break end
            forget(recent[i])
            pruned = pruned + 1
        end
    end
    return pruned
end

--------------------------------------------------------------------------
-- The store
--------------------------------------------------------------------------

--- What the store kept, put back. A row already here (read twice) is left.
---@return boolean read
local function load()
    local ok, rows = pcall(Storage.readAlerts)
    if not ok then
        Log.debug(('the admin panel\'s alerts could not be read from the store: %s; they are '
            .. 'read again at the next write'):format(Util.dbError(rows)))
        return false
    end
    loaded = true
    for _, row in ipairs(type(rows) == 'table' and rows or {}) do
        local id = type(row) == 'table' and Util.toId(row.id) or nil
        if id and not kept[id] then
            local level = row.level == 'problem' and 'problem' or 'always'
            local text = tostring(row.text or '')
            local first = tonumber(row.first_at) or 0
            local a = {
                id = id, level = level, text = text, contract_id = Util.toId(row.contract_id),
                first_at = first, last_at = tonumber(row.last_at) or first,
                count = math.max(1, math.floor(tonumber(row.count) or 1)),
                acknowledged_by = row.acknowledged_by ~= nil and tostring(row.acknowledged_by) or nil,
                acknowledged_at = tonumber(row.acknowledged_at),
                key = keyOf(level, text:match('^[^\n]*')),
            }
            kept[id] = a
            size = size + 1
            if not a.acknowledged_at then
                local holder = kept[openKey[a.key]]
                if not holder or (holder.last_at or 0) <= a.last_at then openKey[a.key] = id end
            end
        end
    end
    prune(os.time())
    return true
end

local scheduleFlush

--- Write what changed, and delete what was pruned. Never raises: one that
--- does not go is kept for the next try. `stopping` is the resource going
--- away: mysql then hands each row over without waiting (writeAlertNoWait).
---@param stopping boolean|nil
---@return integer written
function Alerts.flush(stopping)
    -- A stop does not wait for a flush still waiting on the database: what
    -- changed since it began is handed over now.
    if not Storage or (flushing and not stopping) then return 0 end
    if Storage.healthy and not Storage.healthy() and not stopping then
        scheduleFlush(Alerts.RETRY_MS)
        return 0
    end
    flushing = true
    if not loaded and not stopping then load() end
    local write = (stopping and Storage.writeAlertNoWait) or Storage.writeAlert
    local ids, doomed = unwritten, gone
    unwritten, gone = {}, {}
    local written, failed = 0, false
    for id in pairs(ids) do
        local a = kept[id]
        if a then
            if pcall(write, rowOf(a)) then
                written = written + 1
            else
                unwritten[id], failed = true, true
            end
        end
    end
    for id in pairs(doomed) do
        if stopping or not pcall(Storage.deleteAlert, id) then
            -- Deleted by the next start's prune, at a stop.
            if not stopping then gone[id], failed = true, true end
        end
    end
    flushing = false
    if not stopping and (failed or next(unwritten) or next(gone)) then
        scheduleFlush(failed and Alerts.RETRY_MS or Alerts.FLUSH_MS)
    end
    return written
end

--- On mysql, a flush a moment from now in a timer of its own, once.
---@param ms integer|nil
scheduleFlush = function(ms)
    if flushTimer or type(SetTimeout) ~= 'function' then return end
    flushTimer = SetTimeout(ms or Alerts.FLUSH_MS, function()
        flushTimer = nil
        Alerts.flush()
    end)
end

--- An alert changed: written at once where the store only changes a table,
--- and a moment from now, in its own thread, where it waits on a database.
local function changed(a)
    unwritten[a.id] = true
    if Storage and Storage.remote then
        scheduleFlush(Alerts.FLUSH_MS)
    elseif Storage and not flushing then
        Alerts.flush()
    end
end

--------------------------------------------------------------------------
-- Discord
--------------------------------------------------------------------------

--- Which webhook alerts go to, and which convar named it; never shown.
---@return string|nil url
---@return string|nil which 'alert' | 'staff'
local function webhook()
    if type(GetConvar) ~= 'function' then return nil, nil end
    local url = GetConvar('crimson_hitman_alert_webhook', '')
    if type(url) == 'string' and url ~= '' then return url, 'alert' end
    url = GetConvar('crimson_hitman_webhook', '')
    if type(url) == 'string' and url ~= '' then return url, 'staff' end
    return nil, nil
end

local function postsOn()
    return type(Config.Alerts) == 'table' and Config.Alerts.ToDiscord == true
end

--- An alert's text as Discord may read it: scrubbed by the panel's own
--- redactor as for a reader outside the server (Panel.scrubText), or left
--- out where that could not be done.
local function outsideText(entry)
    if entry.level == 'test' then return entry.text end
    local panel = deps and deps.panel
    local ok, text = pcall(function()
        return panel.scrubText(entry.text, false, entry.contract_id, true)
    end)
    if not ok or type(text) ~= 'string' then return '(not shown here; see the admin panel)' end
    return text
end

--- One post: a heading, a line an alert, and how many more. A line that
--- would take the post past Discord's limit is counted among the more.
local function bodyOf(batch, more)
    local lines = { ('**Crimson Hitman** - %d alert(s)'):format(#batch + more) }
    local length = #lines[1]
    for _, entry in ipairs(batch) do
        local text = cut((outsideText(entry):gsub('%s+', ' ')), LINE_MAX)
        -- No mention pings anybody: an @ is followed by a zero-width space.
        local line = ('- %s: %s%s'):format(LEVEL_WORDS[entry.level] or 'Alert', text,
            entry.count > 1 and (' (x%d)'):format(entry.count) or ''):gsub('@', '@\226\128\139')
        if length + 1 + #line > CONTENT_MAX then
            more = more + 1
        else
            lines[#lines + 1] = line
            length = length + 1 + #line
        end
    end
    if more > 0 then
        lines[#lines + 1] = ('...and %d more; the admin panel\'s Alerts lists every one'):format(more)
    end
    return json.encode({ content = table.concat(lines, '\n') })
end

local schedulePost

--- Try a post, and again after a wait each time it is refused, up to
--- Alerts.TRIES tries. `carried` is what it carries: { alerts, test }, the
--- alerts it names or counts, and whether a test is among them.
local function attempt(body, carried, try)
    local url = webhook()
    if not url or not postsOn() then
        -- Unset or switched off meanwhile: nothing is waiting for it.
        posting = false
        return
    end
    posting = true
    lastPostMs = Util.monotonicMs()
    local function answered(status, _, headers)
        local code = tonumber(status) or 0
        if code >= 200 and code < 300 then
            posting = false
            sent.posted = sent.posted + carried.alerts
            sent.lastOkAt = os.time()
            schedulePost()
            return
        end
        if try >= Alerts.TRIES then
            posting = false
            sent.lastFail = { at = os.time(), tries = try, status = code, alerts = carried.alerts,
                              test = carried.test or nil }
            -- Not Log.always: that would be an alert, and a post, of its own.
            Log.debug(('alerts could not be posted to Discord: %d alert(s)%s given up after %d '
                .. 'tries (HTTP %d)'):format(carried.alerts, carried.test and ' and a test' or '',
                    try, code))
            schedulePost()
            return
        end
        local wait = Alerts.POST_EVERY_MS * 2 ^ (try - 1)
        local after = type(headers) == 'table'
            and tonumber(headers['Retry-After'] or headers['retry-after']) or nil
        if after then wait = math.max(wait, after * 1000) end
        SetTimeout(math.floor(wait), function() attempt(body, carried, try + 1) end)
    end
    local ok = pcall(PerformHttpRequest, url, answered, 'POST', body,
        { ['Content-Type'] = 'application/json' })
    if not ok then answered(0, nil, nil) end
end

--- Post what is waiting: at most Alerts.PER_POST, and how many more.
local function send()
    if #outbox == 0 or posting then return end
    if not postsOn() or not webhook() then
        outbox, outKey = {}, {}
        return
    end
    local batch, more = {}, 0
    for i = 1, #outbox do
        if #batch < Alerts.PER_POST then batch[#batch + 1] = outbox[i] else more = more + 1 end
    end
    outbox, outKey = {}, {}
    local ok, body = pcall(bodyOf, batch, more)
    if not ok then
        Log.debug(('an alerts post could not be put together: %s'):format(tostring(body)))
        return
    end
    -- A test is always first (Alerts.sendTest), and never among the more.
    local test = batch[1] ~= nil and batch[1].level == 'test'
    attempt(body, { alerts = #batch + more - (test and 1 or 0), test = test }, 1)
end

--- The next post, no sooner than Alerts.POST_EVERY_MS after the last one.
schedulePost = function()
    if postTimer or posting or #outbox == 0 or type(SetTimeout) ~= 'function' then return end
    local wait = 0
    if lastPostMs then wait = math.max(0, lastPostMs + Alerts.POST_EVERY_MS - Util.monotonicMs()) end
    postTimer = SetTimeout(wait, function()
        postTimer = nil
        send()
    end)
end

--- Put an alert in the next post, or count it again on the line it has
--- there. `continued` is an indented line added to its text: not said again.
local function queuePost(a, continued)
    if not postsOn() or not webhook() then return end
    local entry = outKey[a.key]
    if entry then
        if not continued then entry.count = entry.count + 1 end
        entry.text, entry.contract_id = a.text, a.contract_id
    elseif not continued then
        entry = { key = a.key, level = a.level, text = a.text, contract_id = a.contract_id, count = 1 }
        outbox[#outbox + 1] = entry
        outKey[a.key] = entry
    end
    schedulePost()
end

--------------------------------------------------------------------------
-- A line said
--------------------------------------------------------------------------

--- A line the console printed whatever Debug said (Log.onAlert). Only ever
--- changes memory and sets a timer, whatever path said it.
---@param level string 'always' | 'problem'
---@param text string
---@param at integer|nil os.time() it was said
function Alerts.note(level, text, at)
    if not LEVELS[level] then return end
    at = tonumber(at) or os.time()
    text = Util.dbErrorIn(tostring(text or '')):gsub('%s+$', '')
    -- A rule of '=' around a block: no alert, and the block it opened or
    -- closed is over.
    if not text:find('%w') then
        block = nil
        return
    end
    local continues = block and kept[block.id]
    if text:find('^%s') and continues and continues.level == level then
        if #continues.text < TEXT_MAX then
            continues.text = cut(continues.text .. '\n' .. text:gsub('^%s+', ''), TEXT_MAX)
        end
        continues.contract_id = continues.contract_id or contractIn(text)
        changed(continues)
        queuePost(continues, true)
        return
    end
    -- The first line is the alert; any more in the same text are its block.
    text = text:gsub('^%s+', '')
    local header, rest = text:match('^([^\n]*)\n(.*)$')
    header = cut(header or text, HEADER_MAX)
    local key = keyOf(level, header)
    local a = kept[openKey[key]]
    if a and not a.acknowledged_at then
        a.count = a.count + 1
        a.last_at = math.max(a.last_at or at, at)
        a.text = header
        a.contract_id = contractIn(header) or a.contract_id
    else
        a = { id = mint(), key = key, level = level, text = header, contract_id = contractIn(header),
              first_at = at, last_at = at, count = 1 }
        kept[a.id] = a
        size = size + 1
        openKey[key] = a.id
        prune(at)
    end
    if rest and rest:find('%w') then
        a.text = cut(header .. '\n' .. rest, TEXT_MAX)
        a.contract_id = a.contract_id or contractIn(rest)
    end
    block = kept[a.id] and { id = a.id } or nil
    changed(a)
    queuePost(a)
end

--------------------------------------------------------------------------
-- What the admin panel reads and does
--------------------------------------------------------------------------

--- Alerts open or acknowledged, newest first, at most `limit`, and how many
--- there are of each. Copies.
---@param state string 'open' | 'acknowledged'
---@param limit integer
---@return table[] rows
---@return table counts { open, acknowledged }
function Alerts.list(state, limit)
    local rows, open, acked = {}, 0, 0
    local wantAcked = state == 'acknowledged'
    for _, a in pairs(kept) do
        local isAcked = a.acknowledged_at ~= nil
        if isAcked then acked = acked + 1 else open = open + 1 end
        if isAcked == wantAcked then rows[#rows + 1] = a end
    end
    table.sort(rows, function(x, y)
        local xt = wantAcked and (x.acknowledged_at or 0) or (x.last_at or 0)
        local yt = wantAcked and (y.acknowledged_at or 0) or (y.last_at or 0)
        if xt ~= yt then return xt > yt end
        if (x.last_at or 0) ~= (y.last_at or 0) then return (x.last_at or 0) > (y.last_at or 0) end
        return x.id > y.id
    end)
    local out = {}
    for i = 1, math.min(#rows, limit or #rows) do out[i] = rowOf(rows[i]) end
    return out, { open = open, acknowledged = acked }
end

--- How many alerts nobody has acknowledged.
---@return integer
function Alerts.openCount()
    local n = 0
    for _, a in pairs(kept) do
        if not a.acknowledged_at then n = n + 1 end
    end
    return n
end

--- Acknowledge alerts by id, as `who`. One acknowledged already, or not
--- kept, is left as it is and counted.
---@param ids string[]
---@param who string the staff member, as the panel names them
---@return integer done
---@return integer already
---@return integer missing
function Alerts.acknowledge(ids, who)
    local done, already, missing = 0, 0, 0
    local at = os.time()
    for _, id in ipairs(ids) do
        local a = kept[id]
        if not a then
            missing = missing + 1
        elseif a.acknowledged_at then
            already = already + 1
        else
            a.acknowledged_by, a.acknowledged_at = who, at
            if openKey[a.key] == id then openKey[a.key] = nil end
            changed(a)
            done = done + 1
        end
    end
    return done, already, missing
end

--- Where posting to Discord stands, for the panel. Whether a webhook is set
--- and which convar set it, never what it is.
---@return table
function Alerts.discordState()
    local _, which = webhook()
    local fail = sent.lastFail
    return {
        on = postsOn(), webhook = which, waiting = #outbox, posting = posting,
        posted = sent.posted, lastOkAt = sent.lastOkAt,
        lastFail = fail and { at = fail.at, tries = fail.tries, status = fail.status,
                              alerts = fail.alerts, test = fail.test } or nil,
    }
end

--- A test alert, first in the next post: false and why where none would go.
---@return boolean queued
---@return string|nil err 'discord_off' | 'no_webhook'
---@return integer|nil seconds about how long until it is posted
function Alerts.sendTest()
    if not postsOn() then return false, 'discord_off' end
    if not webhook() then return false, 'no_webhook' end
    local entry = outKey.test
    if entry then
        entry.count = entry.count + 1
    else
        entry = { key = 'test', level = 'test', text = TEST_TEXT, count = 1 }
        table.insert(outbox, 1, entry)
        outKey.test = entry
    end
    schedulePost()
    local wait = 0
    if lastPostMs then wait = math.max(0, lastPostMs + Alerts.POST_EVERY_MS - Util.monotonicMs()) end
    return true, nil, math.ceil(wait / 1000)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

--- Read what the store kept, then listen: every line said since this start
--- began (Log.beginStart) is handed over now, the start's own checks among
--- them. Never raises.
---@param d table the wired modules (storage, panel)
function Alerts.init(d)
    deps = d
    Storage = d.storage
    kept, openKey, unwritten, gone = {}, {}, {}, {}
    size, loaded, block, flushing = 0, false, nil, false
    if flushTimer and type(ClearTimeout) == 'function' then ClearTimeout(flushTimer) end
    if postTimer and type(ClearTimeout) == 'function' then ClearTimeout(postTimer) end
    flushTimer, postTimer = nil, nil
    outbox, outKey, posting, lastPostMs = {}, {}, false, nil
    sent = { posted = 0 }
    load()
    Log.onAlert(Alerts.note)
    -- What the read pruned, and what the start said before this listened.
    if next(gone) or next(unwritten) then
        if Storage.remote then scheduleFlush(Alerts.FLUSH_MS) else Alerts.flush() end
    end
end

return Alerts
