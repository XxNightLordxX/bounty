--- Headless test runner.
--- Loads the real server modules against the stubbed runtime and runs every
--- suite. Exit code is non-zero on any failure.

package.path = './?.lua;./?/init.lua;' .. package.path

local Natives = require('crimson-bounty.tests.harness.natives')
local Env = Natives.env

Natives.install()

-- Module loader used by the server files.
_G.require_shared = function(name) return require('crimson-bounty.shared.' .. name) end

_G.CB = require('crimson-bounty.shared.constants')
_G.Config = require('crimson-bounty.config.config')

-- os.time is driven by the harness clock so tests can advance time.
local realTime = os.time
os.time = function() return Env.time end

local Suite = {
    total = 0, passed = 0, failed = 0, current = nil, failures = {},
}

function Suite.describe(name, fn)
    Suite.current = name
    fn()
end

function Suite.it(name, fn)
    Suite.total = Suite.total + 1
    local ok, err = pcall(fn)
    if ok then
        Suite.passed = Suite.passed + 1
    else
        Suite.failed = Suite.failed + 1
        table.insert(Suite.failures, ('%s > %s\n    %s'):format(Suite.current, name, tostring(err)))
    end
end

function Suite.eq(actual, expected, message)
    if actual ~= expected then
        error(('%s: expected %s, got %s'):format(message or 'mismatch', tostring(expected), tostring(actual)), 2)
    end
end

function Suite.truthy(value, message)
    if not value then error((message or 'expected truthy') .. ', got ' .. tostring(value), 2) end
end

function Suite.falsy(value, message)
    if value then error((message or 'expected falsy') .. ', got ' .. tostring(value), 2) end
end

_G.describe, _G.it, _G.eq, _G.truthy, _G.falsy = Suite.describe, Suite.it, Suite.eq, Suite.truthy, Suite.falsy
_G.Env, _G.Natives, _G.Suite = Env, Natives, Suite

--- Build a fully wired server stack against fresh in-memory storage.
--- Every suite starts from this, so no test can be polluted by another.
function _G.newStack()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }

    package.loaded['crimson-bounty.server.storage.memory'] = nil
    package.loaded['crimson-bounty.server.escrow'] = nil
    package.loaded['crimson-bounty.server.contracts'] = nil
    package.loaded['crimson-bounty.server.audit'] = nil
    package.loaded['crimson-bounty.server.notify'] = nil
    package.loaded['crimson-bounty.server.identity'] = nil
    package.loaded['crimson-bounty.server.ratelimit'] = nil
    package.loaded['crimson-bounty.server.ledger'] = nil
    package.loaded['crimson-bounty.server.completion.death'] = nil
    package.loaded['crimson-bounty.server.completion.photo'] = nil
    package.loaded['crimson-bounty.server.completion.kidnap'] = nil
    package.loaded['crimson-bounty.server.comms'] = nil
    package.loaded['crimson-bounty.server.projection'] = nil
    package.loaded['crimson-bounty.server.bridges'] = nil
    package.loaded['crimson-bounty.server.mugshot'] = nil
    package.loaded['crimson-bounty.server.amendments'] = nil
    package.loaded['crimson-bounty.server.informant'] = nil
    package.loaded['crimson-bounty.server.bailout'] = nil

    local storage   = require('crimson-bounty.server.storage.memory')
    local audit     = require('crimson-bounty.server.audit')
    local identity  = require('crimson-bounty.server.identity')
    local notify    = require('crimson-bounty.server.notify')
    local escrow    = require('crimson-bounty.server.escrow')
    local contracts = require('crimson-bounty.server.contracts')
    local ratelimit = require('crimson-bounty.server.ratelimit')
    local ledger    = require('crimson-bounty.server.ledger')
    local death     = require('crimson-bounty.server.completion.death')
    local photo     = require('crimson-bounty.server.completion.photo')
    local kidnap    = require('crimson-bounty.server.completion.kidnap')
    local bailout    = require('crimson-bounty.server.bailout')
    local informant  = require('crimson-bounty.server.informant')
    local amendments = require('crimson-bounty.server.amendments')
    local comms      = require('crimson-bounty.server.comms')
    local projection = require('crimson-bounty.server.projection')
    local bridges    = require('crimson-bounty.server.bridges')
    local mugshot    = require('crimson-bounty.server.mugshot')

    storage.open()
    audit.init(storage)
    notify.init({ identity = identity })
    escrow.init(storage, audit)
    contracts.init({
        storage = storage, escrow = escrow, identity = identity,
        audit = audit, notify = notify,
    })

    ledger.init(storage)
    death.init({ storage = storage, identity = identity, contracts = contracts, audit = audit })
    photo.init({
        storage = storage, identity = identity, contracts = contracts, audit = audit,
        death = death, notify = notify, ledger = ledger,
    })

    kidnap.init({
        storage = storage, identity = identity, contracts = contracts,
        audit = audit, notify = notify, ledger = ledger,
    })

    bailout.init({ storage = storage, identity = identity, contracts = contracts,
        escrow = escrow, audit = audit, notify = notify, kidnap = kidnap })
    informant.init({ storage = storage, identity = identity, audit = audit })
    amendments.init({ storage = storage, identity = identity, contracts = contracts,
        escrow = escrow, audit = audit, notify = notify })
    comms.init({ storage = storage, identity = identity, audit = audit,
        notify = notify, ratelimit = ratelimit })

    mugshot.init({ identity = identity, audit = audit })
    projection.init({ storage = storage, identity = identity, escrow = escrow,
                      kidnap = kidnap, mugshot = mugshot })

    return {
        storage = storage, audit = audit, kidnap = kidnap, projection = projection,
        bailout = bailout, informant = informant, amendments = amendments, comms = comms, identity = identity, notify = notify,
        escrow = escrow, contracts = contracts, ratelimit = ratelimit,
        ledger = ledger, death = death, photo = photo, bridges = bridges,
        mugshot = mugshot,
    }
