--- The admin panel's page (/hitmanadmin): opening it, closing it, and
--- carrying its requests to the server.
---
--- The page is this resource's own NUI page (ui_page 'ui/admin.html'),
--- apart from the phone app, which lb-phone draws from ui/index.html in a
--- frame of its own. The client decides nothing here. The page opens only
--- when the server says this player passed the ACE check
--- (crimson-hitman:adminOpen), and every request it makes goes to the
--- server, which checks the ACE again (server/panel.lua). A modified client
--- that opens the page anyway gets refusals and nothing else.

local AdminPanel = {}

--- Whether the page is open, and so holds the focus.
local open = false

--- Requests the page is waiting on, by id: the NUI callback's own answer
--- function, called once.
local pending = {}
local requestSeq = 0

--- How long a request waits for the server before the page is told it timed
--- out, as the phone app's requests do.
local REQUEST_TIMEOUT_MS = 15000

--- How often, and how many times, the focus is asked for again as the page
--- opens: another resource releasing the focus in the same frames (a phone
--- closing, a menu) otherwise leaves the page drawn with no cursor.
local REFOCUS_MS, REFOCUS_TIMES = 50, 5

--- The pause menu, and the key behind it: held off while the page is open,
--- and either one released closes it.
local ESCAPE_CONTROLS = { 200, 322 }

--- And for this long after it closes. Closing gives the game its input back
--- while the key that closed it can still be down, and the watch below
--- ended the frame after: the rest of that keystroke reached the game
--- unguarded, and the pause menu opened as the panel went.
local ESCAPE_GUARD_MS = 400

--- When the trailing guard ends (CrimsonUtil.monotonicMs, which steps past
--- the game timer's wrap), and whether the watch is running, so a second
--- open while it trails starts no second one.
local guardUntil, watching = 0, false

--- Close the page, whichever way it is closed: Escape in the page or in the
--- game, the page's own close button, or this resource stopping. Always
--- gives the focus back, and answers every request still waiting, so no
--- fetch in the page is left hanging.
function AdminPanel.close()
    local was = open
    open = false
    if was then guardUntil = CrimsonUtil.monotonicMs() + ESCAPE_GUARD_MS end
    SetNuiFocus(false, false)
    if was then SendNUIMessage({ type = 'close' }) end
    for rid, answer in pairs(pending) do
        pending[rid] = nil
        pcall(answer, { ok = false, err = 'closed' })
    end
end

--- Open the page with what the server said this player may do.
---@param access table see Panel.open (server/panel.lua)
function AdminPanel.open(access)
    local already = open
    open = true
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'open', access = access })
    CreateThread(function()
        for _ = 1, REFOCUS_TIMES do
            Wait(REFOCUS_MS)
            if not open then return end
            SetNuiFocus(true, true)
        end
    end)
    -- Escape, here as well as in the page: with the focus in the page the
    -- game may still see the key, and the pause menu opening over the
    -- panel is what it does with it. Every frame, only while the page is
    -- open and for ESCAPE_GUARD_MS after it closes; the loop ends then. One
    -- watch however often the server says to open, a trailing one included:
    -- a second would run beside the first.
    if already or watching then return end
    watching = true
    CreateThread(function()
        while open or CrimsonUtil.monotonicMs() < guardUntil do
            for i = 1, #ESCAPE_CONTROLS do DisableControlAction(0, ESCAPE_CONTROLS[i], true) end
            if open then
                for i = 1, #ESCAPE_CONTROLS do
                    if IsDisabledControlJustReleased(0, ESCAPE_CONTROLS[i]) then
                        AdminPanel.close()
                        break
                    end
                end
            end
            Wait(0)
        end
        watching = false
    end)
end

--- Whether the page is open, for the tests.
---@return boolean
function AdminPanel.isOpen()
    return open
end

--------------------------------------------------------------------------
-- From the server
--------------------------------------------------------------------------

RegisterNetEvent('crimson-hitman:adminOpen', function(access)
    -- Type-checked, as every handler in this resource is: an event name is
    -- a server-wide namespace.
    if type(access) ~= 'table' then return end
    AdminPanel.open(access)
end)

RegisterNetEvent('crimson-hitman:adminResult', function(result)
    if type(result) ~= 'table' then return end
    local rid = tonumber(result.rid)
    local answer = rid and pending[rid]
    if not answer then return end
    pending[rid] = nil
    answer({ ok = result.ok == true, err = result.err, message = result.message,
             data = result.data })
end)

--- The most lines one output event is printed for: the server batches a
--- command's answer under about 8 KB, and under this many lines, an event
--- (server/bridges.lua), so a list longer than this is not one it sends.
local OUTPUT_LINES_MAX = CH.OUTPUT_LINES_MAX

--- What a staff command this player ran answers, from the server
--- (Bridges.runCommand): every line printed in their F8 console, in order,
--- never in chat, and the one thing this resource prints to F8 with
--- Config.Debug off. The buyout command answers in chat instead. Lines
--- only: the server sends them as text, already without colour codes.
RegisterNetEvent('crimson-hitman:commandOutput', function(lines)
    if type(lines) ~= 'table' then return end
    for i = 1, math.min(#lines, OUTPUT_LINES_MAX) do
        if type(lines[i]) == 'string' then CrimsonLog.console(lines[i]) end
    end
end)

--- A diagnosis line that had to wait for an answer, for the open page.
RegisterNetEvent('crimson-hitman:adminPush', function(data)
    if not open or type(data) ~= 'table' then return end
    SendNUIMessage({ type = 'push', kind = tostring(data.kind or ''),
                     line = type(data.line) == 'string' and data.line or nil })
end)

--------------------------------------------------------------------------
-- From the page
--------------------------------------------------------------------------

--- One request, { op, data }, sent on to the server and answered with what
--- it says: { ok, err, message, data }. Answered on every path, once.
RegisterNUICallback('adminRequest', function(data, cb)
    local answered = false
    local function answer(value)
        if answered then return end
        answered = true
        cb(value)
    end

    if not open then return answer({ ok = false, err = 'closed' }) end
    local op = type(data) == 'table' and data.op or nil
    if type(op) ~= 'string' or #op == 0 or #op > 32 then
        return answer({ ok = false, err = 'invalid_input' })
    end

    requestSeq = requestSeq + 1
    local rid = requestSeq
    pending[rid] = answer
    SetTimeout(REQUEST_TIMEOUT_MS, function()
        if pending[rid] then
            pending[rid] = nil
            answer({ ok = false, err = 'timeout' })
        end
    end)
    TriggerServerEvent('crimson-hitman:admin', {
        op = op, data = type(data.data) == 'table' and data.data or {}, __rid = rid,
    })
end)

RegisterNUICallback('adminClose', function(_, cb)
    AdminPanel.close()
    cb({ ok = true })
end)

-- A restart with the page open: the focus is this resource's, and nothing
-- else would ever give it back.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    AdminPanel.close()
end)

return AdminPanel
