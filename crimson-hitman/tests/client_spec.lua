--- The client, actually running.
---
--- Two hundred lines between the UI and the server that no test had ever
--- executed. Everything here is a build of lb-phone that is not quite the
--- one the code was written against — which is the normal case, since
--- lb-phone ships its server code escrowed and its export surface has moved
--- across releases.

local Client = require('crimson-hitman.tests.harness.client')

describe('the client on an ordinary phone', function()
    it('registers the app', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        -- A barred job never gets the app, so nothing registers until the
        -- server has said this player may have it.
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()

        local registered
        for _, call in ipairs(Client.phone) do
            if call.call == 'AddCustomApp' then registered = call.spec end
        end
        truthy(registered, 'the app must be registered with lb-phone')
        eq(registered.identifier, 'crimson-hitman')
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
        local manifest = io.open('crimson-hitman/fxmanifest.lua', 'r')
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
        Client.fire('crimson-hitman:access', true)
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

    --- In the App Store unless the owner puts it on every phone. It was a
    --- hard-coded false, with nothing in the README or the config to say
    --- players have to go and download it.
    it('puts the app on the home screen only when the owner says to', function()
        local function registered(app)
            local real = Config.App
            Config.App = app
            Env.reset()
            Client.boot()
            Natives.resourceStates = { ['lb-phone'] = 'started' }
            Client.fire('crimson-hitman:access', true)
            Client.runThreads()
            Config.App = real
            local spec
            for _, call in ipairs(Client.phone) do
                if call.call == 'AddCustomApp' then spec = call.spec end
            end
            return spec
        end

        eq(registered(Config.App).defaultApp, false, 'as shipped, players download it')
        eq(Config.App.DefaultInstalled, false, 'and that is what the shipped config says')
        eq(registered({ DefaultInstalled = true }).defaultApp, true,
            'on every eligible phone when the owner turns it on')
        eq(registered({ DefaultInstalled = 'yes' }).defaultApp, false,
            'only a real true turns it on')
        eq(registered(nil).defaultApp, false,
            'a config from before the setting reads as the shipped default; the '
            .. 'server fills missing sections only on its own side')
    end)

    it('forwards a push to the app', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire('crimson-hitman:push', { reason = 'contract_taken' }))

        local sent
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' then sent = call.message end
        end
        truthy(sent, 'the page must be told')
        eq(sent.type, 'push')
        eq(sent.reason, 'contract_taken')
        eq(sent.ids, nil, 'a push that names none is passed on naming none')
    end)

    it('forwards the contracts a push names', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire('crimson-hitman:push', { reason = 'proposal', ids = { 'ct00000002', 7 } }))

        local sent
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' then sent = call.message end
        end
        eq(sent and sent.ids and #sent.ids, 1, 'only the ids that are ids')
        eq(sent.ids[1], 'ct00000002')
    end)

    it('raises a notification', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire('crimson-hitman:notify', { title = 'Paid', content = '5000' }))

        local sent
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendNotification' then sent = call.data end
        end
        truthy(sent)
        eq(sent.title, 'Paid')
        eq(sent.app, 'crimson-hitman')
    end)
end)

