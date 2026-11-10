--- The notify helpers every module shares (server/notify.lua): telling the
--- parties of a contract (Notify.parties, used by staff freezes and staff
--- deadline moves) and the one police job list every dispatch entry goes
--- to (Police.jobs, server/police.lua).

local function noticesTo(src, title)
    local n = 0
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src and event.args[1].title == title then n = n + 1 end
    end
    return n
end

local function setUp()
    local s = newStack()
    local f = fixture(s)
    local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
        mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
    truthy(c, 'placed: ' .. tostring(err))
    truthy(s.contracts.accept(f.hitman, c.id), 'taken')
    -- Past any wait before the target is shown it (Notify.shownToTarget).
    Env.time = Env.time + 3600
    return s, f, s.storage.readContract(c.id)
end

describe('Notify.parties: the same words to every party of a contract', function()
    it('tells the placer, the target and each active hitman once', function()
        local s, _, c = setUp()
        Env.clientEvents = {}
        s.notify.parties(c, 'Lib parties', 'Something changed.', 'hold')
        eq(noticesTo(1, 'Lib parties'), 1, 'the placer')
        eq(noticesTo(2, 'Lib parties'), 1, 'the target, shown the contract')
        eq(noticesTo(3, 'Lib parties'), 1, 'the hitman')
    end)

    it('skips the one named, and anybody the caller leaves out', function()
        local s, _, c = setUp()
        Env.clientEvents = {}
        s.notify.parties(c, 'Lib skip', 'x', 'hold', { skip = 'CREATOR1',
            except = function(cid) return cid == 'HITMAN01' end })
        eq(noticesTo(1, 'Lib skip'), 0, 'skipped')
        eq(noticesTo(3, 'Lib skip'), 0, 'left out')
        eq(noticesTo(2, 'Lib skip'), 1, 'everybody else told')
    end)

    it('tells no hitman who has left the contract', function()
        local s, f, c = setUp()
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        Env.clientEvents = {}
        s.notify.parties(s.storage.readContract(c.id), 'Lib left', 'x', 'hold')
        eq(noticesTo(3, 'Lib left'), 0)
        eq(noticesTo(1, 'Lib left'), 1)
    end)
end)

describe('Police.jobs: who dispatch entries are for', function()
    it('lists the advisory job names switched on, sorted, and police when none is', function()
        local s = newStack()
        Config.Advisory.RecipientJobNames = { sast = true, fib = true, ems = false, [1] = true }
        local jobs = s.police.jobs()
        eq(table.concat(jobs, ','), 'fib,sast')
        Config.Advisory.RecipientJobNames = {}
        eq(table.concat(s.police.jobs(), ','), 'police')
        Config.Advisory = nil
        local ok, none = pcall(s.police.jobs)
        truthy(ok, 'no advisory section at all never raises')
        eq(table.concat(none, ','), 'police')
        resetConfig()
    end)
end)