end

--- Common fixture: a criminal creator, a criminal target, a criminal hunter.
function _G.fixture(stack, overrides)
    overrides = overrides or {}
    local creator = Env.addPlayer({
        source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
        cash = overrides.creatorCash or 100000, bank = overrides.creatorBank or 100000,
        inventory = overrides.creatorInventory or {
            { name = 'black_money', count = 50000 },
            { name = 'lockpick', count = 5 },
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, metadata = { serial = 'ABC123', ammo = 12 } },
        },
        firstname = 'Vic', lastname = 'Marlowe',
    })
    local target = Env.addPlayer({
        source = 2, citizenid = 'TARGET01', license = 'license:bbb',
        cash = 20000, bank = 20000, firstname = 'Dana', lastname = 'Reyes',
        job = overrides.targetJob or { name = 'unemployed', type = 'none' },
    })
    local hunter = Env.addPlayer({
        source = 3, citizenid = 'HUNTER01', license = 'license:ccc',
        cash = 5000, bank = 5000, firstname = 'Rook', lastname = 'Ash',
    })
    return {
        creator = stack.identity.resolve(1),
        target  = stack.identity.resolve(2),
        hunter  = stack.identity.resolve(3),
        creatorPlayer = creator, targetPlayer = target, hunterPlayer = hunter,
    }
end

--- Load and run every suite listed here.
local suites = {
    'escrow_spec', 'contracts_spec', 'exploit_spec', 'advisory_spec', 'slots_spec',
    'completion_spec', 'kidnap_spec', 'interaction_spec', 'projection_spec', 'storage_spec', 'invariant_spec',
}

for _, name in ipairs(suites) do
    local ok, err = pcall(require, 'crimson-bounty.tests.' .. name)
    if not ok then
        Suite.failed = Suite.failed + 1
        table.insert(Suite.failures, ('suite %s failed to load\n    %s'):format(name, tostring(err)))
    end
end

os.time = realTime

io.write('\n')
for _, f in ipairs(Suite.failures) do io.write('FAIL  ', f, '\n') end
io.write(('\n%d passed, %d failed, %d total\n'):format(Suite.passed, Suite.failed, Suite.total))
os.exit(Suite.failed == 0 and 0 or 1)
