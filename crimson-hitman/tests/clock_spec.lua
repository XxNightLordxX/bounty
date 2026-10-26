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

local Util = require('crimson-hitman.shared.util')

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
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hitman, c.id, false)
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
        local token = s.photo.issue(f.hitman, c.id)
        truthy(token, 'a token to expire')

        -- Well past PhotoTokenLifetimeSeconds, on the far side of the wrap.
        rawTimer(250 + (Config.Completion.PhotoTokenLifetimeSeconds * 1000) + 1000)
        local ok, err = s.photo.submit(f.hitman, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'a stale token must not be accepted because the clock wrapped')
        eq(err, CH.ERR.PROOF_EXPIRED)
    end)

    it('still accepts a token submitted within its lifetime after a wrap', function()
        local s, f, c = ready()
        local token = s.photo.issue(f.hitman, c.id)
        truthy(token)

        rawTimer(250)
        local ok, err = s.photo.submit(f.hitman, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'a fresh token must survive the wrap too: ' .. tostring(err))
    end)

    it('sweeps expired tokens after a wrap', function()
        local s, f, c = ready()
        truthy(s.photo.issue(f.hitman, c.id))
        eq(s.photo.tokenCount(), 1)

        rawTimer(250 + (Config.Completion.PhotoTokenLifetimeSeconds * 1000) + 1000)
        s.photo.sweep()
        eq(s.photo.tokenCount(), 0, 'the sweep must still reclaim tokens after a wrap')
    end)
end)


--- Minting an id nothing is using.
describe('Util.roundClock', function()
    it('rounds up to the next five minutes', function()
        eq(Util.roundClock(1700000000), 1700000100)
        eq(Util.roundClock(1700000101), 1700000400)
        eq(Util.roundClock(1700000399), 1700000400)
    end)

    it('leaves a time already on the five minutes where it is', function()
        eq(Util.roundClock(1700000100), 1700000100)
        eq(Util.roundClock(0), 0)
    end)

    it('never gives less time than it was handed', function()
        for at = 1700000000, 1700000000 + 900 do
            local r = Util.roundClock(at)
            truthy(r >= at and r < at + 300 and r % 300 == 0,
                ('roundClock(%d) = %d'):format(at, r))
        end
    end)
end)

describe('Util.mintId', function()
    local Util = require('crimson-hitman.shared.util')

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
    local Util = require('crimson-hitman.shared.util')

    --- Whether every byte sequence in this string is well-formed UTF-8.
    local function wellFormed(text)
        return utf8 and utf8.len(text) ~= nil
    end

    it('counts characters at the length cap, not bytes', function()
        -- The page's box counts characters, and so does a VARCHAR. Counted
        -- in bytes, a 140-character reason in accented or Cyrillic text was
        -- cut to 70 after the contract had been paid for.
        local text = string.rep('\195\169', 100) .. string.rep('a', 40)
        eq(utf8.len(text), 140)
        eq(Util.sanitizeText(text, 140), text, 'the reason the box allowed was cut short')
    end)

    it('cuts on a character boundary', function()
        local text = string.rep('a', 30) .. '\240\159\148\170 blade'
        local out = Util.sanitizeText(text, 31)
        truthy(wellFormed(out), 'the cap must fall on a character boundary')
        eq(out, string.rep('a', 30) .. '\240\159\148\170', 'the emoji is one character')

        local two = Util.sanitizeText(string.rep('b', 31) .. '\195\169 end', 32)
        truthy(wellFormed(two))
        eq(two, string.rep('b', 31) .. '\195\169')
    end)

    it('keeps a character that fits exactly', function()
        local text = string.rep('c', 28) .. '\240\159\148\170'
        local out = Util.sanitizeText(text, 29)
        eq(out, text, 'nothing straddles the cap here')
        truthy(wellFormed(out))
    end)

    it('does no more work on a huge payload than on a full one', function()
        -- The validating pass walks every byte it is given, so it is given
        -- no more than the cap could keep: four bytes a character.
        local real, longest = Util.toValidUtf8, 0
        Util.toValidUtf8 = function(text)
            longest = math.max(longest, #text)
            return real(text)
        end
        local out = Util.sanitizeText(string.rep('\240\159\148\170', 250000), 32)
        Util.toValidUtf8 = real
        eq(utf8.len(out), 32)
        truthy(wellFormed(out))
        truthy(longest <= 32 * 4, 'a megabyte walked to keep 32 characters: ' .. longest)
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
    local Util = require('crimson-hitman.shared.util')

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

describe('a photo token after the kill was undone', function()
    it('is refused once a revive cleared the kill, even if the target then leaves', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        s.contracts.accept(f.hitman, c.id, false)
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        local token = s.photo.issue(f.hitman, c.id)
        truthy(token)
        -- Revived after the proof window, then gone.
        Env.gameTimer = Env.gameTimer + (Config.Completion.ProofWindowSeconds + 5) * 1000
        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevived('TARGET01')
        Env.dropPlayer = Env.dropPlayer
        Env.players[2] = nil
        local before = Env.players[3].PlayerData.money.cash
        local ok, err = s.photo.submit(f.hitman, token, 'https://cdn.fivemanage.com/p.png')
        falsy(ok, 'paid for a kill the revive had undone')
        eq(err, CH.ERR.PHOTO_REVIVED)
        eq(Env.players[3].PlayerData.money.cash, before)
    end)
end)

--------------------------------------------------------------------------
-- The expiry pass (main.lua ExpireContracts)
--------------------------------------------------------------------------

--- main.lua's own start on memory. `configure` runs after the config is
--- reset and before the start, as a server.cfg's config would.
local function bootMain(configure)
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
    package.loaded['server.main'] = nil
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'memory'
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

local function worth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

--- A staked contract a hitman holds, with a pass run since.
local function heldContract(configure)
    local main, s = bootMain(function()
        if configure then configure() end
    end)
    Config.Limits.ExclusiveIdleReleaseSeconds = 0
    Config.Limits.ExclusiveAttemptWindowSeconds = 0
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
    })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id), 'held')
    main.markPresenceChanged()
    main.expire()
    return main, s, f, c
