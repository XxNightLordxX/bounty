--- A kill photo taken in the app and kept on this server
--- (Config.Completion.PhotoStorage = 'server').
---
--- No image host is involved. The page takes the picture, the client sends
--- it with the token it holds, and the server checks it, keeps it as a file
--- in data/photos/ named for its own handle, and sends it to the client's
--- phone, once, when they open it. Every way a photo ends removes its file,
--- and a start removes any file nothing names.
---
--- Most specs photograph kills with a link ('host' storage, see run.lua);
--- this one sends pictures.

local Util = require('crimson-hitman.shared.util')

--- Bytes that start the way each kind of picture starts, with NUL bytes
--- in them: SaveResourceFile's -1 length stops at the first, and a JPEG
--- has one in its fifth byte.
local JPEG = '\255\216\255\224\0\16JFIF\0\1\1\0\0\1' .. ('\0\7\255kill'):rep(40)
local PNG = '\137PNG\r\n\26\n\0\0\0\13IHDR' .. ('\0\0body'):rep(40)
local WEBP = 'RIFF\0\0\0\0WEBPVP8 ' .. ('\0scene'):rep(40)

local function uri(mime, bytes)
    return 'data:' .. mime .. ';base64,' .. Util.toBase64(bytes)
end

--- A contract, an accepted hitman and a kill the server saw, on a server
--- that keeps its photos itself.
local function killed(opts)
    opts = opts or {}
    local s = newStack()
    -- The fake disk outlives a stack; each test starts with an empty one.
    Natives.files = {}
    Config.Completion.PhotoStorage = 'server'
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 5000 } },
    })
    truthy(c, 'the contract has to exist')
    truthy(s.contracts.accept(f.hitman, c.id, false))

    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    return s, f, c
end

--- Killed and photographed: the client's photo is waiting, in its file.
local function photographed(opts)
    local s, f, c = killed(opts)
    local token = s.photo.issue(f.hitman, c.id)
    truthy(token, 'the hitman has to be able to photograph the kill')
    local ok, err = s.photo.submit(f.hitman, token, nil, uri('image/jpeg', JPEG))
    truthy(ok, 'the photo has to be accepted: ' .. tostring(err))
    local handle = s.storage.readLedger('CREATOR1', 10)[1].photo_ref
    truthy(handle, 'the client row has to name the photo')
    return s, f, c, handle, 'data/photos/' .. handle .. '.jpg'
end

