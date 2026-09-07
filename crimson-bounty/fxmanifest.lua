fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'crimson-bounty'
author 'Crimson'
description 'Crimson Bounty System — criminal contract board for QBox and lb-phone'
version '1.1.0'

shared_scripts {
    'shared/constants.lua',
    -- The shipped configuration, then the operator's. Theirs wins on every
    -- setting it names; boot fills in any section it does not name at all.
    'config/defaults.lua',
    'config/config.lua',
}

client_scripts {
    -- The client needs Util.monotonicMs: GetGameTimer wraps every ~24.8 days
    -- and the mugshot floor is an elapsed subtraction against it. The server
    -- loads this same file through require_shared instead.
    'shared/util.lua',
    'client/main.lua',
    'client/mugshot.lua',
}

server_scripts {
    -- Loaded whatever storage mode is configured, because a manifest cannot
    -- read config. In json mode nothing here queries a database, but the
    -- file still has to resolve — so oxmysql must be present and started
    -- even on a server that never uses it. qbx_core already requires it.
    '@oxmysql/lib/MySQL.lua',
    'server/boot.lua',
    'server/main.lua',
}

files {
    'ui/index.html',
    'ui/app.css',
    'ui/app.js',
    'ui/icon.png',
}

dependencies {
    'qbx_core',
    'ox_inventory',
    'lb-phone',
}

--- Optional integrations, all detected at runtime and skipped when absent:
---   sc-ambulance     server-side death and last-stand state
---   sc-dispatch      law enforcement threat advisories in the MDT
---   sc-blackmarket   criminal progression on a completed contract
---   MugShotBase64    live target headshots
