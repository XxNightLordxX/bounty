--- Nothing the resource can do is lost (hard rule 5): every item in
--- tests/inventory/baseline.lua — config keys, settings, panel ops, app
--- requests, events, NUI callbacks, commands, exports, ACEs, audit actions,
--- refusal codes, screens, tick jobs, other resources' exports — is still
--- extracted from the source, or listed in tests/inventory/moved.lua with
--- the current item that now carries it. New items are allowed.
---
--- Regenerating the baseline: docs/dev/map.md, "Capability inventory".

local Extract = require('tests.inventory.extract')

describe('capability inventory', function()
    local baseline = dofile('tests/inventory/baseline.lua')
    local moved = dofile('tests/inventory/moved.lua')
    local current, counts = Extract.run()

    it('reads every category from the source', function()
        truthy(#baseline > 1000, 'baseline read: ' .. #baseline)
        for _, cat in ipairs(Extract.CATEGORIES) do
            -- No resource export exists today; every other category has items.
            if cat[1] ~= 'export' then
                truthy(counts[cat[1]] > 0, 'nothing extracted for ' .. cat[1])
            end
        end
    end)

    it('still has every baseline item, or says where it moved', function()
        local missing, broken = Extract.compare(baseline, current, moved)
        eq(#missing, 0, ('%d capabilities gone without a line in tests/inventory/moved.lua:\n      %s')
            :format(#missing, table.concat(missing, '\n      ')))
        eq(#broken, 0, ('moved.lua names places that do not exist:\n      %s')
            :format(table.concat(broken, '\n      ')))
    end)

    it('flags a dropped item and a move to nowhere, and accepts a real move and a new item', function()
        local base = { 'op:a', 'op:b', 'config:X.Y' }
        local now = { ['op:a'] = true, ['op:c'] = true, ['config:Z'] = true, ['op:new'] = true }
        local missing, broken = Extract.compare(base, now, {})
        eq(table.concat(missing, ','), 'config:X.Y,op:b')
        eq(#broken, 0)
        missing, broken = Extract.compare(base, now, { ['op:b'] = 'op:c', ['config:X.Y'] = { to = 'config:Z' } })
        eq(#missing, 0)
        eq(#broken, 0)
        missing, broken = Extract.compare(base, now, { ['op:b'] = 'op:gone', ['config:X.Y'] = 'config:Z' })
        eq(#missing, 0)
        eq(table.concat(broken, ','), 'op:b -> op:gone')
    end)

    it('has a baseline as the generator writes it (sorted, no repeats)', function()
        local seen = {}
        for i, item in ipairs(baseline) do
            falsy(seen[item], 'repeated in baseline: ' .. item)
            seen[item] = true
            if i > 1 then truthy(baseline[i - 1] < item, 'baseline not sorted at ' .. item) end
        end
    end)
end)
