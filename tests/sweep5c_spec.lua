--- Sweep 5, client / UI / config: each fix held to a test that failed on
--- the code before it. The UI halves (every write two clicks or two taps,
--- an armed button kept across a redraw, the bodyguard screens) are in
--- tests/ui/run.js and tests/ui/admin_run.js.
---
---   F1  a staff command, or the buyout command, could be renamed onto
---       another command's name (any case), and one of the two was lost at
---       the next start; a stored row doing so overrode config.lua every
---       start.
---   F2  Completion.PhotoTokenLifetimeSeconds was sent to the game and
---       dropped there: the kill photo camera timed itself from config.lua.
---   F5  the clothing resources' appearance events raised from a server
---       were dropped by the client, registered with AddEventHandler alone.
---   F6  Progression.Resource, an export called by name, was editable from
---       the panel while every other one is read-only.

local Client = require('tests.harness.client')

local CHECK = require('crimson-hitman.server.main').checkCandidate

local function stack()
    local s = newStack()
    fixture(s)
    s.settings.init({ storage = s.storage, audit = s.audit, check = CHECK })
    return s
end

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

--- The checks against a copy of the config with `edit` made to it.
local function checked(edit)
    local candidate = deepCopy(Config)
    edit(candidate)
    local ok, fatal = CHECK(candidate)
    return ok, table.concat(fatal or {}, ' | ')
end

--------------------------------------------------------------------------
-- F1: two commands under one name
--------------------------------------------------------------------------

describe('sweep 5 F1: no two commands share a name', function()
    it('the shipped config passes', function()
        local ok, why = checked(function() end)
        truthy(ok, why)
    end)

    it('a staff command renamed onto the panel is refused at start, naming both', function()
        local ok, why = checked(function(c) c.Admin.Commands.whois = 'hitmanadmin' end)
        falsy(ok, 'two commands named hitmanadmin passed the start-up checks')
        truthy(why:find('Admin.Commands.whois', 1, true), why)
        truthy(why:find('Admin.Commands.panel', 1, true), why)
    end)

    it('in any case: FiveM command names are case-insensitive', function()
        local ok, why = checked(function(c) c.Admin.Commands.stuck = 'CH-Void' end)
        falsy(ok, 'ch-void and CH-Void passed')
        truthy(why:find('Admin.Commands.stuck', 1, true) and why:find('Admin.Commands.void', 1, true), why)
    end)

    it('the buyout command onto the panel, or onto a staff command, is refused', function()
        local ok, why = checked(function(c) c.Bailout.Command = 'hitmanadmin' end)
        falsy(ok, 'the buyout command on the panel passed')
        truthy(why:find('Bailout.Command', 1, true), why)
        ok = checked(function(c) c.Bailout.Command = 'ch-diag' end)
        falsy(ok, 'the buyout command on ch-diag passed')
    end)

    it('and so is a name equal to the panel\'s way out, /<panel>-close', function()
        local ok, why = checked(function(c) c.Admin.Commands.review = 'hitmanadmin-close' end)
        falsy(ok, 'a command named hitmanadmin-close passed')
        truthy(why:find('Admin.Commands.review', 1, true), why)
        ok = checked(function(c) c.Bailout.Command = 'HitmanAdmin-Close' end)
        falsy(ok, 'the buyout command on the panel\'s way out passed')
    end)

    it('the old refresh-on-the-panel config is still moved, not refused', function()
        local ok, why = checked(function(c) c.Admin.Commands.refresh = 'hitmanadmin' end)
        truthy(ok, why)
    end)

    it('the panel refuses a setting that would clash, and takes one that does not', function()
        local s = stack()
        local value, err, why = s.settings.check('Admin.Commands.whois', 'hitmanadmin')
        eq(value, nil, 'whois renamed onto the panel was accepted')
        eq(err, 'invalid_value')
        truthy(tostring(why):find('hitmanadmin', 1, true), tostring(why))
        eq(select(2, s.settings.check('Bailout.Command', 'HITMANADMIN')), 'invalid_value',
            'the buyout command onto the panel, in capitals')
        eq(select(2, s.settings.check('Admin.Commands.panel', 'cleanse')), 'invalid_value',
            'the panel onto the buyout command')
        eq(select(2, s.settings.check('Admin.Commands.void', 'hitmanadmin-close')), 'invalid_value',
            'a command onto the panel\'s way out')
        eq(s.settings.check('Admin.Commands.whois', 'ch-who'), 'ch-who', 'a name of its own is fine')
        local set, setErr = s.settings.set('Admin.Commands.whois', 'hitmanadmin', 'ADMIN001')
        falsy(set, 'set it all the same')
        eq(setErr, 'invalid_value')
    end)

    it('a stored row that clashes is not applied at the start, and config.lua stands', function()
        local s = stack()
        s.storage.writeSetting('Admin.Commands.whois', 'hitmanadmin', 'ADMIN001', os.time())
        s.storage.writeSetting('Admin.Commands.diagnose', 'ch-diagnose', 'ADMIN001', os.time())
        resetConfig()
        s.settings.init({ storage = s.storage, audit = s.audit, check = CHECK })
        eq(s.settings.boot(), 1, 'only the row that clashes with nothing is applied')
        eq(Config.Admin.Commands.whois, 'ch-whois', 'config.lua\'s whois stands')
        eq(Config.Admin.Commands.panel, 'hitmanadmin')
        eq(Config.Admin.Commands.diagnose, 'ch-diagnose')
        local row
        for _, r in ipairs(s.settings.active()) do
            if r.key == 'Admin.Commands.whois' then row = r end
        end
        truthy(row, 'listed')
        falsy(row.applied, 'and marked as not applied')
        resetConfig()
    end)
end)

