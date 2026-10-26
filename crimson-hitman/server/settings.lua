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

--- Called with (key, entry) after a key changes live; set by Bridges.install,
--- which knows who to tell (the access refresh, the photo host list).
Settings.onChanged = nil

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
    { key = 'BlockOffDuty', section = 'features', group = 'Access', kind = 'switch',
      label = 'Bar off-duty officers',
      about = 'Barred jobs stay barred from the app while off duty.',
      inflight = AT_USE .. ' Who may see the app is checked again at once.' },
    { key = 'HideAppFromBlockedJobs', section = 'features', group = 'Access', kind = 'switch',
      unless = 'WhitelistedView.Enabled',
      label = 'Hide the app from barred jobs',
      about = 'Keeps the app off a barred player\'s phone instead of showing one that answers nothing.',
      inflight = 'Every phone is told at once; barred jobs are refused either way.' },
    { key = 'WhitelistedView.Enabled', section = 'features', group = 'Access', kind = 'switch',
      label = 'Whitelisted-job view',
      about = 'Barred jobs (police, EMS, DOJ, lawyers and the rest) open the app to one read-only '
          .. 'screen: the contracts on them and on other whitelisted-job members, with no more '
          .. 'than the law enforcement advisory says, and the buyout on a contract on them. '
          .. 'Off: the app is closed to them, as Hide the app from barred jobs says.',
      inflight = 'Every phone is told at once, and an open app changes screen at once. A buyout '
          .. 'already paid still closes after its delay either way.' },
    { key = 'App.DefaultInstalled', section = 'features', group = 'The app', kind = 'switch',
      label = 'Put the app on every home screen', client = true, live = false,
      about = 'Installs the app on eligible phones instead of leaving it in the App Store.',
      inflight = 'Applies after restart: read when the app is added to a phone, at the next '
          .. 'start of this resource or lb-phone, or when a player next joins.' },

    { key = 'Sources.cash.enabled', section = 'features', group = 'Rewards', kind = 'switch',
      label = 'Cash rewards', about = 'Cash may be put up as a reward.', inflight = NEW_ONLY
          .. ' Cash already held in escrow is paid out or returned as before.' },
    { key = 'Sources.bank.enabled', section = 'features', group = 'Rewards', kind = 'switch',
      label = 'Bank rewards', about = 'Bank money may be put up as a reward.', inflight = NEW_ONLY
          .. ' Money already held in escrow is paid out or returned as before.' },
    { key = 'Sources.dirty.enabled', section = 'features', group = 'Rewards', kind = 'switch',
      label = 'Dirty money rewards', about = 'Dirty money may be put up as a reward.',
      inflight = NEW_ONLY .. ' Money already held in escrow is paid out or returned as before.' },
    { key = 'Sources.item.enabled', section = 'features', group = 'Rewards', kind = 'switch',
      label = 'Item rewards', about = 'Items may be put up as a reward.', inflight = NEW_ONLY
          .. ' Items already held in escrow are paid out or returned as before.' },
    { key = 'Sources.weapon.enabled', section = 'features', group = 'Rewards', kind = 'switch',
      label = 'Weapon rewards', about = 'Weapons may be put up as a reward.', inflight = NEW_ONLY
          .. ' Weapons already held in escrow are paid out or returned as before.' },

    { key = 'Completion.Fulfilment', section = 'features', group = 'Completion', kind = 'choice',
      choices = { 'alive', 'either' }, label = 'How contracts are completed',
      -- Who the target is handed to, said here as everywhere a player reads
      -- it; and no photograph, which under KillPhotos off is never taken.
      about = '\'alive\': live transfer only. The target has to be brought alive to the '
          .. 'person who placed the contract, who has to be there for the handover; a kill '
          .. 'never completes one. \'either\': a verified kill, or that handover.',
      inflight = 'Each contract keeps the rule it was placed under; this changes new contracts only.' },
    { key = 'Completion.KillPhotos', section = 'features', group = 'Completion', kind = 'switch',
      label = 'Kill photos',
      about = 'Off: no kill photo is ever taken, uploaded, kept or served, and no image host is '
          .. 'asked anything. Under \'either\', Verify kill completes at the scene on the '
          .. 'server\'s own checks.',
      inflight = 'Read at the next Verify kill, with no restart. A photo already kept stays until '
          .. 'it expires as usual, and its client can still open it once; off, links to photos '
          .. 'saved to a phone\'s Photos stop loading.' },
    { key = 'Completion.PhotoStorage', section = 'features', group = 'Completion', kind = 'choice',
      needs = 'Completion.KillPhotos',
      choices = { 'server', 'host' }, label = 'Where kill photos are kept',
      about = '\'server\': in this resource\'s data folder. \'host\': lb-phone\'s image host.',
      inflight = 'Photos already kept stay where they are and open as before; a photo token '
          .. 'asked for before the change is used the way it was issued.' },
    { key = 'Completion.RejectLastStand', section = 'features', group = 'Completion', kind = 'switch',
      label = 'A downed target is not a kill', about = 'Last stand does not count as dead.',
      inflight = AT_USE },
    { key = 'Completion.RequireObservedDamage', section = 'features', group = 'Completion',
      kind = 'switch', label = 'Kills need damage the server saw',
      about = 'The killer a victim names must also be in the server\'s own damage log.',
      inflight = AT_USE },
    { key = 'Ledger.StorePhotos', section = 'features', group = 'Completion', kind = 'switch',
      needs = 'Completion.KillPhotos',
      label = 'Keep kill photos for the client',
      about = 'The client who placed the contract can open its kill photo once.',
      inflight = 'Photos already kept stay openable; kills verified while it is off keep none.' },

    { key = 'Kidnap.RequireConscious', section = 'features', group = 'Handovers', kind = 'switch',
      label = 'Target must be conscious', about = 'Not dead, not downed, above the health floor.',
      inflight = AT_USE .. ' A contract placed under \'alive\' always checks it.' },
    { key = 'Kidnap.RejectDead', section = 'features', group = 'Handovers', kind = 'switch',
      label = 'Refuse a dead target', about = 'A body is never handed over.',
      inflight = AT_USE .. ' A contract placed under \'alive\' always checks it.' },
    { key = 'Kidnap.RejectLastStand', section = 'features', group = 'Handovers', kind = 'switch',
      label = 'Refuse a downed target', about = 'A target in last stand cannot be handed over.',
      inflight = AT_USE },
    { key = 'Kidnap.RequireCoercion', section = 'features', group = 'Handovers', kind = 'switch',
      label = 'Target must be restrained',
      about = 'Cuffed, or in the hitman\'s own vehicle, for the whole countdown.',
      inflight = AT_USE .. ' A countdown already running is checked by it on its next sample.' },
    { key = 'Kidnap.Coercion.handcuffed', section = 'features', group = 'Handovers', kind = 'switch',
      label = 'Handcuffs count as restraint', about = 'QBox \'ishandcuffed\' metadata.',
      inflight = AT_USE },
    { key = 'Kidnap.Coercion.passengerOfHitman', section = 'features', group = 'Handovers',
      kind = 'switch', label = 'The hitman\'s vehicle counts as restraint',
      about = 'The target riding in the hitman\'s vehicle.', inflight = AT_USE },

    { key = 'Penalty.RequireDisclosureOnAccept', section = 'features', group = 'Stakes',
      kind = 'switch', label = 'Accept must echo the stake shown',
      about = 'A page showing a stale stake is refused rather than charged a new one.',
      inflight = AT_USE },

    { key = 'Bailout.Enabled', section = 'features', group = 'Buyouts', kind = 'switch',
      label = 'Buyouts',
      about = 'A target may pay to close a contract on them, in the app or with the buyout '
          .. 'command for players the app is closed to.',
      inflight = 'A buyout already paid still closes the contract after its delay; new ones are '
          .. 'refused while it is off, and contracts placed meanwhile carry no buyout price. '
          .. 'A price already set is kept: only taking part of the reward back lowers it, '
          .. 'with the reward.' },
    { key = 'Bailout.BlockWhileIncapacitated', section = 'features', group = 'Buyouts',
      kind = 'switch', label = 'No buyout from the floor',
      about = 'A dead or downed target cannot buy out.', inflight = AT_USE },

    { key = 'Targeting.AllowBrowseAll', section = 'features', group = 'Targeting', kind = 'switch',
      label = 'Browse everyone online', about = 'Pick a target from a list of everyone online.',
      inflight = 'Placed contracts are untouched; the list is empty while it is off.' },
    { key = 'Targeting.AllowNearby', section = 'features', group = 'Targeting', kind = 'switch',
      label = 'List the people nearby', client = true,
      about = 'Names unmasked players within the nearby radius. Read its config comment first.',
      inflight = 'The list is empty while it is off, and players\' games stop reporting masks.' },
    { key = 'Targeting.AllowProtectedJobTargets', section = 'features', group = 'Targeting',
      kind = 'switch', label = 'Law enforcement may be targeted',
      about = 'Off refuses new contracts on protected jobs.',
      inflight = 'Contracts already on protected targets run on; only new ones are refused.' },
    { key = 'Mugshot.Enabled', section = 'features', group = 'Targeting', kind = 'switch',
      label = 'Target headshots', client = true,
      about = 'Faces on the board, rendered by each target\'s own game. Off: none is asked for, '
          .. 'one sent anyway is refused unread, and cards show the placeholder.',
      inflight = 'Read at the next card drawn, with no restart: turned off, the headshots kept '
          .. 'are forgotten at once.' },
    { key = 'Mugshot.RemoveBackground', section = 'features', group = 'Targeting', kind = 'switch',
      needs = 'Mugshot.Enabled',
      label = 'Cut the background out of headshots', client = true,
      about = 'Loads a segmentation model into the target\'s game for each render.',
      inflight = 'Headshots already cached keep the background they were made with.' },

    { key = 'Advisory.Enabled', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Advisories', about = 'Law enforcement is told about contracts on officers.',
      inflight = 'Bulletins already sent stand; none is sent while it is off.' },
    { key = 'Advisory.UseDispatch', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Through sc-dispatch', about = 'Raise a dispatch entry as well.',
      inflight = AT_USE },
    { key = 'Advisory.AlwaysAlertTarget', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Always tell the officer', about = 'The targeted officer is told.',
      inflight = AT_USE },
    { key = 'Advisory.OnCreate', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'When posted', about = 'A bulletin when the contract is posted.',
      inflight = AT_USE },
    { key = 'Advisory.OnAccept', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'When accepted', about = 'A bulletin when an operative accepts.',
      inflight = AT_USE },
    { key = 'Advisory.WarnCreator', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Warn the client', about = 'Before escrow is taken.', inflight = AT_USE },
    { key = 'Advisory.WarnHitman', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Warn the hitman', about = 'Before they accept.', inflight = AT_USE },
    { key = 'Advisory.FlagListing', section = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = 'Flag the listing', about = 'The board marks an officer target.',
      inflight = AT_USE },

    { key = 'Relay.Enabled', section = 'features', group = 'Messages and calls', kind = 'switch',
      label = 'Messages', about = 'The masked relay between the parties of a contract.',
      inflight = 'Threads are kept and come back when it is on again; nothing can be read or '
          .. 'sent while it is off.' },
    { key = 'Relay.AllowMaskedCalls', section = 'features', group = 'Messages and calls',
      kind = 'switch', label = 'Calls', about = 'Calls between the parties through lb-phone.',
      inflight = 'A call already ringing is left alone; new ones are refused.' },
    { key = 'Relay.RequireMaskingForAnonymous', section = 'features', group = 'Messages and calls',
      kind = 'switch', label = 'Never unmask a caller',
      about = 'No call to or from an anonymous party on a phone that cannot hide the number.',
      inflight = AT_USE },

    { key = 'Amendments.Enabled', section = 'features', group = 'Proposals', kind = 'switch',
      label = 'Proposals', about = 'Changes to a contract that need the other side\'s agreement.',
      inflight = 'Proposals already open can still be answered and run out as before; new ones '
          .. 'are refused while it is off.' },

    { key = 'Informant.Enabled', section = 'features', group = 'Informant', kind = 'switch',
      label = 'Informant', about = 'A target may pay to learn who is tracking them.',
      inflight = 'Names already bought stay shown; new purchases are refused while it is off.' },
    { key = 'Informant.RequireProximity', section = 'features', group = 'Informant', kind = 'switch',
      label = 'Only hitmen seen nearby', about = 'Only an operative seen near the target is named.',
      inflight = AT_USE },

    { key = 'Notifications.ParanoidAlert', section = 'features', group = 'Notifications',
      kind = 'switch', label = 'Tell the target', about = 'The target\'s phone says a price is on them.',
      inflight = 'Alerts already sent stand; alerts still waiting are checked when they fall due.' },
    { key = 'Notifications.PushEnabled', section = 'features', group = 'Notifications',
      kind = 'switch', label = 'Refresh open apps', about = 'Nudge an open app when its contract changes.',
      inflight = AT_USE },

    { key = 'Limits.PauseWhileTargetJailed', section = 'features', group = 'The clock',
      kind = 'switch', label = 'Pause while the target is jailed',
      about = 'A target serving time stops the deadline, as one offline does.',
      inflight = 'Checked by the next expiry pass: a pause it began ends, with the time banked.' },

    { key = 'AntiCollusion.BlockSameAccount', section = 'features', group = 'Anti-collusion',
      kind = 'switch', label = 'Refuse your own account',
      about = 'No contract between characters of one account.',
      inflight = 'Contracts already placed run on; new ones and acceptances are checked.' },

    { key = 'Progression.Enabled', section = 'features', group = 'Progression', kind = 'switch',
      label = 'Criminal progression', about = 'Completed contracts earn sc-blackmarket trust.',
      inflight = 'Trust already given stands; completions while it is off earn none.' },

    { key = 'Audit.LogAllActions', section = 'features', group = 'Audit and debug', kind = 'switch',
      label = 'Log player conduct', about = 'Every creation, acceptance and refusal, not only money.',
      inflight = 'Money, staff actions and refusals are always logged whatever this says.' },
    { key = 'Audit.LogReasonText', section = 'features', group = 'Audit and debug', kind = 'switch',
      label = 'Log contract reasons', about = 'The reason text goes into the log.', inflight = AT_USE },
    { key = 'Debug', section = 'features', group = 'Audit and debug', kind = 'switch',
      label = 'Debug output in the server console',
      about = 'Off: the server console prints only what needs you (refusing to start, money '
          .. 'left for staff, a write that failed) and one line for every setting that needs '
          .. 'attention. On: everything, each setting problem in full and page faults with their '
          .. 'stack. The diagnosis lists all of it either way.',
      inflight = 'Read at every line printed, with no restart. The lines of a start before the '
          .. 'panel\'s settings are applied (the store opening, its migrations) follow config.lua; '
          .. 'the diagnosis lists them either way.' },

    -- Read only, with the reason -----------------------------------------
    { key = 'Admin.Enabled', section = 'readonly', group = 'Staff', kind = 'switch',
      label = 'Staff tools',
      readonly = 'Turning the staff tools off from the staff tools would lock you out of turning '
          .. 'them back on. Set it in config.lua.' },
    { key = 'Admin.Ace', section = 'readonly', group = 'Staff', kind = 'text',
      label = 'Staff ACE', readonly = 'Who may use this panel. Set it in config.lua, so a slip '
          .. 'here cannot lock staff out.' },
    { key = 'Admin.IdentityAce', section = 'readonly', group = 'Staff', kind = 'text',
      label = 'Identity ACE', readonly = 'Who may unmask anonymous parties. Set it in config.lua.' },
    { key = 'Database.Mode', section = 'readonly', group = 'Storage', kind = 'text',
      label = 'Storage mode', readonly = 'Changing it needs the money in the old mode settled and '
          .. 'a restart (README, Changing storage mode).' },
    { key = 'Database.AllowModeSwitch', section = 'readonly', group = 'Storage', kind = 'switch',
      label = 'Start over money in another mode',
      readonly = 'Read once at start, and only safe on a server that settled the old mode by hand.' },
    { key = 'Database.Json.SyncOnFinancialWrite', section = 'readonly', group = 'Storage',
      kind = 'switch', label = 'Write money to disk as it moves',
      readonly = 'Off, a crash could lose money that had moved. Set it in config.lua.' },
    { key = 'Database.QueryTimeoutSeconds', section = 'readonly', group = 'Storage',
      kind = 'number', label = 'Database answer limit (s)',
      readonly = 'mysql only. Set it in config.lua; it takes effect at the next start.' },

    -- Limits and settings -------------------------------------------------
    { key = 'Limits.MaxActiveContractsPerCreator', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Contracts a client may have out',
      inflight = CAP },
    { key = 'Limits.MaxAcceptedPerHitman', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Contracts a hitman may hold',
      inflight = CAP },
    { key = 'Limits.MaxActiveContractsPerTarget', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Contracts on one target',
      inflight = CAP },
    { key = 'Limits.MinContractReward', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 100000000,
      label = 'Least a reward may be worth ($, 0 off)', inflight = CAP },
    { key = 'Limits.MaxHitmenPerContract', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = 'Operatives on one contract',
      inflight = CAP },
    { key = 'Limits.MaxPayoutSlots', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 3,
      label = 'Times one contract can be collected (1 to 3)',
      inflight = 'New contracts only: each contract keeps the number it was placed with. At 1 the '
          .. 'Place form shows no extra collections.' },
    { key = 'Limits.MaxEscrowLines', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 500, label = 'Escrow lines in one contract',
      inflight = CAP },
    { key = 'Limits.MaxDeadlineSkipSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 10, max = 3600,
      label = 'Longest the expiry pass sleeps (s)', inflight = AT_USE },
    { key = 'Limits.SlotCooldownSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Wait between one hitman\'s payouts (s)', inflight = AT_USE },
    { key = 'Limits.TargetCooldownAfterResolveSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Wait before a target is listed again (s)', inflight = AT_USE },
    { key = 'Limits.SameCreatorSameTargetCooldownSeconds', section = 'limits',
      group = 'Contract limits', kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Wait before one client lists one target again (s)', inflight = AT_USE },
    { key = 'Limits.ContractLifetimeSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 600, max = 2592000,
      label = 'Longest a contract may run (s)',
      inflight = 'New contracts only: each contract keeps the lifetime it was placed with.' },
    { key = 'Limits.DefaultDeadlineSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 300, max = 2592000,
      label = 'Deadline a new contract gets (s)',
      inflight = 'New contracts only: each contract keeps the deadline it was given.' },
    { key = 'Limits.ExclusiveIdleReleaseSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Release an idle exclusive hold after (s, 0 off)', inflight = AT_USE },
    { key = 'Limits.ExclusiveAttemptWindowSeconds', section = 'limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = 'Release a hold with no attempt after (s, 0 off)', inflight = AT_USE },
    { key = 'Limits.JailZone.radius', section = 'limits', group = 'Contract limits',
      kind = 'number', min = 10, max = 5000, label = 'Prison grounds radius (m)', inflight = AT_USE },

    { key = 'Penalty.MaxAmount', section = 'limits', group = 'Stakes', kind = 'number',
      integer = true, min = 0, max = 100000000, label = 'Largest stake ($)',
      inflight = 'New contracts only: a stake is fixed when the contract is placed.' },
    { key = 'Penalty.MaxFractionOfEscrow', section = 'limits', group = 'Stakes', kind = 'number',
      min = 0, max = 10, label = 'Largest stake, as a share of the reward',
      inflight = 'New contracts only: a stake is fixed when the contract is placed.' },
    { key = 'Penalty.MinWindowMinutes', section = 'limits', group = 'Stakes', kind = 'number',
      integer = true, min = 0, max = 1440, label = 'Least time left to stake on (min)',
      inflight = AT_USE },

    { key = 'Anonymity.CreatorFee', section = 'limits', group = 'Anonymity', kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Fee to place anonymously ($)',
      inflight = 'Charged when a contract is placed; a fee refunded is always the one charged.' },
    { key = 'Anonymity.HitmanFee', section = 'limits', group = 'Anonymity', kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Fee to accept anonymously ($)',
      inflight = 'Charged when a contract is accepted.' },
    { key = 'Anonymity.FeeAccount', section = 'limits', group = 'Anonymity', kind = 'choice',
      choices = { 'bank', 'cash' }, label = 'Account the fees are charged to',
      inflight = 'A fee refunded goes back to the account it was taken from.' },

    { key = 'Informant.Cost', section = 'limits', group = 'Informant', kind = 'number',
      integer = true, min = 0, max = 10000000, label = 'Price of a name ($)', inflight = AT_USE },

    { key = 'Kidnap.CountdownSeconds', section = 'limits', group = 'Handovers', kind = 'number',
      integer = true, min = 5, max = 600, label = 'Handover countdown (s)', inflight = AT_USE
          .. ' A countdown already running finishes at the new length.' },
    { key = 'Kidnap.Radius', section = 'limits', group = 'Handovers', kind = 'number',
      min = 2, max = 100, label = 'Handover radius (m)',
      inflight = 'A countdown already running keeps the radius it was armed with.' },
    { key = 'Kidnap.MinTargetHealthPercent', section = 'limits', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 100,
      label = 'Least health to hand a target over (%)', inflight = AT_USE },

    { key = 'Bailout.MinMultiplier', section = 'limits', group = 'Buyout pricing', kind = 'number',
      min = 0, max = 20, label = 'Least buyout, times the reward',
      inflight = 'New contracts only: a buyout price is fixed when the contract is placed.' },
    { key = 'Bailout.MaxMultiplier', section = 'limits', group = 'Buyout pricing', kind = 'number',
      min = 0, max = 20, label = 'Most buyout, times the reward',
      inflight = 'New contracts only: a buyout price is fixed when the contract is placed, '
          .. 'and only comes down, to this many times what is left, when part of the reward '
          .. 'is taken back.' },
    { key = 'Bailout.AbsoluteMax', section = 'limits', group = 'Buyout pricing', kind = 'number',
      integer = true, min = 0, max = 100000000, label = 'Most buyout ($)',
      inflight = 'New contracts only: a buyout price is fixed when the contract is placed, '
          .. 'and lowering this never re-prices one.' },

    { key = 'Targeting.NearbyRadius', section = 'limits', group = 'Targeting', kind = 'number',
      min = 5, max = 200, label = 'Nearby list radius (m)', inflight = AT_USE },
    { key = 'Targeting.MaxNearby', section = 'limits', group = 'Targeting', kind = 'number',
      integer = true, min = 1, max = 50, label = 'Names on the nearby list', inflight = AT_USE },
    { key = 'Targeting.NearbyClosedAfterSeconds', section = 'limits', group = 'Targeting',
      kind = 'number', integer = true, min = 0, max = 86400,
      label = 'Nearby list closed after a contract (s)', inflight = AT_USE },
    { key = 'Targeting.BrowsePageSize', section = 'limits', group = 'Targeting', kind = 'number',
      integer = true, min = 5, max = 100, label = 'Names per page when browsing', inflight = AT_USE },
    { key = 'Targeting.MinQueryLength', section = 'limits', group = 'Targeting', kind = 'number',
      integer = true, min = 1, max = 10, label = 'Shortest name search', inflight = AT_USE },
    { key = 'Targeting.MaxResults', section = 'limits', group = 'Targeting', kind = 'number',
      integer = true, min = 1, max = 50, label = 'Results of a name search', inflight = AT_USE },

    { key = 'Ledger.PhotoRetentionDays', section = 'limits', group = 'Ledger', kind = 'number',
      integer = true, min = 0, max = 365, label = 'Days an unopened kill photo is kept (0 forever)',
      inflight = 'Looked at every ten minutes: photos already past a shorter age go then.',
      destroys = 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the '
          .. 'next sweep, for good.' },

    { key = 'Advisory.TriggerJobTypes', section = 'limits', group = 'Advisory job lists',
      kind = 'list', label = 'Job types that raise an advisory', inflight = AT_USE },
    { key = 'Advisory.TriggerJobNames', section = 'limits', group = 'Advisory job lists',
      kind = 'list', label = 'Job names that raise an advisory', inflight = AT_USE },
    { key = 'Advisory.RecipientJobTypes', section = 'limits', group = 'Advisory job lists',
      kind = 'list', label = 'Job types that receive advisories', inflight = AT_USE },
    { key = 'Advisory.RecipientJobNames', section = 'limits', group = 'Advisory job lists',
      kind = 'list', label = 'Job names that receive advisories', inflight = AT_USE },
}

--- The rate-limit buckets, each as two keys: how many seconds a full
--- bucket refills over, and how many it holds.
local BUCKETS = {
    'load', 'search', 'wallet', 'create', 'accept', 'amend', 'informant', 'bailout', 'photo',
    'photoSubmit', 'photoView', 'photoDecide', 'message', 'progress', 'death', 'mugshot',
    'image', 'diagnostic', 'admin', 'adminWrite',
}

--- The panel's own buckets, which every request it makes spends (Panel.handle).
--- Changeable here, one request an hour was accepted, kept and applied at
--- every start, and the page's own overview refresh spent it: the reset that
--- would have put it back was refused with the rest, and only an edit of the
--- store by hand let staff in again.
local PANEL_BUCKETS = { admin = true, adminWrite = true }
local PANEL_BUCKET_READONLY = 'The staff panel\'s own allowance, which every request it makes '
    .. 'spends: set too low from here it would refuse the very request that puts it back, at '
    .. 'every start. Set it in config.lua.'

for _, bucket in ipairs(BUCKETS) do
    local panel = PANEL_BUCKETS[bucket]
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Cooldowns.' .. bucket .. '.per', section = panel and 'readonly' or 'limits',
        group = panel and 'Staff' or 'Rate limits',
        kind = 'number', min = 0.5, max = 3600, label = bucket .. ': refill window (s)',
        inflight = not panel and AT_USE or nil, readonly = panel and PANEL_BUCKET_READONLY or nil,
    }
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Cooldowns.' .. bucket .. '.burst', section = panel and 'readonly' or 'limits',
        group = panel and 'Staff' or 'Rate limits',
        kind = 'number', integer = true, min = 1, max = 200, label = bucket .. ': requests held',
        inflight = not panel and AT_USE or nil, readonly = panel and PANEL_BUCKET_READONLY or nil,
    }
end

local byKey = {}
for i = 1, #CATALOGUE do byKey[CATALOGUE[i].key] = CATALOGUE[i] end

Settings.CATALOGUE = CATALOGUE

--------------------------------------------------------------------------
-- Reading and writing a key
--------------------------------------------------------------------------

local function copyOf(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copyOf(v) end
    return out
end

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
    if entry.kind == 'list' then return asList(stored) end
    return copyOf(stored)
end

--- And in the shape the config holds it.
local function stored(entry, value)
    if entry.kind == 'list' then return asSet(value) end
    return copyOf(value)
end

--- What the panel would show for a key now.
local function current(entry)
    return shown(entry, read(Config, entry.key))
end

--------------------------------------------------------------------------
-- Checking a value
--------------------------------------------------------------------------

local LIST_MAX, NAME_MAX = 50, 32

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
        if (entry.min and n < entry.min) or (entry.max and n > entry.max) then
            return nil, ('has to be from %s to %s'):format(tostring(entry.min), tostring(entry.max))
        end
        return n
    end
    if entry.kind == 'list' then
        if type(raw) ~= 'table' then return nil, 'has to be a list of job names' end
        if #raw > LIST_MAX then return nil, ('takes at most %d names'):format(LIST_MAX) end
        local seen, out = {}, {}
        for i = 1, #raw do
            local name = raw[i]
            if type(name) ~= 'string' or #name == 0 or #name > NAME_MAX
                or not name:match('^[%w_%-]+$') then
                return nil, ('names letters, digits, - and _ only, up to %d long'):format(NAME_MAX)
            end
            name = name:lower()
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
        table.sort(out)
        return out
    end
    return nil, 'cannot be changed here'
end

--- Whether a set of changes passes the start-up checks, run against a copy
--- of the live config with the changes in it (main.lua's checkConfig).
---
--- Refused when the checks would refuse to start on it, or would quietly
--- change any key the panel shows: a value they correct at start is one
--- that would not mean what staff set it to. Their own words are the reason.
---@param changes table [key] = value as the panel shows it
---@return boolean ok
---@return string|nil reason
local function fits(changes)
    if not Check then return true end
    local candidate = copyOf(Config)
    for key, value in pairs(changes) do write(candidate, key, stored(byKey[key], value)) end
    local ok, fatal, warn = Check(candidate)
    fatal, warn = fatal or {}, warn or {}
    if not ok or #fatal > 0 then
        return false, tostring(fatal[1] or 'the start-up checks refuse it')
    end
    for _, entry in ipairs(CATALOGUE) do
        if not entry.readonly then
            local wanted = changes[entry.key]
            if wanted == nil then wanted = current(entry) end
            local got = shown(entry, read(candidate, entry.key))
            if not same(got, wanted) then
                local name = entry.key:match('([%w_]+)$')
                for _, line in ipairs(warn) do
                    if line:find(entry.key, 1, true) or line:find(name, 1, true) then
                        return false, line
                    end
                end
                return false, ('the start-up checks would change Config.%s'):format(entry.key)
            end
        end
    end
    return true
end

--- A value for a key, checked as the start-up checks would check it.
---@param key string
---@param raw any
---@return any value as the panel shows it, or nil
---@return string|nil err 'not_allowed' | 'read_only' | 'invalid_value'
---@return string|nil why
function Settings.check(key, raw)
    local entry = type(key) == 'string' and byKey[key] or nil
    if not entry then return nil, 'not_allowed', 'not a setting the panel may change' end
    if entry.readonly then return nil, 'read_only', entry.readonly end
    local value, why = normalise(entry, raw)
    if value == nil then return nil, 'invalid_value', why end
    local ok, reason = fits({ [key] = value })
    if not ok then return nil, 'invalid_value', reason end
    return value
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

function Settings.init(deps)
    Storage, Audit, Check = deps.storage, deps.audit, deps.check
    overrides, ignored = {}, {}
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
end

local function setKey(key, raw, staff, actorCid)
    local value, err, why = Settings.check(key, raw)
    if value == nil then return false, err, why end
    local entry = byKey[key]
    local old = current(entry)
    local backToConfig = same(value, defaults[key])
    local at = os.time()

    local wrote, writeErr
    if backToConfig then
        wrote, writeErr = pcall(Storage.deleteSetting, key)
    else
        wrote, writeErr = pcall(Storage.writeSetting, key, copyOf(value), staff, at)
    end
    if not wrote then
        return false, 'store_failed', Util.dbError(writeErr)
    end

    write(Config, key, stored(entry, value))
    if backToConfig then
        overrides[key] = nil
    else
        overrides[key] = { value = copyOf(value), by = staff, at = at }
    end
    ignored[key] = nil

    Audit.staff('admin_setting_changed', actorCid, nil, {
        key = key, old = old, new = copyOf(value), by = staff,
        source = backToConfig and 'config' or 'panel',
    })
    flushNow()
    changed(entry)
    return true, nil, { key = key, value = copyOf(value), old = old,
                        source = backToConfig and 'config' or 'panel' }
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
--- listed as not applied.
local function resetKey(key, staff, actorCid)
    local entry = type(key) == 'string' and byKey[key] or nil
    if not entry then return false, 'not_allowed', 'not a setting the panel may change' end
    if entry.readonly and not ignored[key] then return false, 'read_only', entry.readonly end
    if not overrides[key] and not ignored[key] then
        return false, 'not_overridden', 'it is what config.lua says already'
    end
    -- What config.lua says passed the start-up checks on its own, but not
    -- necessarily beside the other overrides still in force: a least
    -- buyout put back under a most one changed from here.
    if overrides[key] then
        local ok, reason = fits({ [key] = defaults[key] })
        if not ok then return false, 'invalid_value', reason end
    end
    local wrote, writeErr = pcall(Storage.deleteSetting, key)
    if not wrote then return false, 'store_failed', Util.dbError(writeErr) end

    local old = current(entry)
    write(Config, key, stored(entry, defaults[key]))
    local had = overrides[key] ~= nil
    overrides[key], ignored[key] = nil, nil
    Audit.staff('admin_setting_reset', actorCid, nil,
        { key = key, old = old, new = copyOf(defaults[key]), by = staff })
    flushNow()
    if had then changed(entry) end
    return true, nil, { key = key, value = copyOf(defaults[key]), old = old, source = 'config' }
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
    local wrote, writeErr = pcall(Storage.clearSettings)
    if not wrote then return false, 'store_failed', Util.dbError(writeErr) end
    local keys, changes = {}, {}
    for key in pairs(overrides) do keys[#keys + 1] = key end
    for key in pairs(ignored) do if not overrides[key] then keys[#keys + 1] = key end end
    table.sort(keys)
    local touched = {}
    for _, key in ipairs(keys) do
        local entry = byKey[key]
        if entry and overrides[key] then
            changes[key] = { old = current(entry), new = copyOf(defaults[key]) }
            write(Config, key, stored(entry, defaults[key]))
            touched[#touched + 1] = entry
        end
    end
    overrides, ignored = {}, {}
    Audit.staff('admin_settings_reset_all', actorCid, nil,
        { keys = keys, changes = changes, by = staff })
    flushNow()
    for _, entry in ipairs(touched) do changed(entry) end
    return true, nil, { keys = #keys }
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

--- Every key the panel shows, with its value now, what config.lua says,
--- and where the value in force comes from.
---@return table { features = entry[], limits = entry[], readonly = entry[], overrides = n }
function Settings.view()
    local out = { features = {}, limits = {}, readonly = {}, overrides = 0 }
    for _, entry in ipairs(CATALOGUE) do
        local override = overrides[entry.key]
        local skipped = ignored[entry.key]
        local row = {
            key = entry.key, group = entry.group, label = entry.label, about = entry.about,
            kind = entry.kind, choices = entry.choices, min = entry.min, max = entry.max,
            integer = entry.integer or nil, live = entry.live ~= false,
            inflight = entry.inflight, readonly = entry.readonly, destroys = entry.destroys,
            value = current(entry), default = copyOf(defaults[entry.key]),
            source = override and 'panel' or 'config',
            by = override and override.by or nil, at = override and override.at or nil,
            ignored = skipped and skipped.why or nil,
            inactive = (entry.needs and read(Config, entry.needs) ~= true
                and NEEDS_OFF[entry.needs])
                or (entry.unless and read(Config, entry.unless) == true
                and UNLESS_ON[entry.unless]) or nil,
        }
        if override then out.overrides = out.overrides + 1 end
        local list = out[entry.section]
        list[#list + 1] = row
    end
    return out
end

--- The overrides in force and the ones not applied, by key, for /ch-diag.
---@return table[] { key, value, by, at, ignored }
function Settings.active()
    local out = {}
    for key, override in pairs(overrides) do
        out[#out + 1] = { key = key, value = copyOf(override.value), by = override.by, at = override.at }
    end
    for key, skipped in pairs(ignored) do
        out[#out + 1] = { key = key, value = copyOf(skipped.value), by = skipped.by,
                          at = skipped.at, ignored = skipped.why }
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

return Settings
