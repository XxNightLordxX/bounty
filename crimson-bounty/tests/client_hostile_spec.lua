--- The client half under a runtime that is not behaving.
---
--- The server half has been hardened against exports that are missing or
--- that throw. The client has its own `phone` guard, which is not the same
--- as having been tested: until now the only NUI callback any test had ever
--- invoked was the camera one, no test had ever watched a reply arrive for a
--- request that had already been answered, and every registration test ran
--- against a phone that either always worked or always refused.
---
--- The registration state machine is the part that matters. This app has
--- twice vanished from players' phones on a live server, and the shape of
--- that failure is always the same: something goes wrong for a while, and
--- when it stops going wrong nothing puts the app back. So the phone modelled
--- here is not a call recorder — it tracks whether the app is actually
--- installed, misbehaves for a bounded time, and is then asked to prove that
--- the client converged on the truth: the app is on the phone if and only if
--- the server said this player may have it.

local Client = require('crimson-bounty.tests.harness.client')

--------------------------------------------------------------------------
-- A phone that can be ill
--------------------------------------------------------------------------

--- Replace this build's lb-phone with one that models what is installed.
---
--- The stock harness phone only records that the client called it, which
--- cannot tell "asked to register and was refused" from "registered". The
--- whole question here is what is on the player's home screen at the end, so
--- that has to be a thing the test can read.
---
---@param opts table|nil
---   add        fun(n:number):string  verdict for the nth AddCustomApp:
---                                    'ok' | 'throw' | 'false' | 'nil'
---                                    | 'string' | 'table'
---   removeAs   string|nil            which removal export this build has
---   removeVerdict fun():any|nil      what that export answers
---@return table model { installed, adds, removes }
local function phoneModel(opts)
    opts = opts or {}
    local add = opts.add or function() return 'ok' end
    local model = { installed = false, adds = 0, removes = 0 }

    Client.exports.AddCustomApp = function(_, spec)
        model.adds = model.adds + 1
        table.insert(Client.phone, { call = 'AddCustomApp', spec = spec })

        local verdict = add(model.adds)
        -- A phone that throws, refuses, or answers nothing has not
        -- installed anything, and the model must not pretend otherwise:
        -- a test whose phone lies cannot measure whether the client
        -- converged on the truth.
        if verdict == 'throw' then error('lb-phone is still starting up', 0) end
        if verdict == 'false' then return false end
        if verdict == 'nil' then return nil end

        model.installed = true
        -- Builds have been seen to answer with the app record rather than a
        -- boolean. Anything that is not a refusal is a success.
        if verdict == 'string' then return 'crimson-bounty' end
        if verdict == 'table' then return { identifier = 'crimson-bounty' } end
        return true
    end

    -- The removal export's name has moved across lb-phone releases, so which
    -- one this build has is part of what is being modelled.
    Client.exports.RemoveCustomApp = nil
    local name = opts.removeAs
    if name ~= false then
        name = name or 'RemoveCustomApp'
        Client.exports[name] = function(_, identifier)
            model.removes = model.removes + 1
            table.insert(Client.phone, { call = name, app = identifier })
            local answer = opts.removeVerdict and opts.removeVerdict()
            if answer == false then return false end   -- refused: still installed
            model.installed = false
            if answer ~= nil then return answer end
            return true
        end
    end

    return model
end

--- A booted client on a phone that has finished starting.
---
--- lb-phone reporting 'started' matters to more than realism: the
--- registration thread waits on that state in a loop, and the harness's Wait
--- does not advance anything, so a reconcile driven while lb-phone is
--- stopped never returns.
local function ready(bootOpts)
    Env.reset()
    Client.boot(bootOpts)
    Natives.resourceStates = { ['lb-phone'] = 'started' }
end

--- One pass of the client's heartbeat. In the resource this runs every
--- fifteen seconds forever; here it is the thing a test drives.
local function heartbeats(n)
    for _ = 1, n do Client.reconcile() end
end

local function console()
    return table.concat(Client.console, ' | ')
end

--------------------------------------------------------------------------
-- Registration: converging on the truth
--------------------------------------------------------------------------

