fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'crimson-bounty'
author 'Crimson'
description 'Crimson Bounty System — criminal contract board for QBox and lb-phone'
version '1.0.0'

shared_scripts {
    'shared/constants.lua',
    'config/config.lua',
}

client_scripts {
    'client/main.lua',
    'client/mugshot.lua',
}

server_scripts {
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
