CrimsonBoot.define('server.intel.engine', function() --- Intel (Config.Intel, README "Intel"): every paid look-up sold in this
--- resource runs through this one engine.
---
--- The products, each its own module for what it finds and keeps:
---
---   informant        the target's informant: who is after me
---                    (server/intel/informants.lua, Config.Intel.Informant)
---   placerInformant  the placer's informant: who took it (the same module,
---                    Config.Intel.PlacerInformant)
---   locationTip      the hitman's tip: the target's rough area
---                    (server/intel/tip.lua, Config.Intel.LocationTip)
---   goDark           the counter-product: a tipped-off target hides from
---                    tips for a while (server/intel/rules.lua,
---                    Config.Intel.GoDark)
---
--- What the engine does for every one of them, in one place:
---
---   the check     Intel.check: "may this player buy intel X on contract
---                 Y": the steps the product lists, in its order, drawn
---                 from one set (party, feature and target class through
---                 Config.TargetClasses, holds through server/holds.lua,
---                 the contract still open) and the product's own (limits,
---                 cooldowns, the price);
---   the purchase  Intel.buy: one purchase at a time per lock
---                 (Contracts.serialized), the terms read once, the quote
---                 checked (TERMS_CHANGED), the last read before the
---                 charge, the charge last (Util.charge), then the
---                 product's confirm: any refusal there, or a read that
---                 raised, gives the price back (Intel.refund) before
---                 anything is delivered;
---   the refund    Intel.refund: one routine, with each product's own audit
---                 action and what happens to a refund that cannot be
---                 credited (owed through the buyout path, or left for
---                 staff in the review queue), as each did before;
---   delivery      Intel.tell: every notice a purchase sends (the target's
---                 tip warning, the advisory, the operative found out, a
---                 card refresh, a broker's briefing), each in a pcall;
---   in person     Intel.gate: with Config.Intel.InPerson on, the three
---                 look-ups are sold only beside the informant NPC
---                 (server/rp_places.lua), refused before anything is read.
---
--- Rumours and the broker's briefings (server/intel/rumours.lua) are intel
--- given, not sold, and use the engine's delivery only.
---
--- Nothing here learns or sends who a placer or a target is, or where
--- anybody stands: each product decides what its buyer is told, as before.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Feature = CrimsonBoot.require('server.lib.feature')
local Places = CrimsonBoot.require('server.rp_places')
local L = CrimsonBoot.requireShared('locale').t

local Intel = {}

--- The engine's own services: the in-person gate's audit, and the notices.
--- Each purchase brings its product module's (Intel.buy's svc), so a test
--- that starts one module over another store moves that one alone.
local Audit, Notify
--- The review queue a purchase caught by a crash is kept in, and the
--- buyout path's owed lines its price is given back by (Intel.decideUnrecorded).
local Review, Bailout

function Intel.init(deps)
    deps = deps or {}
    Audit, Notify = deps.audit, deps.notify
    Review, Bailout = deps.review, deps.bailout
    if Review and Review.DECIDERS then
        Review.DECIDERS.intel_unrecorded = function(item) return Intel.decideUnrecorded(item) end
    end
end

-- ============================================================================
--                              THE SWITCHES
-- ============================================================================

--- Whether one of the three look-ups is sold on a contract: the master
--- switch (Config.Intel.Enabled), the product's own (Config.Intel.<section>
--- .Enabled) and its switch for the target's class (Config.TargetClasses,
--- Util.targetRule).
---@param section string 'Informant' | 'PlacerInformant' | 'LocationTip'
---@param protected boolean|nil the target is on a whitelisted job
---@return boolean
function Intel.on(section, protected)
    local intel = Config and Config.Intel
    if type(intel) ~= 'table' or intel.Enabled ~= true then return false end
    local block = intel[section]
    if not (type(block) == 'table' and block.Enabled == true) then return false end
    return Util.targetRule(section, protected)
end

--- Whether one of the three is sold to any target at all, civilian or on a
--- whitelisted job: what the page is told of its price and rules, and the
--- first refusal, before a contract is read.
---@param section string
---@return boolean
function Intel.anyOn(section)
    return Intel.on(section, false) or Intel.on(section, true)
end

-- ============================================================================
--                              THE PRODUCTS
-- ============================================================================