end

--- What the log kept after the start: Log.always lines among them.
local function said()
    local out = {}
    for _, entry in ipairs(require('crimson-hitman.shared.log').view().recent) do
        out[#out + 1] = entry.text
    end
    return table.concat(out, '\n')
end

describe('the expiry pass past a contract the store refuses', function()
    --- S01: an endPause the database refused (a pause total past its INT
    --- column) raised out of the pass at that contract, every pass, and no
    --- contract after it was expired, paused or resumed.
    it('expires the others in the same pass, and names the one it could not update', function()
        local main, s = bootMain()
        Config.Limits.MaxActiveContractsPerTarget = 5
        Config.Limits.MaxActiveContractsPerCreator = 5
        local f = fixture(s)
        local a = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        local b = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'y',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        truthy(a and b, 'two contracts')
        -- The first one paused, so the pass ends its pause; the second one
        -- simply overdue.
        local rowA = s.storage.readContract(a.id)
        rowA.paused_since = os.time() - 60
        s.storage.writeContract(rowA)
        local rowB = s.storage.readContract(b.id)
        rowB.deadline_at = os.time() - 5
        s.storage.writeContract(rowB)

        local live, endPause = s.storage.liveContracts, s.storage.endPause
        s.storage.liveContracts = function()
            local rows = live()
            table.sort(rows, function(x, y) return x.id == a.id and y.id ~= a.id end)
            return rows
        end
        s.storage.endPause = function(id, ...)
            if id == a.id then
                error("crimson-hitman was unable to execute a query!\nQuery: UPDATE crimson_contracts"
                    .. " SET deadline_at = deadline_at + ?\n[60,60000,\"x\",1]\n"
                    .. "Out of range value for column 'paused_ms' at row 1", 0)
            end
            return endPause(id, ...)
        end
        main.markPresenceChanged()
        local ran, err = pcall(main.expire)
        s.storage.liveContracts, s.storage.endPause = live, endPause

        truthy(ran, 'the pass did not stop at the first contract: ' .. tostring(err))
        eq(s.storage.readContract(b.id).state, CH.STATE.EXPIRED, 'the second one is expired by the same pass')
        eq(s.storage.readContract(a.id).state, CH.STATE.ACTIVE, 'the first left as it was')
        local text = said()
        truthy(text:find(('expiry pass: contract %s could not be updated'):format(a.id), 1, true), text)
        truthy(text:find("Out of range value for column 'paused_ms'", 1, true), 'in the store\'s words: ' .. text)
        falsy(text:find('60000', 1, true), 'and none of the values it was sent: ' .. text)
    end)

    it('says so once in ten minutes, and tries it again within a minute', function()
        local main, s = bootMain()
        local f = fixture(s)
        local a = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        local row = s.storage.readContract(a.id)
        row.paused_since = os.time() - 60
        s.storage.writeContract(row)
        local endPause, tries = s.storage.endPause, 0
        s.storage.endPause = function() tries = tries + 1 error('refused', 0) end
        main.markPresenceChanged()
        main.expire()
        eq(tries, 1)
        Env.advance(30)
        main.expire()
        eq(tries, 1, 'not on every tick')
        Env.advance(31)
        main.expire()
        eq(tries, 2, 'again within a minute, with nobody arriving or leaving')
        local n = 0
        for line in said():gmatch('[^\n]+') do
            if line:find('could not be updated', 1, true) then n = n + 1 end
        end
        eq(n, 1, 'one console line, not one a minute')
        s.storage.endPause = endPause
    end)

    --- The flag that a player came or went was cleared before the read, so
    --- a read that raised forgot the logoff until the next deadline.
    it('keeps a logoff it was woken for when the read of the contracts raises', function()
        local main, s, _, c = heldContract()
        Env.removePlayer(2)
        main.markPresenceChanged()
        local live = s.storage.liveContracts
        s.storage.liveContracts = function() error('the store did not answer', 0) end
        falsy(pcall(main.expire), 'the read raised')
        s.storage.liveContracts = live
        main.expire()
        truthy(s.storage.readContract(c.id).paused_since,
            'the next pass still acts on the target having gone')
    end)
end)

describe('a party gone in the seconds after the deadline, as this resource ships', function()
    local Shipped = require('crimson-hitman.tests.harness.shipped')

    --- W077: a pause begun after the deadline turned the expiry into a
    --- lifetime ending, which hands the stake back, and left the hitman on
    --- a card saying Due now they could not work.
    it('expires the contract and forfeits the stake, whoever left', function()
        local main, s, _, c = heldContract(Shipped.apply)
        eq(s.storage.readContract(c.id).fulfilment_rule, CH.FULFILMENT_RULE.ALIVE)
        local hitman = worth(3)
        local row = s.storage.readContract(c.id)
        Env.advance(row.deadline_at - os.time() + 5)
        -- The person who placed it (named) disconnects five seconds after
        -- the deadline, before the pass comes round.
        Env.removePlayer(1)
        main.markPresenceChanged()
        main.expire()
        local after = s.storage.readContract(c.id)
        eq(after.state, CH.STATE.EXPIRED, 'expired, not paused')
        eq(after.paused_since, nil, 'no pause began after the deadline')
        eq(worth(3), hitman, 'the hitman ran out of time: no stake back')
        local stake
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CH.PORTION.STAKE then stake = line end
        end
        truthy(stake.state == CH.ESCROW_STATE.SETTLED or stake.owed_to == 'CREATOR1',
            'the stake is the client\'s, owed to them while they are away')
    end)

    it('still pauses for a party gone before the deadline', function()
        local main, s, _, c = heldContract(Shipped.apply)
        Env.removePlayer(1)
        main.markPresenceChanged()
        main.expire()
        truthy(s.storage.readContract(c.id).paused_since, 'paused while the client is away')
    end)
end)

describe('a sentence the pass cannot count yet', function()
    local function jailedAt(x, y, minutes)
        Env.players[2].PlayerData.metadata.injail = minutes
        Env.players[2]._coords = { x = x, y = y, z = 45.0 }
    end

    --- W076: the hook woke one pass while the target was still outside the
    --- prison, and the next one came at the deadline, too late to pause.
    it('pauses the clock within a minute of the target reaching the prison', function()
        local main, s, _, c = heldContract()
        local row = s.storage.readContract(c.id)
        Env.advance(row.deadline_at - os.time() - 420)
        main.markPresenceChanged()
        main.expire()
        -- Sentenced at the station, seven minutes before the deadline.
        jailedAt(0.0, 0.0, 60)
        Env.handlers['qbx_core:server:onSetMetaData']('injail', 0, 60, 2)
        main.expire()
        falsy(s.storage.readContract(c.id).paused_since, 'not in the prison yet')

        Env.advance(15)
        local zone = Config.Limits.JailZone
        jailedAt(zone.x + 10.0, zone.y - 10.0, 60)
        local pausedAfter
        for i = 1, 6 do
            Env.advance(10)
            main.expire()
            if not pausedAfter and s.storage.readContract(c.id).paused_since then pausedAfter = i * 10 end
        end
        truthy(pausedAfter, 'paused once they were inside')
        truthy(pausedAfter <= 60, 'within a minute of arriving: ' .. tostring(pausedAfter))
        Env.advance(600)
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'and not expired while they serve')
    end)

    it('pauses within one pass of the switch being turned on from the admin panel', function()
        local main, s, _, c = heldContract()
        Config.Limits.PauseWhileTargetJailed = false
        local zone = Config.Limits.JailZone
        jailedAt(zone.x, zone.y, 60)
        main.markPresenceChanged()
        main.expire()
        falsy(s.storage.readContract(c.id).paused_since, 'the switch is off')

        truthy(s.settings.set('Limits.PauseWhileTargetJailed', true, 'Staff', 'STAFF001'))
        main.expire()
        truthy(s.storage.readContract(c.id).paused_since,
            'the next pass, not the one after the longest skip')
    end)
end)

describe('the expiry pass kept in step', function()
    --- W079: a deadline brought in by Edit waited out the soonest deadline
    --- the pass had last seen.
    it('acts on a deadline brought in by Edit at the next pass after it', function()
        local main, s = bootMain()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c)
        main.markPresenceChanged()
        main.expire()
        truthy(s.contracts.revise(f.creator, c.id, { deadlineSeconds = 300 }))
        local due = s.storage.readContract(c.id).deadline_at
        Env.advance(due - os.time() + 2)
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED, 'expired seconds after its new deadline')
    end)

    it('tries a due contract again on the next tick when its ending was refused', function()
        local main, s, _, c = heldContract()
        local row = s.storage.readContract(c.id)
        Env.advance(row.deadline_at - os.time() + 1)
        local resolve, refused = s.contracts.resolve, false
        s.contracts.resolve = function(...)
            if not refused then
                refused = true
                return false, CH.ERR.LOCKED
            end
            return resolve(...)
        end
        main.markPresenceChanged()
        main.expire()
        truthy(refused, 'the ending was refused once')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        Env.advance(Config.Audit.FlushIntervalMs / 1000)
        main.expire()
        s.contracts.resolve = resolve
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED, 'on the next tick, not ten minutes on')
    end)
end)
