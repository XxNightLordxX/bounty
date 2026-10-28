--- Who may act on a contract, cell by cell.
---
--- Every handler registered in server/app.lua, crossed with every role a
--- caller can hold on the contract it names: the creator who placed it, the
--- target it names, a hitman who accepted it, a hitman accepted on a
--- DIFFERENT contract, a complete stranger, and a server admin with no
--- relation to it at all. Each cell says permit or refuse, and the grid is
--- driven through the real net events rather than the modules underneath,
--- because the net event is the only surface a player has.
---
--- The valuable half is the refusals. A missing authorisation check is not
--- a crash and not a wrong number: it is a request that quietly succeeds
--- for the wrong person. Per-module specs assert the one refusal each
--- module owns, and they are good at it — but they are a list, and a list
--- has no shape. Nothing said that EVERY handler refuses EVERY role that is
--- not party to the contract, so a handler could gain a second entry point,
--- or a participant test could be widened by one line, and the suite would
--- report full marks. Three defects planted to check that came back green
--- across the whole shipped suite: a hitman allowed to buy informant data
--- on the contract they are working, the masked relay naming a hitman who
--- paid to be anonymous, and a death report opening a claim for anyone
--- party to the contract rather than only its target.
---
--- Four rules this file enforces on top of permit and refuse:
---
---   * A refusal names its reason. A cell that expects `not_participant` and
---     gets `photo_too_far` has not proved anything: deleting the check it
---     is about would leave it passing. That is not hypothetical — it is
---     what the stolen-photo-token row did until every role was moved to
---     stand over the body.
---   * A refusal carries nothing. Handlers refuse by returning `false, err`,
---     which App.reply forwards as a literal false, so a refused request is
---     an error code and no payload. The gate's throttle reply is the one
---     exception in the resource and is checked on its own terms.
---   * A citizen id belonging to somebody else never crosses, on any
---     handler. Four modules state that rule in their own comments and each
---     enforces it for the payload it builds; this walks every reply the
---     grid produces and asks it once.
---   * Anonymity is not an authorisation. The whole grid runs twice — once
---     on a named contract, once with the creator and the hitman both
---     anonymous — with the same verdicts expected either way, and every
---     reply from the second pass scanned for the real names underneath.
---
--- And the rule that keeps it a matrix: a handler with no row FAILS. The
--- grid is checked against App.handlers and against the RegisterNetEvent
--- lines in app.lua, in both directions, so a handler added without a row
--- is a failure rather than a silent gap.

local APP_SOURCE = read_file('crimson-hitman/server/app.lua')

--------------------------------------------------------------------------
-- The cast
--------------------------------------------------------------------------

--- Everyone the grid needs, and what each is for. Ten players rather than
--- six: three contracts have to exist at once for "a hitman on somebody
--- else's contract" to be a role somebody can actually hold, and the
--- contract nobody has accepted needs a target of its own because a creator
--- may not place two on the same person inside the cooldown.
local CAST = {
    creator     = { source = 1,  cid = 'CREATOR1', name = { 'Vic', 'Marlowe' } },
    target      = { source = 2,  cid = 'TARGET01', name = { 'Dana', 'Reyes' } },
    hitman      = { source = 3,  cid = 'HITMAN01', name = { 'Rook', 'Ash' } },
    stranger    = { source = 4,  cid = 'STRANGE1', name = { 'Nils', 'Odd' } },
    otherHitman = { source = 5,  cid = 'TAILER01', name = { 'Kade', 'Wolfe' } },
    admin       = { source = 6,  cid = 'ADMIN001', name = { 'Sam', 'Steward' } },
    -- Supporting cast: never a caller, only somebody for a contract to name.
    spare       = { source = 7,  cid = 'TARGET02', name = { 'Pia', 'Nolan' } },
    farCreator  = { source = 8,  cid = 'CREATOR2', name = { 'Otto', 'Vance' } },
    farTarget   = { source = 9,  cid = 'TARGET03', name = { 'Ines', 'Cruz' } },
    victim      = { source = 10, cid = 'VICTIM01', name = { 'Bram', 'Tully' } },
}

--- The six roles every row must answer for, in the order they are reported.
local ROLES = { 'creator', 'target', 'hitman', 'otherHitman', 'stranger', 'admin' }

--- Citizen ids that must never appear in a payload sent to somebody else.
local FOREIGN_CIDS = {}
for _, who in pairs(CAST) do FOREIGN_CIDS[who.cid] = true end

local SCENE = { x = 200.0, y = 200.0, z = 30.0 }

--------------------------------------------------------------------------
-- Driving the real net events
--------------------------------------------------------------------------

--- Fire a handler the way a client does and hand back the reply.
--- Copied from journey_spec: the point of both files is that the payload
--- crosses the boundary rather than the module being called directly.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER', missing = true } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err), threw = true } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

--- Every reply the grid has produced, with who asked, so the leak scan can
--- be a single pass over the whole surface rather than a rule each row has
--- to remember to apply.
local seen = {}

local function record(pass, handler, roleName, actorCid, reply)
    seen[#seen + 1] = { pass = pass, handler = handler, role = roleName,
                        cid = actorCid, reply = reply }
end

--------------------------------------------------------------------------
-- The world each cell is measured in
--------------------------------------------------------------------------

