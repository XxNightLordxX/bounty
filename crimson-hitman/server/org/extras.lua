--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/org/extras.lua                   ║
    ║   Organisation extras 1: contracts to the org, approval, probation,       ║
    ║   duty, the private channel and dossiers (each its own switch, off)       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The plan's R2, R3, R4, R5, R7 and R8 (README, Organisation extras;
--- docs/developer.md). Each is one switch under Config.Organisation, off as
--- shipped, and each needs the organisation itself on. Off, nothing here
--- reads a row or keeps a timer: the accept gate compares one switch per
--- feature, the board's filter is nil (Projection.reserved), and the tick
--- returns after one comparison.
---
---   * OrgContracts (R2): a placer sends a contract to the organisation
---     instead of the open board. It is held off the board while a boss
---     assigns it (K4) and the member takes it, AssignMinutes each; then it
---     goes on the open board. Reassign or send it back (K5). The placer's
---     anonymity is the board's: the organisation sees what a board card
---     shows (the target's name, the worth, the rule), never who placed it.
---   * AcceptApproval (R3): a member's accept worth more than ApprovalAbove,
---     or any accept of a member on probation (ApprovalProbation), waits for
---     a boss holding K6. Nothing is taken while it waits: approved, the
---     accept runs then, every rule checked again; refused or run out
---     (ApprovalMinutes), nothing was ever taken, so the stake stays theirs.
---   * Probation (R4): members at or below ProbationMaxGrade take only
---     contracts worth up to ProbationMaxReward, none staked where
---     ProbationNoStake, until ProbationCompletions completions (counted on
---     their record from when probation began) or a boss's sign-off (M8).
---   * Duty (R5): members clock in and out in the app (or only at the office,
---     DutyAtOffice); only members on duty are assigned, see and take the
---     organisation's contracts. Told to qbx_core (SetJobDuty, through the
---     framework adapter) where the job is their primary one, and a qbx duty
---     change of the job is taken in. A boss holding M9 sends one off duty.
---   * Channel (R7): a private message channel inside the Organisation tab,
---     rate limited (ChannelPerMinute), plain text only, kept
---     ChannelRetentionDays. A boss holding N3 removes messages and mutes a
---     member below them for up to Limits.ChannelMuteMaxHours.
---   * Dossiers (R8): a boss holding K7 attaches a briefing to an assigned
---     organisation contract: notes, one of the organisation's meeting spots
---     and the rules of engagement. Shown only to the member it is assigned
---     to. Never anything about the target: no field for it, and notes
---     naming the target's or the placer's citizen id are refused.
---
--- Every write is audited (org_*), staff may do every one of them from the
--- panel (server/org/staff_ops.lua), and every boss power is its own row in
--- Boss permissions (server/org/powers.lua), off until staff allow it.

local Util = CrimsonBoot.requireShared('util')
local Window = CrimsonBoot.require('server.lib.window')
local Feature = CrimsonBoot.require('server.lib.feature')
local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t

local Extras = {}

--- What the organisation gains (Org.sendRefusal, Org.assignContract, ...),
--- copied onto the organisation's own table (server/org/init.lua) by
--- Extras.attach; inside these functions the organisation is O.
local Org = {}
Extras.API = Org

-- ============================================================================
--                              STATE
-- ============================================================================

--- Accepts waiting for a boss (R3): [contractId:cid] = { id, contractId,
--- cid, anonymous, opts, at, expires }. Kept in memory: a restart forgets
--- them, and nothing was taken for any of them.
local Pending = {}

--- The accepts a boss approved, run now: [contractId:cid] = true, set and
--- cleared around the one Contracts.accept the approval makes.
local Approved = {}

--- Members on duty (R5): [cid] = os.time() they went on.
local OnDuty = {}

--- The channel (R7), newest last, at most KEEP in memory; nil until it is
--- first read with the switch on.
--- By organisation (Config.Organisation.SeveralOrganisations): [orgId] = rows.
local Messages, MessageSeq = {}, 0
local KEEP = 200

--- Messages each member sent in the last minute (ChannelPerMinute).
local Sent = Window.new(60)

--- When the tick last did its work, and last pruned the channel.
local LastTick, LastPrune = 0, 0

local O, kit

local function now() return os.time() end
local function deps() return kit.deps() end
local function fail(...) return kit.fail(...) end

--- Whether one of the extras is on: the organisation on, and its switch.
---@param name string a Config.Organisation key
---@return boolean
local function on(name)
    return Feature.on('Organisation') and Config.Organisation[name] == true
end
Extras.on = on

local function minutes(key, fallback, most)
    local n = math.floor(tonumber(Config.Organisation[key]) or fallback)
    return math.max(1, math.min(most or 10080, n))
end

local function tell(cid, text)
    local d = deps()
    if d.notify and d.notify.toCitizen and d.identity.byCitizenId(cid) then
        pcall(d.notify.toCitizen, cid, (O.current() and O.current().label) or L('org_extras.organisation'), text)
    end
end

--- The member a boss may act on (rank, lock, self): nil, or the refusal.
local function mayActOn(org, who, cid)
    if who.staff then return nil end
    local why = O.Engine.mayActOn(org, who.cid, cid)
    if not why then return nil end
    local ERR = O.ERR
    return why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or why == 'not_member' and ERR.NOT_FOUND
        or ERR.RANK
end

--- Plain text from a player: control characters and runs of spaces folded,
--- trimmed; nil (refused, never cut) when empty, longer than `max`
--- characters, or holding markup or a link.
---@return string|nil
local function plain(text, max)
    if type(text) ~= 'string' or #text > max * 4 then return nil end
    text = Util.toValidUtf8(text):gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s*(.-)%s*$', '%1')
    if text == '' or (utf8.len(text) or math.huge) > max then return nil end
    local lower = text:lower()
    if text:find('[<>]') or lower:find('https?://') or lower:find('www%.') or lower:find('discord%.gg') then
        return nil
    end
    return text
end
Extras.plain = plain

