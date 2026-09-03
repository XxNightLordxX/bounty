--- Headless test runner.
--- Loads the real server modules against the stubbed runtime and runs every
--- suite. Exit code is non-zero on any failure.

package.path = './?.lua;./?/init.lua;' .. package.path

local Natives = require('crimson-bounty.tests.harness.natives')
local Env = Natives.env

Natives.install()

-- Module loader used by the server files.
_G.require_shared = function(name) return require('crimson-bounty.shared.' .. name) end

-- The resource's own require (server/boot.lua) resolves 'server.escrow'
-- against the resource root. Teaching the harness the same shape is what
-- lets main.lua — the real wiring, the tick and the expiry pass — be loaded
-- and tested rather than reimplemented here. Reimplementing it is how
-- app.init came to be missing from newStack for the life of the build.
package.path = './crimson-bounty/?.lua;' .. package.path

_G.CB = require('crimson-bounty.shared.constants')
_G.Config = require('crimson-bounty.config.config')

-- os.time is driven by the harness clock so tests can advance time.
local realTime = os.time
os.time = function() return Env.time end

local Suite = {
    total = 0, passed = 0, failed = 0, current = nil, failures = {},
}

--- Groups tests under a name for failure reporting. The name is restored
--- afterwards, so a nested group does not silently relabel every test that
--- follows it in the file — a mislabelled failure sends you to the wrong
--- code.
function Suite.describe(name, fn)
    local outer = Suite.current
    Suite.current = outer and (outer .. ' > ' .. name) or name
    fn()
    Suite.current = outer
end

--- A snapshot of the configuration as the file ships it, taken once.
---
--- Suites change config to test a rule, and restoring on the line after the
--- assertions only works when they pass. A failing test used to leave its
--- override in place, so one failure became several in unrelated suites and
--- the real one was buried. Every stack now starts from this snapshot.
local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

local CONFIG_DEFAULTS = deepCopy(Config)

--- Restore in place, recursing into tables that exist in both. Assigning a
--- fresh table would leave anything holding a subtable — a module that did
--- `local rules = Config.Sources.item` at load — looking at a detached copy.
local function restoreInto(target, defaults)
    for key in pairs(target) do
        if defaults[key] == nil then target[key] = nil end
    end
    for key, value in pairs(defaults) do
        if type(value) == 'table' and type(target[key]) == 'table' then
            restoreInto(target[key], value)
        else
            target[key] = deepCopy(value)
        end
    end
end

function Suite.resetConfig()
    restoreInto(Config, CONFIG_DEFAULTS)
end

--- Run `fn` with configuration overrides applied, and put the old values
--- back whichever way `fn` ends.
---
--- Restoring on the line after the assertions only works when they pass. A
--- failing test used to leave the config it changed in place, so one failure
--- became several in unrelated suites and the real one was hard to find.
---@param overrides table [ { table, key, value } ]
---@param fn function
function Suite.withConfig(overrides, fn)
    local saved = {}
    for i = 1, #overrides do
        local target, key, value = overrides[i][1], overrides[i][2], overrides[i][3]
        saved[i] = { target, key, target[key] }
        target[key] = value
    end

    local ok, err = pcall(fn)

    for i = #saved, 1, -1 do
        saved[i][1][saved[i][2]] = saved[i][3]
    end

    if not ok then error(err, 0) end
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

--- Read a source file, for the few assertions that are about the source
--- rather than about behaviour.
function _G.read_file(path)
    local handle = io.open(path, 'r')
    if not handle then return '' end
    local content = handle:read('*a')
    handle:close()
    return content
end

_G.describe, _G.it, _G.eq, _G.truthy, _G.falsy = Suite.describe, Suite.it, Suite.eq, Suite.truthy, Suite.falsy
_G.withConfig, _G.resetConfig = Suite.withConfig, Suite.resetConfig
_G.Env, _G.Natives, _G.Suite = Env, Natives, Suite

