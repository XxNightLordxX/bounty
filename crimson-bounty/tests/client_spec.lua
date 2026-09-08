--- The client, actually running.
---
--- Two hundred lines between the UI and the server that no test had ever
--- executed. Everything here is a build of lb-phone that is not quite the
--- one the code was written against — which is the normal case, since
--- lb-phone ships its server code escrowed and its export surface has moved
--- across releases.

local Client = require('crimson-bounty.tests.harness.client')

describe('the client on an ordinary phone', function()
    it('registers the app', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        -- A barred job never gets the app, so nothing registers until the
        -- server has said this player may have it.
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()

        local registered
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then registered = call.spec end
        end
        truthy(registered, 'the app must be registered with lb-phone')
        eq(registered.identifier, 'crimson-bounty')
        truthy(registered.ui:find('ui/index.html', 1, true), 'and point at the page')

        -- The build stamp is the only thing that makes an update reach a
        -- player who has opened the app before: CEF caches the page and its
        -- app.js on its own disk, keyed by URL, and this URL was a constant
        -- for the life of the resource. Every fix shipped to the page went
        -- to nobody who had already used it.
        truthy(registered.ui:find('?v=', 1, true),
            'the page URL must carry a build, or CEF serves the copy the '
            .. 'player already has forever: ' .. registered.ui)

        -- And the build has to be the manifest's, not a placeholder: a stamp
        -- that never changes caches exactly as badly as no stamp at all.
        local manifest = io.open('crimson-bounty/fxmanifest.lua', 'r')
        local version = manifest and manifest:read('*a'):match("version%s+'([^']+)'")
        if manifest then manifest:close() end
        truthy(version, 'fxmanifest.lua must carry a version to stamp with')
        truthy(registered.ui:find(version, 1, true),
            ('the page URL must carry the manifest version (%s): %s')
                :format(tostring(version), registered.ui))
    end)

    it('still registers when the version cannot be read', function()
        -- The build is read while the registration payload is being built,
        -- inside a pcall whose failure is reported as "lb-phone rejected the
        -- app". A native that throws would take the app off the phone
        -- entirely and blame lb-phone for it.
        Env.reset()
        local real = _G.GetResourceMetadata
        _G.GetResourceMetadata = function() error('no such native on this build') end

        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        -- A barred job never gets the app, so nothing registers until the
        -- server has said this player may have it.
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        _G.GetResourceMetadata = real

        local registered
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then registered = call.spec end
        end
        truthy(registered,
            'a missing version native must not cost the player the whole app')
        truthy(registered.ui:find('?v=', 1, true),
            'and it must still bust the cache rather than silently stop: '
            .. tostring(registered.ui))
    end)

    it('forwards a push to the app', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire('crimson-bounty:push', { reason = 'contract_taken' }))

        local sent
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' then sent = call.message end
        end
        truthy(sent, 'the page must be told')
        eq(sent.type, 'push')
        eq(sent.reason, 'contract_taken')
    end)

    it('raises a notification', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire('crimson-bounty:notify', { title = 'Paid', content = '5000' }))

        local sent
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendNotification' then sent = call.data end
        end
        truthy(sent)
        eq(sent.title, 'Paid')
        eq(sent.app, 'crimson-bounty')
    end)
end)

