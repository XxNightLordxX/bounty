--- Crimson Hitman System — the one way to the console.
---
--- With Config.Debug = false (as shipped) the server console stays quiet: a
--- normal start on a sound config, and normal play, print nothing at all.
--- Every line this resource prints, on either side, goes through here as one
--- of three kinds:
---
---   Log.always   printed whatever Debug says, and kept for nothing else:
---                refusing to start (FATAL); money at risk, or something
---                left for staff (the review queue, a stalled or parked
---                escrow line, an ending that raised); a write that failed
---                or read back wrong, so data could be lost. Log.raised is
---                the same for a request or command that may have moved
---                money and raised, once every few minutes per name, and
---                one line when they are up counting any it held back.
---   Log.problem  a configuration problem found at start. With Debug on each
---                is printed in full as it is found; with it off they are
---                counted, and the start prints one line for all of them
---                (Log.reportProblems), or nothing when there are none.
---   Log.debug    everything else, printed only with Debug on.
---
--- Nothing is lost when the console is quiet. The problems, everything the
--- start said and the newest of what came after are kept here (Log.view),
--- each line with its kind, and the diagnosis lists them: ch-diag in F8 or
--- the server console, and Run the diagnosis in the admin panel. The admin
--- panel's Console section shows the same, to filter and copy.
---
--- Log.console is a staff command's own answer, printed as it is to the
--- console that asked: the owner wants that whatever Debug says.
---
--- Every Log.always line and every Log.problem is also handed, as it is
--- said, to the admin panel's Alerts on the server (server/alerts.lua,
--- Log.onAlert), which keeps it across restarts and posts it to Discord.
--- Lines said before it is listening (the start's own checks) wait here
--- for it. Handing one over only puts it in memory: it never waits on a
--- store or a webhook, whatever path printed it.
---
--- Debug is read at every line, so switching it from the admin panel takes
--- effect at the next line printed.

local Log = {}

local PREFIX = '[crimson-hitman] '

--- Lines kept from the start, in order, for the diagnosis. A start says
--- some thirty; the cap is only so a loop at start cannot grow it.
Log.BOOT_KEPT = 120

--- Lines kept from after the start, newest last. The same line again (a
--- job failing every tick) is counted on the one it repeats, not kept twice.
Log.KEPT = 40

--- Log.always lines kept from after the start, in a list of their own: the
--- debug lines a player can cause (a page fault report, worded by the page)
--- cannot push money left for staff or a failed write out of what the
--- diagnosis lists. Only another Log.always line takes the oldest one's
--- place.
Log.KEPT_ALWAYS = 40

local problems = {}    -- { text = string, count = integer, printed = boolean }[] this start
local reported = false -- whether this start has said its one summary line
local booting = true   -- until Log.started(): lines go to `boot`
local boot = {}        -- string[] what the start said, in order
local bootKinds = {}   -- string[] the kind of each of those: 'always' | 'debug'
local bootLeft = 0     -- lines the start said past Log.BOOT_KEPT, counted and not kept
local recent = {}      -- { text, key, at, times, seq }[] Log.debug lines, newest last
local loud = {}        -- { text, key, at, times, seq }[] Log.always lines, newest last
local seq = 0          -- the order lines were kept in, across both lists
local raisedAt = {}    -- [name] = os.time() Log.raised last printed under it
local heldBack = {}    -- [name] = how many raised under it since, kept and not printed
local starts = 0       -- which start this is, so a wait an earlier one set says nothing
local sink = nil       -- function(kind, text, at): the server's Alerts, once it listens
local unheard = {}     -- { kind, text, at }[] lines said before it did, oldest first

--- Lines kept for the Alerts until it listens. A start says a few; the cap
--- is only so a loop before it can never grow this.
Log.ALERTS_WAITING = 200

--- How long Log.raised waits before printing under the same name again.
--- An app request is one a player can send again as fast as its allowance
--- lets them, and one that raises every time must not fill the console.
Log.RAISED_EVERY = 300

--- Whether Debug output is on, read at every line.
---@return boolean
function Log.debugOn()
    return type(Config) == 'table' and Config.Debug == true
end

--- The server's clock, where there is one (the client has no os.time).
local function now()
    if type(os) == 'table' and type(os.time) == 'function' then return os.time() end
    return nil
end

--- A line as it is shown: FiveM's colour codes (^0 to ^9) taken out,
--- until none is left. Names, reasons and what a page reports are
--- player-written, and one ending in ^1 would colour everything printed
--- after it; a single pass turned '^^11' into a live '^1'.
---@param text any
---@return string
function Log.plain(text)
    local out, n = tostring(text), 0
    repeat out, n = out:gsub('%^%d', '') until n == 0
    return out
end

--- The one print in the resource.
local function emit(text)
    print(PREFIX .. text)
end

--- Hand a line printed whatever Debug says to the Alerts, or keep it for
--- them until they listen. Only on the server (the client has no clock and
--- no Alerts). Never raises into the caller: a line that could not be kept
--- as an alert is still printed and kept for the diagnosis.
---@param kind string 'always' | 'problem'
---@param text string
local function toAlerts(kind, text)
    local at = now()
    if not at then return end
    if sink then
        pcall(sink, kind, text, at)
    elseif #unheard < Log.ALERTS_WAITING then
        unheard[#unheard + 1] = { kind = kind, text = text, at = at }
    end
end

--- Keep a line for the diagnosis, in `list` (recent or loud) bounded to
--- `cap`. The same line again, or one with the same key (player-worded
--- lines, kept as one counted entry), is counted on the one it repeats.
--- A line of the start is kept with its kind, which the list says.
local function keep(text, list, cap, key)
    if booting then
        if #boot < Log.BOOT_KEPT then
            boot[#boot + 1] = text
            bootKinds[#boot] = list == loud and 'always' or 'debug'
        else
            bootLeft = bootLeft + 1
        end
        return
    end
    seq = seq + 1
    for i = #list, 1, -1 do
        local entry = list[i]
        if (key and entry.key == key) or (not key and not entry.key and entry.text == text) then
            table.remove(list, i)
            entry.text, entry.times, entry.at, entry.seq = text, entry.times + 1, now(), seq
            list[#list + 1] = entry
            return
        end
    end
    list[#list + 1] = { text = text, key = key, at = now(), times = 1, seq = seq }
    while #list > cap do table.remove(list, 1) end
end

--- How many settings this start found that need attention, each problem
--- counted as many times as it names settings.
local function counted()
    local n = 0
    for i = 1, #problems do n = n + problems[i].count end
    return n
end

--- The one line a quiet start says about its problems.
---@return string
function Log.summary()
    local names = type(Config) == 'table' and type(Config.Admin) == 'table'
        and type(Config.Admin.Commands) == 'table' and Config.Admin.Commands or {}
    return ('%d setting(s) need attention; run %s (F8 or the server console) or open /%s to '
        .. 'see them'):format(counted(), tostring(names.diagnose or 'ch-diag'),
            tostring(names.panel or 'hitmanadmin'))
end

--- Printed whatever Debug says. Only for refusing to start, money at risk
--- or left for staff, and a write that failed or read back wrong.
---@param text string
function Log.always(text)
    text = Log.plain(text)
    emit(text)
    keep(text, loud, Log.KEPT_ALWAYS)
    toAlerts('always', text)
end

--- Say how many raises under `name` were held back since the last line
--- printed for it, if any were.
local function sayHeld(name)
    local n = heldBack[name]
    heldBack[name] = nil
    if not n then return end
    local names = type(Config) == 'table' and type(Config.Admin) == 'table'
        and type(Config.Admin.Commands) == 'table' and Config.Admin.Commands or {}
    Log.always(('%s raised %d more time(s) in the %d minutes after the last line printed for '
        .. 'it; run %s (F8 or the server console) to read them')
        :format(name, n, Log.RAISED_EVERY // 60, tostring(names.diagnose or 'ch-diag')))
end

--- A raise in something that may have moved money part-way before it
--- raised: an app request (a cancel whose ending raised, a buyout whose
--- record would not write), a staff command that writes, or the buyout
--- command. Printed whatever Debug says, as the admin panel's own writes
--- are, at most once every Log.RAISED_EVERY seconds for the same name; one
--- in between is a Log.debug line, kept for the diagnosis, and counted in
--- one line printed when those seconds are up. Counted by name alone, a
--- second ending that raised inside them, on another contract and by
--- another player, reached the console as nothing at all.
---@param name string what raised ('request cancel', 'command ch-void')
---@param text string
function Log.raised(name, text)
    local at, last = now(), raisedAt[name]
    if at and last and at - last < Log.RAISED_EVERY then
        heldBack[name] = (heldBack[name] or 0) + 1
        if heldBack[name] == 1 and type(SetTimeout) == 'function' then
            local start = starts
            SetTimeout((Log.RAISED_EVERY - (at - last)) * 1000, function()
                if start == starts then sayHeld(name) end
            end)
        end
        return Log.debug(text)
    end
    raisedAt[name] = at
    sayHeld(name)
    Log.always(text)
end

--- Printed only with Debug on, and kept for the diagnosis either way.
---@param text string
---@param key string|nil lines with the same key are kept as one entry, the
--- newest text counted on it: a line worded by a player (a page fault
--- report) could otherwise fill what is kept with lines of its own
function Log.debug(text, key)
    text = Log.plain(text)
    if Log.debugOn() then emit(text) end
    keep(text, recent, Log.KEPT, key)
end

--- A configuration problem. In full with Debug on; with it off, counted for
--- the start's one line (Log.reportProblems). One found after that line was
--- said (a host list read on the first tick) says the line again with the
--- new count, so it is not missed. The same problem again is not counted
--- twice, nor said again.
---@param text string as it is printed, without the [crimson-hitman] prefix
---@param count integer|nil how many settings it names (default 1)
function Log.problem(text, count)
    text = Log.plain(text)
    for i = 1, #problems do
        if problems[i].text == text then return end
    end
    local entry = { text = text, count = math.max(1, math.floor(tonumber(count) or 1)), printed = false }
    problems[#problems + 1] = entry
    toAlerts('problem', text)
    if Log.debugOn() then
        emit(text)
        entry.printed = true
    elseif reported then
        emit(Log.summary())
    end
end

--- A problem that is not one any more (a host list that has hosts again):
--- no longer listed by the diagnosis, nor counted.
---@param text string as it was given to Log.problem
function Log.dropProblem(text)
    text = Log.plain(text)
    for i = #problems, 1, -1 do
        if problems[i].text == text then table.remove(problems, i) end
    end
end

--- Say this start's problems: each in full with Debug on (those not said
--- yet, Debug having been turned on since they were found), or the one
--- summary line with it off, or nothing when there are none.
---@param full boolean|nil every one in full whatever Debug says: a start
--- refusing to go on, where no diagnosis can be run to read them
---@return integer said lines printed
function Log.reportProblems(full)
    reported = true
    if #problems == 0 then return 0 end
    if full or Log.debugOn() then
        local said = 0
        for i = 1, #problems do
            if not problems[i].printed then
                emit(problems[i].text)
                problems[i].printed = true
                said = said + 1
            end
        end
        return said
    end
    emit(Log.summary())
    return 1
end

--- A staff command's answer, printed as it is (no prefix) to the console
--- that ran it, whatever Debug says.
---@param line string
function Log.console(line)
    print(Log.plain(line))
end

--- A start begins: what an earlier one found and said is forgotten. The
--- Alerts of the last start stop listening; this start's lines wait for
--- this start's (Log.onAlert).
function Log.beginStart()
    problems, boot, recent, loud, raisedAt, heldBack = {}, {}, {}, {}, {}, {}
    bootKinds = {}
    bootLeft = 0
    starts = starts + 1
    reported, booting = false, true
    sink = nil
end

--- Where every line printed whatever Debug says goes besides the console:
--- the server's Alerts (server/alerts.lua). Each line said before this is
--- handed over now, oldest first, with the time it was said.
---@param fn function(kind: string, text: string, at: integer)
function Log.onAlert(fn)
    sink = fn
    local waiting = unheard
    unheard = {}
    for i = 1, #waiting do
        pcall(fn, waiting[i].kind, waiting[i].text, waiting[i].at)
    end
end

--- The start is over: lines from here on are kept as the newest few.
function Log.started()
    booting = false
end

--- Forget the problems found so far (a check run again from scratch).
function Log.clearProblems()
    problems, reported = {}, false
end

--- What is kept, for the diagnosis and the admin panel's Console section:
--- copies, so nothing outside changes them.
--- `recent` is both lists of what came after the start, in the order the
--- lines were said, each with its kind: 'always' (printed whatever Debug
--- says) or 'debug' (printed only with it on). `bootKinds` is the same for
--- each line of `boot`, by its place there; every one of `problems` is a
--- 'problem'.
--- `bootLeft` is how many lines the start said past what is kept of it:
--- a start that said more than Log.BOOT_KEPT lost the rest without a word.
---@return table { problems = string[], count = integer, boot = string[], bootKinds = string[], bootLeft = integer, recent = { text, kind, at, times }[], debug = boolean }
function Log.view()
    local out = { problems = {}, count = counted(), boot = {}, bootKinds = {}, bootLeft = bootLeft,
                  recent = {}, debug = Log.debugOn() }
    for i = 1, #problems do out.problems[i] = problems[i].text end
    for i = 1, #boot do
        out.boot[i] = boot[i]
        out.bootKinds[i] = bootKinds[i] or 'debug'
    end
    local both = {}
    for i = 1, #recent do both[#both + 1] = { entry = recent[i], kind = 'debug' } end
    for i = 1, #loud do both[#both + 1] = { entry = loud[i], kind = 'always' } end
    table.sort(both, function(a, b) return a.entry.seq < b.entry.seq end)
    for i = 1, #both do
        local entry = both[i].entry
        out.recent[i] = { text = entry.text, kind = both[i].kind, at = entry.at, times = entry.times }
    end
    return out
end

CrimsonLog = Log

return Log
