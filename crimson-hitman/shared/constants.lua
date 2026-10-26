--- Crimson Hitman System — shared constants.
--- Loaded on both sides. Contains no state.

CH = CH or {}

CH.STATE = {
    ACTIVE     = 'active',     -- listed, no hitman yet
    ACCEPTED   = 'accepted',   -- at least one hitman holds it
    COMPLETING = 'completing', -- a fulfilment is settling; persisted before funds move
    COMPLETED  = 'completed',
    BAILED_OUT = 'bailed_out',
    EXPIRED    = 'expired',
    CANCELLED  = 'cancelled',
    VOIDED     = 'voided',     -- admin
}

--- Terminal states release escrow exactly once and never transition again.
CH.TERMINAL = {
    [CH.STATE.COMPLETED]  = true,
    [CH.STATE.BAILED_OUT] = true,
    [CH.STATE.EXPIRED]    = true,
    [CH.STATE.CANCELLED]  = true,
    [CH.STATE.VOIDED]     = true,
}

--- Legal transitions. Anything absent here is rejected by contracts.transition().
CH.TRANSITIONS = {
    [CH.STATE.ACTIVE] = {
        [CH.STATE.ACCEPTED]   = true,
        [CH.STATE.CANCELLED]  = true,
        [CH.STATE.EXPIRED]    = true,
        [CH.STATE.BAILED_OUT] = true,
        [CH.STATE.VOIDED]     = true,
    },
    [CH.STATE.ACCEPTED] = {
        [CH.STATE.ACTIVE]     = true, -- last hitman abandoned an exclusive contract
        [CH.STATE.COMPLETING] = true,
        [CH.STATE.CANCELLED]  = true,
        [CH.STATE.EXPIRED]    = true,
        [CH.STATE.BAILED_OUT] = true,
        [CH.STATE.VOIDED]     = true,
    },
    [CH.STATE.COMPLETING] = {
        [CH.STATE.COMPLETED] = true,
        [CH.STATE.ACCEPTED]  = true, -- settlement failed and was rolled back
    },
}

CH.ESCROW_STATE = { HELD = 'held', RELEASING = 'releasing', SETTLED = 'settled' }

CH.SOURCE = {
    CASH   = 'cash',
    BANK   = 'bank',
    DIRTY  = 'dirty',
    ITEM   = 'item',
    WEAPON = 'weapon',
}

CH.MONEY_SOURCES = { cash = true, bank = true, dirty = true }

--- The subset of those that are qbx_core accounts.
---
--- Dirty money is not one: it is an ox_inventory item, moved with AddItem
--- and RemoveItem. Anywhere a config setting names an account that is handed
--- straight to AddMoney or RemoveMoney — a fee, a purchase price — naming
--- 'dirty' there does not charge black money, it charges nothing and reports
--- failure, which reads as the feature being broken.
CH.MONEY_ACCOUNTS = { cash = true, bank = true }

--- A stake is escrow held from the *hitman*, not the creator: the failure
--- penalty they agreed to when accepting an exclusive contract (§3.6).
---
--- An owed line is money already promised to one named person — a premium
--- for an offline creator, a refund for an offline target. It is its own
--- portion so that no general release can sweep it up by accident.
CH.PORTION = {
    BASELINE = 'baseline', BONUS = 'bonus', STAKE = 'stake', OWED = 'owed',
}

CH.MODE = { EXCLUSIVE = 'exclusive', COMPETITIVE = 'competitive' }

CH.FULFILMENT = { ELIMINATION = 'elimination', KIDNAPPING = 'kidnapping' }

--- How a contract may be completed (Config.Completion.Fulfilment): ALIVE
--- only by a live handover, EITHER by a kill or a live handover. A term of
--- the contract like its reward, written onto it as fulfilment_rule when it
--- is placed, so changing the setting changes only what new contracts are
--- placed under (Util.fulfilmentRule).
CH.FULFILMENT_RULE = { ALIVE = 'alive', EITHER = 'either' }

--- Where a kill photograph kept for a contract's client stands (§14.43).
--- PENDING until the client opens it, OPEN while they are looking at it,
--- and then SAVED to their phone, KEPT for them in this app, or DELETED.
---
--- DELETED keeps no image, and neither does SAVED, with one exception: a
--- photo kept on this server and saved to the phone's Photos through a
--- link this server serves, whose file stays for as long as the phone's
--- gallery holds the link. KEPT is the last resort for a phone that cannot
--- take the photo at all: its owner opens it again whenever they like, and
--- it is deleted when they say so.
CH.PHOTO = {
    PENDING = 'pending', OPEN = 'open', SAVED = 'saved', KEPT = 'kept', DELETED = 'deleted',
}

--- The kinds of picture a kill photo kept on this server may be
--- (Config.Completion.PhotoStorage = 'server'), and the file extension
--- each is kept under. A list of three, not a pattern: 'image/svg+xml' is
--- an image type too, and a script in a picture is not a photograph.
CH.PHOTO_MIME = { ['image/webp'] = 'webp', ['image/jpeg'] = 'jpg', ['image/png'] = 'png' }