describe('the client on a phone missing an export', function()
    it('does not lose the notify handler', function()
        Env.reset()
        Client.boot({ without = { 'SendNotification' } })

        local ok = Client.fire('crimson-bounty:notify', { title = 'Paid', content = '5000' })
        truthy(ok, 'a build without the export must not throw out of the handler')
        truthy(Client.said('SendNotification'),
            'and it must say which export is missing: ' .. table.concat(Client.console, ' | '))
    end)

    it('does not lose the push handler', function()
        Env.reset()
        Client.boot({ without = { 'SendCustomAppMessage' } })
        truthy(Client.fire('crimson-bounty:push', { reason = 'x' }),
            'a push into a build without the export must not throw')
    end)

    it('still answers the page when the camera cannot be opened', function()
        -- The worst of them: the UI is waiting on this callback. A throw
        -- here left the player looking at a button that does nothing, with
        -- no error and no way to try again.
        Env.reset()
        Client.boot({ without = { 'SetCameraComponent' } })

        -- Pressing the button asks the server for a token first.
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        falsy(Client.answered, 'nothing to say until the token comes back')

        local asked = Client.toServer[#Client.toServer]
        truthy(asked, 'the client must have asked the server for a token')
        eq(asked.name, 'crimson-bounty:requestPhotoToken')
        local rid = asked.args[1] and asked.args[1].__rid
        truthy(rid, 'and stamped the request with its own id')

        -- The token arrives, and the camera is what fails.
        truthy(Client.fire('crimson-bounty:result', {
            rid = rid, event = 'requestPhotoToken', ok = true, data = { token = 'tok' },
        }), 'the result handler must not throw')

        truthy(Client.answered,
            'the page must be answered even when the camera export is missing')
        falsy(Client.answer.ok)
        eq(Client.answer.err, 'camera_unavailable')
    end)

    it('opens the camera and answers on an ordinary phone', function()
        Env.reset()
        Client.boot()

        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid
        Client.fire('crimson-bounty:result', {
            rid = rid, event = 'requestPhotoToken', ok = true, data = { token = 'tok' },
        })

        truthy(Client.cameraCallback, 'the camera must have been opened')
        falsy(Client.answered, 'and the page waits while the player composes the shot')

        -- The player backs out.
        Client.cameraCallback(nil)
        truthy(Client.answered, 'cancelling must still answer the page')
        eq(Client.answer.err, 'cancelled')
    end)
end)

--- Everything that reaches the client from outside it.
---
--- Two ways in and both took whatever they were given. The NUI endpoints
--- are addressable by resource name from any frame the phone draws, and net
--- event names are a server-wide namespace that every other resource on the
--- box shares — so "our own server always sends a table" is a statement
--- about one of the two senders.
describe('the client handed something it did not expect', function()
    it('answers the page when an action is posted with something odd', function()
        Env.reset()
        Client.boot()

        -- Every one of the generic callbacks goes through App.request, so
        -- one of them standing for all of them is enough — and `list` is the
        -- one the page posts on every open.
        for _, odd in ipairs({ 42, true, 'ct00000001' }) do
            local answered, err = Client.nuiCall('crimson:list', odd)
            truthy(answered ~= nil,
                ('a %s body must not throw out of the callback: %s')
                    :format(type(odd), tostring(err)))

            local asked = Client.toServer[#Client.toServer]
            truthy(asked, 'and the server must still have been asked')
            eq(asked.name, 'crimson-bounty:list')
            truthy(asked.args[1] and asked.args[1].__rid,
                'with a request id on it, or nothing can ever answer it')
        end
    end)

    it('keeps the request answerable after an odd body', function()
        -- The consequence is not the throw, it is what the throw skipped:
        -- nothing was pending, so the 15s timeout had no request to rescue
        -- and the page's promise never settled. The button stays dead for
        -- the rest of the session.
        Env.reset()
        Client.boot()

        Client.nuiCall('crimson:list', 42)
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid
        truthy(rid)

        truthy(Client.fire('crimson-bounty:result', {
            rid = rid, event = 'list', ok = true, data = { contracts = {} },
        }), 'the result handler must not throw')
        truthy(Client.answered, 'and the page must be answered')
        truthy(Client.answer and Client.answer.ok)
    end)

    it('survives a result that is not a table', function()
        Env.reset()
        Client.boot()

        for _, odd in ipairs({ 42, true }) do
            truthy(Client.fire('crimson-bounty:result', odd),
                ('a %s result must not throw out of the handler'):format(type(odd)))
        end
        truthy(Client.fire('crimson-bounty:result'),
            'nor must a result that is missing entirely')
    end)

    it('still delivers a real result after a malformed one', function()
        -- The handler forwards every reply to the open app as well as
        -- resolving the request that asked. A throw skipped both, so the
        -- app was told nothing either.
        Env.reset()
        Client.boot()

        Client.nuiCall('crimson:mine', {})
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid

        truthy(Client.fire('crimson-bounty:result', 42),
            'a malformed reply must not throw out of the handler')
        falsy(Client.answered, 'a malformed reply answers nobody')

        Client.fire('crimson-bounty:result', {
            rid = rid, event = 'mine', ok = true, data = { created = {} },
        })
        truthy(Client.answered, 'and the real reply still lands')

        local forwarded
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' then forwarded = call end
        end
        truthy(forwarded, 'and the open app is told about it')
    end)
end)

describe('the camera, on a phone that dies mid-upload', function()
    --- Reported from a live server: the photo route says "uploading" and then
    --- the phone crashes. Everything here is a way this resource could be the
    --- one taking it down.

    local function tokenIssued(app)
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid
        Client.fire('crimson-bounty:result', {
            rid = rid, event = 'requestPhotoToken', ok = true, data = { token = 'tok' },
        })
    end

    it('answers the page exactly once, however often the camera calls back', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        truthy(Client.cameraCallback, 'the camera must have opened')

        -- lb-phone has been seen to invoke a camera callback more than once.
        -- Resolving an NUI callback twice throws inside the browser the phone
        -- is drawn in, which reads as the phone crashing rather than as a
        -- bug here.
        Client.cameraCallback(nil)
        Client.cameraCallback(nil)
        Client.cameraCallback('https://example.com/a.png')

        eq(Client.answerCount, 1,
            'the page was answered more than once, which is what crashes it')
    end)

    it('does not let a throw of its own reach the camera', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()

        -- Whatever goes wrong inside the callback, it runs inside lb-phone's
        -- camera: a throw there does not stay there, it goes back into the
        -- camera and takes the phone with it.
        local realTrigger = _G.TriggerServerEvent
        _G.TriggerServerEvent = function() error('submission blew up') end
        local ok = pcall(Client.cameraCallback, 'https://example.com/a.png')
        _G.TriggerServerEvent = realTrigger

        truthy(ok, 'a throw escaped into the camera')
        truthy(Client.answered, 'and the page must still be answered')
    end)

    it('answers eventually when the camera never calls back at all', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()

        falsy(Client.answered, 'the page waits while the player composes the shot')

        -- The server round trip has a timeout; a player standing in front of
        -- an open camera does not. Without one the page waits forever.
        Client.runTimeouts()
        truthy(Client.answered,
            'a camera that never calls back left the page waiting for good')
    end)

    it('takes its camera override back off the phone when it is done', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        truthy(Client.camera('https://example.com/a.png'))

        local resets = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'SetCameraComponent' and call.spec == nil then
                resets = resets + 1
            end
        end
        truthy(resets > 0,
            'the override stays installed, so every later use of the phone camera '
            .. 'runs through a component configured for one photograph of a body, '
            .. 'callback included')
    end)

    it('does not upload the shot to the players own gallery by default', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()

        local spec
        for _, call in ipairs(Client.phone) do
            if call.call == 'SetCameraComponent' then spec = call.spec end
        end
        truthy(spec, 'the camera should have been configured')
        falsy(spec.saveToGallery,
            'a second upload of the same image, inside the operation that '
            .. 'already uploads it, and a photograph of a body left in the '
            .. 'hunters gallery')
    end)
end)

describe('a job that is barred from the app', function()
    --- The gate already refuses every request from a barred job, but the app
    --- was still installed and opened for them: it answered nothing, which
    --- reads as broken rather than as not for them. An officer should not be
    --- looking at a bounty board at all.

    local function ready()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
    end

    local function registrations()
        local n = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then n = n + 1 end
        end
        return n
    end

    it('does not put the app on the phone before the server has said', function()
        ready()
        Client.runThreads()
        eq(registrations(), 0,
            'unknown is not yes: a player is not handed the app on a job '
            .. 'nobody has read yet')
    end)

    it('never registers it for a player the server bars', function()
        ready()
        Client.fire('crimson-bounty:access', false)
        Client.runThreads()
        eq(registrations(), 0, 'a barred job was given the app anyway')
    end)

    it('registers it once the server says they may have it', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        eq(registrations(), 1, 'an allowed player must get the app')
    end)

    it('takes it back when they go on duty mid-session', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        eq(registrations(), 1)

        -- They take a barred job. Refusing to register it next time is not
        -- enough: it is already on their phone.
        Client.fire('crimson-bounty:access', false)
        Client.runThreads()

        local removed = false
        for _, call in ipairs(Client.phone) do
            if call.call == 'RemoveCustomApp' or call.call == 'DeleteCustomApp'
                or call.call == 'UninstallApp' then
                removed = true
            end
        end
        truthy(removed,
            'the app has to come off the phone, not merely stop being added: '
            .. table.concat(Client.console, ' | '))
    end)

    it('gives it back when they come off that job', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        Client.fire('crimson-bounty:access', false)
        Client.runThreads()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()

        truthy(registrations() >= 2,
            'a player who leaves the barred job must get the app back without '
            .. 'reconnecting, got ' .. registrations() .. ' registrations')
    end)

    it('does not churn the phone when the answer has not changed', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        for _ = 1, 5 do Client.fire('crimson-bounty:access', true) end
        Client.runThreads()
        eq(registrations(), 1,
            'the same answer repeated must not re-register the app each time')
    end)

    --- Acting on the transition — register when the answer turns true,
    --- remove when it turns false — read well and was wrong. Every way of
    --- missing that moment ended in the same state, and it is the worst one:
    --- no app, and nothing coming that will put it back. It stranded a live
    --- server twice. These are the ways it got stuck.
    it('puts the app back when it went missing while the answer stayed the same', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        eq(registrations(), 1)

        -- lb-phone dropped it, or a removal half worked, or our own resource
        -- restarted. Nothing changes on the server, so no event is coming.
        -- lb-phone dropped it. Nothing changes on the server, so no event
        -- is coming: only a pass that compares the two states can notice.
        Client.appGone()
        Client.reconcile()

        truthy(registrations() >= 2,
            'the app stayed missing because the answer had not changed: '
            .. registrations() .. ' registrations')
    end)

    it('re-registers on its own heartbeat, with no event at all', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()

        -- Whatever took it off the phone, nothing is going to say so, and
        -- the server's answer never changes. The heartbeat is the only
        -- thing left that can put it right.
        Client.appGone()
        Client.reconcile()

        truthy(registrations() >= 2,
            'a player who lost the app has to get it back without an event '
            .. 'arriving at the right moment')
    end)

    it('does not register anything while the answer is still unknown', function()
        ready()
        -- The heartbeat runs whether or not the server has answered. It must
        -- not take silence for a yes.
        Client.reconcile()
        Client.reconcile()
        eq(registrations(), 0, 'silence was taken for permission')
    end)

    --- The client obeys the answer; it does not make it.
    ---
    --- This used to toggle Config.HideAppFromBlockedJobs here, which the
    --- client never reads — the setting is the server's, and the client is
    --- told a yes or a no. Worse, it fired the yes, which registers the app
    --- with the setting either way, so the toggle it was named for changed
    --- nothing about what it measured. The setting is tested where it is
    --- actually read, below.
    it('registers the app when it is told yes', function()
        ready()
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()
        eq(registrations(), 1)
        -- The no is covered above, by the test that watches the app come
        -- off the phone rather than merely stop being added.
    end)


    it('asks the server when it has not been told', function()
        ready()
        Client.runThreads()

        local asked = false
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-bounty:whoAmI' then asked = true end
        end
        truthy(asked,
            'a client that started after the join push would otherwise wait '
            .. 'for an event that has already been and gone')
    end)
end)

describe('app registration that does not take the first time', function()
    it('retries until lb-phone accepts', function()
        Env.reset()
        Client.boot({ refuseRegistration = true })
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-bounty:access', true)

        -- The first pass refuses throughout: ten attempts, no app.
        Client.runThreads()

        local attempts = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then attempts = attempts + 1 end
        end
        truthy(attempts > 1,
            'a refusal must be retried, not accepted as final — got ' .. attempts)
        truthy(Client.said('will not appear'),
            'and give up loudly: ' .. table.concat(Client.console, ' | '))
    end)

    it('survives a build with no AddCustomApp at all', function()
        Env.reset()
        Client.boot({ without = { 'AddCustomApp' } })
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-bounty:access', true)

        local ran = Client.runThreads()
        truthy(ran > 0, 'the registration thread must have run')
        truthy(Client.said('AddCustomApp'),
            'a missing export must be named, not swallowed: '
            .. table.concat(Client.console, ' | '))
    end)

    it('registers again when lb-phone restarts', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        -- A barred job never gets the app, so nothing registers until the
        -- server has said this player may have it.
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()

        local before = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then before = before + 1 end
        end
        eq(before, 1, 'registered once')

        -- lb-phone restarting drops every custom app it was holding.
        truthy(Client.handlers['onClientResourceStart'],
            'the client must be listening for lb-phone coming back')
        Client.fire('onClientResourceStart', 'lb-phone')
        Client.runThreads()

        local after = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then after = after + 1 end
        end
        eq(after, 2, 'and register again, or the app is gone until a server restart')
    end)

    it('ignores some other resource restarting', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        -- A barred job never gets the app, so nothing registers until the
        -- server has said this player may have it.
        Client.fire('crimson-bounty:access', true)
        Client.runThreads()

        Client.fire('onClientResourceStart', 'some-other-resource')
        Client.runThreads()

        local calls = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then calls = calls + 1 end
        end
        eq(calls, 1, 'only lb-phone coming back means anything here')
    end)
end)

--- Who the server tells the client they are.
---
--- The decision belongs on the server: the job blacklist is its config, and
--- a client that could answer this for itself could grant itself the app.
describe('the servers own access decision', function()
    local function wired()
        local s = newStack()
        s.app.init(s)
        require('crimson-bounty.server.bridges').install(s)
        return s
    end

    --- What the server last told this player.
    local function toldOf(src)
        local answer
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:access' and event.target == src then
                answer = event.args[1]
            end
        end
        return answer
    end

    it('tells an ordinary player they may have the app', function()
        local s = wired()
        fixture(s)
        Env.clientEvents = {}

        _G.source = 1
        Env.events['crimson-bounty:whoAmI']({})
        _G.source = nil

        eq(toldOf(1), true, 'an unemployed citizen must be allowed')
    end)

    it('tells a barred job they may have it when hiding is switched off', function()
        local s = wired()
        fixture(s)
        Env.addPlayer({ source = 21, citizenid = 'OFFICER3', license = 'license:o3',
            firstname = 'Off', lastname = 'Switch',
            job = { name = 'police', type = 'leo', onduty = true } })

        local was = Config.HideAppFromBlockedJobs
        Config.HideAppFromBlockedJobs = false
        Env.clientEvents = {}
        _G.source = 21
        Env.events['crimson-bounty:whoAmI']({})
        _G.source = nil
        Config.HideAppFromBlockedJobs = was

        eq(toldOf(21), true,
            'the switch must stop the hiding, not merely soften it')

        -- And it grants nothing: the gate refuses them exactly as before.
        local blocked, err = s.identity.gate(21)
        falsy(blocked, 'the switch must not become a way past the gate')
        eq(err, CB.ERR.BLACKLISTED_JOB)
    end)

    it('tells a barred job they may not', function()
        local s = wired()
        fixture(s)
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o',
            firstname = 'Ann', lastname = 'Ryder',
            job = { name = 'police', type = 'leo', onduty = true } })
        Env.clientEvents = {}

        _G.source = 20
        Env.events['crimson-bounty:whoAmI']({})
        _G.source = nil

        eq(toldOf(20), false,
            'a barred job must not be handed the app: the gate refuses their '
            .. 'every request, so what they get is an app that answers nothing')
    end)

    --- The event-free path. A job-change event name that is wrong fails
    --- silently in the direction that costs a player the app and gives them
    --- no way to ask for it back, so the answer is recomputed on the
    --- ordinary tick and does not depend on any framework event.
    it('gives the app back when a player leaves the barred job', function()
        local s = wired()
        fixture(s)
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o',
            firstname = 'Ann', lastname = 'Ryder',
            job = { name = 'police', type = 'leo', onduty = true } })

        local bridges = require('crimson-bounty.server.bridges')

        Env.clientEvents = {}
        bridges.refreshAccess()
        eq(toldOf(20), false, 'on duty, they must not have it')

        -- They go off the job. No event fires; the sweep is what notices.
        Env.players[20].PlayerData.job = { name = 'unemployed', type = 'none' }

        Env.clientEvents = {}
        bridges.refreshAccess()
        eq(toldOf(20), true,
            'a player who leaves the barred job must get the app back without '
            .. 'depending on an event this resource cannot verify')
    end)

    --- The kill switch, tested where it is read.
    ---
    --- Config.HideAppFromBlockedJobs is a server setting: it decides what
    --- answer goes out, and the client only obeys. Off, everybody keeps the
    --- app and the request gate does the refusing, which is how this
    --- behaved before hiding existed — and is the way back for an operator
    --- whose players have lost the app.
    it('tells a barred job yes when hiding is switched off', function()
        local s = wired()
        fixture(s)
        Env.addPlayer({ source = 21, citizenid = 'OFFICER2', license = 'license:o2',
            firstname = 'Kay', lastname = 'Mercer',
            job = { name = 'police', type = 'leo', onduty = true } })
        local bridges = require('crimson-bounty.server.bridges')

        Env.clientEvents = {}
        bridges.refreshAccess()
        eq(toldOf(21), false, 'with hiding on, a barred job is told no')

        withConfig({ { Config, 'HideAppFromBlockedJobs', false } }, function()
            Env.clientEvents = {}
            bridges.refreshAccess()
            eq(toldOf(21), true,
                'with hiding off, the app stays and the gate refuses the '
                .. 'requests instead — which is the only way back for an '
                .. 'operator whose players have lost it')
        end)
    end)

    it('does not re-send an answer that has not changed', function()
        local s = wired()
        fixture(s)
        local bridges = require('crimson-bounty.server.bridges')

        bridges.refreshAccess()
        Env.clientEvents = {}
        bridges.refreshAccess()
        bridges.refreshAccess()

        local sent = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:access' then sent = sent + 1 end
        end
        eq(sent, 0, 'the sweep must send changes, not an event per player per tick')
    end)

    it('does not remember every source that has ever connected', function()
        local s = wired()
        fixture(s)
        local bridges = require('crimson-bounty.server.bridges')

        -- Two hundred players come and go, one at a time, as they do over a
        -- night on a busy server. What the sweep remembers has to be bounded
        -- by who is here, not by who has ever been.
        for i = 1, 200 do
            Env.addPlayer({ source = 100 + i, citizenid = ('TRANSIT%03d'):format(i),
                license = 'license:t' .. i, firstname = 'Pass', lastname = 'Through' })
            bridges.refreshAccess()
            Env.players[100 + i] = nil
        end
        bridges.refreshAccess()

        local remembered = bridges.accessMemoSize and bridges.accessMemoSize() or 0
        truthy(remembered <= 8,
            'the sweep is holding an entry for every source that has ever '
            .. 'connected, which only ever grows: ' .. remembered)
    end)

    it('says nothing about a player it cannot describe', function()
        local s = wired()
        fixture(s)
        Env.clientEvents = {}

        _G.source = 999
        Env.events['crimson-bounty:whoAmI']({})
        _G.source = nil

        eq(toldOf(999), nil,
            'unresolvable is not allowed: a player mid-join asks again rather '
            .. 'than being handed the app on a job nobody has read yet')
    end)
