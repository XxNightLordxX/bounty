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

--- The client saying the photo it was sent is there, as its photoImage
--- handler does on arrival (client/main.lua).
local function arrived(src, handle)
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:photoArrived'], handle)
    _G.source = nil
    truthy(fired, tostring(err))
end

--- The photo landing: a moment later, as no photo arrives the instant it is
--- sent, and then the client's word.
local function landed(src, handle)
    Env.advance(1)
    arrived(src, handle)
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
            -- A refused picture keeps its charge; each of these is to reach
            -- the checks, not the rate limit.
            s.ratelimit.resetAll()
            local reply = call('submitPhoto', 3, { token = token, image = image })
            truthy(reply, 'answered')
            falsy(reply.ok, 'accepted ' .. tostring(image):sub(1, 40))
            falsy(tostring(reply.err):find('THREW', 1, true), tostring(reply.err))
            falsy(reply.err == CH.ERR.SERVER_ERROR, 'the handler threw on ' .. tostring(image):sub(1, 40))
        end
        eq(Env.players[3].PlayerData.money.cash, cash)
        eq(#photoFiles(), 0)
    end)

    it('refuses text that is not base64 to the end, and padding anywhere but the end', function()
        local good = Util.toBase64(JPEG)
        for label, body in pairs({
            ['a bad last character'] = good:sub(1, -2) .. '!',
            ['a NUL near the end'] = good:sub(1, -5) .. '\0AAA',
            ['padding in the middle'] = good:sub(1, 16) .. '=AAA' .. good:sub(21),
            ['three pads'] = good:sub(1, -4) .. '===',
            ['a space'] = good:sub(1, 20) .. ' ' .. good:sub(22),
        }) do
            local s, f, c = killed()
            local token = s.photo.issue(f.hitman, c.id)
            local ok, err = s.photo.submit(f.hitman, token, nil, 'data:image/jpeg;base64,' .. body)
            falsy(ok, label)
            eq(err, CH.ERR.PHOTO_BAD_IMAGE, label)
        end
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

describe('what a refused picture costs the server', function()
    --- Decoding a picture is base64 in pure Lua, on the server's main thread:
    --- about 60ms for one of the default size. It used to come before every
    --- other check, and a refusal gave the hitman's allowance back, so one
    --- token was worth a full decode for every send the flood guard let
    --- through, from anywhere on the map. A refusal is now judged before the
    --- decode, the server's own facts come first, and a refusal of the
    --- picture keeps its charge.

    --- The largest picture the server keeps, as the page would send it.
    local function largest(head)
        local max = Config.Completion.PhotoMaxBytes
        return uri('image/jpeg', head .. ('\0'):rep(max - #head))
    end

    --- Count the decodes of anything longer than a picture's first sixteen
    --- characters, while `fn` runs.
    local function decodesDuring(fn)
        local real = Util.fromBase64
        local decoded = 0
        Util.fromBase64 = function(text, ...)
            if type(text) == 'string' and #text > 16 then decoded = decoded + 1 end
            return real(text, ...)
        end
        local ok, err = pcall(fn)
        Util.fromBase64 = real
        if not ok then error(err, 0) end
        return decoded
    end

    it('decodes nothing for a hitman away from the body, and gives the try back', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local image = largest(JPEG)
        Env.players[3]._coords = { x = 900.0, y = 100.0, z = 30.0 }

        local errs = {}
        local decoded = decodesDuring(function()
            for i = 1, Config.Cooldowns.photoSubmit.burst + 3 do
                errs[i] = call('submitPhoto', 3, { token = token, image = image }).err
            end
        end)
        eq(decoded, 0, 'a picture sent from 800m away was decoded to be refused')
        for i, err in ipairs(errs) do
            eq(err, CH.ERR.PHOTO_TOO_FAR, 'send ' .. i .. ': a hitman told to move closer can try again')
        end

        -- Back at the body, the same token takes it.
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        local paid = call('submitPhoto', 3, { token = token, image = image })
        truthy(paid.ok, tostring(paid.err))
    end)

    it('reads what kind of picture it is before decoding the rest', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local max = Config.Completion.PhotoMaxBytes
        local ok, err
        local decoded = decodesDuring(function()
            -- Valid base64 of the largest size, and not a jpeg at all.
            ok, err = s.photo.submit(f.hitman, token, nil,
                'data:image/jpeg;base64,' .. ('x'):rep(max // 3 * 4))
        end)
        falsy(ok)
        eq(err, CH.ERR.PHOTO_BAD_IMAGE)
        eq(decoded, 0, 'the wrong kind of picture was decoded in full to be refused')

        decoded = decodesDuring(function()
            local text = Util.toBase64(JPEG .. ('\0'):rep(max - #JPEG))
            ok, err = s.photo.submit(f.hitman, token, nil,
                'data:image/jpeg;base64,' .. text:sub(1, -2) .. '!')
        end)
        falsy(ok)
        eq(err, CH.ERR.PHOTO_BAD_IMAGE)
        eq(decoded, 0, 'a bad character at the very end cost a whole decode to find')
    end)

    it('keeps the charge of a refused picture: the sixth on one token is told to slow down', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local burst = Config.Cooldowns.photoSubmit.burst
        local image = 'data:image/jpeg;base64,' .. ('x'):rep(Config.Completion.PhotoMaxBytes // 3 * 4)

        local errs = {}
        for i = 1, burst + 1 do
            errs[i] = call('submitPhoto', 3, { token = token, image = image }).err
        end
        for i = 1, burst do eq(errs[i], CH.ERR.PHOTO_BAD_IMAGE, 'send ' .. i) end
        eq(errs[burst + 1], CH.ERR.RATE_LIMITED,
            'every refused picture was given its allowance back')
        eq(#photoFiles(), 0)
    end)

    it('keeps the charge of a picture decoded and then refused by the claim', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local burst = Config.Cooldowns.photoSubmit.burst
        local image = largest(JPEG)
        local realClaim = s.contracts.claimSlot
        s.contracts.claimSlot = function() return false, CH.ERR.BUSY end

        local errs = {}
        local decoded = decodesDuring(function()
            for i = 1, burst + 2 do
                errs[i] = call('submitPhoto', 3, { token = token, image = image }).err
            end
        end)
        s.contracts.claimSlot = realClaim
        eq(decoded, burst, 'one decode for each send the allowance paid for, and no more')
        eq(errs[burst + 1], CH.ERR.RATE_LIMITED)
        eq(errs[burst + 2], CH.ERR.RATE_LIMITED)

        -- The token was never spent: once the claim can go through, the
        -- kill is still the hitman's.
        s.ratelimit.resetAll()
        local paid = call('submitPhoto', 3, { token = token, image = image })
        truthy(paid.ok, tostring(paid.err))
    end)

    it('answers a second send during a claim without decoding it', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        local image = largest(JPEG)
        local realClaim = s.contracts.claimSlot
        local inner
        local decoded
        s.contracts.claimSlot = function(...)
            -- The claim awaits on mysql; the same token sent again lands here.
            decoded = decodesDuring(function()
                inner = { s.photo.submit(f.hitman, token, nil, image) }
            end)
            return realClaim(...)
        end
        local ok = s.photo.submit(f.hitman, token, nil, image)
        s.contracts.claimSlot = realClaim
        truthy(ok, 'the first send is paid')
        eq(inner[2], CH.ERR.BUSY)
        eq(decoded, 0, 'the second send was decoded only to be told the first is being claimed')
        eq(#photoFiles(), 1)
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
        landed(1, handle)
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

    --- "No record names it" is only true of the store the files were kept
    --- for. A server whose storage mode was switched starts with a store
    --- that names none of them, and the sweep removed every kill photo the
    --- other mode kept or served, for good.
    it('leaves the files of another storage mode alone', function()
        local s = photographed()
        -- The sweep's notes are said with Config.Debug on, and kept for the
        -- diagnosis either way.
        Config.Debug = true
        Natives.files['data/photos/ph0000000orphan.webp'] = WEBP
        Natives.files['data/photos/kept/ph000000kept01.webp'] = WEBP
        Natives.files['data/photos/.mode'] = 'mysql'
        eq(Config.Database.Mode, 'json', 'this server is in json mode')

        eq(s.photos.sweepFiles(), 0, 'nothing is removed')
        truthy(Natives.files['data/photos/ph0000000orphan.webp'], 'not a waiting photo')
        truthy(Natives.files['data/photos/kept/ph000000kept01.webp'], 'nor a kept one')
        eq(Natives.files['data/photos/.mode'], 'mysql', 'and they stay marked as that mode\'s')
        truthy(table.concat(Env.console, ' '):find('kept for mysql mode', 1, true),
            'and the console says why: ' .. table.concat(Env.console, ' '))
    end)

    it('sweeps after memory mode, whose records never outlive a start, and marks the files', function()
        local s = photographed()
        Natives.files['data/photos/ph0000000orphan.webp'] = WEBP
        Natives.files['data/photos/.mode'] = 'memory'
        eq(s.photos.sweepFiles(), 1, 'memory mode\'s leftovers go')
        eq(Natives.files['data/photos/.mode'], 'json', 'and what is left is this mode\'s')

        Natives.files['data/photos/.mode'] = nil
        Natives.files['data/photos/ph0000000orphan.webp'] = WEBP
        eq(s.photos.sweepFiles(), 1, 'a folder no mode has marked yet is swept as before')
        eq(Natives.files['data/photos/.mode'], 'json', 'and marked')
    end)

    it('says so, and removes nothing, on a server that cannot list a folder', function()
        local s = photographed()
        Config.Debug = true
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
        -- Said in full, as with Config.Debug on.
        Config.Debug = true
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

--------------------------------------------------------------------------
-- Save to Photos, for a photo kept on this server
--------------------------------------------------------------------------
--
-- lb-phone's Photos keeps links of at most 500 characters, never pictures.
-- With a public https address this server serves the photo itself, under
-- a new name nobody can guess, for as long as the client's Photos keeps
-- it. Without one the page uses lb-phone's own upload, and failing that
-- the photo is kept for the client in this app.

local QBOX = 'chatty.server.qbox.re'

--- The header the photo handler marks its answers with.
local function s_MARKER() return require('crimson-hitman.server.photos').MARKER end

--- Opened by its client, on a server with a public address.
local function opened(opts)
    opts = opts or {}
    local s, f, c, handle, file = photographed(opts)
    if opts.web ~= false then Natives.convars.web_baseUrl = opts.web or QBOX end
    s.bridges.install(s)
    local reply = call('openPhoto', 1, { handle = handle })
    truthy(reply and reply.ok, tostring(reply and reply.err))
    -- And it lands, as the client says on arrival.
    if reply.data and reply.data.latent then landed(1, handle) end
    return s, f, c, handle, file, reply
end

--- The link the client's page is handed to save, and the name in it.
local function linked(opts)
    local s, f, c, handle, file = opened(opts)
    local reply = call('photoDecision', 1, { handle = handle, choice = 'link' })
    truthy(reply and reply.ok, 'a link: ' .. tostring(reply and reply.err))
    local link = reply.data.link
    local name = link:match('/p/([%w_-]+)%.jpg$')
    truthy(name, 'a link to the photo: ' .. tostring(link))
    return s, f, c, handle, file, link, name
end

--- Saved to the client's Photos by that link.
local function savedByLink(opts)
    local s, f, c, handle, file, link, name = linked(opts)
    local reply = call('photoDecision', 1, { handle = handle, choice = 'save' })
    truthy(reply and reply.ok, tostring(reply and reply.err))
    return s, f, c, handle, file, link, name
end

describe('a link for the phone\'s Photos, served by this server', function()
    it('says when it can give one', function()
        local _, _, _, _, _, reply = opened()
        eq(reply.data.link, true, 'with a public address')
        local _, _, _, _, _, without = opened({ web = false })
        falsy(without.data.link, 'and without one, says nothing of a link')
    end)

    it('names it anew, with 128 bits from the server\'s own cryptographic source', function()
        local s, _, _, handle, file, link, name = linked()
        eq(link, 'https://' .. QBOX .. '/crimson-hitman/p/' .. name .. '.jpg')
        eq(#name, 22, 'a bcrypt salt is 22 characters: 128 bits')
        truthy(name:match('^[%w_-]+$'), 'safe in a link and in a lookup: ' .. name)
        falsy(name:find(handle, 1, true), 'nothing to do with the handle the page knows it by')
        truthy((Natives.calls.passwordHashes or 0) >= 1, 'drawn from GetPasswordHash')
        local record = s.storage.readPhoto(handle)
        eq(record.public_id, name)
        eq(record.saved_link, link)
        eq(record.saved_phone, '555-1', 'the phone it is saved from, for a factory reset')
        eq(record.state, CH.PHOTO.OPEN, 'still open until the page says the phone has it')
        eq(record.file, file, 'the file is where it was; only the record knows the name')
        truthy(#link <= 500, 'inside lb-phone\'s 500 characters')
    end)

    it('is never a name two saves share', function()
        local seen = {}
        for _ = 1, 5 do
            local _, _, _, _, _, _, name = linked()
            falsy(seen[name], 'the same name twice: ' .. name)
            seen[name] = true
        end
    end)

    it('gives the same link when asked again', function()
        local _, _, _, handle, _, link = linked()
        local again = call('photoDecision', 1, { handle = handle, choice = 'link' })
        eq(again.data.link, link)
    end)

    it('uses Config.Completion.PhotoPublicUrl over web_baseUrl', function()
        local s, _, _, handle = opened()
        Config.Completion.PhotoPublicUrl = 'https://photos.example.com/hits'
        local reply = call('photoDecision', 1, { handle = handle, choice = 'link' })
        truthy(reply.data.link:find('^https://photos%.example%.com/hits/p/[%w_-]+%.jpg$'),
            reply.data.link)
    end)

    it('gives none without a public address, a usable one, or a source of secret names', function()
        local cases = {
            { 'no address', function() Natives.convars.web_baseUrl = nil end },
            { 'a users.cfx.re address, switched off by Cfx.re',
              function() Natives.convars.web_baseUrl = 'abc123-xyz.users.cfx.re' end },
            { 'a bare IP address', function() Natives.convars.web_baseUrl = '203.0.113.7:30120' end },
            { 'an http address', function()
                Natives.convars.web_baseUrl = nil
                Config.Completion.PhotoPublicUrl = 'http://photos.example.com/x'
            end },
        }
        for _, case in ipairs(cases) do
            local s, _, _, handle = opened()
            case[2]()
            local reply = call('photoDecision', 1, { handle = handle, choice = 'link' })
            falsy(reply.ok, case[1])
            eq(reply.err, CH.ERR.PHOTO_NO_LINK, case[1])
            local record = s.storage.readPhoto(handle)
            eq(record.state, CH.PHOTO.OPEN, case[1] .. ': still open, to keep or delete')
            falsy(record.public_id, case[1])
        end

        local s, _, _, handle = opened()
        local real = _G.GetPasswordHash
        _G.GetPasswordHash = nil
        falsy(s.photos.linkable(), 'never math.random in its place')
        local reply = call('photoDecision', 1, { handle = handle, choice = 'link' })
        _G.GetPasswordHash = real
        eq(reply.err, CH.ERR.PHOTO_NO_LINK)
        falsy(s.storage.readPhoto(handle).public_id)
    end)

    it('keeps the file once the phone has the link, and serves it', function()
        local s, _, _, handle, file, _, name = savedByLink()
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.SAVED)
        eq(Natives.files[file], JPEG, 'the phone\'s Photos loads it from here')
        local got = Natives.httpRequest('GET', '/p/' .. name .. '.jpg')
        eq(got.status, 200)
        eq(got.body, JPEG)
    end)

    it('deletes the file at once when the phone saved it some other way', function()
        -- lb-phone's own upload: the gallery points at lb-phone's host, and
        -- this server's copy has nothing left to do.
        local s, _, _, handle, file = opened({ web = false })
        truthy(call('photoDecision', 1, { handle = handle, choice = 'save' }).ok)
        eq(Natives.files[file], nil)
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.SAVED)
    end)

    it('lets the link go with the photo when it is left open', function()
        local s, _, _, _, file, _, name = linked()
        Env.advance(Config.Completion.PhotoOpenSeconds + 5)
        eq(s.photos.expire(), 1, 'a page that took the link and never said: still the open timeout')
        eq(Natives.files[file], nil)
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').status, 404)
    end)

    it('lets the link go when the client deletes it instead', function()
        local _, _, _, handle, file, _, name = linked()
        truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
        eq(Natives.files[file], nil)
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').status, 404)
    end)

    it('is not the retention\'s, nor the ledger\'s, to take from the client\'s Photos', function()
        local s, _, _, handle, file, _, name = savedByLink()
        Env.advance(Config.Ledger.PhotoRetentionDays * 86400 + 1)
        s.ledger.forgetOldPhotos()
        local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
        for i = 1, depth do
            Env.advance(1)
            s.ledger.record({ id = 'cx' .. i, creator_cid = 'OTHER001', target_cid = 'TARGET99',
                target_name = 'Somebody' }, 'CREATOR1', nil, CH.FULFILMENT.KIDNAPPING, { slot = 1 })
        end
        truthy(s.storage.readPhoto(handle), 'still in their Photos, so still here')
        eq(Natives.files[file], JPEG)
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').status, 200)
    end)
end)

describe('serving a saved photo over HTTP', function()
    it('answers a GET for the name with the photo, and nothing that would keep it', function()
        local _, _, _, _, _, _, name = savedByLink()
        truthy(Natives.httpHandler, 'the handler is installed with the bridges')
        local got = Natives.httpRequest('GET', '/p/' .. name .. '.jpg')
        eq(got.status, 200)
        eq(got.body, JPEG, 'whole, NULs and all')
        eq(got.headers['Content-Type'], 'image/jpeg')
        eq(got.headers['Cache-Control'], 'no-store')
        eq(got.headers['X-Content-Type-Options'], 'nosniff')
        for header, value in pairs(got.headers) do
            eq(type(value), 'string', header .. ': FiveM throws on a header that is not a string')
        end
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg?w=200').status, 200,
            'a query string is dropped, not read')
    end)

    it('marks every answer as this resource\'s, found or not', function()
        local _, _, _, _, _, _, name = savedByLink()
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').headers[s_MARKER()], '1')
        local missing = Natives.httpRequest('GET', '/p/' .. ('0'):rep(22) .. '.webp')
        eq(missing.status, 404)
        eq(missing.headers[s_MARKER()], '1', 'what /ch-diag knows this handler by')
        eq(Natives.httpRequest('POST', '/x').headers[s_MARKER()], '1')
    end)

    it('answers 404 to anything else, the same way every time', function()
        local _, _, _, handle, file, _, name = savedByLink()
        local reads = {}
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, path)
            reads[#reads + 1] = path
            return realLoad(res, path)
        end
        local refused = {
            { 'POST', '/p/' .. name .. '.jpg' },
            { 'HEAD', '/p/' .. name .. '.jpg' },
            { 'PUT', '/p/' .. name .. '.jpg' },
            { 'DELETE', '/p/' .. name .. '.jpg' },
            { 'GET', '/p/' .. name .. '.png' },
            { 'GET', '/p/' .. name },
            { 'GET', '/p/' .. name .. 'x.jpg' },
            { 'GET', '/p/' .. handle .. '.jpg' },
            { 'GET', '/p/Zk3_q-9xWb2LmT0cRf8aNd.jpg' },
            { 'GET', '/' .. file },
            { 'GET', '/p/../../server/main.lua' },
            { 'GET', '/p/..%2F..%2Fconfig%2Fconfig.lua' },
            { 'GET', '/p/' .. name .. '.jpg/../../fxmanifest.lua' },
            { 'GET', '/p/%2e%2e/' .. name .. '.jpg' },
            { 'GET', '/../data/photos/' .. handle .. '.jpg' },
            { 'GET', '//p/' .. name .. '.jpg' },
            { 'GET', '/p/' .. ('a'):rep(300) .. '.jpg' },
            { 'GET', '' },
            { 'GET', '/' },
        }
        for _, req in ipairs(refused) do
            local got = Natives.httpRequest(req[1], req[2])
            eq(got.status, 404, req[1] .. ' ' .. req[2])
            eq(got.body, 'Not found.', req[1] .. ' ' .. req[2])
            truthy(got.sent, 'answered, not left hanging: ' .. req[2])
        end
        _G.LoadResourceFile = realLoad
        eq(#reads, 0, 'no refused request reads a file: ' .. table.concat(reads, ', '))
    end)

    it('does not serve a photo by name before it is linked, or after it is let go', function()
        local s, _, _, handle, file = opened()
        eq(Natives.httpRequest('GET', '/p/' .. handle .. '.jpg').status, 404,
            'a photo waiting or open is not served by its handle')
        truthy(call('photoDecision', 1, { handle = handle, choice = 'link' }).ok)
        local name = s.storage.readPhoto(handle).public_id
        truthy(call('photoDecision', 1, { handle = handle, choice = 'keep' }).ok)
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').status, 404,
            'kept in the app instead: the link it was given goes')
        truthy(Natives.files['data/photos/kept/' .. handle .. '.jpg'], 'the photo itself stays')
        eq(Natives.files[file], nil)
    end)

    it('survives a request it cannot read', function()
        savedByLink()
        for _, req in ipairs({ { 'GET', 42 }, { nil, '/p/x.jpg' }, { 'GET', nil } }) do
            local ok, got = pcall(Natives.httpRequest, req[1], req[2])
            truthy(ok, tostring(got))
            eq(got.status, 404)
        end
    end)
end)

describe('a photo deleted from the client\'s Photos', function()
    it('takes the file and its link with it', function()
        local s, _, _, handle, file, link, name = savedByLink()
        eq(Env.events['lb-phone:deletedFromGallery'], nil,
            'never a net event: a client cannot say a photo was deleted')
        TriggerEvent('lb-phone:deletedFromGallery', 1, '555-1', link)
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED)
        eq(Natives.files[file], nil)
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').status, 404)
        falsy(s.storage.readPhoto(handle).public_id)
    end)

    it('only when its own client deleted it', function()
        local s, _, _, handle, file, link = savedByLink()
        -- Somebody the link was passed on to, deleting their copy.
        TriggerEvent('lb-phone:deletedFromGallery', 3, '555-3', link)
        TriggerEvent('lb-phone:deletedFromGallery', 2, '555-2', link)
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.SAVED)
        eq(Natives.files[file], JPEG)
    end)

    it('ignores any other link, and anything that is not one', function()
        local s, _, _, handle, file, link = savedByLink()
        for _, other in ipairs({ 'https://cdn.fivemanage.com/x.png',
                                 link:gsub('/p/[%w_-]+', '/p/Zk3_q-9xWb2LmT0cRf8aNd'),
                                 'https://' .. QBOX .. '/crimson-hitman/p/' .. handle .. '.jpg',
                                 42, {}, ('x'):rep(5000) }) do
            TriggerEvent('lb-phone:deletedFromGallery', 1, '555-1', other)
        end
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.SAVED)
        eq(Natives.files[file], JPEG)
    end)

    it('takes everything saved from a phone that is factory reset, and nothing else', function()
        local s, _, _, handle, file = savedByLink()
        TriggerEvent('lb-phone:factoryReset', 1, '555-9')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.SAVED, 'another phone of theirs')
        TriggerEvent('lb-phone:factoryReset', 3, '555-1')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.SAVED, 'not theirs to reset')
        TriggerEvent('lb-phone:factoryReset', 1, '555-1')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED)
        eq(Natives.files[file], nil)
    end)
end)

describe('a photo kept for the client in the app, on this server', function()
    local function kept(opts)
        local s, f, c, handle, file = opened(opts)
        local reply = call('photoDecision', 1, { handle = handle, choice = 'keep' })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        return s, f, c, handle, file
    end

    it('moves its file into data/photos/kept/', function()
        local s, _, _, handle, file = kept({ web = false })
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.KEPT)
        eq(record.file, 'data/photos/kept/' .. handle .. '.jpg')
        eq(Natives.files[record.file], JPEG, 'moved whole')
        eq(Natives.files[file], nil, 'and not left where it was')
        truthy(Natives.dirs['data/photos/kept'], 'the folder made first')
    end)

    it('keeps it beside the others where the kept folder cannot be made', function()
        local realCreate = os.createdir
        os.createdir = function(path)
            if path:find('/kept$') then return nil, path .. ': Failed to create directory', 1 end
            return realCreate(path)
        end
        local ok, err = pcall(function()
            local s, _, _, handle = kept({ web = false })
            local record = s.storage.readPhoto(handle)
            eq(record.file, 'data/photos/kept-' .. handle .. '.jpg')
            eq(Natives.files[record.file], JPEG)
        end)
        os.createdir = realCreate
        truthy(ok, tostring(err))
    end)

    it('keeps it where it is where the server cannot move files', function()
        Natives.renameRefused = true
        local ok, err = pcall(function()
            local s, _, _, handle, file = kept({ web = false })
            local record = s.storage.readPhoto(handle)
            eq(record.state, CH.PHOTO.KEPT)
            eq(record.file, file, 'still kept, under the name it had')
            eq(Natives.files[file], JPEG)
        end)
        Natives.renameRefused = nil
        truthy(ok, tostring(err))
    end)

    it('opens again and again, sent each time as the first time, and says it is kept', function()
        local s, _, _, handle = kept({ web = false })
        for _ = 1, 3 do
            local reply, events = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, tostring(reply and reply.err))
            eq(reply.data.kept, true)
            local sent = latentTo(events, 'crimson-hitman:photoImage')
            eq(#sent, 1, 'sent latent, to the client')
            eq(sent[1].target, 1)
            eq(Util.fromBase64(sent[1].args[1].src:sub(24)), JPEG)
            landed(1, handle)
        end
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.KEPT)
        for _, src in ipairs({ 2, 3 }) do
            local reply, events = call('openPhoto', src, { handle = handle })
            eq(reply.err, CH.ERR.PHOTO_GONE, 'source ' .. src)
            eq(#latentTo(events, 'crimson-hitman:photoImage'), 0)
        end
    end)

    --- Each open read the file and encoded it again in Lua on the main
    --- thread: tens of milliseconds at the default size, as often as the
    --- open limit lets its owner tap.
    it('is encoded once for repeated opens, and again once it is gone', function()
        local s, _, _, handle = kept({ web = false })
        local encodes, real = 0, Util.toBase64
        Util.toBase64 = function(...) encodes = encodes + 1 return real(...) end
        local ok, err = pcall(function()
            for _ = 1, 4 do
                local reply, events = call('openPhoto', 1, { handle = handle })
                truthy(reply and reply.ok, tostring(reply and reply.err))
                eq(Util.fromBase64(latentTo(events, 'crimson-hitman:photoImage')[1].args[1].src:sub(24)),
                    JPEG, 'the same picture each time')
                landed(1, handle)
            end
            eq(encodes, 1, 'encoded on the first open only')
            local reply = call('openPhoto', 2, { handle = handle })
            eq(reply.err, CH.ERR.PHOTO_GONE, 'still nobody else\'s to open')
            eq(encodes, 1)
            truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
            Env.advance(30)   -- past the open limit
            reply = call('openPhoto', 1, { handle = handle })
            eq(reply.err, CH.ERR.PHOTO_GONE, 'deleted is deleted, cache or not')
        end)
        Util.toBase64 = real
        truthy(ok, tostring(err))
    end)

    --- Each open queued another whole photo to the same player with nothing
    --- to say one was already on its way. FXServer moves them no faster than
    --- the client acknowledges, so a client tapping, or a page scripted to
    --- open every two seconds, piled sends up faster than they drained.
    it('is sent to a player one at a time, and the next waits for the first to land', function()
        local s, _, _, handle = kept({ web = false })
        local reads, realLoad = 0, _G.LoadResourceFile
        _G.LoadResourceFile = function(res, path)
            if tostring(path):find('^data/photos/') then reads = reads + 1 end
            return realLoad(res, path)
        end
        local ok, err = pcall(function()
            local reply, events = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, tostring(reply and reply.err))
            eq(#latentTo(events, 'crimson-hitman:photoImage'), 1)
            local readsForOne = reads

            -- Refused before the photo is opened at all: a photo waiting
            -- for its one look, asked for meanwhile, keeps it.
            local opens, realOpen = 0, s.photos.open
            s.photos.open = function(...) opens = opens + 1 return realOpen(...) end
            local sentAgain = 0
            for _ = 1, 10 do
                local again, more = call('openPhoto', 1, { handle = handle })
                eq(again.err, CH.ERR.RATE_LIMITED, 'still on its way')
                truthy(again.data and again.data.retryAfter >= 1 and again.data.retryAfter <= 60,
                    'with how long: ' .. tostring(again.data and again.data.retryAfter))
                sentAgain = sentAgain + #latentTo(more, 'crimson-hitman:photoImage')
            end
            s.photos.open = realOpen
            eq(sentAgain, 0, 'ten more taps queued nothing')
            eq(reads, readsForOne, 'and read nothing')
            eq(opens, 0, 'and opened nothing, so no look is spent')

            -- Somebody else's word, or a word about another photo, is not it.
            arrived(2, handle)
            arrived(1, 'ph0000000other')
            eq(call('openPhoto', 1, { handle = handle }).err, CH.ERR.RATE_LIMITED)

            -- Said to have landed the moment it was sent: no photo drains
            -- that fast, and a client acking at once had a whole photo
            -- re-sent on every open the limit allowed.
            arrived(1, handle)
            eq(call('openPhoto', 1, { handle = handle }).err, CH.ERR.RATE_LIMITED,
                'not before it could have landed')
            Env.advance(1)
            reply, events = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, 'once it landed, it opens again: ' .. tostring(reply and reply.err))
            eq(#latentTo(events, 'crimson-hitman:photoImage'), 1)

            -- A send the client never acknowledged is let go of once the
            -- client itself would have stopped waiting.
            Env.advance(61)
            reply = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, tostring(reply and reply.err))

            -- And forgotten with the player, so the next one on this
            -- server id is not kept waiting.
            s.app.forgetSource(1)
            reply = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, tostring(reply and reply.err))
        end)
        _G.LoadResourceFile = realLoad
        truthy(ok, tostring(err))
    end)

    --- photoArrived is the client's word, and the handle it names is in the
    --- open's own reply. A modified client saying it at once had the whole
    --- photo re-sent on every open the limit allowed, queued several times
    --- faster than FXServer drains it: the memory the one-at-a-time guard
    --- was there to save.
    it('is not sent again sooner than a photo that size could have landed', function()
        local s, _, _, handle = kept({ web = false })
        local big = 'data:image/jpeg;base64,' .. ('A'):rep(1500000)
        local realOpen = s.photos.open
        s.photos.open = function(actor, h)
            local view, err = realOpen(actor, h)
            if view and view.image then view.image = big end
            return view, err
        end
        local ok, err = pcall(function()
            local sends = 0
            local reply, events = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, tostring(reply and reply.err))
            sends = sends + #latentTo(events, 'crimson-hitman:photoImage')
            arrived(1, handle)
            Env.advance(5)
            local again = call('openPhoto', 1, { handle = handle })
            eq(again.err, CH.ERR.RATE_LIMITED, 'a 1.5 MB photo has not landed five seconds on')
            truthy(again.data.retryAfter >= 4 and again.data.retryAfter <= 6,
                'and it says for how long: ' .. tostring(again.data.retryAfter))
            Env.advance(6)
            reply, events = call('openPhoto', 1, { handle = handle })
            truthy(reply and reply.ok, 'it opens once it could have: ' .. tostring(reply and reply.err))
            sends = sends + #latentTo(events, 'crimson-hitman:photoImage')

            -- A client acking every send at once, and opening every two
            -- seconds for a minute, as the open limit allows.
            for _ = 1, 30 do
                arrived(1, handle)
                Env.advance(2)
                local r, e = call('openPhoto', 1, { handle = handle })
                if r and r.ok then sends = sends + #latentTo(e, 'crimson-hitman:photoImage') end
            end
            truthy(sends <= 2 + math.ceil(62 / 10),
                'no faster than the photo drains: ' .. sends .. ' sends of 1.5 MB')
        end)
        s.photos.open = realOpen
        truthy(ok, tostring(err))
    end)

    it('is removed when the client deletes it', function()
        local s, _, _, handle = kept({ web = false })
        local keptFile = s.storage.readPhoto(handle).file
        truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
        eq(Natives.files[keptFile], nil)
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED)
    end)

    it('outlives the expiry, the retention and its row, and goes after KeptPhotoDays', function()
        local s, _, _, handle = kept({ web = false })
        local keptFile = s.storage.readPhoto(handle).file
        Env.advance(Config.Ledger.PhotoRetentionDays * 86400 + 1)
        s.photos.expire()
        s.ledger.forgetOldPhotos()
        eq(Natives.files[keptFile], JPEG, 'not the retention\'s')
        Config.Completion.KeptPhotoDays = 30
        Env.advance(31 * 86400)
        eq(s.photos.forgetKept(), 1)
        eq(Natives.files[keptFile], nil)
    end)

    it('is kept by the start\'s sweep, wherever it was kept', function()
        local s, _, _, handle = kept({ web = false })
        local keptFile = s.storage.readPhoto(handle).file
        Natives.files['data/photos/kept/ph0000000orphan.webp'] = WEBP
        Natives.files['data/photos/kept-ph000000orphan2.webp'] = WEBP
        eq(s.photos.sweepFiles(), 2, 'kept files no record names are swept like any other')
        eq(Natives.files[keptFile], JPEG, 'the kept photo is not')
        eq(Natives.files['data/photos/kept/ph0000000orphan.webp'], nil)
        eq(Natives.files['data/photos/kept-ph000000orphan2.webp'], nil)
    end)

    it('says in /ch-diag how many are kept and how much disk they take', function()
        local s = kept({ web = false })
        local said = table.concat(s.admin.diagnose(1) or {}, '\n')
        truthy(said:find('1 kept in the app', 1, true), said)
        truthy(said:find('photos on disk:', 1, true), said)

        -- Still counted on a server since switched to live transfer only,
        -- as what is left from before.
        Config.Completion.Fulfilment = 'alive'
        said = table.concat(s.admin.diagnose(1) or {}, '\n')
        truthy(said:find('photos on disk (taken before): 0 waiting', 1, true), said)
        truthy(said:find('1 kept in the app', 1, true), said)
    end)
end)

describe('what /ch-diag says about saving photos kept on this server', function()
    local function diag(s)
        return table.concat(s.admin.diagnose(1) or {}, '\n')
    end

    it('names the address photos are served from, and whether lb-phone takes it', function()
        local s = newStack()
        fixture(s)
        Config.Completion.PhotoStorage = 'server'
        Natives.convars.web_baseUrl = 'r2.qbox.re'
        local said = diag(s)
        truthy(said:find('photo links: https://r2.qbox.re/crimson-hitman/p/... (from web_baseUrl)',
            1, true), said)
        truthy(said:find('allow list takes r2.qbox.re: yes', 1, true), said)

        Natives.convars.web_baseUrl = QBOX
        said = diag(s)
        truthy(said:find('does NOT take ' .. QBOX, 1, true), said)
        truthy(said:find('UploadWhitelistedHostnames', 1, true), 'and says where to add it: ' .. said)
    end)

    --- Everything the report checks can be right and every link still dead:
    --- an address without the /crimson-hitman FXServer routes by, a proxy
    --- that does not pass it on, a certificate a phone refuses. The client's
    --- one look is then spent on a broken picture, and its file kept for
    --- good behind the saved link. So the address itself is asked.
    describe('whether the address reaches this resource', function()
        local function ask(s, answer)
            Natives.httpAnswer = answer
            local after = {}
            local lines = s.admin.diagnose(1, nil, function(line) after[#after + 1] = line end)
            Natives.httpAnswer = nil
            return table.concat(lines, '\n'), table.concat(after, '\n')
        end
        local function server()
            local s = newStack()
            fixture(s)
            Config.Completion.PhotoStorage = 'server'
            Natives.convars.web_baseUrl = 'r2.qbox.re'
            return s
        end

        it('says yes when its own handler answers', function()
            local s = server()
            local asked
            local report, after = ask(s, function(url)
                asked = url
                -- What FXServer does: the path under /crimson-hitman goes
                -- to this resource's handler.
                local path = url:match('^https://r2%.qbox%.re/crimson%-hitman(/.*)$')
                if not path then return 404, 'Not Found', {} end
                local got = Natives.httpRequest('GET', path)
                return got.status, got.body, got.headers
            end)
            truthy(report:find('checking that this address reaches this resource', 1, true), report)
            truthy(asked and asked:find('^https://r2%.qbox%.re/crimson%-hitman/p/0+%.webp$'),
                'a name nobody has, under the address links are built on: ' .. tostring(asked))
            truthy(after:find('reaches this resource: yes', 1, true), after)
        end)

        it('warns when something else answers there', function()
            local s = server()
            local _, after = ask(s, function() return 404, 'Not Found', { ['Content-Type'] = 'text/html' } end)
            truthy(after:find('answered 404, not this resource', 1, true), after)
            truthy(after:find('/crimson-hitman/', 1, true), 'and says what the address needs: ' .. after)
            falsy(after:find(': yes', 1, true), after)

            _, after = ask(s, function() return 200, '<html>', {} end)
            truthy(after:find('answered 200, not this resource', 1, true), after)
        end)

        it('warns, without condemning the address, when nothing answers', function()
            local s = server()
            local _, after = ask(s, function() return 0, nil, {}, 'SSL certificate problem' end)
            truthy(after:find('could not load https://r2.qbox.re/crimson-hitman/p/...', 1, true), after)
            truthy(after:find('SSL certificate problem', 1, true), after)
            truthy(after:find('from a phone', 1, true), 'a hairpin is not a verdict: ' .. after)
        end)

        it('is not asked where there is no address, or nowhere to answer', function()
            local s = newStack()
            fixture(s)
            Config.Completion.PhotoStorage = 'server'
            Natives.calls.http = {}
            ask(s, function() error('nothing should be asked') end)
            eq(#Natives.calls.http, 0, 'no address, nothing to ask')

            s = server()
            Natives.calls.http = {}
            s.admin.diagnose(1)
            eq(#Natives.calls.http, 0, 'a report with nowhere to put the answer asks nothing')
        end)

        it('header names are read as HTTP reads them, whatever their case', function()
            local s = server()
            local _, after = ask(s, function()
                return 404, 'Not found.', { ['x-crimson-hitman'] = '1' }
            end)
            truthy(after:find('reaches this resource: yes', 1, true), after)
        end)
    end)

    it('says so when there is no address, and what happens instead', function()
        local s = newStack()
        fixture(s)
        Config.Completion.PhotoStorage = 'server'
        local said = diag(s)
        truthy(said:find('photo links: none (web_baseUrl is not set)', 1, true), said)
        truthy(said:find('kept in the app', 1, true), said)
        truthy(said:find('server.qbox.re', 1, true), 'the Nucleus replacement is named: ' .. said)
    end)

    --- Under 'alive', as shipped, no kill photo is taken. The report said
    --- the photo settings were unused, and then told the owner to set up
    --- every one of them.
    it('gives no photo advice where no kill photo can be taken, and gives it once one can', function()
        local s = newStack()
        local f = fixture(s)
        Config.Completion.Fulfilment = 'alive'
        Config.Completion.PhotoStorage = 'server'
        Natives.convars.web_baseUrl = 'r2.qbox.re'
        local asked = 0
        Natives.httpAnswer = function() asked = asked + 1; return 200, '', {} end
        local after = {}
        local said = table.concat(s.admin.diagnose(1, nil,
            function(line) after[#after + 1] = line end) or {}, '\n')
        Natives.httpAnswer = nil
        truthy(said:find('photo settings: not used (live transfer only)', 1, true), said)
        falsy(said:find('photo storage:', 1, true), said)
        falsy(said:find('photo links', 1, true), said)
        eq(asked, 0, 'nor is the address asked whether it reaches a page nothing uses')
        eq(#after, 0, table.concat(after, '\n'))
        truthy(said:find('\n  no kill photo is taken', 1, true), said)
        falsy(said:find('-> no kill photo', 1, true), 'an unused setting is nothing to act on: ' .. said)

        Natives.convars.web_baseUrl = nil
        said = diag(s)
        falsy(said:find('PhotoPublicUrl', 1, true), 'no address to set: ' .. said)

        Config.Completion.PhotoStorage = 'host'
        Config.Completion.ExtraPhotoHosts = {}
        said = diag(s)
        falsy(said:find('photo hosts:', 1, true), said)
        falsy(said:find('every kill photo will be refused', 1, true), said)

        -- One placed under 'either' and still live is completed by a kill,
        -- and the advice is back for it.
        Config.Completion.PhotoStorage = 'server'
        Config.Completion.Fulfilment = 'either'
        truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } }))
        Config.Completion.Fulfilment = 'alive'
        said = diag(s)
        falsy(said:find('photo settings: not used', 1, true), said)
        truthy(said:find('photo storage: server', 1, true), said)
        truthy(said:find('photo links: none (web_baseUrl is not set)', 1, true), said)
    end)

    it('takes lb-phone\'s own allow list as lb-phone reads it', function()
        local s = newStack()
        local real = Natives.phoneConfig
        local ok, err = pcall(function()
            Natives.phoneConfig = { UploadWhitelistedHostnames = { '*.server.qbox.re' },
                                    UploadWhitelistedDomains = { 'example.com' } }
            truthy(s.photos.galleryAllows('https://chatty.server.qbox.re/c/p/x.webp'), 'a * label')
            falsy(s.photos.galleryAllows('https://a.b.server.qbox.re/c/p/x.webp'), '* is one label')
            truthy(s.photos.galleryAllows('https://photos.example.com/c/p/x.webp'), 'a subdomain')
            truthy(s.photos.galleryAllows('https://example.com/c/p/x.webp'), 'the domain')
            falsy(s.photos.galleryAllows('https://example.com:8443/c/p/x.webp'),
                'lb-phone reads the port as part of the host')
            falsy(s.photos.galleryAllows('https://badexample.com/c/p/x.webp'))
            Natives.phoneConfig = {}
            truthy(s.photos.galleryAllows('https://anything.example/c/p/x.webp'),
                'with both lists empty lb-phone takes any link')
        end)
        Natives.phoneConfig = real
        truthy(ok, tostring(err))
    end)
end)

--------------------------------------------------------------------------
-- Kill photos switched off (Config.Completion.KillPhotos = false)
--------------------------------------------------------------------------

describe('kill photos switched off', function()
    --- A payload that writes down every key read from it.
    local function watched(fields)
        local read = {}
        return setmetatable({}, { __index = function(_, key)
            read[#read + 1] = tostring(key)
            return fields[key]
        end }), read
    end

    it('refuses every photo request unread, as a photo nobody has, and writes nothing', function()
        local s, _, c = killed()
        Config.Completion.KillPhotos = false
        local gates = 0
        local realGate = s.identity.gate
        s.identity.gate = function(...) gates = gates + 1 return realGate(...) end

        local requests = {
            { 'requestPhotoToken', 3, { id = c.id } },
            { 'submitPhoto', 3, { token = 'tk00000000000001', image = uri('image/jpeg', JPEG) } },
            { 'submitPhoto', 3, { token = 'tk00000000000001', url = 'https://cdn.fivemanage.com/p.png' } },
            { 'openPhoto', 1, { handle = 'ph00000000000001' } },
            { 'photoDecision', 1, { handle = 'ph00000000000001', choice = 'save' } },
        }
        local ok, err = pcall(function()
            for i, req in ipairs(requests) do
                req[3].__rid = 70 + i
                local payload, read = watched(req[3])
                local reply = call(req[1], req[2], payload)
                truthy(reply, req[1] .. ' is answered')
                eq(reply.ok, false, req[1])
                eq(reply.err, CH.ERR.PHOTO_GONE, req[1] .. ' is answered as a photo nobody has')
                eq(reply.rid, 70 + i, req[1] .. ' answers the request it was asked')
                eq(table.concat(read, ','), '__rid',
                    req[1] .. ' reads nothing of what was sent but the id it answers')
            end
            arrived(1, 'ph00000000000001')
        end)
        s.identity.gate = realGate
        truthy(ok, tostring(err))
        eq(gates, 0, 'nor asks who is asking')
        eq(s.photo.tokenCount(), 0, 'no token is issued')
        eq(#photoFiles(), 0, 'no photo file is written')
        falsy(Natives.dirs['data/photos'], 'and data/photos is not made')
        eq(#s.storage.photosOf('CREATOR1'), 0, 'nor any photo record')
    end)

    it('keeps no photo however a kill is verified, and makes no folder for one', function()
        local s, f, c = killed()
        Config.Completion.KillPhotos = false
        local ok, err = s.photo.verifyAtScene(f.hitman, c.id)
        truthy(ok, tostring(err))
        eq(#photoFiles(), 0)
        falsy(Natives.dirs['data/photos'])
        falsy(s.storage.readLedger('CREATOR1', 10)[1].photo_ref, 'the client row names no photo')
        eq(#s.storage.photosOf('CREATOR1'), 0)
        -- And a picture that reached the store's door anyway is not kept.
        eq(s.photos.keep(s.storage.readContract(c.id), 1,
            { kind = 'file', data = JPEG, mime = 'image/jpeg' }), nil)
        eq(#photoFiles(), 0)
    end)

    it('lets a photo kept before they were turned off be opened once by its owner, and expire', function()
        local s, _, _, handle, file = photographed()
        Config.Completion.KillPhotos = false
        truthy(s.photos.inUse(), 'a photo is still kept, so what looks after it still runs')
        local reply = call('openPhoto', 1, { handle = handle })
        truthy(reply and reply.ok, 'its owner opens it: ' .. tostring(reply and reply.err))
        landed(1, handle)
        eq(call('openPhoto', 1, { handle = handle }).err, CH.ERR.PHOTO_GONE, 'once')
        eq(call('openPhoto', 2, { handle = handle }).err, CH.ERR.PHOTO_GONE, 'and only its owner')

        -- Left open past the time to decide, it goes as it always did.
        Env.advance(Config.Completion.PhotoOpenSeconds + 1)
        eq(s.photos.expire(), 1, 'the expiry still runs')
        eq(Natives.files[file], nil, 'and its file goes')

        -- Its record goes with the retention, and then nothing is kept.
        Env.advance(Config.Ledger.PhotoRetentionDays * 86400 + 61)
        s.ledger.forgetOldPhotos()
        Env.advance(61)
        falsy(s.photos.inUse(), 'with none kept and none taken, nothing about photos runs')
        eq(call('openPhoto', 1, { handle = handle }).err, CH.ERR.PHOTO_GONE)
    end)

    --- Nothing is served while they are off, so a link handed out then is a
    --- broken picture on the phone, and the client's one look spent on it.
    it('offers no link to the phone\'s Photos for a photo kept from before', function()
        local s, _, _, handle = photographed()
        Natives.convars.web_baseUrl = QBOX
        s.bridges.install(s)
        truthy(s.photos.linkable(), 'this server could link one while photos are on')
        Config.Completion.KillPhotos = false
        local reply = call('openPhoto', 1, { handle = handle })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        if reply.data.latent then landed(1, handle) end
        falsy(reply.data.link, 'no link is offered')
        local asked = call('photoDecision', 1, { handle = handle, choice = 'link' })
        eq(asked.err, CH.ERR.PHOTO_NO_LINK, 'nor given when asked for')
        local record = s.storage.readPhoto(handle)
        falsy(record.public_id, 'nothing is published')
        eq(record.state, CH.PHOTO.OPEN, 'and it is still open, to keep in the app or delete')
        truthy(call('photoDecision', 1, { handle = handle, choice = 'keep' }).ok, 'kept in the app')
    end)

    it('serves nothing over HTTP, even a photo saved to a phone\'s Photos before', function()
        local _, _, _, _, _, _, name = savedByLink()
        eq(Natives.httpRequest('GET', '/p/' .. name .. '.jpg').status, 200, 'served while on')
        Config.Completion.KillPhotos = false
        local reads = {}
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, path)
            reads[#reads + 1] = path
            return realLoad(res, path)
        end
        local answers = {
            Natives.httpRequest('GET', '/p/' .. name .. '.jpg'),
            Natives.httpRequest('GET', '/p/' .. ('0'):rep(22) .. '.webp'),
            Natives.httpRequest('POST', '/x'),
            Natives.httpRequest('GET', '/'),
        }
        _G.LoadResourceFile = realLoad
        for i, got in ipairs(answers) do
            eq(got.status, 404, 'request ' .. i)
            eq(got.body, 'Not found.', 'request ' .. i)
        end
        eq(#reads, 0, 'and reads no file to say so')
    end)
end)
