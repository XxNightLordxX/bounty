--- Settings staff change from the admin panel, kept over config.lua.
---
--- The owner wanted every feature switchable, and the limits changeable,
--- from inside the game, with every change surviving a restart. config.lua
--- stays the file a server owner edits: what the panel changes is kept
--- beside it as an override per key, in whichever store the server runs
--- (memory, json records.json, mysql crimson_settings), applied over the
--- config at every start, right after the start-up checks and before
--- anything reads the config, and changed live in the same table every
--- module reads at use time.
---
--- Only keys in the catalogue below can be changed, and each one is checked
--- the way the start-up checks it (main.lua's validateConfig, run against a
--- copy of the config with the new value in it): a value those checks would
--- refuse, or quietly correct, is refused here with their words. A switch
--- that would lock staff out, or one that needs a migration, is listed
--- read-only with the reason.
---
--- What happens to things already under way when a feature is turned off
--- is the same everywhere unless an entry says otherwise: contracts already
--- placed, and payouts already owed, finish under the rules they started
--- with, and only new actions are refused, with CH.ERR.FEATURE_OFF (or the
--- feature's own code) and words on the page. No switch here strands money.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Settings = {}

local Storage, Audit, Check

--- What config.lua says for each catalogue key, as the start-up checks left
--- it, before any override: what a reset puts back. [key] = value
local defaults = {}

--- Overrides in force. [key] = { value, by, at }
local overrides = {}

--- Overrides the store holds that were not applied at start, and why.
--- [key] = { value, by, at, why }
local ignored = {}

--- Keys a change raised on and could not be read back for: the store may
--- or may not hold what was written, and the diagnosis says so until a
--- change to the key, or the next start, settles it. [key] = { why, by, at }
local unknown = {}

--- Called with (key, entry) after a key changes live; set by Bridges.install,
--- which knows who to tell (the access refresh, the photo host list).
Settings.onChanged = nil

--- Functions called after one key changes live, by key: what a switch
--- starts or stops the moment it is turned (the app pause,
--- Freeze.syncAppPause). Kept across Settings.init. [key] = fn
local watchers = {}

--- Call `fn` after `key` changes live (set, reset, reset all, an undo).
---@param key string
---@param fn function
function Settings.watch(key, fn)
    if type(key) == 'string' and type(fn) == 'function' then watchers[key] = fn end
end

--------------------------------------------------------------------------
-- The catalogue
--------------------------------------------------------------------------

--- Shared wording for in-flight behaviour, so every entry says the same
--- thing the same way.
local NEW_ONLY = 'Things already under way finish under the rules they started with; only '
    .. 'new actions are refused while it is off.'
local AT_USE = 'Read each time it is used, so it applies to the next check, including on '
    .. 'contracts already placed.'
local CAP = 'Lowering it below what is in use now never cancels anything: it only refuses '
    .. 'new ones over it.'
local RESTART = 'Read once at start: kept now, and in force after the next restart.'

--- Never changed from the panel, whatever a page sends: shown read-only with
--- why, and refused by Settings.check before anything else. Secrets (secret
--- = true) are shown only as set or not set, never their value; a key here
--- that config.lua does not hold (a convar, a key nil by default) is listed
--- all the same. [key] = { why, secret, convar }
local EDIT_IN_CONFIG = ' Edit it in config.lua.'
local DENY = {
    ['Database.Mode'] = { label = 'Storage mode',
        why = 'Changing it needs the money in the old mode settled and a restart '
        .. '(README, Changing storage mode).' .. EDIT_IN_CONFIG },
    ['Database.Json.Directory'] = { label = 'json store folder',
        why = 'Where the json store lives on disk: moved from here, the '
        .. 'next start would open an empty store.' .. EDIT_IN_CONFIG },
    ['Admin.Ace'] = { label = 'Staff panel ACE',
        why = 'Who may use this panel. An ACE renamed from here could grant or lock '
        .. 'out staff.' .. EDIT_IN_CONFIG },
    ['Admin.IdentityAce'] = { label = 'Identity ACE (unmask anonymous parties)',
        why = 'Who may unmask anonymous parties. An ACE renamed from here could '
        .. 'grant it to anyone.' .. EDIT_IN_CONFIG },
    ['Admin.DeveloperAce'] = { label = 'Developer section ACE',
        why = 'Who sees the Developer section. An ACE renamed from here could '
        .. 'grant it to anyone.' .. EDIT_IN_CONFIG },
    ['Admin.ModeratorAce'] = { label = 'Moderator ACE',
        why = 'Who may freeze, suspend, protect and void from this panel. An ACE '
        .. 'renamed from here could grant it to anyone.' .. EDIT_IN_CONFIG },
    ['Admin.ExtraAces'] = { label = 'Extra ACEs that may read the staff tools',
        why = 'ACEs that may read the staff tools. Changed from here, staff could '
        .. 'grant themselves access.' .. EDIT_IN_CONFIG },
    ['Reason.PatternDenylist'] = { label = 'Patterns a reason may not contain',
        why = 'Lua patterns: a malformed one raises in every reason check.'
        .. EDIT_IN_CONFIG },
    ['Completion.DeathStateProviders'] = { label = 'Death-state exports',
        why = 'Exports of other resources, called by name.'
        .. EDIT_IN_CONFIG },
    ['Completion.PhotoPublicUrl'] = { label = 'Address photos are served from',
        why = 'The address photos are served from.' .. EDIT_IN_CONFIG },
    ['Completion.KeptPhotoDays'] = { label = 'Days a saved photo is kept',
        why = 'nil keeps a saved photo until deleted.' .. EDIT_IN_CONFIG },
    ['Disposal.VehicleSpawn'] = { label = 'Disposal vehicle spawn spot',
        why = 'A place: set it with the panel\'s disposal spots (Use my position), which win over this.'
        .. EDIT_IN_CONFIG },
    ['Disposal.DropOff'] = { label = 'Disposal drop-off',
        why = 'A place: set it with the panel\'s disposal spots (Use my position), which win over this.'
        .. EDIT_IN_CONFIG },
    ['Kidnap.RestraintProvider'] = { label = 'Restraint export',
        why = 'A resource export, called by name.' .. EDIT_IN_CONFIG },
    ['Immunity.PlaytimeProvider'] = { label = 'Playtime export',
        why = 'A resource export, called by name.' .. EDIT_IN_CONFIG },
    ['Relay.CallExport'] = { label = 'Phone call export',
        why = 'A resource export, called by name.' .. EDIT_IN_CONFIG },
    -- progression.lua calls exports[<this>]:AddTrust(cid, amount): renamed
    -- from here, every finished contract called another resource's export.
    ['Progression.Resource'] = { label = 'Progression resource',
        why = 'A resource export, called by name.' .. EDIT_IN_CONFIG },
    ['convar:crimson_hitman_webhook'] = { secret = true, convar = 'crimson_hitman_webhook',
        why = 'The Discord webhook for the log: a secret, set in server.cfg with set (never setr).' },
    ['convar:crimson_hitman_alert_webhook'] = { secret = true, convar = 'crimson_hitman_alert_webhook',
        why = 'The Discord webhook for alerts: a secret, set in server.cfg with set (never setr).' },
}
Settings.DENY = DENY

--- The categories a key is shown under in the panel: who uses it.
Settings.CATEGORIES = { 'rules-timers', 'rules-rewards', 'rules-limits', 'rules-targeting', 'features',
    'developer', 'organisation',
    -- The Target limits section's Defaults (server/targetlimits.lua).
    'target-limits',
    -- The step markers and body disposal (server/missionsteps.lua).
    'mission-steps' }

--- Rewards & money, shown in these groups rather than the key's own.
local MONEY = {
    ['MaxContractValue'] = 'Rewards', ['Limits.MinContractReward'] = 'Rewards',
    ['Sources.cash.max'] = 'Rewards', ['Sources.bank.max'] = 'Rewards', ['Sources.dirty.max'] = 'Rewards',
    ['Sources.dirty.item'] = 'Rewards', ['Sources.item.maxStacks'] = 'Rewards',
    ['Sources.item.maxPerStack'] = 'Rewards', ['Sources.weapon.max'] = 'Rewards',
    ['Bonus.maxPercent'] = 'Rewards',
    ['Limits.MaxPayoutSlots'] = 'Payouts', ['Limits.SlotCooldownSeconds'] = 'Payouts',
    ['PendingEscrow.MaxRetriesPerLogin'] = 'Payouts', ['PendingEscrow.LoginRetryDelayMs'] = 'Payouts',
    ['Bailout.MinMultiplier'] = 'Buyouts', ['Bailout.MaxMultiplier'] = 'Buyouts',
    ['Bailout.AbsoluteMax'] = 'Buyouts', ['Bailout.ProcessingDelaySeconds'] = 'Buyouts',
    ['Informant.Cost'] = 'Informant prices', ['Informant.Account'] = 'Informant prices',
    ['PlacerInformant.Cost'] = 'Informant prices', ['PlacerInformant.Account'] = 'Informant prices',
    ['LocationTip.Cost'] = 'Informant prices', ['LocationTip.Account'] = 'Informant prices',
    ['Anonymity.CreatorFee'] = 'Anonymity fees', ['Anonymity.HitmanFee'] = 'Anonymity fees',
    ['Anonymity.FeeAccount'] = 'Anonymity fees',
    ['EscrowBlacklist'] = 'Escrow', ['Limits.MaxEscrowLines'] = 'Escrow', ['Penalty.MaxAmount'] = 'Escrow',
    ['Penalty.MaxFractionOfEscrow'] = 'Escrow',
}
Settings.MONEY = MONEY

--- Beside both restraints. With a restraint required and neither counting
--- (and no restraint resource), every handover was refused as 'not
--- restrained', even with the target cuffed in the hitman's car: on 'alive'
--- no contract could complete, and each ran to its deadline with its
--- hitman's stake forfeited. The start turns handcuffs back on; this
--- refuses the click that would do it, in the start's words.
local ONE_RESTRAINT = 'While Target must be restrained is on, one of the two restraints (or a '
    .. 'restraint resource, Config.Kidnap.RestraintProvider) has to count: with neither, no '
    .. 'handover could ever complete, so the last one is not turned off from here.'

--- What the panel says beside a key whose `unless` switch is on.
local UNLESS_ON = {
    ['WhitelistedView.Enabled'] = 'Does not apply while the whitelisted-job view is on '
        .. '(WhitelistedView.Enabled): barred jobs have the app, showing them its one '
        .. 'read-only screen, so this changes nothing until the view is off.',
}

--- What the panel says beside a key whose `needs` switch is off.
local NEEDS_OFF = {
    ['Completion.KillPhotos'] = 'Does not apply while kill photos are off (Completion.KillPhotos): '
        .. 'no kill photo is taken or kept, so this changes nothing until they are on again.',
    ['Mugshot.Enabled'] = 'Does not apply while target headshots are off (Mugshot.Enabled): '
        .. 'none is rendered, so this changes nothing until they are on again.',
    ['WhitelistedView.Enabled'] = 'Does not apply while the whitelisted-job view is off '
        .. '(WhitelistedView.Enabled): nobody has the view, so this changes nothing until it is '
        .. 'on again.',
    ['InformantsEnabled'] = 'Does not apply while every informant feature is off '
        .. '(InformantsEnabled): none is offered, so this changes nothing until it is on again.',
    ['Kidnap.RequireCoercion'] = 'Does not apply while Target must be restrained is off '
        .. '(Kidnap.RequireCoercion): a handover needs no restraint, so this changes nothing '
        .. 'until it is on again.',
}

--- Every key the panel may show, in the order it shows them.
---
--- kind: 'switch' (on/off), 'choice' (one of `choices`), 'number' (with
--- min, max and `integer`), 'list' (job names). needs is a switch this key
--- means nothing without: while it is off the panel says so beside the key
--- (`inactive`, from NEEDS_OFF); unless is the other way round, a switch
--- this key means nothing beside while it is ON (UNLESS_ON). section: 'features' or
--- 'limits'. live = false is a key kept and applied at the next start (or
--- the next time what reads it runs), and said so. client = true is a key
--- players' games read too, sent to them when it changes. readonly is the
--- reason a key cannot be changed here. destroys is for a number whose
--- lowering deletes something for good (0 being 'never', the highest): what
--- the panel says lowering it does, %s the new value. Lowering it takes the
--- two clicks every other destructive button does; one click, or Enter in
--- the box, put a typo of 1 for 10 days into force, and the next sweep
--- deleted every unopened kill photo older than a day.
local CATALOGUE = {
    -- Features ------------------------------------------------------------
    { key = 'BlockOffDuty', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      label = 'Bar off-duty officers',
      about = 'Barred jobs stay barred from the app while off duty.',
      inflight = AT_USE .. ' Who may see the app is checked again at once.' },
    { key = 'HideAppFromBlockedJobs', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      unless = 'WhitelistedView.Enabled',
      label = 'Hide the app from barred jobs',
      about = 'Keeps the app off a barred player\'s phone instead of showing one that answers nothing.',
      inflight = 'Every phone is told at once; barred jobs are refused either way.' },
    { key = 'WhitelistedView.Enabled', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      label = 'Whitelisted-job view',
      about = 'Barred jobs (police, EMS, DOJ, lawyers and the rest) open the app to one read-only '
          .. 'screen: the contracts on them and on other whitelisted-job members, with no more '
          .. 'than the law enforcement advisory says, and the buyout on a contract on them. '
          .. 'Off: the app is closed to them, as Hide the app from barred jobs says.',
      inflight = 'Every phone is told at once, and an open app changes screen at once. A buyout '
          .. 'already paid still closes after its delay either way.' },
    { key = 'WhitelistedView.Alerts', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      needs = 'WhitelistedView.Enabled',
      label = 'Notify me on the whitelisted-job view',
      about = 'A player on the whitelisted-job view may turn on Notify me (off until they do, for '
          .. 'each character): a phone notice when a new entry appears on their view. One on '
          .. 'them after the same wait as their own alert; one on another whitelisted-job member '
          .. 'as the advisory bulletin for it goes out. It says only who the contract is on and '
          .. 'their job, within the notice budget.',
      inflight = 'Read at every use, with no restart. Off hides the toggle and sends nothing, '
          .. 'notices still waiting included; each player\'s choice is kept, and applies again '
          .. 'when this is turned back on.' },
    { key = 'App.DefaultInstalled', section = 'features', category = 'features', group = 'The app', kind = 'switch',
      label = 'Put the app on every home screen', client = true, live = false,
      about = 'Installs the app on eligible phones instead of leaving it in the App Store.',
      inflight = 'Applies after restart: read when the app is added to a phone, at the next '
          .. 'start of this resource or lb-phone, or when a player next joins.' },

    { key = 'Sources.cash.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = 'Cash rewards', about = 'Cash may be put up as a reward.', inflight = NEW_ONLY
          .. ' Cash already held in escrow is paid out or returned as before.' },
    { key = 'Sources.bank.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = 'Bank rewards', about = 'Bank money may be put up as a reward.', inflight = NEW_ONLY
          .. ' Money already held in escrow is paid out or returned as before.' },
    { key = 'Sources.dirty.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = 'Dirty money rewards', about = 'Dirty money may be put up as a reward.',
      inflight = NEW_ONLY .. ' Money already held in escrow is paid out or returned as before.' },
    { key = 'Sources.item.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = 'Item rewards', about = 'Items may be put up as a reward.', inflight = NEW_ONLY
          .. ' Items already held in escrow are paid out or returned as before.' },
    { key = 'Sources.weapon.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = 'Weapon rewards', about = 'Weapons may be put up as a reward.', inflight = NEW_ONLY
          .. ' Weapons already held in escrow are paid out or returned as before.' },

    { key = 'Completion.Fulfilment', section = 'features', group = 'Completion', kind = 'choice',
      category = 'rules-limits',
      choices = { 'alive', 'either' }, label = 'How contracts are completed',
      -- Who the target is handed to, said here as everywhere a player reads
      -- it; and no photograph, which under KillPhotos off is never taken.
      about = '\'alive\': live transfer only. The target has to be brought alive to the '
          .. 'person who placed the contract, who has to be there for the handover; a kill '
          .. 'never completes one. \'either\': a verified kill, or that handover.',
      inflight = 'Each contract keeps the rule it was placed under; this changes new contracts only.' },
    { key = 'Completion.KillPhotos', section = 'features', category = 'features', group = 'Completion', kind = 'switch',
      label = 'Kill photos',
      about = 'Off: no kill photo is ever taken, uploaded, kept or served, and no image host is '
          .. 'asked anything. Under \'either\', Verify kill completes at the scene on the '
          .. 'server\'s own checks.',
      inflight = 'Read at the next Verify kill, with no restart. A photo already kept stays until '
          .. 'it expires as usual, and its client can still open it once; off, links to photos '
          .. 'saved to a phone\'s Photos stop loading. While it is off, the photos kept from '
          .. 'before can be removed all at once here.' },
    { key = 'Completion.PhotoStorage', section = 'features', group = 'Completion', kind = 'choice',
      category = 'developer',
      needs = 'Completion.KillPhotos',
      choices = { 'server', 'host' }, label = 'Where kill photos are kept',
      about = '\'server\': in this resource\'s data folder. \'host\': lb-phone\'s image host.',
      inflight = 'Photos already kept stay where they are and open as before; a photo token '
          .. 'asked for before the change is used the way it was issued.' },
    { key = 'Completion.RequireObservedDamage', section = 'features', category = 'features', group = 'Completion',
      kind = 'switch', label = 'Kills need damage the server saw',
      about = 'The killer a victim names must also be in the server\'s own damage log.',
      inflight = AT_USE },
    { key = 'Ledger.StorePhotos', section = 'features', category = 'features', group = 'Completion', kind = 'switch',
      needs = 'Completion.KillPhotos',
      label = 'Keep kill photos for the placer',
      about = 'The placer who placed the contract can open its kill photo once.',
      inflight = 'Photos already kept stay openable; kills verified while it is off keep none.' },

    { key = 'Kidnap.RequireConscious', section = 'features', group = 'Handovers', kind = 'switch',
      category = 'features',
      label = 'Target must be conscious', about = 'Not dead, not downed, above the health floor.',
      inflight = AT_USE .. ' A contract placed under \'alive\' always checks it.' },
    { key = 'Kidnap.RejectDead', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = 'Refuse a dead target', about = 'A body is never handed over.',
      inflight = AT_USE .. ' A contract placed under \'alive\' always checks it.' },
    { key = 'Kidnap.RejectLastStand', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = 'Refuse a downed target', about = 'A target in last stand cannot be handed over.',
      inflight = AT_USE },
    { key = 'Kidnap.RequireCoercion', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = 'Target must be restrained',
      about = 'Off (as shipped): the target only has to be alive, conscious, not downed and with '
          .. 'the hitman, within the handover radius of the person who placed the contract, for '
          .. 'the whole countdown. On: they also have to be cuffed, or in the hitman\'s own '
          .. 'vehicle, the whole time.',
      inflight = AT_USE .. ' A countdown already running is checked by it on its next sample.' },
    { key = 'Kidnap.Coercion.handcuffed', section = 'features', group = 'Handovers', kind = 'switch',
      category = 'features',
      label = 'Handcuffs count as restraint', about = 'QBox \'ishandcuffed\' metadata. ' .. ONE_RESTRAINT,
      needs = 'Kidnap.RequireCoercion', inflight = AT_USE },
    { key = 'Kidnap.Coercion.passengerOfHitman', section = 'features', category = 'features', group = 'Handovers',
      kind = 'switch', label = 'The hitman\'s vehicle counts as restraint',
      about = 'The target riding in the hitman\'s vehicle. ' .. ONE_RESTRAINT,
      needs = 'Kidnap.RequireCoercion', inflight = AT_USE },
    { key = 'Kidnap.MeetingPoint', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = 'Meeting point for the handover',
      about = 'On an alive-only contract a hitman holds, the person who placed it can set a '
          .. 'meeting point where they stand, and clear it. Only the hitmen on that contract '
          .. 'see it, on their GPS: not the board, the target, the whitelisted-job view or the '
          .. 'advisory, and staff only with the identity ACE.',
      inflight = 'Read at every use, with no restart. Off hides the controls and refuses changes; '
          .. 'points already set are kept, and shown again when it is turned back on.' },
    { key = 'Kidnap.PlacerConfirms', section = 'features', category = 'features', group = 'Handovers',
      kind = 'switch', label = 'The placer confirms the handover',
      about = 'Once a handover has been held for its countdown, the person who placed the contract '
          .. 'taps Confirm handover on their card (twice) before it pays. A decline pays nothing; '
          .. 'the contract stays open and the hitman may arm it again after the usual wait.',
      inflight = 'A handover keeps the rule it was armed under; the next one armed reads it.' },
    { key = 'Kidnap.ConfirmSeconds', section = 'limits', category = 'rules-timers', group = 'Handovers',
      kind = 'number', integer = true, min = 10, max = 600, needs = 'Kidnap.PlacerConfirms',
      label = 'Time the placer has to confirm (s)',
      about = 'From the end of the countdown. Stands still on the restart hold and while the app is paused.',
      inflight = 'A window already open keeps its length; the next one opened reads it.' },
    { key = 'Kidnap.ConfirmMissed', section = 'limits', category = 'rules-timers', group = 'Handovers',
      kind = 'choice', choices = { 'rearm', 'pay' }, needs = 'Kidnap.PlacerConfirms',
      label = 'When the placer does not answer in time',
      about = '\'rearm\': nothing is paid and the hitman may arm again. \'pay\': paid as if confirmed.',
      inflight = AT_USE },
    { key = 'Kidnap.MaxDeclines', section = 'limits', category = 'rules-limits', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 20, needs = 'Kidnap.PlacerConfirms',
      label = 'Declines a contract\'s placer gets (0 no limit)',
      about = 'Declines, and windows left to run out under \'rearm\', counted per contract. Past this the '
          .. 'next handover held for its countdown pays without asking the placer.',
      inflight = AT_USE },

    { key = 'Penalty.RequireDisclosureOnAccept', section = 'features', category = 'features', group = 'Stakes',
      kind = 'switch', label = 'Accept must echo the stake shown',
      about = 'A page showing a stale stake is refused rather than charged a new one.',
      inflight = AT_USE },

    { key = 'Bailout.Enabled', section = 'features', category = 'features', group = 'Buyouts', kind = 'switch',
      label = 'Buyouts',
      about = 'A target may pay to close a contract on them, in the app or with the buyout '
          .. 'command for players the app is closed to.',
      inflight = 'A buyout already paid still closes the contract after its delay; new ones are '
          .. 'refused while it is off, and contracts placed meanwhile carry no buyout price. '
          .. 'A price already set is kept: only taking part of the reward back lowers it, '
          .. 'with the reward.' },
    { key = 'Bailout.BlockWhileIncapacitated', section = 'features', category = 'features', group = 'Buyouts',
      kind = 'switch', label = 'No buyout from the floor',
      about = 'A dead or downed target cannot buy out.', inflight = AT_USE },

    { key = 'Targeting.AllowBrowseAll', section = 'features', group = 'Targeting', kind = 'switch',
      category = 'features',
      label = 'Browse everyone online', about = 'Pick a target from a list of everyone online.',
      inflight = 'Placed contracts are untouched; the list is empty while it is off.' },
    { key = 'Targeting.AllowNearby', section = 'features', category = 'features', group = 'Targeting', kind = 'switch',
      label = 'List the people nearby', client = true,
      about = 'Names unmasked players within the nearby radius. Read its config comment first.',
      inflight = 'The list is empty while it is off, and players\' games stop reporting masks.' },
    { key = 'Targeting.AllowProtectedJobTargets', section = 'features', category = 'features', group = 'Targeting',
      kind = 'switch', label = 'Law enforcement may be targeted',
      about = 'Off refuses new contracts on protected jobs.',
      inflight = 'Contracts already on protected targets run on; only new ones are refused.' },
    { key = 'Mugshot.Enabled', section = 'features', category = 'features', group = 'Targeting', kind = 'switch',
      label = 'Target headshots', client = true,
      about = 'Faces on the board, rendered by each target\'s own game. Off: none is asked for, '
          .. 'one sent anyway is refused unread, and cards show the placeholder.',
      inflight = 'Read at the next card drawn, with no restart: turned off, the headshots kept '
          .. 'are forgotten at once.' },
    { key = 'Mugshot.RemoveBackground', section = 'features', group = 'Targeting', kind = 'switch',
      category = 'features',
      needs = 'Mugshot.Enabled',
      label = 'Cut the background out of headshots', client = true,
      about = 'Loads a segmentation model into the target\'s game for each render.',
      inflight = 'Headshots already cached keep the background they were made with.' },

    { key = 'Advisory.Enabled', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Advisories', about = 'Law enforcement is told about contracts on officers.',
      inflight = 'Bulletins already sent stand; none is sent while it is off.' },
    { key = 'Advisory.UseDispatch', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Through sc-dispatch', about = 'Raise a dispatch entry as well.',
      inflight = AT_USE },
    { key = 'Advisory.AlwaysAlertTarget', section = 'features', group = 'Law enforcement advisory',
      category = 'features',
      kind = 'switch', label = 'Always tell the officer', about = 'The targeted officer is told.',
      inflight = AT_USE },
    { key = 'Advisory.OnCreate', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'When posted', about = 'A bulletin when the contract is posted.',
      inflight = AT_USE },
    { key = 'Advisory.OnAccept', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'When accepted', about = 'A bulletin when an operative accepts.',
      inflight = AT_USE },
    { key = 'Advisory.OnLocationTip', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'When a tip is bought',
      about = 'A bulletin when a hitman buys an informant tip on the officer.', inflight = AT_USE },
    { key = 'Advisory.OnCancel', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'When called off',
      about = 'A bulletin when a contract on an officer is cancelled or voided with a refund.',
      inflight = AT_USE },
    { key = 'Advisory.WarnCreator', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Warn the placer', about = 'Before escrow is taken.', inflight = AT_USE },
    { key = 'Advisory.WarnHitman', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Warn the hitman', about = 'Before they accept.', inflight = AT_USE },
    { key = 'Advisory.FlagListing', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Flag the listing', about = 'The board marks an officer target.',
      inflight = AT_USE },

    { key = 'Relay.Enabled', section = 'features', category = 'features', group = 'Messages and calls', kind = 'switch',
      label = 'Messages', about = 'The masked relay between the parties of a contract.',
      inflight = 'Threads are kept and come back when it is on again; nothing can be read or '
          .. 'sent while it is off.' },
    { key = 'Relay.AllowMaskedCalls', section = 'features', category = 'features', group = 'Messages and calls',
      kind = 'switch', label = 'Calls', about = 'Calls between the parties through lb-phone.',
      inflight = 'A call already ringing is left alone, and its caller can still hang it up '
          .. 'from the app; new ones are refused.' },
    { key = 'Relay.RequireMaskingForAnonymous', section = 'features', group = 'Messages and calls',
      category = 'features',
      kind = 'switch', label = 'Never unmask a caller',
      about = 'No call to or from an anonymous party on a phone that cannot hide the number.',
      inflight = AT_USE },

    { key = 'Anonymity.AllowAnonymousPlacer', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = 'Placing anonymously',
      about = 'A contract may be placed anonymously. Off, the Place form has no such option and '
          .. 'the server refuses one, charging nothing.',
      inflight = 'Read at every placing, with no restart. Contracts already placed anonymously '
          .. 'stay anonymous: it is not retroactive.' },
    { key = 'Anonymity.AllowAnonymousHitman', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = 'Accepting anonymously',
      about = 'A contract may be accepted anonymously. Off, Accept has no such option and the '
          .. 'server refuses one, charging nothing: every new operative is named to the person '
          .. 'who placed the contract.',
      inflight = 'Read at every acceptance, with no restart. Operatives already anonymous stay '
          .. 'anonymous, and one coming back to a contract they held anonymously comes back '
          .. 'under the same alias.' },
    { key = 'Anonymity.ShowOperativeNames', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = 'Operative names shown to the target',
      about = 'An operative who accepted under their name is shown by it to the contract\'s '
          .. 'target too (On me, and the informant\'s list), not only to the person who placed '
          .. 'it. Off, the target sees every operative as an alias. Never to the board, other '
          .. 'hitmen, law enforcement or Discord.',
      inflight = 'Read at every view, with no restart. Operatives who accepted anonymously keep '
          .. 'their alias either way.' },
    { key = 'Anonymity.ShowPlacerOnBoard', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = 'Placer names shown on the board',
      about = 'A placer who put their name to a contract is named to everybody browsing the '
          .. 'board. Off, only the contract\'s parties see the name: the placer, the operatives '
          .. 'on it and its target.',
      inflight = 'Read at every view, with no restart. Contracts placed anonymously are never '
          .. 'named either way.' },

    -- The same four, in place of those above, on a contract whose target is
    -- on a whitelisted job (as the contract records it, like the advisory).
    { key = 'Anonymity.WhitelistedTargets.AllowAnonymousPlacer', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = 'Placing anonymously',
      about = 'A contract on a member of a whitelisted job may be placed anonymously. Applies '
          .. 'there in place of the general switch; off, the server refuses one, charging '
          .. 'nothing.',
      inflight = 'Read at every placing, with no restart. Not retroactive.' },
    { key = 'Anonymity.WhitelistedTargets.AllowAnonymousHitman', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = 'Accepting anonymously',
      about = 'A contract on a member of a whitelisted job may be accepted anonymously. Applies '
          .. 'there in place of the general switch; off, the server refuses one, charging '
          .. 'nothing.',
      inflight = 'Read at every acceptance, with no restart. Operatives already anonymous stay '
          .. 'anonymous.' },
    { key = 'Anonymity.WhitelistedTargets.ShowOperativeNames', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = 'Operative names shown to the target',
      about = 'A member of a whitelisted job sees an operative who accepted under their name by '
          .. 'it. Applies there in place of the general switch. Never to anybody else.',
      inflight = 'Read at every view, with no restart. Operatives who accepted anonymously keep '
          .. 'their alias either way.' },
    { key = 'Anonymity.WhitelistedTargets.ShowPlacerOnBoard', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = 'Placer names shown on the board',
      about = 'A placer who put their name to a contract on a member of a whitelisted job is '
          .. 'named to everybody browsing the board. Applies there in place of the general '
          .. 'switch; off, only the contract\'s parties see the name.',
      inflight = 'Read at every view, with no restart. Contracts placed anonymously are never '
          .. 'named either way.' },

    { key = 'Amendments.Enabled', section = 'features', category = 'features', group = 'Proposals', kind = 'switch',
      label = 'Proposals', about = 'Changes to a contract that need the other side\'s agreement.',
      inflight = 'Proposals already open can still be answered and run out as before; new ones '
          .. 'are refused while it is off.' },

    { key = 'InformantsEnabled', section = 'features', category = 'features', group = 'Informant', kind = 'switch',
      label = 'Every informant feature',
      about = 'The master switch over the target\'s informant, the placer\'s informant and the '
          .. 'informant tip. Off turns all three off at once, whatever their own switches say.',
      inflight = 'Names already found stay shown, and a tip already bought stays on its buyer\'s '
          .. 'map until it runs out; new look-ups and tips are refused, and their buttons are '
          .. 'gone, while it is off.' },
    { key = 'Informant.Enabled', section = 'features', category = 'features', group = 'Informant', kind = 'switch',
      needs = 'InformantsEnabled',
      label = 'Target\'s informant',
      about = 'A target may pay for a chance to find out who is after them. For civilian '
          .. 'targets; a target on a whitelisted job has its own switch.',
      inflight = 'Names already found stay shown; new look-ups are refused while it is off.' },
    { key = 'PlacerInformant.Enabled', section = 'features', group = 'Informant', kind = 'switch',
      category = 'features',
      needs = 'InformantsEnabled',
      label = 'Placer\'s informant',
      about = 'The person who placed a contract may pay for a chance to find out who took it. '
          .. 'On contracts on civilians; one on a whitelisted job has its own switch.',
      inflight = 'Names already found stay shown; new look-ups are refused while it is off.' },

    { key = 'LocationTip.Enabled', section = 'features', group = 'Informant tip', kind = 'switch',
      category = 'features',
      needs = 'InformantsEnabled',
      label = 'Informant tip',
      about = 'A hitman on a contract may pay for the rough area the target was in. On '
          .. 'contracts on civilians; one on a whitelisted job has its own switch.',
      inflight = 'A tip already bought stays on its buyer\'s map until it runs out; new ones '
          .. 'are refused while it is off.' },
    { key = 'LocationTip.NotifyTarget', section = 'features', category = 'features', group = 'Informant tip',
      kind = 'switch', label = 'Tell the target',
      about = 'The target is told someone knows their rough area, never who or where.',
      inflight = 'Read when a tip is bought; a target already told stays told.' },

    -- The three above, in place of their own switches, on a contract whose
    -- target is on a whitelisted job (the flag it recorded, as the advisory
    -- reads it). The master switch still turns them off.
    { key = 'InformantsWhitelistedTargets.Informant', section = 'features', category = 'features',
      group = 'Informants (whitelisted-job targets)', kind = 'switch',
      needs = 'InformantsEnabled', label = 'Target\'s informant',
      about = 'A target on a whitelisted job may pay for a chance to find out who is after '
          .. 'them. Off, it is refused as before (informant_protected), charging nothing.',
      inflight = 'Names already found stay shown; new look-ups are refused while it is off.' },
    { key = 'InformantsWhitelistedTargets.PlacerInformant', section = 'features', category = 'features',
      group = 'Informants (whitelisted-job targets)', kind = 'switch',
      needs = 'InformantsEnabled', label = 'Placer\'s informant',
      about = 'The person who placed a contract on a member of a whitelisted job may pay for a '
          .. 'chance to find out who took it.',
      inflight = 'Names already found stay shown; new look-ups are refused while it is off.' },
    { key = 'InformantsWhitelistedTargets.LocationTip', section = 'features', category = 'features',
      group = 'Informants (whitelisted-job targets)', kind = 'switch',
      needs = 'InformantsEnabled', label = 'Informant tip',
      about = 'A hitman on a contract on a member of a whitelisted job may pay for the rough '
          .. 'area the target was in.',
      inflight = 'A tip already bought stays on its buyer\'s map until it runs out; new ones '
          .. 'are refused while it is off.' },

    { key = 'Notifications.ParanoidAlert', section = 'features', category = 'features', group = 'Notifications',
      kind = 'switch', label = 'Tell the target', about = 'The target\'s phone says a price is on them.',
      inflight = 'Alerts already sent stand; alerts still waiting are checked when they fall due.' },
    { key = 'Notifications.PushEnabled', section = 'features', category = 'features', group = 'Notifications',
      kind = 'switch', label = 'Refresh open apps', about = 'Nudge an open app when its contract changes.',
      inflight = AT_USE },

    { key = 'Limits.PauseWhileTargetJailed', section = 'features', category = 'features', group = 'The clock',
      kind = 'switch', label = 'Pause while the target is jailed',
      about = 'A target serving time stops the deadline, as one offline does.',
      inflight = 'Checked by the next expiry pass: a pause it began ends, with the time banked.' },

    { key = 'AntiCollusion.BlockSameAccount', section = 'features', category = 'features', group = 'Anti-collusion',
      kind = 'switch', label = 'Refuse your own account',
      about = 'No contract between characters of one account.',
      inflight = 'Contracts already placed run on; new ones and acceptances are checked.' },

    { key = 'Progression.Enabled', section = 'features', category = 'features', group = 'Progression', kind = 'switch',
      label = 'Criminal progression', about = 'Completed contracts earn sc-blackmarket trust.',
      inflight = 'Trust already given stands; completions while it is off earn none.' },

    { key = 'Audit.LogAllActions', section = 'features', group = 'Audit and debug', kind = 'switch',
      category = 'features',
      label = 'Log player conduct', about = 'Every creation, acceptance and refusal, not only money.',
      inflight = 'Money, staff actions and refusals are always logged whatever this says.' },
    { key = 'Audit.LogReasonText', section = 'features', group = 'Audit and debug', kind = 'switch',
      category = 'features',
      label = 'Log contract reasons', about = 'The reason text goes into the log.', inflight = AT_USE },
    { key = 'Alerts.ToDiscord', section = 'features', category = 'features', group = 'Audit and debug', kind = 'switch',
      label = 'Post alerts to Discord',
      about = 'Every alert in the Alerts section is posted to the webhook set in server.cfg '
          .. '(crimson_hitman_alert_webhook, or else crimson_hitman_webhook), scrubbed of every '
          .. 'identity, at most one post every 10 seconds. Off: nothing is posted; the Alerts '
          .. 'section still lists every one.',
      inflight = 'Read at the next post, with no restart: turned off, alerts waiting to be posted '
          .. 'are dropped, and nothing said while it is off is posted later.' },
    { key = 'Staff.AppPaused', section = 'features', category = 'features', group = 'Staff tools',
      kind = 'switch', label = 'Pause the whole app',
      about = 'For an event: no contract is placed or accepted anywhere, and every live contract '
          .. 'keeps both its clocks stopped, as the restart hold stops them. Players are told '
          .. '"Contracts are paused by staff." Off again, each clock runs where nothing else '
          .. '(a freeze, the restart hold, somebody away) still stops it, and the lifetime is '
          .. 'given back the time it was paused.',
      inflight = 'At once, with no restart, and kept across one. Payouts, handovers and buyouts '
          .. 'already under way finish as they began.' },
    { key = 'Staff.DailySummary', section = 'features', category = 'features', group = 'Staff tools',
      kind = 'switch', label = 'Daily summary to Discord',
      about = 'Once a day, at the hour under Rules > Timers, a post to the alert webhook '
          .. '(crimson_hitman_alert_webhook, or else crimson_hitman_webhook) with counts only: '
          .. 'contracts placed, completed and refunded in the last day, money in escrow, open '
          .. 'review items, frozen and suspended players. It never names anybody.',
      inflight = 'Read at the hour. At most once a day, a restart included.' },
    { key = 'Debug', section = 'features', category = 'developer', group = 'Audit and debug', kind = 'switch',
      label = 'Debug output in the server console',
      about = 'Off: the server console prints only what needs you (refusing to start, money '
          .. 'left for staff, a write that failed) and one line for every setting that needs '
          .. 'attention. On: everything, each setting problem in full and page faults with their '
          .. 'stack. The diagnosis lists all of it either way.',
      inflight = 'Read at every line printed, with no restart. The lines of a start before the '
          .. 'panel\'s settings are applied (the store opening, its migrations) follow config.lua; '
          .. 'the diagnosis lists them either way.' },

    -- Read only, with the reason -----------------------------------------
    { key = 'Admin.Enabled', section = 'readonly', category = 'developer', group = 'Staff', kind = 'switch',
      label = 'Staff tools',
      readonly = 'Turning the staff tools off from the staff tools would lock you out of turning '
          .. 'them back on. Set it in config.lua.' },
    { key = 'Admin.Ace', section = 'readonly', category = 'developer', group = 'Staff', kind = 'text',
      label = 'Staff ACE', readonly = 'Who may use this panel. Set it in config.lua, so a slip '
          .. 'here cannot lock staff out.' },
    { key = 'Admin.IdentityAce', section = 'readonly', category = 'developer', group = 'Staff', kind = 'text',
      label = 'Identity ACE', readonly = 'Who may unmask anonymous parties. Set it in config.lua.' },
    { key = 'Database.Mode', section = 'readonly', category = 'developer', group = 'Storage', kind = 'text',
      label = 'Storage mode', readonly = 'Changing it needs the money in the old mode settled and '
          .. 'a restart (README, Changing storage mode).' },
    { key = 'Database.AllowModeSwitch', section = 'readonly', group = 'Storage', kind = 'switch',
      category = 'developer',
      label = 'Start over money in another mode',
      readonly = 'Read once at start, and only safe on a server that settled the old mode by hand.' },
    { key = 'Database.Json.SyncOnFinancialWrite', section = 'readonly', category = 'developer', group = 'Storage',
      kind = 'switch', label = 'Write money to disk as it moves',
      readonly = 'Off, a crash could lose money that had moved. Set it in config.lua.' },
    { key = 'Database.QueryTimeoutSeconds', section = 'readonly', category = 'developer', group = 'Storage',
      kind = 'number', label = 'Database answer limit (s)',
      readonly = 'mysql only. Set it in config.lua; it takes effect at the next start.' },
    -- Shown, not switched: turned off it changed nothing. A target only in
    -- last stand never reads as dead to the server, the sampler or the
    -- photo checks, whatever it says; it only removes one a death provider
    -- reports as dead and in last stand at once.
    { key = 'Completion.RejectLastStand', section = 'readonly', category = 'developer', group = 'Completion',
      kind = 'switch', label = 'A downed target is not a kill',
      readonly = 'Only matters for a death provider that reports dead and last stand at once; '
          .. 'a downed target is never a kill here.' },

    -- Limits and settings -------------------------------------------------
    { key = 'Limits.MaxActiveContractsPerCreator', section = 'limits', group = 'Contract limits',
      category = 'rules-limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Contracts a client may have out',
      inflight = CAP },
    { key = 'Limits.MaxAcceptedPerHitman', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Contracts a hitman may hold',
      inflight = CAP },
    -- Target limits (the panel's own section, server/targetlimits.lua): how
    -- often one person may have a contract placed on them. A job's or a
    -- player's override is set there too, over these.
    { key = 'Limits.MaxActiveContractsPerTarget', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Live contracts on one person at once',
      inflight = CAP },
    { key = 'Limits.MaxContractsPerTargetPerDay', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Contracts placed on one person in a rolling 24 hours (0 = off)',
      about = 'Every contract placed on them counts, whatever became of it, but one staff voided.',
      inflight = CAP },
    { key = 'Limits.MaxContractsPerTargetPerWeek', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 0, max = 500,
      label = 'Contracts placed on one person in a rolling 7 days (0 = off)',
      about = 'Every contract placed on them counts, whatever became of it, but one staff voided.',
      inflight = CAP },
    -- Never above the most a contract may be worth (Config.MaxContractValue,
    -- config.lua's only): offered up to 100,000,000, anything over that was
    -- refused, in words that said the start would use the ceiling instead.
    { key = 'Limits.MinContractReward', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 100000000, ceiling = 'MaxContractValue',
      label = 'Least a reward may be worth ($, 0 off)', inflight = CAP },
    { key = 'Limits.MaxHitmenPerContract', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Operatives on one contract',
      inflight = CAP },
    { key = 'Limits.MaxPayoutSlots', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 3,
      label = 'Times one contract can be collected (1 to 3)',
      inflight = 'New contracts only: each contract keeps the number it was placed with. At 1 the '
          .. 'Place form shows no extra collections.' },
    { key = 'Limits.MaxEscrowLines', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 500, label = 'Escrow lines in one contract',
      inflight = CAP },
    { key = 'Limits.MaxDeadlineSkipSeconds', section = 'limits', category = 'developer', group = 'Contract limits',
      kind = 'number', integer = true, min = 10, max = 3600,
      label = 'Longest the expiry pass sleeps (s)', inflight = AT_USE },
    { key = 'Limits.SlotCooldownSeconds', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Wait between one hitman\'s payouts (s)', inflight = AT_USE },
    { key = 'Limits.TargetCooldownAfterResolveSeconds', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Wait after a contract on a person ends before anybody names them again (seconds)',
      inflight = AT_USE },
    { key = 'Limits.SameCreatorSameTargetCooldownSeconds', section = 'limits', category = 'target-limits',
      group = 'Target limits', kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Wait before the same placer names the same person again (seconds)', inflight = AT_USE },
    { key = 'Limits.ContractLifetimeSeconds', section = 'limits', category = 'rules-timers', group = 'Contract limits',
      kind = 'number', integer = true, min = 600, max = 2592000,
      label = 'Longest a contract may run (s)',
      inflight = 'New contracts only: each contract keeps the lifetime it was placed with.' },
    { key = 'Limits.DefaultDeadlineSeconds', section = 'limits', category = 'rules-timers', group = 'Contract limits',
      kind = 'number', integer = true, min = 300, max = 2592000,
      label = 'Deadline a new contract gets (s)',
      inflight = 'New contracts only: each contract keeps the deadline it was given.' },
    { key = 'Limits.StaffDeadlineMaxAdjustSeconds', section = 'limits', category = 'rules-timers',
      group = 'Contract limits', kind = 'number', integer = true, min = 60, max = 2592000,
      label = 'Most staff may extend or shorten a deadline by (s)', inflight = AT_USE },
    { key = 'Limits.StaffDeadlineMinLeftSeconds', section = 'limits', category = 'rules-timers',
      group = 'Contract limits', kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Least time a staff shortening leaves (s)', inflight = AT_USE },
    -- Config.Staff (Staff and permissions in config.lua): the most one
    -- manual payment from Players may be. Shown with the limits.
    { key = 'Staff.ManualPaymentMax', section = 'limits', category = 'rules-limits', group = 'Staff',
      kind = 'number', integer = true, min = 0, max = 100000000,
      label = 'Most one manual staff payment may be ($, 0 off)',
      about = 'Players, Pay: cash or bank paid to one player by staff with the staff ACE.',
      inflight = AT_USE },
    { key = 'Staff.RewardChangeMax', section = 'limits', category = 'rules-limits', group = 'Staff',
      kind = 'number', integer = true, min = 0, max = 100000000,
      label = 'Most staff may change a reward by at once ($, 0 off)',
      about = 'A contract\'s Change reward: raised (added by staff, or charged to the placer) or '
          .. 'lowered (the difference back to whoever funded it), by staff with the staff ACE.',
      inflight = AT_USE },
    { key = 'Staff.ReassignStake', section = 'limits', category = 'rules-limits', group = 'Staff',
      kind = 'choice', choices = { 'waive', 'charge' },
      label = 'Stake of a hitman staff assign',
      about = 'A contract\'s Reassign: \'waive\' puts no stake up for them; \'charge\' stakes them '
          .. 'as their own Accept would.',
      inflight = AT_USE },
    { key = 'Limits.ExclusiveIdleReleaseSeconds', section = 'limits', group = 'Contract limits',
      category = 'rules-timers',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Release an idle exclusive hold after (s, 0 off)', inflight = AT_USE },
    { key = 'Limits.ExclusiveAttemptWindowSeconds', section = 'limits', group = 'Contract limits',
      category = 'rules-timers',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Release a hold with no attempt after (s, 0 off)', inflight = AT_USE },
    { key = 'Limits.JailZone.radius', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', min = 10, max = 5000, label = 'Prison grounds radius (m)', inflight = AT_USE },

    { key = 'Penalty.MaxAmount', section = 'limits', category = 'rules-rewards', group = 'Stakes', kind = 'number',
      integer = true, min = 0, max = 100000000, label = 'Largest stake ($)',
      inflight = 'New contracts only: a stake is fixed when the contract is placed.' },
    { key = 'Penalty.MaxFractionOfEscrow', section = 'limits', group = 'Stakes', kind = 'number',
      category = 'rules-rewards',
      min = 0, max = 10, label = 'Largest stake, as a share of the reward',
      inflight = 'New contracts only: a stake is fixed when the contract is placed.' },
    { key = 'Penalty.MinWindowMinutes', section = 'limits', group = 'Stakes', kind = 'number',
      category = 'rules-timers',
      integer = true, min = 0, max = 1440, label = 'Least time left to stake on (min)',
      inflight = AT_USE },

    { key = 'Anonymity.CreatorFee', section = 'limits', category = 'rules-rewards', group = 'Anonymity',
      kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Fee to place anonymously ($)',
      inflight = 'Charged when a contract is placed; a fee refunded is always the one charged.' },
    { key = 'Anonymity.HitmanFee', section = 'limits', category = 'rules-rewards', group = 'Anonymity', kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Fee to accept anonymously ($)',
      inflight = 'Charged when a contract is accepted.' },
    { key = 'Anonymity.FeeAccount', section = 'limits', category = 'rules-rewards', group = 'Anonymity',
      kind = 'choice',
      choices = { 'bank', 'cash' }, label = 'Account the fees are charged to',
      inflight = 'A fee refunded goes back to the account it was taken from.' },

    { key = 'Informant.Cost', section = 'limits', category = 'rules-rewards', group = 'Informant', kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Target\'s look-up price ($)',
      inflight = AT_USE },
    { key = 'Informant.RevealChancePercent', section = 'limits', category = 'rules-limits', group = 'Informant',
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Target\'s chance a look-up finds out (%)', inflight = AT_USE },
    { key = 'PlacerInformant.Cost', section = 'limits', category = 'rules-rewards', group = 'Informant',
      kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Placer\'s look-up price ($)',
      inflight = AT_USE },
    { key = 'PlacerInformant.RevealChancePercent', section = 'limits', category = 'rules-limits', group = 'Informant',
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Placer\'s chance a look-up finds out (%)', inflight = AT_USE },
    { key = 'PlacerInformant.AlertChancePercent', section = 'limits', category = 'rules-limits', group = 'Informant',
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Chance the operative found out is told (%)', inflight = AT_USE },
    { key = 'PlacerInformant.MaxPurchasesPerContract', section = 'limits', group = 'Informant',
      category = 'rules-limits',
      kind = 'number', integer = true, min = 0, max = 20,
      label = 'Placer\'s look-ups per contract',
      inflight = 'Look-ups already made count against the new figure.' },
    { key = 'PlacerInformant.CooldownMinutes', section = 'limits', category = 'rules-timers', group = 'Informant',
      kind = 'number', integer = true, min = 0, max = 1440,
      label = 'Placer\'s wait between look-ups (min)', inflight = AT_USE },

    { key = 'LocationTip.Cost', section = 'limits', category = 'rules-rewards', group = 'Informant tip',
      kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Price of a tip ($)', inflight = AT_USE },
    { key = 'LocationTip.RadiusMeters', section = 'limits', category = 'rules-limits', group = 'Informant tip',
      kind = 'number', integer = true, min = 100, max = 2000,
      label = 'Radius of the area (m; shown twice this across)',
      inflight = 'Tips already bought keep the area they were shown.' },
    { key = 'LocationTip.ShowMinutes', section = 'limits', category = 'rules-timers', group = 'Informant tip',
      kind = 'number', integer = true, min = 1, max = 120, label = 'Minutes a tip is shown',
      inflight = 'Tips already bought keep the time they were sold with.' },
    { key = 'LocationTip.CooldownMinutes', section = 'limits', category = 'rules-timers', group = 'Informant tip',
      kind = 'number', integer = true, min = 0, max = 1440,
      label = 'Minutes between two tips on a contract', inflight = AT_USE },
    { key = 'LocationTip.MaxPurchasesPerContract', section = 'limits', group = 'Informant tip',
      category = 'rules-limits',
      kind = 'number', integer = true, min = 1, max = 50,
      label = 'Tips per contract, all its hitmen together', inflight = AT_USE },

    { key = 'Restart.PauseBeforeSeconds', section = 'limits', category = 'rules-timers', group = 'Server restart',
      kind = 'number', integer = true, min = 0, max = 3600,
      label = 'Pause contracts this long before a txAdmin restart (s, 0 = off)',
      inflight = 'A pause already on stays until the restart, a skip or its longest.' },
    { key = 'Restart.MaxHoldMinutes', section = 'limits', category = 'rules-timers', group = 'Server restart',
      kind = 'number', integer = true, min = 1, max = 240,
      label = 'Longest the pause lasts with no restart (min)',
      inflight = 'A pause already on ends at the new length.' },

    { key = 'Staff.DailySummaryHour', section = 'limits', category = 'rules-timers', group = 'Staff tools',
      kind = 'number', integer = true, min = 0, max = 23,
      label = 'Hour the daily summary is posted (server time, 0-23)',
      inflight = 'Read every tick: a summary already posted today is not posted again.' },
    { key = 'Staff.AlertPlacedPerHour', section = 'limits', category = 'rules-limits', group = 'Staff alerts',
      kind = 'number', integer = true, min = 0, max = 1000,
      label = 'Alert past this many contracts placed by one player in an hour (0 = off)',
      inflight = AT_USE },
    { key = 'Staff.AlertTargetPerDay', section = 'limits', category = 'rules-limits', group = 'Staff alerts',
      kind = 'number', integer = true, min = 0, max = 1000,
      label = 'Alert past this many contracts on one target in a day (0 = off)',
      inflight = AT_USE },
    { key = 'Staff.AlertRefusalsPer10Min', section = 'limits', category = 'rules-limits', group = 'Staff alerts',
      kind = 'number', integer = true, min = 0, max = 10000,
      label = 'Alert past this many refusals to one player in 10 minutes (0 = off)',
      inflight = AT_USE },

    { key = 'Kidnap.CountdownSeconds', section = 'limits', group = 'Handovers', kind = 'number',
      category = 'rules-timers',
      integer = true, min = 5, max = 600, label = 'Handover countdown (s)', inflight = AT_USE
          .. ' A countdown already running finishes at the new length.' },
    { key = 'Kidnap.Radius', section = 'limits', category = 'rules-limits', group = 'Handovers', kind = 'number',
      min = 2, max = 100, label = 'Handover radius (m)',
      inflight = 'A countdown already running keeps the radius it was armed with.' },
    { key = 'Kidnap.MinTargetHealthPercent', section = 'limits', category = 'rules-limits', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Least health to hand a target over (%)', inflight = AT_USE },

    { key = 'Bailout.MinMultiplier', section = 'limits', group = 'Buyout pricing', kind = 'number',
      category = 'rules-rewards',
      min = 0, max = 20, label = 'Least buyout, times the reward',
      inflight = 'New contracts only: a buyout price is fixed when the contract is placed.' },
    { key = 'Bailout.MaxMultiplier', section = 'limits', group = 'Buyout pricing', kind = 'number',
      category = 'rules-rewards',
      min = 0, max = 20, label = 'Most buyout, times the reward',
      inflight = 'New contracts only: a buyout price is fixed when the contract is placed, '
          .. 'and only comes down, to this many times what is left, when part of the reward '
          .. 'is taken back.' },
    { key = 'Bailout.AbsoluteMax', section = 'limits', group = 'Buyout pricing', kind = 'number',
      category = 'rules-rewards',
      integer = true, min = 0, max = 100000000, label = 'Most buyout ($)',
      inflight = 'New contracts only: a buyout price is fixed when the contract is placed, '
          .. 'and lowering this never re-prices one.' },

    { key = 'Targeting.NearbyRadius', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      min = 5, max = 200, label = 'Nearby list radius (m)', inflight = AT_USE },
    { key = 'Targeting.MaxNearby', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 1, max = 50, label = 'Names on the nearby list', inflight = AT_USE },
    { key = 'Targeting.NearbyClosedAfterSeconds', section = 'limits', category = 'rules-targeting', group = 'Targeting',
      kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Nearby list closed after a contract (s)', inflight = AT_USE },
    { key = 'Targeting.BrowsePageSize', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 5, max = 100, label = 'Names per page when browsing', inflight = AT_USE },
    { key = 'Targeting.MinQueryLength', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 1, max = 10, label = 'Shortest name search', inflight = AT_USE },
    { key = 'Targeting.MaxResults', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 1, max = 50, label = 'Results of a name search', inflight = AT_USE },

    { key = 'Ledger.PhotoRetentionDays', section = 'limits', group = 'Ledger', kind = 'number',
      category = 'rules-timers',
      integer = true, min = 0, max = 365, label = 'Days an unopened kill photo is kept (0 forever)',
      inflight = 'Looked at every ten minutes: photos already past a shorter age go then.',
      destroys = 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the '
          .. 'next sweep, for good.' },

    { key = 'Advisory.TriggerJobTypes', section = 'limits', category = 'rules-targeting', group = 'Advisory job lists',
      kind = 'list', label = 'Job types that raise an advisory', inflight = AT_USE },
    { key = 'Advisory.TriggerJobNames', section = 'limits', category = 'rules-targeting', group = 'Advisory job lists',
      kind = 'list', label = 'Job names that raise an advisory', inflight = AT_USE },
    { key = 'Advisory.RecipientJobTypes', section = 'limits', group = 'Advisory job lists',
      category = 'rules-targeting',
      kind = 'list', label = 'Job types that receive advisories', inflight = AT_USE },
    { key = 'Advisory.RecipientJobNames', section = 'limits', group = 'Advisory job lists',
      category = 'rules-targeting',
      kind = 'list', label = 'Job names that receive advisories', inflight = AT_USE },
    -- Every other setting in config.lua ------------------------------------
    -- Added so (close to) every setting is changed from the panel. Each is
    -- checked by the start-up checks like the rest (fits); a key that is
    -- read once at start says so (live = false) and is kept for the next one.
    { key = 'MaxContractValue', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 1, max = 100000000,
      label = 'Most a contract may hold ($)', about = 'The money a reward, its bonus and additions may '
          .. 'add up to.', inflight = CAP },
    { key = 'Sources.cash.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100000000, label = 'Most cash in a reward ($)',
      about = 'The cash one reward may hold.', inflight = CAP },
    { key = 'Sources.bank.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100000000, label = 'Most bank money in a reward ($)',
      about = 'The bank money one reward may hold.', inflight = CAP },
    { key = 'Sources.dirty.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100000000, label = 'Most dirty money in a reward ($)',
      about = 'The dirty money one reward may hold.', inflight = CAP },
    { key = 'Sources.dirty.item', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Dirty money item',
      about = 'The ox_inventory item dirty money is paid in.',
      inflight = 'Read at each payment: lines already in escrow keep the item they were taken as.' },
    { key = 'Sources.item.maxStacks', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100, label = 'Item stacks in a reward',
      about = 'How many stacks of items one reward may hold.', inflight = CAP },
    { key = 'Sources.item.maxPerStack', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 1, max = 100000, label = 'Items in one stack',
      about = 'The count one stack of a reward may hold.', inflight = CAP },
    { key = 'Sources.weapon.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 50, label = 'Weapons in a reward',
      about = 'How many weapons one reward may hold.', inflight = CAP },
    { key = 'Bonus.maxPercent', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 1000, label = 'Most a kidnapping bonus adds (%)',
      about = 'Under \'either\', the most a live-handover bonus may add to the reward.',
      inflight = 'Contracts keep the bonus they were placed with; new ones are held to it.' },
    { key = 'EscrowBlacklist', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'list', names = 'item', label = 'Items never put in a reward',
      about = 'ox_inventory item names a reward may not hold.',
      inflight = 'Items already in escrow are paid out or returned as before; new ones are refused.' },
    { key = 'PendingEscrow.MaxRetriesPerLogin', section = 'limits', category = 'rules-rewards',
      group = 'Payouts', kind = 'number', integer = true, min = 1, max = 100,
      label = 'Owed payouts tried at each login',
      about = 'How many payouts owed to a player one pass tries when they log in.', inflight = AT_USE },
    { key = 'PendingEscrow.LoginRetryDelayMs', section = 'limits', category = 'rules-rewards',
      group = 'Payouts', kind = 'number', integer = true, min = 0, max = 600000,
      label = 'Wait after login before paying (ms)',
      about = 'How long after a login what is owed is paid, so the inventory is loaded first.',
      inflight = AT_USE },
    { key = 'Bailout.ProcessingDelaySeconds', section = 'limits', category = 'rules-rewards',
      group = 'Buyouts', kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Hitman\'s head start on a buyout (s)',
      about = 'A held contract\'s hitman gets this long to finish before a buyout closes it.',
      inflight = 'A buyout already queued keeps the time it was queued at.' },
    { key = 'Informant.Account', section = 'limits', category = 'rules-rewards', group = 'Informant prices',
      kind = 'choice', choices = { 'bank', 'cash' }, label = 'Account the target\'s look-up is paid from',
      about = 'Where the target\'s informant price is taken from.', inflight = AT_USE },
    { key = 'PlacerInformant.Account', section = 'limits', category = 'rules-rewards',
      group = 'Informant prices', kind = 'choice', choices = { 'bank', 'cash' },
      label = 'Account the placer\'s look-up is paid from',
      about = 'Where the placer\'s informant price is taken from.', inflight = AT_USE },
    { key = 'LocationTip.Account', section = 'limits', category = 'rules-rewards',
      group = 'Informant prices', kind = 'choice', choices = { 'bank', 'cash' },
      label = 'Account a tip is paid from', about = 'Where the price of an informant tip is taken from.',
      inflight = AT_USE },

    { key = 'Completion.ProofWindowSeconds', section = 'limits', category = 'rules-timers',
      group = 'Completion', kind = 'number', integer = true, min = 0, max = 3600,
      label = 'Kill verifies this long after death (s)',
      about = 'A kill still verifies this long after the target died, even once they are back up.',
      inflight = AT_USE },
    { key = 'Completion.PhotoTokenLifetimeSeconds', section = 'limits', category = 'rules-timers',
      group = 'Completion', kind = 'number', integer = true, min = 10, max = 3600, client = true,
      label = 'Time to verify a kill (s)', about = 'How long a kill waits to be verified.',
      inflight = 'Applies to the next kill; one already waiting keeps its time.' },
    { key = 'Completion.PhotoOpenSeconds', section = 'limits', category = 'rules-timers',
      group = 'Completion', kind = 'number', integer = true, min = 10, max = 86400,
      label = 'Time the placer may view a photo (s)', about = 'After this the opened photo is deleted.',
      inflight = AT_USE },
    { key = 'Kidnap.RearmCooldownSeconds', section = 'limits', category = 'rules-timers',
      group = 'Handovers', kind = 'number', integer = true, min = 0, max = 3600,
      label = 'Wait after a failed handover (s)', about = 'Before a handover can be armed again.',
      inflight = AT_USE },
    { key = 'Amendments.ProposalExpirySeconds', section = 'limits', category = 'rules-timers',
      group = 'Proposals', kind = 'number', integer = true, min = 30, max = 86400,
      label = 'A proposal lapses after (s)', about = 'Open proposals between placer and hitman lapse.',
      inflight = 'Proposals already open keep the time they were given.' },
    { key = 'Amendments.CancelCooldownSeconds', section = 'limits', category = 'rules-timers',
      group = 'Proposals', kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Wait after calling a contract off (s)',
      about = 'Before the same placer may place another on that target.', inflight = AT_USE },
    { key = 'Informant.RerollLockMinutes', section = 'limits', category = 'rules-timers',
      group = 'Informant', kind = 'number', integer = true, min = 0, max = 1440,
      label = 'Same pick repeats its answer for (min)',
      about = 'The same look-up again this soon repeats the answer, free.', inflight = AT_USE },
    { key = 'Immunity.PostRespawnSeconds', section = 'limits', category = 'rules-timers',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Protected after a respawn (s)', about = 'Nobody may be targeted this long after a respawn.',
      inflight = AT_USE },
    { key = 'Immunity.AfterBailoutSeconds', section = 'limits', category = 'rules-timers',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Protected after a buyout (s)', about = 'Nobody may target them again this long after a buyout.',
      inflight = AT_USE },
    { key = 'Notifications.ParanoidAlertJitter', section = 'limits', category = 'rules-timers',
      group = 'Notifications', kind = 'range', integer = true, min = 0, max = 86400,
      label = 'Wait before "eyes on you" (s, from-to)',
      about = 'The target\'s alert waits a random time between these two.', inflight = AT_USE },
    { key = 'Notifications.ParanoidCooldownMinutes', section = 'limits', category = 'rules-timers',
      group = 'Notifications', kind = 'number', integer = true, min = 0, max = 1440,
      label = 'One "eyes on you" per target per (min)', about = 'At most one such alert in this long.',
      inflight = AT_USE },
    { key = 'Mugshot.MinRefreshMinutes', section = 'limits', category = 'rules-timers',
      group = 'Targeting', kind = 'number', integer = true, min = 0, max = 1440,
      label = 'Least time between two headshots (min)', about = 'Of one target.', inflight = AT_USE },

    { key = 'Completion.PhotoRadius', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'number', min = 1, max = 100, label = 'Distance to the body to verify (m)',
      about = 'How close the hitman must be to verify a kill.', inflight = AT_USE },
    { key = 'Completion.MaxWeaponRange', section = 'limits', category = 'rules-limits',
      group = 'Completion', kind = 'number', min = 10, max = 2000, label = 'Range a hit is believed from (m)',
      about = 'A hit reported from further than this is not counted.', inflight = AT_USE },
    { key = 'Completion.MedicJobs', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'list', label = 'Medic jobs', about = 'Jobs whose revive counts, as sc-ambulance\'s RequireEMS.',
      inflight = AT_USE },
    { key = 'Completion.DefibItem', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Defibrillator item',
      about = 'As sc-ambulance\'s Defib.Item.', inflight = AT_USE },
    { key = 'Completion.DefibRange', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'number', min = 0.5, max = 20, label = 'Defibrillator range (m)',
      about = 'As sc-ambulance\'s Defib.Distance.', inflight = AT_USE },
    { key = 'Kidnap.MaxConcurrentCountdowns', section = 'limits', category = 'rules-limits',
      group = 'Handovers', kind = 'number', integer = true, min = 1, max = 500,
      label = 'Handovers counting at once', about = 'Server-wide.', inflight = CAP },
    { key = 'Amendments.MaxOpenPerContract', section = 'limits', category = 'rules-limits',
      group = 'Proposals', kind = 'number', integer = true, min = 1, max = 10,
      label = 'Proposals open at once', about = 'On one contract.', inflight = CAP },
    { key = 'Informant.RevealMode', section = 'limits', category = 'rules-limits', group = 'Informant',
      kind = 'choice', choices = { 'name', 'description' }, label = 'What the target\'s look-up reveals',
      about = '\'name\': the hitman\'s name. \'description\': what they look like.', inflight = AT_USE },
    { key = 'Informant.ProximityRadius', section = 'limits', category = 'rules-limits', group = 'Informant',
      kind = 'number', min = 5, max = 2000, label = 'Distance that counts as near (m)',
      about = 'For an idle exclusive hold\'s clock.', inflight = AT_USE },
    { key = 'Informant.MaxPurchasesPerContract', section = 'limits', category = 'rules-limits',
      group = 'Informant', kind = 'number', integer = true, min = 0, max = 50,
      label = 'Target\'s look-ups per contract', about = 'Both kinds together.', inflight = AT_USE },
    { key = 'PlacerInformant.RevealMode', section = 'limits', category = 'rules-limits',
      group = 'Informant', kind = 'choice', choices = { 'name', 'description' },
      label = 'What the placer\'s look-up reveals',
      about = '\'name\': the operative\'s name. \'description\': what they look like.', inflight = AT_USE },
    { key = 'Reason.Mode', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'choice', choices = { 'preset', 'freetext', 'off' }, label = 'How a reason is given',
      about = '\'preset\': picked from the list. \'freetext\': typed. \'off\': none.',
      inflight = 'Contracts keep the reason they were placed with.' },
    { key = 'Reason.MaxLength', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'number', integer = true, min = 10, max = 255, label = 'Longest reason (characters)',
      about = '255 at most on mysql.', inflight = AT_USE },
    { key = 'Reason.MaxDigits', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'number', integer = true, min = 0, max = 50, label = 'Digits a reason may hold',
      about = 'Kept low so no phone number is posted.', inflight = AT_USE },
    { key = 'Reason.Presets', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'list', array = true, names = 'phrase', label = 'Reasons to pick from',
      about = 'The choices in \'preset\' mode, in order.', inflight = AT_USE },
    { key = 'Notifications.MaxPerRecipientPerMinute', section = 'limits', category = 'rules-limits',
      group = 'Notifications', kind = 'number', integer = true, min = 1, max = 100,
      label = 'Notices a player may get a minute', about = 'Above it, notices are dropped.',
      inflight = AT_USE },
    { key = 'Notifications.MaxPerRecipientPerHour', section = 'limits', category = 'rules-limits',
      group = 'Notifications', kind = 'number', integer = true, min = 1, max = 1000,
      label = 'Notices a player may get an hour', about = 'Above it, notices are dropped.',
      inflight = AT_USE },
    { key = 'Advisory.DispatchPriority', section = 'limits', category = 'rules-limits',
      group = 'Law enforcement advisory', kind = 'number', integer = true, min = 1, max = 3,
      label = 'Dispatch priority', about = 'The sc-dispatch priority of an advisory.', inflight = AT_USE },
    { key = 'Relay.MaxLength', section = 'limits', category = 'rules-limits', group = 'Messages and calls',
      kind = 'number', integer = true, min = 10, max = 255, label = 'Longest message (characters)',
      about = '255 at most on mysql.', inflight = AT_USE },
    { key = 'Relay.MaxMessagesPerThread', section = 'limits', category = 'rules-limits',
      group = 'Messages and calls', kind = 'number', integer = true, min = 10, max = 1000,
      label = 'Messages a thread keeps', about = 'The newest are kept.', inflight = AT_USE },
    { key = 'Ledger.Depth', section = 'limits', category = 'rules-limits', group = 'Ledger',
      kind = 'number', integer = true, min = 1, max = 100, ceiling = 'Ledger.MaxDepthHardCap',
      label = 'Ledger rows per player', about = 'At most the hard cap below.', inflight = AT_USE },
    { key = 'Ledger.MaxDepthHardCap', section = 'limits', category = 'rules-limits', group = 'Ledger',
      kind = 'number', integer = true, min = 1, max = 100, label = 'Ledger rows hard cap',
      about = 'The ceiling on Ledger rows per player.', inflight = AT_USE },
    { key = 'Progression.TrustPerElimination', section = 'limits', category = 'rules-limits',
      group = 'Progression', kind = 'number', integer = true, min = 0, max = 10000,
      label = 'Trust per kill', about = 'sc-blackmarket trust a completed kill earns.', inflight = AT_USE },
    { key = 'Progression.TrustPerKidnapping', section = 'limits', category = 'rules-limits',
      group = 'Progression', kind = 'number', integer = true, min = 0, max = 10000,
      label = 'Trust per live handover', about = 'sc-blackmarket trust a handover earns.', inflight = AT_USE },
    { key = 'Listing.PageSize', section = 'limits', category = 'rules-limits', group = 'The app',
      kind = 'number', integer = true, min = 5, max = 100, label = 'Contracts per board page',
      about = 'On the app\'s board.', inflight = AT_USE },
    { key = 'Limits.JailZone.x', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', min = -10000, max = 10000, label = 'Prison grounds centre, x',
      about = 'Where the prison grounds are.', inflight = AT_USE },
    { key = 'Limits.JailZone.y', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', min = -10000, max = 10000, label = 'Prison grounds centre, y',
      about = 'Where the prison grounds are.', inflight = AT_USE },
    { key = 'Bailout.Command', section = 'limits', category = 'rules-limits', group = 'Buyouts',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 32, live = false,
      label = 'Buyout command', about = 'For players who cannot open the app.', inflight = RESTART },

    { key = 'BlockedJobTypes', section = 'limits', category = 'rules-targeting', group = 'Barred jobs',
      kind = 'list', label = 'Job types barred from the app',
      about = 'Players on these job types cannot use the app.',
      inflight = AT_USE .. ' Who may see the app is checked again at once.' },
    { key = 'BlockedJobNames', section = 'limits', category = 'rules-targeting', group = 'Barred jobs',
      kind = 'list', label = 'Job names barred from the app',
      about = 'Players on these jobs cannot use the app, besides the types.',
      inflight = AT_USE .. ' Who may see the app is checked again at once.' },
    { key = 'Immunity.MinTargetPlaytimeHours', section = 'limits', category = 'rules-targeting',
      group = 'Immunity', kind = 'number', min = 0, max = 10000,
      label = 'Hours played before being a target (0 off)', about = 'New players are protected.',
      inflight = AT_USE },
    { key = 'Immunity.MinTargetSessionMinutes', section = 'limits', category = 'rules-targeting',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 1440,
      label = 'Minutes in the city this session', about = 'Before anyone may target them.',
      inflight = AT_USE },
    { key = 'Immunity.GrandfatherDays', section = 'limits', category = 'rules-targeting',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 365,
      label = 'Days of grandfathering', about = 'Only without qbx_core\'s players table.',
      inflight = AT_USE },

    { key = 'Database.Json.WarnContractCount', section = 'limits', category = 'developer', group = 'Storage',
      kind = 'number', integer = true, min = 100, max = 1000000, label = 'json: warn above this many contracts',
      about = 'A console warning past it.', inflight = AT_USE },
    { key = 'Database.Json.MaxDirtyShardsPerFlush', section = 'limits', category = 'developer',
      group = 'Storage', kind = 'number', integer = true, min = 1, max = 1000,
      label = 'json: contract files one flush writes', about = 'The rest wait for the next flush.',
      inflight = AT_USE },
    { key = 'Audit.FlushIntervalMs', section = 'limits', category = 'developer', group = 'Audit and debug',
      kind = 'number', integer = true, min = 1000, max = 600000, label = 'Audit flush interval (ms)',
      about = 'How often queued log rows are written; it paces every maintenance job.',
      inflight = 'Read at the next flush.' },
    { key = 'Audit.MaxQueueSize', section = 'limits', category = 'developer', group = 'Audit and debug',
      kind = 'number', integer = true, min = 100, max = 100000, label = 'Log rows queued at most',
      about = 'Past it, the oldest are written at once.', inflight = AT_USE },
    { key = 'Audit.RetentionDays', section = 'limits', category = 'developer', group = 'Audit and debug',
      kind = 'number', integer = true, min = 0, max = 3650, label = 'Days the log is kept (0 forever)',
      about = 'Older rows are deleted by the next sweep.',
      destroys = 'Lowering it to %s deletes every log row older than that at the next sweep, for good.',
      inflight = 'Read at the next sweep.' },
    { key = 'Audit.ContractRetentionDays', section = 'limits', category = 'developer',
      group = 'Audit and debug', kind = 'number', integer = true, min = 0, max = 3650,
      label = 'Days a finished contract is kept (0 forever)',
      about = 'Finished contracts older than this are deleted by the next sweep.',
      destroys = 'Lowering it to %s deletes every finished contract older than that, for good.',
      inflight = 'Read at the next sweep.' },
    { key = 'Audit.ContractsPrunedPerTick', section = 'limits', category = 'developer',
      group = 'Audit and debug', kind = 'number', integer = true, min = 1, max = 10000,
      label = 'Finished contracts removed per sweep', about = 'Paces the sweep.', inflight = AT_USE },
    { key = 'Diagnostics.SlowJobMs', section = 'limits', category = 'developer', group = 'Diagnostics',
      kind = 'number', integer = true, min = 0, max = 60000, label = 'Slow job threshold (ms, 0 never)',
      about = 'A maintenance job slower than this prints a Debug line.', inflight = AT_USE },
    { key = 'Kidnap.MaxTotalGraceMs', section = 'limits', category = 'developer', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 60000, label = 'Handover break allowed (ms)',
      about = 'In all, before a handover fails.', inflight = AT_USE },
    { key = 'Kidnap.TickMs', section = 'limits', category = 'developer', group = 'Handovers',
      kind = 'number', integer = true, min = 250, max = 5000, label = 'Handover check interval (ms)',
      about = 'How often a running handover is checked.', inflight = 'Read at the next check.' },
    { key = 'Completion.DeathReportWindowMs', section = 'limits', category = 'developer',
      group = 'Completion', kind = 'number', integer = true, min = 1000, max = 600000,
      label = 'A hit counts this long before a death (ms)', about = 'For the damage log.',
      inflight = AT_USE },
    { key = 'Completion.ConditionSampleMs', section = 'limits', category = 'developer',
      group = 'Completion', kind = 'number', integer = true, min = 250, max = 10000,
      label = 'Targets\' health sampled every (ms)', about = 'Server-wide.', inflight = 'Read at the next sample.' },
    { key = 'Completion.PhotoMaxSide', section = 'limits', category = 'developer', group = 'Completion',
      kind = 'number', integer = true, min = 320, max = 4096, label = 'Photo longest side (px)',
      about = '\'server\' storage.', inflight = AT_USE },
    { key = 'Completion.PhotoMaxBytes', section = 'limits', category = 'developer', group = 'Completion',
      kind = 'number', integer = true, min = 10000, max = 10000000, label = 'Largest photo (bytes)',
      about = '\'server\' storage.', inflight = AT_USE },
    { key = 'Completion.PhotoHostRefreshSeconds', section = 'limits', category = 'developer',
      group = 'Completion', kind = 'number', integer = true, min = 30, max = 86400,
      label = 'Re-read lb-phone\'s image hosts every (s)', about = '\'host\' storage.',
      inflight = 'Read at the next re-read.' },
    { key = 'Completion.ExtraPhotoHosts', section = 'limits', category = 'developer', group = 'Completion',
      kind = 'list', array = true, names = 'host', label = 'Image hosts allowed besides lb-phone\'s',
      about = '\'host\' storage: host names, such as fivemanage.com.', inflight = AT_USE },
    { key = 'Mugshot.RenderTimeoutMs', section = 'limits', category = 'developer', group = 'Targeting',
      kind = 'number', integer = true, min = 1000, max = 60000, label = 'Time a headshot may take (ms)',
      about = 'On the target\'s game.', inflight = AT_USE },
    { key = 'Mugshot.MaxImageBytes', section = 'limits', category = 'developer', group = 'Targeting',
      kind = 'number', integer = true, min = 4096, max = 1048576, label = 'Largest headshot (bytes)',
      about = 'A larger one is refused.', inflight = AT_USE },
    { key = 'Mugshot.AllowedMime', section = 'limits', category = 'developer', group = 'Targeting',
      kind = 'list', names = 'mime', label = 'Headshot image types accepted',
      about = 'Such as image/png.', inflight = AT_USE },
    { key = 'Bailout.MaxSettleAttempts', section = 'limits', category = 'developer', group = 'Buyouts',
      kind = 'number', integer = true, min = 1, max = 100, label = 'Ticks a buyout waits on a stuck claim',
      about = 'Then it is left for staff.', inflight = AT_USE },
    { key = 'Notifications.PushMinIntervalSeconds', section = 'limits', category = 'developer',
      group = 'Notifications', kind = 'number', integer = true, min = 1, max = 60,
      label = 'Least time between two app refreshes (s)', about = 'Per open app.', inflight = AT_USE },
    { key = 'Admin.PanelPageSize', section = 'limits', category = 'developer', group = 'Staff',
      kind = 'number', integer = true, min = 5, max = 100, label = 'Rows per page in this panel',
      about = 'Its lists.', inflight = 'Read at the next page asked for.' },
    { key = 'Admin.PanelRefreshSeconds', section = 'limits', category = 'developer', group = 'Staff',
      kind = 'number', integer = true, min = 2, max = 300, label = 'Overview refresh (s)',
      about = 'How often this panel\'s overview refreshes.', inflight = 'Read when the panel is opened.' },
    { key = 'Admin.TimelineRows', section = 'limits', category = 'developer', group = 'Staff',
      kind = 'number', integer = true, min = 10, max = 2000, label = 'Log rows read for one timeline',
      about = 'A contract\'s history.', inflight = AT_USE },
    { key = 'RateLimit.Key', section = 'limits', category = 'developer', group = 'Rate limits',
      kind = 'choice', choices = { 'license', 'citizenid' }, label = 'Rate limits counted per',
      about = '\'license\': per account. \'citizenid\': per character.',
      inflight = 'Read at each request: allowances start fresh under the new key.' },
}

--- Each staff command's name, read once at start (RegisterCommand): kept,
--- and in force after a restart.
for _, name in ipairs({ 'timeline', 'void', 'stuck', 'settle', 'whois', 'contracts', 'diagnose',
    'refresh', 'review', 'panel' }) do
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Admin.Commands.' .. name, section = 'limits', category = 'developer', group = 'Staff commands',
        kind = 'text', pattern = '^[%w_%-]+$', maxLength = 32, live = false,
        label = 'Command name: ' .. name, about = 'Without the slash.', inflight = RESTART,
    }
end

--- The rate-limit buckets, each as two keys: how many seconds a full
--- bucket refills over, and how many it holds.
local BUCKETS = {
    'load', 'search', 'wallet', 'create', 'accept', 'amend', 'informant', 'placerInformant', 'locationTip',
    'bailout', 'photo',
    'photoSubmit', 'photoView', 'photoDecide', 'message', 'progress', 'death', 'mugshot',
    'image', 'diagnostic', 'admin', 'adminWrite', 'report', 'org', 'orgWrite', 'disposal',
}

--- What each bucket gates: the buttons and events a player is refused once
--- it is spent. The rows said only '<bucket>: requests held', and one click
--- of 'load' from 20 to 1 refused every Board, Mine and Ledger read for an
--- hour. The background ones are refused without a word to anybody.
local BUCKET_ABOUT = {
    load = 'Every read the app makes of its own state: Board, Mine, On me, the Ledger, proposals, '
        .. 'threads and the whitelisted-job view, and the buyout command\'s list. Opening the app '
        .. 'is four of these at once, and every refresh two more.',
    search = 'Browsing and searching names on the Place form.',
    wallet = 'Reading what the placer carries, once per Place form.',
    create = 'Placing a contract.',
    accept = 'Accepting, abandoning and cancelling a contract, and arming a handover.',
    amend = 'Proposals and the answers to them, revising, improving and adding to a reward, and '
        .. 'taking part of it back.',
    informant = 'A target\'s look-up from the informant.',
    placerInformant = 'A placer\'s look-up from the informant on an operative.',
    locationTip = 'Buying an informant tip on a target\'s rough area.',
    bailout = 'Buying out a contract, in the app and with the buyout command.',
    photo = 'Asking to photograph a kill, and Verify kill.',
    photoSubmit = 'Sending a kill photo.',
    photoView = 'Opening a kill photo from the Ledger.',
    photoDecide = 'Saving or deleting a kill photo just opened.',
    message = 'Placing and ending a call, muting a thread, and turning Notify me on the '
        .. 'whitelisted-job view on or off.',
    progress = 'In the background: the handover countdown the app asks for once a second while a '
        .. 'handover runs. Refused without a word: the countdown stops moving on the page.',
    death = 'In the background: death and revive reports from players\' games. Refused without a '
        .. 'word: a death or a revive not recorded, so a target just up can be listed at once.',
    mugshot = 'In the background: the headshots players\' games send, and their word that a face '
        .. 'changed. Refused without a word to the player (the log keeps one row a minute): '
        .. 'faces on the board stay old or missing.',
    image = 'Fetching a headshot the board was given a reference to.',
    diagnostic = 'Fault reports players\' apps send. The log staff ask for with the diagnosis '
        .. 'never spends it.',
    report = 'Reporting a contract or a message thread to staff (the Report button). Each one '
        .. 'is an item in the review queue.',
    org = 'Reading the hitman organisation in the app: the Organisation tab, its roster, roles, funds '
        .. 'and applications.',
    orgWrite = 'What a boss or member changes in the hitman organisation from the app: hiring, roles, '
        .. 'cuts, money, places, notices and applications.',
    disposal = 'Loading a body and dropping it off (Config.Disposal). Refused without a word: the '
        .. 'hitman tries again a moment later.',
}

--- The least the buckets the app cannot work without may be set to from
--- here. Set from config.lua, a value below them is the owner's to choose;
--- one click here could otherwise stop the app opening, or stop a handover
--- running, for everyone at once.
local BUCKET_FLOORS = {
    load = { burst = 6, rate = 1 / 5,
             needs = 'at least 6 requests held and a refill of at least one every 5 seconds',
             why = 'opening the app sends four reads at once (the board, Mine, the Ledger and the '
                 .. 'view), so below that the app cannot open' },
    progress = { rate = 1, needs = 'a refill of at least one a second',
                 why = 'a running handover asks for its countdown once a second' },
    death = { burst = 2, needs = 'at least 2 requests held',
              why = 'a death and the revive after it are a report each' },
}

--- What a stricter value does, said beside the second click: %s the value.
local BUCKET_STRICTER = '%s: players are refused sooner, and wait longer for it to refill. '
    .. 'What this gates (above) answers "slow down" until it does.'

--- The panel's own buckets, which every request it makes spends (Panel.handle).
--- Changeable here, one request an hour was accepted, kept and applied at
--- every start, and the page's own overview refresh spent it: the reset that
--- would have put it back was refused with the rest, and only an edit of the
--- store by hand let staff in again.
local PANEL_BUCKETS = { admin = true, adminWrite = true }
local PANEL_BUCKET_READONLY = 'The staff panel\'s own allowance, which every request it makes '
    .. 'spends: set too low from here it would refuse the very request that puts it back, at '
    .. 'every start. Set it in config.lua.'

--- Each bucket's two rows. `stricter` is the way a value refuses players
--- sooner (a longer refill window, fewer requests held), which takes two
--- clicks with `strict` said beside the second, as `destroys` does.
for _, bucket in ipairs(BUCKETS) do
    local panel = PANEL_BUCKETS[bucket]
    local gates = BUCKET_ABOUT[bucket]
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Cooldowns.' .. bucket .. '.per', section = panel and 'readonly' or 'limits', category = 'developer',
        group = panel and 'Staff' or 'Rate limits',
        kind = 'number', min = 0.5, max = 3600, label = bucket .. ': refill window (s)',
        about = gates and (gates .. ' A full allowance refills over this many seconds: '
            .. 'longer is stricter.') or nil,
        stricter = not panel and 'up' or nil,
        strict = not panel and ('A refill window of ' .. BUCKET_STRICTER) or nil,
        inflight = not panel and AT_USE or nil, readonly = panel and PANEL_BUCKET_READONLY or nil,
    }
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Cooldowns.' .. bucket .. '.burst', section = panel and 'readonly' or 'limits', category = 'developer',
        group = panel and 'Staff' or 'Rate limits',
        kind = 'number', integer = true, min = 1, max = 200, label = bucket .. ': requests held',
        about = gates and (gates .. ' How many it allows at once. It also sets the refill rate '
            .. '(this many per refill window), so fewer is stricter both ways.') or nil,
        stricter = not panel and 'down' or nil,
        strict = not panel and ('Holding ' .. BUCKET_STRICTER) or nil,
        inflight = not panel and AT_USE or nil, readonly = panel and PANEL_BUCKET_READONLY or nil,
    }
end

--- The roleplay consequences (server/rp_consequences.lua, README, Optional
--- features): each switch under Features, the rest under the Rules view it
--- belongs to. `whole` lists take each line as typed, spaces and commas
--- included (a phrase, a template, an area), rather than as names.
local RP_TEXT = 'letters, digits, spaces and punctuation, no < or >'
for _, entry in ipairs({
    -- Witness heat
    { key = 'Roleplay.WitnessHeat.Enabled', category = 'features', group = 'Roleplay: Witness heat',
      kind = 'switch', label = 'Witness heat',
      about = 'A completion seen by bystanders (players near the hitman who are no party to the '
          .. 'contract) sends the police a vague witness report on their phones and to sc-dispatch. '
          .. 'It never names the hitman or the placer.',
      inflight = 'At the next completion, with no restart.' },
    { key = 'Roleplay.WitnessHeat.AlwaysAlert', category = 'features', group = 'Roleplay: Witness heat',
      kind = 'switch', label = 'Witness heat: alert on every completion',
      about = 'A report on every completion, whether anybody saw it or not.', inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.SendCoords', category = 'features', group = 'Roleplay: Witness heat',
      kind = 'switch', label = 'Witness heat: give dispatch a position',
      about = 'Off: only the area is named. On: a position, moved by up to the fuzz distance.',
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.WitnessRadius', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', min = 1, max = 500, label = 'Metres a bystander sees a completion from',
      about = 'Measured from the hitman, on the server.', inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.MinWitnesses', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Bystanders it takes to raise a report',
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.FuzzMeters', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', min = 0, max = 1000, label = 'Metres the position may be off by',
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.DispatchPriority', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', integer = true, min = 1, max = 5, label = 'sc-dispatch priority of a report',
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.Title', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'text', pattern = '^[^%c<>]+$', maxLength = 60, says = RP_TEXT,
      label = 'Title of a witness report', inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.Phrases', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'list', array = true, whole = true, names = 'phrase', label = 'What a witness says',
      about = 'One is picked. {direction} is where they went (north, south-west, ...).',
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.Areas', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'list', array = true, whole = true, names = 'area', label = 'Areas, as Name@x,y',
      about = 'The nearest centre names the area of a report and of a news post.', inflight = AT_USE },
    -- EMS before re-listing
    { key = 'Roleplay.EmsRelisting.Enabled', category = 'features', group = 'Roleplay: EMS before re-listing',
      kind = 'switch', label = 'EMS before re-listing',
      about = 'After a contract on somebody completes by a kill, a new contract on them is refused '
          .. '("They are still recovering.") until they have been up, neither dead nor downed, for '
          .. 'the minutes under Rules > Timers. On top of the usual cooldowns.',
      inflight = 'At the next contract placed, with no restart.' },
    { key = 'Roleplay.EmsRelisting.RequireEMS', category = 'features', group = 'Roleplay: EMS before re-listing',
      kind = 'switch', label = 'EMS before re-listing: a medic\'s revive is needed',
      about = 'Instead of the minutes up: an on-duty medic\'s defibrillator on them (sc-ambulance\'s '
          .. 'own event, checked as the kill logic checks it). A kill from before a restart falls '
          .. 'back to the minutes up.', inflight = AT_USE },
    { key = 'Roleplay.EmsRelisting.TreatedMinutes', category = 'rules-timers', group = 'Roleplay: EMS before re-listing',
      kind = 'number', integer = true, min = 0, max = 240, label = 'Minutes up that count as treated',
      inflight = AT_USE },
    { key = 'Roleplay.EmsRelisting.MaxHoldMinutes', category = 'rules-timers', group = 'Roleplay: EMS before re-listing',
      kind = 'number', integer = true, min = 1, max = 1440, label = 'Longest the rule holds after a kill (min)',
      about = 'Past it, the target may be listed again whatever was seen.', inflight = AT_USE },
    -- City news
    { key = 'Roleplay.CityNews.Enabled', category = 'features', group = 'Roleplay: City news',
      kind = 'switch', label = 'City news',
      about = 'A completed contract on a whitelisted-job target posts an anonymous news item, on '
          .. 'lb-phone\'s Birdy or through a server event. It names the job, the area and the time, '
          .. 'never the hitman or the placer.',
      inflight = 'At the next completion, with no restart.' },
    { key = 'Roleplay.CityNews.AllTargets', category = 'features', group = 'Roleplay: City news',
      kind = 'switch', label = 'City news: on every target',
      about = 'Off: whitelisted-job targets only.', inflight = AT_USE },
    { key = 'Roleplay.CityNews.NameTarget', category = 'features', group = 'Roleplay: City news',
      kind = 'switch', label = 'City news: name the target',
      about = 'On, {name} in a template is the target\'s name; off, it is "a resident". Nothing '
          .. 'else names anybody.', inflight = AT_USE },
    { key = 'Roleplay.CityNews.App', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'choice', choices = { 'birdy', 'event' }, label = 'Where news is posted',
      about = '\'birdy\': lb-phone\'s PostBirdy export. \'event\': a server event another resource '
          .. 'posts from (lb-phone\'s News app has no server export).', inflight = AT_USE },
    { key = 'Roleplay.CityNews.Account', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'text', pattern = '^[%w_%-%.]+$', maxLength = 32, label = 'Birdy account news is posted from',
      about = 'It must exist in lb-phone.', inflight = AT_USE },
    { key = 'Roleplay.CityNews.Event', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'text', pattern = '^[%w_%-%.:]+$', maxLength = 64, says = 'an event name: letters, digits, - _ . and :',
      label = 'Server event news is fired as (\'event\')',
      about = 'Fired on the server only, with { account, text }.', inflight = AT_USE },
    { key = 'Roleplay.CityNews.Templates', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'list', array = true, whole = true, names = 'sentence', label = 'News templates',
      about = 'One is picked: {job}, {zone}, {time} and {name}.', inflight = AT_USE },
    -- Dirty money payouts
    { key = 'Roleplay.DirtyPayouts.Enabled', category = 'features', group = 'Roleplay: Dirty money payouts',
      kind = 'switch', label = 'Dirty money payouts',
      about = 'A hitman\'s cash or bank payout is handed over as a dirty money item instead, at a '
          .. 'rate that loses nothing. Escrow keeps the money it took; a refund goes back as it was '
          .. 'taken; a payout that does not fit is owed, as any other.',
      inflight = 'At the next payout, owed ones included, with no restart.' },
    { key = 'Roleplay.DirtyPayouts.Item', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Item a payout is paid as',
      about = 'An ox_inventory item: black_money, or markedbills with the \'worth\' mode.',
      inflight = AT_USE },
    { key = 'Roleplay.DirtyPayouts.Mode', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'choice', choices = { 'count', 'worth' }, label = 'How the item holds the money',
      about = '\'count\': items by the rate. \'worth\': one item, its value in its metadata.',
      inflight = AT_USE },
    { key = 'Roleplay.DirtyPayouts.WorthKey', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 32, label = 'Metadata key of its value (\'worth\')',
      inflight = AT_USE },
    { key = 'Roleplay.DirtyPayouts.Rate', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'number', integer = true, min = 1, max = 100, label = 'Items paid for each dollar (\'count\')',
      inflight = AT_USE },
}) do
    entry.section = entry.category == 'features' and 'features' or 'limits'
    CATALOGUE[#CATALOGUE + 1] = entry
end
for _, key in ipairs({ 'Roleplay.DirtyPayouts.Item', 'Roleplay.DirtyPayouts.Mode',
    'Roleplay.DirtyPayouts.WorthKey', 'Roleplay.DirtyPayouts.Rate' }) do
    MONEY[key] = 'Payouts'
end

--- Roleplay (group rpC, README, Optional features): proof of intent, earned
--- reputation, bodyguards and the hit on the hitman. Each switch under
--- Features, each figure under Rules; all read at use, with no restart.
local RP_INTENT, RP_REPUTATION = 'Roleplay: Proof of intent', 'Roleplay: Reputation'
local RP_PROTECTION, RP_HIT = 'Roleplay: Bodyguards', 'Roleplay: Hit on the hitman'
for _, entry in ipairs({
    { key = 'Roleplay.ProofOfIntent.Enabled', section = 'features', category = 'features', group = RP_INTENT,
      kind = 'switch', label = 'Proof of intent before a payout',
      about = 'A payout waits until the hitman sent enough messages to the placer in the thread, or the '
          .. 'contract had a live handover or a meeting point; released anyway after the hold time.',
      inflight = 'Read at every give. Turned off, every held payout is handed over at its next try.' },
    { key = 'Roleplay.ProofOfIntent.MinMessages', section = 'limits', category = 'rules-limits', group = RP_INTENT,
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Messages to the placer that count as intent (0 = none needed)', inflight = AT_USE },
    { key = 'Roleplay.ProofOfIntent.HoldMaxMinutes', section = 'limits', category = 'rules-timers', group = RP_INTENT,
      kind = 'number', integer = true, min = 1, max = 10080,
      label = 'Longest a payout is held for proof of intent (min)',
      inflight = 'Read at every give: a hold already on ends at the new length.' },

    { key = 'Roleplay.Reputation.Enabled', section = 'features', category = 'features', group = RP_REPUTATION,
      kind = 'switch', label = 'Reputation earned in character',
      about = 'The progression trust a completion earns is scaled: a base factor, plus bonuses for the '
          .. 'thread used, a meeting point, a live handover and no witnesses, up to a cap. The hitman '
          .. 'sees the breakdown on their completion notice.',
      inflight = 'Read at each completion; trust already given stands.' },
    { key = 'Roleplay.Reputation.BaseFactor', section = 'limits', category = 'rules-limits', group = RP_REPUTATION,
      kind = 'number', min = 0, max = 10, label = 'Trust factor for a plain completion', inflight = AT_USE },
    { key = 'Roleplay.Reputation.ThreadBonus', section = 'limits', category = 'rules-limits', group = RP_REPUTATION,
      kind = 'number', min = 0, max = 10, label = 'Bonus: the hitman wrote in the thread', inflight = AT_USE },
    { key = 'Roleplay.Reputation.MeetingBonus', section = 'limits', category = 'rules-limits', group = RP_REPUTATION,
      kind = 'number', min = 0, max = 10, label = 'Bonus: a meeting point was set', inflight = AT_USE },
    { key = 'Roleplay.Reputation.HandoverBonus', section = 'limits', category = 'rules-limits', group = RP_REPUTATION,
      kind = 'number', min = 0, max = 10, label = 'Bonus: a live handover', inflight = AT_USE },
    { key = 'Roleplay.Reputation.WitnessFreeBonus', section = 'limits', category = 'rules-limits',
      group = RP_REPUTATION, kind = 'number', min = 0, max = 10, label = 'Bonus: no witnesses',
      inflight = AT_USE },
    { key = 'Roleplay.Reputation.WitnessRadius', section = 'limits', category = 'rules-limits', group = RP_REPUTATION,
      kind = 'number', min = 1, max = 500, label = 'Witness radius around the hitman (m)', inflight = AT_USE },
    { key = 'Roleplay.Reputation.MaxFactor', section = 'limits', category = 'rules-limits', group = RP_REPUTATION,
      kind = 'number', min = 0, max = 10, label = 'Most the trust factor may reach', inflight = AT_USE },

    { key = 'Roleplay.Protection.Enabled', section = 'features', category = 'features', group = RP_PROTECTION,
      kind = 'switch', label = 'Bodyguard contracts',
      about = 'A target may post an anonymous protection job from On me, its reward taken at once; another '
          .. 'player takes it from the board\'s Protection tab and gets the target\'s name and meeting pin, '
          .. 'never who placed the hit or who is on it. Paid when the contract ends without a completion.',
      inflight = 'Turned off, no job is posted or taken; jobs already posted are still paid or refunded '
          .. 'when their contract ends.' },
    { key = 'Roleplay.Protection.Account', section = 'limits', category = 'rules-rewards', group = RP_PROTECTION,
      kind = 'choice', choices = { 'cash', 'bank' }, label = 'Bodyguard reward paid from',
      inflight = 'New jobs only: a job is paid out from the account it was taken from.' },
    { key = 'Roleplay.Protection.MinReward', section = 'limits', category = 'rules-rewards', group = RP_PROTECTION,
      kind = 'number', integer = true, min = 1, max = 10000000, label = 'Least bodyguard reward ($)',
      inflight = 'New jobs only.' },
    { key = 'Roleplay.Protection.MaxReward', section = 'limits', category = 'rules-rewards', group = RP_PROTECTION,
      kind = 'number', integer = true, min = 1, max = 10000000, label = 'Most bodyguard reward ($)',
      inflight = 'New jobs only.' },
    { key = 'Roleplay.Protection.PayOnCompletionPercent', section = 'limits', category = 'rules-rewards',
      group = RP_PROTECTION, kind = 'number', integer = true, min = 0, max = 100,
      label = 'Guard\'s share if the contract completes anyway (%)',
      inflight = 'Read when the contract ends.' },
    { key = 'Roleplay.Protection.MaxJobsPerGuard', section = 'limits', category = 'rules-limits', group = RP_PROTECTION,
      kind = 'number', integer = true, min = 1, max = 20, label = 'Protection jobs one guard holds at once',
      inflight = CAP },

    { key = 'Roleplay.HitOnHitman.Enabled', section = 'features', category = 'features', group = RP_HIT,
      kind = 'switch', label = 'Hit on the hitman',
      about = 'A target whose informant found out an operative\'s name may place a contract on them from '
          .. 'that card: the Place form opens with them chosen, and every rule of placing applies.',
      inflight = AT_USE },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end
MONEY['Roleplay.Protection.Account'] = 'Payouts'
MONEY['Roleplay.Protection.MinReward'] = 'Payouts'
MONEY['Roleplay.Protection.MaxReward'] = 'Payouts'
MONEY['Roleplay.Protection.PayOnCompletionPercent'] = 'Payouts'

--- The roleplay features (server/rp_*.lua, Config.Roleplay), each off as
--- shipped: the switch under Features, the rest under the rules they are.
--- `whole` on a list: what is typed is one entry, spaces and commas kept
--- (a place, a phrase), not names split at each.
local RP_RUMOURS, RP_BURNER = 'Roleplay: Rumours and broker', 'Roleplay: Burner phone'
local RP_INFORMANT, RP_REASON = 'Roleplay: Informant in person', 'Roleplay: Reason quality'
local PLACES = 'Each place is x, y, z, heading. The NPC stands at one at a time.'
local NPC_MOVES = 'Every game is told at once, and draws the NPC in its new place.'
for _, entry in ipairs({
    { key = 'Roleplay.Rumours.Enabled', section = 'features', category = 'features', group = RP_RUMOURS,
      kind = 'switch', label = 'Rumours and the broker',
      about = 'The board shows a new contract only as a rumour (an area and a reward band) until '
          .. 'the broker briefs the hitman.',
      inflight = 'Read at every board read and Accept: on, hitmen not yet briefed see rumours at '
          .. 'once; contracts already held are untouched.' },
    { key = 'Roleplay.Rumours.AreaMode', section = 'limits', category = 'rules-targeting', group = RP_RUMOURS,
      kind = 'choice', choices = { 'district', 'zones' }, label = 'What area a rumour names',
      about = '"district": the nearest of Districts to where the target was. "zones": a name '
          .. 'from Zones.', inflight = 'Rumours already told keep the area they named.' },
    { key = 'Roleplay.Rumours.Zones', section = 'limits', category = 'rules-targeting', group = RP_RUMOURS,
      kind = 'list', array = true, whole = true, names = 'phrase', label = 'Zone names',
      about = 'Vague area names a rumour picks from.', inflight = AT_USE },
    { key = 'Roleplay.Rumours.Districts', section = 'limits', category = 'rules-targeting',
      group = RP_RUMOURS, kind = 'list', array = true, whole = true, names = 'area',
      label = 'Districts (x, y, name)', about = 'The nearest one to the target names the area.',
      inflight = 'Rumours already told keep the area they named.' },
    { key = 'Roleplay.Rumours.BandPercent', section = 'limits', category = 'rules-limits', group = RP_RUMOURS,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Reward band either side (%)',
      about = 'A rumour gives the reward as a range this many percent either side.', inflight = AT_USE },
    { key = 'Roleplay.Rumours.Radius', section = 'limits', category = 'rules-limits', group = RP_RUMOURS,
      kind = 'number', min = 1, max = 100, label = 'Distance to the broker (m)',
      about = 'How close the hitman stands to the broker NPC, or to a broker player.', inflight = AT_USE },
    { key = 'Roleplay.Rumours.BriefValidMinutes', section = 'limits', category = 'rules-timers',
      group = RP_RUMOURS, kind = 'number', integer = true, min = 1, max = 1440,
      label = 'A briefing lasts (min)', about = 'How long a briefing unlocks a contract for.',
      inflight = 'Briefings already given keep their time.' },
    { key = 'Roleplay.Rumours.Locations', section = 'limits', category = 'rules-limits', group = RP_RUMOURS,
      kind = 'list', array = true, whole = true, names = 'point', label = 'Broker NPC places',
      about = PLACES, inflight = NPC_MOVES },
    { key = 'Roleplay.Rumours.RotateHours', section = 'limits', category = 'rules-timers', group = RP_RUMOURS,
      kind = 'number', integer = true, min = 1, max = 168, label = 'Broker moves every (h)',
      about = 'The broker NPC moves to its next place this often.', inflight = NPC_MOVES },
    { key = 'Roleplay.Rumours.Model', section = 'limits', category = 'rules-limits', group = RP_RUMOURS,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Broker NPC model',
      about = 'A GTA ped model name.', inflight = NPC_MOVES },
    { key = 'Roleplay.Rumours.Scenario', section = 'limits', category = 'rules-limits', group = RP_RUMOURS,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Broker NPC scenario',
      about = 'What the NPC does while it stands there.', inflight = NPC_MOVES },
    { key = 'Roleplay.Rumours.Blip', section = 'features', category = 'features', group = RP_RUMOURS,
      kind = 'switch', label = 'Broker on the map', about = 'A map blip where the broker NPC stands.',
      inflight = NPC_MOVES },
    { key = 'Roleplay.Rumours.BrokerJobs', section = 'limits', category = 'rules-targeting',
      group = RP_RUMOURS, kind = 'list', label = 'Broker jobs',
      about = 'Players on these jobs brief a hitman standing near them from their own app.',
      inflight = AT_USE },

    { key = 'Roleplay.BurnerPhone.Enabled', section = 'features', category = 'features', group = RP_BURNER,
      kind = 'switch', label = 'Burner phone required',
      about = 'Placing, accepting and every contract action need the burner phone item.',
      inflight = 'Checked at every action: live contracts stay as they are; only the next action '
          .. 'needs the item.' },
    { key = 'Roleplay.BurnerPhone.ConsumeOnPlace', section = 'features', category = 'features',
      group = RP_BURNER, kind = 'switch', label = 'Use one up on placing',
      about = 'One burner is used up when a contract is placed.', inflight = AT_USE },
    { key = 'Roleplay.BurnerPhone.ConsumeOnAccept', section = 'features', category = 'features',
      group = RP_BURNER, kind = 'switch', label = 'Use one up on accepting',
      about = 'One burner is used up when a contract is accepted.', inflight = AT_USE },
    { key = 'Roleplay.BurnerPhone.RequireToOpen', section = 'features', category = 'features',
      group = RP_BURNER, kind = 'switch', label = 'No burner, no contract tabs',
      about = 'Without one the Board and the contract half of Mine show nothing.', inflight = AT_USE },
    { key = 'Roleplay.BurnerPhone.Item', section = 'limits', category = 'rules-limits', group = RP_BURNER,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Burner phone item',
      about = 'The ox_inventory item name.', inflight = AT_USE },

    { key = 'Roleplay.InformantNpc.Enabled', section = 'features', category = 'features', group = RP_INFORMANT,
      kind = 'switch', label = 'Informant in person',
      about = 'Every informant purchase needs the buyer beside the informant NPC.',
      inflight = 'Checked at every purchase; nothing already bought changes.' },
    { key = 'Roleplay.InformantNpc.Radius', section = 'limits', category = 'rules-limits', group = RP_INFORMANT,
      kind = 'number', min = 1, max = 100, label = 'Distance to the informant (m)',
      about = 'How close the buyer stands to the informant NPC.', inflight = AT_USE },
    { key = 'Roleplay.InformantNpc.Locations', section = 'limits', category = 'rules-limits',
      group = RP_INFORMANT, kind = 'list', array = true, whole = true, names = 'point',
      label = 'Informant NPC places', about = PLACES, inflight = NPC_MOVES },
    { key = 'Roleplay.InformantNpc.RotateHours', section = 'limits', category = 'rules-timers',
      group = RP_INFORMANT, kind = 'number', integer = true, min = 1, max = 168,
      label = 'Informant moves every (h)', about = 'The informant NPC moves to its next place this often.',
      inflight = NPC_MOVES },
    { key = 'Roleplay.InformantNpc.Model', section = 'limits', category = 'rules-limits', group = RP_INFORMANT,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Informant NPC model',
      about = 'A GTA ped model name.', inflight = NPC_MOVES },
    { key = 'Roleplay.InformantNpc.Scenario', section = 'limits', category = 'rules-limits',
      group = RP_INFORMANT, kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64,
      label = 'Informant NPC scenario', about = 'What the NPC does while it stands there.',
      inflight = NPC_MOVES },
    { key = 'Roleplay.InformantNpc.Blip', section = 'features', category = 'features', group = RP_INFORMANT,
      kind = 'switch', label = 'Informant on the map', about = 'A map blip where the informant NPC stands.',
      inflight = NPC_MOVES },
    { key = 'Roleplay.NpcPlaces.Enabled', section = 'features', category = 'features', group = RP_INFORMANT,
      kind = 'switch', label = 'Broker and informant placed from the panel',
      about = 'The places staff set in Locations (Use my position) are used instead of the Locations lists, '
          .. 'which stay the defaults while none is set.', inflight = NPC_MOVES },

    { key = 'Roleplay.ReasonQuality.Enabled', section = 'features', category = 'features', group = RP_REASON,
      kind = 'switch', label = 'Reason quality',
      about = 'A typed reason needs a least length and word count, and low-effort ones are caught.',
      inflight = 'Read at every placing and edit: contracts keep the reason they were placed with.' },
    { key = 'Roleplay.ReasonQuality.MinLength', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'number', integer = true, min = 0, max = 255,
      label = 'Shortest reason (characters)', about = 'At most Reason.MaxLength.', inflight = AT_USE },
    { key = 'Roleplay.ReasonQuality.MinWords', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'number', integer = true, min = 0, max = 50,
      label = 'Fewest words in a reason', about = 'Words are runs of letters and digits.', inflight = AT_USE },
    { key = 'Roleplay.ReasonQuality.LowEffort', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'list', array = true, whole = true, names = 'phrase',
      label = 'Low-effort phrases', about = 'Matched as whole words, in any case.', inflight = AT_USE },
    { key = 'Roleplay.ReasonQuality.LowEffortAction', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'choice', choices = { 'refuse', 'review' },
      label = 'A low-effort reason is',
      about = '"refuse": refused. "review": placed, and put in Needs review for staff.',
      inflight = AT_USE },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end

--- The improvements (server/imp_*.lua, Config.Improvements), each off as
--- shipped: the switch under Features, the rest under the rules they are.
--- Informant fairness (server/imp_tips.lua), six blocks.
local IMP_DELAY, IMP_LIMITS = 'Improvements: Tip warning delay', 'Improvements: Tip limits'
local IMP_HOLD, IMP_SECOND = 'Improvements: Hold before a tip', 'Improvements: Informant second try'
local IMP_ZONES, IMP_DARK = 'Improvements: Tip safe zones', 'Improvements: Go dark'
MONEY['Improvements.TipLimits.MaxCost'] = 'Informant prices'
MONEY['Improvements.InformantSecondTry.SecondTryCostPercent'] = 'Informant prices'
MONEY['Improvements.GoDark.Cost'] = 'Informant prices'
MONEY['Improvements.GoDark.Account'] = 'Informant prices'
for _, entry in ipairs({
    { key = 'Improvements.TipWarningDelay.Enabled', section = 'features', category = 'features',
      group = IMP_DELAY, kind = 'switch', label = 'Delay the target\'s tip warning',
      about = 'The target\'s "someone knows your rough area" notice waits a random while after a tip.',
      inflight = 'Read at every tip: warnings already waiting are still sent when due.' },
    { key = 'Improvements.TipWarningDelay.MinSeconds', section = 'limits', category = 'rules-timers',
      group = IMP_DELAY, kind = 'number', integer = true, min = 0, max = 3600,
      label = 'Shortest warning delay (s)', about = 'At most the longest delay.', inflight = AT_USE },
    { key = 'Improvements.TipWarningDelay.MaxSeconds', section = 'limits', category = 'rules-timers',
      group = IMP_DELAY, kind = 'number', integer = true, min = 0, max = 3600,
      label = 'Longest warning delay (s)', about = '0 sends the warning at once, as before.',
      inflight = AT_USE },

    { key = 'Improvements.TipLimits.Enabled', section = 'features', category = 'features', group = IMP_LIMITS,
      kind = 'switch', label = 'Extra tip limits',
      about = 'One tip per hitman per contract, and/or each further tip twice the last one\'s price.',
      inflight = 'Read at every tip: tips already bought stay bought.' },
    { key = 'Improvements.TipLimits.OnePerHitman', section = 'features', category = 'features',
      group = IMP_LIMITS, kind = 'switch', label = 'One tip per hitman per contract',
      about = 'Each hitman on a contract buys one tip on it, on top of the contract\'s own limit.',
      inflight = AT_USE },
    { key = 'Improvements.TipLimits.PriceDoubling', section = 'features', category = 'features',
      group = IMP_LIMITS, kind = 'switch', label = 'Each further tip costs double',
      about = 'Each tip on a contract costs twice the one before, up to the most a tip costs.',
      inflight = AT_USE },
    { key = 'Improvements.TipLimits.MaxCost', section = 'limits', category = 'rules-rewards', group = IMP_LIMITS,
      kind = 'number', integer = true, min = 0, max = 10000000, label = 'Most a doubled tip costs ($)',
      about = 'Never less than the price of a tip.', inflight = AT_USE },

    { key = 'Improvements.TipHoldFirst.Enabled', section = 'features', category = 'features', group = IMP_HOLD,
      kind = 'switch', label = 'Hold a contract before a tip',
      about = 'A hitman buys a tip only once they have held the contract a while.', inflight = AT_USE },
    { key = 'Improvements.TipHoldFirst.MinHeldMinutes', section = 'limits', category = 'rules-timers',
      group = IMP_HOLD, kind = 'number', integer = true, min = 0, max = 1440,
      label = 'Hold before a tip (min)', about = 'Counted from when the hitman accepted it.',
      inflight = AT_USE },

    { key = 'Improvements.InformantSecondTry.Enabled', section = 'features', category = 'features',
      group = IMP_SECOND, kind = 'switch', label = 'Target\'s later look-ups priced apart',
      about = 'The target\'s look-ups after the first on a contract cost a share of the price.',
      inflight = AT_USE },
    { key = 'Improvements.InformantSecondTry.SecondTryCostPercent', section = 'limits',
      category = 'rules-rewards', group = IMP_SECOND, kind = 'number', integer = true, min = 0, max = 1000,
      label = 'Later look-ups cost (% of the price)',
      about = '100 is the same price; the chance stays the informant\'s.', inflight = AT_USE },

    { key = 'Improvements.TipSafeZones.Enabled', section = 'features', category = 'features', group = IMP_ZONES,
      kind = 'switch', label = 'Safe zones for tips',
      about = 'No tip is sold while the target stands in one of the zones; nothing is charged.',
      inflight = AT_USE },
    { key = 'Improvements.TipSafeZones.Zones', section = 'limits', category = 'rules-targeting',
      group = IMP_ZONES, kind = 'list', array = true, whole = true, names = 'zone',
      label = 'Safe zones (x, y, radius, name)',
      about = 'The hitman is told only that the informant cannot place them.', inflight = AT_USE },

    { key = 'Improvements.GoDark.Enabled', section = 'features', category = 'features', group = IMP_DARK,
      kind = 'switch', label = 'Go dark',
      about = 'A target told of a tip may pay so that tips on them find nothing for a while.',
      inflight = 'Read at every purchase; a target already dark stays dark to the end.' },
    { key = 'Improvements.GoDark.Cost', section = 'limits', category = 'rules-rewards', group = IMP_DARK,
      kind = 'number', integer = true, min = 0, max = 10000000, label = 'Price to go dark ($)',
      inflight = AT_USE },
    { key = 'Improvements.GoDark.Account', section = 'limits', category = 'rules-rewards', group = IMP_DARK,
      kind = 'choice', choices = { 'bank', 'cash' }, label = 'Account going dark is paid from',
      inflight = AT_USE },
    { key = 'Improvements.GoDark.Minutes', section = 'limits', category = 'rules-timers', group = IMP_DARK,
      kind = 'number', integer = true, min = 1, max = 1440, label = 'Dark for (min)',
      about = 'Tips bought on them meanwhile find nothing and are given back in full.',
      inflight = 'A target already dark keeps the time they paid for.' },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end
--- The board and progression improvements (server/imp_board.lua, README
--- Optional features), each off as shipped. Each switch under Features
--- in its own group, the rest under the Rules view it belongs to; all read
--- at use, with no restart.
local IMP_RECORD, IMP_HEAT = 'Improvements: Placer record', 'Improvements: Hitman heat'
local IMP_TIERS, IMP_DECAY = 'Improvements: Tiered board', 'Improvements: Contract decay'
for _, entry in ipairs({
    { key = 'Improvements.PlacerRecord.Enabled', category = 'features', group = IMP_RECORD,
      kind = 'switch', label = 'Placer record on the board',
      about = 'A board card shows how many contracts its placer placed, had paid out and cancelled lately. '
          .. 'Never who they are.',
      inflight = 'At the next board read, with no restart.' },
    { key = 'Improvements.PlacerRecord.ShowForAnonymous', category = 'features', group = IMP_RECORD,
      kind = 'switch', label = 'Placer record: anonymous placers too',
      about = 'Off: no record on an anonymous contract. On: their anonymous contracts only, in rough '
          .. 'bands (0, 1-4, 5-9, 10+), fixed when the card is first drawn, so two anonymous contracts '
          .. 'cannot be tied together.', inflight = AT_USE },
    { key = 'Improvements.PlacerRecord.LookbackDays', category = 'rules-limits', group = IMP_RECORD,
      kind = 'number', integer = true, min = 1, max = 365, label = 'Days the placer record counts',
      inflight = AT_USE },

    { key = 'Improvements.HitmanHeat.Enabled', category = 'features', group = IMP_HEAT,
      kind = 'switch', label = 'Hitman heat',
      about = 'Completions on whitelisted-job targets and police alerts about a hitman\'s work give them '
          .. 'heat for a while. At the threshold their targets are warned more often and police get a '
          .. 'vague bulletin. Never a name.',
      inflight = 'At the next completion, acceptance or tick, with no restart.' },
    { key = 'Improvements.HitmanHeat.ProtectedCompletionHeat', category = 'rules-limits', group = IMP_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Heat for a whitelisted-job completion',
      inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.WitnessHeat', category = 'rules-limits', group = IMP_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Heat for a witness report',
      about = 'Needs Witness heat (Roleplay) on to send reports.', inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.AdvisoryHeat', category = 'rules-limits', group = IMP_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Heat for a police bulletin on them',
      about = 'An acceptance or an informant tip on a whitelisted-job target, while those bulletins go.',
      inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.Threshold', category = 'rules-limits', group = IMP_HEAT,
      kind = 'number', integer = true, min = 1, max = 1000, label = 'Heat at which a hitman is known',
      inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.WarnTargetChancePercent', category = 'rules-limits', group = IMP_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Chance a known hitman\'s target is warned (%)',
      about = '100: the paranoid alert always goes when a known hitman takes a contract. Needs the '
          .. 'paranoid alert on.', inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.DecayHours', category = 'rules-timers', group = IMP_HEAT,
      kind = 'number', integer = true, min = 1, max = 720, label = 'Hours heat stays',
      inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.BulletinEveryMinutes', category = 'rules-timers', group = IMP_HEAT,
      kind = 'number', integer = true, min = 0, max = 1440, label = 'Least minutes between police bulletins',
      about = '0: no bulletin.', inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.BulletinTitle', category = 'rules-limits', group = IMP_HEAT,
      kind = 'text', pattern = '^[^%c<>]+$', maxLength = 60, says = RP_TEXT,
      label = 'Title of the police bulletin', inflight = AT_USE },
    { key = 'Improvements.HitmanHeat.BulletinText', category = 'rules-limits', group = IMP_HEAT,
      kind = 'text', pattern = '^[^%c<>]+$', maxLength = 160, says = RP_TEXT,
      label = 'What the police bulletin says', about = 'Keep it vague: it must name nobody.',
      inflight = AT_USE },

    { key = 'Improvements.Tiers.Enabled', category = 'features', group = IMP_TIERS,
      kind = 'switch', label = 'Tiered board',
      about = 'Contracts paying more are locked to hitmen below the tier\'s progression level. Needs '
          .. 'Criminal progression on.', inflight = 'At the next board read and acceptance, with no restart.' },
    { key = 'Improvements.Tiers.CompletionsPerLevel', category = 'rules-limits', group = IMP_TIERS,
      kind = 'number', integer = true, min = 1, max = 1000, label = 'Completed contracts per level',
      about = 'A hitman is level 1, plus one for each this many contracts they completed.',
      inflight = AT_USE },
    { key = 'Improvements.Tiers.Tiers', category = 'rules-limits', group = IMP_TIERS,
      kind = 'list', array = true, whole = true, names = 'tier', label = 'Tiers, as name, least reward, level',
      about = 'Such as Elite, 150000, 4. The highest tier a payout reaches decides.', inflight = AT_USE },

    { key = 'Improvements.ContractDecay.Enabled', category = 'features', group = IMP_DECAY,
      kind = 'switch', label = 'Contract decay',
      about = 'An untaken contract\'s reward rises each step, charged to its placer, or it ends sooner. '
          .. 'The placer is told and can turn it off for their contract.',
      inflight = 'At the next tick, with no restart.' },
    { key = 'Improvements.ContractDecay.Mode', category = 'rules-limits', group = IMP_DECAY,
      kind = 'choice', choices = { 'rise', 'shorten' }, label = 'What decay does',
      about = '\'rise\': the reward goes up. \'shorten\': the deadline comes in.', inflight = AT_USE },
    { key = 'Improvements.ContractDecay.Hours', category = 'rules-timers', group = IMP_DECAY,
      kind = 'number', integer = true, min = 1, max = 168, label = 'Hours between decay steps',
      inflight = AT_USE },
    { key = 'Improvements.ContractDecay.Percent', category = 'rules-rewards', group = IMP_DECAY,
      kind = 'number', integer = true, min = 1, max = 100, label = 'Decay step (%)',
      about = 'Of the reward at the first step (\'rise\'), or of the time left (\'shorten\').',
      inflight = AT_USE },
    { key = 'Improvements.ContractDecay.MaxIncreasePercent', category = 'rules-rewards', group = IMP_DECAY,
      kind = 'number', integer = true, min = 0, max = 1000, label = 'Most a reward rises in all (%)',
      inflight = AT_USE },
    { key = 'Improvements.ContractDecay.Account', category = 'rules-rewards', group = IMP_DECAY,
      kind = 'choice', choices = { 'cash', 'bank' }, label = 'Where a rise is charged from',
      inflight = AT_USE },
}) do
    entry.section = entry.category == 'features' and 'features' or 'limits'
    CATALOGUE[#CATALOGUE + 1] = entry
end
for _, key in ipairs({ 'Improvements.ContractDecay.Percent', 'Improvements.ContractDecay.MaxIncreasePercent',
    'Improvements.ContractDecay.Account' }) do
    MONEY[key] = 'Rewards'
end

--- Proof items, serial scrubbing, the weekly stats and the completion cooldown
--- (server/imp_proof.lua, imp_scrub.lua, imp_weekly.lua, imp_staffeco.lua).
local IMP_PROOF, IMP_SCRUB = 'Improvements: Proof items', 'Improvements: Serial scrubbing'
local IMP_WEEKLY = 'Improvements: Weekly stats'
for _, entry in ipairs({
    { key = 'Improvements.ProofItems.Enabled', section = 'features', category = 'features', group = IMP_PROOF,
      kind = 'switch', label = 'Proof items',
      about = 'On a contract a kill completes, a hitman beside the placer may hand over an item '
          .. 'taken from the target (an id card naming them) and is paid as for a verified kill.',
      inflight = 'Read at every handover: on, the button shows on contracts already held; a '
          .. 'payout already made is untouched.' },
    { key = 'Improvements.ProofItems.Item', section = 'limits', category = 'rules-limits', group = IMP_PROOF,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = 'Proof item',
      about = 'The ox_inventory item a hitman hands over.', inflight = AT_USE },
    { key = 'Improvements.ProofItems.MetadataKey', section = 'limits', category = 'rules-limits',
      group = IMP_PROOF, kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64,
      label = 'Metadata field that names the target',
      about = 'Must hold the target\'s citizen id: citizenid on qbx_idcard\'s id_card.', inflight = AT_USE },
    { key = 'Improvements.ProofItems.HandoverRadius', section = 'limits', category = 'rules-limits',
      group = IMP_PROOF, kind = 'number', min = 1, max = 50, label = 'Distance to the placer (m)',
      about = 'How close the hitman stands to the placer to hand it over.', inflight = AT_USE },

    { key = 'Improvements.SerialScrub.Enabled', section = 'features', category = 'features', group = IMP_SCRUB,
      kind = 'switch', label = 'Weapon serial scrubbing',
      about = 'A weapon an anonymous placer put up reaches the hitman with a new random serial; '
          .. 'the original is kept in the log for staff with the identity ACE.',
      inflight = 'Read at every give: weapons already handed over keep the serial they had.' },

    { key = 'Improvements.WeeklyStats.Enabled', section = 'features', category = 'features', group = IMP_WEEKLY,
      kind = 'switch', label = 'Weekly stats to Discord',
      about = 'Once a week, a post of the last seven days\' totals: contracts placed, completed '
          .. 'and money paid out to hitmen. Counts only, never a name or a handle. To '
          .. 'crimson_hitman_stats_webhook, or else the alert webhook.',
      inflight = 'Read at the hour. At most once a week, a restart included.' },
    { key = 'Improvements.WeeklyStats.Day', section = 'limits', category = 'rules-timers', group = IMP_WEEKLY,
      kind = 'choice', choices = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' },
      label = 'Day the weekly stats are posted', about = 'Server time.',
      inflight = 'Read every tick: a week already posted is not posted again.' },
    { key = 'Improvements.WeeklyStats.Hour', section = 'limits', category = 'rules-timers', group = IMP_WEEKLY,
      kind = 'number', integer = true, min = 0, max = 23,
      label = 'Hour the weekly stats are posted (server time, 0-23)',
      inflight = 'Read every tick: a week already posted is not posted again.' },

    { key = 'Limits.TargetCooldownAfterCompletionSeconds', section = 'limits', category = 'target-limits',
      group = 'Target limits', kind = 'number', integer = true, min = 0, max = 2592000,
      label = 'Wait after a completed contract before its target is named again (seconds, 0 = off)',
      about = 'The longer of this and the wait after any contract. The placer is told the wait '
          .. 'in hours, nothing else.', inflight = AT_USE },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end

-- The hitman organisation's own (server/org/settings_catalogue.lua), in
-- their category, 'organisation'.
for _, entry in ipairs(CrimsonBoot.require('server.org.settings_catalogue')) do
    CATALOGUE[#CATALOGUE + 1] = entry
end
-- The step markers and body disposal (server/missionsteps.lua), in their
-- category, 'mission-steps'.
for _, entry in ipairs(CrimsonBoot.require('server.missionsteps').CATALOGUE) do
    CATALOGUE[#CATALOGUE + 1] = entry
end

local byKey = {}
for i = 1, #CATALOGUE do byKey[CATALOGUE[i].key] = CATALOGUE[i] end
for key, group in pairs(MONEY) do
    if byKey[key] then byKey[key].money = group end
end

Settings.CATALOGUE = CATALOGUE

--------------------------------------------------------------------------
-- Reading and writing a key
--------------------------------------------------------------------------

--- A deep copy (Util.copy, the one shared copy).
local copyOf = Util.copy

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function parts(key)
    local out = {}
    for part in key:gmatch('[^%.]+') do out[#out + 1] = part end
    return out
end

--- The value at a key in a config table, as it is stored there.
local function read(config, key)
    local node = config
    for _, part in ipairs(parts(key)) do
        if type(node) ~= 'table' then return nil end
        node = node[part]
    end
    return node
end

--- Put a value at a key in a config table. Every table on the way exists
--- once the start-up checks have run; one that does not is made.
local function write(config, key, value)
    local path = parts(key)
    local node = config
    for i = 1, #path - 1 do
        if type(node[path[i]]) ~= 'table' then node[path[i]] = {} end
        node = node[path[i]]
    end
    node[path[#path]] = value
end

--- A job list as the config holds it (a set) from how the panel shows it
--- (a sorted list), and back.
local function asSet(list)
    local set = {}
    for _, name in ipairs(list) do set[name] = true end
    return set
end

local function asList(set)
    local list = {}
    for name, on in pairs(type(set) == 'table' and set or {}) do
        if on == true and type(name) == 'string' then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

--- A key's value in the shape the panel shows it.
local function shown(entry, stored)
    if entry.kind == 'list' and entry.array then return copyOf(type(stored) == 'table' and stored or {}) end
    if entry.kind == 'list' then return asList(stored) end
    return copyOf(stored)
end

--- And in the shape the config holds it.
local function stored(entry, value)
    if entry.kind == 'list' and not entry.array then return asSet(value) end
    return copyOf(value)
end

--- What defaults.lua ships for a key, in the shape the panel shows it, or
--- nil where it ships none (a key only config.lua has).
local function shippedOf(entry)
    if type(ConfigDefaults) ~= 'table' then return nil end
    local value = read(ConfigDefaults, entry.key)
    if value == nil then return nil end
    return shown(entry, value)
end

--- Keys read once at start (inflight RESTART: the command names) changed
--- from the panel since this start: kept in the store and shown, and put
--- into Config only by the next start (Settings.init's apply). Written into
--- Config at once, every message quoted a command that was not registered
--- until then. [key] = the value as the panel shows it.
local nextStart = {}

--- What the panel would show for a key now.
local function current(entry)
    if nextStart[entry.key] ~= nil then return copyOf(nextStart[entry.key]) end
    return shown(entry, read(Config, entry.key))
end

--- Put a changed value in force: into Config, or, for a key read once at
--- start, kept for the next one (nextStart).
local function putInForce(entry, key, value)
    if entry and entry.inflight == RESTART then
        if same(value, shown(entry, read(Config, key))) then
            nextStart[key] = nil
        else
            nextStart[key] = copyOf(value)
        end
        return
    end
    write(Config, key, stored(entry, value))
end

--------------------------------------------------------------------------
-- Checking a value
--------------------------------------------------------------------------

local LIST_MAX, NAME_MAX = 50, 32

--- What one name in a list may be, by the entry's `names` (job names when
--- not given): the pattern, how long, and what the refusal says.
local NAMES = {
    job = { pattern = '^[%w_%-]+$', max = NAME_MAX, lower = true,
            says = 'names letters, digits, - and _ only, up to 32 long' },
    item = { pattern = '^[%w_%-]+$', max = 64, says = 'item names letters, digits, - and _ only, up to 64 long' },
    mime = { pattern = '^[%w%-%.]+/[%w%-%.%+]+$', max = 64, lower = true,
             says = 'image types such as image/png, up to 64 long' },
    host = { pattern = '^[%w%-]+%.[%w%-%.]+$', max = 128, lower = true,
             says = 'host names such as fivemanage.com, up to 128 long' },
    phrase = { pattern = '^[^%c<>]+$', max = 60, says = 'short phrases, up to 60 characters, no < or >' },
    -- The roleplay lists (server/rp_places.lua, rp_consequences.lua): an NPC's
    -- place; a news template; and a named area, in either form both lists
    -- read (Places.parseArea): 'Name@x,y' (witness heat and city news) or
    -- 'x, y, name' (the rumours' districts).
    point = { pattern = '^[%d%s%.,%-]+$', max = 60, says = 'places as x, y, z, heading' },
    sentence = { pattern = '^[^%c<>]+$', max = 160, says = 'sentences, up to 160 characters, no < or >' },
    area = { patterns = { '^[^%c<>@]+@%s*%-?%d+%.?%d*%s*,%s*%-?%d+%.?%d*$',
                          '^%s*%-?%d+%.?%d*%s*,%s*%-?%d+%.?%d*%s*,[^%c<>@]+$' }, max = 60,
             says = 'areas as Name@x,y or x, y, name (such as Legion Square@195,-934), up to 60 characters' },
    -- The tiered board (server/imp_tiers.lua): 'name, least reward, level'.
    tier = { pattern = '^[^%c<>,]+,%s*%d+%s*,%s*%d+$', max = 60,
             says = 'tiers as name, least reward, level (such as Elite, 150000, 4), up to 60 characters' },
    -- A tip safe zone (server/imp_tips.lua, Imp.parseZone): 'x, y, radius, name'.
    zone = { pattern = '^%s*%-?%d+%.?%d*%s*,%s*%-?%d+%.?%d*%s*,%s*%d+%.?%d*%s*,[^%c<>]+$', max = 80,
             says = 'zones as x, y, radius, name (such as 300, -590, 80, Pillbox), up to 80 characters' },
}

--- Whether one typed name keeps its list's rule: its pattern, or any one of
--- its patterns.
local function nameFits(rule, name)
    if rule.pattern and name:match(rule.pattern) then return true end
    for _, pattern in ipairs(rule.patterns or {}) do
        if name:match(pattern) then return true end
    end
    return false
end

--- The most a number key takes now: its own max, or less where another
--- setting caps it (`ceiling`, a key read from the config in force).
---@param entry table
---@return number|nil
function Settings.maxOf(entry)
    local ceiling = entry.ceiling and tonumber(read(Config, entry.ceiling))
    if ceiling and (not entry.max or ceiling < entry.max) then return ceiling end
    return entry.max
end

--- Whether a start-up line names a key: in full, or by its last part where
--- no other key on the list ends in it ('MinMultiplier', not 'Enabled').
local lastParts = {}
for i = 1, #CATALOGUE do
    local last = CATALOGUE[i].key:match('([%w_]+)$')
    lastParts[last] = (lastParts[last] or 0) + 1
end
local function names(line, key)
    line = tostring(line)
    if line:find(key, 1, true) then return true end
    local last = key:match('([%w_]+)$')
    return lastParts[last] == 1 and #last >= 8 and line:find(last, 1, true) ~= nil
end

--- A start-up line as the reason a change is refused: what it says without
--- the start's own correction ("Using the lifetime."), which the panel does
--- not make, and naming the key once. Read as "Not changed: <key> <line>
--- Using X..", it said both that nothing changed and that something else
--- was used, and not what to do. `other` is the key to change first.
---@param key string
---@param line string
---@param other string|nil
---@return string
local function refusal(key, line, other)
    local text = tostring(line):gsub('[%.;]%s+[Uu]sing .*$', ''):gsub('[%s%.]+$', '')
    if not names(text, key) then text = key .. ' ' .. text end
    if other and other ~= key then text = ('%s. Change %s first'):format(text, other) end
    return text
end

--- Why a change would leave a bucket the app cannot work without below its
--- floor (BUCKET_FLOORS), or nil. Only for the keys being changed, and not
--- for one put back to what config.lua says.
---@param changes table [key] = value
---@param candidate table the config with the changes in it
---@return string|nil
local function belowFloor(changes, candidate)
    for key, value in pairs(changes) do
        local bucket = key:match('^Cooldowns%.([%w_]+)%.%a+$')
        local floor = bucket and BUCKET_FLOORS[bucket]
        if floor and not same(value, defaults[key]) then
            local rule = read(candidate, 'Cooldowns.' .. bucket)
            local per = type(rule) == 'table' and tonumber(rule.per)
            local burst = type(rule) == 'table' and tonumber(rule.burst)
            if per and burst and per > 0 and ((floor.burst and burst < floor.burst)
                or (floor.rate and burst / per < floor.rate)) then
                return ('%s would leave %s below what it needs, %s: %s'):format(key, bucket,
                    floor.needs, floor.why)
            end
        end
    end
    return nil
end

--- A value the panel sent, in the type and range the key takes, or nil
--- and why not. Nothing here trusts what the page sent: a number arrives
--- as a number or as digits, a switch as a boolean, a list as job names.
---@return any value
---@return string|nil why
local function normalise(entry, raw)
    if entry.kind == 'switch' then
        if type(raw) ~= 'boolean' then return nil, 'has to be on or off' end
        return raw
    end
    if entry.kind == 'choice' then
        for _, choice in ipairs(entry.choices) do
            if raw == choice then return raw end
        end
        return nil, ('has to be one of: %s'):format(table.concat(entry.choices, ', '))
    end
    if entry.kind == 'number' then
        local n = (type(raw) == 'number' or type(raw) == 'string') and tonumber(raw) or nil
        if not n or n ~= n or n == math.huge or n == -math.huge then
            return nil, 'has to be a number'
        end
        if entry.integer then
            if math.floor(n) ~= n then return nil, 'has to be a whole number' end
            n = math.tointeger(n) or n
        end
        local max = Settings.maxOf(entry)
        if (entry.min and n < entry.min) or (max and n > max) then
            return nil, ('has to be from %s to %s'):format(tostring(entry.min), tostring(max))
        end
        return n
    end
    if entry.kind == 'list' then
        local rule = NAMES[entry.names or 'job']
        if type(raw) ~= 'table' then return nil, 'has to be a list: ' .. rule.says end
        if #raw > LIST_MAX then return nil, ('takes at most %d names'):format(LIST_MAX) end
        for k in pairs(raw) do
            if math.type(k) ~= 'integer' or k < 1 or k > #raw then return nil, 'has to be a list' end
        end
        local seen, out = {}, {}
        for i = 1, #raw do
            local name = raw[i]
            if type(name) == 'string' then name = name:gsub('^%s+', ''):gsub('%s+$', '') end
            if type(name) ~= 'string' or #name == 0 or #name > rule.max or not nameFits(rule, name) then
                return nil, rule.says
            end
            if rule.lower then name = name:lower() end
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
        if not entry.array then table.sort(out) end
        return out
    end
    if entry.kind == 'text' then
        if type(raw) ~= 'string' or #raw == 0 or #raw > (entry.maxLength or 64)
            or not raw:match(entry.pattern or '^[%w_%-]+$') then
            return nil, ('has to be %s, up to %d long'):format(entry.says or 'letters, digits, - and _ only',
                entry.maxLength or 64)
        end
        return raw
    end
    if entry.kind == 'range' then
        if type(raw) ~= 'table' then return nil, 'has to be a pair: from and to' end
        for k in pairs(raw) do
            if k ~= 'min' and k ~= 'max' then return nil, 'has to be a pair: from and to' end
        end
        local lo, hi = tonumber(raw.min), tonumber(raw.max)
        if not lo or not hi or lo ~= lo or hi ~= hi then return nil, 'has to be two numbers' end
        if entry.integer and (math.floor(lo) ~= lo or math.floor(hi) ~= hi) then
            return nil, 'has to be whole numbers'
        end
        if lo < (entry.min or -math.huge) or hi > (entry.max or math.huge) then
            return nil, ('has to be within %s to %s'):format(tostring(entry.min), tostring(entry.max))
        end
        if lo > hi then return nil, 'has its from above its to' end
        if entry.integer then lo, hi = math.tointeger(lo) or lo, math.tointeger(hi) or hi end
        return { min = lo, max = hi }
    end
    return nil, 'cannot be changed here'
end

--- Whether a set of changes passes the start-up checks, run against a copy
--- of the live config with the changes in it (main.lua's checkConfig).
---
--- Refused when the checks would refuse to start on it, or would quietly
--- change any key the panel shows: a value they correct at start is one
--- that would not mean what staff set it to. Their own words are the reason.
---
--- A bucket the app cannot work without is held to its floor as well
--- (BUCKET_FLOORS). What passes answers, third, the start's warnings: they
--- refuse nothing, and staff are told the ones that name a key changed.
---@param changes table [key] = value as the panel shows it
---@return boolean ok
---@return string|nil reason
---@return string[]|nil warn on success, every warning the checks gave
---@return string|nil other on refusal, another key the checks would change
local function fits(changes)
    if not Check then return true, nil, {} end
    local candidate = copyOf(Config)
    -- A restart-only key changed since this start is checked as the next
    -- start will run it: left at the value in force, every later change was
    -- refused as one that "would change" it (sweep 4 D1).
    for key, value in pairs(nextStart) do
        if byKey[key] then write(candidate, key, stored(byKey[key], value)) end
    end
    for key, value in pairs(changes) do write(candidate, key, stored(byKey[key], value)) end
    local floor = belowFloor(changes, candidate)
    if floor then return false, floor end
    local ok, fatal, warn = Check(candidate)
    fatal, warn = fatal or {}, warn or {}
    if not ok or #fatal > 0 then
        local line = tostring(fatal[1] or 'the start-up checks refuse it')
        -- Another key the line names, to change first.
        local other
        for _, entry in ipairs(CATALOGUE) do
            if not other and not entry.readonly and changes[entry.key] == nil
                and names(line, entry.key) then
                other = entry.key
            end
        end
        return false, line, nil, other
    end
    for _, entry in ipairs(CATALOGUE) do
        if not entry.readonly then
            local wanted = changes[entry.key]
            if wanted == nil then wanted = current(entry) end
            local got = shown(entry, read(candidate, entry.key))
            if not same(got, wanted) then
                for _, line in ipairs(warn) do
                    if names(line, entry.key) then return false, line, nil, entry.key end
                end
                return false, ('would make the start-up checks change Config.%s'):format(entry.key),
                    nil, entry.key
            end
        end
    end
    return true, nil, warn
end

--- A value for a key, checked as the start-up checks would check it.
---@param key string
---@param raw any
---@return any value as the panel shows it, or nil
---@return string|nil err 'not_allowed' | 'read_only' | 'invalid_value'
---@return string|nil why a sentence that names the key, without its full stop
---@return string[]|nil warnings with a value: the start's warnings that name
--- the key, which refuse nothing and were said nowhere (W145)
function Settings.check(key, raw)
    if type(key) == 'string' and DENY[key] then return nil, 'read_only', DENY[key].why end
    local entry = type(key) == 'string' and byKey[key] or nil
    if not entry then return nil, 'not_allowed', 'not a setting the panel may change' end
    if entry.readonly then return nil, 'read_only', entry.readonly end
    local value, why = normalise(entry, raw)
    if value == nil then return nil, 'invalid_value', refusal(key, why) end
    local ok, reason, warn, other = fits({ [key] = value })
    if not ok then return nil, 'invalid_value', refusal(key, reason, other) end
    local said = {}
    for _, line in ipairs(warn or {}) do
        if names(line, key) then said[#said + 1] = line end
    end
    return value, nil, nil, said
end

--------------------------------------------------------------------------
-- Changing a key
--------------------------------------------------------------------------

--- A change being saved (set, reset, reset all): only one runs at a time.
---
--- Each is checked against the config in force, then waits on the store (a
--- yield on mysql), then applied. Two at once were each checked against the
--- config from before the other: a least buyout of 2.5 and a most of 2,
--- each fine beside what was in force, both passed, and the server ran on a
--- pair the start-up checks call fatal, which the next start then dropped
--- one of. The second is refused as busy, and staff ask again.
local saving = false

--- Run one change, or refuse it while another is being saved.
local function oneAtATime(fn, ...)
    if saving then
        return false, CH.ERR.BUSY, 'another change to the settings is being saved'
    end
    saving = true
    local ran, ok, err, detail = pcall(fn, ...)
    saving = false
    if not ran then error(ok, 0) end
    return ok, err, detail
end

--- Moved by every init: what each catalogue entry says of itself, and the
--- defaults read here, are fixed until the next (Settings.schemaVersion).
local schemaVersion = 0

--- Which version of the entries' fixed parts (label, help, limits,
--- defaults) the panel is shown: the same number, the same parts. The
--- admin panel sends them once and then only the values (server/panel.lua).
---@return integer
function Settings.schemaVersion()
    return schemaVersion
end

function Settings.init(deps)
    schemaVersion = schemaVersion + 1
    Storage, Audit, Check = deps.storage, deps.audit, deps.check
    overrides, ignored, unknown, nextStart = {}, {}, {}, {}
    saving = false
    -- What config.lua says, as the start-up checks left it. Taken here so a
    -- stack that never boots still knows what a reset puts back.
    defaults = {}
    for _, entry in ipairs(CATALOGUE) do defaults[entry.key] = current(entry) end
end

--- The log written now, and on json to the disk as well: a setting staff
--- changed is the record of how the server was run, and the store is where
--- the next start finds it.
local function flushNow()
    pcall(Audit.flush)
    if Storage.flush then pcall(Storage.flush) end
end

--- Values of the keys players' games read, for the client's copy of the
--- config, or nil when every one of them is what config.lua says.
---@param always boolean|nil every one, whatever it says
---@return table|nil [key] = value
function Settings.clientValues(always)
    local out, any = {}, false
    for _, entry in ipairs(CATALOGUE) do
        if entry.client then
            out[entry.key] = current(entry)
            if overrides[entry.key] then any = true end
        end
    end
    if not (always or any) then return nil end
    return out
end

--- Tell whoever needs telling that a key changed: players' games for a key
--- they read, and the hook Bridges installs.
local function changed(entry)
    if entry.client then
        TriggerClientEvent('crimson-hitman:settings', -1, Settings.clientValues(true))
    end
    if Settings.onChanged then pcall(Settings.onChanged, entry.key, entry) end
    local watcher = watchers[entry.key]
    if watcher then
        local ok, err = pcall(watcher, entry.key)
        if not ok then
            Log.always(('the change to %s is in force, but what follows it raised: %s')
                :format(entry.key, tostring(err)))
        end
    end
end

--- Whether a write that raised landed after all, read back from the store
--- as the money paths read theirs: true when the store holds `expected`
--- for the key (nothing at all, for a delete), false when it does not, and
--- nil, with why, when the read raised too. A commit followed by a dropped
--- connection raises, and "Nothing changed" said then left config.lua's
--- value in force over a row the next start applied.
---@param key string
---@param expected any the value written, or nil for a delete
---@return boolean|nil landed
---@return string|nil why
local function landed(key, expected)
    local ok, rows = pcall(Storage.readSettings)
    if not ok or type(rows) ~= 'table' then return nil, Util.dbError(rows) end
    local row = rows[key]
    if expected == nil then return row == nil end
    return type(row) == 'table' and same(row.value, expected)
end

--- A key the store may or may not hold the change for, kept for the
--- diagnosis (Settings.active) until a change to it, or the next start.
local function markUnknown(key, why, staff)
    unknown[key] = { why = tostring(why), by = staff, at = os.time() }
    Log.always(('the admin panel change to %s raised in the store, and reading it back raised '
        .. 'too (%s): the store may or may not hold it. It is not in force; set or reset it again '
        .. 'once the store answers.'):format(key, tostring(why)))
end

--- What follows a change the store has kept: the audit row, the log
--- written, and whoever needs telling. Each in its own pcall: one that
--- raised after the commit answered the change as an error, with no row
--- and nobody told, though it was in force and kept.
local function committed(entry, action, actorCid, detail)
    local okAudit, auditErr = pcall(Audit.staff, action, actorCid, nil, detail)
    if not okAudit then
        Log.always(('the admin panel %s is in force and kept, but its audit row raised: %s')
            :format(detail.key and ('change to ' .. tostring(detail.key)) or 'reset of every setting',
                tostring(auditErr)))
    end
    flushNow()
    if entry then
        local okTold, toldErr = pcall(changed, entry)
        if not okTold then
            Log.debug(('players\' games were not told of the change to %s: %s')
                :format(entry.key, tostring(toldErr)))
        end
    end
end

local function setKey(key, raw, staff, actorCid)
    local value, err, why, warnings = Settings.check(key, raw)
    if value == nil then return false, err, why end
    local entry = byKey[key]
    local old = current(entry)

    -- The value in force already: nothing written, recorded or told. Set
    -- again from a stale page, a switch to what it was re-sent every
    -- barred player the 'Closed to you' notice and every phone its access.
    -- Not for a key the store holds something else for (not applied, or
    -- not known): writing it is what settles that row.
    if same(value, old) and not ignored[key] and not unknown[key] then
        return true, nil, { key = key, value = copyOf(value), old = old, unchanged = true,
                            source = overrides[key] and 'panel' or 'config', warnings = warnings }
    end

    local backToConfig = same(value, defaults[key])
    local at = os.time()

    local wrote, writeErr
    if backToConfig then
        wrote, writeErr = pcall(Storage.deleteSetting, key)
    else
        wrote, writeErr = pcall(Storage.writeSetting, key, copyOf(value), staff, at)
    end
    if not wrote then
        local expected = nil
        if not backToConfig then expected = value end
        local kept, readErr = landed(key, expected)
        if kept == nil then
            markUnknown(key, readErr, staff)
            return false, 'store_unknown', Util.dbError(writeErr)
        end
        if not kept then return false, 'store_failed', Util.dbError(writeErr) end
        Log.debug(('the admin panel change to %s raised in the store (%s), and the store holds it: '
            .. 'applied'):format(key, Util.dbError(writeErr)))
    end

    putInForce(entry, key, value)
    if backToConfig then
        overrides[key] = nil
    else
        overrides[key] = { value = copyOf(value), by = staff, at = at }
    end
    ignored[key], unknown[key] = nil, nil

    committed(entry, 'admin_setting_changed', actorCid, {
        key = key, old = old, new = copyOf(value), by = staff,
        source = backToConfig and 'config' or 'panel',
    })
    return true, nil, { key = key, value = copyOf(value), old = old,
                        source = backToConfig and 'config' or 'panel', warnings = warnings }
end

--- Change a key live and keep it over config.lua.
---
--- A value equal to what config.lua says takes the override away instead:
--- the key is then config.lua's again, as a reset would leave it.
---@param key string
---@param raw any
---@param staff string|nil who, for the record ('console' at the console)
---@param actorCid string|nil their citizen id, for the audit row
---@return boolean ok
---@return string|nil err also 'busy' while another change is being saved
---@return any detail the reason, or { key, value, old, source } on success
function Settings.set(key, raw, staff, actorCid)
    return oneAtATime(setKey, key, raw, staff, actorCid)
end

--- One key back to what config.lua says. A key read-only now whose stored
--- value was not applied at start (one changeable before, say) has its row
--- taken away all the same: nothing in force changes, and it stops being
--- listed as not applied. So does a row for a key the catalogue does not
--- list at all (one from another version), which every start said to reset
--- in the panel and the panel had no row for.
local function resetKey(key, staff, actorCid)
    local entry = type(key) == 'string' and byKey[key] or nil
    local stray = type(key) == 'string' and not entry and (ignored[key] or unknown[key]) ~= nil
    if not entry and not stray then
        return false, 'not_allowed', 'not a setting the panel may change'
    end
    if entry and entry.readonly and not ignored[key] then return false, 'read_only', entry.readonly end
    if not overrides[key] and not ignored[key] and not unknown[key] then
        return false, 'not_overridden', 'it is what config.lua says already'
    end
    -- What config.lua says passed the start-up checks on its own, but not
    -- necessarily beside the other overrides still in force: a least
    -- buyout put back under a most one changed from here.
    if overrides[key] then
        local ok, reason, _, other = fits({ [key] = defaults[key] })
        if not ok then return false, 'invalid_value', refusal(key, reason, other) end
    end
    local wrote, writeErr = pcall(Storage.deleteSetting, key)
    if not wrote then
        local gone, readErr = landed(key, nil)
        if gone == nil then
            markUnknown(key, readErr, staff)
            return false, 'store_unknown', Util.dbError(writeErr)
        end
        if not gone then return false, 'store_failed', Util.dbError(writeErr) end
    end

    local old = entry and current(entry) or copyOf((ignored[key] or {}).value)
    if entry then putInForce(entry, key, defaults[key]) end
    local had = overrides[key] ~= nil
    overrides[key], ignored[key], unknown[key] = nil, nil, nil
    committed(had and entry or nil, 'admin_setting_reset', actorCid,
        { key = key, old = old, new = copyOf(defaults[key]), by = staff })
    return true, nil, { key = key, value = copyOf(defaults[key]), old = old, source = 'config',
                        removed = not entry or nil }
end

--- Put one key back to what config.lua says.
---@return boolean ok
---@return string|nil err 'not_allowed' | 'read_only' | 'not_overridden' | 'invalid_value' |
--- 'store_failed' | 'busy'
---@return any detail
function Settings.reset(key, staff, actorCid)
    return oneAtATime(resetKey, key, staff, actorCid)
end

local function resetEvery(staff, actorCid)
    local keys = {}
    for key in pairs(overrides) do keys[#keys + 1] = key end
    for key in pairs(ignored) do if not overrides[key] then keys[#keys + 1] = key end end
    for key in pairs(unknown) do
        if not overrides[key] and not ignored[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)

    -- Which rows went: every one, or, when the clear raised, the ones the
    -- store no longer holds (read back, as a change is).
    local gone = {}
    local wrote, writeErr = pcall(Storage.clearSettings)
    if wrote then
        for _, key in ipairs(keys) do gone[key] = true end
    else
        local ok, rows = pcall(Storage.readSettings)
        if not ok or type(rows) ~= 'table' then
            for _, key in ipairs(keys) do
                if not unknown[key] then markUnknown(key, Util.dbError(rows), staff) end
            end
            return false, 'store_unknown', Util.dbError(writeErr)
        end
        for _, key in ipairs(keys) do gone[key] = rows[key] == nil end
    end

    local changes, touched, done, kept = {}, {}, {}, 0
    for _, key in ipairs(keys) do
        if gone[key] then
            local entry = byKey[key]
            if entry and overrides[key] then
                changes[key] = { old = current(entry), new = copyOf(defaults[key]) }
                putInForce(entry, key, defaults[key])
                touched[#touched + 1] = entry
            end
            overrides[key], ignored[key], unknown[key] = nil, nil, nil
            done[#done + 1] = key
        else
            kept = kept + 1
        end
    end
    if #done == 0 and kept > 0 then return false, 'store_failed', Util.dbError(writeErr) end

    committed(nil, 'admin_settings_reset_all', actorCid,
        { keys = done, changes = changes, by = staff, kept = kept > 0 and kept or nil })
    for _, entry in ipairs(touched) do
        local okTold, toldErr = pcall(changed, entry)
        if not okTold then
            Log.debug(('players\' games were not told of the change to %s: %s')
                :format(entry.key, tostring(toldErr)))
        end
    end
    if kept > 0 then
        return false, 'store_failed', ('%s; %d were reset, and %d are still kept and in force')
            :format(Util.dbError(writeErr), #done, kept)
    end
    return true, nil, { keys = #done }
end

--- Put every key back to what config.lua says.
---@return boolean ok
---@return string|nil err 'store_failed' | 'busy'
---@return any detail { keys = n }
function Settings.resetAll(staff, actorCid)
    return oneAtATime(resetEvery, staff, actorCid)
end

--------------------------------------------------------------------------
-- At start
--------------------------------------------------------------------------

--- Apply what the store holds over config.lua. Run at start, right after
--- the start-up checks and before anything reads the config.
---
--- The overrides are checked again against config.lua as it now is, all of
--- them together, as they stood together in force when the server stopped.
--- One at a time, each was checked beside config.lua and only the ones
--- before it in sort order: a least buyout of 0.5 and a most of 0.8, set in
--- that order and each fine beside the other, sorted Max before Min, and the
--- most was refused beside config.lua's least of 1 and dropped at every
--- restart. Only when the set as a whole fails are they tried one at a time,
--- in passes until a pass applies nothing more, so that the order they sort
--- in decides nothing. One the catalogue no longer lists, one read-only, or
--- one config.lua has made invalid (a most buyout now under a least one an
--- owner raised in the file) is not applied, and is said so in the console
--- and in /ch-diag until staff reset it.
---@return integer applied
function Settings.boot()
    local ok, rows = pcall(Storage.readSettings)
    if not ok then
        Log.problem(('warning: could not read the settings changed from the admin '
            .. 'panel (%s); config.lua is used as it stands.'):format(tostring(rows)))
        return 0
    end
    local keys = {}
    for key in pairs(type(rows) == 'table' and rows or {}) do keys[#keys + 1] = key end
    table.sort(keys)

    local function rowOf(key) return type(rows[key]) == 'table' and rows[key] or {} end
    local function notApplied(key, why)
        local row = rowOf(key)
        ignored[key] = { value = copyOf(row.value), by = row.by, at = row.at, why = tostring(why) }
        Log.problem(('warning: the admin panel setting %s is not applied: %s. '
            .. 'config.lua\'s value is used; reset it in the panel to clear this.')
            :format(key, tostring(why)))
    end

    -- Each value first as the panel would take it, on its own.
    local wanted, order = {}, {}
    for _, key in ipairs(keys) do
        local entry = byKey[key]
        -- Read as it is, not through `and ... or`: a switch turned off is
        -- false, and `row and row.value or nil` read it as nothing at all.
        local raw = rowOf(key).value
        local value, why
        if not entry then
            why = 'not a setting the panel may change'
        elseif entry.readonly then
            why = entry.readonly
        else
            value, why = normalise(entry, raw)
        end
        if value == nil then
            notApplied(key, why or 'invalid_value')
        else
            wanted[key] = value
            order[#order + 1] = key
        end
    end

    -- Then together; and only if that fails, one at a time in passes.
    local applied = {}
    if fits(wanted) then
        for _, key in ipairs(order) do applied[key] = wanted[key] end
    else
        local left = order
        repeat
            local rest, progressed = {}, false
            for _, key in ipairs(left) do
                local candidate = copyOf(applied)
                candidate[key] = wanted[key]
                if fits(candidate) then
                    applied[key] = wanted[key]
                    progressed = true
                else
                    rest[#rest + 1] = key
                end
            end
            left = rest
        until not progressed or #left == 0
        for _, key in ipairs(left) do
            local candidate = copyOf(applied)
            candidate[key] = wanted[key]
            local _, reason = fits(candidate)
            notApplied(key, reason or 'the start-up checks refuse it')
        end
    end

    local said = {}
    for _, key in ipairs(order) do
        local value = applied[key]
        if value ~= nil then
            local row = rowOf(key)
            write(Config, key, stored(byKey[key], value))
            overrides[key] = { value = copyOf(value), by = row.by, at = row.at }
            said[#said + 1] = ('%s = %s'):format(key, Settings.describe(value))
        end
    end
    if #said > 0 then
        Log.debug(('%d setting(s) changed from the admin panel are in force over '
            .. 'config.lua: %s'):format(#said, table.concat(said, ', ')))
    end
    return #said
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

--- A value in words, for the console and /ch-diag.
---@param value any
---@return string
function Settings.describe(value)
    if type(value) == 'boolean' then return value and 'on' or 'off' end
    if type(value) == 'table' then return '[' .. table.concat(value, ', ') .. ']' end
    return tostring(value)
end

--- The feature area each group is shown under in the admin panel's Game
--- rules (a setting's `area`): staff find a feature's switch, numbers and
--- lists on one page, whatever kind of value each is. A group not named
--- here is 'other'; the Developer section's own groups are 'engine'.
local AREA_OF_GROUP = {
    ['Access'] = 'access', ['The app'] = 'access', ['Barred jobs'] = 'access',
    ['Anti-collusion'] = 'access', ['Progression'] = 'access',
    ['Contract limits'] = 'placing', ['Contract reasons'] = 'placing', ['Roleplay: Reason quality'] = 'placing',
    ['Proposals'] = 'placing', ['Stakes'] = 'placing', ['Targeting'] = 'placing', ['Immunity'] = 'placing',
    ['Improvements: Contract decay'] = 'placing', ['Improvements: Placer record'] = 'placing',
    ['Anonymity'] = 'anonymity', ['Anonymity (whitelisted-job targets)'] = 'anonymity',
    ['Improvements: Serial scrubbing'] = 'anonymity',
    ['Rewards'] = 'rewards', ['Payouts'] = 'rewards', ['Roleplay: Dirty money payouts'] = 'rewards',
    ['Completion'] = 'completing', ['Handovers'] = 'completing', ['Ledger'] = 'completing',
    ['The clock'] = 'completing', ['Server restart'] = 'completing',
    ['Roleplay: EMS before re-listing'] = 'completing', ['Roleplay: Proof of intent'] = 'completing',
    ['Improvements: Proof items'] = 'completing',
    ['Buyouts'] = 'buyouts', ['Buyout pricing'] = 'buyouts',
    ['Informant'] = 'informants', ['Informant prices'] = 'informants', ['Informant tip'] = 'informants',
    ['Informants (whitelisted-job targets)'] = 'informants', ['Roleplay: Informant in person'] = 'informants',
    ['Improvements: Tip warning delay'] = 'informants', ['Improvements: Tip limits'] = 'informants',
    ['Improvements: Hold before a tip'] = 'informants', ['Improvements: Informant second try'] = 'informants',
    ['Improvements: Tip safe zones'] = 'informants', ['Improvements: Go dark'] = 'informants',
    ['Law enforcement advisory'] = 'police', ['Advisory job lists'] = 'police',
    ['Roleplay: Witness heat'] = 'police', ['Roleplay: City news'] = 'police',
    ['Improvements: Hitman heat'] = 'police',
    ['Messages and calls'] = 'messages', ['Notifications'] = 'messages', ['Roleplay: Burner phone'] = 'messages',
    ['Roleplay: Reputation'] = 'extras', ['Roleplay: Bodyguards'] = 'extras', ['Roleplay: Hit on the hitman'] = 'extras',
    ['Roleplay: Rumours and broker'] = 'extras', ['Improvements: Tiered board'] = 'extras',
    ['Staff tools'] = 'staff', ['Staff alerts'] = 'staff', ['Audit and debug'] = 'staff', ['Staff'] = 'staff',
    ['Improvements: Weekly stats'] = 'staff',
    ['Storage'] = 'engine', ['Rate limits'] = 'engine', ['Diagnostics'] = 'engine', ['Staff commands'] = 'engine',
    ['Edit in config.lua'] = 'engine', ['Kept in the store, not on this list'] = 'engine',
    ['Target limits'] = 'targets',
    ['Organisation'] = 'organisation', ['Organisation: Boss limits'] = 'organisation',
    -- The step markers and body disposal (server/missionsteps.lua): steps
    -- of completing a contract.
    ['Step markers'] = 'completing', ['Body disposal'] = 'completing',
}
Settings.AREA_OF_GROUP = AREA_OF_GROUP

--- A catalogue entry's area: its own `area`, or its group's.
---@param entry table
---@return string
function Settings.areaOf(entry)
    return entry.area or AREA_OF_GROUP[entry.group] or 'other'
end

--- Every key the panel shows, with its value now, what config.lua says,
--- and where the value in force comes from.
---
--- `overrides` counts the ones in force; `stored` every row the store holds
--- (or may hold), which Reset all clears; `notApplied` the rows held and
--- not applied. A row for a key this version does not list is shown
--- read-only, with why and its Reset: every start said to reset it here,
--- and there was no row to do it from.
---@return table { features = entry[], limits = entry[], readonly = entry[], overrides = n, stored = n, notApplied = n }
function Settings.view()
    local out = { features = {}, limits = {}, readonly = {}, overrides = 0, stored = 0, notApplied = 0 }
    for _, entry in ipairs(CATALOGUE) do
        local override = overrides[entry.key]
        local skipped = ignored[entry.key]
        local row = {
            key = entry.key, group = entry.group, label = entry.label, about = entry.about,
            category = entry.category, money = entry.money, area = Settings.areaOf(entry),
            shipped = shippedOf(entry), hasShipped = shippedOf(entry) ~= nil,
            kind = entry.kind, choices = entry.choices, min = entry.min, max = Settings.maxOf(entry),
            integer = entry.integer or nil, live = entry.live ~= false,
            inflight = entry.inflight, readonly = entry.readonly, destroys = entry.destroys,
            stricter = entry.stricter, strict = entry.strict, whole = entry.whole or nil,
            value = current(entry), default = copyOf(defaults[entry.key]),
            source = override and 'panel' or 'config',
            by = override and override.by or nil, at = override and override.at or nil,
            ignored = skipped and skipped.why or nil,
            unknown = unknown[entry.key] and unknown[entry.key].why or nil,
            inactive = (entry.needs and read(Config, entry.needs) ~= true
                and NEEDS_OFF[entry.needs])
                or (entry.unless and read(Config, entry.unless) == true
                and UNLESS_ON[entry.unless]) or nil,
        }
        if override then out.overrides = out.overrides + 1 end
        local list = out[entry.section]
        list[#list + 1] = row
    end
    -- The keys never changed from here, not on the list above: shown with
    -- why, and a secret only as set or not.
    local denied = {}
    for key in pairs(DENY) do if not byKey[key] then denied[#denied + 1] = key end end
    table.sort(denied)
    for _, key in ipairs(denied) do
        local rule = DENY[key]
        local value
        if rule.secret then
            local ok, got = pcall(GetConvar, rule.convar, '')
            value = (ok and type(got) == 'string' and got ~= '') and 'set' or 'not set'
        else
            value = copyOf(read(Config, key))
            if value == nil then value = '(not set)' end
            if type(value) == 'table' then value = json and json.encode(value) or '(a table)' end
        end
        out.readonly[#out.readonly + 1] = {
            key = key, group = 'Edit in config.lua', area = 'engine',
            label = rule.secret and ('Secret: ' .. rule.convar) or rule.label or key,
            kind = 'text', category = 'developer', readonly = rule.why, denied = true,
            secret = rule.secret or nil, value = value, source = 'config',
        }
    end
    local strays = {}
    for key in pairs(ignored) do if not byKey[key] then strays[#strays + 1] = key end end
    for key in pairs(unknown) do
        if not byKey[key] and not ignored[key] then strays[#strays + 1] = key end
    end
    table.sort(strays)
    for _, key in ipairs(strays) do
        local skipped = ignored[key] or {}
        out.readonly[#out.readonly + 1] = {
            key = key, group = 'Kept in the store, not on this list', label = key, kind = 'text',
            category = 'developer', area = 'engine',
            readonly = 'Not a setting this version lists, so nothing reads it. Reset takes its row '
                .. 'out of the store; nothing in force changes.',
            value = copyOf(skipped.value), source = 'config', by = skipped.by, at = skipped.at,
            ignored = skipped.why, unknown = unknown[key] and unknown[key].why or nil, stray = true,
        }
    end
    for _, row in ipairs(Settings.active()) do
        out.stored = out.stored + 1
        if row.ignored then out.notApplied = out.notApplied + 1 end
    end
    return out
end

--- The overrides in force and the ones not applied, by key, for /ch-diag:
--- `applied` on the ones in force, `ignored` (why) on the ones not, and
--- `unknown` (why) on a key whose last change the store may or may not hold.
---@return table[] { key, value, by, at, applied, ignored, unknown }
function Settings.active()
    local out, listed = {}, {}
    for key, override in pairs(overrides) do
        listed[key] = #out + 1
        out[#out + 1] = { key = key, value = copyOf(override.value), by = override.by,
                          at = override.at, applied = true }
    end
    for key, skipped in pairs(ignored) do
        listed[key] = #out + 1
        out[#out + 1] = { key = key, value = copyOf(skipped.value), by = skipped.by,
                          at = skipped.at, ignored = skipped.why }
    end
    for key, doubt in pairs(unknown) do
        local row = listed[key] and out[listed[key]]
        if row then
            row.unknown = doubt.why
        else
            local entry = byKey[key]
            out[#out + 1] = { key = key, value = entry and current(entry) or nil, by = doubt.by,
                              at = doubt.at, unknown = doubt.why }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- The catalogue entry for a key, for the panel and the tests.
---@param key string
---@return table|nil
function Settings.entry(key)
    return byKey[key]
end

--------------------------------------------------------------------------
-- History (Developer > Settings history)
--------------------------------------------------------------------------

--- The audit rows every change writes (admin_setting_changed, its reset
--- admin_setting_reset, and admin_settings_reset_all) each hold the key,
--- the value before and after, who and when, so the history is read from
--- them: one substring of the action matches all three.
local HISTORY_ACTION = 'admin_setting'

--- Whether a key's values are never shown: a secret on the deny list (a
--- webhook), or a key whose name says it holds one. Neither is changeable
--- from the panel, so neither should ever be in a row; this is the guard
--- should one be.
---@param key any
---@return boolean
function Settings.secretKey(key)
    if type(key) ~= 'string' then return true end
    local rule = DENY[key]
    if rule and rule.secret then return true end
    local lowered = key:lower()
    return lowered:find('webhook', 1, true) ~= nil or lowered:find('secret', 1, true) ~= nil
        or lowered:find('password', 1, true) ~= nil or lowered:find('token', 1, true) ~= nil
end

--- One page of the history, newest first: a row for each change of one
--- key, and a reset of every setting one row for each key it changed.
---@param cursor any where the page before stopped (opaque)
---@param limit integer rows of the log read, at most
---@return table[] rows { ts, action, key, old, new, actor, by, source, secret, category, undoable }
---@return any next the cursor of the next page, nil on the last
function Settings.history(cursor, limit)
    pcall(Audit.flush)
    local rows, next_ = Storage.queryAudit({ action = HISTORY_ACTION }, cursor, limit)
    local out = {}
    local function add(row, key, old, new, by, source)
        local secret = Settings.secretKey(key)
        local entry = byKey[key]
        local shownOld, shownNew
        if not secret then shownOld, shownNew = copyOf(old), copyOf(new) end
        out[#out + 1] = {
            ts = tonumber(row.ts), action = row.action, key = key,
            old = shownOld, new = shownNew,
            actor = row.actor_cid, by = by, source = source, secret = secret or nil,
            category = entry and entry.category or 'developer',
            undoable = (not secret and entry ~= nil and not entry.readonly and old ~= nil) or nil,
        }
    end
    for _, row in ipairs(rows or {}) do
        local detail = type(row.detail) == 'table' and row.detail or {}
        if row.action == 'admin_settings_reset_all' then
            local changes = type(detail.changes) == 'table' and detail.changes or {}
            local keys = {}
            for key in pairs(changes) do keys[#keys + 1] = key end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local change = changes[key]
                if type(change) == 'table' then add(row, key, change.old, change.new, detail.by, 'config') end
            end
        elseif row.action == 'admin_setting_changed' or row.action == 'admin_setting_reset' then
            add(row, detail.key, detail.old, detail.new, detail.by,
                row.action == 'admin_setting_reset' and 'config' or detail.source)
        end
    end
    return out, next_
end

return Settings
