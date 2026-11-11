fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'crimson-hitman'
author 'Crimson'
description 'Crimson Hitman System — criminal contract board for QBox and lb-phone'
version '1.2.0'

shared_scripts {
    'shared/constants.lua',
    -- The shipped configuration, then the operator's. Theirs wins on every
    -- setting it names; boot fills in any section it does not name at all.
    'config/defaults.lua',
    'config/config.lua',
}

client_scripts {
    -- qbx_core's own copy of this player's data, as QBX.PlayerData: it
    -- follows QBCore:Player:SetPlayerData and empties on unload, so the
    -- death watcher reads the medical metadata from it rather than asking
    -- the GetPlayerData export for the whole record every second.
    '@qbx_core/modules/playerdata.lua',
    -- The client needs Util.monotonicMs: GetGameTimer wraps every ~24.8 days
    -- and the mugshot floor is an elapsed subtraction against it. The server
    -- loads this same file through CrimsonBoot.requireShared instead.
    'shared/util.lua',
    -- Positions and distances (CrimsonGeo), one copy for both sides.
    'shared/geo.lua',
    -- The one way to the console (CrimsonLog): with Config.Debug off the
    -- client prints nothing to F8 but a staff command's own answer.
    'shared/log.lua',
    -- The words the game shows, by key (CrimsonClientLocales, CrimsonLocale.t):
    -- every language's locales/client/ file, then the lookup, in the language
    -- Config.Locale names. The server's words (locales/*.lua) are not sent.
    'locales/client/*.lua',
    'shared/locale.lua',
    -- The other scripts this resource works with (CrimsonIntegrations), and
    -- the client's adapters for them, one file per kind and name
    -- (docs/dev/adapters.md), before anything that calls one.
    'shared/integrations.lua',
    'client/adapters/*/*.lua',
    -- The map markers for each step of a contract (CrimsonMarkers), before
    -- client/main.lua, which draws the tip and the meeting point with them.
    'client/missionsteps.lua',
    'client/main.lua',
    'client/mugshot.lua',
    -- The admin panel's page: opening it, closing it, its requests.
    'client/admin.lua',
    -- Making and removing scenery NPCs and their blips (CrimsonNpc), before
    -- the files that draw them.
    'client/npc.lua',
    -- The roleplay NPCs, the broker and the informant (Config.Roleplay).
    'client/rp_npc.lua',
    -- The hitman organisation's spots (Config.Organisation, off as shipped):
    -- nothing runs until the server sends this player a spot to draw.
    'client/org.lua',
}

server_scripts {
    -- Loaded whatever storage mode is configured, because a manifest cannot
    -- read config. In json mode the store queries no database; the playtime
    -- count only reads qbx_core's own players table through it, to tell
    -- characters from before it was installed (server/playtime.lua). So
    -- oxmysql must be present and started in every mode. qbx_core already
    -- requires it.
    '@oxmysql/lib/MySQL.lua',
    'server/boot.lua',
    'server/main.lua',
}

-- Kill photos are never one of the page's files, and with
-- Config.Completion.KillPhotos = false (as shipped) there are none at all:
-- nothing below is written or served. With them on, on 'server' photo
-- storage (the default) they are written to data/photos/ by the server, which must
-- be able to write there, and reach the client's phone as a latent event
-- when they open one. A photo the client saves to their phone's Photos is
-- served read-only by this resource's own HTTP handler (SetHttpHandler, in
-- server/bridges.lua) at https://<public address>/crimson-hitman/p/<name>,
-- for as long as their Photos keeps it. That needs a public https address
-- (Config.Completion.PhotoPublicUrl, or web_baseUrl) and that host in
-- lb-phone's Config.UploadWhitelistedHostnames; /ch-diag checks both.
-- The admin panel (/hitmanadmin) is this resource's own NUI page. The phone
-- app is not: lb-phone draws ui/index.html in a frame of its own, from the
-- files below, and setting a page here changes nothing about it. The page
-- stays hidden, and takes no input, until staff open it.
ui_page 'ui/admin.html'

files {
    -- The design system both pages link first (colours, type, buttons,
    -- fields, cards, chips, notices, tables, dialogs).
    'ui/kit.css',
    'ui/index.html',
    'ui/app.css',
    'ui/app.js',
    'ui/icon.png',
    'ui/admin.html',
    'ui/admin.css',
    'ui/admin.js',
    -- The words both pages read, by key, in each language (Config.Locale).
    'locales/*.json',
}

-- Left readable on an escrowed build (FiveM Asset Escrow): every file a
-- server owner edits. ui/, install/sql/ and data/ are not Lua, and only Lua
-- is escrowed. README, "Escrow, and where the words live".
escrow_ignore {
    'config/*.lua',
    -- The words players and staff read, in every language (README, Translations).
    'locales/*.lua',
    'locales/client/*.lua',
    'server/adapters/*.lua',
    'server/adapters/*/*.lua',
    'client/adapters/*.lua',
    'client/adapters/*/*.lua',
}

-- Only the framework. Every other script is optional, behind an adapter
-- (server/adapters/, client/adapters/, Config.Integrations): one that is
-- missing turns off what needs it, said in one console line at start.
--
-- Not lb-phone. FiveM stops every resource that depends on one being
-- restarted and never starts them again, so `restart lb-phone` after a config
-- edit took this app off every phone, and stopped the handover countdowns,
-- expiry and the death sampler with it, until somebody typed `ensure
-- crimson-hitman`. lb-phone's own app templates declare no dependency on it
-- either: the client waits for lb-phone and adds the app again whenever it
-- starts (client/main.lua), and every server call into it is guarded.
--
-- Not ox_inventory: without it, item, weapon and dirty-money rewards are
-- off and cash and bank rewards work. qbx_core stays: players, jobs and
-- money are read through it, and its playerdata module is loaded above.
-- Restarting it (or oxmysql) still stops this resource; `ensure
-- crimson-hitman` afterwards (README, Updating).
dependencies {
    'qbx_core',
}
