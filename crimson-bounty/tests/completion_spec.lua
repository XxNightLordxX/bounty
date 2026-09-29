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
        -- Real damage: the server sees the victim's health fall. A claim
        -- without an observed decrease is not corroborated.
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
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
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0, 'a hit from 5km away did not happen')
    end)

    it('expires stale damage rather than corroborating a much later death', function()
        local s, f, c = seeded()
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.advance((Config.Completion.DeathReportWindowMs / 1000) + 5)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0, 'damage outside the window cannot corroborate')
    end)

    it('keeps a pending completion alive through an immediate respawn', function()
        local s, f, c = seeded()
        killTarget(s)
        eq(s.death.onRevived('TARGET01'), 0,
            'a target pressing respawn must not erase a kill that just happened')
        truthy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('invalidates a pending completion when the revive comes later', function()
        local s, f, c = seeded()
        killTarget(s)
        Env.advance(Config.Completion.ProofWindowSeconds + 10)
        eq(s.death.onRevived('TARGET01'), 1)
        falsy(s.death.getPending(c.id, 'HUNTER01'), 'a revived target was not eliminated')
    end)
end)

describe('capture tokens', function()
    it('is only issued when a pending completion exists', function()
        local s, f, c = seeded()
        local token, err = s.photo.issue(f.hunter, c.id)
        falsy(token, 'no kill, no token')
        eq(err, CB.ERR.NO_KILL_TO_VERIFY,
            'the commonest tap of Verify kill: the button is on every '
            .. 'accepted contract whether or not a kill has happened, so '
            .. 'this answer needs to say what is actually required')

        killTarget(s)
        truthy(s.photo.issue(f.hunter, c.id), 'issued after a corroborated kill')
    end)

    it('has nothing left to claim by the time the client gives up on the camera', function()
        -- client/main.lua answers camera_no_answer PhotoTokenLifetimeSeconds
        -- after the camera opened, and the camera cannot open before the
        -- kill. The page's words for that code are held to this: it used to
        -- say "the kill is still yours to claim - try again".
        local s, f, c = seeded()
        killTarget(s)
        truthy(s.photo.issue(f.hunter, c.id), 'the camera opens on a live kill')

        Env.advance(Config.Completion.PhotoTokenLifetimeSeconds + 1)
        local token, err = s.photo.issue(f.hunter, c.id)
        falsy(token)
        eq(err, CB.ERR.NO_KILL_TO_VERIFY)
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
            eq(err, CB.ERR.PHOTO_BAD_HOST)
        end
    end)

    it('rejects a URL whose userinfo impersonates the upload host', function()
        local s, f, c, token = ready()
        -- Each of these fetches from somewhere other than the trusted host,
        -- while a naive parser reports the trusted host.
        for _, url in ipairs({
            'https://cdn.fivemanage.com@198.51.100.7/grab.png',
            'https://cdn.fivemanage.com:8080@evil.tld/x.png',
            'https://cdn.fivemanage.com%40evil.tld/x.png',
            'https://user:pass@cdn.fivemanage.com.evil.tld/x.png',
        }) do
            local ok, err = s.photo.submit(f.hunter, token, url)
            falsy(ok, 'accepted a spoofed host: ' .. url)
            eq(err, CB.ERR.PHOTO_BAD_HOST)
        end
    end)

    it('rejects a URL longer than the stored column holds', function()
        local s, f, c, token = ready()
        local long = 'https://cdn.fivemanage.com/' .. string.rep('a', 600) .. '.png'
        local ok, err = s.photo.submit(f.hunter, token, long)
        falsy(ok, 'an over-length URL would be truncated in storage')
        eq(err, CB.ERR.PHOTO_BAD_HOST)
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
        eq(err, CB.ERR.PHOTO_TOO_FAR)
    end)

    it('accepts a photo taken right after the target respawned', function()
        local s, f, c, token = ready()
        Env.players[2].PlayerData.metadata.isdead = false
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the kill happened; respawning is not a defence: ' .. tostring(err))
    end)

    it('accepts a photo taken late on a token taken late, with the body still down', function()
        -- The token is good for its lifetime from when it was issued; the
        -- kill it proves lapsed that long after the death. A hunter who
        -- tapped Verify late was told the target had been revived.
        local s, f, c = seeded()
        killTarget(s)
        local lifetime = Config.Completion.PhotoTokenLifetimeSeconds
        Env.advance(lifetime - 20)
        local token = s.photo.issue(f.hunter, c.id)
        truthy(token)
        Env.advance(25)
        s.death.sweep()
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the body is still on the ground: ' .. tostring(err))
    end)

    it('does not keep a kill alive by asking for token after token', function()
        -- Each token held the kill for its own lifetime, and a token can be
        -- asked for while the kill is held: a hunter asking every few
        -- minutes could claim a target revived out of the watcher's sight
        -- an hour later. Two lifetimes from the death is the most.
        local s, f, c = seeded()
        killTarget(s)
        local lifetime = Config.Completion.PhotoTokenLifetimeSeconds
        local token
        for _ = 1, 6 do
            Env.advance(lifetime - 5)
            token = s.photo.issue(f.hunter, c.id) or token
            s.death.sweep()
        end
        eq(s.death.getPending(c.id, 'HUNTER01'), nil, 'the kill lapsed')
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'paid for a kill six lifetimes old')
        truthy(err == CB.ERR.PHOTO_REVIVED or err == CB.ERR.TOKEN_INVALID, tostring(err))
    end)

    it('holds the kill for a token asked for at the end of its window', function()
        local s, f, c = seeded()
        killTarget(s)
        local lifetime = Config.Completion.PhotoTokenLifetimeSeconds
        Env.advance(lifetime - 1)
        local token = s.photo.issue(f.hunter, c.id)
        truthy(token)
        Env.advance(lifetime - 2)
        s.death.sweep()
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the first token outlived its own kill: ' .. tostring(err))
    end)

    it('says a token asked for late has expired, not that the target was revived', function()
        -- The second token outlived the kill it proved, and the photograph
        -- was refused as a revive with the body still on the ground.
        local s, f, c = seeded()
        killTarget(s)
        local lifetime = Config.Completion.PhotoTokenLifetimeSeconds
        Env.advance(lifetime - 10)
        truthy(s.photo.issue(f.hunter, c.id))
        Env.advance(lifetime - 10)
        local token = s.photo.issue(f.hunter, c.id)
        truthy(token, 'the kill is held by the first token')
        Env.advance(30)
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok)
        eq(err, CB.ERR.TOKEN_INVALID, 'told the target was revived: ' .. tostring(err))
    end)

    it('tells a hunter a target shocked back to last stand is still down', function()
        local s, f, c, token = ready()
        local meta = Env.players[2].PlayerData.metadata
        meta.isdead, meta.inlaststand = false, true
        Env.advance(Config.Completion.ProofWindowSeconds + 10)
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'last stand is not a kill')
        eq(err, CB.ERR.PHOTO_STILL_DOWN)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the kill was thrown away')

        -- Finished on the ground: a new kill, and a new photograph for it.
        s.death.watch('TARGET01', 2, true)
        Env.players[2]._health = Env.players[2]._health - 30
        s.death.recordDamage(3, 2, 123456)
        meta.isdead, meta.inlaststand = true, false
        truthy(s.death.onVictimReport(2) >= 1)
        local _, stale = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        eq(stale, CB.ERR.TOKEN_INVALID, 'the old token is for the old kill')
        local fresh = s.photo.issue(f.hunter, c.id)
        local paid, why = s.photo.submit(f.hunter, fresh, 'https://cdn.fivemanage.com/p.png')
        truthy(paid, 'the finishing kill pays: ' .. tostring(why))
    end)

    it('refuses a photo long after the target was revived', function()
        local s, f, c, token = ready()
        Env.players[2].PlayerData.metadata.isdead = false
        -- Seen up by the server's watch, and still up when it looks again.
        s.death.watchTargets(s.storage.allContracts())
        Env.advance(Config.Completion.ProofWindowSeconds + 10)
        s.death.watchTargets(s.storage.allContracts())
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a target who has been up and about for a minute is not proof of death')
        eq(err, CB.ERR.PHOTO_REVIVED)
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

describe('damage observation is actually wired', function()
    --- The elimination payout depends on a single engine event being
    --- registered. Calling Death.recordDamage directly proves the function
    --- works, not that anything ever calls it — so these tests go through
    --- the real registration path.

    local function wiredStack()
        local s = newStack()
        s.bridges.install(s)
        return s
    end

    it('registers a weaponDamageEvent handler', function()
        local s = wiredStack()
        truthy(Env.handlers['weaponDamageEvent'],
            'nothing would ever record damage, so no kill could be attributed')
    end)

    it('attributes a kill end to end through the registered handler', function()
        local s = wiredStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)

        Env.players[3]._coords = { x = 50.0, y = 50.0, z = 30.0 }
        Env.players[2]._coords = { x = 51.0, y = 50.0, z = 30.0 }
        Env.players[2]._health = 120   -- the server sees the health drop

        -- The engine reports the hit; nothing here is asserted by a player.
        Env.handlers['weaponDamageEvent'](3, {
            weaponDamage = 50,
            weaponType = 123456,
            hitGlobalIds = { 1002 },   -- the target's ped
        })

        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1, 'the kill should now be attributable')
        truthy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    --- On a live server the event comes first: weaponDamageEvent is the
    --- shooter's game asking for the hit, and the victim's health reaches the
    --- server only once their game has applied it. Read at the event, a lone
    --- shot never showed any damage.
    local function placed(s)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        Env.players[3]._coords = { x = 50.0, y = 50.0, z = 30.0 }
        Env.players[2]._coords = { x = 51.0, y = 50.0, z = 30.0 }
        s.death.watchTargets(s.storage.allContracts())
        return f, c
    end

    local function shoot(attacker)
        Env.handlers['weaponDamageEvent'](attacker, {
            weaponDamage = 50, weaponType = 123456, hitGlobalIds = { 1002 },
        })
    end

    it('credits a single shot whose damage lands after the event', function()
        local s = wiredStack()
        local f, c = placed(s)
        shoot(3)                          -- the event, before any damage
        Env.players[2]._health = 150      -- then the victim's game applies it
        Env.advance(0.3)
        shoot(3)                          -- the finishing shot, the same way
        Env.players[2]._health = 0
        Env.players[2].PlayerData.metadata.isdead = true
        Env.advance(0.3)
        s.death.onVictimReport(2)
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'),
            'a target downed with one shot and finished with another opened no kill')
    end)

    it('waits for the finishing shot when the death is reported first', function()
        local s = wiredStack()
        local f, c = placed(s)
        shoot(3)
        Env.players[2]._health = 0
        Env.players[2].PlayerData.metadata.isdead = true
        -- The death report arrives before any check of the shot has run.
        eq(s.death.onVictimReport(2), 0, 'attributed before the hit was checked')
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the kill went to nobody')
    end)

    it('does not lose a hit to the sampler looking before the damage lands', function()
        local s = wiredStack()
        local f, c = placed(s)
        shoot(3)
        s.death.watchTargets(s.storage.allContracts())   -- a sample, pre-damage
        Env.players[2]._health = 120
        Env.advance(0.5)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'the sample erased the hit')
    end)

    it('credits one drop to one hit, the one the victim\'s game names', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        shoot(3)
        shoot(4)                          -- claims a hit it never landed
        Env.players[2]._health = 110      -- one shot's damage
        Env.players[2]._damageSource = 1003
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'))
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'one drop credited twice')
    end)

    it('gives a drop between two hunters the victim\'s game cannot name to neither', function()
        -- sc-ambulance has cleared who did it, as it nearly always has. First
        -- in line took it: a rival's event sent a moment before an honest
        -- shot took the shot's damage, and the kill.
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        shoot(4)                          -- the rival's, first, with nothing behind it
        shoot(3)
        Env.players[2]._health = 130
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'the rival took the shot\'s damage')
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'one of two was guessed at')
    end)

    --- The victim's own game telling the server who hit it, as the client
    --- does on each damage event that reaches it.
    local function told(victim, attacker)
        _G.source = victim
        local ok, err = pcall(Env.events['crimson-bounty:hitBy'], attacker)
        _G.source = nil
        truthy(ok, tostring(err))
    end

    local function rival(s, c)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
    end

    it('gives a drop between two hunters to the one the victim\'s game says hit it', function()
        -- A forged event never reaches the victim's game. Its word on who
        -- hit it tells the shot that landed from the one that was only sent,
        -- where sc-ambulance has cleared the engine's own.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        shoot(4)                          -- forged: no round behind it
        shoot(3)                          -- the real one
        Env.players[2]._health = 130
        Env.advance(0.08)                 -- the first check waits for its word
        told(2, 3)
        Env.advance(2)
        local one = s.death.recordFor('TARGET01', 'HUNTER01')
        truthy(one and one.damage == 70, 'the shooter lost their hit')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'the forger was credited')
    end)

    it('does not wait on the victim\'s word for ever', function()
        -- Its word arriving after the drop is settled does not reopen it.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        shoot(4)
        shoot(3)
        Env.players[2]._health = 130
        Env.advance(0.3)
        told(2, 3)
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'a late word reopened a settled drop')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'))
    end)

    it('credits the one hunter the victim named since the hit, not before it', function()
        -- Named for a hit two seconds ago; this drop is somebody else's.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        told(2, 4)
        Env.advance(1)
        shoot(4)
        shoot(3)
        Env.players[2]._health = 130
        Env.advance(0.08)
        told(2, 3)
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'the shooter lost their hit')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'an old report named this drop')
    end)

    it('takes a report as standing for the round just before it, as the client sends one a tenth of a second', function()
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        told(2, 3)                        -- the burst's first round, told
        Env.advance(0.06)
        shoot(4)
        shoot(3)                          -- its second, which goes untold
        Env.players[2]._health = 130
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'a burst\'s second round was guessed at')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'))
    end)

    it('does not let one drop nobody could settle cloud every one after it', function()
        -- A rival's stray event beside an honest hunter's first round: that
        -- drop is nobody's. The hunter's next four rounds are theirs alone.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        shoot(3)
        shoot(4)
        Env.players[2]._health = 180
        Env.advance(0.3)
        local health = 180
        for _ = 1, 4 do
            shoot(3)
            health = health - 20
            Env.players[2]._health = health
            Env.advance(0.1)
        end
        Env.advance(2)
        local one = s.death.recordFor('TARGET01', 'HUNTER01')
        truthy(one and one.damage == 20, 'the honest hunter\'s later rounds were written off')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'the stray event was paid')
    end)

    it('waits for the victim\'s word before a death report settles the kill', function()
        -- The death reported while a drop two hunters wait on is still
        -- waiting on who landed it.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        shoot(4)
        shoot(3)
        Env.players[2]._health = 0
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0)
        Env.advance(0.08)
        told(2, 3)
        Env.advance(3)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the kill went to nobody')
        falsy(s.death.getPending(c.id, 'HUNTER02'), 'the forger took the kill')
    end)

    it('does not credit a drop already showing to a hunter the victim did not name', function()
        -- The victim said a rival hit them since the last reading, and never
        -- this hunter: the damage showing is the rival's.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        Env.advance(0.1)
        Env.players[2]._health = 150
        told(2, 4)
        shoot(3)                          -- arrives after the drop
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'credited with the rival\'s damage')
    end)

    it('still credits a drop already showing when the victim named this hunter, or nobody', function()
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        Env.advance(0.1)
        Env.players[2]._health = 150
        told(2, 4)
        told(2, 3)
        shoot(3)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'named, and still refused')
    end)

    it('keeps hits a drop is waiting on past their own window, and the death report with them', function()
        -- A slow victim: the damage shows at the end of the second the hits
        -- wait, the death is reported, and the victim's word comes after.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        shoot(4)
        shoot(3)
        Env.advance(0.97)
        Env.players[2]._health = 0
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0)
        Env.advance(0.13)
        told(2, 3)
        Env.advance(3)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the hits\' window closed on their own drop')
        falsy(s.death.getPending(c.id, 'HUNTER02'), 'the forger took the kill')
    end)

    it('does not hold a report from before the last reading against a hunter', function()
        -- The victim named a rival for a hit a reading ago. The drop showing
        -- now is since then, and this hunter's.
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        told(2, 4)
        Env.advance(0.5)
        s.death.watch('TARGET01', 2, true)
        Env.advance(0.5)
        Env.players[2]._health = 150
        shoot(3)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'an old report took the hunter\'s drop')
    end)

    it('waits for the victim\'s word on every drop, not only the first', function()
        local s = wiredStack()
        local f, c = placed(s)
        rival(s, c)
        shoot(4)
        shoot(3)
        Env.players[2]._health = 170
        Env.advance(0.08)
        told(2, 3)
        Env.advance(0.42)
        shoot(4)
        shoot(3)
        Env.players[2]._health = 130
        Env.advance(0.08)
        told(2, 3)
        Env.advance(2)
        local one = s.death.recordFor('TARGET01', 'HUNTER01')
        truthy(one and one.damage == 40, 'the second drop was not waited on')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'))
    end)

    it('forgets victims\' reports of who hit them once they are too old to settle anything', function()
        local s = wiredStack()
        placed(s)
        local function kept()
            local lines = table.concat(s.admin.diagnose(0, 2) or {}, '\n')
            return tonumber(lines:match('(%d+) report%(s%) of who hit whom')) or 0
        end
        for _ = 1, 40 do told(2, 3) end
        truthy(kept() > 0 and kept() <= s.death.SAW_MAX, 'kept without bound')
        Env.advance(s.death.SAW_KEEP_MS / 1000 + 1)
        s.death.sweep()
        eq(kept(), 0, 'kept after nobody fired again')
        told(2, 3)
        s.death.clearPlayer('TARGET01')
        eq(kept(), 0, 'kept after the victim left')
    end)

    it('hears a victim\'s reports of who hit them on a budget of their own', function()
        local s = wiredStack()
        placed(s)
        local real, heard = s.death.victimSaw, 0
        s.death.victimSaw = function(...) heard = heard + 1; return real(...) end
        for _ = 1, 200 do told(2, 3) end
        s.death.victimSaw = real
        eq(heard, 30, 'a flood of reports was heard in full')
        truthy(s.app.floodOk(2, 'iDied'), 'and spent the allowance the death report shares')
        s.death.victimSaw = function(...) heard = heard + 1; return real(...) end
        Env.advance(1.1)
        told(2, 3)
        s.death.victimSaw = real
        eq(heard, 31, 'the next second\'s report went unheard')
    end)

    it('keeps no report naming the victim themselves, or nobody', function()
        local s = wiredStack()
        placed(s)
        falsy(s.death.victimSaw(2, 2), 'a victim hit by themselves')
        falsy(s.death.victimSaw(2, 999), 'by a player not here')
        falsy(s.death.victimSaw(999, 3), 'told by a player not here')
        for _, junk in ipairs({ {}, 'x', true, 1e300, -1, 0 / 0 }) do
            local ok, kept = pcall(s.death.victimSaw, 2, junk)
            truthy(ok, tostring(kept))
            falsy(kept)
        end
        told(2, { nested = { 1 } })
    end)

    it('gives a drop to the shooter the victim\'s game names, not the first in line', function()
        -- A rival's event a moment before a real shot, with no shot behind it,
        -- took that shot's damage and the kill.
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        shoot(4)                               -- forged: no round behind it
        shoot(3)                               -- the real one
        Env.players[2]._health = 120
        Env.players[2]._damageSource = 1003    -- hunter one's ped
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'the shooter lost their hit')
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'the forger was credited')
    end)

    it('gives a drop the victim\'s game puts down to somebody else to nobody', function()
        -- A queued hit that never landed took an NPC's damage.
        local s = wiredStack()
        local f, c = placed(s)
        shoot(3)
        Env.players[2]._health = 120
        Env.players[2]._damageSource = 1099    -- not a hunter: an NPC
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'credited with somebody else\'s damage')
    end)

    it('credits a hit whose source sc-ambulance has already cleared', function()
        -- sc-ambulance clears the record of who damaged its player within a
        -- tenth of a second of every hit: nearly every check reads 0, and 0
        -- read as nobody wrote every real hit off.
        local s = wiredStack()
        local f, c = placed(s)
        shoot(3)
        Env.advance(0.055)
        Env.players[2]._health = 150
        Env.players[2]._damageSource = 1003
        Env.advance(0.01)
        Env.players[2]._damageSource = 0       -- cleared before the server looked
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'an honest hit was written off')
    end)

    it('credits a shooter the victim\'s game names by the car they fire from', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.players[3]._vehicle = 5003
        shoot(3)
        Env.players[2]._health = 150
        Env.players[2]._damageSource = 5003
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'a drive-by was written off')
    end)

    it('settles a drop at the next event, while its shooter is still named', function()
        -- Hunter one's round lands before hunter two fires; hunter two's
        -- then lands. The first drop went to nobody, or to hunter two.
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        shoot(3)
        Env.advance(0.02)
        Env.players[2]._health = 170
        Env.players[2]._damageSource = 1003
        shoot(4)                               -- settles hunter one's drop first
        Env.advance(0.02)
        Env.players[2]._health = 150
        Env.players[2]._damageSource = 1004
        Env.advance(2)
        local one = s.death.recordFor('TARGET01', 'HUNTER01')
        local two = s.death.recordFor('TARGET01', 'HUNTER02')
        truthy(one and one.damage == 30, 'hunter one\'s damage went elsewhere')
        truthy(two and two.damage == 20, 'hunter two lost their own')
    end)

    it('keeps no more than a few of one attacker\'s hits waiting', function()
        local s = wiredStack()
        local f, c = placed(s)
        for _ = 1, 60 do shoot(3) end
        s.audit.flush()
        local flooded = false
        for _, row in ipairs(s.storage.readAudit(400) or {}) do
            if row.action == 'flood_damage' then flooded = true end
        end
        truthy(flooded, 'a flood of events queued without bound')
        Env.players[2]._health = 150
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'and the real hit in it was lost')
    end)

    it('does not count a round into the target\'s car as a hit on them', function()
        local s = wiredStack()
        local f, c = placed(s)
        local realOwner, realExists = _G.NetworkGetEntityOwner, _G.DoesEntityExist
        _G.NetworkGetEntityOwner = function(entity)
            if entity == 7002 then return 2 end
            return realOwner(entity)
        end
        _G.DoesEntityExist = function(entity) return entity == 7002 or realExists(entity) end
        local ok, recorded = pcall(s.bridges.onWeaponDamage, s, 3,
            { weaponDamage = 30, weaponType = 123456, hitGlobalIds = { 7002 } })
        _G.NetworkGetEntityOwner, _G.DoesEntityExist = realOwner, realExists
        truthy(ok, tostring(recorded))
        eq(recorded, 0, 'the car is not the driver')
    end)

    it('credits the finishing shot on a body raised at once', function()
        -- In a car or on a stretcher sc-ambulance puts a dead player back at
        -- full health in the same frame: the lethal reading never shows.
        local s = wiredStack()
        local f, c = placed(s)
        local meta = Env.players[2].PlayerData.metadata
        Env.players[2]._health = 150
        meta.inlaststand = true
        s.death.watchTargets(s.storage.allContracts())
        Env.advance(40)                        -- the downing's hits long gone
        shoot(3)
        meta.inlaststand, meta.isdead = false, true
        Env.players[2]._health = 200           -- raised, dead, at full health
        s.death.onVictimReport(2, 3)           -- the victim's game names the finisher
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the finishing shot opened no kill')
    end)

    it('does not pay a hit that did nothing when a downed target bleeds out', function()
        -- A bleed-out reads on the server exactly like a body raised at once.
        -- The victim's game names nobody for it, and nobody is paid.
        local s = wiredStack()
        local f, c = placed(s)
        local meta = Env.players[2].PlayerData.metadata
        Env.players[2]._health = 150
        meta.inlaststand = true
        s.death.watchTargets(s.storage.allContracts())
        Env.advance(40)
        shoot(3)                               -- no round behind it
        Env.advance(0.5)
        meta.inlaststand, meta.isdead = false, true
        Env.players[2]._health = 200
        s.death.onVictimReport(2)              -- bled out: no killer
        Env.advance(2)
        falsy(s.death.getPending(c.id, 'HUNTER01'), 'paid for a bleed-out')
    end)

    it('attributes the death of a victim who leaves before it is checked', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.players[2]._health = 120
        shoot(3)                               -- the downing, already showing
        Env.advance(0.3)
        shoot(3)                               -- a round into the body, still waiting
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        s.death.clearPlayer('TARGET01')        -- gone within the second
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'quitting took the kill away')
    end)

    it('does not credit a drop twice across a heal', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        shoot(3)
        shoot(4)                               -- never lands
        Env.players[2]._health = 170
        Env.players[2]._damageSource = 1003
        Env.advance(0.2)                       -- hunter one's 30 is credited
        Env.players[2]._damageSource = 0
        Env.players[2]._health = 180           -- a bandage
        s.death.watchTargets(s.storage.allContracts())
        Env.advance(2)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'))
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'paid for the drop hunter one was paid for')
    end)

    it('keeps a named finisher\'s hit when the victim quits before it is checked', function()
        local s = wiredStack()
        local f, c = placed(s)
        local meta = Env.players[2].PlayerData.metadata
        Env.players[2]._health = 150
        meta.inlaststand = true
        s.death.watchTargets(s.storage.allContracts())
        Env.advance(40)
        shoot(3)                               -- the finishing round, in a car
        meta.inlaststand, meta.isdead = false, true
        Env.players[2]._health = 200
        s.death.onVictimReport(2, 3)
        s.death.clearPlayer('TARGET01')        -- gone within the second
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'quitting took the finisher\'s kill')
    end)

    it('forgets hits on somebody down once they are too old to name', function()
        local s = wiredStack()
        local f, c = placed(s)
        local meta = Env.players[2].PlayerData.metadata
        Env.players[2]._health = 150
        meta.inlaststand = true
        s.death.watchTargets(s.storage.allContracts())
        local function kept()
            local lines = table.concat(s.admin.diagnose(0, 2) or {}, '\n')
            return tonumber(lines:match('(%d+) hit%(s%) on downed players')) or 0
        end
        for _ = 1, 40 do
            shoot(3)                           -- a client sending events at the body
            Env.advance(0.5)
        end
        truthy(kept() <= 24, 'kept ' .. kept() .. ' hits for a death report ten seconds long')
        -- Picked up from last stand, and never reported: the sweep drops them.
        Env.advance(20)
        s.death.sweep()
        eq(kept(), 0, 'kept hits outlived any report that could name them')
    end)

    it('does not hand an unnamed drop to a rival once the honest hit has expired', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        shoot(3)
        Env.advance(0.02)
        shoot(4)                               -- the rival's, just after, with nothing behind it
        Env.players[2]._health = 130
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER02'), 'the rival took the drop once the shot expired')
    end)

    it('records a deferred attribution that fails', function()
        local s = wiredStack()
        local f, c = placed(s)
        shoot(3)
        Env.players[2]._health = 0
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        local real = s.death.attributeDeath
        s.death.attributeDeath = function() error('storage went away', 0) end
        Env.advance(2)
        s.death.attributeDeath = real
        s.audit.flush()
        local found = false
        for _, row in ipairs(s.storage.readAudit(200) or {}) do
            if row.action == 'error_iDied' then found = true end
        end
        truthy(found, 'a lost kill left no trace')
    end)

    it('does not hand a hit a drop already showing that somebody else caused', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.players[2]._health = 150           -- an NPC's round, just before the event
        Env.players[2]._damageSource = 1099
        shoot(3)                               -- a round that never lands
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'credited with the NPC\'s damage')
    end)

    it('gives a body raised at once to the finisher the victim\'s game names', function()
        local s = wiredStack()
        local f, c = placed(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:h2',
            coords = { x = 52.0, y = 50.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        local meta = Env.players[2].PlayerData.metadata
        Env.players[2]._health = 150
        meta.inlaststand = true
        s.death.watchTargets(s.storage.allContracts())
        Env.advance(40)
        shoot(4)                               -- the finishing round
        shoot(3)                               -- misses the body
        meta.inlaststand, meta.isdead = false, true
        Env.players[2]._health = 200
        s.death.onVictimReport(2, 4)           -- the victim's game names hunter two
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER02'), 'the finisher opened no kill')
        falsy(s.death.getPending(c.id, 'HUNTER01'), 'the first in line took it')
    end)

    it('registers sc-ambulance\'s defibrillator event', function()
        local s = wiredStack()
        truthy(Env.events['sc-ambulance:server:UseDefib'],
            'a defibrillator\'s gap would read as a revive whatever landed in it')
    end)

    it('ignores a damage event reporting no damage', function()
        local s = wiredStack()
        local f = fixture(s)
        eq(s.bridges.onWeaponDamage(s, 3, { weaponDamage = 0, hitGlobalIds = { 1002 } }), 0)
    end)

    it('ignores self-damage', function()
        local s = wiredStack()
        fixture(s)
        Env.players[2]._health = 120
        eq(s.bridges.onWeaponDamage(s, 2, { weaponDamage = 50, hitGlobalIds = { 1002 } }), 0,
            'the attacker and victim are the same player')
    end)

    it('ignores a malformed payload instead of erroring', function()
        local s = wiredStack()
        fixture(s)
        for _, bad in ipairs({ {}, { weaponDamage = 10 }, { weaponDamage = 10, hitGlobalIds = 'x' } }) do
            eq(s.bridges.onWeaponDamage(s, 3, bad), 0)
        end
        eq(s.bridges.onWeaponDamage(s, 3, nil), 0)
    end)

    it('cleans a disconnecting player up using their remembered citizen id', function()
        local s = wiredStack()
        local f = fixture(s)
        s.ratelimit.check('HUNTER01', 'create')
        truthy(s.bridges.onPlayerDropped(s, 'HUNTER01'))
        -- Cleanup must not depend on the framework still knowing the player.
        Env.removePlayer(3)
        truthy(s.bridges.onPlayerDropped(s, 'HUNTER01'), 'still cleans up after they are gone')
    end)
end)

describe('damage claims are corroborated, not trusted', function()
    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)   -- starts watching the target
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        return s, f, c
    end

    it('watches the target from the moment a contract is accepted', function()
        local s, f, c = armed()
        -- No health drop: the claim has nothing behind it.
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        Env.advance(2)   -- past the window the hit's damage is looked for in
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'a claim with no observed damage is discarded')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('rejects a fabricated hit from a hunter who never fired', function()
        local s, f, c = armed()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            coords = { x = 12.0, y = 10.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)

        -- Hunter one genuinely shoots.
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)

        -- Hunter two fires an event immediately afterwards without shooting.
        -- Its damage is looked for for a second, and never shows.
        s.death.recordDamage(4, 2, 123456)

        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        Env.advance(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the hunter who actually shot is credited')
        falsy(s.death.getPending(c.id, 'HUNTER02'), 'the one who only claimed is not')
    end)

    it('credits the hunter who did the most damage, not the last to report', function()
        local s, f, c = armed()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            coords = { x = 12.0, y = 10.0, z = 30.0 } })
        s.contracts.accept(s.identity.resolve(4), c.id, false)

        Env.players[2]._health = 120           -- hunter one takes 80
        s.death.recordDamage(3, 2, 123456)
        Env.players[2]._health = 110           -- hunter two chips 10 off later
        s.death.recordDamage(4, 2, 123456)

        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the real killer keeps the kill')
        falsy(s.death.getPending(c.id, 'HUNTER02'), 'a late chip does not steal it')
    end)

    it('does not read a respawn as damage', function()
        local s, f, c = armed()
        Env.players[2]._health = 120
        s.death.recordDamage(3, 2, 123456)

        -- They actually die, and the server sees it, before anyone can come
        -- back from it. A revive claim with no death behind it is refused.
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)

        Env.players[2].PlayerData.metadata.isdead = false
        truthy(s.death.onRevivedVerified(2, 'TARGET01') ~= nil)
        Env.players[2]._health = 200            -- back on their feet
        Env.advance(s.death.REVIVE_CONFIRM_MS / 1000 + 1)                          -- and still up: the revive is confirmed

        local first = s.death.getPending(c.id, 'HUNTER01')
        s.death.recordDamage(3, 2, 123456)      -- no new damage since
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'a heal is not a hit')
        local now = s.death.getPending(c.id, 'HUNTER01')
        truthy(not now or (first and now.at == first.at), 'a second kill was opened on no damage')
    end)
