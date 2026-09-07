--- Who may act on a contract, cell by cell.
---
--- Every handler registered in server/app.lua, crossed with every role a
--- caller can hold on the contract it names: the creator who placed it, the
--- target it names, a hunter who accepted it, a hunter accepted on a
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
--- across the whole shipped suite: a hunter allowed to buy informant data
--- on the contract they are hunting, the masked relay naming a hunter who
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
---     on a named contract, once with the creator and the hunter both
---     anonymous — with the same verdicts expected either way, and every
---     reply from the second pass scanned for the real names underneath.
---
--- And the rule that keeps it a matrix: a handler with no row FAILS. The
--- grid is checked against App.handlers and against the RegisterNetEvent
--- lines in app.lua, in both directions, so a handler added without a row
--- is a failure rather than a silent gap.

local APP_SOURCE = read_file('crimson-bounty/server/app.lua')

--------------------------------------------------------------------------
-- The cast
--------------------------------------------------------------------------

--- Everyone the grid needs, and what each is for. Ten players rather than
--- six: three contracts have to exist at once for "a hunter on somebody
--- else's contract" to be a role somebody can actually hold, and the
--- contract nobody has accepted needs a target of its own because a creator
--- may not place two on the same person inside the cooldown.
local CAST = {
    creator     = { source = 1,  cid = 'CREATOR1', name = { 'Vic', 'Marlowe' } },
    target      = { source = 2,  cid = 'TARGET01', name = { 'Dana', 'Reyes' } },
    hunter      = { source = 3,  cid = 'HUNTER01', name = { 'Rook', 'Ash' } },
    stranger    = { source = 4,  cid = 'STRANGE1', name = { 'Nils', 'Odd' } },
    otherHunter = { source = 5,  cid = 'TAILER01', name = { 'Kade', 'Wolfe' } },
    admin       = { source = 6,  cid = 'ADMIN001', name = { 'Sam', 'Steward' } },
    -- Supporting cast: never a caller, only somebody for a contract to name.
    spare       = { source = 7,  cid = 'TARGET02', name = { 'Pia', 'Nolan' } },
    farCreator  = { source = 8,  cid = 'CREATOR2', name = { 'Otto', 'Vance' } },
    farTarget   = { source = 9,  cid = 'TARGET03', name = { 'Ines', 'Cruz' } },
    victim      = { source = 10, cid = 'VICTIM01', name = { 'Bram', 'Tully' } },
}