--- Build a fully wired server stack against fresh in-memory storage.
--- Every suite starts from this, so no test can be polluted by another.
--- Build a stack whose storage returns copies from every read, the way a
--- real database does. The memory backend hands back live references, so a
--- bug that depends on writing back a stale snapshot cannot be reproduced
--- against it — the snapshot IS the stored row.
---@return table stack
function _G.newCopyingStack()
    local stack = newStack()
    local wrap = require('crimson-bounty.tests.harness.copying_store')
    local copying = wrap(stack.storage)

    -- Rewire every module that holds the store, so nothing is left talking
    -- to the sharing one behind the wrapper's back.
    for _, module in ipairs({ 'audit', 'escrow', 'ledger' }) do
        local _ = module
    end

    stack.audit.init(copying)
    stack.escrow.init(copying, stack.audit)
    stack.progression.init({ storage = copying, identity = stack.identity, audit = stack.audit })
    stack.contracts.init({ storage = copying, escrow = stack.escrow, identity = stack.identity,
                           audit = stack.audit, notify = stack.notify,
                           progression = stack.progression, death = stack.death })
    stack.ledger.init(copying)
    stack.bailout.init({ storage = copying, identity = stack.identity,
                         contracts = stack.contracts, escrow = stack.escrow,
                         audit = stack.audit, notify = stack.notify, kidnap = stack.kidnap })
    stack.death.init({ storage = copying, identity = stack.identity,
                       contracts = stack.contracts, audit = stack.audit })

    stack.storage = copying
    return stack
end

function _G.newStack()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    -- Every stack starts from the configuration as it ships. A test that
    -- changes a setting — and fails before putting it back — no longer
    -- changes what every later test is measuring.
    Suite.resetConfig()
    -- Likewise for a fully-equipped server.
    Natives.resetResourceStates()

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
    package.loaded['crimson-bounty.server.progression'] = nil
    package.loaded['crimson-bounty.server.app'] = nil
    package.loaded['crimson-bounty.server.admin'] = nil
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
    local progression = require('crimson-bounty.server.progression')
    local app        = require('crimson-bounty.server.app')
    local admin      = require('crimson-bounty.server.admin')

    storage.open()
    audit.init(storage)
    notify.init({ identity = identity })
    escrow.init(storage, audit)
    progression.init({ storage = storage, identity = identity, audit = audit })
    contracts.init({
        storage = storage, escrow = escrow, identity = identity,
        audit = audit, notify = notify, progression = progression, death = death,
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
    informant.init({ storage = storage, identity = identity, audit = audit, death = death })
    amendments.init({ storage = storage, identity = identity, contracts = contracts,
        escrow = escrow, audit = audit, notify = notify })
    comms.init({ storage = storage, identity = identity, audit = audit,
        notify = notify, ratelimit = ratelimit })

    mugshot.init({ identity = identity, audit = audit })
    projection.init({ storage = storage, identity = identity, escrow = escrow,
                      kidnap = kidnap, mugshot = mugshot, progression = progression })

    -- Wired exactly as main.lua wires it. The app was previously left
    -- uninitialised here, so anything it reached for through deps was
    -- unreachable in a test and only failed on a live server.
    local wiring = {
        storage = storage, identity = identity, ratelimit = ratelimit, audit = audit,
        notify = notify, escrow = escrow, contracts = contracts, ledger = ledger,
        death = death, photo = photo, kidnap = kidnap, bailout = bailout,
        informant = informant, amendments = amendments, comms = comms,
        projection = projection, mugshot = mugshot, progression = progression,
        admin = admin,
    }
    app.init(wiring)
    admin.init(wiring)

    return {
        storage = storage, audit = audit, kidnap = kidnap, projection = projection,
        bailout = bailout, informant = informant, amendments = amendments, comms = comms, identity = identity, notify = notify,
        escrow = escrow, contracts = contracts, ratelimit = ratelimit,
        ledger = ledger, death = death, photo = photo, bridges = bridges,
        mugshot = mugshot, progression = progression, app = app, admin = admin,
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
    'completion_spec', 'kidnap_spec', 'interaction_spec', 'projection_spec', 'storage_spec', 'progression_spec', 'invariant_spec', 'boot_spec', 'admin_spec', 'fuzz_spec',
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