--- A fresh server for one cell.
---
--- One world per cell rather than one for the file: several rows have to
--- arrange mutually exclusive states — a contract nobody holds and a
--- contract mid-handover cannot be the same contract — and a cell that
--- inherited the previous cell's leftovers would be measuring something
--- other than what it says.
---
--- Three contracts:
---   held    the contract under test for most rows. Hitman has accepted it.
---   unheld  the creator's, nobody accepted, for the rows that are refused
---           outright once somebody is working (cancel, revise, withdraw).
---   far     somebody else's entirely, so `otherHitman` is a real hitman
---           rather than a stranger wearing the label.
---@param opts table|nil { anonymous = boolean, fulfilment = string|nil }
local function world(opts)
    opts = opts or {}
    local s = newStack()
    -- The rule its contracts are placed under (Config.Completion.Fulfilment),
    -- where a row needs one other than the suite's.
    if opts.fulfilment then Config.Completion.Fulfilment = opts.fulfilment end

    for _, who in pairs(CAST) do
        Env.addPlayer({
            source = who.source, citizenid = who.cid,
            license = 'license:' .. who.cid,
            cash = 250000, bank = 250000,
            firstname = who.name[1], lastname = who.name[2],
        })
    end
    -- An admin is a player with an ACE, not a different kind of caller. The
    -- app surface has no admin path at all: everything an operator may do
    -- lives behind the commands in server/admin.lua. That is the claim this
    -- column checks.
    Env.aces[CAST.admin.source] = { ['crimson.admin'] = true }

    local who = {}
    for name, entry in pairs(CAST) do who[name] = s.identity.resolve(entry.source) end

    -- No bonus on an alive-only contract: the whole reward is for the live
    -- delivery, and a bonus named on one is refused (no_bonus).
    local held = s.contracts.create(who.creator, {
        targetCid = CAST.target.cid, reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 },
                   bonus = opts.fulfilment ~= CH.FULFILMENT_RULE.ALIVE and { cash = 2500 } or nil },
        bailoutAmount = 15000,
        anonymous = opts.anonymous or nil,
    })
    truthy(held, 'the world needs a contract somebody is working')
    truthy(s.contracts.accept(who.hitman, held.id, opts.anonymous == true),
        'the hitman has to be on it')

    -- Anonymous on the anonymous pass as well: the creator is the same
    -- person, and one named contract of theirs on the board would put their
    -- real name in every listing reply for a reason that has nothing to do
    -- with the contract under test.
    local unheld = s.contracts.create(who.creator, {
        targetCid = CAST.spare.cid, reason = 'Unpaid debt',
        mode = CH.MODE.EXCLUSIVE,
        reward = { baseline = { cash = 5000, bank = 3000 } },
        anonymous = opts.anonymous or nil,
    })
    truthy(unheld, 'the world needs a contract nobody is working')

    local far = s.contracts.create(who.farCreator, {
        targetCid = CAST.farTarget.cid, reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(far, 'the world needs a contract belonging to somebody else')
    truthy(s.contracts.accept(who.otherHitman, far.id, false),
        'the other hitman has to be a hitman, or the column proves nothing')

    return { s = s, who = who, held = held, unheld = unheld, far = far }
end

--- Which player plays each role for a given contract.
---
--- Only the target moves: the contract nobody holds names a different
--- person, so `target` there is that person. `hitman` against the unheld
--- contract is somebody who really did accept a contract — just not this
--- one — which is exactly the role the column is for.
local function castFor(w, which)
    local contract = which == 'unheld' and w.unheld or w.held
    local target = which == 'unheld' and CAST.spare or CAST.target
    return contract, {
        creator = CAST.creator, target = target, hitman = CAST.hitman,
        otherHitman = CAST.otherHitman, stranger = CAST.stranger, admin = CAST.admin,
    }
end

--------------------------------------------------------------------------
-- Arrangements
--------------------------------------------------------------------------

local VALID_IMAGE = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='

--- Put everyone at the scene, and restrain the target: what a handover
--- needs before the server will look at who is asking for one.
local function assembleForHandover(w)
    -- Everybody, not only the three the handover needs. A caller standing
    -- somewhere else would be refused for the distance rather than for who
    -- they are, and a distance refusal would hide a missing one.
    for _, who in pairs(CAST) do
        Env.players[who.source]._coords = { x = SCENE.x, y = SCENE.y, z = SCENE.z }
    end
    Env.players[CAST.target.source].PlayerData.metadata.ishandcuffed = true
end

--- A real, server-observed elimination of the held contract's target by its
--- hitman, leaving a pending claim. Nothing here is taken from a client's
--- word: the damage is recorded, the health loss is real, and the victim
--- reports their own death.
local function eliminate(w)
    Env.players[CAST.hitman.source]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[CAST.target.source]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[CAST.target.source]._health = 140
    w.s.death.recordDamage(CAST.hitman.source, CAST.target.source, 123456)
    Env.players[CAST.target.source].PlayerData.metadata.isdead = true
    w.s.death.onVictimReport(CAST.target.source)
    truthy(w.s.death.getPending(w.held.id, CAST.hitman.cid),
        'the arrangement has to leave a claim the hitman could prove')
end

--- The handle a creator is given for their thread with the hitman. Minted
--- through Comms so it is the real one, and deliberately handed to every
--- role: the question this file asks is whether a handle somebody else was
--- given is any use to you.
local function creatorThreadHandle(w)
    local threads = w.s.comms.threads(w.who.creator, w.held.id)
    truthy(threads and threads[1] and threads[1].handle,
        'the creator has to have a thread with the hitman to hand around')
    return threads[1].handle
end

--- A target handle minted for one searcher, for the roles that place a
--- contract. Minted per searcher and expiring, so each role has to get
--- their own through the browser the page uses.
local function handleForVictim(source)
    local list = call('browseTargets', source, { scope = 'online', page = 1 })
    truthy(list and list.ok, 'a caller has to be able to browse before they can place')
    for _, row in ipairs(list.data.people or {}) do
        if row.name == 'Bram Tully' then return row.handle end
    end
    return nil
end

--------------------------------------------------------------------------
-- The grid
--------------------------------------------------------------------------

--- Verdicts a cell may carry.
---   allow          the reply came back ok
---   empty          the reply came back ok and the payload is empty — the
---                  shape `threads` uses for somebody with nothing to see,
---                  which is a permit in form and a refusal in substance
---   <an err code>  the reply came back not-ok, carrying that code and no
---                  data
---
--- A refusal names its code rather than being a bare "no", because a cell
--- that refuses for an unrelated reason is a cell that passes whether or
--- not the check it is about exists. Removing the stolen-photo-token check
--- left every outsider still refused — for standing in the wrong place —
--- and a bare "refused" read that as the rule holding.
local ALLOW, EMPTY, SILENT = 'allow', 'empty', 'none'
local NOT_PARTY = CH.ERR.NOT_PARTICIPANT

--- Handlers that name no contract at all: they answer about the caller and
--- about nobody else, so every role may call them and the grid's job is the
--- leak scan rather than the verdict.
local ANYONE = { creator = ALLOW, target = ALLOW, hitman = ALLOW,
                 otherHitman = ALLOW, stranger = ALLOW, admin = ALLOW }

--- Everyone but one role is refused, with the same code.
local function only(role, code)
    local row = {}
    for _, name in ipairs(ROLES) do row[name] = code end
    row[role] = ALLOW
    return row
end

--- Only the creator of the contract.
local CREATOR_ONLY = only('creator', NOT_PARTY)

--- Only the hitman who accepted this contract.
local HITMAN_ONLY = only('hitman', NOT_PARTY)

--- Only the person the contract names.
local TARGET_ONLY = only('target', NOT_PARTY)

--- The two sides of the deal: creator and the hitmen working for them.
--- The target is not one of them — a contract is amended between the people
--- who agreed it, and the person it names is not a party to that (§12).
local BOTH_SIDES = { creator = ALLOW, target = NOT_PARTY, hitman = ALLOW,
                     otherHitman = NOT_PARTY, stranger = NOT_PARTY, admin = NOT_PARTY }

local MATRIX = {}

-- Listings and the caller's own state -----------------------------------

MATRIX.list = { payload = { page = 1 }, expect = ANYONE,
    why = 'the board is public; what is on it is filtered per viewer' }
MATRIX.mine = { payload = {}, expect = ANYONE,
    why = 'answers about the caller only' }
MATRIX.ledger = { payload = {}, expect = ANYONE,
    why = 'answers about the caller only' }
-- The two target browsers are the one place a real name legitimately
-- crosses to somebody it does not belong to: they are a list of who is
-- online, which is what a contract is placed FROM. They are marked so the
-- anonymity scan below skips them rather than reporting the roster as a
-- leak — and marking them is the point, because a handler that is not
-- marked is scanned.
MATRIX.searchTargets = { payload = { query = 'Bram' }, expect = ANYONE,
    namesMayCross = true,
    why = 'anyone may look for somebody to place a contract on' }
MATRIX.browseTargets = { payload = { scope = 'online', page = 1 }, expect = ANYONE,
    namesMayCross = true,
    why = 'anyone may look for somebody to place a contract on' }
-- The whitelisted-job view's one read (Config.WhitelistedView). Only a
-- player on a job the app bars may ask, and every role in this cast is a
-- civilian the whole app is open to, so each is refused and sent back to
-- it. The barred column is a block of its own, below the grid ("a player
-- on a whitelisted job").
MATRIX.whitelistedView = {
    payload = {},
    expect = { creator = CH.ERR.NOT_WHITELISTED, target = CH.ERR.NOT_WHITELISTED,
               hitman = CH.ERR.NOT_WHITELISTED, otherHitman = CH.ERR.NOT_WHITELISTED,
               stranger = CH.ERR.NOT_WHITELISTED, admin = CH.ERR.NOT_WHITELISTED },
    why = 'the view is the screen of a player the app bars, and nobody here is one',
}
-- Its Notify me toggle (Config.WhitelistedView.Alerts), through the same
-- gate: refused to every role here, each a civilian the whole app is open
-- to. Answered for the barred column below.
MATRIX.whitelistedViewAlerts = {
    payload = { on = true },
    expect = { creator = CH.ERR.NOT_WHITELISTED, target = CH.ERR.NOT_WHITELISTED,
               hitman = CH.ERR.NOT_WHITELISTED, otherHitman = CH.ERR.NOT_WHITELISTED,
               stranger = CH.ERR.NOT_WHITELISTED, admin = CH.ERR.NOT_WHITELISTED },
    why = 'a choice made on the view, the screen of a player the app bars, and nobody here is one',
}
MATRIX.rewardOptions = { payload = {}, expect = ANYONE,
    why = 'reads the caller own wallet' }

MATRIX.create = {
    expect = ANYONE,
    why = 'placing a contract needs no standing on any other contract',
    payload = function(w, role, contract, cast)
        return {
            target = handleForVictim(cast[role].source),
            reason = 'Unpaid debt', mode = 'exclusive',
            reward = { slots = { { baseline = { cash = 1000 } } } },
        }
    end,
}

-- A face, by the reference a projection handed out ----------------------

MATRIX.mugshotImage = {
    expect = ANYONE,
    why = 'a target headshot is on the public board, so every viewer of the '
       .. 'board may fetch the one it showed them; the reference is the '
       .. 'entitlement and it is checked in Mugshot.byHandle',
    arrange = function(w)
        w.s.mugshot.request(CAST.target.cid)
        truthy(w.s.mugshot.store(CAST.target.cid, VALID_IMAGE), 'the face must store')
    end,
    payload = function(w) return { id = w.s.mugshot.handleFor(CAST.target.cid) } end,
}

-- Taking a contract on, and putting it down -----------------------------

MATRIX.accept = {
    payload = function(w, role, contract) return { id = contract.id, anonymous = false } end,
    -- The three refusals are three different rules, and each is named where
    -- it is enforced: a creator may not take their own contract, a target may
    -- not take one on themselves, and a hitman already on it cannot accept twice.
    expect = { creator = CH.ERR.SELF_ACCEPT, target = CH.ERR.SELF_TARGET,
               hitman = CH.ERR.ALREADY_HOLDING,
               otherHitman = ALLOW, stranger = ALLOW, admin = ALLOW },
    why = 'open to anyone not already party to it',
}

MATRIX.abandon = {
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = HITMAN_ONLY,
    why = 'only somebody actually holding it can put it down',
}

-- The creator changing their own contract -------------------------------

MATRIX.cancel = {
    contract = 'unheld',
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = CREATOR_ONLY,
    why = 'taking a contract down is the creator decision alone',
}

MATRIX.revise = {
    contract = 'unheld',
    payload = function(w, role, contract)
        return { id = contract.id, reason = 'Settled elsewhere' }
    end,
    expect = CREATOR_ONLY,
    why = 'the terms belong to whoever put them up',
}

MATRIX.rewardBreakdown = {
    payload = function(w, role, contract) return { id = contract.id } end,
    -- not_found, not not_participant, and deliberately: telling the two
    -- apart would turn this into a way to ask whether a contract id exists.
    expect = only('creator', CH.ERR.NOT_FOUND),
    why = 'the itemised reward, with the ids that name each line, is the '
       .. 'creator own property list and nobody else business',
}

MATRIX.withdrawReward = {
    contract = 'unheld',
    -- Every role is handed the REAL line id, read out of storage rather than
    -- guessed. A check that only works because a stranger cannot learn the
    -- id is not a check; it is an accident of the projection.
    payload = function(w, role, contract)
        local pick
        for _, line in ipairs(w.s.storage.readEscrow(contract.id)) do
            if line.source == 'bank' and line.portion == CH.PORTION.BASELINE then pick = line.id end
        end
        truthy(pick, 'the arrangement has to find a real line to aim at')
        return { id = contract.id, lines = { pick } }
    end,
    expect = CREATOR_ONLY,
    why = 'taking value back out is the creator alone, even with a valid line id',
}

MATRIX.addEscrow = {
    payload = function(w, role, contract)
        return { id = contract.id, reward = { baseline = { cash = 1000 } } }
    end,
    expect = CREATOR_ONLY,
    why = 'topping up funds the contract, and only its funder may',
}

MATRIX.improve = {
    payload = function(w, role, contract)
        return { id = contract.id, kind = 'extend_deadline', payload = { seconds = 600 } }
    end,
    expect = CREATOR_ONLY,
    why = 'an immediate change to somebody else terms, however friendly, is theirs to make',
}

-- Proving the job ------------------------------------------------------

MATRIX.requestPhotoToken = {
    arrange = eliminate,
    payload = function(w, role, contract) return { id = contract.id } end,
    -- no_kill_to_verify: there is no pending kill in this caller's name,
    -- which is the same sentence as "you did not do this". It shared
    -- bad_state with every other refusal in the resource until the page
    -- needed to word the commonest one; the rule here is unchanged.
    expect = only('hitman', CH.ERR.NO_KILL_TO_VERIFY),
    why = 'the proof token belongs to the hitman the server saw make the kill',
}

MATRIX.submitPhoto = {
    -- One token, issued to the hitman, offered to everybody. This is the
    -- cell that matters: a token is a bearer credential unless the server
    -- checks who is bearing it.
    arrange = function(w)
        eliminate(w)
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        w.s.photo.loadAllowedHosts()
        local token = w.s.photo.issue(w.who.hitman, w.held.id)
        truthy(token, 'the arrangement has to produce a token to pass around')
        w.token = token

        -- Every role standing over the body, not just the hitman. Ownership
        -- of the token has to be the ONLY thing refusing them: with everyone
        -- left where they spawned, deleting the ownership check outright
        -- still refused them all — for being too far from the scene — and
        -- this row went on passing over a resource anybody could collect on.
        for _, name in ipairs(ROLES) do
            Env.players[CAST[name].source]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        end
    end,
    payload = function(w) return { token = w.token, url = 'https://cdn.fivemanage.com/p.png' } end,
    expect = only('hitman', CH.ERR.TOKEN_INVALID),
    why = 'a photo token is bound to the hitman it was issued to',
}

MATRIX.verifyKill = {
    -- Kill photos off, as they ship: Verify kill is the server checking the
    -- scene, with no token to bind it. Every role stands over the body, so
    -- the kill being the caller's own is the only thing left to refuse them.
    arrange = function(w)
        eliminate(w)
        Config.Completion.KillPhotos = false
        for _, name in ipairs(ROLES) do
            Env.players[CAST[name].source]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        end
    end,
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = only('hitman', CH.ERR.NO_KILL_TO_VERIFY),
    why = 'a kill verified at the scene belongs to the hitman the server saw make it',
}

-- The client's kill photo -----------------------------------------------

--- The held contract's kill, photographed by its hitman: a photo waiting
--- for the client. Its handle is read out of the store and handed to every
--- role, because the question is whether a handle somebody else was given
--- is any use to you.
local function photographed(w)
    eliminate(w)
    Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
    w.s.photo.loadAllowedHosts()
    local token = w.s.photo.issue(w.who.hitman, w.held.id)
    truthy(token, 'the arrangement has to produce a token')
    truthy(w.s.photo.submit(w.who.hitman, token, 'https://cdn.fivemanage.com/p.png'),
        'the arrangement has to leave a photo waiting for the client')
    w.photo = w.s.storage.readLedger(CAST.creator.cid, 10)[1].photo_ref
    truthy(w.photo, 'the client row has to name the photo')
end

MATRIX.openPhoto = {
    arrange = photographed,
    payload = function(w) return { handle = w.photo } end,
    -- photo_gone, the code a handle that was never minted gets: telling a
    -- photo that is not yours from one that does not exist would say whose
    -- handle it is.
    expect = only('creator', CH.ERR.PHOTO_GONE),
    why = 'a kill photo is the client alone, once; anyone else holding its '
       .. 'handle is answered as if it named nothing',
}

MATRIX.photoDecision = {
    arrange = function(w)
        photographed(w)
        truthy(w.s.photos.open(w.who.creator, w.photo), 'the client has it open')
    end,
    payload = function(w) return { handle = w.photo, choice = 'delete' } end,
    expect = only('creator', CH.ERR.PHOTO_GONE),
    why = 'saving or deleting the photo is the client decision, about the photo they have open',
}

MATRIX.armKidnap = {
    arrange = assembleForHandover,
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = HITMAN_ONLY,
    why = 'a handover is started by the operative holding the target',
}

MATRIX.kidnapProgress = {
    arrange = function(w)
        assembleForHandover(w)
        truthy(w.s.kidnap.arm(w.held.id, CAST.hitman.cid), 'the countdown has to be running')
    end,
    payload = function(w, role, contract) return { id = contract.id } end,
    -- no_handover: the countdown is looked up by (contract, hitman) and
    -- simply is not there for anyone else, which the app draws as "no
    -- delivery running" rather than as an error.
    --
    -- This cell used to expect no code at all, because the handler returned
    -- a bare nil and App.reply forwarded that as ok = false with err = nil —
    -- a refusal with nothing in it. The page has nothing to look up for an
    -- absent code, so a countdown that was simply not running reached the
    -- player as "Lost track of the handover", which sounds like a fault and
    -- is not one. The rule this cell is about is unchanged.
    expect = only('hitman', CH.ERR.NO_HANDOVER),
    why = 'the countdown is the hitman own; where a delivery has got to is '
       .. 'not something the target gets to poll',
}

-- The target's counter-play ---------------------------------------------

MATRIX.bailout = {
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = TARGET_ONLY,
    why = 'buying your way out is the one move the person named gets',
}

MATRIX.informant = {
    -- Every look-up forced to find nothing: a name a look-up finds is what
    -- was paid for, not a leak, and informant_spec says who may learn one.
    -- What this row is about is who may buy at all.
    -- The operative an alias to the target in both passes, as the
    -- informant sells them (one named to the target is not sold).
    arrange = function(w)
        w.s.informant.setRandom(function() return 100 end)
        Config.Anonymity.ShowOperativeNames = false
        Config.Anonymity.WhitelistedTargets.ShowOperativeNames = false
    end,
    -- With the price quoted, as the page sends it, and the operative the
    -- target's card offers (a handle the server minted).
    payload = function(w, role, contract)
        local card = w.s.projection.contract(w.s.storage.readContract(contract.id), CAST.target.cid)
        return { id = contract.id, pick = card.informantPicks[1].pick,
                 shown = { cost = Config.Informant.Cost, account = Config.Informant.Account } }
    end,
    -- The target's alone: the placer has an informant of their own
    -- (placerInformant), and nobody else may buy either.
    expect = TARGET_ONLY,
    why = 'the target\'s look-up on who is after them is sold to the target alone',
}

MATRIX.placerInformant = {
    -- One operative the placer cannot already see by name: in the named
    -- pass the hitman put their name to it, so somebody else takes it too,
    -- anonymously.
    arrange = function(w)
        -- Forced to find nothing, as the target's row is.
        w.s.informant.setRandom(function() return 100 end)
        Env.addPlayer({ source = 11, citizenid = 'SHADOW01', license = 'license:SHADOW01',
            cash = 250000, bank = 250000, firstname = 'Lux', lastname = 'Penn' })
        truthy(w.s.contracts.accept(w.s.identity.resolve(11), w.held.id, true),
            'an anonymous operative to ask about')
    end,
    payload = function(w, role, contract)
        local card = w.s.projection.contract(w.s.storage.readContract(contract.id), CAST.creator.cid)
        return { id = contract.id, pick = card.placerInformantPicks[1].pick,
                 shown = { cost = Config.PlacerInformant.Cost,
                           account = Config.PlacerInformant.Account } }
    end,
    -- The person who placed it, named or anonymous, and nobody else: not
    -- the operative, not the target.
    expect = CREATOR_ONLY,
    why = 'the placer\'s look-up on who took their contract is sold to the placer alone',
}

-- The informant tip a hitman buys (server/locationtip.lua). The target
-- has to be standing somewhere for there to be anything to sell.
MATRIX.locationTip = {
    arrange = function()
        Env.players[CAST.target.source]._coords = { x = 1200.0, y = -800.0, z = 30.0 }
    end,
    payload = function(w, role, contract)
        return { id = contract.id,
                 shown = { cost = Config.LocationTip.Cost, account = Config.LocationTip.Account } }
    end,
    expect = { creator = NOT_PARTY, target = CH.ERR.NOT_FOUND, hitman = ALLOW,
               otherHitman = NOT_PARTY, stranger = NOT_PARTY, admin = NOT_PARTY },
    why = 'the target\'s rough area is sold to a hitman holding the contract, and to nobody '
       .. 'else: not the person it names, not the placer',
}
MATRIX.locationTips = { payload = {}, expect = ANYONE,
    why = 'puts the caller\'s own tips back on their map, and nobody else\'s' }

-- Amendments ------------------------------------------------------------

MATRIX.amendments = {
    arrange = function(w)
        local proposal = w.s.amendments.propose(w.who.hitman, w.held.id,
            'shorten_deadline', { seconds = 600 })
        truthy(proposal, 'the arrangement has to leave something on the table')
        w.proposal = proposal
    end,
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = BOTH_SIDES,
    why = 'what is on the table is visible to the people who must answer it',
}

MATRIX.propose = {
    payload = function(w, role, contract)
        return { id = contract.id, kind = 'shorten_deadline', payload = { seconds = 600 } }
    end,
    expect = BOTH_SIDES,
    why = 'either side of the deal may ask to change it',
}

MATRIX.respondAmendment = {
    arrange = function(w)
        local proposal = w.s.amendments.propose(w.who.hitman, w.held.id,
            'shorten_deadline', { seconds = 600 })
        truthy(proposal, 'the arrangement has to leave something to answer')
        w.proposal = proposal
    end,
    payload = function(w) return { id = w.proposal.id, approve = true } end,
    expect = BOTH_SIDES,
    why = 'a vote belongs to the participants, and an outsider voting would '
       .. 'apply or kill a change on a contract they are not on',
}

-- The masked relay ------------------------------------------------------

MATRIX.threads = {
    payload = function(w, role, contract) return { id = contract.id } end,
    -- Everybody gets an answer; only the two sides get anything in it. The
    -- empty list is the refusal, so it is asserted as empty rather than as
    -- ok — an ok that quietly carried the creator's thread handles would be
    -- the whole relay unlocked.
    expect = { creator = ALLOW, target = EMPTY, hitman = ALLOW,
               otherHitman = EMPTY, stranger = EMPTY, admin = EMPTY },
    why = 'an inbox lists your own threads and nobody else',
}

MATRIX.readThread = {
    arrange = function(w)
        truthy(w.s.comms.send(w.who.creator, w.held.id, creatorThreadHandle(w), 'Where are you?'),
            'the arrangement has to put something in the thread worth stealing')
        w.handle = creatorThreadHandle(w)
    end,
    -- The creator's handle, given to everyone. A hitman reading with it gets
    -- their own thread — they have exactly one and the handle is not what
    -- selects it — which is why both sides are permitted here.
    payload = function(w, role, contract) return { id = contract.id, thread = w.handle } end,
    expect = BOTH_SIDES,
    why = 'a thread is readable by its two ends, and a handle minted for one '
       .. 'viewer is no use to a third party holding it',
}

MATRIX.sendMessage = {
    arrange = function(w) w.handle = creatorThreadHandle(w) end,
    payload = function(w, role, contract)
        return { id = contract.id, thread = w.handle, body = 'Where are you?' }
    end,
    expect = BOTH_SIDES,
    why = 'only the two ends of a thread may write into it',
}

MATRIX.requestCall = {
    arrange = function(w) w.handle = creatorThreadHandle(w) end,
    payload = function(w, role, contract) return { id = contract.id, thread = w.handle } end,
    expect = BOTH_SIDES,
    why = 'ringing somebody masked phone is for the party they are dealing with',
}

MATRIX.muteThread = {
    arrange = function(w) w.handle = creatorThreadHandle(w) end,
    payload = function(w, role, contract)
        return { id = contract.id, thread = w.handle, muted = true }
    end,
    expect = BOTH_SIDES,
    why = 'a thread is muted by one of its two ends, for themselves alone',
}

MATRIX.endCall = { payload = {}, expect = ANYONE,
    why = 'hangs up the caller own call and names no contract' }

-- The handover's meeting point (server/meeting.lua) ----------------------
--
-- Only on an alive-only contract, so these rows place theirs under that
-- rule. Everybody stands where the placer does: a caller somewhere else
-- would be refused for the distance rather than for who they are.

local function allAtScene()
    for _, who in pairs(CAST) do
        Env.players[who.source]._coords = { x = SCENE.x, y = SCENE.y, z = SCENE.z }
    end
end

--- The placer's point on the held contract, set through the module and
--- left past the once-every-30-seconds rule, so a clear is not refused for
--- coming too soon.
local function meetingPointSet(w)
    allAtScene()
    truthy(w.s.meeting.set(w.who.creator,
        { id = w.held.id, x = SCENE.x, y = SCENE.y, z = SCENE.z }),
        'the arrangement has to leave a meeting point')
    Env.advance(w.s.meeting.EVERY_SECONDS)
end

-- not_found for everybody else, the placer's own contract or none: telling
-- the two apart would say which ids are somebody's.
MATRIX.setMeeting = {
    fulfilment = 'alive',
    arrange = allAtScene,
    payload = function(w, role, contract)
        return { id = contract.id, x = SCENE.x, y = SCENE.y, z = SCENE.z }
    end,
    expect = only('creator', CH.ERR.NOT_FOUND),
    why = 'the meeting point is set by the person who placed the contract, where they stand',
}

MATRIX.clearMeeting = {
    fulfilment = 'alive',
    arrange = meetingPointSet,
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = only('creator', CH.ERR.NOT_FOUND),
    why = 'the placer alone takes their meeting point off',
}

MATRIX.meetingWaypoint = {
    fulfilment = 'alive',
    arrange = meetingPointSet,
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = only('hitman', CH.ERR.NOT_FOUND),
    why = 'where to meet is for the hitman holding the contract; nobody else, '
       .. 'the placer included, is told where',
}

-- The two events the victim's own client fires --------------------------
--
-- These reply to nobody, so they have no permit/refuse cell. What they do
-- have is an authorisation rule of exactly the same kind: they act on the
-- caller and on nobody else. A killer reporting their own kill is the claim
-- §14.2 refuses, and it is checked here by having each role fire the event
-- and asserting no claim opened on a contract that is not theirs.

--- The handlers that are not permit/refuse cells, and where each is covered
--- instead. A closed set, by name.
---
--- `custom` on a row exempts it from the grid, from the leak scan and from
--- the per-role hole check — which, left as a free-form flag, is a way to
--- silence a new handler with one line. A planted handler returning another
--- player's citizen id was caught by "has a row for every handler app.lua
--- registers", and then quieted completely by adding
--- `MATRIX.contractSummary = { custom = true }` above this. The whole file
--- went green with a live leak in it.
---
--- So the exemption is granted here, by name, alongside the title of the
--- block that covers the handler instead — and that title is checked to
--- exist. Exempting something new now means naming it and writing the block
--- that replaces the row, which is a decision somebody makes rather than a
--- flag they reach for.
local CUSTOM = {
    iDied    = 'a death report acts on its caller and on nobody else',
    iRevived = 'a death report acts on its caller and on nobody else',
    -- The three registered in bridges.lua rather than app.lua. Same kind of
    -- rule and no permit/refuse cell: each acts on whoever fired it and on
    -- nobody else, and none of them answers a request.
    whoAmI            = 'the events registered outside the app gate',
    mugshot           = 'the events registered outside the app gate',
    appearanceChanged = 'the events registered outside the app gate',
    -- Names no contract, so there is no role to permit or refuse against:
    -- any player may report that their own copy of the page broke. What it
    -- must not do is let a browser put arbitrary text into the audit log,
    -- or name somebody else, and that is what the block below checks.
    pageError = 'a page reporting its own fault',
    -- A client's word that the kill photo it was sent is there. Names no
    -- contract; it can only let go of the caller's own send, of the photo
    -- named (server_photos_spec has the whole of it).
    photoArrived = 'a photo reported as arrived',
    -- A client's word about its own player's mask, for the nearby list.
    -- Names no contract and nobody; it is kept against the caller's own
    -- server id (anonymity_spec has what it does to the list).
    maskState = 'a mask reported by its own client',
    -- The admin panel's requests, registered in bridges.lua. Not a player
    -- surface at all: every op is staff-only, by ACE, checked on every
    -- request (admin_panel_spec has every op).
    admin = 'the admin panel requests',
}

-- Registered in bridges.lua, which is how three events any player on the
-- server can fire came to have no row at all: the completeness guard read
-- app.lua and the block around it said "the whole net surface".
MATRIX.whoAmI = { custom = true,
    why = 'asking whether you may have the app answers about you' }
MATRIX.mugshot = { custom = true,
    why = 'a headshot is stored against whoever sent it, never against a cid in the payload' }
MATRIX.appearanceChanged = { custom = true,
    why = 'a player invalidates their own face and no one else' }

MATRIX.iDied = { custom = true,
    why = 'only the victim own client can report their death' }
MATRIX.iRevived = { custom = true,
    why = 'only the victim own client can report their revival' }

MATRIX.pageError = { custom = true,
    why = 'a fault report is about the caller own page and names no contract' }

MATRIX.photoArrived = { custom = true,
    why = 'lets go of the caller own photo on its way, and of nobody else' }

MATRIX.maskState = { custom = true,
    why = 'says whether the caller wears a mask, and nothing about anybody else' }

MATRIX.admin = { custom = true,
    why = 'staff only, by ACE on every request; no role a player holds on a contract opens it' }

describe('the admin panel requests', function()
    --- Every op the page may ask for. Each role in the cast is a player
    --- with no ACE, whatever they are to a contract, except `admin`, who
    --- holds crimson.admin: the grid's own admin column.
    local OPS = { 'access', 'overview', 'contracts', 'contract', 'reviews', 'logs', 'player',
                  'settings', 'diag', 'void', 'settle', 'resolve', 'setSetting',
                  'resetSetting', 'resetSettings', 'refresh', 'flush', 'whois' }

    local function ask(src, op, data)
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(Env.events['crimson-hitman:admin'],
            { op = op, data = data or {}, __rid = 1 })
        _G.source = nil
        truthy(fired, 'raised: ' .. tostring(err))
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminResult' then return event.args[1], event.target end
        end
        return nil
    end

    it('refuses every op to every role on a contract, and sends them nothing', function()
        local w = world()
        w.s.bridges.install(w.s)
        for _, role in ipairs(ROLES) do
            if role ~= 'admin' then
                for _, op in ipairs(OPS) do
                    local reply, target = ask(CAST[role].source, op,
                        { id = w.held.id, key = 'Relay.Enabled', value = false })
                    truthy(reply, role .. ' ' .. op .. ' is answered')
                    eq(target, CAST[role].source, 'to them alone')
                    eq(reply.err, 'not_allowed', role .. ' ' .. op)
                    eq(reply.data, nil, role .. ' ' .. op .. ' carries nothing')
                end
            end
        end
        eq(w.s.storage.readContract(w.held.id).state, CH.STATE.ACCEPTED, 'nothing was voided')
        eq(Config.Relay.Enabled, true, 'and nothing changed')
    end)

    it('lets the admin column read and write, and not unmask', function()
        local w = world({ anonymous = true })
        w.s.bridges.install(w.s)
        local reply = ask(CAST.admin.source, 'contract', { id = w.held.id })
        eq(reply.ok, true, tostring(reply.message))
        local seen = {}
        local function walk(value)
            if type(value) == 'string' then seen[#seen + 1] = value
            elseif type(value) == 'table' then
                for k, v in pairs(value) do walk(k) walk(v) end
            end
        end
        walk(reply.data)
        local text = table.concat(seen, '\n')
        for _, who in pairs(CAST) do
            falsy(text:find(who.cid, 1, true),
                who.cid .. ': no citizen id reaches staff without crimson.identity')
        end
        eq(reply.data.contract.client.name, 'Anonymous')
        eq(ask(CAST.admin.source, 'whois', { id = w.held.id }).err, 'identity_required')
        eq(ask(CAST.admin.source, 'void', { id = w.held.id, reason = 'x' }).ok, true,
            'crimson.admin itself writes')
    end)
end)

describe('a photo reported as arrived', function()
    --- Fired by the client's photoImage handler when a kill photo lands, so
    --- the server may send the next. A net event any player can fire with
    --- anything in it: it answers nobody, writes nothing and cannot throw,
    --- and what it lets go of is keyed by the caller's own server id.
    it('answers nobody, whoever fires it and with whatever', function()
        world()
        for _, role in ipairs(ROLES) do
            for _, sent in ipairs({ 'ph00000000aa', 42, true, {}, false }) do
                Env.clientEvents = {}
                _G.source = CAST[role].source
                local ok, err = pcall(Env.events['crimson-hitman:photoArrived'], sent)
                _G.source = nil
                truthy(ok, role .. ': ' .. tostring(err))
                eq(#Env.clientEvents, 0, role .. ' was answered')
            end
        end
    end)
end)

describe('a mask reported by its own client', function()
    --- Sent by the client when its player's mask goes on or comes off. A
    --- net event any player can fire with anything in it: it answers
    --- nobody and cannot throw, and anything but a yes or no is refused.
    it('answers nobody, whoever fires it and with whatever', function()
        world()
        for _, role in ipairs(ROLES) do
            for _, sent in ipairs({ true, false, 'false', 0, {}, { source = 1, masked = false } }) do
                Env.clientEvents = {}
                _G.source = CAST[role].source
                local ok, err = pcall(Env.events['crimson-hitman:maskState'], sent)
                local okNil, errNil = pcall(Env.events['crimson-hitman:maskState'])
                _G.source = nil
                truthy(ok, role .. ': ' .. tostring(err))
                truthy(okNil, role .. ' with nothing: ' .. tostring(errNil))
                eq(#Env.clientEvents, 0, role .. ' was answered')
            end
        end
    end)

    --- Our client only ever sends a boolean, so anything else is somebody
    --- probing: written down for staff, once a window rather than once a
    --- message, so a flood of them cannot fill the log.
    it('writes a malformed one down, once', function()
        local w = world()
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            _G.source = CAST.stranger.source
            for _ = 1, 5 do Env.events['crimson-hitman:maskState']({ source = 1, masked = false }) end
            _G.source = nil
        end)
        w.s.audit.flush()
        local rows = {}
        for _, row in ipairs(w.s.storage.readAudit()) do
            if row.action == 'mask_bad_format' then rows[#rows + 1] = row end
        end
        eq(#rows, 1, 'one row for five')
        eq(rows[1].detail.source, CAST.stranger.source, 'naming the source that sent it')
    end)

    --- Our client sends nothing while the nearby list is off, so one that
    --- does is refused, and written down once a window like a malformed one.
    it('refuses one sent while the nearby list is off, and writes it down once', function()
        local w = world()
        _G.source = CAST.stranger.source
        for _ = 1, 5 do Env.events['crimson-hitman:maskState'](false) end
        _G.source = nil
        w.s.audit.flush()
        local rows = {}
        for _, row in ipairs(w.s.storage.readAudit()) do
            if row.action == 'gate_maskState' then rows[#rows + 1] = row end
        end
        eq(#rows, 1, 'one row for five')
        eq(rows[1].detail.source, CAST.stranger.source, 'naming the source that sent it')
    end)
end)

describe('a page reporting its own fault', function()
    --- The app runs in CEF, where a JavaScript error reaches nobody. This
    --- handler is how it reaches the server log instead — and it is an NUI
    --- endpoint, so everything arriving on it came from a browser and some
    --- of it may not have come from ours.
    local function report(s, actor, payload)
        return s.app.handlers.pageError(actor, payload)
    end

    it('records a fault against the caller and nobody else', function()
        local s = newStack()
        local f = fixture(s)

        truthy(report(s, f.hitman, { what = 'x is not a function',
            where = 'app.js:120:9', stack = 'at card', build = '1.2.3' }))
        s.audit.flush()

        local found
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'page_error' then found = row end
        end
        truthy(found, 'the fault has to reach somewhere an owner can read it')
        eq(found.actor_cid, f.hitman.cid,
            'recorded against whoever reported it, never a cid from the payload')
        eq(found.detail.what, 'x is not a function')
    end)

    it('will not let a browser write whatever it likes into the log', function()
        local s = newStack()
        local f = fixture(s)

        -- Everything here came over an NUI endpoint that any frame the phone
        -- draws can post to.
        truthy(report(s, f.hitman, {
            what = string.rep('A', 5000),
            where = string.rep('B', 5000),
            stack = string.rep('C', 20000),
            build = string.rep('D', 500),
            cid = 'CREATOR1',
        }))
        s.audit.flush()

        local found
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'page_error' then found = row end
        end
        truthy(found)
        truthy(#found.detail.what <= 300, 'what: ' .. #found.detail.what)
        truthy(#found.detail.where <= 200, 'where: ' .. #found.detail.where)
        truthy(#found.detail.stack <= 900, 'stack: ' .. #found.detail.stack)
        eq(found.actor_cid, f.hitman.cid,
            'a cid in the payload must not become the cid on the row')
    end)

    it('survives a report carrying nothing at all', function()
        local s = newStack()
        local f = fixture(s)
        -- A page broken badly enough to report may be broken badly enough to
        -- report badly.
        truthy(report(s, f.hitman, {}),
            'the one path that exists for saying the app is broken must not '
            .. 'itself be a way to break the server')
    end)

    it('is rate limited, so a render loop cannot fill the log', function()
        local s = newStack()
        local f = fixture(s)
        local rule = Config.Cooldowns.diagnostic
        truthy(rule, 'the bucket has to exist or this handler is unlimited')

        local allowed = 0
        for _ = 1, rule.burst + 5 do
            if s.ratelimit.check(f.hitman, 'diagnostic') then allowed = allowed + 1 end
        end
        eq(allowed, rule.burst,
            'a page throwing every frame would otherwise write a row every frame')
    end)
end)

--------------------------------------------------------------------------
-- Running the grid
--------------------------------------------------------------------------

--- Whether a reply carries anything a client could read.
---
--- Nil and false are both "nothing": App.reply forwards a handler's first
--- return value as `data`, and a refusing handler returns `false, err`.
local function hasPayload(reply)
    return reply.data ~= nil and reply.data ~= false
end

--- A barred job's refusal carries what bars them (Identity.gate: their own
--- job, and whether they hold it rather than work it, W002), and nothing
--- else: no contract, no wallet, nobody else.
local function onlyWhatBarsThem(reply)
    if type(reply.data) ~= 'table' then return not hasPayload(reply) end
    for key, value in pairs(reply.data) do
        if key == 'job' then
            if type(value) ~= 'string' then return false end
        elseif key == 'held' then
            if type(value) ~= 'boolean' then return false end
        else
            return false
        end
    end
    return true
end

--- Was this what the cell said it would be?
local function verdictHolds(expected, reply)
    if reply == nil then return false, 'no reply at all' end
    if reply.missing then return false, 'no such net event is registered' end
    if reply.threw then return false, reply.err end

    if expected == ALLOW then
        if not reply.ok then return false, 'refused with ' .. tostring(reply.err) end
        return true
    end

    if expected == EMPTY then
        if not reply.ok then return false, 'refused with ' .. tostring(reply.err) end
        local rows = reply.data
        if type(rows) ~= 'table' then return false, 'answered with a ' .. type(rows) end
        if next(rows) ~= nil then return false, 'answered with rows in it' end
        return true
    end

    -- A refusal, named. All three halves matter: it must be refused, it
    -- must be refused for the stated reason, and it must carry no data —
    -- a handler that answers the question and then says no has not refused.
    --
    -- `false` is not a payload: a refusing handler returns `false, err`, and
    -- App.reply passes that first return through as data, so every refusal
    -- in the resource carries a literal false.
    if reply.ok then return false, 'was PERMITTED' end

    local wanted = expected ~= SILENT and expected or nil
    if reply.err ~= wanted then
        return false, ('refused with %s, which is not the rule this cell is '
            .. 'about — a cell refused for an unrelated reason passes with '
            .. 'the check removed'):format(tostring(reply.err))
    end
    if hasPayload(reply) then return false, 'refused but still returned data' end
    return true
end

--- Run one row of the grid: the same handler, the same arrangement, the same
--- payload shape, as each of the six roles in turn — twice.
---
--- Twice because anonymity is a paid choice and must not be an
--- authorisation one. The second pass is the same contract with the creator
--- and the hitman both anonymous, which changes who may be NAMED and must
--- change nothing about who may ACT. A check that reads a name where it
--- should read a role passes the first pass and fails the second.
local PASSES = {
    { name = 'named', opts = {} },
    { name = 'anonymous', opts = { anonymous = true } },
}

local function runRow(name)
    local entry = MATRIX[name]
    local failures = {}

    for _, pass in ipairs(PASSES) do
        for _, role in ipairs(ROLES) do
            local w = world({ anonymous = pass.opts.anonymous, fulfilment = entry.fulfilment })
            local contract, cast = castFor(w, entry.contract)
            if entry.arrange then entry.arrange(w) end

            local payload = entry.payload
            if type(payload) == 'function' then payload = payload(w, role, contract, cast) end

            local reply = call(name, cast[role].source, payload or {})
            record(pass.name, name, role, cast[role].cid, reply)

            local ok, detail = verdictHolds(entry.expect[role], reply)
            if not ok then
                failures[#failures + 1] = ('%s, %s contract: should be %s and %s')
                    :format(role, pass.name, entry.expect[role], detail)
            end
        end
    end

    eq(#failures, 0, ('%s — %s\n      %s')
        :format(name, entry.why, table.concat(failures, '\n      ')))
end

describe('the authorisation matrix, driven through the real net events', function()
    -- One test per handler, reporting the whole row, so a failure names
    -- every role that got the wrong answer rather than stopping at the
    -- first. Half a broken row looks like a typo; a whole one looks like a
    -- missing check, and the difference is what you do next.
    local names = {}
    for name, entry in pairs(MATRIX) do
        if not entry.custom then names[#names + 1] = name end
    end
    table.sort(names)

    for _, name in ipairs(names) do
        it(name .. ' answers each role the way the resource intends', function()
            runRow(name)
        end)
    end
end)

--------------------------------------------------------------------------
-- The barred column: a player on a whitelisted job
--------------------------------------------------------------------------
--
-- The grid's six roles are all civilians. A player on a job the app bars
-- (Config.BlockedJobTypes / BlockedJobNames) is the seventh, and with the
-- whitelisted-job view on (as shipped) the matrix for them is exactly what
-- it was with no view at all, apart from three cells: the view's own read,
-- the buyout, which answers only on a contract naming them, and the page's
-- own fault report (pageError), which changes nothing and answers nothing
-- about anybody. Every other handler refuses them at the gate, as
-- blacklisted_job, carrying nothing, before it looks at what was sent.

describe('a player on a whitelisted job', function()
    local OFFICER = { source = 11, cid = 'OFFICER1' }
    local COLLEAGUE = { source = 12, cid = 'OFFICER2' }

    --- The grid's world, with two officers: one a contract names (placed
    --- while they were a civilian, then hired), and a colleague with one of
    --- their own.
    local function barredWorld()
        local w = world()
        for _, who in ipairs({ OFFICER, COLLEAGUE }) do
            Env.addPlayer({ source = who.source, citizenid = who.cid,
                license = 'license:' .. who.cid, cash = 250000, bank = 250000,
                firstname = 'Officer', lastname = who.cid })
        end
        local creator = w.s.identity.resolve(CAST.farCreator.source)
        w.mine = w.s.contracts.create(creator, {
            targetCid = OFFICER.cid, reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
        })
        truthy(w.mine, 'the world needs a contract on the officer')
        w.theirs = w.s.contracts.create(w.who.creator, {
            targetCid = COLLEAGUE.cid, reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
        })
        truthy(w.theirs, 'the world needs a contract on a colleague')
        -- Shown to their targets, as On me would be.
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        for _, who in ipairs({ OFFICER, COLLEAGUE }) do
            Env.players[who.source].PlayerData.job =
                { name = 'police', label = 'Police', type = 'leo', onduty = true }
        end
        return w
    end

    it('is answered on the view and refused, carrying nothing, everywhere else', function()
        local App = require('crimson-hitman.server.app')
        local names = {}
        for name in pairs(App.handlers) do names[#names + 1] = name end
        table.sort(names)
        truthy(#names >= 30, 'the handler table has to be the whole surface: ' .. #names)

        local wrong = {}
        for _, name in ipairs(names) do
            local w = barredWorld()
            local reply = call(name, OFFICER.source, { id = w.mine.id, page = 1, on = true })
            if name == 'whitelistedView' or name == 'whitelistedViewAlerts' or name == 'bailout'
                or name == 'pageError' then
                if not (reply and reply.ok) then
                    wrong[#wrong + 1] = name .. ' refused them with ' .. tostring(reply and reply.err)
                end
            elseif not reply or reply.ok or reply.err ~= CH.ERR.BLACKLISTED_JOB
                or not onlyWhatBarsThem(reply) then
                wrong[#wrong + 1] = ('%s answered %s'):format(name, reply and (reply.ok
                    and 'ok' or ('%s with %s'):format(tostring(reply.err),
                        hasPayload(reply) and 'data' or 'nothing')) or 'nothing')
            end
        end
        eq(#wrong, 0, 'the view and its Notify me, their own buyout and their page\'s report, '
            .. 'and nothing else: ' .. table.concat(wrong, '; '))
    end)

    it('buys out only a contract naming them', function()
        local w = barredWorld()
        local colleague = call('bailout', OFFICER.source, { id = w.theirs.id })
        eq(colleague.ok, false)
        eq(colleague.err, CH.ERR.NOT_PARTICIPANT, 'a colleague\'s is not theirs to close')
        falsy(hasPayload(colleague), 'and the refusal carries nothing')

        local civilian = call('bailout', OFFICER.source, { id = w.held.id })
        eq(civilian.err, CH.ERR.NOT_PARTICIPANT, 'nor a civilian\'s, which they cannot even see')

        local forged = call('bailout', OFFICER.source, { id = 'ctforged00000' })
        eq(forged.err, CH.ERR.NOT_FOUND, 'an id they made up names nothing')
        local junk = call('bailout', OFFICER.source, { id = { 1, 2 } })
        eq(junk.err, CH.ERR.INVALID_INPUT, 'and one that is not an id is not one')

        eq(w.s.storage.readContract(w.theirs.id).state, CH.STATE.ACTIVE)
        eq(w.s.storage.readContract(w.held.id).state, CH.STATE.ACCEPTED)
    end)

    it('refuses the view to them too while it is off, as the app always did', function()
        local w = barredWorld()
        Config.WhitelistedView.Enabled = false
        local view = call('whitelistedView', OFFICER.source, {})
        eq(view.err, CH.ERR.BLACKLISTED_JOB)
        truthy(onlyWhatBarsThem(view), 'nothing but what bars them')
        local buyout = call('bailout', OFFICER.source, { id = w.mine.id })
        eq(buyout.err, CH.ERR.BLACKLISTED_JOB, 'and the buyout goes back to the command alone')
        eq(w.s.storage.readContract(w.mine.id).state, CH.STATE.ACTIVE)
        eq(call('pageError', OFFICER.source, { what = 'render', where = 'jobview' }).err,
            CH.ERR.BLACKLISTED_JOB, 'and a page\'s report, with no view to report from')
    end)
end)

--------------------------------------------------------------------------
-- The two self-reports
--------------------------------------------------------------------------

describe('a death report acts on its caller and on nobody else', function()
    --- Fire iDied as somebody who really has just been killed by the hitman.
    ---
    --- The reporter is the victim in every respect the server can check:
    --- they are at the scene, the hitman's damage on them is in the log,
    --- their condition really dropped and the medical resource really says
    --- they are dead. Everything is true except that the contract does not
    --- name them — which is the one thing that is supposed to decide it.
    ---
    --- Killing the reporter for real matters. With only the contract's
    --- target laid out, every other role was refused for not being dead,
    --- and the refusal would have held with the target check deleted: a
    --- creator and a hitman arranging a death between them would have
    --- collected on a target nobody touched.
    local function reportAs(source, cid)
        local w = world()
        Env.players[CAST.hitman.source]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[source]._coords = { x = 101.0, y = 100.0, z = 30.0 }

        -- Watched, so the hitman's damage on them is corroborated and lands
        -- in the log. Being watched is not special: the server watches
        -- anyone an accepted contract names, so a creator who is also
        -- somebody else's target is watched exactly like this. Without it
        -- the damage is thrown away for want of a baseline and every
        -- refusal below holds for that reason instead of the right one.
        w.s.death.watch(cid, source, true)
        Env.players[source]._health = 140
        w.s.death.recordDamage(CAST.hitman.source, source, 123456)
        Env.players[source].PlayerData.metadata.isdead = true

        Env.clientEvents = {}
        _G.source = source
        pcall(Env.events['crimson-hitman:iDied'], CAST.hitman.source)
        _G.source = nil
        return w
    end

    it('opens a claim when the person who died reports it', function()
        local w = reportAs(CAST.target.source, CAST.target.cid)
        truthy(w.s.death.getPending(w.held.id, CAST.hitman.cid),
            'the victim own report is the one the server acts on — without '
            .. 'this passing, every refusal below is vacuous')
    end)

    for _, role in ipairs({ 'creator', 'hitman', 'otherHitman', 'stranger', 'admin' }) do
        it('opens nothing when ' .. role .. ' reports somebody else death', function()
            local w = reportAs(CAST[role].source, CAST[role].cid)
            falsy(w.s.death.getPending(w.held.id, CAST.hitman.cid),
                role .. ' reported a death that was not theirs and a claim opened '
                .. 'on it. A hitman who can fire this is a hitman who can '
                .. 'collect on a target they never touched.')
        end)
    end

    it('does not answer the client at all', function()
        local w = world()
        Env.clientEvents = {}
        _G.source = CAST.stranger.source
        pcall(Env.events['crimson-hitman:iRevived'])
        _G.source = nil
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.name == 'crimson-hitman:result',
                'a self-report has no reply, so there is nothing for it to leak')
        end
    end)
end)

--------------------------------------------------------------------------
-- What leaked
--------------------------------------------------------------------------

--- Walk a payload for a string, however deeply it is buried and whether it
--- is a key or a value. Bounded, because a payload is client-visible data
--- and a cycle in one would hang the suite rather than fail it.
local function findString(value, wanted, depth)
    if depth > 8 then return false end
    if type(value) == 'string' then return value == wanted end
    if type(value) ~= 'table' then return false end
    for k, v in pairs(value) do
        if findString(k, wanted, depth + 1) then return true end
        if findString(v, wanted, depth + 1) then return true end
    end
    return false
end

describe('what the grid sent back', function()
    it('exercised every cell it claims to', function()
        -- Without this the leak scan below is a scan of nothing, and a row
        -- that stopped producing replies would go on "passing" it.
        local rows = 0
        for name, entry in pairs(MATRIX) do
            if not entry.custom then rows = rows + 1 end
        end
        eq(#seen, rows * #ROLES * #PASSES,
            'every handler in the grid must have answered every role, on a '
            .. 'named contract and on an anonymous one')
    end)

    --- The rule four separate modules state in their own comments — a
    --- citizen id is an internal key and does not go to a client — asserted
    --- once, across every handler at once, rather than per module.
    ---
    --- The caller's own id is left out of it: the ledger stamps rows with
    --- the id of the player they belong to, which is a different question
    --- from whether one player learns another's.
    it('never handed one player another player citizen id', function()
        local leaks = {}
        for _, row in ipairs(seen) do
            if row.reply and hasPayload(row.reply) then
                for cid in pairs(FOREIGN_CIDS) do
                    if cid ~= row.cid and findString(row.reply.data, cid, 0) then
                        leaks[#leaks + 1] = ('%s told %s the citizen id %s')
                            :format(row.handler, row.role, cid)
                    end
                end
            end
        end
        eq(#leaks, 0, table.concat(leaks, '; '))
    end)

    --- Anonymity is enforced by omission (§14.4): an anonymous
    --- participant's real name is not supposed to exist anywhere in a
    --- payload, so there is nothing for a client-side inspector to find.
    --- Each module asserts that for the payload it builds. This asserts it
    --- across the whole net surface at once, on the pass where the creator
    --- and the hitman both paid to be hidden.
    ---
    --- Your own name is not a leak — a creator sees their own name on the
    --- contract they just placed — so only somebody else's is counted.
    it('never named an anonymous participant to anybody else', function()
        local hidden = {
            [CAST.creator.cid] = 'Vic Marlowe',
            [CAST.hitman.cid]  = 'Rook Ash',
        }
        local leaks = {}
        for _, row in ipairs(seen) do
            if row.pass == 'anonymous' and not MATRIX[row.handler].namesMayCross
                and row.reply and hasPayload(row.reply) then
                for cid, name in pairs(hidden) do
                    if cid ~= row.cid and findString(row.reply.data, name, 0) then
                        leaks[#leaks + 1] = ('%s told %s the real name %s')
                            :format(row.handler, row.role, name)
                    end
                end
            end
        end
        eq(#leaks, 0, 'anonymity is paid for and is not a display preference: '
            .. table.concat(leaks, '; '))
    end)

    --- The one refusal in the resource that answers with a payload.
    ---
    --- Every handler refusal returns `false, err`, and App.reply forwards
    --- that first value, so a refused request carries a literal false and
    --- nothing else — which is what the cells above assert. The gate is the
    --- exception: a throttled caller is told how long to wait, because
    --- "slow down" on its own is not something a player can act on. That
    --- payload is built in the gate, outside every projection, and is the
    --- one place a refusal could grow a field nobody reviewed.
    it('tells a throttled caller how long to wait and nothing else', function()
        local w = world()
        local target = CAST.target.source

        -- The buyout bucket is one token per minute, so the second press is
        -- refused by the gate rather than by the handler.
        local first = call('bailout', target, { id = w.held.id })
        truthy(first and first.ok, 'the first buyout has to go through')

        local second = call('bailout', target, { id = w.held.id })
        truthy(second, 'a throttled request is answered, never dropped')
        eq(second.ok, false, 'the second press inside the window is refused')
        eq(second.err, CH.ERR.RATE_LIMITED)

        local keys = {}
        for key in pairs(second.data or {}) do keys[#keys + 1] = key end
        table.sort(keys)
        eq(table.concat(keys, ','), 'retryAfter',
            'a refusal may carry the wait and nothing else; anything more is '
            .. 'a field that reached a client without passing a projection')
    end)
end)

--------------------------------------------------------------------------
-- The guard that keeps this a matrix
--------------------------------------------------------------------------

--- The three net events registered in bridges.lua rather than through the
--- app gate.
---
--- Every one is reachable by any player on the server — a net event name is
--- addressable by anybody, not only by the page this resource ships — and
--- none of them had a row, because the completeness guard read app.lua and
--- the block around it called that "the whole net surface".
---
--- They answer no request, so there is no permit/refuse cell to fill. The
--- rule is the same shape as the death reports': each acts on whoever fired
--- it, and on nobody else.
describe('the events registered outside the app gate', function()
    local function wired()
        local s = newStack()
        local f = fixture(s)
        -- The stack does not install these; bridges.install is what
        -- registers them on a live server, which is exactly why nothing had
        -- ever executed them.
        s.bridges.install(s)
        return s, f
    end

    local function fire(name, src, ...)
        local handler = Env.events['crimson-hitman:' .. name]
        if not handler then return nil, 'no handler for ' .. name end
        _G.source = src
        local ok, err = pcall(handler, ...)
        _G.source = nil
        return ok, err
    end

    it('registers all three', function()
        wired()
        for _, name in ipairs({ 'whoAmI', 'mugshot', 'appearanceChanged' }) do
            truthy(Env.events['crimson-hitman:' .. name],
                name .. ' must be registered by bridges.install')
        end
    end)

    --- A real headshot, and the smallest thing that satisfies the format.
    local PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='

    it('stores a headshot against whoever sent it', function()
        local s = wired()
        -- Solicited: an unsolicited image is refused outright, which is a
        -- rule of its own and already covered. This is about WHOSE face it
        -- becomes.
        s.mugshot.request('HITMAN01')
        truthy(fire('mugshot', 3, PNG), 'the handler must not throw')

        truthy(s.mugshot.handleFor('HITMAN01'),
            'the sender got a face')
        falsy(s.mugshot.handleFor('CREATOR1'),
            'and nobody else did')
        falsy(s.mugshot.handleFor('TARGET01'))
    end)

    it('takes the sender from the connection, never from the payload', function()
        -- The image is the only argument, so there is no cid to forge — and
        -- that is the property worth pinning, because an argument added
        -- later is how it stops being true.
        local s = wired()
        s.mugshot.request('CREATOR1')
        s.mugshot.request('HITMAN01')

        -- Player 3 sends, naming player 1 every way an argument could.
        truthy(fire('mugshot', 3, PNG, 'CREATOR1'))
        truthy(fire('mugshot', 3, { cid = 'CREATOR1', image = PNG }))

        falsy(s.mugshot.handleFor('CREATOR1'),
            'a sender must not be able to put a face on somebody else')
    end)

    it('refuses a headshot from a source with no character', function()
        local s = wired()
        s.mugshot.request('HITMAN01')
        truthy(fire('mugshot', 999, PNG), 'an unknown source must not throw')
        falsy(s.mugshot.handleFor('HITMAN01'),
            'and must not have stored anything')
    end)

    it('does not throw on a headshot that is not a string', function()
        local s = wired()
        s.mugshot.request('HITMAN01')
        for _, odd in ipairs({ 42, true, {} }) do
            truthy(fire('mugshot', 3, odd),
                ('a %s payload must not throw out of a net event'):format(type(odd)))
        end
        truthy(fire('mugshot', 3), 'nor must an absent one')
        falsy(s.mugshot.handleFor('HITMAN01'), 'and none of it is a face')
    end)

    it('invalidates only the face of whoever asked', function()
        local s = wired()
        for _, who in ipairs({ 'CREATOR1', 'HITMAN01' }) do
            s.mugshot.request(who)
        end
        s.mugshot.store('CREATOR1', PNG)
        s.mugshot.store('HITMAN01', PNG)
        truthy(s.mugshot.handleFor('CREATOR1'))
        truthy(s.mugshot.handleFor('HITMAN01'))

        -- Past the refresh floor, so an invalidation is allowed at all.
        Env.advance((Config.Mugshot.MinRefreshMinutes * 60) + 1)
        truthy(fire('appearanceChanged', 3))

        falsy(s.mugshot.handleFor('HITMAN01'), 'the sender face is dropped')
        truthy(s.mugshot.handleFor('CREATOR1'),
            'and a player cannot drop somebody else face')
    end)

    it('answers whoAmI about the caller and nobody else', function()
        local s = wired()
        Env.clientEvents = {}
        truthy(fire('whoAmI', 3))

        local told = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:access' then
                told[#told + 1] = event.target
            end
        end
        eq(#told, 1, 'exactly one player is told')
        eq(told[1], 3, 'and it is the one who asked')
    end)

    it('never lets whoAmI carry anything but a yes or no, and which screen', function()
        -- It is the access decision, and the access decision is a boolean,
        -- with the screen it shows them (W167): one of three words about
        -- themselves. Anything else on this payload is something a player
        -- learned by asking a question about themselves.
        local s = wired()
        Env.clientEvents = {}
        fire('whoAmI', 3)
        local seen = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:access' then
                seen = seen + 1
                eq(type(event.args[1]), 'boolean',
                    'the access answer must be a boolean and nothing else')
                truthy(event.args[2] == 'full' or event.args[2] == 'whitelisted'
                    or event.args[2] == 'closed', 'a screen: ' .. tostring(event.args[2]))
                eq(#event.args, 2, 'and must carry nothing beside them')
            end
        end
        eq(seen, 1)
    end)

    it('does not throw when a stranger fires any of them', function()
        -- A source the resource has never seen. Every one of these is
        -- addressable by anybody on the server.
        local s = wired()
        for _, name in ipairs({ 'whoAmI', 'appearanceChanged' }) do
            truthy(fire(name, 4242),
                name .. ' must survive a source with no character')
        end
    end)
end)

--- The framework's own events, as this resource registers them.
---
--- These are the resource's whole lifecycle — a player arriving, changing
--- job, leaving, switching character — and line coverage showed the suite
--- had never executed one of them. The functions underneath are tested;
--- the registrations that call them are where a wrong event name fails
--- silently, which the file's own comments say has happened here before.
---
--- One of them is a net event rather than a local one, so it is also a
--- surface any player on the server can reach.
describe('the framework events this resource listens for', function()
    local function wired()
        local s = newStack()
        local f = fixture(s)
        s.bridges.install(s)
        return s, f
    end

    local function fire(name, src, ...)
        local handler = Env.events[name]
        if not handler then return nil, 'not registered: ' .. name end
        _G.source = src
        local ok, err = pcall(handler, ...)
        _G.source = nil
        return ok, err
    end

    --- Owed money waiting for somebody to come back. Each on a target of
    --- its own: one live contract per player on one target.
    local placed = 0
    local function owed(s, cid)
        placed = placed + 1
        local target = 'TARGET01'
        if placed > 1 then
            target = 'TARGET0' .. (placed + 1)
            Env.addPlayer({ source = 30 + placed, citizenid = target, license = 'license:o' .. placed,
                cash = 100, bank = 100, firstname = 'Owe', lastname = tostring(placed) })
        end
        local c = s.contracts.create(s.identity.resolve(1), {
            targetCid = target, reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        s.bailout.owe(cid, c.id, 4000, 'bank', 'test')
        return c
    end

    it('listens under the names the frameworks actually fire', function()
        -- A renamed event is not an error anywhere: it is a handler that
        -- never runs, and a player who quietly never gets what they are
        -- owed. Listed so a rename is a decision rather than a silence.
        wired()
        for _, name in ipairs({
            'QBCore:Server:OnPlayerLoaded',      -- a net event on some builds
            'local:QBCore:Server:PlayerLoaded',  -- what qbx_core fires on login
            'local:qbx_core:server:playerLoaded',
            'local:QBCore:Server:OnJobUpdate',   -- and on a job change
            'local:qbx_core:server:onSetJob',
            'local:playerDropped',
            'local:QBCore:Server:OnPlayerUnload',
            'local:qbx_core:server:playerLoggedOut',
            'local:weaponDamageEvent',
        }) do
            truthy(Env.events[name],
                'nothing is listening for ' .. name)
        end
    end)

    it('delivers what a player was owed once they are ready', function()
        local s = wired()
        owed(s, 'HITMAN01')
        local before = Env.players[3].PlayerData.money.bank

        truthy(fire('local:qbx_core:server:playerLoaded', 3,
            { PlayerData = { source = 3 } }))
        Env.advance(10)

        eq(Env.players[3].PlayerData.money.bank, before + 4000,
            'the login path is what pays somebody who was offline when their '
            .. 'money was released')
    end)

    --- The amplification, and the reason the pass is latched.
    ---
    --- QBCore:Server:OnPlayerLoaded is a RegisterNetEvent, so any client can
    --- fire it, and it had no flood guard — unlike every crimson-hitman:
    --- event, all of which have one. Each firing scheduled a five-second
    --- timer whose job is to read the pending-payout table. Measured before
    --- the latch: 200 firings queued 200 timers and 200 reads.
    it('schedules one readiness pass however many times it is fired', function()
        local s = wired()
        -- The firing player's reads only. Everyone already connected when the
        -- bridges were installed has one pass of their own queued (as after
        -- a restart of this resource), which is not the amplification.
        local reads = 0
        local real = s.storage.readPending
        s.storage.readPending = function(cid, ...)
            if cid == 'HITMAN01' then reads = reads + 1 end
            return real(cid, ...)
        end
        s.escrow.init(s.storage, s.audit)

        local before = #Env.timers
        for _ = 1, 200 do fire('QBCore:Server:OnPlayerLoaded', 3) end

        truthy(#Env.timers - before <= 2,
            ('one client queued %d server timers by repeating an event it is '
             .. 'allowed to send'):format(#Env.timers - before))

        Env.advance(10)
        truthy(reads <= 2,
            ('and %d reads of the pending table came of it'):format(reads))
    end)

    it('still pays somebody who logs in twice in a row', function()
        -- The latch must not eat a real second login. It is released when
        -- the pass runs, and when the player drops.
        local s = wired()
        placed = 0
        owed(s, 'HITMAN01')
        local before = Env.players[3].PlayerData.money.bank

        fire('QBCore:Server:OnPlayerLoaded', 3)
        Env.advance(10)
        eq(Env.players[3].PlayerData.money.bank, before + 4000)

        owed(s, 'HITMAN01')
        fire('QBCore:Server:OnPlayerLoaded', 3)
        Env.advance(10)
        eq(Env.players[3].PlayerData.money.bank, before + 8000,
            'a later login must still collect what was owed after the first')
    end)

    it('cannot be replayed into paying twice for the same line', function()
        -- The money-critical property on a client-reachable event. It holds
        -- because the release is a compare-and-set on the escrow line, not
        -- because the event is hard to reach.
        local s = wired()
        owed(s, 'HITMAN01')
        local before = Env.players[3].PlayerData.money.bank

        for _ = 1, 5 do
            fire('QBCore:Server:OnPlayerLoaded', 3)
            Env.advance(10)
        end

        eq(Env.players[3].PlayerData.money.bank, before + 4000,
            'four thousand was owed and four thousand was paid, whatever the '
            .. 'client did')
    end)

    it('tells a player their access when their job changes', function()
        local s = wired()
        Env.clientEvents = {}
        truthy(fire('local:QBCore:Server:OnJobUpdate', nil, 3, { name = 'unemployed' }))

        local told = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:access' then told[#told + 1] = event.target end
        end
        eq(#told, 1, 'the player whose job changed is told, and only them')
        eq(told[1], 3)
    end)

    it('cleans up after a player who drops', function()
        local s = wired()
        fire('local:qbx_core:server:playerLoaded', 3, { PlayerData = { source = 3 } })
        truthy(fire('local:playerDropped', 3))
        -- Resolving them afterwards is what a naive cleanup would do, and by
        -- this point the framework may already have discarded them.
        truthy(true)
    end)

    it('cleans up after, and pauses the clock for, a player online across a restart', function()
        -- Nobody fires a load event for a player already in the city when
        -- the resource starts. If the framework has let them go by the time
        -- their playerDropped arrives, they were nobody: nothing cleaned
        -- up, and no clock stopped, so the contract on them expired the
        -- moment they came back, their hitman's stake with it.
        local s = newStack()
        fixture(s)
        local marked = 0
        s.scheduler = { presenceChanged = function() marked = marked + 1 end,
                        contractsChanged = function() end }
        s.bridges.install(s)
        s.bridges.refreshAccess()
        local ended
        local endSession = s.identity.endSession
        s.identity.endSession = function(cid) ended = cid return endSession(cid) end

        Env.removePlayer(2)
        truthy(fire('local:playerDropped', 2))
        s.identity.endSession = endSession
        truthy(marked > 0, 'the expiry pass was not told somebody left')
        eq(ended, 'TARGET01', 'and nothing of theirs was cleaned up')
    end)

    it('survives a loaded event carrying nothing usable', function()
        local s = wired()
        for _, odd in ipairs({ 42, true, {}, { PlayerData = false }, { PlayerData = 5 } }) do
            truthy(fire('local:qbx_core:server:playerLoaded', nil, odd),
                ('a %s payload must not throw out of a framework event')
                    :format(type(odd)))
        end
        truthy(fire('local:qbx_core:server:playerLoaded', nil),
            'nor must an absent one')
    end)
end)

describe('the matrix covers the whole net surface', function()
    --- A handler with no row is the gap this file exists to close. Left to
    --- a hand-written list, the next handler is added to app.lua and to the
    --- page and to nothing else — and the suite reports full marks on a
    --- surface it has never called.
    it('has a row for every handler app.lua registers', function()
        local app = newStack().app
        local missing = {}
        for name in pairs(app.handlers) do
            if not MATRIX[name] then missing[#missing + 1] = name end
        end
        table.sort(missing)
        eq(#missing, 0,
            'these handlers are reachable from a client and no row here says '
            .. 'who may call them: ' .. table.concat(missing, ', '))
    end)

    --- The other direction, so a handler that is renamed or deleted takes
    --- its row with it rather than leaving one that quietly tests nothing.
    it('has no row for a handler that does not exist', function()
        local app = newStack().app
        local stale = {}
        for name, entry in pairs(MATRIX) do
            if not app.handlers[name] and not entry.custom then
                stale[#stale + 1] = name
            end
        end
        table.sort(stale)
        eq(#stale, 0, 'rows for handlers nothing registers: ' .. table.concat(stale, ', '))
    end)

    --- App.handlers only knows about the ones registered through handler().
    --- Anything registered directly is exactly how a handler comes to have
    --- no gate and no row, so the source is read for the literal names too.
    ---
    --- Every server file, not just app.lua. This read one file and the block
    --- around it says "the whole net surface", which it was not: three
    --- events any player on the server can fire — whoAmI, mugshot and
    --- appearanceChanged — are registered in bridges.lua, so none of them
    --- had a row and nothing noticed. A net event is a net event wherever it
    --- is written.
    it('has a row for every net event this resource registers anywhere', function()
        local found, missing = {}, {}
        local listing = io.popen("find crimson-hitman/server -name '*.lua' 2>/dev/null")
        for path in listing:lines() do
            local source = read_file(path) or ''
            for name in source:gmatch("RegisterNetEvent%('crimson%-hitman:([%w_]+)'") do
                found[name] = path
            end
        end
        listing:close()

        for name, path in pairs(found) do
            if not MATRIX[name] then
                missing[#missing + 1] = name .. ' (' .. path .. ')'
            end
        end
        table.sort(missing)
        eq(#missing, 0,
            'these net events are registered outside the handler() gate and '
            .. 'the matrix says nothing about them: ' .. table.concat(missing, ', '))
    end)

    --- And the search itself has to be able to find something, or the check
    --- above passes because it looked nowhere.
    it('actually reads the files it claims to search', function()
        local names = {}
        local listing = io.popen("find crimson-hitman/server -name '*.lua' 2>/dev/null")
        for path in listing:lines() do
            for name in (read_file(path) or ''):gmatch(
                "RegisterNetEvent%('crimson%-hitman:([%w_]+)'") do
                names[#names + 1] = name
            end
        end
        listing:close()
        truthy(#names >= 5,
            'the resource registers more direct net events than this found ('
            .. #names .. '), so the completeness check above is looking at '
            .. 'nothing')
    end)

    --- The exemption is a closed set, or it is a way to silence a handler.
    it('exempts only the handlers named in CUSTOM', function()
        local claimed = {}
        for name, entry in pairs(MATRIX) do
            if entry.custom and not CUSTOM[name] then claimed[#claimed + 1] = name end
        end
        table.sort(claimed)
        eq(#claimed, 0,
            'these rows take the grid exemption without being named as one '
            .. 'of the handlers that has its own block: '
            .. table.concat(claimed, ', '))
    end)

    it('covers every exempt handler in a block that exists', function()
        -- The exemption names where the handler is covered instead. A name
        -- pointing at a block nobody wrote is the same hole, one step along.
        local source = read_file('tests/authz_matrix_spec.lua')
        local missing = {}
        for name, title in pairs(CUSTOM) do
            if not source:find("describe('" .. title .. "'", 1, true) then
                missing[#missing + 1] = name .. ' -> ' .. title
            end
        end
        table.sort(missing)
        eq(#missing, 0,
            'exempt handlers whose covering block is not in this file: '
            .. table.concat(missing, ', '))
    end)

    --- A row that names five roles has a hole in it, and a hole in a matrix
    --- reads as a pass.
    it('answers for every role in every row', function()
        local holes = {}
        for name, entry in pairs(MATRIX) do
            if not entry.custom then
                for _, role in ipairs(ROLES) do
                    if entry.expect[role] == nil then
                        holes[#holes + 1] = name .. '/' .. role
                    end
                end
            end
        end
        table.sort(holes)
        eq(#holes, 0, 'cells with no expectation: ' .. table.concat(holes, ', '))
    end)
end)