-- ============================================================================
--                              R2: CONTRACTS TO THE ORGANISATION
-- ============================================================================

--- The board's filter (Projection.reserved): [contractId] = the one member
--- shown it, or false for nobody. nil while none is held, so the board pays
--- nothing for it.
local function rebuild()
    local d = deps()
    if not d.projection then return end
    if not O.current() or not on('OrgContracts') then
        d.projection.reserved = nil
        return
    end
    local map, any = {}, false
    local duty = on('Duty')
    -- Every organisation's (SeveralOrganisations): a contract is sent to one.
    for _, org in ipairs(O.all()) do
        for id, entry in pairs(org.settings.orgContracts) do
            if entry.state == 'waiting' then
                map[id] = false
            elseif entry.state == 'assigned' then
                map[id] = (not duty or OnDuty[entry.cid]) and entry.cid or false
            else
                map[id] = entry.cid or false
            end
            any = true
        end
    end
    d.projection.reserved = any and map or nil
end
Extras.rebuild = rebuild

--- Why a placer may not send a contract to the organisation now: nil, or
--- the refusal (code, data). Asked before anything is placed or charged.
---@return string|nil err
---@return table|nil data
function Org.sendRefusal()
    if not O.current() then return O.ERR.OFF, { message = O.message(O.ERR.OFF) } end
    if not on('OrgContracts') then return O.ERR.FEATURE_OFF, { message = O.message(O.ERR.FEATURE_OFF) } end
    return nil
end

--- A contract just placed and sent to the organisation: held off the open
--- board for AssignMinutes. The placer is not kept here: the organisation
--- never learns who sent it.
---@param contractId string
---@param placerCid string for the record only
function Org.receiveContract(contractId, placerCid)
    local org = O.current()
    if not org or not on('OrgContracts') or type(contractId) ~= 'string' then return false end
    local wait = minutes('AssignMinutes', 30, 1440)
    org.settings.orgContracts[contractId] = { state = 'waiting', at = now(), expires = now() + wait * 60 }
    kit.save()
    rebuild()
    deps().audit.action('org_contract_received', placerCid, contractId, { org = org.id, minutes = wait })
    -- Every boss online who may assign it, told there is one; never by whom.
    for cid in pairs(org.members) do
        if O.Engine.holds(org, cid, 'K4') then
            tell(cid, (L('org_extras.a_contract_was_sent_to_the')):format(wait))
        end
    end
    return true
end

--- Assign an organisation contract to a member (K4), or move it to another
--- (K5 for one already assigned). The member then has AssignMinutes to
--- take it. With Duty on, only a member on duty.
function Org.assignContract(who, contractId, cid)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('OrgContracts') then return fail(ERR.FEATURE_OFF) end
    local entry = type(contractId) == 'string' and org.settings.orgContracts[contractId]
    if not entry or entry.state == 'taken' then return fail(ERR.NOT_FOUND) end
    local err = O.authorize(org, who, entry.state == 'assigned' and 'K5' or 'K4')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    if entry.cid == cid then return fail(ERR.ALREADY) end
    if member.suspended_until and member.suspended_until > now() then
        return fail(ERR.RULE, { message = L('org_extras.that_member_is_suspended_from_contracts') })
    end
    if on('Duty') and not OnDuty[cid] then return fail(ERR.OFF_DUTY, { message = L('org_extras.that_member_is_not_on_duty') }) end
    local wait = minutes('AssignMinutes', 30, 1440)
    local from = entry.cid
    entry.state, entry.cid, entry.by, entry.assignedAt = 'assigned', cid, who.staff and 'staff' or who.cid, now()
    entry.expires = now() + wait * 60
    kit.save()
    rebuild()
    kit.record(from and 'org_contract_reassigned' or 'org_contract_assigned', who, { member = cid, from = from },
        contractId)
    tell(cid, (L('org_extras.a_contract_was_assigned_to_you')):format(wait))
    if from then tell(from, L('org_extras.a_contract_assigned_to_you_was')) end
    return true, nil, { expiresIn = wait * 60 }
end

--- Send an organisation contract to the open board now (K5).
local function release(org, contractId, reason)
    local entry = org.settings.orgContracts[contractId]
    if not entry then return nil end
    org.settings.orgContracts[contractId] = nil
    kit.save()
    rebuild()
    if entry.cid and entry.state == 'assigned' then tell(entry.cid, L('org_extras.a_contract_assigned_to_you_went')) end
    -- The placer told it is on the open board now, never who had it. A
    -- territory hold (server/org/extras3.lua) says nothing: the placer never
    -- learns it was held, which would say where the target was.
    if reason ~= 'ended' and not entry.territory then
        local contract = deps().storage.readContract(contractId)
        if contract and contract.creator_cid then
            tell(contract.creator_cid, L('org_extras.your_contract_sent_to_an_organisation'))
        end
    end
    return entry
end

function Org.releaseContract(who, contractId)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('OrgContracts') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'K5')
    if err then return fail(err) end
    local entry = type(contractId) == 'string' and org.settings.orgContracts[contractId]
    if not entry or entry.state == 'taken' then return fail(ERR.NOT_FOUND) end
    release(org, contractId, 'boss')
    kit.record('org_contract_released', who, { reason = 'released', member = entry.cid }, contractId)
    return true
end

--- The gate's first question: held for the organisation, and this is not
--- the member it is assigned to (or they are off duty). Staff assigning a
--- hitman (Contracts.acceptHeld) pass.
---@return string|nil err
---@return table|nil data
function Extras.reservedRefusal(org, actor, contractId, opts)
    if not on('OrgContracts') then return nil end
    local entry = org.settings.orgContracts[contractId]
    if not entry or (type(opts) == 'table' and opts.staffAssigned) then return nil end
    if entry.cid ~= actor.cid then return 'org_reserved', { message = O.message('org_reserved') } end
    if on('Duty') and not OnDuty[actor.cid] then
        return O.ERR.OFF_DUTY, { message = L('org_extras.go_on_duty_to_take_a') }
    end
    return nil
end

