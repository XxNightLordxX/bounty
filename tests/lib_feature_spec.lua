--- Feature blocks (server/lib/feature.lua): the one way an optional
--- feature's block of config is read (on, block, active) and held to its
--- rules at the start (check), and the rules agreeing with what the admin
--- panel's settings catalogue offers for the same keys.

local Feature = require('server.lib.feature')

describe('Feature: reading a block', function()
    it('is on only while its Enabled is true, read live', function()
        newStack()
        Config.Intel.Rumours.Enabled = false
        eq(Feature.on('Intel.Rumours'), false)
        eq(Feature.active('Intel.Rumours'), nil, 'no block while off')
        Config.Intel.Rumours.Enabled = true
        eq(Feature.on('Intel.Rumours'), true, 'a switch from the panel applies at once')
        eq(Feature.active('Intel.Rumours'), Config.Intel.Rumours, 'the block itself, not a copy')
        Config.Intel.Rumours.Enabled = 'true'
        eq(Feature.on('Intel.Rumours'), false, 'a string is not a switch turned on')
    end)

    it('reads a path to a plain switch as that switch', function()
        newStack()
        Config.Kidnap.MeetingPoint = true
        eq(Feature.on('Kidnap.MeetingPoint'), true)
        Config.Kidnap.MeetingPoint = false
        eq(Feature.on('Kidnap.MeetingPoint'), false)
    end)

    it('answers an empty block, never a raise, for a block that is not there', function()
        newStack()
        Config.Improvements.NoSuchFeature = nil
        eq(next(Feature.block('Improvements.NoSuchFeature')), nil)
        eq(Feature.on('Improvements.NoSuchFeature'), false)
        eq(Feature.on('Nowhere.At.All'), false)
        eq(next(Feature.block('Nowhere.At.All')), nil)
    end)
end)