describe('a phone that is not ready when the client is', function()
    --- lb-phone finishes its own setup on its own schedule, and on a busy
    --- server it can lose that race by more than the client's ten attempts.
    --- What happens after those ten attempts is the whole question: the
    --- player is allowed the app and does not have it, and if nothing tries
    --- again they will not have it for the rest of the session.

    it('gives the player the app once lb-phone stops throwing', function()
        ready()
        local ill = true
        local model = phoneModel({ add = function() return ill and 'throw' or 'ok' end })

        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        falsy(model.installed, 'a phone that throws cannot have installed anything')
        truthy(model.adds > 1, 'and the client must have kept trying: ' .. model.adds)

        -- lb-phone finishes starting. Nothing tells the client so: the
        -- server's answer has not changed, no resource restarted, no event
        -- is coming. The heartbeat is the only thing left.
        ill = false
        heartbeats(2)

        truthy(model.installed,
            'the app never came back after lb-phone recovered, which is the '
            .. 'state this resource has twice been in on a live server: '
            .. console())
    end)

    it('gives the player the app once lb-phone stops refusing', function()
        -- Refusal rather than a throw: the export is there, answers false,
        -- and keeps answering false for longer than one round of retries.
        ready()
        local refuseUntil = 25
        local model = phoneModel({
            add = function(n) return n <= refuseUntil and 'false' or 'ok' end,
        })
        Client.fire('crimson-bounty:access', true)

        -- Each pass is one round of the client's retries. The first two
        -- cannot get past the refusals; by the third the phone is well.
        heartbeats(2)
        falsy(model.installed, 'nothing should be installed while it refuses')
        heartbeats(2)

        truthy(model.installed,
            'a refusal that outlasts one round of retries must not be final: '
            .. model.adds .. ' attempts, ' .. console())
    end)

    it('takes an answer that is not a boolean as a yes', function()
        -- Some builds answer with the app record rather than true. Treating
        -- that as a refusal would leave the client re-adding an app that is
        -- already on the phone for the rest of the session.
        for _, shape in ipairs({ 'string', 'table' }) do
            ready()
            local model = phoneModel({ add = function() return shape end })
            Client.fire('crimson-bounty:access', true)
            heartbeats(3)

            truthy(model.installed, shape .. ': the app must be installed')
            eq(model.adds, 1,
                shape .. ': a success answered with ' .. shape .. ' was read as a '
                .. 'refusal, so the client kept re-adding an app that was '
                .. 'already there')
        end
    end)

    it('does not throw when lb-phone itself is hostile', function()
        -- Not a missing export: an export table that raises on every index,
        -- which is what indexing an escrowed resource that failed to start
        -- has looked like.
        ready()
        Client.exports = setmetatable({}, {
            __index = function() error('lb-phone: resource not started', 0) end,
        })

        Client.fire('crimson-bounty:access', true)
        Client.runThreads()

        -- The harness stops the client's two forever-loops — the heartbeat
        -- and the still-unanswered whoAmI — by refusing to Wait any more, so
        -- that one message is expected and is not the client throwing.
        local threw = {}
        for _, err in ipairs(Client.threadErrors) do
            if not err:find('loop that does not end', 1, true) then
                threw[#threw + 1] = err
            end
        end
        eq(#threw, 0,
            'registration must not throw out of its own thread: '
            .. table.concat(threw, ' | '))
        truthy(Client.said('AddCustomApp'),
            'and the operator must be told which call failed: ' .. console())

        -- Every other entry point runs through the same guard.
        truthy(Client.fire('crimson-bounty:push', { reason = 'x' }), 'push threw')
        truthy(Client.fire('crimson-bounty:notify', { title = 't', content = 'c' }), 'notify threw')
        truthy(Client.fire('crimson-bounty:result', { rid = 99, ok = true }), 'result threw')
    end)
end)

describe('the app coming and going', function()
    --- Registering and unregistering repeatedly is the ordinary life of a
    --- player who goes on and off duty. The end state has to match the last
    --- answer, whatever happened on the way there.

    it('ends with the app on the phone when the last word is yes', function()
        ready()
        local model = phoneModel()
        for i = 1, 8 do
            Client.fire('crimson-bounty:access', i % 2 == 0)
            heartbeats(1)
        end
        Client.fire('crimson-bounty:access', true)
        heartbeats(2)
        truthy(model.installed,
            'eight changes of job left an allowed player with no app: '
            .. model.adds .. ' adds, ' .. model.removes .. ' removes')
    end)

    it('ends with the app off the phone when the last word is no', function()
        ready()
        local model = phoneModel()
        for i = 1, 8 do
            Client.fire('crimson-bounty:access', i % 2 == 0)
            heartbeats(1)
        end
        Client.fire('crimson-bounty:access', false)
        heartbeats(2)
        falsy(model.installed,
            'a sworn officer was left holding the app: ' .. model.adds
            .. ' adds, ' .. model.removes .. ' removes')
    end)

    it('does not add the app again on every heartbeat', function()
        ready()
        local model = phoneModel()
        Client.fire('crimson-bounty:access', true)
        heartbeats(20)
        eq(model.adds, 1,
            'the heartbeat re-registered an app that was already installed, '
            .. 'which on a real phone is twenty icons')
    end)

    it('puts it back exactly once each time lb-phone restarts', function()
        ready()
        local model = phoneModel()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        truthy(model.installed)

        for restart = 1, 5 do
            -- A restart drops every custom app lb-phone was holding.
            model.installed = false
            Client.fire('onClientResourceStart', 'lb-phone')
            Client.runThreads()
            truthy(model.installed,
                ('the app was not put back after restart %d'):format(restart))
        end
        eq(model.adds, 6, 'one registration per restart, got ' .. model.adds)
    end)

    it('finds the removal export under whichever name this build has', function()
        -- The stock harness only ever offers RemoveCustomApp. A build that
        -- has only one of the later names must still be able to take the app
        -- off a player who has just gone on duty.
        for _, name in ipairs({ 'RemoveCustomApp', 'DeleteCustomApp', 'UninstallApp' }) do
            ready()
            local model = phoneModel({ removeAs = name })
            Client.fire('crimson-bounty:access', true)
            heartbeats(1)
            truthy(model.installed, name .. ': not installed to begin with')

            Client.fire('crimson-bounty:access', false)
            heartbeats(1)
            falsy(model.installed,
                'a build whose removal export is called ' .. name
                .. ' left the app on a barred player: ' .. console())
        end
    end)

    it('keeps the app and says so when no removal export exists', function()
        ready()
        local model = phoneModel({ removeAs = false })
        Client.fire('crimson-bounty:access', true)
        heartbeats(1)

        Client.fire('crimson-bounty:access', false)
        heartbeats(3)
        truthy(model.installed, 'nothing could have removed it')
        truthy(Client.said('no export for removing'),
            'an icon that cannot be removed has to be said out loud, or the '
            .. 'operator is left with a bug report and no cause: ' .. console())

        -- And the client must still know it is there. Believing it was
        -- removed would add a second copy the moment the player comes off
        -- that job.
        Client.fire('crimson-bounty:access', true)
        heartbeats(2)
        eq(model.adds, 1,
            'the app was added again on top of the one that was never removed')
    end)
end)

--------------------------------------------------------------------------
-- Server round trips
--------------------------------------------------------------------------

--- Invoke one of the page's NUI callbacks with a callback of our own, so
--- each request's answers can be counted separately.
---
--- Client.nuiCall keeps one answer at a time, which cannot see a reply being
--- delivered into the wrong request or a request being answered twice after
--- something else has been answered since.
local function press(name, payload)
    local handler = Client.nui['crimson:' .. name]
    truthy(handler, 'no NUI callback named crimson:' .. name)

    local record = { answers = {} }
    -- Nothing here reaches lb-phone: the callback stamps the request and
    -- hands it to the server, and the reply arrives later through the result
    -- event, which is fired with the phone in place.
    local ok, err = pcall(handler, payload or {}, function(value)
        table.insert(record.answers, value)
    end)
    truthy(ok, 'the NUI callback threw: ' .. tostring(err))

    local sent = Client.toServer[#Client.toServer]
    truthy(sent, 'the callback asked the server for nothing')
    record.event = sent.name
    record.rid = sent.args[1] and sent.args[1].__rid
    truthy(record.rid, 'the request must carry an id of its own')
    return record
end

local function reply(rid, event, data)
    return Client.fire('crimson-bounty:result',
        { rid = rid, event = event, ok = true, data = data or {} })
end

describe('replies arriving in a runtime that does not keep order', function()
    it('answers each request into its own callback', function()
        -- Two searches in flight at once, answered in the other order. If
        -- the correlation is wrong the player sees the results of the search
        -- they have already moved on from.
        ready()
        local first  = press('searchTargets', { query = 'a' })
        local second = press('browseTargets', { page = 2 })
        truthy(first.rid ~= second.rid, 'two requests must not share an id')

        reply(second.rid, 'browseTargets', { which = 'second' })
        eq(#first.answers, 0, 'the first request was answered by the second reply')
        eq(#second.answers, 1)
        eq(second.answers[1].data.which, 'second')

        reply(first.rid, 'searchTargets', { which = 'first' })
        eq(#first.answers, 1)
        eq(first.answers[1].data.which, 'first')
        eq(#second.answers, 1, 'the second request was answered twice')
    end)

    it('answers the page once when a reply arrives twice', function()
        ready()
        local req = press('list', { page = 1 })
        reply(req.rid, 'list')
        truthy(Client.fire('crimson-bounty:result',
            { rid = req.rid, event = 'list', ok = true, data = {} }),
            'a duplicate reply must not throw out of the net event')
        eq(#req.answers, 1,
            'the page callback was resolved ' .. #req.answers .. ' times; '
            .. 'resolving an NUI callback twice throws inside the browser the '
            .. 'phone is drawn in, which looks like the phone crashing')
    end)

    it('does not answer again when a reply beats its own timeout home', function()
        ready()
        local req = press('mine', {})

        -- Nothing came back in fifteen seconds, so the page is told so.
        Client.runTimeouts()
        eq(#req.answers, 1, 'a request that is never answered must not hang the page')
        eq(req.answers[1].err, 'timeout')

        -- And then the server answers after all.
        reply(req.rid, 'mine')
        eq(#req.answers, 1,
            'a late reply resolved a callback that had already been answered')
    end)

    it('leaves nothing waiting once every request is done with', function()
        -- The outstanding-request map is the one place in the client that can
        -- grow without bound, and a stale entry in it is a callback belonging
        -- to a screen the player has left.
        ready()
        local requests = {}
        for i = 1, 6 do requests[i] = press('list', { page = i }) end

        for i = 1, 3 do reply(requests[i].rid, 'list') end
        Client.runTimeouts()

        -- Everything is now answered, one way or the other. Replay every
        -- reply, twice: if any entry survived, a callback fires again.
        for _ = 1, 2 do
            for i = 1, 6 do reply(requests[i].rid, 'list') end
        end
        for i = 1, 6 do
            eq(#requests[i].answers, 1,
                ('request %d was answered %d times'):format(i, #requests[i].answers))
        end
    end)

    it('still tells the app about a reply nobody is waiting for', function()
        -- A reply whose request has already timed out, or a push the server
        -- sends unprompted. The page renders on these, so losing them is a
        -- screen that never updates.
        ready()
        truthy(Client.fire('crimson-bounty:result',
            { rid = 4242, event = 'list', ok = true, data = {} }),
            'an unknown request id must not throw')

        local sent
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' then sent = call.message end
        end
        truthy(sent, 'the page must still be told: ' .. console())
        eq(sent.type, 'result')
        eq(sent.event, 'list')
    end)

    it('gives every action on the page a route to the server', function()
        -- The page posts to these names. One that is not registered is a
        -- button that does nothing, and nothing else in the suite has ever
        -- invoked one of them.
        ready()
        local names = {
            'list', 'mine', 'ledger', 'searchTargets', 'browseTargets',
            'rewardOptions', 'create', 'accept', 'abandon', 'cancel', 'revise',
            'requestPhotoToken', 'armKidnap', 'kidnapProgress', 'bailout',
            'informant', 'addEscrow', 'rewardBreakdown', 'withdrawReward',
            'improve', 'propose', 'respondAmendment', 'amendments',
            'threads', 'readThread', 'sendMessage', 'requestCall',
        }
        local seen = {}
        for _, name in ipairs(names) do
            local req = press(name, {})
            eq(req.event, 'crimson-bounty:' .. name)
            falsy(seen[req.rid], 'two actions shared request id ' .. tostring(req.rid))
            seen[req.rid] = true
        end
    end)
end)

--------------------------------------------------------------------------
-- Payloads of the wrong type
--------------------------------------------------------------------------

describe('a runtime that hands the client the wrong type', function()
    --- Net event names are a server-wide namespace and NUI callbacks are
    --- addressable by resource name, so neither payload is only ever the one
    --- this resource's own code sends. Both of these are called from inside a
    --- handler that owes somebody an answer.

    it('does not take a non-boolean access answer for a yes', function()
        for _, answer in ipairs({ 'true', 1, {} }) do
            ready()
            local model = phoneModel()
            truthy(Client.fire('crimson-bounty:access', answer),
                'an access answer of type ' .. type(answer) .. ' threw')
            heartbeats(2)
            falsy(model.installed,
                'a ' .. type(answer) .. ' was read as permission to install the app')
        end
    end)

    it('survives a result that is not a table', function()
        ready()
        for _, payload in ipairs({ 42, true, 'result' }) do
            local ok, err = Client.fire('crimson-bounty:result', payload)
            truthy(ok, ('a %s payload threw out of the result handler: %s')
                :format(type(payload), tostring(err)))
        end
        local ok, err = Client.fire('crimson-bounty:result', nil)
        truthy(ok, 'an empty result threw out of the handler: ' .. tostring(err))
    end)

    it('answers the page when an action is posted with something odd', function()
        -- The callback owes the page a reply. Throwing before it has even
        -- asked the server leaves the button dead for the rest of the
        -- session: there is no request, so there is no timeout to save it.
        for _, payload in ipairs({ 42, true, 'list' }) do
            ready()
            local answers = {}
            local handler = Client.nui['crimson:list']
            local ok, err = pcall(handler, payload, function(v) table.insert(answers, v) end)
            truthy(ok, ('a %s payload threw out of the NUI callback: %s')
                :format(type(payload), tostring(err)))
        end
    end)
end)
