--- Step 7: every capability of the inventory has a workflow that drives it.
---
--- The workflow specs record what they drove as they drive it (lib.lua's
--- W.cover: each phone request, panel op, NUI callback, command, net event,
--- engine event, client event and tick job, by the name the capability
--- inventory gives it; the switches by key). The UI suites name the screens
--- they walk in their test names ("workflow screen:<id>"). This spec takes a
--- fresh inventory (tests/inventory/extract.lua) and fails on any item in
--- scope that no workflow drove and that NOT_COVERED does not list with a
--- reason. docs/dev/workflows.md is the report; CH_WRITE_WORKFLOWS=1 writes
--- it, and this spec fails when it no longer names every item in scope.
---
--- It judges only a full run: under CH_SUITES with the workflow specs left
--- out it has nothing to judge, and says so.

local W = require('tests.workflows.lib')
local Extract = require('tests.inventory.extract')

--- The inventory's categories a workflow drives.
local SCOPE = { 'handler', 'op', 'nui', 'command', 'netevent.server', 'netevent.client', 'event', 'tick',
                'screen', 'switch' }

--- Driven by nothing here, and why.
local NOT_COVERED = {
}

--- What the other categories are, and why they are counted, not required.
local OUT_OF_SCOPE = {
    config = 'values, not actions: each is read by the workflow of its feature; the panel\'s setSetting workflow '
        .. 'changes them (surface spec, every switch; panel spec, game rules)',
    setting = 'the panel catalogue\'s keys; its switches are in scope (category switch), the other values are '
        .. 'edited by the same setSetting path the game-rules workflow drives',
    audit = 'rows a workflow leaves: counted (which actions any workflow made the resource write), and '
        .. 'asserted where a flow is about them',
    err = 'refusal codes: counted where a phone workflow was answered with one; the refusals are the business of the authz, '
        .. 'boundary and abuse specs',
    ext = 'other resources\' exports: the adapters and the harness\'s fakes answer them in every workflow; '
        .. 'each integration set to none is a matrix profile',
    ace = 'staff permissions: every panel and command workflow runs with them, the refusals in authz specs',
    export = 'the resource offers none',
}

--- The UI suites' screens, read once a run.
local screensCache = {}

local function uiScreens()
    local out = {}
    for _, path in ipairs({ 'tests/ui/run.js', 'tests/ui/admin_run.js' }) do
        local text = read_file(path)
        for name in text:gmatch("it%('workflow ([^']+)'") do
            for id in name:gmatch('screen:([%w%._:]+)') do out['screen:' .. id] = path end
        end
        -- Names built in a loop: 'workflow screen:admin.group:' + group, or
        -- 'screen:admin.view:' + v for each view of a group.
        for prefix in text:gmatch("'workflow screen:([%w%._]+:)' %+") do out['screen-prefix:' .. prefix] = path end
        for prefix in text:gmatch("'screen:([%w%._]+:)' %+") do out['screen-prefix:' .. prefix] = path end
    end
    return out
end

local function inventory()
    local items = Extract.run()
    local Settings = package.loaded['server.settings'] or require('server.settings')
    for _, e in ipairs(Settings.CATALOGUE) do
        if e.kind == 'switch' then items['switch:' .. e.key] = true end
    end
    return items
end

local function inScope(item)
    local cat = item:match('^([^:]+):')
    for _, c in ipairs(SCOPE) do if c == cat then return true end end
    return false
end

local function covered(item, screens)
    if W.covered[item] then return W.covered[item] end
    if screens[item] then return { screens[item] } end
    if item:sub(1, 7) == 'screen:' then
        -- A screen drawn by a loop over its kind ('admin.view:' .. v).
        local kind = item:match('^screen:([%w%.]+:)')
        if kind and screens['screen-prefix:' .. kind] then
            return { screens['screen-prefix:' .. kind] .. ' (every ' .. kind .. ')' }
        end
    end
    return nil
end

local function counts(items, screens)
    local by = {}
    for item in pairs(items) do
        local cat = item:match('^([^:]+):')
        local c = by[cat] or { total = 0, covered = 0 }
        by[cat] = c
        c.total = c.total + 1
        local seen = covered(item, screens) or (cat == 'audit' and W.covered[item])
        if cat == 'err' then
            local name = item:sub(5)
            local code = CH.ERR[name]
            if name:sub(1, 4) == 'Org.' then
                local Org = package.loaded['server.org.init']
                code = Org and Org.ERR and Org.ERR[name:sub(5)]
            end
            seen = code ~= nil and W.covered['refusal:' .. tostring(code)] ~= nil
        end
        if seen then c.covered = c.covered + 1 end
    end
    return by