describe('Feature: the start-up check', function()
    local RULES = {
        Enabled = { kind = 'switch' },
        Hours = { kind = 'number', integer = true, min = 1, max = 24 },
        Mode = { kind = 'choice', choices = { 'a', 'b' } },
        Item = { kind = 'text' },
        Lines = { kind = 'list', each = function(v) return v == 'ok' and v or nil end },
    }

    it('copies a whole block config.lua does not have from what ships, and names it', function()
        newStack()
        ConfigDefaults.Improvements.TestBlock = { Enabled = false, Hours = 4, Mode = 'b', Item = 'card', Lines = {} }
        Config.Improvements.TestBlock = nil
        local warn, filled = {}, {}
        Feature.check('Improvements.TestBlock', RULES, warn, filled)
        ConfigDefaults.Improvements.TestBlock = nil
        eq(Config.Improvements.TestBlock.Hours, 4)
        eq(Config.Improvements.TestBlock.Mode, 'b')
        eq(#warn, 0, 'nothing wrong with a block that is simply missing')
        eq(filled[1], 'Improvements.TestBlock (whole block)')
        Config.Improvements.TestBlock = nil
    end)

    it('puts a value that breaks its rule back to what ships, in words naming the key', function()
        newStack()
        ConfigDefaults.Improvements.TestBlock = { Enabled = false, Hours = 4, Mode = 'b', Item = 'card', Lines = {} }
        Config.Improvements.TestBlock = { Enabled = 'yes', Hours = 40, Mode = 'c', Item = 'a b', Lines = { 'ok', 'no' } }
        local warn, filled = {}, {}
        Feature.check('Improvements.TestBlock', RULES, warn, filled)
        ConfigDefaults.Improvements.TestBlock = nil
        local block = Config.Improvements.TestBlock
        eq(block.Enabled, false)
        eq(block.Hours, 4)
        eq(block.Mode, 'b')
        eq(block.Item, 'card')
        eq(#block.Lines, 0)
        eq(#warn, 5, table.concat(warn, ' | '))
        local all = table.concat(warn, ' | ')
        truthy(all:find('Improvements.TestBlock.Hours is 40; it has to be a whole number from 1 to 24. Using 4.',
            1, true), all)
        eq(#filled, 0, 'nothing was missing')
        Config.Improvements.TestBlock = nil
    end)

    it('fills a missing field quietly into the filled list, and keeps what fits', function()
        newStack()
        ConfigDefaults.Improvements.TestBlock = { Enabled = false, Hours = 4, Mode = 'b', Item = 'card', Lines = {} }
        Config.Improvements.TestBlock = { Enabled = true, Hours = 7, Mode = 'a', Lines = { 'ok' } }
        local warn, filled = {}, {}
        Feature.check('Improvements.TestBlock', RULES, warn, filled)
        ConfigDefaults.Improvements.TestBlock = nil
        eq(Config.Improvements.TestBlock.Item, 'card')
        eq(Config.Improvements.TestBlock.Hours, 7, 'their value stands')
        eq(#warn, 0)
        eq(filled[1], 'Improvements.TestBlock.Item')
        Config.Improvements.TestBlock = nil
    end)

    it('fills from the rule where nothing ships, and never shares the shipped table', function()
        newStack()
        ConfigDefaults.Improvements.TestBlock = nil
        Config.Improvements.TestBlock = {}
        Feature.check('Improvements.TestBlock', RULES, {})
        local block = Config.Improvements.TestBlock
        eq(block.Enabled, false)
        eq(block.Hours, 1)
        eq(block.Mode, 'a')
        eq(type(block.Lines), 'table')
        Config.Improvements.TestBlock = nil
        newStack()
        Config.Intel.Rumours = nil
        Feature.check('Intel.Rumours', { Enabled = { kind = 'switch' } }, {})
        truthy(Config.Intel.Rumours ~= ConfigDefaults.Intel.Rumours, 'a copy')
    end)
end)

describe('Feature: the rules and the settings catalogue', function()
    --- Every rule the start holds a feature block to, against the panel's
    --- entry for the same key: the panel must offer it, and accept exactly
    --- what the start accepts for its kind, range and choices.
    it('every checked setting is in the catalogue, of the same kind and range', function()
        local s = newStack()
        -- Only what the start itself checks (not the blocks made up above).
        for key in pairs(Feature.RULES) do Feature.RULES[key] = nil end
        local ok = require('crimson-hitman.server.main').validateConfig(true)
        truthy(ok, 'the shipped config passes')
        local byKey = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do byKey[entry.key] = entry end
        local keys = {}
        for key in pairs(Feature.RULES) do keys[#keys + 1] = key end
        table.sort(keys)
        truthy(#keys > 100, 'every feature block registered its rules: ' .. #keys)
        local problems = {}
        local function say(key, what) problems[#problems + 1] = key .. ': ' .. what end
        for _, key in ipairs(keys) do
            local rule, entry = Feature.RULES[key], byKey[key]
            if not entry then
                say(key, 'not in the settings catalogue')
            elseif rule.kind ~= entry.kind and not (rule.kind == 'set' and entry.kind == 'list') then
                say(key, ('the start reads a %s, the panel a %s'):format(rule.kind, tostring(entry.kind)))
            elseif rule.kind == 'number' then
                if rule.min ~= entry.min or rule.max ~= entry.max then
                    say(key, ('range %s-%s at the start, %s-%s in the panel'):format(tostring(rule.min),
                        tostring(rule.max), tostring(entry.min), tostring(entry.max)))
                end
                if (rule.integer == true) ~= (entry.integer == true) then say(key, 'whole number or not') end
            elseif rule.kind == 'choice' then
                local a, b = {}, {}
                for _, c in ipairs(rule.choices) do a[#a + 1] = tostring(c) end
                for _, c in ipairs(entry.choices) do b[#b + 1] = tostring(c) end
                table.sort(a)
                table.sort(b)
                if table.concat(a, ',') ~= table.concat(b, ',') then say(key, 'choices differ') end
            elseif rule.kind == 'text' then
                if (rule.max or 64) ~= (entry.maxLength or 64)
                    or (rule.pattern or '^[%w_%-]+$') ~= (entry.pattern or '^[%w_%-]+$') then
                    say(key, 'text rule differs')
                end
            end
        end
        eq(#problems, 0, table.concat(problems, '\n'))
    end)
end)