--------------------------------------------------------------------------
-- F2: the camera's time, from the server
--------------------------------------------------------------------------

describe('sweep 5 F2: the photo token lifetime reaches the game', function()
    it('the game takes Completion.PhotoTokenLifetimeSeconds from the server', function()
        resetConfig()
        Client.boot()
        eq(Config.Completion.PhotoTokenLifetimeSeconds, 120, 'config.lua as shipped')
        Client.fire('crimson-hitman:settings', { ['Completion.PhotoTokenLifetimeSeconds'] = 600 })
        eq(Config.Completion.PhotoTokenLifetimeSeconds, 600, 'the server\'s value is in force here')
        Client.fire('crimson-hitman:settings', { ['Completion.PhotoTokenLifetimeSeconds'] = '30' })
        eq(Config.Completion.PhotoTokenLifetimeSeconds, 600, 'a value of the wrong type is not taken')
        resetConfig()
    end)

    it('every setting the server sends the game is one the game takes', function()
        local fh = assert(io.open('crimson-hitman/client/main.lua', 'r'))
        local source = fh:read('a')
        fh:close()
        local block = source:match('local CLIENT_SETTINGS = (%b{})')
        truthy(block, 'CLIENT_SETTINGS found')
        local taken = {}
        for key in block:gmatch("%['([%w_%.]+)'%]%s*=") do taken[key] = true end
        local missing = {}
        for _, entry in ipairs(require('crimson-hitman.server.settings').CATALOGUE) do
            if entry.client and not taken[entry.key] then missing[#missing + 1] = entry.key end
        end
        eq(#missing, 0, 'sent to the game and dropped there: ' .. table.concat(missing, ', '))
    end)
end)

--------------------------------------------------------------------------
-- F5: appearance events from the server
--------------------------------------------------------------------------

describe('sweep 5 F5: a clothing resource\'s event from the server reaches the mugshot', function()
    it('each is registered as a net event, and announces the change', function()
        Client.boot()
        for _, event in ipairs({ 'qb-clothing:client:loadOutfit', 'illenium-appearance:client:reloadSkin',
                                 'rcore_clothing:outfitChanged' }) do
            truthy(Client.netEvents[event], event .. ' is not a net event: a server-raised copy is dropped')
            Client.toServer = {}
            Client.fire(event)
            local told = false
            for _, sent in ipairs(Client.toServer) do
                if sent.name == 'crimson-hitman:appearanceChanged' then told = true end
            end
            truthy(told, event .. ' did not announce the change')
        end
        falsy(Client.netEvents['crimson-hitman:appearanceChanged'], 'our own stays a local event')
        truthy(Client.handlers['crimson-hitman:appearanceChanged'], 'and is still handled')
    end)
end)

--------------------------------------------------------------------------
-- F6: the progression export, read-only
--------------------------------------------------------------------------

describe('sweep 5 F6: Progression.Resource is read-only, as every export called by name is', function()
    it('the panel refuses to change it and says why', function()
        local s = stack()
        local value, err, why = s.settings.check('Progression.Resource', 'my-blackmarket')
        eq(value, nil)
        eq(err, 'read_only')
        truthy(tostring(why):find('called by name', 1, true), tostring(why))
        falsy(s.settings.set('Progression.Resource', 'my-blackmarket', 'ADMIN001'))
        eq(Config.Progression.Resource, 'sc-blackmarket')
    end)

    it('it is listed among the keys edited in config.lua', function()
        local s = stack()
        local found
        for _, row in ipairs(s.settings.view().readonly) do
            if row.key == 'Progression.Resource' then found = row end
        end
        truthy(found, 'not on the read-only list')
        truthy(found.denied, 'as one changed only in config.lua')
        eq(found.value, 'sc-blackmarket')
    end)

    it('a row stored before is not applied at the start', function()
        local s = stack()
        s.storage.writeSetting('Progression.Resource', 'my-blackmarket', 'ADMIN001', os.time())
        resetConfig()
        s.settings.init({ storage = s.storage, audit = s.audit, check = CHECK })
        eq(s.settings.boot(), 0)
        eq(Config.Progression.Resource, 'sc-blackmarket')
        resetConfig()
    end)
end)