--- Every product: its config block, who may buy it, what one purchase at a
--- time is locked by, and how its price comes back. `define` fills in the
--- product's own steps (Intel.define).
---
--- refund.fallback: 'owe', a refund that cannot be credited is owed and
--- handed over at the next login (Bailout.owe); 'review', it is left for
--- staff (the review queue, under the product's failed action).
Intel.PRODUCTS = {
    informant = {
        section = 'Informant', party = 'target',
        lock = function(actor, contractId) return 'informant:' .. contractId .. ':' .. tostring(actor.cid) end,
        refund = { action = 'informant_refunded', fallback = 'owe' },
    },
    placerInformant = {
        section = 'PlacerInformant', party = 'placer',
        lock = function(actor, contractId)
            return 'placerInformant:' .. contractId .. ':' .. tostring(actor.cid)
        end,
        refund = { action = 'placer_informant_refunded', fallback = 'owe' },
    },
    locationTip = {
        section = 'LocationTip', party = 'hitman',
        -- The contract's: its limit and its wait are shared by its hitmen.
        lock = function(_, contractId) return 'locationTip:' .. contractId end,
        refund = { action = 'location_tip_refunded', fallback = 'review',
                   failed = 'location_tip_refund_failed' },
        -- A refusal for want of money says the price.
        sayTerms = true,
    },
    goDark = {
        section = 'GoDark', party = 'target',
        -- The target's: one window at a time, whichever contract.
        lock = function(actor) return 'goDark:' .. tostring(actor.cid) end,
        refund = { action = 'go_dark_refunded', fallback = 'owe' },
        sayTerms = true,
    },
}

--- A product: its entry in Intel.PRODUCTS with the product module's own
--- part of the purchase, as a table of its own (the module keeps it and
--- hands it to Intel.buy), so a second copy of a module never takes over
--- the first one's purchases.
---@param name string a key of Intel.PRODUCTS
---@param parts table { terms, steps, ready, uncharged, confirm, deliver }
---   terms(ctx)      the price and account, read once: sets ctx.cost, ctx.account
---   steps           the check, in order: names of Intel.STEPS or functions
---                   (ctx) -> nil, or err, data
---   ready(ctx)      after the quote, before the charge: nil, or err, data
---   uncharged(ctx)  the charge was refused (undo what ready kept)
---   confirm(ctx)    after the charge: true, or false, err, data, why, say;
---                   false (or a raise) gives the price back first, `say`
---                   puts whether it came back in data.refunded
---   deliver(ctx)    the purchase stands: the answer to send
---   intent(ctx)     before the confirm: what names this purchase's record
---   recorded(contractId, cid, mark)  after a restart: whether the record
---                   `intent` named was written (Intel.decideUnrecorded)
---@return table product
function Intel.define(name, parts)
    local base = assert(Intel.PRODUCTS[name], 'no such intel product: ' .. tostring(name))
    local product = { name = name }
    for k, v in pairs(base) do product[k] = v end
    for k, v in pairs(parts) do product[k] = v end
    Intel.defined[name] = product
    return product
end

--- The products defined, by name: the last module to define one is the one
--- a purchase caught by a crash is asked about.
Intel.defined = {}

-- ============================================================================
--                              THE CHECK
-- ============================================================================

local function isLive(contract)
    return contract ~= nil and (contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED)
end
Intel.isLive = isLive

--- The steps every product draws on, by name.
Intel.STEPS = {
    --- The buyer's part in it. Not found and not theirs are the same
    --- answer (not_participant), so an id cannot be tried for whether it
    --- exists. A hitman's row is kept for the product (ctx.mine).
    party = function(ctx, product)
        local contract, cid = ctx.contract, ctx.actor.cid
        if product.party == 'target' then
            if contract.target_cid ~= cid then return CH.ERR.NOT_PARTICIPANT end
        elseif product.party == 'placer' then
            if contract.creator_cid ~= cid then return CH.ERR.NOT_PARTICIPANT end
        elseif product.party == 'hitman' then
            local mine = ctx.svc.storage.readHitman(ctx.contractId, cid)
            if not mine or mine.state ~= 'active' then return CH.ERR.NOT_PARTICIPANT end
            ctx.mine = mine
        else
            return CH.ERR.NOT_PARTICIPANT
        end
        return nil
    end,
    --- On hold by staff (server/holds.lua): no money moves on it.
    holds = function(ctx)
        if Holds.on(ctx.contract, nil, 'staff') then return CH.ERR.CONTRACT_FROZEN end
        return nil
    end,
    --- Not settled yet.
    open = function(ctx)
        if CH.TERMINAL[ctx.contract.state] then return CH.ERR.ALREADY_SETTLED end
        return nil
    end,
    --- Still on the board: open, or accepted.
    live = function(ctx)
        if not isLive(ctx.contract) then return CH.ERR.ALREADY_SETTLED end
        return nil
    end,
    --- Sold on this contract: the master switch, the product's and the
    --- target class's (Intel.on), the class read from the contract's flag
    --- unless the product reads it another way (product.protected).
    class = function(ctx, product)
        local protected = ctx.contract.target_protected == true
        if product.protected then protected = product.protected(ctx) end
        if Intel.on(product.section, protected) then return nil end
        return product.offErr and product.offErr(ctx, protected) or CH.ERR.FEATURE_OFF
    end,
}

--- Whether this player may buy this product on this contract, now: every
--- step the product lists, in its order, the first refusal answered.
---@param product table
---@param ctx table { actor, contractId, contract, svc, ... }
---@return string|nil err
---@return table|nil data
function Intel.check(product, ctx)
    for _, step in ipairs(product.steps or {}) do
        local fn = type(step) == 'string' and Intel.STEPS[step] or step
        local err, data = fn(ctx, product)
        if err then return err, data end
        if ctx.answer then return nil end
    end
    return nil
end

--- Whether the price the page quoted is the price now: one raised from the
--- admin panel while the dialog was open is refused, with the price now.
--- No quote (a caller that is not a page) and a free purchase pass.
---@return boolean
function Intel.quoteHolds(shown, cost, account)
    if shown == nil or cost <= 0 then return true end
    local quoted = type(shown) == 'table' and shown or {}
    return tonumber(quoted.cost) == cost and quoted.account == account
end

-- ============================================================================
--                              THE REFUND
-- ============================================================================

--- Give back a price taken for a purchase that never stood. Credited now
--- where it can be; otherwise owed (Bailout.owe, handed over at the next
--- login) or left for staff (the review queue), by the product. Audited
--- under the product's own action, with why.
---@param ctx table the purchase (actor, contractId, cost, account, svc)
---@param product table
---@param why string
---@return boolean credited true where it was paid back, or owed
function Intel.refund(ctx, product, why)
    local cost, account, actor = ctx.cost or 0, ctx.account, ctx.actor
    if cost <= 0 then return true end
    local how, svc = product.refund, ctx.svc
    -- With what a credit that raised says arrived (Util.credit), as
    -- Bailout.deliver passes it: a price that partly or perhaps arrived is
    -- never owed blind.
    local credited, raised, arrived, before = Util.credit(actor.player, account, cost)
    if how.fallback == 'review' then
        if credited then
            svc.audit.financial(how.action, actor.cid, ctx.contractId,
                { amount = cost, account = account, reason = why })
            return true
        end
        svc.audit.financial(how.failed, actor.cid, ctx.contractId,
            { amount = cost, account = account, reason = why, error = raised })
        if svc.review then
            pcall(svc.review.open, { kind = how.failed, contract_id = ctx.contractId,
                cids = { payer = actor.cid }, amount = cost, account = account,
                known = { reason = why, error = raised } })
        end
        return false
    end
    if not credited and svc.bailout and svc.bailout.owe then
        local raise = raised and { error = raised, arrived = arrived, before = before } or nil
        local okOwe, owed = pcall(svc.bailout.owe, actor.cid, ctx.contractId, cost, account, how.action, raise)
        credited = okOwe and owed ~= nil
    end
    svc.audit.financial(how.action, actor.cid, ctx.contractId,
        { amount = cost, account = account, reason = why, owed = not credited or nil, error = raised })
    return credited
end

-- ============================================================================
--                              THE PURCHASE
-- ============================================================================

local function run(product, ctx)
    product.terms(ctx)
    ctx.cost = math.max(0, math.floor(tonumber(ctx.cost) or 0))

    ctx.contract = ctx.svc.storage.readContract(ctx.contractId)
    if not ctx.contract then return false, CH.ERR.NOT_PARTICIPANT end
    local err, data = Intel.check(product, ctx)
    if err then return false, err, data end
    -- Answered without a sale (the informant's repeat inside its lock).
    if ctx.answer then return ctx.answer end

    if not Intel.quoteHolds(ctx.shown, ctx.cost, ctx.account) then
        return false, CH.ERR.TERMS_CHANGED, { cost = ctx.cost, account = ctx.account }
    end

    -- The last reads, with nothing between them and the charge.
    if product.ready then
        local notReady, readyData = product.ready(ctx)
        if notReady then return false, notReady, readyData end
    end

    -- Charged last. Balance read first: RemoveMoney answers true on an
    -- empty bank.
    if not Util.charge(ctx.actor.player, ctx.account, ctx.cost) then
        if product.uncharged then pcall(product.uncharged, ctx) end
        return false, CH.ERR.INSUFFICIENT,
            product.sayTerms and { cost = ctx.cost, account = ctx.account } or nil
    end

    -- Kept on this machine before anything is awaited (Review.prepare): a
    -- crash between the charge and the product's record kept the price
    -- with nothing to show for it and nothing to give it back (step 7
    -- BUG-3). The next start settles it (Intel.decideUnrecorded); a
    -- purchase that ends here, either way, lets it go.
    local intent
    if Review and Review.prepare and ctx.cost > 0 and product.recorded then
        intent = Review.prepare({
            kind = 'intel_unrecorded', contract_id = ctx.contractId,
            cids = { payer = ctx.actor.cid }, amount = ctx.cost, account = ctx.account,
            known = { decide = true, product = product.name,
                      mark = product.intent and product.intent(ctx) or {} },
        })
    end

    -- Anything that stops the purchase after the charge gives the money
    -- back first, a read that raised (a dropped connection) included.
    local okC, stands, cErr, cData, why, say = pcall(product.confirm, ctx)
    if not okC then
        Intel.refund(ctx, product, 'read_failed')
        if intent then Review.discard(intent) end
        error(stands, 0)
    end
    if not stands then
        local back = Intel.refund(ctx, product, why or cErr)
        if intent then Review.discard(intent) end
        if say then
            cData = cData or {}
            cData.refunded = back
        end
        return false, cErr, cData
    end
    local out = table.pack(product.deliver(ctx))
    if intent then Review.discard(intent) end
    return table.unpack(out, 1, out.n)
end

--- intel_unrecorded, settled by the server at the next start: a purchase
--- charged whose process stopped before it finished. Kept where the
--- product's record is in the store (it stands, and is shown again as any
--- is after a restart); otherwise its price is owed back to the buyer under
--- an id that comes from the item, so a second decision gives nothing more
--- (Bailout.payOwed), and handed over now or at their next login.
---@param item table a review item
---@return string verdict 'done' | 'staff'
---@return string note
function Intel.decideUnrecorded(item)
    local known = type(item.known) == 'table' and item.known or {}
    local product = Intel.defined[known.product]
    local payer = type(item.cids) == 'table' and item.cids.payer or nil
    local amount = math.floor(tonumber(item.amount) or 0)
    if not (product and product.recorded and item.contract_id and payer and amount > 0) then
        return 'staff', L('intel_engine.it_does_not_carry_the_purchases')
    end
    if product.recorded(item.contract_id, payer, type(known.mark) == 'table' and known.mark or {}) then
        return 'done', L('intel_engine.the_purchase_is_on_record_so')
    end
    if not (Bailout and Bailout.payOwed) then return 'staff', L('intel_engine.nothing_here_can_give_the_price') end
    Bailout.payOwed({ id = item.contract_id }, ('intel:%s'):format(tostring(item.id)), payer, amount,
        item.account, product.refund.action)
    if Audit then
        Audit.financial(product.refund.action, payer, item.contract_id,
            { amount = amount, account = item.account, reason = 'interrupted', review = item.id })
    end
    return 'done', L('intel_engine.the_purchase_was_not_on_record')
end

--- Buy one product on one contract, one purchase at a time per the
--- product's lock: a second tap while one runs is refused as busy, before
--- anything is read or charged.
---@param product table from Intel.define
---@param svc table the product module's services { storage, audit, contracts, bailout, review }
---@param actor table the buyer
---@param contractId string checked by the caller (Util.toId)
---@param shown table|nil the page's echo of the price it quoted
---@param extra any the product's own input (the informant's pick)
---@return any result the product's answer, or false
---@return string|nil err
---@return table|nil data
function Intel.buy(product, svc, actor, contractId, shown, extra)
    local ctx = { name = product.name, svc = svc, actor = actor, contractId = contractId, shown = shown,
                  extra = extra }
    if not svc.contracts then return run(product, ctx) end
    return svc.contracts.serialized({ product.lock(actor, contractId) }, run, product, ctx)
