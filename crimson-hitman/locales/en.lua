--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                    crimson-hitman - locales/en.lua                        ║
    ║        Every word players and staff read in game, by key (English)        ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

-- To translate: copy this file to locales/<language>.lua (say de.lua), change
-- the line CrimsonLocales.en below to CrimsonLocales.de, translate the texts on
-- the right and set Config.Locale = 'de' in config/config.lua. Keep every %s
-- and %d, in the same order: the code puts names, numbers and amounts there.
-- A key your file leaves out reads in English, and the console says so once.
-- The phone app and the admin panel read locales/<language>.json the same way.
-- Left readable on an escrowed build (escrow_ignore in fxmanifest.lua).

CrimsonLocales = CrimsonLocales or {}

CrimsonLocales.en = {
    -- =========================================================================
    --                 NOTICES TO PLAYERS (server/notify.lua)
    -- =========================================================================
    ['notify.contract_on_you'] = 'Contract on you',
    ['notify.a_contract_on_you_is_now'] = 'A contract on you is now listed in this app.',
    ['notify.a_whitelisted_job_member'] = 'a whitelisted-job member',
    ['notify.contract_on_a_whitelisted_job'] = 'Contract on a whitelisted job',
    ['notify.a_contract_on_is_now_listed'] = 'A contract on %s is now listed in this app.',
    ['notify.unsettling'] = 'Unsettling',
    ['notify.you_feel_eyes_on_you_a'] = 'You feel eyes on you. A price has been put on your head.',
    ['notify.an_operative'] = 'an operative',
    ['notify.your_contract_on_has_been_accepted'] = 'Your contract on %s has been accepted by %s. %d operative%s now active.',
    ['notify.is'] = ' is',
    ['notify.are'] = 's are',
    ['notify.a_hitman_took_your_contract_on'] = 'A hitman%s took your contract on %s. They\'ll bring the target to you alive — stay in the city%s.%s',
    ['notify.and_watch_your_messages'] = ' and watch your messages',
    ['notify.hitmen_are_on_it_now'] = ' %d hitmen are on it now.',
    ['notify.contract_accepted'] = 'Contract accepted',
    ['notify.the_photo_is_waiting_under_ledger'] = 'The photo is waiting under Ledger. You can see it once: save it to your Photos to keep it.',
    ['notify.your_contract_was_fulfilled_by_live'] = 'Your contract was fulfilled by live delivery: the target was handed over in person.',
    ['notify.your_contract_was_fulfilled_by_live_2'] = 'Your contract was fulfilled by live delivery. There is no photograph — the target was handed over in person.',
    ['notify.your_contract_was_fulfilled'] = 'Your contract was fulfilled. ',
    ['notify.your_contract_was_fulfilled_2'] = 'Your contract was fulfilled.',
    ['notify.contract_fulfilled'] = 'Contract fulfilled',
    ['notify.collection_paid'] = 'Collection paid',
    ['notify.collection_of_on_your_contract_was'] = 'Collection %d of %d on your contract was paid%s.',
    ['notify.by_live_delivery'] = ' by live delivery',
    ['notify.it_is_still_running_with_more'] = ' It is still running, with %d more to collect.',
    ['notify.contract_message'] = 'Contract message',
    ['notify.new_message_about_your_contract_on'] = 'New message about your contract on %s. Open it from Mine.',
    ['notify.your_target'] = 'your target',
    ['notify.item'] = '%d item(s)',
    ['notify.payment'] = '%d payment(s)',
    ['notify.you_were_owed_arrived'] = '%s you were owed %s arrived',
    ['notify.has'] = 'has',
    ['notify.have'] = 'have',
    ['notify.more_still_waiting_for_you'] = '; %d more %s still waiting for you.',
    ['notify.is_2'] = 'is',
    ['notify.are_2'] = 'are',
    ['notify.outstanding_item_been_delivered'] = '%d outstanding item%s been delivered.',
    ['notify.has_2'] = ' has',
    ['notify.have_2'] = 's have',
    ['notify.outstanding_payment'] = 'Outstanding payment',
    ['notify.your_stake_went_to_the_person'] = ' Your %s stake went to the person who placed the contract.',
    ['notify.your_stake_could_not_be_confirmed'] = ' Your %s stake could not be confirmed as handed back; staff have been asked to check it.',
    ['notify.your_stake_is_held_for_you'] = ' Your %s stake is held for you and is handed back as soon as you can take it.',
    ['notify.your_stake_has_been_returned'] = ' Your %s stake has been returned.',
    ['notify.and_item'] = '%s and %d item(s)',
    ['notify.payout_recorded'] = 'Payout recorded',
    ['notify.your_payout_on_the_contract_on'] = 'Your payout on the contract on %s was recorded after a fault',
    ['notify.released_to_you'] = ' released to you.',
    ['notify.handover_paid'] = 'Handover paid',
    ['notify.kill_paid'] = 'Kill paid',
    ['notify.delivered_alive'] = 'Delivered alive',
    ['notify.kill_verified'] = 'Kill verified',
    ['notify.your_payout_was_released'] = ': your payout was released.',
    ['notify.payout_held_released_within_minutes'] = ' Payout held: released within %d minutes.',
    ['notify.your_payout_is_held_until_you'] = ' Your payout is held until you show intent: %s. It is released anyway within %d minutes.',
    ['notify.proof_of_intent'] = 'proof of intent',
    ['notify.part_of_it_is_held_for'] = ' Part of it is held for you and is handed over as soon as you can take it.',
    ['notify.part_of_it_is_held_until'] = ' Part of it is held until you make room: make room and it is handed over.',
    ['notify.part_of_it_could_not_be'] = ' Part of it could not be confirmed; staff have been asked to check it.',
    ['notify.the_contract_is_still_running_with'] = ' The contract is still running, with %d more to collect',
    ['notify.you_can_collect_again_in'] = '; you can collect again in %s.',
    ['notify.you_were_paid_for_collection_on'] = ' You were paid for %d collection%s on it.',
    ['notify.contract_expired'] = 'Contract expired',
    ['notify.the_deadline_on_your_contract_on'] = 'The deadline on your contract on %s passed.',
    ['notify.your_contract_on_ran_out_before'] = 'Your contract on %s ran out before it could be finished.',
    ['notify.contract_closed'] = 'Contract closed',
    ['notify.bought_their_way_out_of_your'] = '%s bought their way out of your contract.',
    ['notify.staff_closed_your_contract_on'] = 'Staff closed your contract on %s.',
    ['notify.another_operative_finished_the_contract_on'] = 'Another operative finished the contract on %s.',
    ['notify.contract_called_off'] = 'Contract called off',
    ['notify.the_contract_on_was_called_off'] = 'The contract on %s was called off by agreement.',
    ['notify.of_payouts_were_collected'] = '%d of %d payouts were collected',
    ['notify.thing_could_not_be_confirmed_as'] = ' %d thing(s) could not be confirmed as handed back; staff have been asked to check.',
    ['notify.your_contract_on_was_called_off'] = 'Your contract on %s was called off by agreement. ',
    ['notify.most_of_what_you_put_up'] = 'Most of what you put up is back.',
    ['notify.thing_would_not_fit_and_are'] = ' %d thing(s) would not fit and are waiting for you — they arrive when you next have room.',
    ['notify.everything_you_put_up_has_been'] = 'Everything you put up has been returned.',
    ['notify.nobody_finished_your_contract_on_in'] = 'Nobody finished your contract on %s in time.',
    ['notify.the_rest_of_what_you_put'] = '; the rest of what you put up is coming back:',
    ['notify.what_you_put_up_is_coming'] = ' What you put up is coming back:',
    ['notify.thing_could_not_be_handed_over'] = ' %d thing(s) could not be handed over yet and arrive as soon as you can take them.',
    ['notify.the_rest_of_what_you_put_2'] = '; the rest of what you put up has been returned.',
    ['notify.everything_you_put_up_has_been_2'] = ' Everything you put up has been returned.',
    ['notify.the_operatives_stake_is_yours'] = ' The operative\'s %s stake is yours.',
    ['notify.the_operatives_stakes_in_all_are'] = ' The operatives\' stakes, %s in all, are yours.',
    ['notify.breathing_room'] = 'Breathing room',
    ['notify.a_price_on_your_head_has'] = 'A price on your head has lapsed.',
    ['notify.an_operative_left_your_contract_on'] = 'An operative left your contract on %s.',
    ['notify.their_stake_is_yours'] = ' Their %s stake is yours.',
    ['notify.operative_still_on_it'] = ' %d operative%s still on it.',
    ['notify.it_is_back_on_the_board'] = ' It is back on the board.',
    ['notify.operative_walked_away'] = 'Operative walked away',
    ['notify.minutes'] = '%d minutes',
    ['notify.seconds'] = '%d seconds',
    ['notify.is_buying_their_way_out_of'] = '%s is buying their way out of your contract. It closes in %s unless you finish it first.',
    ['notify.your_target_2'] = 'Your target',
    ['notify.contract_challenged'] = 'Contract challenged',
    ['notify.threat_advisory'] = 'THREAT ADVISORY',
    ['notify.a_contract_has_been_placed_on'] = 'A contract has been placed on %s%s.',
    ['notify.threat_advisory_active'] = 'THREAT ADVISORY — ACTIVE',
    ['notify.the_contract_on_has_been_accepted'] = 'The contract on %s%s has been accepted. %d operative%s active.',
    ['notify.your_department_has_been_advised'] = 'Your department has been advised.',
    ['notify.law_enforcement_has_been_advised'] = 'Law enforcement has been advised.',
    ['notify.a_contract_has_been_placed_on_2'] = 'A contract has been placed on you. ',
    ['notify.the_contract_on_you_has_been'] = 'The contract on you has been accepted. %d operative%s active.',
    ['notify.criminal_intelligence'] = 'Criminal Intelligence',
    ['notify.threat_advisory_tip'] = 'THREAT ADVISORY — TIP',
    ['notify.a_hitman_has_been_tipped_off'] = 'A hitman has been tipped off about %s%s\'s location and is closing in.',
    ['notify.threat_advisory_cancelled'] = 'THREAT ADVISORY — CANCELLED',
    ['notify.the_contract_on_has_been_called'] = 'The contract on %s%s has been called off.',
    ['notify.the_contract_on_you_has_been_2'] = 'The contract on you has been called off.',

    -- =========================================================================
    --        STAFF ALERTS AND THEIR DISCORD POSTS (server/alerts.lua)
    -- =========================================================================
    ['alerts.needs_staff'] = 'Needs staff',
    ['alerts.setting'] = 'Setting',
    ['alerts.test'] = 'Test',
    ['alerts.a_test_alert_from_the_admin'] = 'A test alert from the admin panel: alerts reach this channel.',
    ['alerts.not_shown_here_see_the_admin'] = '(not shown here; see the admin panel)',
    ['alerts.crimson_hitman_alert'] = '**Crimson Hitman** - %d alert(s)',
    ['alerts.alert'] = 'Alert',
    ['alerts.and_more_the_admin_panels_alerts'] = '...and %d more; the admin panel\'s Alerts lists every one',

    -- =========================================================================
    --                   DISCORD POSTS (server/discord.lua)
    -- =========================================================================
    ['discord.a_link'] = '(a link)',

    -- =========================================================================
    --                  STAFF NOTICES (server/announce.lua)
    -- =========================================================================
    ['announce.staff'] = 'Staff',

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

return CrimsonLocales.en
