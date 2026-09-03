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
        Client.runThreads()

        local registered
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then registered = call.spec end
        end
        truthy(registered, 'the app must be registered with lb-phone')
        eq(registered.identifier, 'crimson-bounty')
        truthy(registered.ui:find('ui/index.html', 1, true), 'and point at the page')
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

describe('app registration that does not take the first time', function()
    it('retries until lb-phone accepts', function()
        Env.reset()
        Client.boot({ refuseRegistration = true })
        Natives.resourceStates = { ['lb-phone'] = 'started' }

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
