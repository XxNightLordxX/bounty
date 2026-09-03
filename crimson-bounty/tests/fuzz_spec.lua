--- Every handler, against payloads nothing legitimate would send.
---
--- Each of these is what an event a player can trigger looks like when it is
--- not the app sending it. The bar is not that they succeed — most should be
--- refused — it is that none of them throws, hangs, moves money, or answers
--- with something it should not.

local HANDLERS = {
    'list', 'mine', 'ledger', 'searchTargets', 'mugshotImage', 'rewardOptions',
    'create', 'accept', 'abandon', 'requestPhotoToken', 'submitPhoto',
    'armKidnap', 'kidnapProgress', 'bailout', 'informant', 'addEscrow',
    'improve', 'amendments', 'propose', 'respondAmendment',
    'threads', 'readThread', 'sendMessage', 'requestCall',
}

--- A table that is its own child. Anything walking it without a depth guard
--- never comes back.
local function cyclic()
    local t = { id = 'ct00000001' }
    t.self = t
    t.reward = { baseline = { cash = 1 }, loop = t }
    return t
end

--- Deeper than any legitimate payload, to catch a recursive walk.
local function deep(levels)
    local root = {}
    local node = root
    for _ = 1, levels do
        node.next = {}
        node = node.next
    end
    return root
end

local function payloads()
    local out = {
        nil,
        {},
        true,
        42,
        'a string where a table belongs',
        { id = nil },
        { id = 42 },
        { id = {} },
        { id = true },
        { id = '' },
        { id = string.rep('a', 10000) },
        { id = 'ct00000001/../../etc/passwd' },
        { id = "ct' OR 1=1 --" },
        { id = 'ct00000001\0truncated' },
        { id = 'ct00000001', __rid = 'not a number' },
        { id = 'ct00000001', __rid = 1 / 0 },
        { id = 'ct00000001', approve = 'yes' },
        { id = 'ct00000001', anonymous = 'true' },
        { query = string.rep('x', 5000) },
        { query = 1 },
        { body = string.rep('x', 100000) },
        { body = { 'not a string' } },
        { page = -1 },
        { page = 0 / 0 },
        { page = 1 / 0 },
        { page = 2 ^ 53 },
        { target = { handle = 'nope' } },
        { reward = 'not a table' },
        { reward = { slots = 'not a table' } },
        { reward = { slots = {} } },
        { reward = { baseline = { cash = -1 } } },
        { reward = { baseline = { cash = 0 / 0 } } },
        { reward = { baseline = { cash = 1 / 0 } } },
        { reward = { baseline = { cash = '5000' } } },
        { reward = { baseline = { items = 'not a list' } } },
        { reward = { baseline = { items = { 'not a table' } } } },
        { reward = { baseline = { items = { { name = {}, count = 1 } } } } },
        { reward = { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = -1 } } } } },
        { kind = 'not_a_kind' },
        { kind = 42 },
        { kind = 'cancel', payload = 'not a table' },
        { url = 'javascript:alert(1)' },
        { url = string.rep('h', 100000) },
        { thread = { 'not a handle' } },
        cyclic(),
        deep(500),
    }
    -- A hole at index 1 (nil) would truncate the array, so it is passed
    -- separately by the caller.
    return out
end

--- Fire a handler as a player and return its reply, or the error it threw.
local function fire(name, source, payload)
    local handler = Env.events['crimson-bounty:' .. name]
    if not handler then return nil, 'unregistered' end

    Env.clientEvents = {}
    _G.source = source
    local ok, err = pcall(handler, payload)
    _G.source = nil

    if not ok then return nil, tostring(err) end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