--- The six roles every row must answer for, in the order they are reported.
local ROLES = { 'creator', 'target', 'hunter', 'otherHunter', 'stranger', 'admin' }

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
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER', missing = true } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err), threw = true } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
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
---   held    the contract under test for most rows. Hunter has accepted it.
---   unheld  the creator's, nobody accepted, for the rows that are refused
---           outright once somebody is hunting (cancel, revise, withdraw).
---   far     somebody else's entirely, so `otherHunter` is a real hunter
---           rather than a stranger wearing the label.
---@param opts table|nil { anonymous = boolean }
local function world(opts)
    opts = opts or {}
    local s = newStack()

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

    local held = s.contracts.create(who.creator, {
        targetCid = CAST.target.cid, reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        bailoutAmount = 15000,
        anonymous = opts.anonymous or nil,
    })
    truthy(held, 'the world needs a contract somebody is hunting')
    truthy(s.contracts.accept(who.hunter, held.id, opts.anonymous == true),
        'the hunter has to be on it')

    -- Anonymous on the anonymous pass as well: the creator is the same
    -- person, and one named contract of theirs on the board would put their
    -- real name in every listing reply for a reason that has nothing to do
    -- with the contract under test.
    local unheld = s.contracts.create(who.creator, {
        targetCid = CAST.spare.cid, reason = 'Unpaid debt',
        mode = CB.MODE.EXCLUSIVE,
        reward = { baseline = { cash = 5000, bank = 3000 } },
        anonymous = opts.anonymous or nil,
    })
    truthy(unheld, 'the world needs a contract nobody is hunting')

    local far = s.contracts.create(who.farCreator, {
        targetCid = CAST.farTarget.cid, reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(far, 'the world needs a contract belonging to somebody else')
    truthy(s.contracts.accept(who.otherHunter, far.id, false),
        'the other hunter has to be a hunter, or the column proves nothing')

    return { s = s, who = who, held = held, unheld = unheld, far = far }
end

--- Which player plays each role for a given contract.
---
--- Only the target moves: the contract nobody holds names a different
--- person, so `target` there is that person. `hunter` against the unheld
--- contract is somebody who really did accept a contract — just not this
--- one — which is exactly the role the column is for.
local function castFor(w, which)
    local contract = which == 'unheld' and w.unheld or w.held
    local target = which == 'unheld' and CAST.spare or CAST.target
    return contract, {
        creator = CAST.creator, target = target, hunter = CAST.hunter,
        otherHunter = CAST.otherHunter, stranger = CAST.stranger, admin = CAST.admin,
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
--- hunter, leaving a pending claim. Nothing here is taken from a client's
--- word: the damage is recorded, the health loss is real, and the victim
--- reports their own death.
local function eliminate(w)
    Env.players[CAST.hunter.source]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[CAST.target.source]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[CAST.target.source]._health = 140
    w.s.death.recordDamage(CAST.hunter.source, CAST.target.source, 123456)
    Env.players[CAST.target.source].PlayerData.metadata.isdead = true
    w.s.death.onVictimReport(CAST.target.source)
    truthy(w.s.death.getPending(w.held.id, CAST.hunter.cid),
        'the arrangement has to leave a claim the hunter could prove')
end

--- The handle a creator is given for their thread with the hunter. Minted
--- through Comms so it is the real one, and deliberately handed to every
--- role: the question this file asks is whether a handle somebody else was
--- given is any use to you.
local function creatorThreadHandle(w)
    local threads = w.s.comms.threads(w.who.creator, w.held.id)
    truthy(threads and threads[1] and threads[1].handle,
        'the creator has to have a thread with the hunter to hand around')
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
local NOT_PARTY = CB.ERR.NOT_PARTICIPANT

--- Handlers that name no contract at all: they answer about the caller and
--- about nobody else, so every role may call them and the grid's job is the
--- leak scan rather than the verdict.
local ANYONE = { creator = ALLOW, target = ALLOW, hunter = ALLOW,
                 otherHunter = ALLOW, stranger = ALLOW, admin = ALLOW }

--- Everyone but one role is refused, with the same code.
local function only(role, code)
    local row = {}
    for _, name in ipairs(ROLES) do row[name] = code end
    row[role] = ALLOW
    return row
end

--- Only the creator of the contract.
local CREATOR_ONLY = only('creator', NOT_PARTY)

--- Only the hunter who accepted this contract.
local HUNTER_ONLY = only('hunter', NOT_PARTY)

--- Only the person the contract names.
local TARGET_ONLY = only('target', NOT_PARTY)

--- The two sides of the deal: creator and the hunters working for them.
--- The target is not one of them — a contract is amended between the people
--- who agreed it, and the person it names is not a party to that (§12).
local BOTH_SIDES = { creator = ALLOW, target = NOT_PARTY, hunter = ALLOW,
                     otherHunter = NOT_PARTY, stranger = NOT_PARTY, admin = NOT_PARTY }

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
    -- it is enforced: a creator may not hunt their own contract, a target may
    -- not hunt themselves, and a hunter already on it cannot accept twice.
    expect = { creator = CB.ERR.SELF_ACCEPT, target = CB.ERR.SELF_TARGET,
               hunter = CB.ERR.BAD_STATE,
               otherHunter = ALLOW, stranger = ALLOW, admin = ALLOW },
    why = 'open to anyone not already party to it',
}

MATRIX.abandon = {
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = HUNTER_ONLY,
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
    expect = only('creator', CB.ERR.NOT_FOUND),
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
            if line.source == 'bank' and line.portion == CB.PORTION.BASELINE then pick = line.id end
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
    -- bad_state: there is no pending kill in this caller's name, which is
    -- the same sentence as "you did not do this".
    expect = only('hunter', CB.ERR.BAD_STATE),
    why = 'the proof token belongs to the hunter the server saw make the kill',
}

MATRIX.submitPhoto = {
    -- One token, issued to the hunter, offered to everybody. This is the
    -- cell that matters: a token is a bearer credential unless the server
    -- checks who is bearing it.
    arrange = function(w)
        eliminate(w)
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        w.s.photo.loadAllowedHosts()
        local token = w.s.photo.issue(w.who.hunter, w.held.id)
        truthy(token, 'the arrangement has to produce a token to pass around')
        w.token = token

        -- Every role standing over the body, not just the hunter. Ownership
        -- of the token has to be the ONLY thing refusing them: with everyone
        -- left where they spawned, deleting the ownership check outright
        -- still refused them all — for being too far from the scene — and
        -- this row went on passing over a resource anybody could collect on.
        for _, name in ipairs(ROLES) do
            Env.players[CAST[name].source]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        end
    end,
    payload = function(w) return { token = w.token, url = 'https://cdn.fivemanage.com/p.png' } end,
    expect = only('hunter', CB.ERR.TOKEN_INVALID),
    why = 'a photo token is bound to the hunter it was issued to',
}

MATRIX.armKidnap = {
    arrange = assembleForHandover,
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = HUNTER_ONLY,
    why = 'a handover is started by the operative holding the target',
}

MATRIX.kidnapProgress = {
    arrange = function(w)
        assembleForHandover(w)
        truthy(w.s.kidnap.arm(w.held.id, CAST.hunter.cid), 'the countdown has to be running')
    end,
    payload = function(w, role, contract) return { id = contract.id } end,
    -- No code: the countdown is looked up by (contract, hunter) and simply
    -- is not there for anyone else, which the app draws as "no delivery
    -- running" rather than as an error.
    expect = only('hunter', SILENT),
    why = 'the countdown is the hunter own; where a delivery has got to is '
       .. 'not something the target gets to poll',
}

-- The target's counter-play ---------------------------------------------

MATRIX.bailout = {
    payload = function(w, role, contract) return { id = contract.id } end,
    expect = TARGET_ONLY,
    why = 'buying your way out is the one move the person named gets',
}

MATRIX.informant = {
    payload = function(w, role, contract) return { id = contract.id } end,
    -- Both ends of the deal may buy, and nobody else: the creator to see who
    -- is working for them, the target to see who is coming (§6.1).
    expect = { creator = ALLOW, target = ALLOW, hunter = NOT_PARTY,
               otherHunter = NOT_PARTY, stranger = NOT_PARTY, admin = NOT_PARTY },
    why = 'unmasking an operative is sold to the two parties, not to onlookers',
}

-- Amendments ------------------------------------------------------------

MATRIX.amendments = {
    arrange = function(w)
        local proposal = w.s.amendments.propose(w.who.hunter, w.held.id,
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
        local proposal = w.s.amendments.propose(w.who.hunter, w.held.id,
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
    expect = { creator = ALLOW, target = EMPTY, hunter = ALLOW,
               otherHunter = EMPTY, stranger = EMPTY, admin = EMPTY },
    why = 'an inbox lists your own threads and nobody else',
}

MATRIX.readThread = {
    arrange = function(w)
        truthy(w.s.comms.send(w.who.creator, w.held.id, creatorThreadHandle(w), 'Where are you?'),
            'the arrangement has to put something in the thread worth stealing')
        w.handle = creatorThreadHandle(w)
    end,
    -- The creator's handle, given to everyone. A hunter reading with it gets
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
}

MATRIX.iDied = { custom = true,
    why = 'only the victim own client can report their death' }
MATRIX.iRevived = { custom = true,
    why = 'only the victim own client can report their revival' }

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
--- and the hunter both anonymous, which changes who may be NAMED and must
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
            local w = world(pass.opts)
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
-- The two self-reports
--------------------------------------------------------------------------

describe('a death report acts on its caller and on nobody else', function()
    --- Fire iDied as somebody who really has just been killed by the hunter.
    ---
    --- The reporter is the victim in every respect the server can check:
    --- they are at the scene, the hunter's damage on them is in the log,
    --- their condition really dropped and the medical resource really says
    --- they are dead. Everything is true except that the contract does not
    --- name them — which is the one thing that is supposed to decide it.
    ---
    --- Killing the reporter for real matters. With only the contract's
    --- target laid out, every other role was refused for not being dead,
    --- and the refusal would have held with the target check deleted: a
    --- creator and a hunter arranging a death between them would have
    --- collected on a target nobody touched.
    local function reportAs(source, cid)
        local w = world()
        Env.players[CAST.hunter.source]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[source]._coords = { x = 101.0, y = 100.0, z = 30.0 }

        -- Watched, so the hunter's damage on them is corroborated and lands
        -- in the log. Being watched is not special: the server watches
        -- anyone an accepted contract names, so a creator who is also
        -- somebody else's target is watched exactly like this. Without it
        -- the damage is thrown away for want of a baseline and every
        -- refusal below holds for that reason instead of the right one.
        w.s.death.watch(cid, source, true)
        Env.players[source]._health = 140
        w.s.death.recordDamage(CAST.hunter.source, source, 123456)
        Env.players[source].PlayerData.metadata.isdead = true

        Env.clientEvents = {}
        _G.source = source
        pcall(Env.events['crimson-bounty:iDied'], CAST.hunter.source)
        _G.source = nil
        return w
    end

    it('opens a claim when the person who died reports it', function()
        local w = reportAs(CAST.target.source, CAST.target.cid)
        truthy(w.s.death.getPending(w.held.id, CAST.hunter.cid),
            'the victim own report is the one the server acts on — without '
            .. 'this passing, every refusal below is vacuous')
    end)

    for _, role in ipairs({ 'creator', 'hunter', 'otherHunter', 'stranger', 'admin' }) do
        it('opens nothing when ' .. role .. ' reports somebody else death', function()
            local w = reportAs(CAST[role].source, CAST[role].cid)
            falsy(w.s.death.getPending(w.held.id, CAST.hunter.cid),
                role .. ' reported a death that was not theirs and a claim opened '
                .. 'on it. A hunter who can fire this is a hunter who can '
                .. 'collect on a target they never touched.')
        end)
    end

    it('does not answer the client at all', function()
        local w = world()
        Env.clientEvents = {}
        _G.source = CAST.stranger.source
        pcall(Env.events['crimson-bounty:iRevived'])
        _G.source = nil
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.name == 'crimson-bounty:result',
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
    --- and the hunter both paid to be hidden.
    ---
    --- Your own name is not a leak — a creator sees their own name on the
    --- contract they just placed — so only somebody else's is counted.
    it('never named an anonymous participant to anybody else', function()
        local hidden = {
            [CAST.creator.cid] = 'Vic Marlowe',
            [CAST.hunter.cid]  = 'Rook Ash',
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
        eq(second.err, CB.ERR.RATE_LIMITED)

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
    --- The two death reports are registered directly, which is exactly how a
    --- handler comes to have no gate and no row, so the source is read for
    --- the literal names too.
    it('has a row for every net event registered directly in app.lua', function()
        local missing = {}
        for name in APP_SOURCE:gmatch("RegisterNetEvent%('crimson%-bounty:([%w_]+)'") do
            if not MATRIX[name] then missing[#missing + 1] = name end
        end
        table.sort(missing)
        eq(#missing, 0,
            'app.lua registers these net events outside the handler() gate and '
            .. 'the matrix says nothing about them: ' .. table.concat(missing, ', '))
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
        local source = read_file('crimson-bounty/tests/authz_matrix_spec.lua')
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