end)

--- The bridges between the framework and this resource, driven the way the
--- runtime drives them.
---
--- Found by line coverage rather than by reading: with the whole suite
--- running under a debug hook, the body of Bridges.onPlayerReady never
--- executed once, and neither did the memory-mode branch of
--- onPlayerDropped. Escrow.retryPending is called directly by a dozen
--- tests — which proves the function works, not that anything ever calls
--- it on the one occasion it exists for.
describe('what happens to a player as they arrive and leave', function()
    local function wired()
        local s = newStack()
        s.bridges.install(s)
        return s
    end

    --- Owed goods reach the player on the login that follows.
    ---
    --- A payout into a full inventory queues the line rather than losing
    --- it, and this is the only thing that ever hands it over. Nothing
    --- called it, so the whole recovery path existed on the strength of
    --- its own unit test.
    --- A payout into full pockets, which is what leaves something owed.
    local function owing()
        local s = wired()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'lockpick', count = 2 } } },
        })
        s.escrow.take(f.creator, 'ct1', lines)

        Env.players[3]._inventoryFull = true
        s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'test')
        Env.players[3]._inventoryFull = false

        local owed = s.storage.readPending('HUNTER01') or {}
        truthy(#owed > 0, 'the fixture must actually leave something owed')
        return s, #owed
    end

    it('hands over what was owed when the player comes back', function()
        local s, count = owing()
        local delivered = s.bridges.onPlayerReady(s, 3)
        eq(delivered, count, 'everything owed has to be handed over')
        eq(#(s.storage.readPending('HUNTER01') or {}), 0, 'and the queue emptied')
    end)

    it('tells them it happened, rather than doing it silently', function()
        local s = owing()
        Natives.calls.notifications = {}
        s.bridges.onPlayerReady(s, 3)

        local told = false
        for _, note in ipairs(Natives.calls.notifications or {}) do
            local text = tostring(note.title or '') .. ' ' .. tostring(note.message or '')
            if text:find('utstanding') then told = true end
        end
        truthy(told,
            'goods that appear in a pocket with no explanation read as a bug, '
            .. 'and a player who does not know they were paid asks for it twice')
    end)

    it('says nothing to a player who is owed nothing', function()
        local s = wired()
        fixture(s)
        Natives.calls.notifications = {}
        eq(s.bridges.onPlayerReady(s, 3), 0)
        eq(#(Natives.calls.notifications or {}), 0,
            'a message about nothing is one that teaches players to ignore them')
    end)

    it('is safe for a source the framework cannot resolve', function()
        local s = wired()
        fixture(s)
        eq(s.bridges.onPlayerReady(s, 999), 0,
            'a player mid-join must not throw inside a login handler')
    end)

    --- Memory mode keeps nothing across a restart, so a creator who
    --- disconnects would strand their own escrow. It is refunded and the
    --- contract closed instead. Nothing exercised that branch.
    it('refunds a creator who disconnects in memory mode', function()
        -- The stack is opened first: newStack() resets the whole config, so
        -- opening one inside withConfig puts the mode back and the test
        -- measures a server nobody configured.
        local s = wired()
        local f = fixture(s)
        withConfig({ { Config.Database, 'Mode', 'memory' } }, function()
            local before = Env.players[1].PlayerData.money.cash
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(Env.players[1].PlayerData.money.cash < before, 'escrow was taken')

            s.bridges.onPlayerDropped(s, 'CREATOR1')

            eq(s.storage.readContract(c.id).state, CB.STATE.CANCELLED,
                'a contract nobody can pay out is not left open')
            eq(Env.players[1].PlayerData.money.cash, before,
                'and the creator has their money back, because memory mode '
                .. 'would otherwise lose it at the next restart')
        end)
    end)

    it('leaves a durable store alone when a creator disconnects', function()
        local s = wired()
        local f = fixture(s)
        withConfig({ { Config.Database, 'Mode', 'json' } }, function()
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            s.bridges.onPlayerDropped(s, 'CREATOR1')
            eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE,
                'a contract that survives a restart must survive its creator '
                .. 'going to bed')
        end)
    end)
end)