end)

describe('corroboration does not punish legitimate hits', function()
    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        return s, f, c
    end

    it('credits a hit that lands on armour rather than health', function()
        local s, f, c = armed()
        Env.players[2]._armour = 100
        s.death.watch('TARGET01', 2, true)   -- baseline includes the vest

        -- The shot takes armour off and leaves health untouched, which is
        -- exactly what a vest does.
        Env.players[2]._armour = 40
        s.death.recordDamage(3, 2, 123456)

        Env.players[2]._health = 0
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1, 'a shot stopped by a vest is still a shot')
    end)

    it('credits a hit after the target has healed back up', function()
        local s, f, c = armed()

        -- An earlier fight left them low, and the baseline recorded it.
        Env.players[2]._health = 120
        s.death.watch('TARGET01', 2, true)

        -- They heal to full, and the tick refreshes the baseline.
        Env.players[2]._health = 200
        s.death.watchTargets(s.storage.allContracts())

        -- Now a real hit lands.
        Env.players[2]._health = 150
        s.death.recordDamage(3, 2, 123456)

        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1,
            'a stale low baseline must not make a real hit look like healing')
    end)

    it('still rejects a claim with no loss of condition at all', function()
        local s, f, c = armed()
        Env.players[2]._health = 200
        Env.players[2]._armour = 0
        s.death.watch('TARGET01', 2, true)

        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        Env.advance(2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'), 'no loss of condition, and a hit recorded')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)
end)

describe('the victim names the killer, the server checks the claim', function()
    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        return s, f, c
    end

    --- A real kill: the hunter's shot lands and the server sees the target
    --- lose condition, then the victim's game names them. A named killer
    --- the server never observed is a separate case, tested below.
    local function shoot(s, attackerSource)
        Env.players[2]._health = 200
        s.death.watch('TARGET01', 2, true)
        Env.players[2]._health = 40
        s.death.recordDamage(attackerSource or 3, 2, 123456)
    end

    it('credits the hunter the victims own game names', function()
        local s, f, c = armed()
        shoot(s)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 3), 1, 'the victim named an accepted hunter')
        truthy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('pays nobody for a named killer the server never saw touch them', function()
        local s, f, c = armed()
        -- No shot, no observed loss of condition — only the victim's client
        -- saying who did it. A record used to be synthesised here, which
        -- credits a hunter on a claim nothing corroborates.
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 3), 0, 'an unobserved kill pays nobody')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('does not quietly credit somebody else instead', function()
        local s, f, c = armed()
        -- A second hunter who did shoot. The named killer being unobserved
        -- must not hand the kill to whoever else was firing.
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 5000, bank = 5000, coords = { x = 10.0, y = 10.0, z = 30.0 } })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        shoot(s, 4)

        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 3), 0, 'the victim named the unobserved one')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
        falsy(s.death.getPending(c.id, 'HUNTER02'),
            'and the fallback must not run behind the victims own account')
    end)

    it('can be turned off for servers where vehicle kills matter more', function()
        local s, f, c = armed()
        withConfig({ { Config.Completion, 'RequireObservedDamage', false } }, function()
            Env.players[2].PlayerData.metadata.isdead = true
            eq(s.death.onVictimReport(2, 3), 1, 'the victims word alone is enough')
        end)
    end)

    it('ignores a named killer who never accepted the contract', function()
        local s, f, c = armed()
        Env.addPlayer({ source = 9, citizenid = 'RANDOM01', license = 'license:r',
            coords = { x = 12.0, y = 10.0, z = 30.0 } })
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 9), 0, 'an outsider kill still pays nobody')
    end)

    it('ignores a named killer who was nowhere near', function()
        local s, f, c = armed()
        Env.players[3]._coords = { x = 9000.0, y = 0.0, z = 0.0 }
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 3), 0, 'a kill from 9km away did not happen')
    end)

    it('ignores a victim naming themselves', function()
        local s, f, c = armed()
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 2), 0)
    end)

    it('does not let a hunter claim a kill by naming themselves', function()
        local s, f, c = armed()
        -- The hunter's own client fires the report. `source` is the hunter,
        -- so the server treats it as the hunter dying, not the target.
        Env.players[3].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(3, 3), 0, 'reporting your own death credits nobody')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)

    it('still falls back to observed damage when no killer is named', function()
        local s, f, c = armed()
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1, 'the damage log still works on its own')
    end)