--- Every photo file on the fake disk.
local function photoFiles()
    local out = {}
    for file in pairs(Natives.files) do
        if file:find('^data/photos/') then out[#out + 1] = file end
    end
    table.sort(out)
    return out
end

--- Fire a handler the way a client does: the reply, and every event the
--- server sent while answering.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER' }, {} end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) }, {} end
    local reply
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then reply = event.args[1] end
    end
    return reply, Env.clientEvents
end

local function latentTo(events, name)
    local out = {}
    for _, event in ipairs(events or {}) do
        if event.name == name then out[#out + 1] = event end
    end
    return out
end

local function flat(value, out)
    out = out or {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            out[#out + 1] = tostring(k)
            flat(v, out)
        end
    elseif value ~= nil then
        out[#out + 1] = tostring(value)
    end
    return table.concat(out, ' ')
end

describe('base64, which the server\'s Lua has to do for itself', function()
    it('turns any bytes into base64 and back, NULs and all', function()
        for _, bytes in ipairs({ '', 'f', 'fo', 'foo', JPEG, PNG, WEBP, '\0\0\0', '\255' }) do
            eq(Util.fromBase64(Util.toBase64(bytes)), bytes, 'round trip of ' .. #bytes .. ' bytes')
        end
        eq(Util.toBase64('fo'), 'Zm8=')
    end)

    it('reads strict base64 and nothing else', function()
        for _, bad in ipairs({ 'Zm9', 'Zm9 ', 'Zg=a', 'Z===', 'Zg==Zg==', 'Zm9v!', 42 }) do
            eq(Util.fromBase64(bad), nil, 'read ' .. tostring(bad))
        end
    end)
end)

describe('a kill photo sent to be kept on this server', function()
    it('keeps the picture whole, in a file named for its handle', function()
        local s, _, _, handle, file = photographed()
        local record = s.storage.readPhoto(handle)
        eq(record.kind, 'file')
        eq(record.file, file)
        eq(record.mime, 'image/jpeg')
        eq(record.size, #JPEG)
        falsy(record.url, 'no link: no image host is involved')
        eq(Natives.files[file], JPEG,
            'written with its length, not cut short at the first NUL byte')
        truthy(Natives.dirs['data/photos'], 'the folder is made before the first write')
        falsy(flat(record):find('HITMAN01', 1, true), 'the record names no hitman')
        falsy(s.storage.readLedger('HITMAN01', 10)[1].photo_ref,
            'and the hitman\'s row carries no photo')
    end)

    it('takes each of the three kinds it keeps', function()
        for mime, bytes in pairs({ ['image/webp'] = WEBP, ['image/png'] = PNG }) do
            local s, f, c = killed()
            local token = s.photo.issue(f.hitman, c.id)
            truthy(s.photo.submit(f.hitman, token, nil, uri(mime, bytes)), mime)
            local handle = s.storage.readLedger('CREATOR1', 10)[1].photo_ref
            local file = s.storage.readPhoto(handle).file
            eq(file, 'data/photos/' .. handle .. '.' .. CH.PHOTO_MIME[mime], mime)
            eq(Natives.files[file], bytes, mime)
        end
    end)

    it('is sent by the client with its token, and says how to take it', function()
        local s, _, c = killed()
        local issued = call('requestPhotoToken', 3, { id = c.id })
        truthy(issued and issued.ok, tostring(issued and issued.err))
        eq(issued.data.storage, 'server', 'the client opens the app\'s viewfinder')
        eq(issued.data.maxSide, Config.Completion.PhotoMaxSide)
        eq(issued.data.maxBytes, Config.Completion.PhotoMaxBytes)

        local paid = call('submitPhoto', 3, { token = issued.data.token, image = uri('image/jpeg', JPEG) })
        truthy(paid and paid.ok, 'the kill is paid on the picture: ' .. tostring(paid and paid.err))
        eq(#photoFiles(), 1)
        falsy(flat(paid):find(Util.toBase64(JPEG):sub(1, 40), 1, true),
            'the hitman is answered with the claim, never the photo')
        truthy(s.storage.readLedger('CREATOR1', 10)[1].photo_ref)
    end)

    local function refused(image, err, mime)
        local s, f, c = killed()
        local cash = Env.players[3].PlayerData.money.cash
        local token = s.photo.issue(f.hitman, c.id)
        local ok, why = s.photo.submit(f.hitman, token, nil, image)
        falsy(ok, 'accepted ' .. tostring(mime))
        eq(why, err, tostring(mime))
        eq(#photoFiles(), 0, 'nothing written for a refused photo')
        eq(Env.players[3].PlayerData.money.cash, cash, 'and nothing paid')
        -- The token is not spent on a picture it could not read: the
        -- hitman takes another and the kill is still theirs.
        truthy(s.photo.submit(f.hitman, token, nil, uri('image/jpeg', JPEG)),
            'a good photo on the same token is still taken')
    end

    it('refuses a picture that is not what it says it is', function()
        refused(uri('image/png', JPEG), CH.ERR.PHOTO_BAD_IMAGE, 'jpeg bytes called png')
        refused(uri('image/webp', 'RIFF\0\0\0\0AVI LIST'), CH.ERR.PHOTO_BAD_IMAGE, 'RIFF, not WEBP')
        refused(uri('image/svg+xml', '<svg onload="x()"/>'), CH.ERR.PHOTO_BAD_IMAGE, 'svg')
        refused(uri('image/gif', 'GIF89a'), CH.ERR.PHOTO_BAD_IMAGE, 'gif')
        refused('data:image/jpeg;base64,not base64 at all', CH.ERR.PHOTO_BAD_IMAGE, 'junk')
        refused('data:image/jpeg;base64,', CH.ERR.PHOTO_BAD_IMAGE, 'empty')
        refused({ image = JPEG }, CH.ERR.PHOTO_BAD_IMAGE, 'a table')
    end)

    it('refuses a link: this server keeps its own photos', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local ok, err = s.photo.submit(f.hitman, token, 'https://cdn.fivemanage.com/proof.png', nil)
        falsy(ok, 'a link would put the photo on an image host the owner chose not to use')
        eq(err, CH.ERR.PHOTO_BAD_IMAGE)
        eq(#s.storage.photosOf('CREATOR1'), 0)
    end)

    it('refuses a picture bigger than it keeps, without decoding it', function()
        local s, f, c = killed()
        Config.Completion.PhotoMaxBytes = 50000
        local decoded = 0
        local real = Util.fromBase64
        Util.fromBase64 = function(...)
            decoded = decoded + 1
            return real(...)
        end
        local token = s.photo.issue(f.hitman, c.id)
        local ok, err = s.photo.submit(f.hitman, token, nil,
            uri('image/jpeg', JPEG .. ('\0'):rep(60000)))
        Util.fromBase64 = real
        falsy(ok)
        eq(err, CH.ERR.PHOTO_TOO_LARGE)
        eq(decoded, 0, 'judged from the length of the text, before any decode')
        eq(#photoFiles(), 0)
    end)

    it('refuses a token that is not this hitman\'s, or not one at all', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local ok, err = s.photo.submit(f.hitman, 'tk-made-up-0001', nil, uri('image/jpeg', JPEG))
        falsy(ok)
        eq(err, CH.ERR.TOKEN_INVALID)
        -- The latent event's source is the actor; another player sending
        -- this hitman's token is not this hitman.
        local theirs = call('submitPhoto', 1, { token = token, image = uri('image/jpeg', JPEG) })
        falsy(theirs.ok, 'somebody else\'s token claimed a payout')
        eq(theirs.err, CH.ERR.TOKEN_INVALID)
        eq(#photoFiles(), 0)
    end)

    it('survives whatever is sent as a picture, and pays nothing for it', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local cash = Env.players[3].PlayerData.money.cash
        for _, image in ipairs({
            42, true, {}, '', 'data:', 'data:image/jpeg;base64',
            'data:image/jpeg;base64,' .. ('/'):rep(4001),
            'data:image/jpeg;base64,/9j/\0AAA',
            'data:' .. ('image/jpeg'):rep(20) .. ';base64,/9j/',
            'data:image/jpeg;base64,' .. ('A'):rep(2000000),
        }) do
            local reply = call('submitPhoto', 3, { token = token, image = image })
            truthy(reply, 'answered')
            falsy(reply.ok, 'accepted ' .. tostring(image):sub(1, 40))
            falsy(tostring(reply.err):find('THREW', 1, true), tostring(reply.err))
            falsy(reply.err == CH.ERR.SERVER_ERROR, 'the handler threw on ' .. tostring(image):sub(1, 40))
        end
        eq(Env.players[3].PlayerData.money.cash, cash)
        eq(#photoFiles(), 0)
    end)

    it('writes nothing when the ledger keeps no photos', function()
        local s, f, c = killed()
        Config.Ledger.StorePhotos = false
        local token = s.photo.issue(f.hitman, c.id)
        truthy(s.photo.submit(f.hitman, token, nil, uri('image/jpeg', JPEG)), 'the kill is still paid')
        eq(#photoFiles(), 0, 'and the picture never reaches the disk')
        eq(#s.storage.photosOf('CREATOR1'), 0)
    end)

    it('pays the kill and says so when the photo cannot be written', function()
        local s, f, c = killed()
        local realSave = _G.SaveResourceFile
        _G.SaveResourceFile = function(res, file, ...)
            if file:find('^data/photos/') then return false end
            return realSave(res, file, ...)
        end
        local token = s.photo.issue(f.hitman, c.id)
        local ok = s.photo.submit(f.hitman, token, nil, uri('image/jpeg', JPEG))
        _G.SaveResourceFile = realSave
        truthy(ok, 'a full disk is no reason to take a verified kill off the hitman')
        eq(#s.storage.photosOf('CREATOR1'), 0, 'no record of a photo that is not there')
        local said = table.concat(Env.console, ' | ')
        truthy(said:find('data/photos', 1, true), 'and the owner is told where to look: ' .. said)
    end)
end)

describe('the client\'s one look at a photo kept on this server', function()
    it('sends the photo to the client alone, as a latent event', function()
        local s, _, _, handle = photographed()
        local reply, events = call('openPhoto', 1, { handle = handle })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(reply.data.handle, handle)
        eq(reply.data.latent, true, 'the reply only says it is on its way')
        falsy(flat(reply):find('base64', 1, true),
            'the photo is not in the reply, which is also mirrored to the page')

        local sent = latentTo(events, 'crimson-hitman:photoImage')
        eq(#sent, 1, 'sent once')
        truthy(sent[1].latent, 'as a latent event, not an ordinary one')
        eq(sent[1].target, 1, 'to the client, and nobody else')
        truthy((sent[1].bps or 0) > 25000, 'faster than FiveM\'s default')
        eq(sent[1].args[1].handle, handle)
        local src = sent[1].args[1].src
        eq(src:sub(1, 23), 'data:image/jpeg;base64,')
        eq(Util.fromBase64(src:sub(24)), JPEG, 'the picture as it was taken')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.OPEN)
    end)

    it('sends it once', function()
        local _, _, _, handle = photographed()
        call('openPhoto', 1, { handle = handle })
        local again, events = call('openPhoto', 1, { handle = handle })
        falsy(again.ok)
        eq(again.err, CH.ERR.PHOTO_GONE)
        eq(#latentTo(events, 'crimson-hitman:photoImage'), 0, 'and nothing is sent the second time')
    end)

    it('answers anybody else exactly as a handle that does not exist, and sends nothing', function()
        for _, src in ipairs({ 2, 3 }) do
            local s, _, _, handle = photographed()
            local unknown = call('openPhoto', src, { handle = 'ph0000000000zz' })
            local theirs, events = call('openPhoto', src, { handle = handle })
            eq(theirs.ok, false)
            eq(theirs.err, unknown.err, 'source ' .. src .. ': the answers must not differ')
            eq(theirs.data, unknown.data)
            eq(#latentTo(events, 'crimson-hitman:photoImage'), 0, 'source ' .. src .. ' was sent the photo')
            eq(s.storage.readPhoto(handle).state, CH.PHOTO.PENDING)
        end
    end)

    it('spends no look on a file that is gone or cut short, and lets it go', function()
        for _, damage in ipairs({ 'gone', 'cut' }) do
            local s, _, _, handle, file = photographed()
            Natives.files[file] = damage == 'cut' and JPEG:sub(1, 4) or nil
            local reply, events = call('openPhoto', 1, { handle = handle })
            falsy(reply.ok, damage)
            eq(reply.err, CH.ERR.PHOTO_GONE, damage)
            eq(#latentTo(events, 'crimson-hitman:photoImage'), 0, damage)
            eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED,
                damage .. ': nothing will ever show it, so it is not left waiting')
            eq(Natives.files[file], nil, damage .. ': what was left of it is removed')
        end
    end)
end)

describe('every way a photo kept on this server ends removes its file', function()
    local function gone(file, how)
        eq(Natives.files[file], nil, how .. ': the file is still on the disk')
        local removed = table.concat(Natives.calls.removed or {}, ' ')
        truthy(removed:find(file, 1, true), how .. ': removed through the resource folder')
    end

    it('when the client deletes it', function()
        local _, _, _, handle, file = photographed()
        call('openPhoto', 1, { handle = handle })
        truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
        gone(file, 'deleted')
    end)

    it('when the client has it on their phone', function()
        local _, _, _, handle, file = photographed()
        call('openPhoto', 1, { handle = handle })
        truthy(call('photoDecision', 1, { handle = handle, choice = 'save' }).ok)
        gone(file, 'saved')
    end)

    it('when it is left open too long', function()
        local s, _, _, handle, file = photographed()
        call('openPhoto', 1, { handle = handle })
        Env.advance(Config.Completion.PhotoOpenSeconds + 5)
        eq(s.photos.expire(), 1)
        gone(file, 'left open')
    end)

    it('when it is never opened', function()
        local s, _, _, handle, file = photographed()
        Env.advance(Config.Ledger.PhotoRetentionDays * 86400 + 1)
        s.ledger.forgetOldPhotos()
        falsy(s.storage.readPhoto(handle))
        gone(file, 'never opened')
    end)

    it('when its row is pushed off the client\'s ledger', function()
        local s, _, _, handle, file = photographed()
        local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
        for i = 1, depth do
            Env.advance(1)
            s.ledger.record({ id = 'cx' .. i, creator_cid = 'OTHER001', target_cid = 'TARGET99',
                target_name = 'Somebody' }, 'CREATOR1', nil, CH.FULFILMENT.KIDNAPPING, { slot = 1 })
        end
        falsy(s.storage.readPhoto(handle))
        gone(file, 'evicted')
    end)

    it('when staff void the contract', function()
        local s, _, c, handle, file = photographed({
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } } })
        truthy(s.admin.void(0, c.id, 'abuse'))
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED)
        gone(file, 'voided')
    end)
end)

describe('the start\'s sweep of photo files nothing names', function()
    it('removes files no record names, and nothing else', function()
        local s, _, _, handle, file = photographed()
        Natives.files['data/photos/ph0000000orphan.webp'] = WEBP
        Natives.files['data/photos/README.md'] = 'notes'
        Natives.files['data/contracts/ct00000001.json'] = '{}'

        eq(s.photos.sweepFiles(), 1)
        eq(Natives.files['data/photos/ph0000000orphan.webp'], nil, 'a file whose record was lost')
        eq(Natives.files[file], JPEG, 'the waiting photo is kept')
        eq(Natives.files['data/photos/README.md'], 'notes', 'a name this resource never gives is left')
        eq(Natives.files['data/contracts/ct00000001.json'], '{}', 'and nothing outside the folder is looked at')
        eq(s.photos.sweepFiles(), 0, 'running it again removes nothing more')
        truthy(s.storage.readPhoto(handle))
    end)

    it('removes the file of a photo already closed', function()
        local s, _, _, handle, file = photographed()
        -- Closed, but the removal failed at the time.
        local realRemove = os.remove
        os.remove = function() return nil, 'busy', 16 end
        call('openPhoto', 1, { handle = handle })
        call('photoDecision', 1, { handle = handle, choice = 'delete' })
        os.remove = realRemove
        eq(Natives.files[file], JPEG, 'the removal that failed left it')
        eq(s.photos.sweepFiles(), 1)
        eq(Natives.files[file], nil, 'and the next start takes it')
    end)

    it('runs at start, before the app answers anybody', function()
        local src = read_file('crimson-hitman/server/main.lua')
        local sweep = src:find('photos.sweepFiles', 1, true)
        local ready = src:find('app.ready = true', 1, true)
        truthy(sweep and ready and sweep < ready,
            'a sweep alongside a kill being verified would remove the file written a moment before its record')
    end)

    it('says so, and removes nothing, on a server that cannot list a folder', function()
        local s = photographed()
        Natives.files['data/photos/ph0000000orphan.webp'] = WEBP
        local real = io.readdir
        io.readdir = nil
        local removed = s.photos.sweepFiles()
        io.readdir = real
        eq(removed, 0)
        truthy(Natives.files['data/photos/ph0000000orphan.webp'])
        truthy(table.concat(Env.console, ' '):find('io.readdir', 1, true))
    end)
end)

describe('the image host allowlist, only where photos come from a host', function()
    -- The report as a player in game is shown it, which runs every check.
    local function diag(s)
        return table.concat(s.admin.diagnose(1) or {}, '\n')
    end

    it('warns of an empty allowlist on a host server, and not on one that keeps its own', function()
        local s = newStack()
        Config.Completion.ExtraPhotoHosts = {}
        Natives.phoneConfig.UploadWhitelistedDomains = {}
        Natives.phoneConfig.UploadWhitelistedHostnames = {}
        local ok = pcall(function()
            Config.Completion.PhotoStorage = 'server'
            Env.console = {}
            s.photo.warnedEmpty = false
            s.photo.loadAllowedHosts()
            falsy(table.concat(Env.console, ' '):find('no photo upload host', 1, true),
                'told to fix an image host this server does not use')

            Config.Completion.PhotoStorage = 'host'
            s.photo.loadAllowedHosts()
            truthy(table.concat(Env.console, ' '):find('no photo upload host', 1, true),
                'a host server with nothing allowed refuses every photo, and is told')
        end)
        Natives.phoneConfig.UploadWhitelistedDomains = { 'fivemanage.com', 'fmfile.com', 'amazonaws.com' }
        Natives.phoneConfig.UploadWhitelistedHostnames = { 'r2.qbox.re' }
        truthy(ok)
    end)

    it('names the storage in /ch-diag, and the hosts only where they matter', function()
        local s = newStack()
        fixture(s)
        Config.Completion.PhotoStorage = 'server'
        local said = diag(s)
        truthy(said:find('photo storage: server', 1, true), said)
        falsy(said:find('photo hosts:', 1, true), 'a hosts line on a server that uses none')

        Config.Completion.PhotoStorage = 'host'
        said = diag(s)
        truthy(said:find('photo storage: host', 1, true), said)
        truthy(said:find('photo hosts:', 1, true), said)
    end)
end)
