CrimsonBoot.define('server.handover_confirm', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                crimson-hitman - server/handover_confirm.lua               ║
    ║           The placer's Confirm handover on a live handover (option)       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- With Config.Kidnap.PlacerConfirms on (off as shipped), a live handover
--- that has been held for Config.Kidnap.CountdownSeconds does not pay at
--- once: its placer's card shows Confirm handover (two taps) and Decline for
--- Config.Kidnap.ConfirmSeconds, and the payout is made once they confirm
--- (server/completion/kidnap.lua: Kidnap.awaitConfirm, Kidnap.answer). A
--- decline pays nothing, and so does a window that runs out unless
--- Config.Kidnap.ConfirmMissed is 'pay'; either way the contract stays open
--- and the hitman may arm again after Config.Kidnap.RearmCooldownSeconds.
--- A placer gets Config.Kidnap.MaxDeclines of those per contract (2 as
--- shipped; a window left to run out under 'rearm' counts as one): past
--- that the next handover held for its countdown pays without asking them,
--- so an alive-only contract cannot be held open by declining for ever.
---
--- One request, confirmHandover { id, decline }, answered in server/app.lua
--- through the app's own gate (the source, the job blacklist, the flood
--- guard, the 'accept' bucket). Only the contract's placer is answered anything but
--- not found; nothing names the hitman to them or them to the hitman.

local L = CrimsonBoot.requireShared('locale').t
local HandoverConfirm = {}

--- Start-up check of the three settings (main.lua): each wrong one is the
--- shipped value, said.
---@param warn string[]
function HandoverConfirm.validate(warn)
    local k = Config.Kidnap
    if type(k) ~= 'table' then return end
    if k.PlacerConfirms ~= nil and type(k.PlacerConfirms) ~= 'boolean' then
        warn[#warn + 1] = (L('handover_confirm.config_kidnap_placerconfirms_is_it_has'))
            :format(tostring(k.PlacerConfirms))
        k.PlacerConfirms = false
    end
    local seconds = k.ConfirmSeconds
    if type(seconds) ~= 'number' or seconds ~= seconds or seconds < 10 or seconds > 600
        or seconds ~= math.floor(seconds) then
        warn[#warn + 1] = (L('handover_confirm.config_kidnap_confirmseconds_is_it_has')):format(tostring(seconds))
        k.ConfirmSeconds = 60
    end
    if k.ConfirmMissed ~= 'rearm' and k.ConfirmMissed ~= 'pay' then
        warn[#warn + 1] = (L('handover_confirm.config_kidnap_confirmmissed_is_it_has')):format(tostring(k.ConfirmMissed))
        k.ConfirmMissed = 'rearm'
    end
    local most = k.MaxDeclines
    if most ~= nil and (type(most) ~= 'number' or most ~= most or most < 0 or most > 20
        or most ~= math.floor(most)) then
        warn[#warn + 1] = (L('handover_confirm.config_kidnap_maxdeclines_is_it_has')):format(tostring(most))
        k.MaxDeclines = 2
    end
end

return HandoverConfirm
end)