--- After an acceptance: the organisation contract taken by its member (or
--- the hitman staff put on it), held for them from now on.
function Extras.afterAccept(org, actor, contractId)
    local entry = org.settings.orgContracts[contractId]
    if not entry then return end
    entry.state, entry.cid, entry.takenAt = 'taken', actor.cid, now()
    kit.save()
    rebuild()
end

-- ============================================================================
--                              R4: PROBATION
-- ============================================================================

local function completed(cid)
    local ok, stats = pcall(deps().storage.readStats, cid)
    return ok and type(stats) == 'table' and math.floor(tonumber(stats.completed) or 0) or 0
end

--- A member's probation now: nil when they are not on it, or { done, need }.
--- The completions are counted from when it began (the first time it was
--- asked, or a staff restart): their record's count less the one then.
---@param write boolean|nil start the count where none is kept yet
---@return table|nil
function Extras.probation(org, member, write)
    if not on('Probation') or not member then return nil end
    if member.grade > math.floor(tonumber(Config.Organisation.ProbationMaxGrade) or 0) then return nil end
    local row = org.settings.probation[member.cid]
    if row and row.passed then return nil end
    local need = math.max(0, math.floor(tonumber(Config.Organisation.ProbationCompletions) or 0))
    local count = completed(member.cid)
    if not row then
        if not write then return { done = 0, need = need } end
        row = { base = count, at = now() }
        org.settings.probation[member.cid] = row
        kit.save()
    end
    local done = math.max(0, count - (tonumber(row.base) or 0))
    if need > 0 and done >= need then
        row.passed, row.passedAt = 'record', now()
        kit.save()
        deps().audit.action('org_probation_passed', member.cid, nil, { org = org.id, by = 'record', done = done })
        tell(member.cid, L('org_extras.your_probation_is_over_you_may'))
        return nil
    end
    return { done = done, need = need }
end

--- End a member's probation (M8), or (staff only) put them on it again,
--- the count starting from now.
---@param passed boolean
function Org.setProbation(who, cid, passed)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Probation') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'M8')
    if err then return fail(err) end
    if type(passed) ~= 'boolean' or (not passed and not who.staff) then return fail(ERR.INVALID) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    local why = mayActOn(org, who, cid)
    if why then return fail(why) end
    if passed then
        if not Extras.probation(org, member, false) then return fail(ERR.ALREADY) end
        org.settings.probation[cid] = { passed = who.staff and 'staff' or 'boss', passedAt = now() }
        tell(cid, L('org_extras.your_probation_is_over_you_may'))
    else
        org.settings.probation[cid] = { base = completed(cid), at = now() }
        tell(cid, L('org_extras.staff_put_you_on_probation_again'))
    end
    kit.save()
    kit.record('org_probation', who, { member = cid, passed = passed })
    return true
end

-- ============================================================================
--                              R3 AND R4: THE GATE
-- ============================================================================

local function key(contractId, cid) return tostring(contractId) .. ':' .. tostring(cid) end

--- What a contract is worth now (Escrow.moneyValue), 0 where it cannot say.
local function worthOf(contractId)
    local d = deps()
    if not (d.escrow and d.escrow.moneyValue) then return 0 end
    local ok, v = pcall(d.escrow.moneyValue, contractId)
    return ok and tonumber(v) or 0
end

--- The member's accept held to probation: nil to let it through, or the
--- refusal. Notes on the gate whether they are on probation, for the
--- approval asked after every other rule (Extras.approvalGate).
---@param gate table the accept's own (Contracts.accept): { anonymous }
---@return string|nil err
---@return table|nil data
function Extras.probationGate(org, member, actor, contractId, contract, opts, gate)
    local probation = on('Probation')
    if not probation then return nil end
    local staffAssigned = type(opts) == 'table' and opts.staffAssigned
    local worth
    local function value()
        worth = worth or worthOf(contractId)
        return worth
    end
    local onProbation = probation and Extras.probation(org, member, not staffAssigned)
    if onProbation and not staffAssigned then
        local most = math.floor(tonumber(Config.Organisation.ProbationMaxReward) or 0)
        if value() > most then
            return 'org_probation', { message = (L('org_extras.on_probation_you_take_contracts_worth')):format(most, onProbation.done, onProbation.need) }
        end
        if Config.Organisation.ProbationNoStake ~= false and contract and (tonumber(contract.penalty_amount) or 0) > 0 then
            return 'org_probation', { message = L('org_extras.on_probation_you_take_no_contract') }
        end
    end
    if gate then gate.probation = onProbation and true or nil end
    return nil
end

--- After every other rule of the organisation passed: the accept held for
--- a boss's approval where it needs one (AcceptApproval).
---@return string|nil err
---@return table|nil data
function Extras.approvalGate(org, member, actor, contractId, opts, gate)
    if not on('AcceptApproval') then return nil end
    if type(opts) == 'table' and opts.staffAssigned then return nil end
    local d = deps()
    local worth
    local function value()
        worth = worth or worthOf(contractId)
        return worth
    end
    local onProbation = type(gate) == 'table' and gate.probation
    local k = key(contractId, actor.cid)
    if Approved[k] then return nil end
    local above = math.floor(tonumber(Config.Organisation.ApprovalAbove) or 0)
    local needs = value() > above or (onProbation and Config.Organisation.ApprovalProbation ~= false)
    if not needs then return nil end
    local wait = minutes('ApprovalMinutes', 15, 1440)
    local held = Pending[k]
    if held and held.expires > now() then
        return 'org_approval', { message = O.message('org_approval'), pending = true,
            expiresIn = held.expires - now() }
    end
    -- What the page showed, kept to be checked again when it is approved;
    -- nothing else of the request.
    local kept = {}
    if type(opts) == 'table' then
        kept.checkDisclosure = opts.checkDisclosure == true or nil
        kept.disclosed = tonumber(opts.disclosed)
        kept.shownBand = type(opts.shownBand) == 'string' and opts.shownBand:sub(1, 16) or nil
        kept.shown = type(opts.shown) == 'table' and Util.copy(opts.shown) or nil
    end
    MessageSeq = MessageSeq + 1
    Pending[k] = { id = ('ap%d_%d'):format(MessageSeq, math.random(1000, 9999)), contractId = contractId, org = org.id,
        cid = actor.cid, anonymous = type(gate) == 'table' and gate.anonymous == true, opts = kept,
        worth = value(), probation = onProbation and true or nil, at = now(), expires = now() + wait * 60 }
    d.audit.action('org_accept_requested', actor.cid, contractId, { org = org.id, worth = value() })
    for cid in pairs(org.members) do
        if cid ~= actor.cid and O.Engine.holds(org, cid, 'K6') then
            tell(cid, L('org_extras.a_member_asks_to_take_a'))
        end
    end
    return 'org_approval', { message = O.message('org_approval'), pending = true, expiresIn = wait * 60 }
