--- Crimson Bounty System — shared constants.
--- Loaded on both sides. Contains no state.

CB = CB or {}

CB.STATE = {
    ACTIVE     = 'active',     -- listed, no hunter yet
    ACCEPTED   = 'accepted',   -- at least one hunter holds it
    COMPLETING = 'completing', -- a fulfilment is settling; persisted before funds move
    COMPLETED  = 'completed',
    BAILED_OUT = 'bailed_out',
    EXPIRED    = 'expired',
    CANCELLED  = 'cancelled',
    VOIDED     = 'voided',     -- admin
}

--- Terminal states release escrow exactly once and never transition again.
CB.TERMINAL = {
    [CB.STATE.COMPLETED]  = true,
    [CB.STATE.BAILED_OUT] = true,
    [CB.STATE.EXPIRED]    = true,
    [CB.STATE.CANCELLED]  = true,
    [CB.STATE.VOIDED]     = true,
}

--- Legal transitions. Anything absent here is rejected by contracts.transition().
CB.TRANSITIONS = {
    [CB.STATE.ACTIVE] = {
        [CB.STATE.ACCEPTED]   = true,
        [CB.STATE.CANCELLED]  = true,
        [CB.STATE.EXPIRED]    = true,
        [CB.STATE.BAILED_OUT] = true,
        [CB.STATE.VOIDED]     = true,
    },
    [CB.STATE.ACCEPTED] = {
        [CB.STATE.ACTIVE]     = true, -- last hunter abandoned an exclusive contract
        [CB.STATE.COMPLETING] = true,
        [CB.STATE.CANCELLED]  = true,
        [CB.STATE.EXPIRED]    = true,
        [CB.STATE.BAILED_OUT] = true,
        [CB.STATE.VOIDED]     = true,
    },
    [CB.STATE.COMPLETING] = {
        [CB.STATE.COMPLETED] = true,
        [CB.STATE.ACCEPTED]  = true, -- settlement failed and was rolled back
    },
}

CB.ESCROW_STATE = { HELD = 'held', RELEASING = 'releasing', SETTLED = 'settled' }

CB.SOURCE = {
    CASH   = 'cash',
    BANK   = 'bank',
    DIRTY  = 'dirty',
    ITEM   = 'item',
    WEAPON = 'weapon',
}

CB.MONEY_SOURCES = { cash = true, bank = true, dirty = true }

--- The subset of those that are qbx_core accounts.
---
--- Dirty money is not one: it is an ox_inventory item, moved with AddItem
--- and RemoveItem. Anywhere a config setting names an account that is handed
--- straight to AddMoney or RemoveMoney — a fee, a purchase price — naming
--- 'dirty' there does not charge black money, it charges nothing and reports
--- failure, which reads as the feature being broken.
CB.MONEY_ACCOUNTS = { cash = true, bank = true }

--- A stake is escrow held from the *hunter*, not the creator: the failure
--- penalty they agreed to when accepting an exclusive contract (§3.6).
---
--- An owed line is money already promised to one named person — a premium
--- for an offline creator, a refund for an offline target. It is its own
--- portion so that no general release can sweep it up by accident.
CB.PORTION = {
    BASELINE = 'baseline', BONUS = 'bonus', STAKE = 'stake', OWED = 'owed',
}

CB.MODE = { EXCLUSIVE = 'exclusive', COMPETITIVE = 'competitive' }

CB.FULFILMENT = { ELIMINATION = 'elimination', KIDNAPPING = 'kidnapping' }

CB.AMENDMENT = {
    ADD_ESCROW       = 'add_escrow',
    RAISE_BONUS      = 'raise_bonus',
    EXTEND_DEADLINE  = 'extend_deadline',
    LOWER_PENALTY    = 'lower_penalty',
    -- material, require approval
    REDUCE_REWARD    = 'reduce_reward',
    SHORTEN_DEADLINE = 'shorten_deadline',
    RAISE_PENALTY    = 'raise_penalty',
    CHANGE_MODE      = 'change_mode',
    CHANGE_REASON    = 'change_reason',
    WITHDRAW         = 'withdraw',
    CANCEL           = 'cancel',
}

