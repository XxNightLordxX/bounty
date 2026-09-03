describe('PoC: mugshot arbitrary content', function()
    it('accepts unsolicited non-image content and serves it to other players', function()
        local s = newStack()
        local f = fixture(s)

        -- attacker == the TARGET of a contract. Never asked to render.
        local payload = 'data:image/svg+xml;base64,' ..
            'PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIG9ubG9hZD0iYWxlcnQoMSkiLz4='
        truthy(s.mugshot.store('TARGET01', payload), 'server accepted svg+xml with no render request')
        eq(s.mugshot.get('TARGET01'), payload)

        -- a 256KB blob of anything at all also passes
        local big = 'data:image/x-anything;base64,' .. string.rep('A', 262144 - 30)
        truthy(s.mugshot.store('TARGET01', big), 'accepted 256KB of arbitrary base64')

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c)
        -- HUNTER01 is a third party who merely browses the board
        local listing = s.projection.listing('HUNTER01', 1)
        eq(#listing.contracts, 1)
        eq(listing.contracts[1].targetImage, big, 'attacker-controlled blob reaches a stranger')
        io.stderr:write('bytes pushed per listed contract: ' .. #listing.contracts[1].targetImage .. "\n")
    end)

    it('a stored image pins the cache: invalidate and refresh both become no-ops', function()
        local s = newStack()
        fixture(s)
        truthy(s.mugshot.store('TARGET01', 'data:image/png;base64,AAAA'))
        falsy(s.mugshot.invalidate('TARGET01'), 'appearanceChanged cannot clear a fresh entry')
        eq(s.mugshot.get('TARGET01'), 'data:image/png;base64,AAAA')
    end)
end)

describe('PoC: handles', function()
    it('a target handle minted for one searcher is useless to another', function()
        local s = newStack()
        fixture(s)
        local app = require('crimson-bounty.server.app')
        local h = app.mintTargetHandle('CREATOR1', 'TARGET01')
        truthy(h)
        eq(app.resolveTargetHandle('HUNTER01', h), nil, 'foreign searcher rejected')
        eq(app.resolveTargetHandle('CREATOR1', h), 'TARGET01')
        io.stderr:write('handle shape: ' .. h .. "\n")
    end)
end)

describe('PoC: informant selection is steerable', function()
    it('the buyer picks the index by choosing when to buy', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
                        cash = 5000, bank = 5000, firstname = 'Nel', lastname = 'Vey' })
        Env.addPlayer({ source = 5, citizenid = 'HUNTER03', license = 'license:eee',
                        cash = 5000, bank = 5000, firstname = 'Sam', lastname = 'Orr' })
        s.contracts.accept(f.hunter, c.id, true)
        s.contracts.accept(s.identity.resolve(4), c.id, true)
        s.contracts.accept(s.identity.resolve(5), c.id, true)

        -- ((os.time() + #contractId + purchases) % 3) + 1 -- buyer controls os.time()
        local seen = {}
        for t = 0, 2 do
            local s2 = newStack()
            local f2 = fixture(s2)
            local c2 = s2.contracts.create(f2.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 1000 } } })
            Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
                            cash = 5000, bank = 5000, firstname = 'Nel', lastname = 'Vey' })
            Env.addPlayer({ source = 5, citizenid = 'HUNTER03', license = 'license:eee',
                            cash = 5000, bank = 5000, firstname = 'Sam', lastname = 'Orr' })
            s2.contracts.accept(f2.hunter, c2.id, true)
            s2.contracts.accept(s2.identity.resolve(4), c2.id, true)
            s2.contracts.accept(s2.identity.resolve(5), c2.id, true)
            Env.advance(t)
            Env.players[1].PlayerData.money.bank = 999999
            local ok, err, data = s2.informant.buy(f2.creator, c2.id)
            truthy(ok, tostring(err))
            seen[data.name] = true
            io.stderr:write('t+' .. t .. ' revealed ' .. tostring(data.name) .. "\n")
        end
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        io.stderr:write('distinct hunters unmasked by shifting the clock: ' .. n .. "\n")
        truthy(n > 1, 'the pick follows os.time(), which the buyer chooses')
    end)
end)
