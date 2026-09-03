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


--- Minting an id nothing is using.
describe('Util.mintId', function()
    local Util = require('crimson-bounty.shared.util')

    it('returns the first id nothing holds', function()
        local n = 0
        local id = Util.mintId(function(prefix)
            n = n + 1
            return prefix .. n
        end, 'ct', function() return nil end)
        eq(id, 'ct1')
        eq(n, 1, 'and asks for exactly one when the first is free')
    end)

    it('walks past ids that are taken', function()
        local n = 0
        local taken = { ct1 = true, ct2 = true }
        local id = Util.mintId(function(prefix)
            n = n + 1
            return prefix .. n
        end, 'ct', function(candidate) return taken[candidate] end)
        eq(id, 'ct3')
    end)

    it('gives up rather than writing onto one that is in use', function()
        -- Refusing costs a caller one attempt. Writing would destroy
        -- whatever already holds the id.
        local id = Util.mintId(function(prefix) return prefix .. '1' end,
            'ct', function() return true end)
        falsy(id)
    end)

    it('gives up when the store will not mint at all', function()
        falsy(Util.mintId(function() return nil end, 'ct', function() return nil end))
    end)

    it('bounds how long it tries', function()
        local n = 0
        Util.mintId(function(prefix)
            n = n + 1
            return prefix .. n
        end, 'ct', function() return true end, 3)
        eq(n, 3, 'a store handing out nothing but taken ids must not loop forever')
    end)
end)


--- Text a player typed, on its way to a database and a browser.
describe('sanitizing text', function()
    local Util = require('crimson-bounty.shared.util')

    --- Whether every byte sequence in this string is well-formed UTF-8.
    local function wellFormed(text)
        return utf8 and utf8.len(text) ~= nil
    end

    it('does not cut a character in half at the length cap', function()
        -- The cap counts bytes. An emoji straddling it left two of its four
        -- bytes behind: valid text in, invalid UTF-8 out, headed for a
        -- utf8mb4 column that rejects it and a JSON message the page cannot
        -- parse — which drops the whole reply and freezes the app.
        local text = string.rep('a', 30) .. '\240\159\148\170 blade'
        local out = Util.sanitizeText(text, 32)
        truthy(out)
        truthy(wellFormed(out), 'the cap must fall on a character boundary')
        eq(out, string.rep('a', 30), 'and the half-character is dropped, not kept')
    end)

    it('does not cut a two-byte character in half either', function()
        local text = string.rep('b', 31) .. '\195\169 end'
        local out = Util.sanitizeText(text, 32)
        truthy(out)
        truthy(wellFormed(out), 'a two-byte character is just as splittable')
    end)

    it('keeps a character that fits exactly', function()
        local text = string.rep('c', 28) .. '\240\159\148\170'
        local out = Util.sanitizeText(text, 32)
        eq(out, text, 'nothing straddles the cap here')
        truthy(wellFormed(out))
    end)

    it('drops bytes that were never valid to begin with', function()
        -- Not everything arrives from a keyboard. A payload can carry any
        -- bytes at all, and they end up in the same column and the same
        -- JSON message.
        local out = Util.sanitizeText('ok\255\254 then', 64)
        truthy(out)
        truthy(wellFormed(out), 'invalid bytes must not survive: ' .. tostring(out))
        truthy(out:find('ok', 1, true) and out:find('then', 1, true),
            'while the text around them does')
    end)

    it('leaves ordinary text alone', function()
        eq(Util.sanitizeText('  Unpaid   debt  ', 64), 'Unpaid debt')
        eq(Util.sanitizeText('Zoë Ferreira', 64), 'Zoë Ferreira',
            'accented text is ordinary text')
    end)

    it('still refuses what is not a string, and what is left empty', function()
        falsy(Util.sanitizeText(nil, 10))
        falsy(Util.sanitizeText(42, 10))
        falsy(Util.sanitizeText({}, 10))
        falsy(Util.sanitizeText('   ', 10))
        falsy(Util.sanitizeText('\255', 10), 'nothing usable is left of this')
    end)
end)


--- Held against every byte string, not the handful anyone thought of.
describe('sanitized text is always well-formed', function()
    local Util = require('crimson-bounty.shared.util')

    it('never returns a sequence Lua itself will not read', function()
        math.randomseed(20260903)
        local bad = {}

        for case = 1, 4000 do
            local bytes = {}
            for _ = 1, math.random(1, 40) do
                -- Weighted towards the bytes that start and continue a
                -- multi-byte sequence, which is where the edges are.
                local pick = math.random(1, 4)
                if pick == 1 then bytes[#bytes + 1] = string.char(math.random(0x20, 0x7E))
                elseif pick == 2 then bytes[#bytes + 1] = string.char(math.random(0x80, 0xBF))
                elseif pick == 3 then bytes[#bytes + 1] = string.char(math.random(0xC0, 0xFF))
                else bytes[#bytes + 1] = string.char(math.random(0, 255)) end
            end

            local out = Util.sanitizeText(table.concat(bytes), math.random(1, 40))
            if out ~= nil and utf8 and utf8.len(out) == nil then
                bad[#bad + 1] = case
            end
        end

        eq(#bad, 0, ('%d of 4000 random byte strings survived as invalid UTF-8'):format(#bad))
    end)

    it('leaves well-formed text that fits exactly as it was', function()
        math.randomseed(20260904)
        for _ = 1, 2000 do
            local chars = {}
            for _ = 1, math.random(1, 12) do
                -- One codepoint from each length class.
                local class = math.random(1, 4)
                local code =
                    class == 1 and math.random(0x21, 0x7E)
                    or class == 2 and math.random(0xA1, 0x7FF)
                    or class == 3 and math.random(0x800, 0xD7FF)
                    or math.random(0x10000, 0x10FFFF)
                chars[#chars + 1] = utf8.char(code)
            end
            local text = table.concat(chars)
            eq(Util.sanitizeText(text, #text), text,
                'text that fits must come back untouched')
        end
    end)
end)
