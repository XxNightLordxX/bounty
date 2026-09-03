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
    package.loaded['crimson-bounty.server.progression'] = nil
    package.loaded['crimson-bounty.server.app'] = nil
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
    informant.init({ storage = storage, identity = identity, audit = audit })
    amendments.init({ storage = storage, identity = identity, contracts = contracts,
        escrow = escrow, audit = audit, notify = notify })
    comms.init({ storage = storage, identity = identity, audit = audit,
        notify = notify, ratelimit = ratelimit })

    mugshot.init({ identity = identity, audit = audit })
    projection.init({ storage = storage, identity = identity, escrow = escrow,
                      kidnap = kidnap, mugshot = mugshot, progression = progression })

    return {
        storage = storage, audit = audit, kidnap = kidnap, projection = projection,
        bailout = bailout, informant = informant, amendments = amendments, comms = comms, identity = identity, notify = notify,
        escrow = escrow, contracts = contracts, ratelimit = ratelimit,
        ledger = ledger, death = death, photo = photo, bridges = bridges,
        mugshot = mugshot, progression = progression, app = app,
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