--- The client half of the mugshot pipeline.
---
--- client/mugshot.lua had no coverage at all — not one line, ever — and it
--- is the file that produces every headshot on the board. It is also the
--- one file whose comments explain a guard against a clock that wraps, with
--- nothing checking the guard.
describe('rendering your own headshot', function()
    local function booted()
        Env.reset()
        Natives.resetResourceStates()
        Natives.mugshotThrows = nil
        Natives.mugshotReturns = nil
        Natives.calls.mugshots = {}
        require('crimson-bounty.shared.util').resetMonotonic()
        Client.boot()
        return Client
    end

    local function sentImages()
        local out = {}
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-bounty:mugshot' then out[#out + 1] = call.args[1] end
        end
        return out
    end

    it('renders when the server asks, and sends the image back', function()
        booted()
        truthy(Client.netEvents['crimson-bounty:renderMugshot'],
            'the server has to be able to ask')
        truthy(Client.fire('crimson-bounty:renderMugshot'))

        local sent = sentImages()
        eq(#sent, 1, 'one render, one image')
        truthy(tostring(sent[1]):find('data:image/png', 1, true), tostring(sent[1]))
    end)

    it('renders the caller own ped, transparent', function()
        booted()
        Client.fire('crimson-bounty:renderMugshot')
        local rendered = Natives.calls.mugshots[1]
        truthy(rendered, 'the renderer must have been called')
        eq(rendered.ped, 1003, 'a player renders themselves and nobody else')
        eq(rendered.transparent, true)
    end)

    it('does not render again inside the floor', function()
        -- A client must not be made to render in a loop by a flood of
        -- requests, whoever is sending them.
        booted()
        for _ = 1, 20 do Client.fire('crimson-bounty:renderMugshot') end
        eq(#sentImages(), 1, 'twenty asks, one render')
    end)

    it('renders again once the floor has passed', function()
        booted()
        Client.fire('crimson-bounty:renderMugshot')
        Env.gameTimer = (Env.gameTimer or 0) + 31000
        Client.fire('crimson-bounty:renderMugshot')
        eq(#sentImages(), 2, 'the floor is a floor, not a one-shot')
    end)

    --- The reason the file reads the monotonic clock rather than
    --- GetGameTimer, stated in its own comment: GetGameTimer wraps every
    --- ~24.8 days, and after a wrap `now - lastRender` is permanently
    --- negative, so the floor would refuse every render for the rest of the
    --- session and this player would have no headshot at all.
    it('still renders after the game timer wraps', function()
        booted()
        Env.gameTimer = 4294900000
        require('crimson-bounty.shared.util').resetMonotonic()
        Client.fire('crimson-bounty:renderMugshot')
        eq(#sentImages(), 1, 'the first render lands')

        -- Round the wrap, and past the floor on the far side of it.
        Env.gameTimer = 40000
        Client.fire('crimson-bounty:renderMugshot')
        eq(#sentImages(), 2,
            'a wrapped clock must not cost this player their headshot for '
            .. 'the rest of the session')
    end)

    it('does nothing on a server with no renderer installed', function()
        booted()
        Natives.resourceStates['MugShotBase64'] = 'missing'
        truthy(Client.fire('crimson-bounty:renderMugshot'),
            'an optional integration being absent must not throw')
        eq(#sentImages(), 0)
    end)

    it('survives a renderer that throws', function()
        booted()
        Natives.mugshotThrows = true
        truthy(Client.fire('crimson-bounty:renderMugshot'),
            'a third-party export throwing is not this resource crashing')
        eq(#sentImages(), 0, 'and nothing half-made is sent')
        Natives.mugshotThrows = nil
    end)

    it('sends nothing when the renderer returns something that is not an image', function()
        for _, odd in ipairs({ 42, true, {} }) do
            booted()
            Natives.mugshotReturns = odd
            truthy(Client.fire('crimson-bounty:renderMugshot'),
                ('a %s from the renderer must not throw'):format(type(odd)))
            eq(#sentImages(), 0, 'and must not be sent as a headshot')
        end
        Natives.mugshotReturns = nil
    end)

    it('tells the server when the player changes their appearance', function()
        -- Four event names, because three different clothing resources are
        -- in common use and any of them may be the one this server runs.
        for _, event in ipairs({
            'qb-clothing:client:loadOutfit',
            'illenium-appearance:client:reloadSkin',
            'rcore_clothing:outfitChanged',
            'crimson-bounty:appearanceChanged',
        }) do
            booted()
            local handler = Client.handlers[event]
            truthy(handler, 'nothing is listening for ' .. event)
            handler()

            local told = false
            for _, call in ipairs(Client.toServer) do
                if call.name == 'crimson-bounty:appearanceChanged' then told = true end
            end
            truthy(told, event .. ' did not reach the server')
        end
    end)
end)