CH.AMENDMENT = {
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

--- Additive amendments apply immediately: they can only benefit the hitman (§12.1).
CH.ADDITIVE = {
    [CH.AMENDMENT.ADD_ESCROW]      = true,
    [CH.AMENDMENT.RAISE_BONUS]     = true,
    [CH.AMENDMENT.EXTEND_DEADLINE] = true,
    [CH.AMENDMENT.LOWER_PENALTY]   = true,
}

CH.ERR = {
    NO_PLAYER        = 'no_player',
    BLACKLISTED_JOB  = 'blacklisted_job',
    --- The whitelisted-job view's read (Config.WhitelistedView), asked by a
    --- player the app is open to: the whole app is theirs, and the page
    --- goes back to it on this.
    NOT_WHITELISTED  = 'not_whitelisted',
    RATE_LIMITED     = 'rate_limited',
    NOT_FOUND        = 'not_found',
    BAD_STATE        = 'bad_state',
    --- The server has no kill by this hitman on this contract to verify.
    ---
    --- Shared bad_state until now, which the page words as "Not right now."
    --- That is the answer to the MOST COMMON tap of Verify kill: the button
    --- is drawn on every accepted contract whether or not a kill has
    --- happened, so the ordinary case — tapping it before the kill, or after
    --- one the server did not attribute — was four words that explain
    --- nothing about a mechanic with a distance rule and a time limit.
    NO_KILL_TO_VERIFY = 'no_kill_to_verify',
    --- No kill to verify, because the target's own game named this hitman as
    --- their killer and the server never saw a hit of theirs land: a blast,
    --- fire, a car (Config.Completion.RequireObservedDamage). "Down is not
    --- dead" was what they were told, about a target they had blown up.
    KILL_UNOBSERVED   = 'kill_unobserved',
    --- This contract pays only for delivering the target alive
    --- (CH.FULFILMENT_RULE.ALIVE), so a kill does not complete it and there
    --- is no kill to verify. Its own code: no_kill_to_verify tells the
    --- hitman to finish the target and photograph the body, which on this
    --- contract is the one thing that can never pay.
    KILL_NOT_ALLOWED  = 'kill_not_allowed',
    --- A contract that pays only for a live delivery pays its whole reward
    --- for it, so it carries no separate bonus: none is taken when it is
    --- placed, and none can be raised or added. Its own code, because
    --- invalid_reward says the figures do not add up, and they do.
    NO_BONUS          = 'no_bonus',
    --- No handover is running on this contract for this hitman. Either it
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
    --- This hitman collected on this contract too recently to collect again.
    ---
    --- It was RATE_LIMITED, which the page words as "Slow down." and tells a
    --- hitman photographing a body to wait a few seconds and try again. The
    --- rule is a policy wait between payouts on one contract
    --- (Config.Limits.SlotCooldownSeconds, ten minutes as shipped), enforced
    --- at the moment the player has already done all the work — a few seconds
    --- fixes nothing, and the kill is lost either way.
    SLOT_COOLDOWN        = 'slot_cooldown',
    --- A handover on this contract failed a moment ago and cannot be
    --- restarted yet. It was BAD_STATE — "Not right now." — which reads the
    --- same as the contract having been cancelled underneath the hitman,
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
    --- Turned off by the server: a feature staff switched off, from the
    --- admin panel or config.lua (proposals, the informant). It answered
    --- bad_state, "Not right now.", which reads as something to wait out on
    --- a feature that may stay off for good. Only new actions are refused:
    --- whatever was already under way finishes under the rules it began.
    FEATURE_OFF          = 'feature_off',
    --- Informant data on a contract placed before this start, asked for
    --- inside Config.Informant.ProximityWindowMinutes of it, with
    --- RequireProximity on. Who had been near the target is kept in memory
    --- and a restart forgot it, so the purchase was charged for "Unknown
    --- operative". Refused uncharged for everyone, whoever has been seen,
    --- with { minutes } until it is sold again.
    INFORMANT_WARMING    = 'informant_warming',
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
    --- the hitman may hold none. It sent them off to cancel their own work
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
    --- The stake on the contract is not the one the hitman was shown.
    ---
    --- Refused rather than charged. A stake is taken the moment Accept is
    --- tapped and forfeits to the creator if the hitman later walks away or
    --- runs out of clock, so charging a figure the player did not agree to
    --- is the one repricing that cannot be undone by refreshing (§14.18).
    TERMS_CHANGED    = 'terms_changed',
    -- A staked contract too close to its deadline to be worth the stake.
    TOO_LITTLE_TIME  = 'too_little_time',
    INSUFFICIENT     = 'insufficient_funds',
    INVALID_REWARD   = 'invalid_reward',
    --- The reward is worth less in money than Config.Limits.MinContractReward,
    --- or would be once this much of it was taken back out. Sent with
    --- { min = n } so the page can say the figure. Not invalid_reward, which
    --- is worded as figures that do not add up: these add up, to too little.
    REWARD_TOO_SMALL = 'reward_too_small',
    --- An item put up on an anonymous contract says whose it is: a name,
    --- a phone number, an owner (Escrow.namesOwner). Its own code because
    --- invalid_reward is worded as figures that do not add up, and the
    --- figures are fine; the item is the thing to take out.
    ITEM_NAMES_OWNER = 'item_names_owner',
    --- mysql mode only: an item whose metadata is more than the escrow
    --- table's TEXT column holds (MySQLStore.MAX_TEXT_BYTES, 65,535 bytes
    --- once encoded). Refused before anything is taken; it was a bad_state
    --- after a take and a rollback, with nothing to say which item.
    ITEM_TOO_LARGE   = 'item_too_large',
    INVALID_INPUT    = 'invalid_input',

    --- The handler crashed. Distinct from INVALID_INPUT, which used to
    --- cover this too: telling a player to check what they entered when the
    --- fault is a nil index on the server sends them looking at their own
    --- typing for a bug they cannot reach, and tells the operator nothing.
    SERVER_ERROR     = 'server_error',
    NOT_PARTICIPANT  = 'not_participant',
    ALREADY_SETTLED  = 'already_settled',
    TOKEN_INVALID    = 'token_invalid',
    --- The time to prove a kill ran out before the photo arrived. Its own
    --- code because a token never outlives its kill: told to take the photo
    --- again, as TOKEN_INVALID tells them, the hitman went back for a kill
    --- that was already gone.
    PROOF_EXPIRED    = 'proof_expired',
    PHOTO_REJECTED   = 'photo_rejected',

    --- Why a photo was rejected. One code covered four unrelated causes —
    --- a host that is not allowed, standing too far from the body, a target
    --- who was revived, and a shot the server could not attribute — and
    --- "The photo was not accepted" told a hitman nothing about which, so
    --- they had no way to do anything differently. Each is something they
    --- can act on, but only if they are told.
    PHOTO_TOO_FAR    = 'photo_too_far',
    PHOTO_REVIVED    = 'photo_revived',
    PHOTO_STILL_DOWN = 'photo_still_down',
    PHOTO_NOT_DEAD   = 'photo_not_dead',
    PHOTO_BAD_HOST   = 'photo_bad_host',
    --- A photo sent to be kept on this server that is not one: not a webp,
    --- jpeg or png, or not what it says it is. The page makes the picture
    --- itself, so this is a modified client or a broken encoder, never the
    --- hitman's aim.
    PHOTO_BAD_IMAGE  = 'photo_bad_image',
    --- Bigger than Config.Completion.PhotoMaxBytes. The page shrinks a
    --- photo to fit before sending it, so this too says the page did not.
    PHOTO_TOO_LARGE  = 'photo_too_large',
    --- A kill photograph that cannot be opened or decided on. One code for
    --- a handle that was never minted, one that belongs to somebody else,
    --- and one already seen: told apart, the answer would say whether a
    --- handle names somebody else's photograph.
    PHOTO_GONE       = 'photo_gone',
    --- The client asked for a link to save their photo to the phone's
    --- Photos with, and this server has none to give: no public address
    --- (Config.Completion.PhotoPublicUrl or web_baseUrl), or no source of
    --- unguessable names. The photo is still open; the page offers to keep
    --- it in the app instead.
    PHOTO_NO_LINK    = 'photo_no_link',
    --- Verify kill without a photo asked of a server that takes kill photos
    --- (Config.Completion.KillPhotos): the photo is one of the checks there,
    --- so the page opens the camera instead.
    PHOTO_REQUIRED   = 'photo_required',
    LOCKED           = 'locked',
    -- Something else is being done to the same contract, or by the same
    -- player, in this instant; or the resource is still starting. Nothing
    -- was changed, and the same request a moment later goes through.
    BUSY             = 'busy',
    -- Boot recovery raised (App.recoveryFailed), so the app stays closed
    -- until staff fix the logged cause and restart the resource. Not busy:
    -- that says a moment changes it, and here nothing in this process does.
    RECOVERY_FAILED  = 'recovery_failed',
    -- A hitman holds the contract, so its creator can no longer withdraw it,
    -- edit it or take reward back; only add to it or propose a change.
    CONTRACT_TAKEN   = 'contract_taken',
    -- The deadline is already as late as the contract's lifetime allows.
    DEADLINE_AT_LIMIT = 'deadline_at_limit',
    -- A buyout price was set on a reward with no cash or bank in it.
    BUYOUT_NEEDS_CLEAN = 'buyout_needs_clean',
}

--- The most lines one staff command output event carries
--- (crimson-hitman:commandOutput). The server starts a new event at this
--- many lines as well as at its byte limit (Bridges.sendOutput), and a
--- player's game prints no more than this many of one (client/admin.lua).
CH.OUTPUT_LINES_MAX = 400

return CH