end

-- ============================================================================
--                              DELIVERY
-- ============================================================================

--- Every notice a purchase or a briefing sends, by kind, each in a pcall:
--- a notice that raised never undoes what was bought.
Intel.TELL = {
    --- The target: someone knows their rough area (never who, nor where).
    tipped = function(notify, contract, title, text)
        return notify.locationTipped and notify.locationTipped(contract, title, text)
    end,
    --- Law enforcement: a hitman is closing in on a whitelisted-job member.
    advisory = function(notify, contract)
        return notify.tipAdvisory and notify.tipAdvisory(contract)
    end,
    --- The operative a placer found out about, naming the contract by its target.
    foundOut = function(notify, cid, title, text, contractId)
        return notify.tellOrKeep and notify.tellOrKeep(cid, title, text, nil, contractId)
    end,
    --- A card to refresh.
    push = function(notify, cid, kind, contractId)
        return notify.push and notify.push(cid, kind, contractId)
    end,
    --- A player a broker filled in on a contract.
    briefed = function(notify, cid, contractId)
        if notify.toCitizen then
            pcall(notify.toCitizen, cid, 'Crimson-Hitman', L('intel_engine.a_broker_filled_you_in_on'))
        end
        return notify.push and notify.push(cid, 'briefed', contractId)
    end,
}

