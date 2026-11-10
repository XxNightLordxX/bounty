--- Payout checks: the one ordered list of what may hold a payout once a
--- completion has gone through, over the one hold the escrow already has.
---
--- A completion is proven its own way (a verified kill, a live handover,
--- a proof item, the placer's Confirm handover), and every one of them ends
--- in the one settle path, Contracts.claimSlot: the claim's checks there
--- (Contracts' claimRefusal) decide whether it pays at all. What this list
--- holds is when the money moves: a payout the claim released waits in
--- escrow, owed to the hitman and queued, until no check in the list holds
--- it, and the escrow's own retry gives it then (Escrow.deliver asks
--- Payout.holds before every give). Nothing here moves money.
---
--- The checks, in order, each its own feature with its own settings:
---   * 'disposal' (server/disposal.lua, Config.Disposal): a verified kill's
---     baseline waits for the body to be dropped off;
---   * 'intent' (server/rp_intent.lua, Config.Roleplay.ProofOfIntent): a
---     payout waits until the hitman showed intent, at most HoldMaxMinutes.
--- Each check is a table of any of:
---   holds(recipientCid, line) -> boolean    the give waits
---   releasesAt(recipientCid, line) -> int?  when it is released anyway
---   onClaim(contract, hitmanCid, fulfilment, opts) -> any
---       asked by the claim under its lock, before the money is released;
---       the first answer that is not nil is the claim's intentHold
---   afterClaim(contractId, hitmanCid, claimed)
---       the claim has ended (claimed: it went through, or raised part-way)
--- Every call is protected: a check that raises holds nothing and stops no
--- other check, and never stops a claim.

local Log = CrimsonBoot.requireShared('log')

local Payout = {}

--- The order the checks are asked in.
Payout.ORDER = { 'disposal', 'intent' }

--- [name] = check
local checks = {}

local function ask(name, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then
        Log.debug(('payout check %s raised: %s'):format(name, tostring(a)))
        return nil
    end
    return a, b
end

--- Whether any check holds this give, and which.
---@param recipientCid string
---@param line table
---@return boolean held
---@return string|nil by
function Payout.holds(recipientCid, line)
    for _, name in ipairs(Payout.ORDER) do
        local check = checks[name]
        if check and check.holds and ask(name, check.holds, recipientCid, line) then return true, name end
    end
    return false
end

--- When the hold on this give is released anyway (os.time()), from the
--- first check that holds it and says, or nil.
---@return integer|nil
function Payout.releasesAt(recipientCid, line)
    for _, name in ipairs(Payout.ORDER) do
        local check = checks[name]
        if check and check.releasesAt then
            local at = ask(name, check.releasesAt, recipientCid, line)
            if at ~= nil then return at end
        end
    end
    return nil
end

--- The claim is about to release a payout (Contracts.claimSlot, under its
--- lock): every check is told, in order. The first answer is the hold.
function Payout.onClaim(contract, hitmanCid, fulfilment, opts)
    local hold
    for _, name in ipairs(Payout.ORDER) do
        local check = checks[name]
        if check and check.onClaim then
            local answer = ask(name, check.onClaim, contract, hitmanCid, fulfilment, opts)
            if hold == nil then hold = answer end
        end
    end
    return hold
end

--- The claim has ended: every check is told, in order.
function Payout.afterClaim(contractId, hitmanCid, claimed)
    for _, name in ipairs(Payout.ORDER) do
        local check = checks[name]
        if check and check.afterClaim then ask(name, check.afterClaim, contractId, hitmanCid, claimed) end
    end
end

--- Put a check in the list (its feature's init), and point the escrow's
--- gate and the claim's hooks at the list. A name not in ORDER is refused.
---@param name string
---@param check table
---@param deps table|nil { escrow, contracts }
function Payout.add(name, check, deps)
    local known = false
    for _, n in ipairs(Payout.ORDER) do if n == name then known = true end end
    assert(known, 'not a payout check: ' .. tostring(name))
    checks[name] = check
    deps = deps or {}
    if deps.escrow then
        deps.escrow.holdBack = Payout.holds
        deps.escrow.holdUntil = Payout.releasesAt
    end
    if deps.contracts then
        deps.contracts.payoutOnClaim = Payout.onClaim
        deps.contracts.payoutAfterClaim = Payout.afterClaim
    end
end

return Payout