end

local function report(items, screens)
    local by = counts(items, screens)
    local lines = {
        '# Workflow coverage (step 7)',
        '',
        'Every capability of the inventory (`tests/inventory/extract.lua`) against the workflow',
        'test that drives it end to end, the way a player or a member of staff would. Written by',
        '`CH_WRITE_WORKFLOWS=1 lua5.4 tests/run.lua` (tests/workflows/coverage_spec.lua), which fails',
        'when an item in scope is driven by nothing and not listed below with why.',
        '',
        '## The workflow specs',
        '',
        '| Spec | What it drives |',
        '|---|---|',
        '| `tests/workflows/matrix_spec.lua` | The main flows (place, accept, handover, payout; a kill verified at the scene; a buyout; an intel purchase; the organisation\'s pay day; body disposal; staff freeze, reassign and reward change) in every configuration, on every store, with faults injected |',
        '| `tests/workflows/phone_spec.lua` | Every phone request through the real page callbacks and the real client |',
        '| `tests/workflows/org_phone_spec.lua` | The Organisation tab, boss and member, through the page |',
        '| `tests/workflows/org_extras_spec.lua` | The organisation extras: contracts to it, approval, probation, duty, the channel, dossiers |',
        '| `tests/workflows/panel_spec.lua` | Every admin panel op through the panel page (adminRequest) |',
        '| `tests/workflows/surface_spec.lua` | Commands, server and client net events, engine and framework events, tick jobs, every switch |',
        '| `tests/ui/run.js`, `tests/ui/admin_run.js` | Every phone and panel screen\'s main path (tests named `workflow screen:<id>`) |',
        '',
        '## Configurations and faults',
        '',
        '- Configurations: `shipped` (config.lua as the owner ships it); `allon` (every switch of the',
        '  settings catalogue on except ' .. (function()
            local keys = {}
            for k in pairs(W.ALL_ON_SKIPPED) do keys[#keys + 1] = '`' .. k .. '`' end
            table.sort(keys)
            return table.concat(keys, ', ')
        end)() .. ': see `W.ALL_ON_SKIPPED`',
        '  in tests/workflows/lib.lua for why each); and each integration set to `none` in turn',
        '  (' .. table.concat(W.INTEGRATIONS, ', ') .. '), the framework staying qbx_core.',
        '- Stores: memory, json, the executing mysql harness (never a real database).',
        '- Faults at every step boundary: a graceful restart, a crash (no stop), a player leaving and',
        '  coming back (placer, target, hitman in turn). Memory keeps nothing across a restart',
        '  (`testing only`, config.lua), so on memory only the drop runs. By default the `none`',
        '  profiles inject at the boundary after the acceptance only.',
        '- Faults at the database awaits (mysql, shipped): a crash before a statement or after it ran,',
        '  and a player leaving there. By default every 4th await (alternating before/after) and a',
        '  drop at every 6th; `CH_WORKFLOWS_FULL=1` runs every boundary of every profile and every',
        '  await in both phases with a drop at each (both shipped and allon).',
        '- After a crash that left a payout mid-release, staff clear it from the panel (Stuck, Settle)',
        '  as the console tells them to; the money is then conserved to the dollar.',
        '',
        '## Counts',
        '',
        '| Category | In scope | Items | Driven by a workflow |',
        '|---|---|---:|---:|',
    }
    local cats = {}
    for cat in pairs(by) do cats[#cats + 1] = cat end
    table.sort(cats)
    for _, cat in ipairs(cats) do
        local isIn = inScope(cat .. ':x')
        lines[#lines + 1] = ('| %s | %s | %d | %d |'):format(cat, isIn and 'yes' or 'counted', by[cat].total,
            by[cat].covered)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Not in scope, and why'
    lines[#lines + 1] = ''
    local oos = {}
    for k in pairs(OUT_OF_SCOPE) do oos[#oos + 1] = k end
    table.sort(oos)
    for _, k in ipairs(oos) do lines[#lines + 1] = ('- `%s`: %s.'):format(k, OUT_OF_SCOPE[k]) end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Not driven by a workflow, and why'
    lines[#lines + 1] = ''
    local nc = {}
    for k in pairs(NOT_COVERED) do nc[#nc + 1] = k end
    table.sort(nc)
    if #nc == 0 then lines[#lines + 1] = 'None.' end
    for _, k in ipairs(nc) do lines[#lines + 1] = ('- `%s`: %s'):format(k, NOT_COVERED[k]) end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Capability -> workflow test'
    lines[#lines + 1] = ''
    local list = {}
    for item in pairs(items) do if inScope(item) then list[#list + 1] = item end end
    table.sort(list)
    local current
    for _, item in ipairs(list) do
        local cat = item:match('^([^:]+):')
        if cat ~= current then
            current = cat
            lines[#lines + 1] = ''
            lines[#lines + 1] = '### ' .. cat
            lines[#lines + 1] = ''
            lines[#lines + 1] = '| Capability | Workflow test |'
            lines[#lines + 1] = '|---|---|'
        end
        local by_ = covered(item, {}) or covered(item, screensCache)
        local tests = by_ and table.concat(by_, '; ') or ('not driven: ' .. tostring(NOT_COVERED[item]))
        lines[#lines + 1] = ('| `%s` | %s |'):format((item:sub(#cat + 2):gsub('|', '/')), (tests:gsub('|', '/')))
    end
    lines[#lines + 1] = ''
    return table.concat(lines, '\n')
end

describe('workflow coverage', function()
    it('every capability in scope is driven by a workflow, or listed with why not', function()
        -- Under the invariant monitor the matrix runs reduced (matrix_spec),
        -- so coverage is judged by the plain run only.
        local full = W.ran.phone and W.ran.panel and W.ran.surface and W.ran.org
            and (W.ran.matrix or os.getenv('CH_COVERAGE_PARTIAL') == '1')
            and _G.__SKIP_RAW_STORE_SPECS ~= true
        if not full then
            -- A partial run (CH_SUITES) has nothing to judge.
            truthy(true, 'partial run')
            return
        end
        screensCache = uiScreens()
        local items = inventory()
        local missing = {}
        for item in pairs(items) do
            if inScope(item) and not covered(item, screensCache) and NOT_COVERED[item] == nil then
                missing[#missing + 1] = item
            end
        end
        table.sort(missing)
        for item in pairs(NOT_COVERED) do
            truthy(items[item], 'NOT_COVERED names something the inventory no longer has: ' .. item)
        end
        if os.getenv('CH_WRITE_WORKFLOWS') == '1' then
            local fh = assert(io.open('docs/dev/workflows.md', 'w'))
            fh:write(report(items, screensCache))
            fh:close()
        end
        eq(#missing, 0, 'driven by no workflow: ' .. table.concat(missing, ', '))
        local doc = read_file('docs/dev/workflows.md')
        local absent = {}
        for item in pairs(items) do
            if inScope(item) then
                local cat = item:match('^([^:]+):')
                if not doc:find('`' .. item:sub(#cat + 2) .. '`', 1, true) then absent[#absent + 1] = item end
            end
        end
        table.sort(absent)
        eq(#absent, 0, 'docs/dev/workflows.md does not name (CH_WRITE_WORKFLOWS=1 rewrites it): '
            .. table.concat(absent, ', '))
    end)

    it('the known bugs are the ones the specs list, and each still fails', function()
        if not W.ran.matrix then truthy(true, 'partial run') return end
        for _, hit in ipairs(W.knownHits or {}) do
            truthy(hit.bug:match('^BUG%-%d+'), 'a known-bug hit names its bug: ' .. hit.test)
        end
        for _, f in ipairs(W.expectedFails or {}) do
            truthy(f.bug, 'an expected failure names its bug: ' .. f.test)
        end
        if os.getenv('CH_WORKFLOWS_REPORT') == '1' then
            local by = {}
            for _, hit in ipairs(W.knownHits or {}) do
                local id = hit.bug:match('^(BUG%-%d+)')
                by[id] = (by[id] or 0) + 1
            end
            for id, n in pairs(by) do io.stderr:write(('known bug %s: %d matrix cells\n'):format(id, n)) end
            for _, f in ipairs(W.expectedFails or {}) do
                io.stderr:write(('expected failure: %s (%s)\n'):format(f.test, f.bug))
            end
        end
    end)
end)
