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
    SELF_TARGET      = 'self_target',
    SELF_ACCEPT      = 'self_accept',
    SAME_ACCOUNT     = 'same_account',
    LIMIT_REACHED    = 'limit_reached',
    TARGET_PROTECTED = 'target_protected',
    INSUFFICIENT     = 'insufficient_funds',
    INVALID_REWARD   = 'invalid_reward',
    INVALID_INPUT    = 'invalid_input',
    NOT_PARTICIPANT  = 'not_participant',
    ALREADY_SETTLED  = 'already_settled',
    TOKEN_INVALID    = 'token_invalid',
    PHOTO_REJECTED   = 'photo_rejected',
    LOCKED           = 'locked',
}

return CB
