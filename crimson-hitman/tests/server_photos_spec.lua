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

--- Opened by its client, on a server with a public address.
local function opened(opts)
    opts = opts or {}
    local s, f, c, handle, file = photographed(opts)
    if opts.web ~= false then Natives.convars.web_baseUrl = opts.web or QBOX end
    s.bridges.install(s)
    local reply = call('openPhoto', 1, { handle = handle })
    truthy(reply and reply.ok, tostring(reply and reply.err))
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
        end
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.KEPT)
        for _, src in ipairs({ 2, 3 }) do
            local reply, events = call('openPhoto', src, { handle = handle })
            eq(reply.err, CH.ERR.PHOTO_GONE, 'source ' .. src)
            eq(#latentTo(events, 'crimson-hitman:photoImage'), 0)
        end
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

    it('says so when there is no address, and what happens instead', function()
        local s = newStack()
        fixture(s)
        Config.Completion.PhotoStorage = 'server'
        local said = diag(s)
        truthy(said:find('photo links: none (web_baseUrl is not set)', 1, true), said)
        truthy(said:find('kept in the app', 1, true), said)
        truthy(said:find('server.qbox.re', 1, true), 'the Nucleus replacement is named: ' .. said)
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