describe('the client on a phone missing an export', function()
    it('does not lose the notify handler', function()
        Env.reset()
        -- Said in F8 with Config.Debug on; with it off the client prints
        -- nothing in normal play (console_spec).
        Config.Debug = true
        Client.boot({ without = { 'SendNotification' } })

        local ok = Client.fire('crimson-hitman:notify', { title = 'Paid', content = '5000' })
        resetConfig()
        truthy(ok, 'a build without the export must not throw out of the handler')
        truthy(Client.said('SendNotification'),
            'and it must say which export is missing: ' .. table.concat(Client.console, ' | '))
    end)

    it('does not lose the push handler', function()
        Env.reset()
        Client.boot({ without = { 'SendCustomAppMessage' } })
        truthy(Client.fire('crimson-hitman:push', { reason = 'x' }),
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
        eq(asked.name, 'crimson-hitman:requestPhotoToken')
        local rid = asked.args[1] and asked.args[1].__rid
        truthy(rid, 'and stamped the request with its own id')

        -- The token arrives, and the camera is what fails.
        truthy(Client.fire('crimson-hitman:result', {
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
        Client.fire('crimson-hitman:result', {
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
            eq(asked.name, 'crimson-hitman:list')
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

        truthy(Client.fire('crimson-hitman:result', {
            rid = rid, event = 'list', ok = true, data = { contracts = {} },
        }), 'the result handler must not throw')
        truthy(Client.answered, 'and the page must be answered')
        truthy(Client.answer and Client.answer.ok)
    end)

    it('survives a result that is not a table', function()
        Env.reset()
        Client.boot()

        for _, odd in ipairs({ 42, true }) do
            truthy(Client.fire('crimson-hitman:result', odd),
                ('a %s result must not throw out of the handler'):format(type(odd)))
        end
        truthy(Client.fire('crimson-hitman:result'),
            'nor must a result that is missing entirely')
    end)

    it('still delivers a real result after a malformed one', function()
        -- A throw out of the handler skipped resolving the request that
        -- asked, so the page waited out its timeout on a call the server
        -- had answered.
        Env.reset()
        Client.boot()

        Client.nuiCall('crimson:mine', {})
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid

        truthy(Client.fire('crimson-hitman:result', 42),
            'a malformed reply must not throw out of the handler')
        falsy(Client.answered, 'a malformed reply answers nobody')

        Client.fire('crimson-hitman:result', {
            rid = rid, event = 'mine', ok = true, data = { created = {} },
        })
        truthy(Client.answered, 'and the real reply still lands')

        -- And only there: the page acts on pushes alone, and every reply it
        -- uses reaches it once, as the answer to its own fetch. Mirrored as
        -- well, each reply was an export and an NUI message thrown away.
        for _, call in ipairs(Client.phone) do
            falsy(call.call == 'SendCustomAppMessage' and call.message
                and call.message.type == 'result',
                'a reply reaches the page once, as its answer')
        end
    end)

    --- A database held longer than the page's fifteen-second wait (S19): the
    --- server answered after the page had said "No answer", and the answer
    --- was dropped, so a contract placed and paid for showed nowhere until
    --- something else moved the page. It now has the page read everything
    --- again, once, and runs no callback a second time.
    it('refreshes the page once when a request it gave up on is answered late', function()
        Env.reset()
        Client.boot()

        Client.nuiCall('crimson:create', {})
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid
        Client.runTimeouts()
        eq(Client.answer and Client.answer.err, 'timeout')
        eq(Client.answer.event, 'create', 'named, for the page to word a money request apart')

        Client.phone = {}
        local late = { rid = rid, event = 'create', ok = true, data = {} }
        Client.fire('crimson-hitman:result', late)
        Client.fire('crimson-hitman:result', late)
        local pushes = 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' and call.message
                and call.message.type == 'push' then
                eq(call.message.reason, 'late')
                pushes = pushes + 1
            end
        end
        eq(pushes, 1, 'one push for the answer, however often it lands')
        eq(Client.answerCount, 1, 'and the page was answered once, by the timeout')
    end)
end)

describe('the camera, on a phone that dies mid-upload', function()
    --- Reported from a live server: the photo route says "uploading" and then
    --- the phone crashes. Everything here is a way this resource could be the
    --- one taking it down.

    local function tokenIssued(app)
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid
        Client.fire('crimson-hitman:result', {
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

    local function sentToServer(name)
        for _, e in ipairs(Client.toServer) do
            if e.name == name then return e end
        end
    end

    it('hands the photo lb-phone took to the server', function()
        -- lb-phone calls the SECOND argument of SetCameraComponent and never
        -- reads options.cb. With the callback only in the options, the shot
        -- went nowhere: nothing was submitted, and two minutes later the
        -- hitman was told the camera never came back.
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        truthy(Client.camera('https://cdn.fivemanage.com/proof.png'),
            'the camera must be given a callback lb-phone will actually call')

        local submit = sentToServer('crimson-hitman:submitPhoto')
        truthy(submit, 'the photograph was never sent to the server')
        eq(submit.args[1].token, 'tok')
        eq(submit.args[1].url, 'https://cdn.fivemanage.com/proof.png')

        falsy(Client.answered, 'the page waits for the verdict, not the shutter')
        Client.fire('crimson-hitman:result', {
            rid = submit.args[1].__rid, event = 'submitPhoto', ok = true, data = { slot = 1 },
        })
        truthy(Client.answered)
        truthy(Client.answer.ok, 'and it is told what the server decided')
        eq(Client.answerCount, 1)
    end)

    --- lb-phone's flip is the UP key, one key from its shutter (RETURN), and
    --- the photo goes to the client: flipped, it was the hitman's own face.
    it('opens the rear camera with no way to flip to the selfie one', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        local opened
        for _, call in ipairs(Client.phone) do
            if call.call == 'SetCameraComponent' then opened = call.spec end
        end
        truthy(opened, 'a camera was opened')
        eq(opened.default.camera, 'rear')
        eq(opened.permissions.flipCamera, false,
            'lb-phone allows everything it is not told to refuse')
    end)

    it('also works on a build that calls back through options.cb', function()
        -- lb-phone's own documentation gives the callback as a field of the
        -- options table. Builds seen in the wild read the second argument
        -- instead. Both are passed; this is the documented one.
        Env.reset()
        Client.boot()
        local documented
        Client.exports.SetCameraComponent = function(_, spec)
            table.insert(Client.phone, { call = 'SetCameraComponent', spec = spec })
            documented = spec and spec.cb
        end
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        truthy(documented, 'no callback where the documentation puts it')
        documented('https://cdn.fivemanage.com/proof.png')
        local submit = sentToServer('crimson-hitman:submitPhoto')
        truthy(submit, 'a build that calls options.cb had its photograph dropped')
        eq(submit.args[1].url, 'https://cdn.fivemanage.com/proof.png')
    end)

    it('submits once when a build calls back by more than one route', function()
        Env.reset()
        Client.boot()
        Client.exports.SetCameraComponent = function(_, spec, cb)
            table.insert(Client.phone, { call = 'SetCameraComponent', spec = spec })
            spec.cb('https://cdn.fivemanage.com/proof.png')
            cb('https://cdn.fivemanage.com/proof.png')
            return 'https://cdn.fivemanage.com/proof.png'
        end
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        local submits = 0
        for _, e in ipairs(Client.toServer) do
            if e.name == 'crimson-hitman:submitPhoto' then submits = submits + 1 end
        end
        eq(submits, 1, 'one photograph sent as several claims')
    end)

    it('opens no camera when there is nothing to photograph', function()
        -- The commonest tap of Verify kill. The refusal used to "reset" the
        -- camera on its way out, which on lb-phone opens one — and, with no
        -- callback, waits for the player to close it before the page hears
        -- anything.
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        local asked = Client.toServer[#Client.toServer]
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'requestPhotoToken',
            ok = false, err = 'no_kill_to_verify',
        })

        truthy(Client.answered, 'the page must be told straight away')
        eq(Client.answer.err, 'no_kill_to_verify')
        for _, call in ipairs(Client.phone) do
            falsy(call.call == 'SetCameraComponent', 'a refusal opened a camera')
        end
    end)

    --- A build whose SetCameraComponent ignores the callback and waits for
    --- the shot inside the call (Citizen.Await), returning the URL. The wait
    --- is a coroutine yield here.
    local function waitingCamera()
        Client.exports.SetCameraComponent = function(_, spec)
            table.insert(Client.phone, { call = 'SetCameraComponent', spec = spec })
            return coroutine.yield('camera-open')
        end
    end

    local function tokenIssuedInto(co)
        local asked = Client.toServer[#Client.toServer]
        local rid = asked.args[1] and asked.args[1].__rid
        return coroutine.resume(co, rid)
    end

    it('still gives up on a camera that waits inside the call and never returns', function()
        Env.reset()
        Client.boot()
        waitingCamera()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })

        local co = coroutine.create(function(rid)
            return Client.fire('crimson-hitman:result', {
                rid = rid, event = 'requestPhotoToken', ok = true, data = { token = 'tok' },
            })
        end)
        local _, tag = tokenIssuedInto(co)
        eq(tag, 'camera-open', 'the camera is open and the call is waiting on it')

        -- The camera never comes back. The timer has to exist already: one
        -- armed after the call would be armed only once the call returns.
        Client.runTimeouts()
        truthy(Client.answered,
            'the no-answer timer was never armed, so the page waits for good')
        eq(Client.answer.err, 'camera_no_answer')

        -- Let the waiting call finish, or the harness's swapped-in exports
        -- and print stay installed for every suite that runs after this.
        coroutine.resume(co, nil)
        eq(coroutine.status(co), 'dead')
        eq(Client.answerCount, 1)
    end)

    it('submits a URL handed back as the return value', function()
        Env.reset()
        Client.boot()
        waitingCamera()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })

        local co = coroutine.create(function(rid)
            return Client.fire('crimson-hitman:result', {
                rid = rid, event = 'requestPhotoToken', ok = true, data = { token = 'tok' },
            })
        end)
        tokenIssuedInto(co)
        coroutine.resume(co, 'https://cdn.fivemanage.com/proof.png')

        local submit = sentToServer('crimson-hitman:submitPhoto')
        truthy(submit, 'the URL the camera returned was thrown away')
        eq(submit.args[1].url, 'https://cdn.fivemanage.com/proof.png')
    end)

    it('opens exactly one camera, and never a bare one', function()
        -- lb-phone's SetCameraComponent treats anything that is not a table
        -- as empty options and OPENS a camera with them. The "reset" this
        -- used to send after every ending was a second camera with the
        -- phone's defaults, popped open over a hitman who had just taken
        -- their photo — or who had been refused before any camera opened.
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        truthy(Client.camera('https://example.com/a.png'))
        Client.runTimeouts()

        local opened, bare = 0, 0
        for _, call in ipairs(Client.phone) do
            if call.call == 'SetCameraComponent' then
                opened = opened + 1
                if type(call.spec) ~= 'table' or next(call.spec) == nil then bare = bare + 1 end
            end
        end
        eq(opened, 1, 'one photograph, one camera')
        eq(bare, 0, 'a camera was opened with no options at all')
    end)

    it('never leaves the shot in the hitmans own gallery', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()

        local spec
        for _, call in ipairs(Client.phone) do
            if call.call == 'SetCameraComponent' then spec = call.spec end
        end
        truthy(spec, 'the camera should have been configured')
        -- false, not absent: lb-phone saves to the gallery unless told not
        -- to, and there is no setting that turns this back on.
        eq(spec.saveToGallery, false,
            'the photo is the client alone; a copy on the phone that took it is '
            .. 'a photograph of a body left in the hitmans gallery')
    end)
end)

describe('saving the client their kill photo', function()
    local URL = 'https://cdn.fivemanage.com/proof.png'

    --- The server's answer to the page opening a photo, as it reaches the
    --- client: through the result event, like every reply.
    local function opened(handle, url)
        Client.nuiCall('crimson:openPhoto', { handle = handle })
        local asked = Client.toServer[#Client.toServer]
        eq(asked.name, 'crimson-hitman:openPhoto', 'the page asks the server')
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'openPhoto', ok = true,
            data = { handle = handle, url = url },
        })
    end

    local function saves()
        local out = {}
        for _, call in ipairs(Client.phone) do
            if call.call == 'SaveToGallery' then out[#out + 1] = call.link end
        end
        return out
    end

    it('saves the photo the server opened for this player', function()
        Env.reset()
        Client.boot()
        opened('ph00000000aa', URL)
        local _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        truthy(answer and answer.ok, 'the save has to go through')
        eq(saves()[1], URL, 'the link the server handed over, and no other')
    end)

    it('saves nothing the server did not open for this player', function()
        Env.reset()
        Client.boot()
        -- An NUI endpoint is addressable from any frame the phone draws, so
        -- what arrives here may not be from this page.
        local _, answer = Client.nuiCall('crimson:saveToPhotos',
            { handle = 'ph00000000aa', url = 'https://elsewhere.example/x.png' })
        falsy(answer.ok, 'nothing is open')
        eq(#saves(), 0)

        opened('ph00000000aa', URL)
        _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000bb' })
        falsy(answer.ok, 'another handle is not the open photo')
        eq(#saves(), 0)
    end)

    it('saves no link while kill photos are off', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:openPhoto', { handle = 'ph00000000aa' })
        local asked = Client.toServer[#Client.toServer]
        Client.fire('crimson-hitman:result', { rid = asked.args[1].__rid, event = 'openPhoto',
            ok = true, data = { handle = 'ph00000000aa', url = URL, photosOff = true } })
        local _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        falsy(answer.ok, 'nothing goes to the phone\'s Photos with photos off')
        eq(#saves(), 0)
    end)

    it('forgets the link once the server has the decision', function()
        Env.reset()
        Client.boot()
        opened('ph00000000aa', URL)
        Client.fire('crimson-hitman:result', { event = 'photoDecision', ok = true,
            data = { handle = 'ph00000000aa', state = 'deleted' } })
        local _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        falsy(answer.ok, 'a deleted photo cannot be saved from here afterwards')
        eq(#saves(), 0)
    end)

    it('saves the link the server serves a photo it keeps under, once it hands it over', function()
        Env.reset()
        Client.boot()
        local SERVED = 'https://chatty.server.qbox.re/crimson-hitman/p/Zk3_q-9xWb2LmT0cRf8aNd.webp'
        -- A photo kept on the server opens as a picture, with no link.
        Client.nuiCall('crimson:openPhoto', { handle = 'ph00000000aa' })
        local asked = Client.toServer[#Client.toServer]
        Client.fire('crimson-hitman:result', { rid = asked.args[1].__rid, event = 'openPhoto',
            ok = true, data = { handle = 'ph00000000aa', latent = true, link = true } })
        local _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        falsy(answer.ok, 'no link yet: nothing to save')

        Client.fire('crimson-hitman:result', { event = 'photoDecision', ok = true,
            data = { handle = 'ph00000000aa', state = 'open', link = SERVED } })
        _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        truthy(answer and answer.ok, 'the served link is saved')
        eq(saves()[1], SERVED)

        Client.fire('crimson-hitman:result', { event = 'photoDecision', ok = true,
            data = { handle = 'ph00000000aa', state = 'saved' } })
        _, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        falsy(answer.ok, 'and forgotten once the server has the decision')
        eq(#saves(), 1)
    end)

    it('answers on a phone without the export rather than leaving the page waiting', function()
        Env.reset()
        Client.boot({ without = { 'SaveToGallery' } })
        opened('ph00000000aa', URL)
        local answered, answer = Client.nuiCall('crimson:saveToPhotos', { handle = 'ph00000000aa' })
        truthy(answered, 'answered')
        falsy(answer.ok)
        eq(answer.err, 'save_unavailable')
        eq(Client.answerCount, 1)
    end)
end)

describe('the viewfinder, on a server that keeps its photos itself', function()
    --- On 'server' storage the page takes the photo in its own viewfinder
    --- and hands the client the picture; the client puts the token to it.
    --- The token must never reach the page, and the picture must go as a
    --- latent event.

    local IMAGE = 'data:image/webp;base64,UklGRgAAAABXRUJQ'

    local function tokenIssued(data)
        local asked = Client.toServer[#Client.toServer]
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'requestPhotoToken', ok = true,
            data = data or { token = 'tk-secret-01', storage = 'server',
                             maxSide = 1280, maxBytes = 600000 },
        })
    end

    local function called(name)
        local out = {}
        for _, call in ipairs(Client.phone) do
            if call.call == name then out[#out + 1] = call end
        end
        return out
    end

    --- Everything that went to the page: NUI answers and app messages.
    local function toPage()
        local parts = { tostring(Client.answer and Client.answer.data and
            (Client.answer.data.token or '') or '') }
        for _, call in ipairs(called('SendCustomAppMessage')) do
            local m = call.message
            parts[#parts + 1] = tostring(m.data and m.data.token or '')
        end
        return table.concat(parts, ' ')
    end

    it('opens the viewfinder rather than lb-phone\'s camera, and keeps the token', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()

        truthy(Client.answered, 'the page is told at once to open its viewfinder')
        truthy(Client.answer.ok)
        eq(Client.answer.data.viewfinder, true)
        eq(Client.answer.data.maxSide, 1280)
        eq(Client.answer.data.maxBytes, 600000)
        eq(#called('SetCameraComponent'), 0, 'lb-phone\'s camera uploads to its image host')
        falsy(toPage():find('tk-secret-01', 1, true),
            'the token went to the page, in the answer or in the mirrored reply')
    end)

    it('gives the page no way to ask for the token, or to send one', function()
        -- Any frame the phone draws can address this resource's NUI
        -- callbacks. One that forwarded requestPhotoToken answered it with
        -- a live token, and replaced the one held for an open viewfinder.
        Env.reset()
        Client.boot()
        for _, name in ipairs({ 'requestPhotoToken', 'submitPhoto' }) do
            falsy(Client.nui['crimson:' .. name], 'crimson:' .. name .. ' is open to the page')
        end

        -- Every callback the page does have, asked with a contract id while
        -- the server hands out a token: none answers with it.
        local leaked = {}
        local names = {}
        for name in pairs(Client.nui) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local before = #Client.toServer
            Client.nuiCall(name, { id = 'ct00000001', handle = 'ph00000000aa' })
            for i = before + 1, #Client.toServer do
                local sent = Client.toServer[i]
                if sent.name == 'crimson-hitman:requestPhotoToken' then
                    Client.fire('crimson-hitman:result', {
                        rid = sent.args[1].__rid, event = 'requestPhotoToken', ok = true,
                        data = { token = 'tk-secret-01', storage = 'server',
                                 maxSide = 1280, maxBytes = 600000 },
                    })
                end
            end
            if toPage():find('tk-secret-01', 1, true) then leaked[#leaked + 1] = name end
        end
        eq(#leaked, 0, 'the token reached the page through ' .. table.concat(leaked, ', '))
    end)

    it('sends the picture on as a latent event with the token it holds', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()

        Client.nuiCall('crimson:sendVerificationPhoto', { id = 'ct00000001', image = IMAGE })
        local sent = Client.toServer[#Client.toServer]
        eq(sent.name, 'crimson-hitman:submitPhoto')
        truthy(sent.latent, 'a photo is too big for an ordinary event')
        truthy((sent.bps or 0) > 25000, 'and faster than FiveM\'s default of half a minute a photo')
        eq(sent.args[1].token, 'tk-secret-01')
        eq(sent.args[1].image, IMAGE)
        falsy(sent.args[1].url)

        falsy(Client.answered, 'the page waits for the verdict')
        Client.fire('crimson-hitman:result', {
            rid = sent.args[1].__rid, event = 'submitPhoto', ok = true, data = { settled = 1 },
        })
        truthy(Client.answered and Client.answer.ok, 'and is told it')
        eq(Client.answer.data.settled, 1)
        eq(Client.answerCount, 1)
    end)

    it('puts one picture to each token, and none to a contract it holds none for', function()
        Env.reset()
        Client.boot()
        local _, answer = Client.nuiCall('crimson:sendVerificationPhoto',
            { id = 'ct00000001', image = IMAGE })
        eq(answer.err, 'no_token', 'nothing was asked for: the page cannot make a claim alone')

        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued()
        Client.nuiCall('crimson:sendVerificationPhoto', { id = 'ct00000001', image = IMAGE })
        local before = #Client.toServer
        _, answer = Client.nuiCall('crimson:sendVerificationPhoto', { id = 'ct00000001', image = IMAGE })
        eq(answer.err, 'no_token', 'a second picture needs a second Verify kill')
        _, answer = Client.nuiCall('crimson:sendVerificationPhoto', { id = 'ct00000002', image = IMAGE })
        eq(answer.err, 'no_token', 'nor does one contract\'s token go to another')
        eq(#Client.toServer, before, 'and nothing more went to the server')
    end)

    it('sends nothing that is not a picture, or is bigger than the server keeps', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued({ token = 'tk-secret-01', storage = 'server', maxSide = 1280, maxBytes = 3000 })
        local before = #Client.toServer

        local _, answer = Client.nuiCall('crimson:sendVerificationPhoto',
            { id = 'ct00000001', image = 'https://cdn.fivemanage.com/proof.png' })
        eq(answer.err, 'photo_bad_image')
        _, answer = Client.nuiCall('crimson:sendVerificationPhoto',
            { id = 'ct00000001', image = 'data:image/webp;base64,' .. ('A'):rep(8000) })
        eq(answer.err, 'photo_too_large', 'a page cannot have this client upload a great deal')
        eq(#Client.toServer, before, 'neither went anywhere')
    end)

    it('still opens lb-phone\'s camera on a server that keeps links', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:takeVerificationPhoto', { id = 'ct00000001' })
        tokenIssued({ token = 'tk-secret-01', storage = 'host' })
        eq(#called('SetCameraComponent'), 1)
        falsy(Client.answered, 'the page waits for the camera')
    end)

    it('runs the rear game camera behind the viewfinder, and turns it off', function()
        Env.reset()
        Client.boot()
        local _, answer = Client.nuiCall('crimson:verificationCamera', { on = true })
        truthy(answer.ok)
        local on = called('EnableWalkableCam')
        eq(#on, 1)
        eq(on[1].selfie, false, 'never the selfie camera: the hitman is not in the photo')

        _, answer = Client.nuiCall('crimson:verificationCamera', { on = false })
        truthy(answer.ok)
        eq(#called('DisableWalkableCam'), 1)
        Client.nuiCall('crimson:verificationCamera', { on = false })
        eq(#called('DisableWalkableCam'), 1, 'off once, not on every ask')
    end)

    it('turns the camera off when the phone is put away mid-shot', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        local spec
        for _, call in ipairs(called('AddCustomApp')) do spec = call.spec end
        truthy(spec and spec.onClose, 'the app tells lb-phone what to do when it closes')

        Client.nuiCall('crimson:verificationCamera', { on = true })
        local real = _G.exports
        _G.exports = setmetatable({}, { __index = function(_, r)
            if r == 'lb-phone' then return Client.exports end
            return real[r]
        end })
        spec.onClose()
        _G.exports = real
        eq(#called('DisableWalkableCam'), 1)
    end)

    -- `restart crimson-hitman` with the viewfinder open: the onClose above
    -- is a function in the resource that just stopped, so only this
    -- resource's own stop handler can turn the camera off.
    it('turns the camera off when this resource stops mid-shot', function()
        Env.reset()
        Client.boot()
        Client.nuiCall('crimson:verificationCamera', { on = true })
        truthy(Client.fire('onResourceStop', 'some-other-resource') ~= false)
        eq(#called('DisableWalkableCam'), 0, 'another resource stopping is not ours')
        Client.fire('onResourceStop', 'crimson-hitman')
        eq(#called('DisableWalkableCam'), 1)
    end)

    it('answers the page on a phone without the game camera', function()
        Env.reset()
        Client.boot({ without = { 'EnableWalkableCam', 'DisableWalkableCam' } })
        local answered, answer = Client.nuiCall('crimson:verificationCamera', { on = true })
        truthy(answered, 'a missing export must not leave the viewfinder waiting')
        falsy(answer.ok)
        eq(answer.err, 'camera_unavailable')
    end)
end)

describe('a kill photo kept on the server, on its way to the client', function()
    --- The server sends the photo as a latent event of its own and the
    --- ordinary reply only says it is coming. The page's request is held
    --- until it arrives, whichever comes first.

    local SRC = 'data:image/webp;base64,UklGRgAAAABXRUJQ'

    local function openAsked(handle)
        Client.nuiCall('crimson:openPhoto', { handle = handle })
        return Client.toServer[#Client.toServer]
    end

    local function replied(asked, handle)
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'openPhoto', ok = true,
            data = { handle = handle, latent = true },
        })
    end

    it('hands the page the photo once it arrives', function()
        Env.reset()
        Client.boot()
        local asked = openAsked('ph00000000aa')
        replied(asked, 'ph00000000aa')
        falsy(Client.answered, 'held until the photo itself is here')

        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000aa', src = SRC })
        truthy(Client.answered)
        truthy(Client.answer.ok)
        eq(Client.answer.data.src, SRC)
        eq(Client.answer.data.handle, 'ph00000000aa')
        eq(Client.answerCount, 1)

        -- And tells the server it is here, which sends one photo at a time
        -- and otherwise waits out the minute.
        local said
        for _, sent in ipairs(Client.toServer) do
            if sent.name == 'crimson-hitman:photoArrived' then said = sent end
        end
        truthy(said, 'the server is told the photo landed')
        eq(said.args[1], 'ph00000000aa', 'naming it, and nothing else')
        falsy(said.latent)

        for _, call in ipairs(Client.phone) do
            if call.call == 'SendCustomAppMessage' then
                falsy(tostring(call.message.data and call.message.data.src or ''):find('base64', 1, true),
                    'the photo is passed around once, not mirrored to the page as well')
            end
        end
    end)

    it('tells the page how the photo may be saved, as the server said', function()
        Env.reset()
        Client.boot()
        local asked = openAsked('ph00000000aa')
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'openPhoto', ok = true,
            data = { handle = 'ph00000000aa', latent = true, link = true },
        })
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000aa', src = SRC })
        truthy(Client.answered and Client.answer.ok)
        eq(Client.answer.data.link, true, 'the server can serve it to the phone\'s Photos')
        falsy(Client.answer.data.kept)

        Env.reset()
        Client.boot()
        asked = openAsked('ph00000000bb')
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000bb', src = SRC })
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'openPhoto', ok = true,
            data = { handle = 'ph00000000bb', latent = true, kept = true },
        })
        truthy(Client.answered and Client.answer.ok)
        eq(Client.answer.data.kept, true, 'a photo kept in the app, arrived ahead of its reply')
        eq(Client.answer.data.src, SRC)
        falsy(Client.answer.data.link)

        -- Kill photos off: the page offers no way to the phone's Photos.
        Env.reset()
        Client.boot()
        asked = openAsked('ph00000000cc')
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'openPhoto', ok = true,
            data = { handle = 'ph00000000cc', latent = true, photosOff = true },
        })
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000cc', src = SRC })
        truthy(Client.answered and Client.answer.ok)
        eq(Client.answer.data.photosOff, true, 'photos off, as the server said')
        falsy(Client.answer.data.link)
    end)

    it('takes a photo that came before the reply naming it', function()
        Env.reset()
        Client.boot()
        local asked = openAsked('ph00000000aa')
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000aa', src = SRC })
        falsy(Client.answered)
        replied(asked, 'ph00000000aa')
        truthy(Client.answered and Client.answer.ok)
        eq(Client.answer.data.src, SRC)
    end)

    it('passes on nothing that is not the photo it was waiting for', function()
        Env.reset()
        Client.boot()
        local asked = openAsked('ph00000000aa')
        replied(asked, 'ph00000000aa')
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000bb', src = SRC })
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000aa',
            src = 'https://elsewhere.example/x.png' })
        Client.fire('crimson-hitman:photoImage', 'nonsense')
        falsy(Client.answered, 'another handle, a link and junk are none of them the photo')
        for _, sent in ipairs(Client.toServer) do
            falsy(sent.name == 'crimson-hitman:photoArrived' and sent.args[1] == 'ph00000000aa',
                'and none of them is reported as the photo arriving')
        end
    end)

    it('tells the page when the photo never arrives', function()
        Env.reset()
        Client.boot()
        local asked = openAsked('ph00000000aa')
        replied(asked, 'ph00000000aa')
        Client.runTimeouts()
        truthy(Client.answered, 'the page was left waiting for good')
        falsy(Client.answer.ok)
        eq(Client.answer.err, 'photo_no_answer')
        falsy(Client.answer.data and Client.answer.data.kept,
            'a photo waiting for its one look is not one kept in the app')
        Client.fire('crimson-hitman:photoImage', { handle = 'ph00000000aa', src = SRC })
        eq(Client.answerCount, 1, 'and is not answered a second time when it turns up late')
    end)

    it('says when a photo that never arrived is one kept in the app', function()
        -- Opening a kept photo spends nothing, and it opens again. Told only
        -- "no answer", the page reported it deleted and the server deleted
        -- it, file and all.
        Env.reset()
        Client.boot()
        local asked = openAsked('ph00000000bb')
        Client.fire('crimson-hitman:result', {
            rid = asked.args[1].__rid, event = 'openPhoto', ok = true,
            data = { handle = 'ph00000000bb', latent = true, kept = true },
        })
        Client.runTimeouts()
        truthy(Client.answered)
        falsy(Client.answer.ok)
        eq(Client.answer.err, 'photo_no_answer')
        eq(Client.answer.data.kept, true)
        eq(Client.answer.data.handle, 'ph00000000bb')
    end)
end)

describe('a job that is barred from the app', function()
    --- The gate already refuses every request from a barred job, but the app
    --- was still installed and opened for them: it answered nothing, which
    --- reads as broken rather than as not for them. An officer should not be
    --- looking at a contract board at all.

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
        Client.fire('crimson-hitman:access', false)
        Client.runThreads()
        eq(registrations(), 0, 'a barred job was given the app anyway')
    end)

    it('registers it once the server says they may have it', function()
        ready()
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        eq(registrations(), 1, 'an allowed player must get the app')
    end)

    --- W167: the page could not know which screen was theirs, so an
    --- officer's every open asked for the board, Mine and the ledger, and
    --- the server wrote each refusal down as probing. The server says the
    --- screen with the answer; the client hands it to the page as it opens,
    --- asking the server nothing.
    it('hands the page the screen the server said is theirs, asking the server nothing', function()
        ready()
        local answered, answer = Client.nuiCall('crimson:accessMode', {})
        truthy(answered, 'answered at once, even before the server has said')
        eq(answer.ok, true)
        eq(answer.data.mode, nil, 'unknown until told')
        Client.fire('crimson-hitman:access', true, 'whitelisted')
        Client.toServer = {}
        answered, answer = Client.nuiCall('crimson:accessMode', {})
        eq(answer.data.mode, 'whitelisted')
        eq(#Client.toServer, 0, 'nothing asked of the server')
        Client.fire('crimson-hitman:access', true, 'full')
        eq(select(2, Client.nuiCall('crimson:accessMode', {})).data.mode, 'full')
        Client.fire('crimson-hitman:access', true, 'something else')
        eq(select(2, Client.nuiCall('crimson:accessMode', {})).data.mode, nil,
            'only a screen there is')
    end)

    it('takes it back when they go on duty mid-session', function()
        ready()
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        eq(registrations(), 1)

        -- They take a barred job. Refusing to register it next time is not
        -- enough: it is already on their phone.
        Client.fire('crimson-hitman:access', false)
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
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        Client.fire('crimson-hitman:access', false)
        Client.runThreads()
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()

        truthy(registrations() >= 2,
            'a player who leaves the barred job must get the app back without '
            .. 'reconnecting, got ' .. registrations() .. ' registrations')
    end)

    it('does not churn the phone when the answer has not changed', function()
        ready()
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        for _ = 1, 5 do Client.fire('crimson-hitman:access', true) end
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
        Client.fire('crimson-hitman:access', true)
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
        Client.fire('crimson-hitman:access', true)
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
        Client.fire('crimson-hitman:access', true)
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
            if call.name == 'crimson-hitman:whoAmI' then asked = true end
        end
        truthy(asked,
            'a client that started after the join push would otherwise wait '
            .. 'for an event that has already been and gone')
    end)
end)

describe('app registration that does not take the first time', function()
    it('retries until lb-phone accepts', function()
        Env.reset()
        -- Said in F8 with Config.Debug on (see above).
        Config.Debug = true
        Client.boot({ refuseRegistration = true })
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-hitman:access', true)

        -- The first pass refuses throughout: ten attempts, no app.
        Client.runThreads()
        resetConfig()

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
        -- Said in F8 with Config.Debug on (see above).
        Config.Debug = true
        Client.boot({ without = { 'AddCustomApp' } })
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-hitman:access', true)

        local ran = Client.runThreads()
        resetConfig()
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
        Client.fire('crimson-hitman:access', true)
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
        Client.fire('crimson-hitman:access', true)
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
        -- Hiding from barred jobs as it stands with the whitelisted-job view
        -- off (Config.WhitelistedView.Enabled = false). It ships on, and
        -- then a barred job has the app with its one screen: what that
        -- answers is whitelisted_view_spec's business.
        Config.WhitelistedView.Enabled = false
        s.app.init(s)
        require('crimson-hitman.server.bridges').install(s)
        return s
    end

    --- What the server last told this player.
    local function toldOf(src)
        local answer
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:access' and event.target == src then
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
        Env.events['crimson-hitman:whoAmI']({})
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
        Env.events['crimson-hitman:whoAmI']({})
        _G.source = nil
        Config.HideAppFromBlockedJobs = was

        eq(toldOf(21), true,
            'the switch must stop the hiding, not merely soften it')

        -- And it grants nothing: the gate refuses them exactly as before.
        local blocked, err = s.identity.gate(21)
        falsy(blocked, 'the switch must not become a way past the gate')
        eq(err, CH.ERR.BLACKLISTED_JOB)
    end)

    it('tells a barred job they may not', function()
        local s = wired()
        fixture(s)
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o',
            firstname = 'Ann', lastname = 'Ryder',
            job = { name = 'police', type = 'leo', onduty = true } })
        Env.clientEvents = {}

        _G.source = 20
        Env.events['crimson-hitman:whoAmI']({})
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

        local bridges = require('crimson-hitman.server.bridges')

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
        local bridges = require('crimson-hitman.server.bridges')

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
        local bridges = require('crimson-hitman.server.bridges')

        bridges.refreshAccess()
        Env.clientEvents = {}
        bridges.refreshAccess()
        bridges.refreshAccess()

        local sent = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:access' then sent = sent + 1 end
        end
        eq(sent, 0, 'the sweep must send changes, not an event per player per tick')
    end)

    it('does not remember every source that has ever connected', function()
        local s = wired()
        fixture(s)
        local bridges = require('crimson-hitman.server.bridges')

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
        Env.events['crimson-hitman:whoAmI']({})
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
        s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
        Env.players[3]._inventoryFull = false

        local owed = s.storage.readPending('HITMAN01') or {}
        truthy(#owed > 0, 'the fixture must actually leave something owed')
        return s, #owed
    end

    it('hands over what was owed when the player comes back', function()
        local s, count = owing()
        local delivered = s.bridges.onPlayerReady(s, 3)
        eq(delivered, count, 'everything owed has to be handed over')
        eq(#(s.storage.readPending('HITMAN01') or {}), 0, 'and the queue emptied')
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

    --- W195: the kept notice was written while nothing could be handed over,
    --- and came after "it has been delivered", which it then contradicted;
    --- and cash was counted as "1 outstanding item".
    it('says what happened first, then what arrived, by amount', function()
        local s = wired()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 100000 } },
        })
        truthy(c, 'placed')
        Env.removePlayer(1)
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        Env.clientEvents = {}
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
            cash = 0, bank = 100000, firstname = 'Vic', lastname = 'Marlowe' })
        s.bridges.onPlayerReady(s, 1)
        local order = {}
        for _, event in ipairs(Env.clientEvents) do
            if Natives.isNotice(event) and event.target == 1 then order[#order + 1] = event.args[1] end
        end
        eq(#order, 2, 'the kept notice and the delivery')
        eq(order[1].title, 'Contract expired', 'what happened to their contract first')
        eq(order[2].title, 'Outstanding payment', 'then what arrived')
        eq(order[2].content, '$100,000 you were owed has arrived.')
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
                mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(Env.players[1].PlayerData.money.cash < before, 'escrow was taken')

            s.bridges.onPlayerDropped(s, 'CREATOR1')

            eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED,
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
                mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            s.bridges.onPlayerDropped(s, 'CREATOR1')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE,
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
        require('crimson-hitman.shared.util').resetMonotonic()
        Client.boot()
        return Client
    end

    local function sentImages()
        local out = {}
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-hitman:mugshot' then out[#out + 1] = call.args[1] end
        end
        return out
    end

    it('renders when the server asks, and sends the image back', function()
        booted()
        truthy(Client.netEvents['crimson-hitman:renderMugshot'],
            'the server has to be able to ask')
        truthy(Client.fire('crimson-hitman:renderMugshot'))

        local sent = sentImages()
        eq(#sent, 1, 'one render, one image')
        truthy(tostring(sent[1]):find('data:image/png', 1, true), tostring(sent[1]))
    end)

    -- Cutting the background out loads a 2.6 MB segmentation model in
    -- MugShotBase64's page on every render and never frees it, on the
    -- target's game, set off by somebody else viewing the board.
    it('renders the caller own ped, background left in by default', function()
        booted()
        Client.fire('crimson-hitman:renderMugshot')
        local rendered = Natives.calls.mugshots[1]
        truthy(rendered, 'the renderer must have been called')
        eq(rendered.ped, 1003, 'a player renders themselves and nobody else')
        eq(rendered.transparent, false)
    end)

    it('cuts the background out only when the server owner asks', function()
        booted()
        Config.Mugshot.RemoveBackground = true
        Client.fire('crimson-hitman:renderMugshot')
        Config.Mugshot.RemoveBackground = false
        eq(Natives.calls.mugshots[1].transparent, true)
    end)

    it('sends the image as a latent event', function()
        booted()
        Client.fire('crimson-hitman:renderMugshot')
        local sent
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-hitman:mugshot' then sent = call end
        end
        truthy(sent and sent.latent, 'tens of KB, sent paced rather than all at once')
        truthy((sent.bps or 0) > 0)
    end)

    it('does not render again inside the floor', function()
        -- A client must not be made to render in a loop by a flood of
        -- requests, whoever is sending them.
        booted()
        for _ = 1, 20 do Client.fire('crimson-hitman:renderMugshot') end
        eq(#sentImages(), 1, 'twenty asks, one render')
    end)

    it('renders again once the floor has passed', function()
        booted()
        Client.fire('crimson-hitman:renderMugshot')
        Env.gameTimer = (Env.gameTimer or 0) + 31000
        Client.fire('crimson-hitman:renderMugshot')
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
        require('crimson-hitman.shared.util').resetMonotonic()
        Client.fire('crimson-hitman:renderMugshot')
        eq(#sentImages(), 1, 'the first render lands')

        -- Round the wrap, and past the floor on the far side of it.
        Env.gameTimer = 40000
        Client.fire('crimson-hitman:renderMugshot')
        eq(#sentImages(), 2,
            'a wrapped clock must not cost this player their headshot for '
            .. 'the rest of the session')
    end)

    it('renders nothing with headshots switched off, even when asked', function()
        booted()
        withConfig({ { Config.Mugshot, 'Enabled', false } }, function()
            truthy(Client.fire('crimson-hitman:renderMugshot'))
            eq(#Natives.calls.mugshots, 0, 'the renderer is not called')
            eq(#sentImages(), 0, 'and nothing is sent')
        end)
    end)

    it('does nothing on a server with no renderer installed', function()
        booted()
        Natives.resourceStates['MugShotBase64'] = 'missing'
        truthy(Client.fire('crimson-hitman:renderMugshot'),
            'an optional integration being absent must not throw')
        eq(#sentImages(), 0)
    end)

    it('survives a renderer that throws', function()
        booted()
        Natives.mugshotThrows = true
        truthy(Client.fire('crimson-hitman:renderMugshot'),
            'a third-party export throwing is not this resource crashing')
        eq(#sentImages(), 0, 'and nothing half-made is sent')
        Natives.mugshotThrows = nil
    end)

    it('sends nothing when the renderer returns something that is not an image', function()
        for _, odd in ipairs({ 42, true, {} }) do
            booted()
            Natives.mugshotReturns = odd
            truthy(Client.fire('crimson-hitman:renderMugshot'),
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
            'crimson-hitman:appearanceChanged',
        }) do
            booted()
            local handler = Client.handlers[event]
            truthy(handler, 'nothing is listening for ' .. event)
            handler()

            local told = false
            for _, call in ipairs(Client.toServer) do
                if call.name == 'crimson-hitman:appearanceChanged' then told = true end
            end
            truthy(told, event .. ' did not reach the server')
        end
    end)
end)


--- The client half of kill attribution.
---
--- A `while true` watcher that had never been entered by a test — 25 lines
--- of the client, including who gets named as the killer, with nothing
--- checking any of it. It is the report the server corroborates a contract
--- payout against, so getting it wrong is getting paid wrong.
---
--- The design worth holding: the VICTIM reports who killed them. A killer's
--- claim about their own kill is exactly what an attacker forges; a victim
--- has no reason to hand credit to the person who shot them.
describe('reporting your own death', function()
    local function watching(opts)
        opts = opts or {}
        Env.reset()
        Natives.resetResourceStates()
        require('crimson-hitman.shared.util').resetMonotonic()
        -- Source 3 is the local player: PlayerPedId returns 1003.
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        Client.boot()
        Client.ped = 1003
        Client.dead = false
        return Client
    end

    --- How many times an event was sent, and what it carried.
    ---
    --- Counted separately from the payload on purpose: iRevived carries no
    --- argument and a death with nobody to name carries nil, so appending
    --- the value to a list counts neither of them. Written that way first,
    --- three of these tests reported zero events and looked like bugs in
    --- the client rather than in the helper.
    local function reported(name)
        local count, values = 0, {}
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-hitman:' .. name then
                count = count + 1
                values[count] = call.args[1]
            end
        end
        return count, values
    end

    it('says nothing while the player is alive', function()
        watching()
        Client.ticks(3)
        eq(reported('iDied'), 0)
        eq(reported('iRevived'), 0)
    end)

    it('reports a death, and who caused it', function()
        watching()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k',
            firstname = 'Vic', lastname = 'Marlowe' })
        Client.dead = true
        Env.players[3]._killerPed = 1004

        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1, 'one death, one report')
        eq(said[1], 4, 'the server id of whoever killed them')
    end)

    it('reports a death with nobody named when the world killed them', function()
        watching()
        Client.dead = true
        Env.players[3]._killerPed = 0

        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1)
        eq(said[1], nil,
            'falling off a building names nobody, and must not name anybody')
    end)

    it('names nobody when the player killed themselves', function()
        -- Their own ped is not somebody else, and crediting a contract to the
        -- target for dying is the whole reason this check is here.
        watching()
        Client.dead = true
        Env.players[3]._killerPed = 1003

        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1, 'the death is still reported')
        eq(said[1], nil, 'with nobody named')
    end)

    it('names nobody when a ped that is not a player killed them', function()
        -- An NPC, an animal, a car. NetworkGetPlayerIndexFromPed on a ped
        -- that is not a player does not answer "nobody" — it answers with a
        -- number, and that number is somebody's server id. Without the
        -- IsPedAPlayer guard a player killed by a pedestrian credits the
        -- kill to whoever happens to hold that index, which on a contract is
        -- a payout to an uninvolved player.
        watching()
        Client.dead = true
        Env.players[3]._killerPed = 2500

        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1, 'the death is still reported')
        eq(said[1], nil, 'and it names nobody')
    end)

    it('does not report the same death on every tick', function()
        watching()
        Client.dead = true
        Env.players[3]._killerPed = 1004
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })

        Client.ticks(25)
        eq(reported('iDied'), 1, 'twenty-five ticks, one death')
    end)

    it('reports getting back up, once', function()
        watching()
        Client.dead = true
        Client.ticks(2)
        eq(reported('iDied'), 1)

        Client.dead = false
        Client.ticks(5)
        eq(reported('iRevived'), 1, 'one revival, however many ticks follow it')
    end)

    it('reports a second death after a revival', function()
        watching()
        Client.dead = true
        Client.ticks(2)
        Client.dead = false
        Client.ticks(5)
        Client.dead = true
        Client.ticks(2)

        eq(reported('iDied'), 2, 'dying twice is two reports')
        eq(reported('iRevived'), 1)
    end)

    --- sc-ambulance's own sequence, as its client runs it. The engine kills
    --- the ped when the player goes down; the resource resurrects it into
    --- last stand (inlaststand in the metadata); and only when they bleed
    --- out or are finished does it write isdead, resurrecting the ped again.
    --- The client used to report the engine death at the downing, which the
    --- server refuses because last stand is not dead, and then had nothing
    --- left to report when the player really died.
    local function underMedical(meta)
        Client.playerData = { metadata = meta or {} }
        return Client.playerData.metadata
    end

    it('does not spend the death report on being downed', function()
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        Env.players[3]._killerPed = 1004

        -- Shot: the engine death, then last stand.
        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand = true
        Client.ticks(3)
        eq(reported('iDied'), 0, 'downed is not dead')
        eq(reported('iRevived'), 0, 'and not yet up')
    end)

    it('reports the death when the medical resource declares it, once', function()
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        Env.players[3]._killerPed = 1004

        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand = true
        Client.ticks(2)

        -- Bled out, minutes later. The ped has been resurrected again, and
        -- its source of death is no longer the hitman's.
        Env.gameTimer = Env.gameTimer + 300000
        Env.players[3]._killerPed = 0
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(5)
        local count, said = reported('iDied')
        eq(count, 1, 'one death, reported once')
        eq(said[1], nil, 'naming nobody: the downing was not the death, and the '
            .. 'server has its own record of who landed the last hit')

        meta.isdead = false
        Client.ticks(5)
        eq(reported('iRevived'), 1, 'and the hospital revive is reported once')
    end)

    it('names whoever finished them over whoever downed them', function()
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        Env.addPlayer({ source = 5, citizenid = 'KILLER02', license = 'license:k2' })
        Env.players[3]._killerPed = 1004

        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand = true
        Client.ticks(1)

        -- The finishing shot: a second engine death, by somebody else.
        Env.players[3]._killerPed = 1005
        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1)
        eq(said[1], 5, 'the finisher')
    end)

    it('names nobody for a finish it did not see, rather than whoever downed them', function()
        -- The watcher looks once a second, and the medical resource can
        -- resurrect a finished player inside that second (on a stretcher,
        -- in a stopped car). The engine death is never seen, and the
        -- resurrected ped's source of death says nothing reliable. Naming
        -- the player who downed them gave the kill to them when somebody
        -- else finished it; naming nobody leaves it to the server's own
        -- damage log, which holds the finishing hit.
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        Env.addPlayer({ source = 5, citizenid = 'KILLER02', license = 'license:k2' })
        Env.players[3]._killerPed = 1004
        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand = true
        Client.ticks(1)

        Env.gameTimer = Env.gameTimer + 20000
        Env.players[3]._killerPed = 1004
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1)
        eq(said[1], nil, 'not the player who downed them twenty seconds ago')
    end)

    it('does not read the moment between the downing and last stand as a revive', function()
        -- The engine death, then the resurrect, then last stand set a round
        -- trip later: a tick in between saw nobody dead and nobody down.
        watching()
        local meta = underMedical()
        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        Client.ticks(1)
        meta.inlaststand = true
        Client.ticks(2)
        eq(reported('iRevived'), 0, 'a revive that never happened')
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(1)
        eq(reported('iDied'), 1)
    end)

    it('keeps a dead player dead while the medical resource restarts', function()
        watching()
        local meta = underMedical()
        meta.isdead = true
        Client.ticks(1)
        eq(reported('iDied'), 1)

        Natives.resourceStates['sc-ambulance'] = 'stopped'
        Client.ticks(6)
        eq(reported('iRevived'), 0, 'still dead by the metadata the restart left')
        Natives.resourceStates['sc-ambulance'] = 'started'
        Client.ticks(2)
        eq(reported('iDied'), 1, 'and the same death is not reported twice')
    end)

    it('reports no revive for somebody picked up from last stand', function()
        -- They never died, so there is no death to undo; the server takes a
        -- revive from a player it never saw dead as a probe, and posted it
        -- to the staff webhook as one.
        watching()
        local meta = underMedical()
        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand = true
        Client.ticks(2)
        meta.inlaststand = false
        Client.ticks(5)
        eq(reported('iDied'), 0)
        eq(reported('iRevived'), 0, 'picked up by a medic, never dead')
    end)

    it('does not read a defibrillator bringing them round as a revive', function()
        -- Dead, then last stand: sc-ambulance clears isdead a second or more
        -- before it writes inlaststand. A revive read in that gap gave a
        -- target still on the floor five minutes of immunity.
        watching()
        local meta = underMedical()
        meta.isdead = true
        Client.ticks(1)
        eq(reported('iDied'), 1)
        meta.isdead = false
        Client.ticks(2)
        meta.inlaststand = true
        Client.ticks(3)
        eq(reported('iRevived'), 0, 'still down, in last stand')
        meta.inlaststand = false
        Client.ticks(5)
        eq(reported('iRevived'), 1, 'and up for real later')
    end)

    it('does not carry a death over to the next character', function()
        -- /relog while dead, then an alive character: reported as a revive
        -- the server never saw a death for, and posted to staff as a probe.
        watching()
        local meta = underMedical()
        meta.isdead = true
        Client.ticks(2)
        eq(reported('iDied'), 1)
        Client.fire('qbx_core:client:playerLoggedOut')
        meta.isdead = false
        Client.ticks(10)
        eq(reported('iRevived'), 0, 'the new character reported a revive')
    end)

    it('watches nobody while no character is loaded', function()
        -- 17mov's character selection, between unload and the next load.
        -- qbx_core's own player data still holds the last character there,
        -- and one who logged out dead read as a fresh death, then the next
        -- character standing up as a revive the server had no death for.
        watching()
        local meta = underMedical()
        Client.fire('QBCore:Client:OnPlayerUnload')
        Client.state.isLoggedIn = false
        meta.isdead = true
        Client.ticks(3)
        eq(reported('iDied'), 0, 'no death reported for nobody')

        meta.isdead = false
        Client.state.isLoggedIn = true
        Client.ticks(10)
        eq(reported('iRevived'), 0, 'the next character has nothing to recover from')
    end)

    it('reports a second death after a defibrillator, and one revive', function()
        -- Shocked back to last stand, then finished on the ground. The one
        -- death report stayed spent until they stood up, so the hitman who
        -- finished them was never credited.
        watching()
        local meta = underMedical()
        meta.isdead = true
        Client.ticks(1)
        eq(reported('iDied'), 1)
        meta.isdead, meta.inlaststand = false, true
        Client.ticks(5)
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(2)
        eq(reported('iDied'), 2, 'the second death is reported')
        eq(reported('iRevived'), 0, 'never up in between')
        meta.isdead = false
        Client.ticks(5)
        eq(reported('iRevived'), 1, 'and one revive when they stand up')
    end)

    it('reports a finish seconds after a defibrillator', function()
        -- Shocked to last stand and finished two seconds later, inside the
        -- wait the re-arm used to need.
        watching()
        local meta = underMedical()
        meta.isdead = true
        Client.ticks(1)
        meta.isdead = false                 -- the gap
        Client.ticks(1)
        meta.inlaststand = true             -- last stand
        Client.ticks(1)
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(1)
        eq(reported('iDied'), 2, 'the finishing death went unreported')
        eq(reported('iRevived'), 0)
    end)

    it('names the finisher of a body raised in the same frame', function()
        -- In a car or on a stretcher sc-ambulance raises a dead player at
        -- once: the engine death lasts a frame and the watcher never sees
        -- it. The game's own damage event does.
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        meta.inlaststand = true
        Client.ticks(1)
        local fire = Client.handlers['gameEventTriggered']
        truthy(fire, 'nothing listens for the game\'s damage event')
        -- As build 3258 sends it: victim, attacker, damage, two values later
        -- builds added, then "the victim died", then the weapon.
        fire('CEventNetworkEntityDamage', { 1003, 1004, 1109393408, 0, 0, 1, 453432689, 0, 0, 0, 0, 0, 0 })
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(1)
        local count, said = reported('iDied')
        eq(count, 1)
        eq(said[1], 4, 'the finisher went unnamed')
    end)

    it('does not read a hit that did not kill as the killer', function()
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        meta.inlaststand = true
        Client.ticks(1)
        Client.handlers['gameEventTriggered']('CEventNetworkEntityDamage',
            { 1003, 1004, 1109393408, 0, 0, 0, 453432689, 0, 0, 0, 0, 0, 0 })
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(1)
        local _, said = reported('iDied')
        eq(said[1], nil, 'a graze was taken for the killing shot')
    end)

    it('names nobody for a bleed-out', function()
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        -- Downed by them, long ago.
        Client.handlers['gameEventTriggered']('CEventNetworkEntityDamage',
            { 1003, 1004, 1109393408, 0, 0, 1, 453432689, 0, 0, 0, 0, 0, 0 })
        meta.inlaststand = true
        Client.ticks(1)
        Env.gameTimer = Env.gameTimer + 400000
        meta.inlaststand, meta.isdead = false, true
        Client.ticks(1)
        local _, said = reported('iDied')
        eq(said[1], nil, 'a bleed-out was credited to whoever downed them')
    end)

    it('does not report a flicker of the death flag as a second death', function()
        watching()
        local meta = underMedical()
        meta.isdead = true
        Client.ticks(1)
        meta.isdead = false
        Client.ticks(2)
        meta.isdead = true
        Client.ticks(2)
        eq(reported('iDied'), 1, 'one death, however the flag blinks')
    end)

    it('forgets who downed them once they are back up', function()
        watching()
        local meta = underMedical()
        Env.addPlayer({ source = 4, citizenid = 'KILLER01', license = 'license:k' })
        Env.players[3]._killerPed = 1004
        Client.dead = true
        Client.ticks(1)
        Client.dead = false
        meta.inlaststand = true
        Client.ticks(1)
        meta.inlaststand = false
        Client.ticks(5)

        -- Later, dead of something that names nobody.
        Env.players[3]._killerPed = 0
        meta.isdead = true
        Client.ticks(2)
        local count, said = reported('iDied')
        eq(count, 1)
        eq(said[1], nil, 'the earlier downing is not this death')
    end)

    it('reads the state bags qbx_medical writes', function()
        -- Its isDead bag is true in last stand too; its deathState says
        -- which: 2 in last stand, 3 dead.
        watching()
        underMedical()
        Natives.resourceStates['qbx_medical'] = 'started'
        Client.state.isDead = true
        Client.state['qbx_medical:deathState'] = 2
        Client.ticks(2)
        eq(reported('iDied'), 0, 'last stand is not dead')
        Client.state['qbx_medical:deathState'] = 3
        Client.ticks(2)
        eq(reported('iDied'), 1)
        Client.state.isDead = false
        Client.state['qbx_medical:deathState'] = 1
        Client.ticks(5)
        eq(reported('iRevived'), 1)
    end)

    --- The export carried this player's whole record across the resource
    --- boundary once a second, on every client, for the whole session.
    --- qbx_core's modules/playerdata.lua keeps the same data in QBX.PlayerData
    --- from the SetPlayerData event qbx_core sends with every change.
    it('reads the medical state from QBX.PlayerData, never through the export', function()
        watching()
        local meta = underMedical()
        Client.ticks(2)
        meta.isdead = true
        Client.ticks(2)
        eq(reported('iDied'), 1, 'the death the module holds is reported')
        eq(#Client.coreCalls, 0,
            'and no qbx_core export was asked: ' .. table.concat(Client.coreCalls, ', '))

        local f = assert(io.open('crimson-hitman/fxmanifest.lua', 'r'))
        local block = f:read('*a'):match('client_scripts%s*{(.-)}') or ''
        f:close()
        local module = block:find("'@qbx_core/modules/playerdata.lua'", 1, true)
        local main = block:find("'client/main.lua'", 1, true)
        truthy(module and main and module < main,
            'the manifest loads the module before client/main.lua, or QBX is nil there')
    end)

    it('falls back to the engine when the medical state cannot be read', function()
        -- sc-ambulance running, but qbx_core's player data unavailable.
        -- Waiting on a state that never arrives would report no death ever.
        watching()
        Client.playerData = nil
        Client.dead = true
        Client.ticks(2)
        eq(reported('iDied'), 1)
    end)

    it('goes by the engine when no medical resource is running', function()
        watching()
        local meta = underMedical()
        Natives.resourceStates['sc-ambulance'] = 'stopped'
        Natives.resourceStates['qbx_medical'] = 'missing'
        Client.dead = true
        Client.ticks(2)
        eq(reported('iDied'), 1, 'the engine death is the death')
        meta.isdead = false
        Client.dead = false
        Client.ticks(5)
        eq(reported('iRevived'), 1)
    end)

    it('knows the medical resources when the config does not name them', function()
        watching()
        local meta = underMedical()
        local saved = Config.Completion.DeathStateProviders
        Config.Completion.DeathStateProviders = nil
        local ok, err = pcall(function()
            Client.dead = true
            Client.ticks(1)
            Client.dead = false
            meta.inlaststand = true
            Client.ticks(2)
            eq(reported('iDied'), 0, 'still sc-ambulance rules: downed is not dead')
        end)
        Config.Completion.DeathStateProviders = saved
        if not ok then error(err, 0) end
    end)
end)

--- Whether the player wears a mask, which only their own game can see.
---
--- The nearby list leaves masked people off, and the server has no way to
--- read clothes: GetPedDrawableVariation is a client native. The client
--- reads its own ped and says, when the answer changes; the server counts
--- one that has said nothing as masked.
describe('saying whether you wear a mask', function()
    local function watching()
        Env.reset()
        Natives.resetResourceStates()
        require('crimson-hitman.shared.util').resetMonotonic()
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        Client.boot()
        Client.ped = 1003
        Client.dead = false
        return Client
    end

    --- Every mask report sent, in order.
    local function said()
        local out = {}
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-hitman:maskState' then out[#out + 1] = call.args[1] end
        end
        return out
    end

    local NEARBY_ON = { { Config.Targeting, 'AllowNearby', true } }

    it('says nothing while the nearby list is off, as shipped', function()
        watching()
        Client.ticks(3)
        eq(#said(), 0, 'nothing reads it, so nothing is sent')
    end)

    it('says once what the game shows, and again only when it changes', function()
        watching()
        withConfig(NEARBY_ON, function()
            Client.ticks(3)
            eq(#said(), 1, 'one report for three looks')
            eq(said()[1], false, 'bare face: the mask component draws nothing')

            Client.drawables = { [1] = 52 }
            Client.ticks(3)
            eq(#said(), 2, 'the mask going on is said once')
            eq(said()[2], true)

            Client.drawables = nil
            Client.ticks(2)
            eq(#said(), 3)
            eq(said()[3], false, 'and coming off')
        end)
    end)

    it('says it again for the next character after a logout', function()
        watching()
        withConfig(NEARBY_ON, function()
            Client.ticks(2)
            eq(#said(), 1)
            -- The server forgets it at logout; the selector says nothing.
            Client.state.isLoggedIn = false
            Client.ticks(3)
            eq(#said(), 1, 'nothing is said with no character loaded')
            Client.state.isLoggedIn = true
            Client.ticks(2)
            eq(#said(), 2, 'the new character says it, unchanged as it is')
            eq(said()[2], false)
        end)
    end)

    it('counts a mask it cannot read as worn', function()
        watching()
        withConfig(NEARBY_ON, function()
            Client.drawableThrows = true
            Client.ticks(2)
            eq(#said(), 1)
            eq(said()[1], true, 'an unreadable mask is not a bare face')
        end)
    end)

    it('leaves the clothing native behind on no server', function()
        watching()
        withConfig(NEARBY_ON, function() Client.ticks(2) end)
        eq(_G.GetPedDrawableVariation, nil,
            'a client-only native left as a global is one every server spec after this could call')
    end)
end)

--- The admin panel's page (client/admin.lua). It opens only on the
--- server's word, holds the focus while it is open, and gives it back
--- whichever way it closes; every request the page makes is answered,
--- once, on every path.
describe('the admin panel page', function()
    local function booted()
        Env.reset()
        Client.boot()
        return Client
    end

    local function opened()
        booted()
        Client.fire('crimson-hitman:adminOpen', { canWrite = true })
        return Client
    end

    local function lastFocus()
        return Client.focus[#Client.focus]
    end

    local function sent(type_)
        for i = #Client.nuiMessages, 1, -1 do
            if Client.nuiMessages[i].type == type_ then return Client.nuiMessages[i] end
        end
        return nil
    end

    it('opens only on the server\'s word, with the focus, asked for again five times', function()
        booted()
        eq(Client.admin.isOpen(), false)
        Client.fire('crimson-hitman:adminOpen', 'not a table')
        eq(Client.admin.isOpen(), false, 'an event that is not the server\'s shape opens nothing')
        eq(#Client.focus, 0)

        local before = #Env.threads
        Client.fire('crimson-hitman:adminOpen', { canWrite = false, canIdentify = false })
        eq(Client.admin.isOpen(), true)
        eq(lastFocus().focus, true)
        eq(lastFocus().cursor, true)
        eq(sent('open').access.canWrite, false, 'the page is told what this player may do')

        -- The page's own two threads, as the engine runs them: the focus
        -- asked for again, then the Escape watch, which closes it on its
        -- first frame with Escape released in the game, and ends once its
        -- guard after closing has run out. Not the client's other loops,
        -- which never end. A frame is 16 ms of the game's clock.
        Client.released[200] = true
        local realWait = _G.Wait
        _G.Wait = function() Env.gameTimer = Env.gameTimer + 16 end
        for i = before + 1, #Env.threads do Env.threads[i]() end
        _G.Wait = realWait
        local asked = 0
        for _, call in ipairs(Client.focus) do if call.focus then asked = asked + 1 end end
        eq(asked, 6, 'once, then five more times')
        eq(Client.admin.isOpen(), false, 'Escape in the game closes it')
        eq(lastFocus().focus, false, 'and gives the focus back')
        eq(lastFocus().cursor, false)
        truthy(sent('close'), 'and the page is told')
    end)

    it('holds the pause keys off for a moment after it closes, so the key that closed it opens nothing', function()
        booted()
        local before = #Env.threads
        Client.fire('crimson-hitman:adminOpen', { canWrite = true })
        local calls = {}
        local realDisable, realWait = _G.DisableControlAction, _G.Wait
        _G.DisableControlAction = function(_, control)
            calls[#calls + 1] = { control = control, at = Env.gameTimer, open = Client.admin.isOpen() }
        end
        _G.Wait = function() Env.gameTimer = Env.gameTimer + 16 end
        Client.released[322] = true
        -- The Escape watch is the last thread the open queued.
        Env.threads[#Env.threads]()
        _G.DisableControlAction, _G.Wait = realDisable, realWait
        truthy(#Env.threads > before, 'a watch was queued')
        eq(Client.admin.isOpen(), false, 'the key closed it')

        local after, first, last = {}, nil, nil
        for _, call in ipairs(calls) do
            if not call.open then
                after[call.control] = true
                first = first or call.at
                last = call.at
            end
        end
        truthy(after[200] and after[322], 'both pause keys held off after it closed')
        truthy(last - first >= 300, 'for a moment: ' .. tostring(last - first) .. ' ms')
        truthy(last - first < 500, 'and no longer: the watch ended')
    end)

    it('starts no second watch when it opens again while the first still trails', function()
        opened()
        Client.nuiCall('adminClose', {})
        local before = #Env.threads
        Client.fire('crimson-hitman:adminOpen', { canWrite = true })
        eq(#Env.threads - before, 1, 'the focus asked for again, and the watch already running carries on')
        eq(Client.admin.isOpen(), true)
    end)

    it('runs one Escape watch however often the server says to open', function()
        opened()
        local before = #Env.threads
        Client.fire('crimson-hitman:adminOpen', { canWrite = true })
        eq(#Env.threads - before, 1, 'the focus asked for again, and no second watch')
        eq(Client.admin.isOpen(), true)
    end)

    it('closes from the page, and answers it', function()
        opened()
        local answered, answer = Client.nuiCall('adminClose', {})
        truthy(answered)
        eq(answer.ok, true)
        eq(Client.admin.isOpen(), false)
        eq(lastFocus().focus, false)
    end)

    it('gives the focus back when this resource stops, and not when another does', function()
        opened()
        Client.fire('onResourceStop', 'some-other-resource')
        eq(Client.admin.isOpen(), true)
        Client.fire('onResourceStop', 'crimson-hitman')
        eq(Client.admin.isOpen(), false)
        eq(lastFocus().focus, false)
    end)

    it('sends a request on, and answers the page once with what the server said', function()
        opened()
        local answered = Client.nuiCall('adminRequest', { op = 'overview', data = { page = 2 } })
        falsy(answered, 'waits for the server')
        local request = Client.toServer[#Client.toServer]
        eq(request.name, 'crimson-hitman:admin')
        eq(request.args[1].op, 'overview')
        eq(request.args[1].data.page, 2)
        local rid = request.args[1].__rid
        truthy(rid)

        Client.fire('crimson-hitman:adminResult', { rid = rid, ok = true, message = 'fine',
            data = { total = 3 }, extra = 'dropped' })
        truthy(Client.answered)
        eq(Client.answer.ok, true)
        eq(Client.answer.message, 'fine')
        eq(Client.answer.data.total, 3)
        eq(Client.answer.extra, nil, 'only what the page is promised')
        Client.fire('crimson-hitman:adminResult', { rid = rid, ok = false })
        eq(Client.answerCount, 1, 'answered once')
    end)

    it('answers on every path: closed, a bad op, a timeout, and closing with one waiting', function()
        booted()
        local answered, answer = Client.nuiCall('adminRequest', { op = 'overview' })
        truthy(answered)
        eq(answer.err, 'closed', 'a page asking while closed')

        Client.fire('crimson-hitman:adminOpen', {})
        answered, answer = Client.nuiCall('adminRequest', { data = {} })
        eq(answer.err, 'invalid_input')
        answered, answer = Client.nuiCall('adminRequest', { op = string.rep('x', 40) })
        eq(answer.err, 'invalid_input')
        answered, answer = Client.nuiCall('adminRequest', 'not a table')
        eq(answer.err, 'invalid_input')

        Client.nuiCall('adminRequest', { op = 'logs' })
        Client.runTimeouts()
        eq(Client.answer.err, 'timeout', 'a server that never answers')
        eq(Client.answerCount, 1)

        Client.nuiCall('adminRequest', { op = 'logs' })
        Client.admin.close()
        eq(Client.answer.err, 'closed', 'closing answers what was still waiting')
        eq(Client.answerCount, 1)
        Client.runTimeouts()
        eq(Client.answerCount, 1, 'and its timeout answers nothing again')
    end)

    it('ignores a result it did not ask for, and one that is not a table', function()
        opened()
        truthy(Client.fire('crimson-hitman:adminResult', 'junk') ~= false)
        truthy(Client.fire('crimson-hitman:adminResult', { rid = 999, ok = true }) ~= false)
    end)

    it('passes a line pushed for it to the open page, and nothing to a closed one', function()
        opened()
        Client.fire('crimson-hitman:adminPush', { kind = 'diag', line = 'photo links: yes' })
        eq(sent('push').line, 'photo links: yes')
        Client.admin.close()
        Client.nuiMessages = {}
        Client.fire('crimson-hitman:adminPush', { kind = 'diag', line = 'late' })
        eq(sent('push'), nil)
    end)
end)

--- Settings staff changed from the admin panel that this game reads.
describe('settings the server says this game reads', function()
    it('takes the keys it reads, in their types, and nothing else', function()
        Env.reset()
        Client.boot()
        local ok, err = pcall(function()
            Client.fire('crimson-hitman:settings', 'junk')
            Client.fire('crimson-hitman:settings', {
                ['Targeting.AllowNearby'] = 'yes',
                ['Mugshot.RemoveBackground'] = true,
                ['App.DefaultInstalled'] = true,
                ['Database.Mode'] = 'mysql',
            })
            eq(Config.Mugshot.RemoveBackground, true)
            eq(Config.App.DefaultInstalled, true)
            eq(Config.Targeting.AllowNearby, false, 'a switch is a boolean or nothing')
            eq(Config.Database.Mode, 'json', 'and a key it does not read is left alone')
        end)
        resetConfig()
        if not ok then error(err, 0) end
    end)

    it('starts saying whether a mask is on when the nearby list is turned on', function()
        Env.reset()
        Natives.resetResourceStates()
        require('crimson-hitman.shared.util').resetMonotonic()
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        Client.boot()
        Client.ped = 1003
        local ok, err = pcall(function()
            Client.fire('crimson-hitman:settings', { ['Targeting.AllowNearby'] = true })
            Client.ticks(2)
            local reports = 0
            for _, call in ipairs(Client.toServer) do
                if call.name == 'crimson-hitman:maskState' then reports = reports + 1 end
            end
            eq(reports, 1, 'said once, by the watch the setting started')
        end)
        resetConfig()
        if not ok then error(err, 0) end
    end)
end)

--- W004, W085, W091: the pass a login schedules to hand over what a player
--- is owed (Bridges scheduleReady and onPlayerReady).
describe('the pass a login schedules', function()
    local function wired()
        local s = newStack()
        s.bridges.install(s)
        return s
    end

    local function login(src)
        _G.source = src
        Env.events['QBCore:Server:OnPlayerLoaded']()
        _G.source = nil
    end

    local function lockpicks(src)
        local n = 0
        for _, slot in ipairs(Env.players[src]._inventory or {}) do
            if slot.name == 'lockpick' then n = n + (slot.count or 0) end
        end
        return n
    end

    it('leaves no timer behind for players who log in and leave while recovery has failed', function()
        local s = wired()
        fixture(s)
        s.app.ready, s.app.recoveryFailed = false, true
        local before = #Env.timers
        for src = 1, 3 do login(src) end
        Env.advance(10)
        for src = 1, 3 do
            _G.source = src
            Env.handlers['playerDropped']()
            _G.source = nil
        end
        Env.advance(60)
        eq(#Env.timers, before, 'a timer each, re-arming every few seconds for good')
    end)

    it('a pass that raises leaves the payout to the tick, and still says what happened', function()
        local s = wired()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, { baseline = { items = { { name = 'lockpick', count = 2 } } } })
        s.escrow.take(f.creator, 'ct1', lines)
        Env.players[3]._inventoryFull = true
        s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
        Env.players[3]._inventoryFull = false
        -- Offline at a tick, which forgets them until a login says otherwise.
        s.escrow.retryWaiting(function() return false end)

        local real, told = s.storage.readPending, false
        s.storage.readPending = function(...)
            s.storage.readPending = real
            error('mysql: connection lost', 0)
        end
        local deliver = s.notify.deliverWaiting
        s.notify.deliverWaiting = function(...) told = true return deliver(...) end
        falsy(pcall(s.bridges.onPlayerReady, s, 3), 'the pass raised')
        s.notify.deliverWaiting = deliver
        truthy(told, 'what happened while they were away is told even so')

        Env.advance(30)
        s.escrow.retryWaiting(function() return true end)
        eq(lockpicks(3), 2, 'the tick hands it over: it waited for a relog')
    end)

    it('waits the configured delay and up to two seconds more', function()
        local s = wired()
        fixture(s)
        local reads = 0
        local real = s.storage.readPending
        s.storage.readPending = function(...) reads = reads + 1 return real(...) end
        local random = math.random
        math.random = function(a, b) if a == 0 and b == 2000 then return 2000 end return random(a, b) end
        login(3)
        math.random = random
        Env.advance(Config.PendingEscrow.LoginRetryDelayMs / 1000 + 1)
        eq(reads, 0, 'every player at once after a restart: no spread at all')
        Env.advance(1.5)
        eq(reads, 1)
    end)
end)

--- The handover's meeting point (server/meeting.lua): where the placer
--- stands is read by their own game on the tap, never taken from the page;
--- and Set GPS marks the point on the hitman's map without handing the page
--- the coordinates.
describe('the handover meeting point on the client', function()
    it('sends where the character stands, never what the page sent', function()
        Env.reset()
        Client.boot()
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01' })
        Env.players[3]._coords = { x = 1234.4, y = -567.6, z = 30.0 }
        Client.nuiCall('crimson:setMeeting', { id = 'ct00000001', x = 1, y = 2, z = 3 })
        local asked = Client.toServer[#Client.toServer]
        eq(asked.name, 'crimson-hitman:setMeeting')
        eq(asked.args[1].id, 'ct00000001')
        eq(asked.args[1].x, 1234.4, 'its own read, not the page\'s')
        eq(asked.args[1].y, -567.6)
        eq(asked.args[1].z, 30.0)
        truthy(Client.fire('crimson-hitman:result', { rid = asked.args[1].__rid,
            event = 'setMeeting', ok = true, data = { set = true, moved = false } }))
        truthy(Client.answered, 'the page is answered')
        eq(Client.answer.ok, true)
    end)

    it('marks Set GPS on the map and hands the page no coordinates', function()
        Env.reset()
        Client.boot()
        local marked, real = {}, _G.SetNewWaypoint
        _G.SetNewWaypoint = function(x, y) marked[#marked + 1] = { x = x, y = y } end
        Client.nuiCall('crimson:meetingGps', { id = 'ct00000001' })
        local asked = Client.toServer[#Client.toServer]
        eq(asked.name, 'crimson-hitman:meetingWaypoint')
        Client.fire('crimson-hitman:result', { rid = asked.args[1].__rid,
            event = 'meetingWaypoint', ok = true, data = { x = 1234, y = -568 } })
        eq(#marked, 1, 'marked once')
        eq(marked[1].x, 1234)
        eq(marked[1].y, -568)
        truthy(Client.answered)
        eq(Client.answer.ok, true)
        eq(Client.answer.data, nil, 'the page is told it was marked, and nothing of where')

        Client.nuiCall('crimson:meetingGps', { id = 'ct00000001' })
        asked = Client.toServer[#Client.toServer]
        Client.fire('crimson-hitman:result', { rid = asked.args[1].__rid,
            event = 'meetingWaypoint', ok = false, err = 'no_meeting' })
        _G.SetNewWaypoint = real
        eq(#marked, 1, 'nothing marked on a refusal')
        eq(Client.answer.err, 'no_meeting', 'and the page is told why')
    end)
end)