--- Send one notice. `notify` is the caller's Notify (its module's), or the
--- engine's.
---@param kind string a key of Intel.TELL
---@param notify table|nil
---@return boolean sent
---@return any answer
function Intel.tell(kind, notify, ...)
    notify = notify or Notify
    local fn = Intel.TELL[kind]
    if not (fn and notify) then return false end
    local ok, answer = pcall(fn, notify, ...)
    return ok, answer
end

-- ============================================================================
--                              IN PERSON
-- ============================================================================

--- This block of config (server/lib/feature.lua reads and checks it).
local IN_PERSON = 'Intel.InPerson'

--- The requests sold only beside the informant NPC while Config.Intel
--- .InPerson is on, and the product each is: one switched off is refused
--- by its own handler, as before.
Intel.IN_PERSON = {
    informant = 'Informant', placerInformant = 'PlacerInformant', locationTip = 'LocationTip',
}

--- The in-person rule (App's roleplay gates): a buyer anywhere but within
--- Radius of the informant NPC, wherever it stands now, is refused with
--- 'Find the informant first.' before the purchase is looked at, so
--- nothing is charged and no look-up is spent. The distance is read on the
--- server from the buyer's ped.
---@return string|nil err
function Intel.gate(name, actor)
    local section = Intel.IN_PERSON[name]
    if not section or not Feature.on(IN_PERSON) then return nil end
    if not Intel.anyOn(section) then return nil end
    if Places.near('informant', actor.source) then return nil end
    if Audit then Audit.rejected('informant_not_found', actor.cid, nil, { request = name }) end
    return CH.ERR.FIND_INFORMANT
end

Intel.IN_PERSON_RULES = {
    Enabled = { kind = 'switch', default = false },
    Radius = { kind = 'number', min = 1, max = 100, default = 5.0 },
    Locations = { kind = 'list', each = Places.parsePoint, default = {},
        says = L('intel_engine.a_list_of_places_each_x') },
    RotateHours = { kind = 'number', min = 1, max = 168, integer = true, default = 3 },
    Model = { kind = 'text', default = 'a_m_y_hipster_01' },
    Scenario = { kind = 'text', default = 'WORLD_HUMAN_LEANING' },
    Blip = { kind = 'switch', default = false },
}

-- ============================================================================
--                              THE START-UP CHECK
-- ============================================================================

--- Every Intel block's rules held at the start and on the admin panel's
--- quiet check of a change: the informant in person, the tip rules and
--- going dark (server/intel/rules.lua), and the rumours
--- (server/intel/rumours.lua). The three look-ups' own numbers are checked
--- with the rest of the config (main.lua's validateConfig).
---@param warn string[]
function Intel.validate(warn)
    Feature.check(IN_PERSON, Intel.IN_PERSON_RULES, warn)
    -- The broker's and informant's places set from the panel (rp_places.lua).
    Feature.check('Roleplay.NpcPlaces', { Enabled = { kind = 'switch', default = false } }, warn)
    CrimsonBoot.require('server.intel.rules').validate(warn)
    CrimsonBoot.require('server.intel.rumours').validate(warn)
end

return Intel
end)
