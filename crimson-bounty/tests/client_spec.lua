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