--- Additive amendments apply immediately: they can only benefit the hunter (§12.1).
CB.ADDITIVE = {
    [CB.AMENDMENT.ADD_ESCROW]      = true,
    [CB.AMENDMENT.RAISE_BONUS]     = true,
    [CB.AMENDMENT.EXTEND_DEADLINE] = true,
    [CB.AMENDMENT.LOWER_PENALTY]   = true,
}

CB.ERR = {
    NO_PLAYER        = 'no_player',
    BLACKLISTED_JOB  = 'blacklisted_job',
    RATE_LIMITED     = 'rate_limited',
    NOT_FOUND        = 'not_found',
    BAD_STATE        = 'bad_state',
    --- The server has no kill by this hunter on this contract to verify.
    ---
    --- Shared bad_state until now, which the page words as "Not right now."
    --- That is the answer to the MOST COMMON tap of Verify kill: the button
    --- is drawn on every accepted contract whether or not a kill has
    --- happened, so the ordinary case — tapping it before the kill, or after
    --- one the server did not attribute — was four words that explain
    --- nothing about a mechanic with a distance rule and a time limit.
    NO_KILL_TO_VERIFY = 'no_kill_to_verify',
    --- No handover is running on this contract for this hunter. Either it
    --- ended or it was never armed, and both are ordinary answers to an
    --- ordinary question rather than faults.
    NO_HANDOVER       = 'no_handover',
    --- The creator placed a contract on this same person recently.
    ---
    --- A policy cooldown measured in hours, not a token bucket. It shared
    --- RATE_LIMITED with the throttle, which the page words as "Slow down."
    --- and which three of its recovery paths read as a transient condition
    --- worth retrying — so a creator with two hours to wait was told to slow
    --- down, and the app quietly treated the refusal as a hiccup.
    SAME_TARGET_TOO_SOON = 'same_target_too_soon',
    --- The creator cancelled a contract recently. Same story: minutes of
    --- policy wait, reported as throttling.
    CANCELLED_TOO_SOON   = 'cancelled_too_soon',
    --- This hunter collected on this contract too recently to collect again.
    ---
    --- It was RATE_LIMITED, which the page words as "Slow down." and tells a
    --- hunter photographing a body to wait a few seconds and try again. The
    --- rule is a policy wait between payouts on one contract
    --- (Config.Limits.SlotCooldownSeconds, ten minutes as shipped), enforced
    --- at the moment the player has already done all the work — a few seconds
    --- fixes nothing, and the kill is lost either way.
    SLOT_COOLDOWN        = 'slot_cooldown',
    --- A handover on this contract failed a moment ago and cannot be
    --- restarted yet. It was BAD_STATE — "Not right now." — which reads the
    --- same as the contract having been cancelled underneath the hunter,
    --- when this is the one refusal on the delivery path that waiting fixes.
    HANDOVER_COOLDOWN    = 'handover_cooldown',
    --- The caller is already an operative on this contract. It shared
    --- BAD_STATE, "Not right now." — which reads as something to wait out,
    --- on a contract that is already in their Mine tab.
    ALREADY_HOLDING      = 'already_holding',
    --- This player (on any character) held this exclusive contract without
    --- working it and was released from it, so it is not theirs to take
    --- again (§14.8). Without the bar, releasing an idle hold only reset it.
    HOLD_RELEASED        = 'hold_released',
    --- This server does not run the masked relay (Config.Relay.Enabled).
    --- It was read in one place, the send, and answered BAD_STATE — "Not
    --- right now." — on a feature that was never going to work, while the
    --- rest of messaging, calls included, carried on regardless.
    RELAY_OFF            = 'relay_off',
    --- This server does not place calls through the app.
    CALLS_OFF            = 'calls_off',
    --- A call would show a number the other party paid to keep hidden, and
    --- this phone build cannot mask it, so it is not placed (§11.3). It was
    --- BAD_STATE, which says nothing about why or what to do instead.
    CALL_UNMASKED        = 'call_unmasked',
    SELF_TARGET      = 'self_target',
    SELF_ACCEPT      = 'self_accept',
    SAME_ACCOUNT     = 'same_account',
    LIMIT_REACHED    = 'limit_reached',
    --- This contract already carries as many operatives as it allows.
    ---
    --- Its own code because LIMIT_REACHED is worded as "you are holding too
    --- many contracts", and for this rule that is not vague, it is false:
    --- the hunter may hold none. It sent them off to cancel their own work
    --- to fix somebody else's contract being popular.
    CONTRACT_FULL    = 'contract_full',

    --- Why a buyout was refused.
    ---
    --- Six reasons shared one BAD_STATE, which the app words as "Not right
    --- now" — wrong for four of them. Three mean stop trying, two mean try
    --- again shortly, and one means it is already happening. This is the
    --- one move a target has, so being told the wrong thing about it costs
    --- them the contract.
    BAILOUT_OFF          = 'bailout_off',           -- this server runs none
    NO_BUYOUT_PRICE      = 'no_buyout_price',       -- the creator set none
    BUYOUT_PENDING       = 'buyout_pending',        -- already paid, processing
    INCAPACITATED        = 'incapacitated',         -- not from the floor
    HANDOVER_IN_PROGRESS = 'handover_in_progress',  -- somebody has hold of them
    --- Kept for anything older that still sends it, and as the catch-all.
    TARGET_PROTECTED = 'target_protected',

    --- Why a target cannot be listed. One code for all of these said
    --- "That target cannot be listed right now" whether the officer was
    --- off limits by policy, had two contracts on them already, had only
    --- just logged in, or had been the target of one an hour ago — and a
    --- player reading it had no way to tell which, or whether waiting
    --- would help.
    TARGET_IS_LEO      = 'target_is_leo',
    TARGET_HAS_ENOUGH  = 'target_has_enough',
    TARGET_JUST_ON     = 'target_just_on',
    TARGET_TOO_NEW     = 'target_too_new',
    TARGET_JUST_UP     = 'target_just_up',
    TARGET_RECENTLY_ON = 'target_recently_on',
    --- The stake on the contract is not the one the hunter was shown.
    ---
    --- Refused rather than charged. A stake is taken the moment Accept is
    --- tapped and forfeits to the creator if the hunter later walks away or
    --- runs out of clock, so charging a figure the player did not agree to
    --- is the one repricing that cannot be undone by refreshing (§14.18).
    TERMS_CHANGED    = 'terms_changed',
    -- A staked contract too close to its deadline to be worth the stake.
    TOO_LITTLE_TIME  = 'too_little_time',
    INSUFFICIENT     = 'insufficient_funds',
    INVALID_REWARD   = 'invalid_reward',
    INVALID_INPUT    = 'invalid_input',

    --- The handler crashed. Distinct from INVALID_INPUT, which used to
    --- cover this too: telling a player to check what they entered when the
    --- fault is a nil index on the server sends them looking at their own
    --- typing for a bug they cannot reach, and tells the operator nothing.
    SERVER_ERROR     = 'server_error',
    NOT_PARTICIPANT  = 'not_participant',
    ALREADY_SETTLED  = 'already_settled',
    TOKEN_INVALID    = 'token_invalid',
    PHOTO_REJECTED   = 'photo_rejected',

    --- Why a photo was rejected. One code covered four unrelated causes —
    --- a host that is not allowed, standing too far from the body, a target
    --- who was revived, and a shot the server could not attribute — and
    --- "The photo was not accepted" told a hunter nothing about which, so
    --- they had no way to do anything differently. Each is something they
    --- can act on, but only if they are told.
    PHOTO_TOO_FAR    = 'photo_too_far',
    PHOTO_REVIVED    = 'photo_revived',
    PHOTO_BAD_HOST   = 'photo_bad_host',
    LOCKED           = 'locked',
    -- Something else is being done to the same contract, or by the same
    -- player, in this instant; or the resource is still starting. Nothing
    -- was changed, and the same request a moment later goes through.
    BUSY             = 'busy',
    -- A hunter holds the contract, so its creator can no longer withdraw it,
    -- edit it or take reward back; only add to it or propose a change.
    CONTRACT_TAKEN   = 'contract_taken',
    -- The deadline is already as late as the contract's lifetime allows.
    DEADLINE_AT_LIMIT = 'deadline_at_limit',
    -- A buyout price was set on a reward with no cash or bank in it.
    BUYOUT_NEEDS_CLEAN = 'buyout_needs_clean',
}

return CB
