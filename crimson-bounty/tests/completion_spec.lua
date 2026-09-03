--- Elimination fulfilment: attribution from server-observed damage, capture
--- tokens, and photo verification. Every test here is an attempt to get paid
--- without earning it, except where noted.

local function seeded()
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
    })
    s.contracts.accept(f.hunter, c.id, false)
    -- lb-phone uploads to this host in the harness.
    Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
    s.photo.loadAllowedHosts()
    return s, f, c
end

--- Put the hunter next to the target and kill the target properly.
local function killTarget(s, opts)
    opts = opts or {}
    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    if not opts.skipDamage then
        s.death.recordDamage(opts.attackerSource or 3, 2, 123456)
    end
    Env.players[2].PlayerData.metadata.isdead = not opts.downedOnly
    Env.players[2].PlayerData.metadata.inlaststand = opts.downedOnly or false
    return s.death.onVictimReport(2)
end

describe('death attribution', function()
    it('opens a pending completion when an accepted hunter kills the target', function()
        local s, f, c = seeded()
        eq(killTarget(s), 1, 'one contract attributed')
        truthy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('ignores a death with no damage the server observed', function()
        local s, f, c = seeded()
        eq(killTarget(s, { skipDamage = true }), 0, 'no corroborating damage, no attribution')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('ignores a kill by someone who never accepted the contract', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'RANDOM01', license = 'license:r',
            coords = { x = 100.0, y = 100.0, z = 30.0 } })
        eq(killTarget(s, { attackerSource = 9 }), 0, 'an outsider kill pays nobody')
    end)

    it('does not attribute a downed target as a kill', function()
        local s, f, c = seeded()
        eq(killTarget(s, { downedOnly = true }), 0, 'bleeding out is not a death')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('discards damage from beyond any weapon range', function()
        local s, f, c = seeded()
        Env.players[3]._coords = { x = 0.0, y = 0.0, z = 0.0 }
        Env.players[2]._coords = { x = 5000.0, y = 0.0, z = 0.0 }
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0, 'a hit from 5km away did not happen')
    end)

    it('expires stale damage rather than corroborating a much later death', function()
        local s, f, c = seeded()
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        s.death.recordDamage(3, 2, 123456)
        Env.advance((Config.Completion.DeathReportWindowMs / 1000) + 5)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0, 'damage outside the window cannot corroborate')
    end)

    it('invalidates a pending completion when the target is revived', function()
        local s, f, c = seeded()
        killTarget(s)
        eq(s.death.onRevived('TARGET01'), 1)
        falsy(s.death.getPending(c.id, 'HUNTER01'), 'a revived target was not eliminated')
    end)
end)

describe('capture tokens', function()
    it('is only issued when a pending completion exists', function()
        local s, f, c = seeded()
        local token, err = s.photo.issue(f.hunter, c.id)
        falsy(token, 'no kill, no token')
        eq(err, CB.ERR.BAD_STATE)

        killTarget(s)
        truthy(s.photo.issue(f.hunter, c.id), 'issued after a corroborated kill')
    end)

    it('replaces the previous token, so tokens cannot be banked', function()
        local s, f, c = seeded()
        killTarget(s)
        local first = s.photo.issue(f.hunter, c.id)
        local second = s.photo.issue(f.hunter, c.id)
        truthy(second)
        local ok, err = s.photo.submit(f.hunter, first, 'https://cdn.fivemanage.com/a.png')
        falsy(ok, 'the superseded token is dead')
        eq(err, CB.ERR.TOKEN_INVALID)
    end)
end)

describe('photo verification', function()
    local function ready()
        local s, f, c = seeded()
        killTarget(s)
        local token = s.photo.issue(f.hunter, c.id)
        return s, f, c, token
    end

    it('pays out on a valid submission', function()
        local s, f, c, token = ready()
        local ok, err, result = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/proof.png')
        truthy(ok, tostring(err))
        eq(result.slot, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'baseline paid')
    end)

    it('refuses an image from a host lb-phone does not upload to', function()
        local s, f, c, token = ready()
        for _, url in ipairs({
            'https://evil.example.com/gore.png',
            'https://cdn.fivemanage.com.attacker.net/x.png',
            'http://192.168.1.5/x.png',
            'not-a-url',
        }) do
            local ok, err = s.photo.submit(f.hunter, token, url)
            falsy(ok, 'accepted a foreign image host: ' .. url)
            eq(err, CB.ERR.PHOTO_REJECTED)
        end
    end)

    it('accepts a subdomain of the upload host', function()
        local s, f, c, token = ready()
        truthy(s.photo.submit(f.hunter, token, 'https://eu.cdn.fivemanage.com/proof.png'))
    end)

    it('refuses a token belonging to another hunter', function()
        local s, f, c, token = ready()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            coords = { x = 100.0, y = 100.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        local ok, err = s.photo.submit(s.identity.resolve(4), token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a stolen token is worthless')
        eq(err, CB.ERR.TOKEN_INVALID)
    end)

    it('refuses a photo taken away from the scene', function()
        local s, f, c, token = ready()
        Env.players[3]._coords = { x = 900.0, y = 900.0, z = 30.0 }
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'must be at the body')
        eq(err, CB.ERR.PHOTO_REJECTED)
    end)

    it('refuses a photo once the target has been revived', function()
        local s, f, c, token = ready()
        Env.players[2].PlayerData.metadata.isdead = false
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a living target is not proof of death')
        eq(err, CB.ERR.PHOTO_REJECTED)
    end)

    it('cannot be replayed for a second payout', function()
        local s, f, c, token = ready()
        truthy(s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png'))
        local paid = Env.players[3].PlayerData.money.cash
        local ok = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'single use')
        eq(Env.players[3].PlayerData.money.cash, paid)
    end)

    it('refuses a fabricated token', function()
        local s, f, c = seeded()
        killTarget(s)
        for _, bad in ipairs({ 'tk000000000001', 'aaaaaaaaaaaa', '../../x', 12345 }) do
            local ok = s.photo.submit(f.hunter, bad, 'https://cdn.fivemanage.com/p.png')
            falsy(ok, 'accepted a forged token: ' .. tostring(bad))
        end
    end)

    it('writes a ledger entry for creator, hunter and target', function()
        local s, f, c, token = ready()
        s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        eq(#s.ledger.read('CREATOR1'), 1, 'creator archive')
        eq(#s.ledger.read('HUNTER01'), 1, 'hunter archive')
        eq(#s.ledger.read('TARGET01'), 1, 'target archive')
        truthy(s.ledger.read('CREATOR1')[1].photo_ref, 'creator sees the proof')
        falsy(s.ledger.read('TARGET01')[1].photo_ref, 'the target is not shown their own corpse')
    end)
end)
