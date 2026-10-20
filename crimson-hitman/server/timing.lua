--- How long each maintenance job takes, measured by the job itself.
---
--- The tick runs some twenty jobs one after another on the server's main
--- thread, and the death sampler runs every second on its own. Every
--- performance fault found in them so far (a framework lookup per online
--- player, the whole contract table once a second, the whole ledger
--- rewritten per payout) was invisible from the server: resmon names the
--- resource, never the job. So each run is timed here, a small window of
--- recent runs is kept per job, and a job past Config.Diagnostics.SlowJobMs
--- says so in the console, once in a while rather than every tick. /ch-diag
--- lists the slowest.
---
--- os.clock is processor time, and cheap. On Linux it counts the whole
--- server process, so a busy server's other threads add to a reading. Read
--- as "about this slow", which is what a warning needs.
---
--- But not the time a job spends waiting on the database. On mysql every
--- query is an await that hands the server thread to everything else until
--- the answer comes, and the clock kept running through all of it: on
--- Linux every other resource's work in that gap, on Windows (where
--- os.clock is wall time) the round trip itself. The sampler awaits at least
--- once a pass, so a healthy mysql server was told every five minutes that
--- its jobs were slow, for work other resources did. The store hands each
--- await to Timing.await, which counts its span as waiting, and a job is
--- charged only for the time it held the thread.
---
--- Each job's window is allocated once, on its first run; a run after that
--- writes two numbers into it and allocates nothing.

local Timing = {}

--- Read through the table, so a test can stand a clock of its own in.
Timing.clock = os.clock

--- Runs kept per job: five minutes of ten-second ticks, half a minute of
--- sampler passes.
Timing.WINDOW = 30

--- How often one job may warn: once in this many seconds at most.
Timing.WARN_EVERY_SECONDS = 300

--- [name] = { ms = { ...WINDOW }, n = runs so far, sum = over the window,
---            last = ms, warnedAt = os.time() }
local jobs = {}

--- [coroutine] = clock seconds it has spent inside Timing.await. By the
--- thread, because jobs interleave: a job's await is where another job runs,
--- and with one counter for everybody, the second job's waits were taken
--- off the first job's time, work it did included. Weak, so a thread that
--- has ended is not kept.
local waited = setmetatable({}, { __mode = 'k' })

--- Make a call that may yield the thread to wait (a database round trip),
--- and count the clock it spans as waiting rather than work. Errors pass
--- through as they would from the call itself.
---@param fn function
---@return any, any what fn returns (an oxmysql await returns one value)
function Timing.await(fn, ...)
    local thread = coroutine.running()
    local started = Timing.clock()
    local a, b = fn(...)
    waited[thread] = (waited[thread] or 0) + (Timing.clock() - started)
    return a, b
end

--- The threshold, in ms. 0 (or anything not above zero) is no warning.
local function limit()
    local diagnostics = Config and Config.Diagnostics
    local ms = diagnostics and tonumber(diagnostics.SlowJobMs) or nil
    if not ms or ms ~= ms or ms <= 0 then return nil end
    return ms
end

--- Put one run on a job's record, and warn if it was slow.
---@param name string
---@param ms number
function Timing.record(name, ms)
    local job = jobs[name]
    if not job then
        job = { ms = {}, n = 0, sum = 0, last = 0, warnedAt = nil }
        jobs[name] = job
    end
    local slot = (job.n % Timing.WINDOW) + 1
    job.sum = job.sum - (job.ms[slot] or 0) + ms
    job.ms[slot] = ms
    job.n = job.n + 1
    job.last = ms

    local over = limit()
    if over and ms > over then
        local now = os.time()
        if not job.warnedAt or now - job.warnedAt >= Timing.WARN_EVERY_SECONDS then
            job.warnedAt = now
            print(('[crimson-hitman] maintenance job %q took %.1f ms, over '
                .. 'Config.Diagnostics.SlowJobMs (%s ms). Said at most once every %d '
                .. 'minutes per job; /ch-diag lists the slowest.')
                :format(name, ms, tostring(over), math.floor(Timing.WARN_EVERY_SECONDS / 60)))
        end
    end
end

--- Run one job, timed. Returns what pcall would.
---@param name string
---@param fn function
---@return boolean ok
---@return any err
function Timing.run(name, fn, ...)
    local thread = coroutine.running()
    local waitedBefore = waited[thread] or 0
    local started = Timing.clock()
    local ok, err = pcall(fn, ...)
    local held = (Timing.clock() - started) - ((waited[thread] or 0) - waitedBefore)
    Timing.record(name, math.max(0, held) * 1000)
    return ok, err
end

--- The jobs by their slowest run in the window, slowest first.
---@param count integer|nil at most this many
---@return table[] { name, max, avg, last, runs }
function Timing.slowest(count)
    local out = {}
    for name, job in pairs(jobs) do
        local kept = math.min(job.n, Timing.WINDOW)
        local max = 0
        for i = 1, kept do
            if job.ms[i] > max then max = job.ms[i] end
        end
        out[#out + 1] = {
            name = name, max = max, avg = kept > 0 and job.sum / kept or 0,
            last = job.last, runs = job.n,
        }
    end
    table.sort(out, function(a, b)
        if a.max == b.max then return a.name < b.name end
        return a.max > b.max
    end)
    if count and #out > count then
        for i = #out, count + 1, -1 do out[i] = nil end
    end
    return out
end

return Timing
