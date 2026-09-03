--- A clock that only goes forward (§14.31).
---
--- GetGameTimer is a 32-bit millisecond counter: it wraps roughly every
--- 24.8 days, and a server left up over a month sees it fall from two
--- billion back to nearly zero. Every duration in this resource is an
--- elapsed subtraction against it, so a wrap turns each one negative at the
--- same instant. That is not cosmetic. The rate limiter multiplies elapsed
--- by a refill rate, so a negative elapsed pushes every player's token count
--- tens of thousands below zero and refuses them for good — and the sweep
--- that would clear the bucket also tests an elapsed, so it never fires
--- either. Meanwhile every proof token stops expiring, because "issued more
--- than two minutes ago" is false when the subtraction is negative.
---
--- Util.monotonicMs absorbs the wrap once, in one place. These tests drive
--- the raw timer over the boundary and hold the behaviour that depends on
--- it. They fail if any of them is switched back to GetGameTimer().

local Util = require('crimson-bounty.shared.util')

--- One millisecond short of where a signed 32-bit counter turns over.
local NEAR_WRAP = 2147483000

--- Put the raw game timer at `ms` without touching anything else. Env.advance
--- only ever moves forward, which is precisely the case that does not happen
--- here.
local function rawTimer(ms)
    Env.gameTimer = ms
end

describe('the monotonic clock', function()
    it('tracks the raw timer while it is climbing', function()
        Util.resetMonotonic()
        rawTimer(1000)
        eq(Util.monotonicMs(), 1000)
        rawTimer(4500)
        eq(Util.monotonicMs(), 4500, 'no wrap, no adjustment')
    end)

    it('never goes backwards when the raw timer wraps', function()
        Util.resetMonotonic()
        rawTimer(NEAR_WRAP)
        local before = Util.monotonicMs()
        rawTimer(250)
        local after = Util.monotonicMs()
        truthy(after >= before,
            ('the clock went backwards across a wrap: %d then %d'):format(before, after))
    end)

    it('keeps measuring real durations after a wrap', function()
        Util.resetMonotonic()
        rawTimer(NEAR_WRAP)
        Util.monotonicMs()
        rawTimer(250)
        local a = Util.monotonicMs()
        rawTimer(5250)
        local b = Util.monotonicMs()
        eq(b - a, 5000, 'five seconds after the wrap must read as five seconds')
    end)

    it('does not jump forward across the wrap either', function()
        -- A clock that leaped a month would hand every rate limit a full
        -- refill and expire every live token: the mirror image of the bug.
        Util.resetMonotonic()
        rawTimer(NEAR_WRAP)
        local before = Util.monotonicMs()
        rawTimer(250)
        local after = Util.monotonicMs()
        truthy(after - before < 60000,
            ('the wrap moved the clock forward by %dms'):format(after - before))
    end)

    it('survives being wrapped twice', function()
        Util.resetMonotonic()
        local last = Util.monotonicMs()
        for _ = 1, 2 do
            rawTimer(NEAR_WRAP)
            local high = Util.monotonicMs()
            truthy(high >= last, 'climbing to the wrap must not go backwards')
            last = high
            rawTimer(100)
            local low = Util.monotonicMs()
            truthy(low >= last, 'crossing the wrap must not go backwards')
            last = low
        end
    end)
end)

describe('the rate limiter across a timer wrap', function()
    it('still admits a player whose bucket has tokens left', function()
        -- The bug this holds shut: with the raw timer, elapsed is about
        -- minus 2.1 million seconds here, the refill is minus seventy
        -- thousand tokens, and this player is refused every request until
        -- the server restarts.
        local s = newStack()
        rawTimer(NEAR_WRAP)
        truthy(s.ratelimit.check('WRAPPED1', 'create'), 'first request opens the bucket')

        rawTimer(250)
        truthy(s.ratelimit.check('WRAPPED1', 'create'),
            'the second of a burst of two must still be allowed after a wrap')
    end)

    it('does not hand out a free refill across the wrap', function()
        local s = newStack()
        rawTimer(NEAR_WRAP)
        -- create is burst 2 per 60s.
        truthy(s.ratelimit.check('WRAPPED2', 'create'))
        truthy(s.ratelimit.check('WRAPPED2', 'create'))
        falsy(s.ratelimit.check('WRAPPED2', 'create'), 'the bucket is spent')

        rawTimer(250)
        falsy(s.ratelimit.check('WRAPPED2', 'create'),
            'a wrap is not a way to refill a spent bucket')
    end)

    it('still refills at the real rate after a wrap', function()
        local s = newStack()
        rawTimer(NEAR_WRAP)
        s.ratelimit.check('WRAPPED3', 'create')
        s.ratelimit.check('WRAPPED3', 'create')
        falsy(s.ratelimit.check('WRAPPED3', 'create'))

        rawTimer(250)
        -- A full period past the wrap.
        rawTimer(250 + 60000)
        truthy(s.ratelimit.check('WRAPPED3', 'create'), 'a minute later the bucket has refilled')
    end)

    it('still sweeps buckets that have gone idle across a wrap', function()
        -- With the raw timer the idle test is `250 - 2147483000 > 600000`,
        -- which is false forever: buckets accumulate for the life of the
        -- process and are never released.
        local s = newStack()
        rawTimer(NEAR_WRAP)
        s.ratelimit.check('WRAPPED4', 'create')
        eq(s.ratelimit.count(), 1)

        rawTimer(700000)
        eq(s.ratelimit.sweep(), 1, 'an idle bucket must still be reclaimed after a wrap')
        eq(s.ratelimit.count(), 0)
    end)
end)

describe('proof tokens across a timer wrap', function()
    --- Seed a live pending completion with the raw timer already parked just
    --- short of the wrap, so the kill, the damage record and the token are
    --- all stamped on the far side of the boundary the token then crosses.
    local function ready()
        local s = newStack()
        rawTimer(NEAR_WRAP)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()

        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        return s, f, c
    end

    it('expires a photo token issued just before the wrap', function()
        -- The token's whole purpose is that it is short-lived. With the raw
        -- timer, `now - issuedAt` is negative after a wrap, so the lifetime
        -- test never passes and the token is good forever.
        local s, f, c = ready()
        local token = s.photo.issue(f.hunter, c.id)
        truthy(token, 'a token to expire')

        -- Well past PhotoTokenLifetimeSeconds, on the far side of the wrap.
        rawTimer(250 + (Config.Completion.PhotoTokenLifetimeSeconds * 1000) + 1000)
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a stale token must not be accepted because the clock wrapped')
        eq(err, CB.ERR.TOKEN_INVALID)
    end)

    it('still accepts a token submitted within its lifetime after a wrap', function()
        local s, f, c = ready()
        local token = s.photo.issue(f.hunter, c.id)
        truthy(token)

        rawTimer(250)
        local ok, err = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'a fresh token must survive the wrap too: ' .. tostring(err))
    end)

    it('sweeps expired tokens after a wrap', function()
        local s, f, c = ready()
        truthy(s.photo.issue(f.hunter, c.id))
        eq(s.photo.tokenCount(), 1)

        rawTimer(250 + (Config.Completion.PhotoTokenLifetimeSeconds * 1000) + 1000)
        s.photo.sweep()
        eq(s.photo.tokenCount(), 0, 'the sweep must still reclaim tokens after a wrap')
    end)
end)