end)

describe('a respawn does not take a kill away from the hunter', function()
    --- The proof window and post-respawn immunity were added in the same
    --- change and contradicted each other: the respawn the window exists to
    --- survive was exactly what armed the immunity. This drives the real
    --- revive event, which the earlier test did not.

    local function killed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)

        Env.players[3]._coords = { x = 20.0, y = 20.0, z = 30.0 }
        Env.players[2]._coords = { x = 21.0, y = 20.0, z = 30.0 }

        -- A real kill: the shot lands and the server sees the condition go,
        -- then the victim's game names the hunter. The victim's word alone
        -- is not enough — that is what RequireObservedDamage is for.
        Env.players[2]._health = 200
        s.death.watch('TARGET01', 2, true)
        Env.players[2]._health = 30
        s.death.recordDamage(3, 2, 123456)

        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2, 3), 1, 'the kill should be attributed')

        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()
        return s, f, c
    end

    it('pays the hunter who photographs after the target respawns', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hunter, c.id)
        truthy(token)

        -- The target hits respawn, through the event the client really fires.
        Env.advance(5)
        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevivedVerified(2, 'TARGET01')

        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the kill happened before the respawn: ' .. tostring(err))
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and it was paid')
    end)

    it('keeps the token usable when a claim is refused for something transient', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hunter, c.id)

        -- Something else holds the contract, so the claim cannot land yet.
        s.storage.compareSetContractState(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING)
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'the claim cannot be made right now')

        -- The hold clears and the same token still works: a transient refusal
        -- must not destroy proof of a kill the server itself attributed.
        s.storage.compareSetContractState(c.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED)
        local retry = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(retry, 'the proof should survive a transient refusal')
        eq(Env.players[3].PlayerData.money.cash, 10000)
    end)

    it('still refuses a claim on a target who respawned long ago', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hunter, c.id)

        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevivedVerified(2, 'TARGET01')
        Env.advance(Config.Completion.ProofWindowSeconds + 30)

        local ok = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a target up and about for a minute is not proof of death')
        eq(Env.players[3].PlayerData.money.cash, 5000)
    end)
