--- When the server cannot tell whose account a player is on.
---
--- Identity.accountOf reads the license out of a player's identifiers and
--- falls back to the first identifier it finds. On a deployment where
--- neither is there it returns nil — and nil is where the anti-alt checks
--- go wrong, because `nil ~= nil` is false. Every candidate then looks like
--- another character of the person searching, and the list comes back
--- empty: the whole city filtered out as one player's alts.
---
--- Two unknowns are not the same person. They are two unknowns.

local function call(name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return nil end
    Env.clientEvents = {}
    _G.source = source
    fire(payload or {})
    _G.source = nil
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

--- A server whose players carry no identifiers this resource recognises.
local function withoutIdentifiers(fn)
    local real = _G.GetPlayerIdentifiers
    _G.GetPlayerIdentifiers = function() return {} end
    local ok, err = pcall(fn)
    _G.GetPlayerIdentifiers = real
    if not ok then error(err, 0) end
end

describe('players whose account cannot be identified', function()
    local function crowd(s)
        local f = fixture(s)
        Env.addPlayer({ source = 10, citizenid = 'PERSON10', license = 'license:p10',
            firstname = 'Ada', lastname = 'Quill' })
        Env.addPlayer({ source = 11, citizenid = 'PERSON11', license = 'license:p11',
            firstname = 'Bo', lastname = 'Renn' })
        return f
    end

    it('are still listed when browsing', function()
        local s = newStack()
        crowd(s)
        withoutIdentifiers(function()
            local reply = call('browseTargets', 1, { scope = 'all' })
            truthy(reply and reply.ok, 'the handler must answer')
            truthy(#reply.data.people > 0,
                'an unknown account is not evidence that everyone online is the '
                .. 'same person; the whole city was filtered out as one player')
        end)
    end)

    it('are still found by a name search', function()
        local s = newStack()
        crowd(s)
        withoutIdentifiers(function()
            local reply = call('searchTargets', 1, { query = 'Quill' })
            truthy(reply and reply.ok)
            truthy(#reply.data > 0, 'searching by name must find them too')
        end)
    end)

    it('never list the searcher themselves, account or no account', function()
        local s = newStack()
        crowd(s)
        withoutIdentifiers(function()
            local reply = call('browseTargets', 1, { scope = 'all' })
            for _, person in ipairs(reply.data.people) do
                falsy(person.name == 'Vic Marlowe',
                    'the citizen id still rules the searcher out')
            end
        end)
    end)

    it('still separate two characters that do share a known account', function()
        -- The check has to keep working where it can work. This is what it
        -- is for.
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 10, citizenid = 'ALT01', license = 'license:aaa',
            firstname = 'Vic', lastname = 'Alt' })
        local reply = call('browseTargets', 1, { scope = 'all' })
        truthy(reply and reply.ok)
        for _, person in ipairs(reply.data.people) do
            falsy(person.name == 'Vic Alt',
                'a second character on the searcher own licence is still hidden')
        end
    end)

    it('do not make every acceptance look like collusion', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        withoutIdentifiers(function()
            local hunter = s.identity.resolve(3)
            local ok, err = s.contracts.accept(hunter, c.id, false)
            truthy(ok, 'a hunter with no readable account is not the creator: '
                .. tostring(err))
        end)
    end)
end)


describe('the diagnosis on a server with unreadable accounts', function()
    it('names it, because nothing else would', function()
        local s = newStack()
        fixture(s)
        local real = _G.GetPlayerIdentifiers
        _G.GetPlayerIdentifiers = function() return {} end
        local out = table.concat(s.admin.diagnose(1), '\n')
        _G.GetPlayerIdentifiers = real

        truthy(out:find('account unreadable', 1, true),
            'this emptied the entire target list and left nothing to look at: ' .. out)
        truthy(out:find('licence identifiers', 1, true), out)
    end)

    it('says nothing about it when accounts read fine', function()
        local s = newStack()
        fixture(s)
        local out = table.concat(s.admin.diagnose(1), '\n')
        falsy(out:find('account unreadable', 1, true),
            'a healthy server must not be told it has a problem: ' .. out)
    end)

    it('explains a money-only form rather than only reporting it', function()
        local s = newStack()
        fixture(s)
        withConfig({ { Config.Sources.item, 'enabled', false } }, function()
            local out = table.concat(s.admin.diagnose(1), '\n')
            truthy(out:find('money only', 1, true), out)
            truthy(out:find('predates', 1, true),
                'and say what to do about it: ' .. out)
        end)
    end)

    it('does not throw on a config with no item source at all', function()
        local s = newStack()
        fixture(s)
        local saved = Config.Sources.item
        Config.Sources.item = nil
        local ok, out = pcall(s.admin.diagnose, 1)
        Config.Sources.item = saved

        truthy(ok, 'a diagnosis that throws diagnoses nothing: ' .. tostring(out))
        truthy(table.concat(out, '\n'):find('money only', 1, true))
    end)
end)