describe('every handler survives a hostile payload', function()
    it('never throws, whatever it is sent', function()
        local s = newStack()
        local f = fixture(s)

        local thrown = {}
        for _, name in ipairs(HANDLERS) do
            -- nil first, which cannot live in the array below.
            local _, err = fire(name, 1, nil)
            if err and err ~= 'unregistered' then
                thrown[#thrown + 1] = name .. ' (nil): ' .. err
            end

            for _, payload in ipairs(payloads()) do
                local _, threw = fire(name, 1, payload)
                if threw and threw ~= 'unregistered' then
                    thrown[#thrown + 1] = name .. ': ' .. threw
                end
            end
        end

        eq(#thrown, 0, 'handlers threw: ' .. table.concat(thrown, ' | '))
    end)

    it('moves no money for any of them', function()
        local s = newStack()
        local f = fixture(s)

        local function worth()
            local total = 0
            for _, player in pairs(Env.players) do
                total = total + player.PlayerData.money.cash + player.PlayerData.money.bank
            end
            return total
        end

        local before = worth()
        for _, name in ipairs(HANDLERS) do
            for _, payload in ipairs(payloads()) do fire(name, 1, payload) end
        end
        eq(worth(), before, 'a payload nothing legitimate would send moved money')
    end)

    it('creates no contract from any of them', function()
        local s = newStack()
        local f = fixture(s)

        for _, name in ipairs(HANDLERS) do
            for _, payload in ipairs(payloads()) do fire(name, 1, payload) end
        end
        eq(#s.storage.allContracts(), 0, 'a crafted payload created a contract')
    end)

    it('answers a source that is nobody without throwing', function()
        local s = newStack()
        fixture(s)
        local thrown = {}
        for _, name in ipairs(HANDLERS) do
            for _, src in ipairs({ 0, -1, 99999, 2 ^ 31 }) do
                local _, err = fire(name, src, { id = 'ct00000001' })
                if err and err ~= 'unregistered' then
                    thrown[#thrown + 1] = name .. '@' .. src .. ': ' .. err
                end
            end
        end
        eq(#thrown, 0, table.concat(thrown, ' | '))
    end)

    it('leaves no contract in a non-terminal limbo', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id, false))

        for _, name in ipairs(HANDLERS) do
            for _, payload in ipairs(payloads()) do
                fire(name, 1, payload)
                fire(name, 2, payload)
                fire(name, 3, payload)
            end
        end

        local state = s.storage.readContract(c.id).state
        truthy(state == CB.STATE.ACTIVE or state == CB.STATE.ACCEPTED,
            'the contract was left in ' .. tostring(state))
    end)
end)

describe('hostile input reaches the shared validators intact', function()
    local Util = require('crimson-bounty.shared.util')

    it('refuses every id that is not one this store mints', function()
        for _, bad in ipairs({
            '', 'a', 'short', '../../etc/passwd', 'ct/../x', 'ct 00000001',
            'ct\0001', 'ct\n00000001', string.rep('c', 65), "ct' OR '1'='1",
            'ct%00', 'ct;DROP TABLE', '<script>', 'ct00000001 ',
        }) do
            falsy(Util.toId(bad), 'accepted the id ' .. string.format('%q', bad))
        end
        truthy(Util.toId('ct00000001'), 'and still accepts a real one')
    end)

    it('refuses every line id that is not one either', function()
        for _, bad in ipairs({
            '', 'a:b', 'ct00000001:', ':1', 'ct00000001:1:2', '../x:1',
            'ct00000001:1 ', string.rep('c', 90),
        }) do
            falsy(Util.toLineId(bad), 'accepted the line id ' .. string.format('%q', bad))
        end
        truthy(Util.toLineId('ct00000001:3'))
        truthy(Util.toLineId('owe00000001'))
    end)

    it('refuses every count that is not one', function()
        for _, bad in ipairs({ -1, 0.5, -0.0001, 2 ^ 53, 1 / 0, -1 / 0 }) do
            falsy(Util.toCount(bad, 100), 'accepted the count ' .. tostring(bad))
        end
        falsy(Util.toCount(0 / 0, 100), 'accepted NaN')
        falsy(Util.toCount('abc', 100))
        falsy(Util.toCount({}, 100))
        falsy(Util.toCount(nil, 100))
        eq(Util.toCount('42', 100), 42, 'and still reads a numeric string')
    end)

    it('bounds text rather than trusting its length', function()
        local long = string.rep('x', 100000)
        local clean = Util.sanitizeText(long, 140)
        truthy(clean == nil or #clean <= 140,
            'a hundred thousand characters must not reach storage')
    end)
end)
