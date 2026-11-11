--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                 crimson-hitman - locales/client/en.lua                    ║
    ║    The words the game itself shows: markers, app icon, target options     ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

-- The only language file sent to every player's game (fxmanifest.lua): the
-- rest of the words (locales/en.lua: notices, staff answers, Discord posts)
-- stay on the server. To translate: copy this file to
-- locales/client/<language>.lua (say de.lua), change CrimsonClientLocales.en
-- below to CrimsonClientLocales.de and translate the texts on the right, as
-- for locales/en.lua. A key your file leaves out reads in English.
-- Left readable on an escrowed build (escrow_ignore in fxmanifest.lua).

CrimsonClientLocales = CrimsonClientLocales or {}

CrimsonClientLocales.en = {
    -- =========================================================================
    --      IN GAME: THE APP ICON, MAP MARKERS, TARGET OPTIONS (client/)
    -- =========================================================================
    ['client.crimson_hitman'] = 'Crimson-Hitman',
    ['client.contracts_quietly_arranged'] = 'Contracts, quietly arranged.',
    ['client.crimson'] = 'Crimson',
    ['client.informant_tip'] = 'Informant tip',
    ['client.meeting_point'] = 'Meeting point',
    ['client.kill_to_verify'] = 'Kill to verify',
    ['client.handover'] = 'Handover',
    ['client.protection_meeting_pin'] = 'Protection meeting pin',
    ['client.body_to_collect'] = 'Body to collect',
    ['client.disposal_vehicle'] = 'Disposal vehicle',
    ['client.body_drop_off'] = 'Body drop-off',
    ['client.broker'] = 'Broker',
    ['client.informant'] = 'Informant',
    ['client.organisation_office'] = 'Organisation office',
    ['client.organisation_spot'] = 'Organisation spot',
    ['client.load_the_body'] = 'Load the body',
    ['client.drop_off_the_body'] = 'Drop off the body',
}

return CrimsonClientLocales.en