end

--- The accepts waiting for approval, each by its id.
local function pendingById(id)
    if type(id) ~= 'string' or #id > 24 then return nil end
    for k, p in pairs(Pending) do
        if p.id == id then return k, p end
    end
    return nil
end

--- Approve (the accept runs now, every rule checked again) or refuse one
--- (K6). Never one's own. The member is told either way.
function Org.decideAccept(who, id, approve)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('AcceptApproval') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'K6')
    if err then return fail(err) end
    if type(approve) ~= 'boolean' then return fail(ERR.INVALID) end
    local k, p = pendingById(id)
    if not p or p.expires <= now() then return fail(ERR.NOT_FOUND) end
    if not org.members[p.cid] then
        Pending[k] = nil
        return fail(ERR.NOT_FOUND)
    end
    local why = mayActOn(org, who, p.cid)
    if why then return fail(why) end
    Pending[k] = nil
    if not approve then
        kit.record('org_accept_refused', who, { member = p.cid }, p.contractId)
        tell(p.cid, L('org_extras.a_boss_refused_your_accept_nothing'))
        return true, nil, { approved = false }
    end
    local d = deps()
    local actor = d.identity.byCitizenId(p.cid)
    if not actor then
        return fail(ERR.RULE, { message = L('org_extras.they_are_not_in_the_city') })
    end
    Approved[k] = true
    local ran, ok, refusal = pcall(d.contracts.accept, actor, p.contractId, p.anonymous, Util.copy(p.opts))
    Approved[k] = nil
    if not ran or not ok then
        local code = ran and refusal or 'server_error'
        kit.record('org_accept_approved', who, { member = p.cid, refused = tostring(code) }, p.contractId)
        tell(p.cid, L('org_extras.your_accept_was_approved_but_the'))
        return fail(ERR.RULE, { message = L('org_extras.approved_but_the_contract_would_not') .. tostring(code)
            .. L('org_extras.nothing_was_taken') })
    end
    kit.record('org_accept_approved', who, { member = p.cid }, p.contractId)
    tell(p.cid, L('org_extras.a_boss_approved_your_accept_the'))
    return true, nil, { approved = true }
end

-- ============================================================================
--                              R5: DUTY
-- ============================================================================

--- Whether a member is on duty: always true while Duty is off.
---@return boolean
function Extras.onDuty(cid)
    if not on('Duty') then return true end
    return OnDuty[cid] ~= nil
end

--- Told to qbx_core where the job is the player's primary one.
local function tellFramework(src, value)
    local framework = Integrations.get('framework')
    if not (framework and framework.SetJobDuty and src) then return end
    local org = O.current()
    local d = deps()
    local actor = d.identity.resolve and d.identity.resolve(src)
    if not (org and actor and type(actor.job) == 'table' and actor.job.name == org.job) then return end
    if (actor.job.onduty == true) == value then return end
    pcall(framework.SetJobDuty, src, value)
end

--- Clock in or out (any member, themselves): in only at the office where
--- DutyAtOffice says so.
---@param actor table { cid, source }
---@param value boolean
function Org.setDuty(actor, value)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Duty') then return fail(ERR.FEATURE_OFF) end
    if type(actor) ~= 'table' or not org.members[actor.cid] then return fail(ERR.NOT_MEMBER) end
    if type(value) ~= 'boolean' then return fail(ERR.INVALID) end
    if (OnDuty[actor.cid] ~= nil) == value then return fail(ERR.ALREADY) end
    if value and Config.Organisation.DutyAtOffice == true and not O.inOffice(org, actor.source) then
        return fail(ERR.OFFICE, { message = L('org_extras.you_go_on_duty_at_the') })
    end
    OnDuty[actor.cid] = value and now() or nil
    tellFramework(actor.source, value)
    rebuild()
    deps().audit.action('org_duty', actor.cid, nil, { org = org.id, on = value })
    return true, nil, { onDuty = value }
end

--- Send a member off duty (M9; staff anybody).
function Org.forceOffDuty(who, cid)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Duty') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'M9')
    if err then return fail(err) end
    if type(cid) ~= 'string' or not org.members[cid] then return fail(ERR.NOT_FOUND) end
    local why = mayActOn(org, who, cid)
    if why then return fail(why) end
    if not OnDuty[cid] then return fail(ERR.ALREADY) end
    OnDuty[cid] = nil
    local d = deps()
    local actor = d.identity.byCitizenId(cid)
    if actor then tellFramework(actor.source, false) end
    rebuild()
    kit.record('org_duty_forced', who, { member = cid })
    tell(cid, L('org_extras.a_boss_sent_you_off_duty'))
    return true
end

--- qbx_core's own duty change (QBCore:Server:SetDuty, a server event,
--- server/bridges.lua): taken in where the job is the organisation's.
function Extras.frameworkDuty(src, value)
    if not on('Duty') then return end
    local org = O.current()
    local d = deps()
    local actor = d.identity.resolve and d.identity.resolve(src)
    if not (org and actor and org.members[actor.cid] and type(actor.job) == 'table' and actor.job.name == org.job) then
        return
    end
    local want = value == true
    if (OnDuty[actor.cid] ~= nil) == want then return end
    if want and Config.Organisation.DutyAtOffice == true and not O.inOffice(org, actor.source) then return end
    OnDuty[actor.cid] = want and now() or nil
    rebuild()
    d.audit.action('org_duty', actor.cid, nil, { org = org.id, on = want, by = 'qbx' })
