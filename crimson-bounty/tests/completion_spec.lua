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
            eq(err, CB.ERR.PHOTO_REJECTED)
        end
    end)

    it('rejects a URL longer than the stored column holds', function()
        local s, f, c, token = ready()
        local long = 'https://cdn.fivemanage.com/' .. string.rep('a', 600) .. '.png'
        local ok, err = s.photo.submit(f.hunter, token, long)
        falsy(ok, 'an over-length URL would be truncated in storage')
        eq(err, CB.ERR.PHOTO_REJECTED)
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

    it('accepts a photo taken right after the target respawned', function()
        local s, f, c, token = ready()
        Env.players[2].PlayerData.metadata.isdead = false
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the kill happened; respawning is not a defence: ' .. tostring(err))
    end)

    it('refuses a photo long after the target was revived', function()
        local s, f, c, token = ready()
        Env.players[2].PlayerData.metadata.isdead = false
        Env.advance(Config.Completion.ProofWindowSeconds + 10)
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a target who has been up and about for a minute is not proof of death')
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
        eq(s.death.onVictimReport(2), 0, 'a claim with no observed damage is discarded')
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
        s.death.recordDamage(4, 2, 123456)

        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1)
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

        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevivedVerified(2, 'TARGET01')
        Env.players[2]._health = 200            -- back on their feet

        s.death.recordDamage(3, 2, 123456)      -- no new damage since
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 0, 'a heal is not a hit')
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
        eq(s.death.onVictimReport(2), 0)
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