end)


--- The photo host allowlist follows lb-phone's upload config. Read only at
--- boot, an owner who changed provider had to restart this resource too, and
--- the failure mode is every verification photo being rejected.
describe('photo host allowlist', function()
    it('picks up a provider changed after boot', function()
        local s = newStack()
        local phone = Natives.phoneConfig

        withConfig({ { Config.Completion, 'ExtraPhotoHosts', {} } }, function()
            Natives.phoneConfig = { Upload = { url = 'https://old.example/upload' } }
            s.photo.loadAllowedHosts()
            truthy(s.photo.hostAllowed('https://old.example/x.png'), 'the old provider')
            falsy(s.photo.hostAllowed('https://new.example/x.png'), 'not yet the new one')

            -- The owner switches provider without restarting this resource.
            Natives.phoneConfig = { Upload = { url = 'https://new.example/upload' } }
            s.photo.loadAllowedHosts()
            truthy(s.photo.hostAllowed('https://new.example/x.png'), 'the new provider')
            falsy(s.photo.hostAllowed('https://old.example/x.png'), 'and not the old one')
        end)

        Natives.phoneConfig = phone
    end)

    it('keeps the configured extra hosts across a refresh', function()
        local s = newStack()
        local phone = Natives.phoneConfig

        withConfig({ { Config.Completion, 'ExtraPhotoHosts', { 'cdn.fivemanage.com' } } }, function()
            Natives.phoneConfig = { Upload = { url = 'https://other.example/upload' } }
            s.photo.loadAllowedHosts()
            truthy(s.photo.hostAllowed('https://cdn.fivemanage.com/x.png'),
                'an operator-set host is not swept away by a refresh')
        end)

        Natives.phoneConfig = phone
    end)

    it('reports an allowlist that has become empty', function()
        local s = newStack()
        local phone = Natives.phoneConfig

        withConfig({ { Config.Completion, 'ExtraPhotoHosts', {} } }, function()
            Natives.phoneConfig = { Upload = { url = 'https://old.example/upload' } }
            s.photo.loadAllowedHosts()
            eq(#s.photo.allowedHosts(), 1)

            -- Provider removed entirely: nothing would verify, and that is
            -- worth saying out loud rather than silently rejecting.
            Natives.phoneConfig = {}
            s.photo.loadAllowedHosts()
            eq(#s.photo.allowedHosts(), 0)
            truthy(s.photo.hostsChangedAt, 'the change is recorded')
        end)

        Natives.phoneConfig = phone
    end)

    it('does not record a change when nothing changed', function()
        local s = newStack()
        s.photo.loadAllowedHosts()
        local before = s.photo.hostsChangedAt
        s.photo.loadAllowedHosts()
        eq(s.photo.hostsChangedAt, before, 'a steady allowlist is not news')
    end)
end)


--- Sampling. Attribution is only as precise as the last condition sample:
--- a hunter who lands one shot must not inherit whatever else happened to
--- the target since the sampler last looked.
describe('condition sampling', function()
    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        Env.players[2]._health = 200
        s.death.watch('TARGET01', 2, true)
        return s, f, c
    end

    it('credits a hunter only the drop since the last sample', function()
        local s, f, c = armed()

        -- Something the server cannot attribute takes most of the target's
        -- health: a fall, an explosion, another player's car.
        Env.players[2]._health = 60
        s.death.watchTargets(s.storage.allContracts())

        -- Then the hunter lands one shot.
        Env.players[2]._health = 40
        s.death.recordDamage(3, 2, 123456)

        local record = s.death.recordFor('TARGET01', 'HUNTER01')
        truthy(record, 'the shot is recorded')
        eq(record.damage, 20, 'their shot, not the fall before it')
    end)

    it('lets a hunter inherit the lot when nothing samples in between', function()
        local s, f, c = armed()
        -- The same sequence with no sample: this is what the maintenance
        -- tick's ten seconds looked like, and why the sampler exists.
        Env.players[2]._health = 60
        Env.players[2]._health = 40
        s.death.recordDamage(3, 2, 123456)

        eq(s.death.recordFor('TARGET01', 'HUNTER01').damage, 160,
            'unsampled, the whole drop is attributed to whoever fires next')
    end)

    it('samples only the targets of live contracts', function()
        local s, f, c = armed()
        eq(s.death.watchTargets(s.storage.allContracts()), 1, 'one live contract')

        truthy(s.contracts.resolve(c.id, CB.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))
        eq(s.death.watchTargets(s.storage.allContracts()), 0,
            'a resolved contract is not worth sampling for')
    end)

    it('starts exactly one sampler', function()
        local s = newStack()
        local before = #Env.threads
        truthy(s.death.startSampler(), 'the first call starts it')
        falsy(s.death.startSampler(), 'the second must not start a second one')
        eq(#Env.threads - before, 1)
    end)
end)


--- Coming back requires having gone.
---
--- A revive is claimed by the reviving player's own client, and the only
--- check was that they are not dead right now — which every living player
--- passes. Each claim renews post-respawn immunity and clears the damage
--- recorded against them, so anyone could stay permanently untargetable and
--- erase the attribution for a hunter who had just shot them.
describe('a revive claim needs a death behind it', function()
    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        return s, f, c
    end

    it('refuses one from a player who never died', function()
        local s, f, c = armed()
        eq(s.death.onRevivedVerified(2, 'TARGET01'), 0,
            'a living player cannot come back from anything')
        falsy(s.death.sinceRespawn('TARGET01'),
            'and must not be handed post-respawn immunity for asking')
    end)

    it('does not let a claim erase the damage against them', function()
        local s, f, c = armed()
        Env.players[2]._health = 200
        s.death.watch('TARGET01', 2, true)
        Env.players[2]._health = 60
        s.death.recordDamage(3, 2, 123456)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'), 'the shot is on record')

        s.death.onRevivedVerified(2, 'TARGET01')
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'),
            'a refused claim must not wipe what a hunter earned')
    end)

    it('does not let a claim renew immunity in a loop', function()
        local s, f, c = armed()
        for _ = 1, 5 do s.death.onRevivedVerified(2, 'TARGET01') end
        falsy(s.death.sinceRespawn('TARGET01'),
            'spamming the event must not be a way to stay untargetable forever')
    end)

    it('accepts one after a death the server saw', function()
        local s, f, c = armed()
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        truthy(s.death.wasSeenDead('TARGET01'), 'the server saw them die')

        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevivedVerified(2, 'TARGET01')
        Env.advance(s.death.REVIVE_CONFIRM_MS / 1000 + 1)
        truthy(s.death.sinceRespawn('TARGET01'), 'and a real revive counts')
    end)

    it('accepts one after a death nobody reported', function()
        local s, f, c = armed()
        -- Died to a fall, or a car, or another player entirely. The sampler
        -- visits every live target, so the server still sees it.
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.watchTargets(s.storage.allContracts())
        truthy(s.death.wasSeenDead('TARGET01'))

        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevivedVerified(2, 'TARGET01')
        Env.advance(s.death.REVIVE_CONFIRM_MS / 1000 + 1)
        truthy(s.death.sinceRespawn('TARGET01'),
            'a target who dies to the world can still come back')
    end)

    it('spends the death, so one death is one revive', function()
        local s, f, c = armed()
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        Env.players[2].PlayerData.metadata.isdead = false

        s.death.onRevivedVerified(2, 'TARGET01')
        Env.advance(s.death.REVIVE_CONFIRM_MS / 1000 + 1)
        local first = s.death.sinceRespawn('TARGET01')
        truthy(first, 'the first claim takes')

        Env.time = Env.time + 60
        eq(s.death.onRevivedVerified(2, 'TARGET01'), 0, 'the second does not')
        truthy(s.death.sinceRespawn('TARGET01') > first,
            'and the immunity clock is not renewed by asking again')
    end)
end)

--- The two events that decide whether a kill counts, driven as events.
---
--- iDied and iRevived are registered outside handler(), because they are the
--- highest-frequency events in the resource and each one walks the contract
--- table — so they carry their own flood guard, identity gate, rate limit
--- and pcall rather than borrowing the wrapper's. Line coverage found that
--- none of that had ever run: every test calls Death.onVictimReport
--- directly, which proves the function works and nothing about the wiring
--- that reaches it.
---
--- This is the same gap as Bridges.onPlayerReady, and on the path where a
--- hunter's payout is decided.
describe('reporting a death through the event a client actually fires', function()
    local function fire(name, source, ...)
        local handler = Env.events['crimson-bounty:' .. name]
        if not handler then return nil, 'no handler registered' end
        _G.source = source
        local ok, err = pcall(handler, ...)
        _G.source = nil
        return ok, err
    end

    local function downed(s)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        return f, c
    end

    it('is registered at all', function()
        local s = newStack()
        truthy(Env.events['crimson-bounty:iDied'],
            'nothing would ever report a death, so no elimination could pay')
        truthy(Env.events['crimson-bounty:iRevived'],
            'and nothing would ever clear one')
    end)

    it('reaches the death module and records the victim', function()
        local s = newStack()
        local f, c = downed(s)
        local ok = fire('iDied', 2, 3)
        truthy(ok, 'the event threw')
        truthy(s.death.wasSeenDead('TARGET01'),
            'a death reported through the event has to reach the module that '
            .. 'decides whether it pays')
    end)

    it('does not throw for a source the framework cannot resolve', function()
        local s = newStack()
        fixture(s)
        local ok, err = fire('iDied', 999)
        truthy(ok, 'a player mid-join must not take the event down: ' .. tostring(err))
    end)

    it('does not throw when the module beneath it raises', function()
        local s = newStack()
        local f, c = downed(s)
        local real = s.death.onVictimReport
        s.death.onVictimReport = function() error('death exploded', 0) end
        local ok, err = fire('iDied', 2, 3)
        s.death.onVictimReport = real
        truthy(ok,
            'these events are registered outside handler(), so the pcall here '
            .. 'is the only thing between a throw and the whole net event '
            .. 'dying for everybody: ' .. tostring(err))
    end)

    it('writes down a throw rather than swallowing it', function()
        local s = newStack()
        local f, c = downed(s)
        local real = s.death.onVictimReport
        s.death.onVictimReport = function() error('death exploded', 0) end
        fire('iDied', 2, 3)
        s.death.onVictimReport = real

        -- The audit is a queue, so it has to be flushed before it is read.
        s.audit.flush()
        local recorded = false
        for _, row in ipairs(s.storage.readAudit(200) or {}) do
            if tostring(row.action):find('iDied') then recorded = true end
        end
        truthy(recorded,
            'an error nobody records is one nobody fixes, and this is the '
            .. 'path a hunter reports as "the kill did not count"')
    end)

    it('throttles a client firing it repeatedly', function()
        local s = newStack()
        local f, c = downed(s)

        -- Far more than the death bucket allows, which is what a modified
        -- client would send.
        for _ = 1, 40 do fire('iDied', 2, 3) end

        s.audit.flush()
        local refused = false
        for _, row in ipairs(s.storage.readAudit(400) or {}) do
            local action = tostring(row.action)
            if action:find('ratelimit_iDied') or action:find('flood_iDied') then
                refused = true
            end
        end
        truthy(refused,
            'each of these walks the contract table, so an unthrottled client '
            .. 'is a denial of service with no payload at all')
    end)

    it('clears the death when the victim reports being revived', function()
        local s = newStack()
        local f, c = downed(s)
        fire('iDied', 2, 3)
        truthy(s.death.wasSeenDead('TARGET01'), 'the fixture has to mark them dead')

        Env.players[2].PlayerData.metadata.isdead = false
        Env.players[2]._health = 200
        local ok = fire('iRevived', 2)
        truthy(ok, 'the revive event threw')
    end)

    it('does not throw when the revive path raises', function()
        local s = newStack()
        local f, c = downed(s)
        local real = s.death.onRevivedVerified
        s.death.onRevivedVerified = function() error('revive exploded', 0) end
        local ok, err = fire('iRevived', 2)
        s.death.onRevivedVerified = real
        truthy(ok, 'the same pcall has to cover the other event: ' .. tostring(err))
    end)
end)

describe('what one verification costs against the rate limit', function()
    --- Asking for a token and submitting the photo both billed the `photo`
    --- bucket, so a single verification spent two of the three attempts it
    --- allows — and the second charge lands after the hunter has lined up
    --- and taken the shot.
    ---
    --- Whether a retry sequence can actually exhaust it depends on how long
    --- the camera stays open, because the bucket refills while it is. The
    --- shape of the failure is what matters: a confirmed kill, photographed,
    --- refused for going too fast at the one moment the player has already
    --- done the work.
    it('does not bill the same allowance twice', function()
        local ask = Config.Cooldowns.photo
        local send = Config.Cooldowns.photoSubmit
        truthy(ask and send, 'both buckets have to exist')

        local App = require('crimson-bounty.server.app')
        local source = read_file('crimson-bounty/server/app.lua')
        local askBucket = source:match("handler%('requestPhotoToken', '([%w]+)'")
        local sendBucket = source:match("handler%('submitPhoto', '([%w]+)'")
        eq(askBucket, 'photo')
        truthy(sendBucket ~= askBucket,
            'one verification would spend two attempts, and the second '
            .. 'charge lands after the photograph has been taken')
        local _ = App
    end)

    it('lets a hunter retry a refused photo as many times as the bucket says', function()
        local s = newStack()
        local f = fixture(s)

        -- Three attempts means three, not one and a half.
        local attempts = 0
        for _ = 1, Config.Cooldowns.photo.burst do
            if s.ratelimit.check(f.hunter, 'photo') then attempts = attempts + 1 end
        end
        eq(attempts, Config.Cooldowns.photo.burst,
            'asking for a token is what is limited')

        -- And the submissions for those attempts are not refused by a
        -- budget the asking already spent.
        local sends = 0
        for _ = 1, Config.Cooldowns.photo.burst do
            if s.ratelimit.check(f.hunter, 'photoSubmit') then sends = sends + 1 end
        end
        eq(sends, Config.Cooldowns.photo.burst,
            'every token that was issued can still be used')
    end)
end)