end

--- A character in again starts off duty.
function Extras.playerLoaded(cid)
    if OnDuty[cid] then
        OnDuty[cid] = nil
        rebuild()
    end
end

-- ============================================================================
--                              R7: THE CHANNEL
-- ============================================================================

local function retention() return minutes('ChannelRetentionDays', 7, 365) * 86400 end

--- The channel's rows, read once (with the switch on), the old ones gone.
local function messages(org)
    if Messages[org.id] then return Messages[org.id] end
    local rows = {}
    local ok, read = pcall(deps().storage.readOrgRows, 'messages', org.id)
    local oldest = now() - retention()
    for _, row in ipairs(ok and read or {}) do
        if (tonumber(row.created_at) or 0) < oldest then
            pcall(deps().storage.deleteOrgRow, 'messages', row.id)
        else
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        if a.created_at ~= b.created_at then return (a.created_at or 0) < (b.created_at or 0) end
        return tostring(a.id) < tostring(b.id)
    end)
    while #rows > KEEP do table.remove(rows, 1) end
    Messages[org.id] = rows
    return rows
end

local function muteOf(org, cid)
    local untilAt = tonumber(org.settings.channelMutes[cid])
    if untilAt and untilAt > now() then return untilAt end
    return nil
end

--- Post a message (any member not muted; staff as 'Staff').
function Org.channelPost(who, text)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Channel') then return fail(ERR.FEATURE_OFF) end
    local member = not who.staff and org.members[who.cid]
    if not who.staff and not member then return fail(ERR.NOT_MEMBER) end
    local max = math.max(1, math.min(1000, math.floor(tonumber(Config.Organisation.ChannelMaxLength) or 300)))
    local body = plain(text, max)
    if not body then
        return fail(ERR.INVALID, { message = (L('org_extras.plain_text_up_to_characters_no')):format(max) })
    end
    if member then
        local muted = muteOf(org, who.cid)
        if muted then
            return fail(ERR.LOCKED, { message = L('org_extras.a_boss_muted_you_in_the'), untilAt = muted })
        end
        local most = math.max(1, math.floor(tonumber(Config.Organisation.ChannelPerMinute) or 6))
        if not Sent.take(who.cid, most, now()) then return fail(ERR.COOLDOWN) end
    end
    local list = messages(org)
    MessageSeq = MessageSeq + 1
    local from = who.staff and L('org_extras.staff') or ((O.codenamesOn() and member.codename)
        and O.codenameLabel(member.codename) or member.name)
    local row = { id = ('msg:%s:%d:%d'):format(org.id, now(), MessageSeq):sub(1, 64), org_id = org.id,
        cid = who.staff and 'staff' or who.cid, name = tostring(from or L('org_extras.a_member')):sub(1, 64), body = body,
        created_at = now() }
    local ok = pcall(deps().storage.writeOrgRow, 'messages', row)
    if not ok then return fail(ERR.REFUSED, { message = L('org_extras.the_message_could_not_be_kept') }) end
    list[#list + 1] = row
    while #list > KEEP do table.remove(list, 1) end
    -- The record keeps who and how long, never the words.
    kit.record('org_channel_post', who, { length = #body })
    return true, nil, { id = row.id }
end

--- The newest messages (`limit`, at most 100), oldest first. A member sees
--- who wrote each as the channel shows them; a boss holding N3 gets each
--- writer's handle to mute them; staff see the citizen too.
function Org.channelRead(who, limit)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Channel') then return fail(ERR.FEATURE_OFF) end
    if not who.staff and not org.members[who.cid] then return fail(ERR.NOT_MEMBER) end
    local list = messages(org)
    limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 50)))
    local moderator = who.staff or O.Engine.holds(org, who.cid, 'N3')
    local viewer = who.staff and (who.cid or 'staff') or who.cid
    local out = {}
    for i = math.max(1, #list - limit + 1), #list do
        local m = list[i]
        local row = { id = m.id, from = m.name, body = m.body, at = m.created_at,
            mine = (not who.staff and m.cid == who.cid) or nil }
        if moderator and org.members[m.cid] and m.cid ~= who.cid then row.member = O.refFor(viewer, m.cid) end
        if who.staff then row.staff = m.cid == 'staff' or nil end
        out[#out + 1] = row
    end
    return true, nil, { rows = out, muted = not who.staff and muteOf(org, who.cid) or nil,
        maxLength = math.floor(tonumber(Config.Organisation.ChannelMaxLength) or 300) }
end

--- Remove a message (N3; staff any). A boss removes only a message of a
--- member below them, or their own.
function Org.channelRemove(who, id)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Channel') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'N3')
    if err then return fail(err) end
    if type(id) ~= 'string' or #id > 64 then return fail(ERR.INVALID) end
    local list = messages(org)
    for i, m in ipairs(list) do
        if m.id == id then
            if not who.staff and m.cid ~= who.cid then
                if m.cid == 'staff' then return fail(ERR.LOCKED) end
                if org.members[m.cid] then
                    local why = mayActOn(org, who, m.cid)
                    if why then return fail(why) end
                end
            end
            pcall(deps().storage.deleteOrgRow, 'messages', id)
            table.remove(list, i)
            kit.record('org_channel_removed', who, { member = org.members[m.cid] and m.cid or nil })
            return true
        end
    end
    return fail(ERR.NOT_FOUND)
end

--- Mute a member in the channel for some hours (0 lifts it). A boss (N3):
--- below them, up to Limits.ChannelMuteMaxHours.
function Org.channelMute(who, cid, hours)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Channel') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'N3')
    if err then return fail(err) end
    if type(cid) ~= 'string' or not org.members[cid] then return fail(ERR.NOT_FOUND) end
    hours = tonumber(hours)
    if not hours or hours ~= math.floor(hours) or hours < 0 or hours > 720 then return fail(ERR.INVALID) end
    local why = mayActOn(org, who, cid)
    if why then return fail(why) end
    if not who.staff and hours > O.Powers.limit(org, 'ChannelMuteMaxHours') then return fail(ERR.BOUNDS) end
    org.settings.channelMutes[cid] = hours > 0 and (now() + hours * 3600) or nil
    kit.save()
    kit.record('org_channel_mute', who, { member = cid, hours = hours })
    tell(cid, hours > 0 and (L('org_extras.a_boss_muted_you_in_the_2')):format(hours)
        or L('org_extras.you_may_write_in_the_organisation'))
    return true
end

-- ============================================================================
--                              R8: DOSSIERS
-- ============================================================================

Extras.RULES = { discreet = L('org_extras.discreet_no_witnesses_nothing_in_public'), clean = L('org_extras.clean_the_target_only'),
    open = L('org_extras.open_whatever_it_takes') }

--- Attach a briefing to an assigned organisation contract (K7), or clear
--- it (spec false). notes (plain text, DossierMaxLength), spot (one of the
--- organisation's meeting spots), rules (Extras.RULES).
function Org.writeDossier(who, contractId, spec)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Dossiers') or not on('OrgContracts') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'K7')
    if err then return fail(err) end
    local entry = type(contractId) == 'string' and org.settings.orgContracts[contractId]
    if not entry or entry.state == 'waiting' then
        return fail(ERR.NOT_FOUND, { message = L('org_extras.only_a_contract_assigned_to_a') })
    end
    if spec == false then
        entry.dossier = nil
        kit.save()
        kit.record('org_dossier', who, { cleared = true }, contractId)
        return true
    end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    local dossier = {}
    if spec.notes ~= nil and spec.notes ~= false then
        local max = math.max(1, math.min(2000, math.floor(tonumber(Config.Organisation.DossierMaxLength) or 600)))
        local notes = plain(spec.notes, max)
        if not notes then
            return fail(ERR.INVALID, { message = (L('org_extras.plain_text_up_to_characters_no')):format(max) })
        end
        -- Nothing a hitman is not already shown: never a citizen id of the
        -- contract's parties.
        local contract = deps().storage.readContract(contractId)
        local lower = notes:lower()
        for _, cid in ipairs({ contract and contract.target_cid, contract and contract.creator_cid }) do
            if type(cid) == 'string' and #cid > 2 and lower:find(cid:lower(), 1, true) then
                return fail(ERR.RULE, { message = L('org_extras.a_dossier_never_carries_a_citizen') })
            end
        end
        dossier.notes = notes
    end
    if spec.spot ~= nil and spec.spot ~= false then
        local spot = type(spec.spot) == 'string' and org.locations[spec.spot]
        if not spot or spot.kind ~= 'meeting' or spot.enabled == false then
            return fail(ERR.NOT_FOUND, { message = L('org_extras.pick_one_of_the_organisations_meeting') })
        end
        dossier.spot = spec.spot
    end
    if spec.rules ~= nil and spec.rules ~= false then
        if type(spec.rules) ~= 'string' or not Extras.RULES[spec.rules] then return fail(ERR.INVALID) end
        dossier.rules = spec.rules
    end
    if not next(dossier) then return fail(ERR.INVALID, { message = L('org_extras.write_notes_or_pick_a_spot') }) end
    dossier.by, dossier.at = who.staff and 'staff' or 'boss', now()
    entry.dossier = dossier
    kit.save()
    kit.record('org_dossier', who, { notes = dossier.notes and #dossier.notes or nil, spot = dossier.spot,
        rules = dossier.rules, member = entry.cid }, contractId)
    if entry.cid then tell(entry.cid, L('org_extras.a_boss_attached_a_dossier_to')) end
    return true
end

--- A dossier as its hitman (or a boss) reads it.
local function dossierView(org, dossier)
    if type(dossier) ~= 'table' or not on('Dossiers') then return nil end
    local spot = dossier.spot and org.locations[dossier.spot]
    return { notes = dossier.notes, rules = dossier.rules, rulesText = dossier.rules and Extras.RULES[dossier.rules],
        spot = spot and { id = spot.id, label = spot.label or L('org_extras.meeting_spot') } or nil, at = dossier.at }
end

-- ============================================================================
--                              READS
-- ============================================================================

--- A contract as the organisation sees it: what any board card shows (the
--- target's name, the worth, the rule, the mode, whether it is staked),
--- never who placed it.
local function contractView(org, viewer, id, entry, contract)
    local worth = worthOf(id)
    local member = entry.cid and org.members[entry.cid]
    return { id = id, state = entry.state, expiresIn = entry.state ~= 'taken' and math.max(0, entry.expires - now())
        or nil, targetName = contract and contract.target_name or nil, worth = worth,
        rule = contract and contract.fulfilment_rule or nil, mode = contract and contract.mode or nil,
        staked = contract and (tonumber(contract.penalty_amount) or 0) > 0 or nil,
        member = member and { ref = O.refFor(viewer, entry.cid), name = (O.codenamesOn() and member.codename)
            or member.name } or nil,
        dossier = dossierView(org, entry.dossier) }
end

--- The organisation's work, for a boss holding K4, K5, K6 or K7 (or
--- staff): its contracts, the accepts waiting, who may be assigned and
--- the meeting spots a dossier may name.
function Org.work(who)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    local held = {}
    for _, code in ipairs({ 'K4', 'K5', 'K6', 'K7' }) do
        held[code] = who.staff or O.Engine.holds(org, who.cid, code)
    end
    if not who.staff and not org.members[who.cid] then return fail(ERR.NOT_MEMBER) end
    local contractsOn, approvalOn = on('OrgContracts'), on('AcceptApproval')
    if not ((contractsOn and (held.K4 or held.K5 or held.K7)) or (approvalOn and held.K6)) then
        if not contractsOn and not approvalOn then return fail(ERR.FEATURE_OFF) end
        return fail(ERR.NO_POWER)
    end
    local viewer = who.staff and (who.cid or 'staff') or who.cid
    local out = { contracts = nil, approvals = nil, members = nil, spots = nil, rules = nil }
    if contractsOn and (held.K4 or held.K5 or held.K7) then
        out.contracts = {}
        local d = deps()
        for id, entry in pairs(org.settings.orgContracts) do
            out.contracts[#out.contracts + 1] = contractView(org, viewer, id, entry, d.storage.readContract(id))
        end
        table.sort(out.contracts, function(a, b) return a.id < b.id end)
        if held.K4 or held.K5 then
            out.members = {}
            for cid, m in pairs(org.members) do
                if not (m.suspended_until and m.suspended_until > now()) then
                    out.members[#out.members + 1] = { ref = O.refFor(viewer, cid),
                        name = (O.codenamesOn() and m.codename) or m.name, grade = m.grade,
                        onDuty = on('Duty') and OnDuty[cid] ~= nil or nil,
                        probation = Extras.probation(org, m, false) and true or nil }
                end
            end
            table.sort(out.members, function(a, b)
                if a.grade ~= b.grade then return a.grade > b.grade end
                return tostring(a.name) < tostring(b.name)
            end)
        end
        if held.K7 and on('Dossiers') then
            out.spots, out.rules = {}, {}
            for id, l in pairs(org.locations) do
                if l.kind == 'meeting' and l.enabled ~= false then
                    out.spots[#out.spots + 1] = { id = id, label = l.label or L('org_extras.meeting_spot') }
                end
            end
            table.sort(out.spots, function(a, b) return a.id < b.id end)
            for code, text in pairs(Extras.RULES) do out.rules[#out.rules + 1] = { value = code, label = text } end
            table.sort(out.rules, function(a, b) return a.value < b.value end)
        end
    end
    if approvalOn and held.K6 then
        out.approvals = {}
        for k, p in pairs(Pending) do
            if p.expires <= now() then
                Pending[k] = nil
            elseif org.members[p.cid] then
                local m = org.members[p.cid]
                out.approvals[#out.approvals + 1] = { id = p.id, contractId = p.contractId, worth = p.worth,
                    probation = p.probation, expiresIn = p.expires - now(),
                    member = { ref = O.refFor(viewer, p.cid), name = (O.codenamesOn() and m.codename) or m.name },
                    own = (not who.staff and p.cid == who.cid) or nil }
            end
        end
        table.sort(out.approvals, function(a, b) return a.expiresIn < b.expiresIn end)
    end
    return true, nil, out
end

--- What a member's own tab adds, each only while its switch is on.
---@param out table Org.mine's reply, added to
function Extras.mine(org, member, out)
    if not member then return end
    local cid = member.cid
    if on('Duty') then
        out.dutyOn = true
        out.duty = { on = OnDuty[cid] ~= nil, atOffice = Config.Organisation.DutyAtOffice == true or nil }
    end
    if on('Probation') then
        out.probationOn = true
        local p = Extras.probation(org, member, false)
        if p then
            out.probation = { done = p.done, need = p.need,
                maxReward = math.floor(tonumber(Config.Organisation.ProbationMaxReward) or 0),
                noStake = Config.Organisation.ProbationNoStake ~= false or nil }
        end
    end
    if on('OrgContracts') then
        out.orgContracts = true
        out.dossiers = on('Dossiers') or nil
        if Extras.onDuty(cid) then
            local rows = {}
            for id, entry in pairs(org.settings.orgContracts) do
                if entry.cid == cid and entry.state ~= 'waiting' then
                    local contract = deps().storage.readContract(id)
                    rows[#rows + 1] = { id = id, state = entry.state, targetName = contract and contract.target_name,
                        expiresIn = entry.state == 'assigned' and math.max(0, entry.expires - now()) or nil,
                        dossier = dossierView(org, entry.dossier) }
                end
            end
            table.sort(rows, function(a, b) return a.id < b.id end)
            out.assigned = rows
        end
    end
    if on('AcceptApproval') then
        out.approval = true
        local waiting = {}
        for _, p in pairs(Pending) do
            if p.cid == cid and p.expires > now() then
                waiting[#waiting + 1] = { contractId = p.contractId, expiresIn = p.expires - now() }
            end
        end
        out.waiting = next(waiting) and waiting or nil
    end
    if on('Channel') then
        out.channel = true
        out.channelMuted = muteOf(org, cid)
    end
end

--- What a member is in the roster, each only while its switch is on.
function Extras.memberView(org, m, out)
    if on('Duty') then out.onDuty = OnDuty[m.cid] ~= nil end
    if on('Probation') then
        local p = Extras.probation(org, m, false)
        out.probation = p and { done = p.done, need = p.need } or nil
    end
    if on('Channel') then out.channelMuted = muteOf(org, m.cid) end
end

--- What the panel's orgGet adds: each feature on, and its state.
function Extras.staffView(org, viewer, out)
    local any = false
    local view = {}
    for _, name in ipairs({ 'OrgContracts', 'AcceptApproval', 'Probation', 'Duty', 'Channel', 'Dossiers' }) do
        view[name] = on(name) or nil
        any = any or on(name)
    end
    if not any then return end
    if on('OrgContracts') or on('AcceptApproval') then
        local _, _, work = O.work({ staff = true, cid = viewer })
        view.work = work
    end
    if on('Channel') then
        local _, _, read = O.channelRead({ staff = true, cid = viewer }, 50)
        view.channel = read and read.rows or {}
    end
    out.extras = view
end

-- ============================================================================
--                              THE TICK
-- ============================================================================

--- Once a minute at most: organisation contracts whose time ran out go to
--- the open board, those that ended are forgotten, approvals run out, the
--- duty of players gone is ended, and the channel's old messages go.
---@param at integer|nil os.time()
local tickOne

function Org.extrasTick(at)
    if not Feature.on('Organisation') then return end
    at = at or now()
    if at - LastTick < 30 then return end
    LastTick = at
    if not O.current() then return end
    -- Each organisation in turn (SeveralOrganisations), then the channel's
    -- pruning clock once for all.
    local prune = on('Channel') and at - LastPrune >= 3600
    for _, org in ipairs(O.all()) do O.within(org, tickOne, org, at, prune) end
    if prune then
        LastPrune = at
        Sent.sweep(at)
    end
end

tickOne = function(org, at, prune)
    local d = deps()
    if next(org.settings.orgContracts) then
        if not on('OrgContracts') then
            -- Turned off: every one on the open board.
            for id in pairs(org.settings.orgContracts) do release(org, id, 'off') end
        else
            local ids = {}
            for id in pairs(org.settings.orgContracts) do ids[#ids + 1] = id end
            for _, id in ipairs(ids) do
                local entry = org.settings.orgContracts[id]
                local contract = d.storage.readContract(id)
                if not contract or CH.TERMINAL[contract.state] then
                    release(org, id, 'ended')
                elseif entry.state == 'assigned' and not org.members[entry.cid] then
                    -- Its member left or was fired: on the open board.
                    release(org, id, 'left')
                elseif entry.state ~= 'taken' and entry.expires <= at then
                    release(org, id, 'timeout')
                    d.audit.action('org_contract_released', nil, id, { org = org.id, reason = 'timeout' })
                elseif entry.state == 'taken' and contract.state == CH.STATE.ACTIVE then
                    -- Taken and walked away from: back to the open board.
                    local hitman = d.storage.readHitman and d.storage.readHitman(id, entry.cid)
                    if not hitman or hitman.state ~= 'active' then release(org, id, 'ended') end
                end
            end
        end
    end
    for k, p in pairs(Pending) do
        if (p.org == nil or p.org == org.id) and (p.expires <= at or not on('AcceptApproval')) then
            Pending[k] = nil
            d.audit.action('org_accept_expired', p.cid, p.contractId, { org = org.id })
            tell(p.cid, L('org_extras.nobody_approved_your_accept_in_time'))
        end
    end
    local changed = false
    for cid in pairs(OnDuty) do
        -- A member of another organisation is that one's to keep.
        local theirs = O.orgOf(cid)
        if (theirs == nil or theirs == org)
            and (not on('Duty') or not org.members[cid] or not d.identity.byCitizenId(cid)) then
            OnDuty[cid] = nil
            changed = true
        end
    end
    if changed then rebuild() end
    -- Organisation extras 3: drops, garage vehicles, requests.
    O.Extras3.tick(org, at)
    local rows = Messages[org.id]
    if prune and rows then
        local oldest = at - retention()
        while rows[1] and (tonumber(rows[1].created_at) or 0) < oldest do
            pcall(d.storage.deleteOrgRow, 'messages', rows[1].id)
            table.remove(rows, 1)
        end
    end
end

-- ============================================================================
--                              WIRING
-- ============================================================================

--- The board's settings: whether a placer may send to the organisation.
local function boardSettings(settings)
    if not on('OrgContracts') then return end
    local org = O.current()
    if not org then return end
    settings.orgContracts = { label = org.label, minutes = minutes('AssignMinutes', 30, 1440) }
    -- Several organisations: the placer picks which one (their labels and
    -- ids, the ids being the qbx_core job names every player sees anyway).
    if O.severalOn() and #O.all() > 1 then
        local list = {}
        for _, o in ipairs(O.all()) do list[#list + 1] = { id = o.id, label = o.label } end
        settings.orgContracts.orgs = list
    end
end

--- Wire into the organisation (server/org/init.lua): `k` is its own
--- helpers (fail, record, save, deps).
function Extras.attach(o, k)
    O, kit = o, k
    for name, fn in pairs(Org) do o[name] = fn end
end

--- A fresh start (Org.init).
function Extras.init(d)
    Pending, Approved, OnDuty, Messages, MessageSeq = {}, {}, {}, {}, 0
    LastTick, LastPrune = 0, 0
    Sent.reset()
    if d.projection then
        d.projection.reserved = nil
        if d.projection.settingsExtenders then d.projection.settingsExtenders.org = boardSettings end
    end
    if d.settings and d.settings.watch then
        d.settings.watch('Organisation.OrgContracts', rebuild)
        d.settings.watch('Organisation.Duty', rebuild)
    end
end

--- The organisation (re)loaded: the board's filter from what it holds.
function Extras.loaded()
    Messages = {}
    rebuild()
end

--- The start-up check of the extras' settings (Feature.check: a value it
--- cannot take is put back to the shipped one, and said).
Extras.CHECKS = {
    OrgContracts = { kind = 'switch' }, AssignMinutes = { kind = 'number', integer = true, min = 1, max = 1440 },
    AcceptApproval = { kind = 'switch' }, ApprovalAbove = { kind = 'number', integer = true, min = 0, max = 2000000000 },
    ApprovalProbation = { kind = 'switch' }, ApprovalMinutes = { kind = 'number', integer = true, min = 1, max = 1440 },
    Probation = { kind = 'switch' }, ProbationMaxGrade = { kind = 'number', integer = true, min = 0, max = 100 },
    ProbationCompletions = { kind = 'number', integer = true, min = 0, max = 1000 },
    ProbationMaxReward = { kind = 'number', integer = true, min = 0, max = 2000000000 },
    ProbationNoStake = { kind = 'switch' },
    Duty = { kind = 'switch' }, DutyAtOffice = { kind = 'switch' },
    Channel = { kind = 'switch' }, ChannelRetentionDays = { kind = 'number', integer = true, min = 1, max = 365 },
    ChannelMaxLength = { kind = 'number', integer = true, min = 1, max = 1000 },
    ChannelPerMinute = { kind = 'number', integer = true, min = 1, max = 60 },
    Dossiers = { kind = 'switch' }, DossierMaxLength = { kind = 'number', integer = true, min = 1, max = 2000 },
}

---@param warn string[]
function Extras.validate(warn)
    Feature.check('Organisation', Extras.CHECKS, warn)
end

return Extras
