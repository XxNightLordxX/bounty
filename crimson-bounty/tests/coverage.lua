--- Line coverage of the server code, measured by running the whole suite.
---
---   lua5.4 crimson-bounty/tests/coverage.lua
---
--- A report, not a gate. It is deliberately not in all.sh: a coverage
--- number that has to go up is a number people make go up, and the useful
--- output here is the list of lines, not the percentage.
---
--- A line the suite never executes is a line nothing has ever checked, and
--- the interesting ones are the branches that only run when something has
--- gone wrong. What it found on its first run: bridges.lua, the resource's
--- entire interface with the framework, was the second-least covered file
--- in the server — and three of the never-executed lines were net events
--- any player on the server can fire, none of which had a row in the
--- authorisation matrix, because that matrix read app.lua and called it the
--- whole net surface.
---
--- Read the percentages as a rough guide only. The executable-line
--- heuristic below counts a multi-line string literal as statements, so
--- storage/mysql.lua — which holds the schema as one long literal — reads
--- far worse than it is.
local hits = {}

debug.sethook(function(_, line)
    local info = debug.getinfo(2, 'S')
    local src = info and info.short_src
    if src and src:find('crimson%-bounty/server/') then
        hits[src] = hits[src] or {}
        hits[src][line] = (hits[src][line] or 0) + 1
    end
end, 'l')

local realExit = os.exit
os.exit = function() end
pcall(function() dofile('crimson-bounty/tests/run.lua') end)
os.exit = realExit
debug.sethook()

--- Which lines in a file could have been executed at all.
--- Blank lines, comments, `end`, `else` and table punctuation are not
--- statements; counting them makes every file look worse than it is.
local function executable(path)
    local out, n = {}, 0
    local f = io.open(path, 'r')
    if not f then return out, 0 end
    for line in f:lines() do
        n = n + 1
        local t = line:match('^%s*(.-)%s*$')
        if t ~= '' and not t:match('^%-%-')
            and t ~= 'end' and t ~= 'end)' and t ~= 'end,' and t ~= 'end)}'
            and t ~= 'else' and t ~= '}' and t ~= '},' and t ~= '})' and t ~= '{' then
            out[n] = true
        end
    end
    f:close()
    return out, n
end

local files = {}
local pipe = io.popen("find crimson-bounty/server -name '*.lua' | sort")
for line in pipe:lines() do files[#files + 1] = line end
pipe:close()

local rows = {}
local grandRun, grandTotal = 0, 0
for _, path in ipairs(files) do
    local lines = executable(path)
    local total, run, missed = 0, 0, {}
    for lineNo in pairs(lines) do
        total = total + 1
        local seen = hits['./' .. path] or hits[path] or {}
        if seen[lineNo] then run = run + 1 else missed[#missed + 1] = lineNo end
    end
    table.sort(missed)
    grandRun, grandTotal = grandRun + run, grandTotal + total
    rows[#rows + 1] = { path = path, run = run, total = total, missed = missed }
end

table.sort(rows, function(a, b)
    return (a.total - a.run) > (b.total - b.run)
end)

io.write(('\n=== server line coverage: %d/%d (%.1f%%) ===\n\n')
    :format(grandRun, grandTotal, grandTotal > 0 and grandRun / grandTotal * 100 or 0))
for _, r in ipairs(rows) do
    if r.total > 0 then
        io.write(('%-46s %4d/%-4d %5.1f%%  missed %d\n')
            :format(r.path:gsub('crimson%-bounty/server/', ''),
                    r.run, r.total, r.run / r.total * 100, #r.missed))
    end
end

io.write('\n=== the biggest gaps, line by line ===\n')
for i = 1, math.min(6, #rows) do
    local r = rows[i]
    if #r.missed > 0 then
        local runs = {}
        local from = r.missed[1]
        for j = 1, #r.missed do
            if r.missed[j + 1] ~= r.missed[j] + 1 then
                runs[#runs + 1] = from == r.missed[j] and tostring(from)
                    or (from .. '-' .. r.missed[j])
                from = r.missed[j + 1]
            end
        end
        io.write(('\n%s (%d missed)\n  %s\n')
            :format(r.path, #r.missed, table.concat(runs, ' ')))
    end
end
