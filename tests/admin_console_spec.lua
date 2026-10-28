--- The admin panel's Console section, and its button that removes the kill
--- photos kept from before kill photos were turned off (server/panel.lua's
--- console and removePhotos, shared/log.lua's Log.view, server/photos.lua's
--- removeAll).
---
--- What these hold the features to: the Console shows what the logger keeps,
--- each line with its kind, to anybody who may read the panel, scrubbed for
--- staff without IdentityAce as the Alerts are, and never a webhook's
--- address, a convar's secret or a statement's values to anybody. The
--- removal is a staff write, offered only while kill photos are off and some
--- are kept, that deletes every record and every file on each store, forgets
--- a link to the image host (saying the picture stays there), leaves a photo
--- open on a phone to its view, and does nothing the second time.

local Exec = require('tests.harness.mysql_exec')
local Shipped = require('tests.harness.shipped')
local Log = require('crimson-hitman.shared.log')

local HOOK = 'https://discord.example/api/webhooks/123456/hook-token-secret'
local JPEG = '\255\216\255\224\0\16JFIF\0\1\1\0\0\1' .. ('\0\7\255kill'):rep(10)

--- A stack running the shipped switches (kill photos off among them), with
--- the usual three players and three staff: crimson.admin, an extra ACE
--- only (reads), and crimson.admin with crimson.identity.
local function stack()
    local s = Shipped.newStack()
    -- Anonymous contracts are what the scrubbing is for: placing
    -- anonymously allowed, explicitly, though the resource ships it off.
    Config.Anonymity.AllowAnonymousPlacer = true
    Config.Anonymity.AllowAnonymousHitman = true
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    Natives.files = {}
    s.bridges.install(s)
    return s, f
end

local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 9 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

local function strings(value, out)
    out = out or {}
    if type(value) == 'string' then
        out[#out + 1] = value
    elseif type(value) == 'table' then
        for k, v in pairs(value) do strings(k, out) strings(v, out) end
    end
    return out
end

local function lineWith(lines, needle)
    for _, line in ipairs(lines) do
        if tostring(line.text):find(needle, 1, true) then return line end
    end
    return nil
end

--- The photo records every store is given: one waiting with its file here,
--- one kept in the app (its file in kept/), one closed whose file went
--- already, one waiting on the image host and one saved from it.
local function keepPhotos(store)
    local now = os.time()
    local rows = {
        { id = 'ph0000000fa1', kind = 'file', file = 'data/photos/ph0000000fa1.jpg', mime = 'image/jpeg',
          size = #JPEG, state = CH.PHOTO.PENDING },
        { id = 'ph0000000fa2', kind = 'file', file = 'data/photos/kept/ph0000000fa2.jpg', mime = 'image/jpeg',
          size = #JPEG, state = CH.PHOTO.KEPT, opened_at = now - 50 },
        { id = 'ph0000000fa3', kind = 'file', mime = 'image/jpeg', size = #JPEG, state = CH.PHOTO.DELETED,
          opened_at = now - 40 },
        { id = 'ph0000000ur1', kind = 'url', url = 'https://cdn.fivemanage.com/one.png', state = CH.PHOTO.PENDING },
        { id = 'ph0000000ur2', kind = 'url', state = CH.PHOTO.SAVED, opened_at = now - 30 },
    }
    for i, row in ipairs(rows) do
        row.contract_id, row.slot, row.owner_cid, row.created_at = 'ct0000000' .. i, 1, 'CREATOR1', now - 100 + i
        store.writePhoto(row)
        if row.file then Natives.files[row.file] = JPEG end
    end
end

--- One photo open on its client's phone right now, on the image host.
local function openOne(s, store, f)
    store.writePhoto({ id = 'ph0000000op1', kind = 'url', url = 'https://cdn.fivemanage.com/open.png',
        state = CH.PHOTO.PENDING, contract_id = 'ct00000009', slot = 1, owner_cid = 'CREATOR1',
        created_at = os.time() - 5 })
    local view = s.photos.open(f.creator, 'ph0000000op1')
    truthy(view and view.url, 'the client has it open')
    eq(store.readPhoto('ph0000000op1').state, CH.PHOTO.OPEN)
end

--------------------------------------------------------------------------
-- What the logger keeps
--------------------------------------------------------------------------

describe('what the logger keeps, by kind', function()
    it('keeps the kind of every line of the start and every line after it', function()
        stack()
        Log.beginStart()
        Log.debug('opening the store')
        Log.always('BOOT RECOVERY FAILED: a test')
        Log.problem('warning: Kidnap.Radius is 2')
        Log.started()
        Log.always('escrow line ct00000001:1 left for staff')
        Log.debug('a page fault report')
        Log.debug('a page fault report')
        local kept = Log.view()
        eq(kept.boot[1], 'opening the store', 'the diagnosis still reads the start as lines')
        eq(kept.bootKinds[1], 'debug')
        eq(kept.bootKinds[2], 'always')
        eq(kept.problems[1], 'warning: Kidnap.Radius is 2')
        eq(kept.recent[1].kind, 'always')
        eq(kept.recent[2].kind, 'debug')
        eq(kept.recent[2].times, 2, 'the same line again counted on it')
    end)
end)

--------------------------------------------------------------------------
-- The Console section
--------------------------------------------------------------------------

describe('the Console section', function()
    it('shows the problems, the start and the newest lines, each with its kind, time and count', function()
        local s = stack()
        Log.beginStart()
        Log.debug('opening the store')
        Log.always('FATAL: not really, a test')
        Log.problem('warning: Kidnap.Radius is 2')
        Log.started()
        local said = os.time()
        Log.always('escrow line ct00000001:1 left for staff')
        Env.advance(5)
        Log.debug('slow job expiry')
        Log.debug('slow job expiry')
        local reply = ask(7, 'console', {})
        eq(reply.ok, true, tostring(reply.message))
        local d = reply.data
        eq(d.debug, true, 'as shipped')
        eq(d.count, 1)
        eq(d.problems[1], 'warning: Kidnap.Radius is 2')
        eq(d.boot[1].text, 'opening the store')
        eq(d.boot[1].kind, 'debug')
        eq(d.boot[2].kind, 'always')
        local money = lineWith(d.recent, 'left for staff')
        eq(money.kind, 'always')
        eq(money.at, said)
        local slow = lineWith(d.recent, 'slow job')
        eq(slow.kind, 'debug')
        eq(slow.times, 2)
        eq(slow.at, said + 5)
        eq(d.bootKept, Log.BOOT_KEPT)
        truthy(s.panel.OPS.console == 'read', 'a read')
    end)

    it('needs the ACE or one of the extra ACEs to read, and asks nothing more', function()
        stack()
        Log.always('a line')
        eq(ask(3, 'console', {}).err, 'not_allowed', 'a player reads nothing')
        eq(ask(7, 'console', {}).ok, true, 'an extra ACE reads')
        eq(ask(6, 'console', {}).ok, true)
    end)

    it('scrubs the lines for staff without IdentityAce, exactly as the Alerts do', function()
        local s, f = stack()
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, anonymous = true })
        truthy(c, 'an anonymous contract')
        Log.started()
        Log.always(('contract %s: crediting CREATOR1 (Vic Marlowe, license:aaa) raised'):format(c.id))
        local seen = lineWith(ask(6, 'console', {}).data.recent, c.id).text
        local alert = s.alerts.list('open', 10)[1]
        local alerts = ask(6, 'alerts', {}).data.rows[1].text
        truthy(alert, 'the same line is an alert')
        eq(seen, alerts, 'the Console reads it as the Alerts do')
        for _, needle in ipairs({ 'CREATOR1', 'Vic Marlowe', 'license:aaa' }) do
            falsy(seen:find(needle, 1, true), needle .. ' reaches staff without crimson.identity: ' .. seen)
        end
        truthy(seen:find('the client', 1, true) and seen:find('Anonymous', 1, true), seen)
        local whole = lineWith(ask(8, 'console', {}).data.recent, c.id).text
        truthy(whole:find('CREATOR1', 1, true) and whole:find('Vic Marlowe', 1, true),
            'crimson.identity reads it whole: ' .. whole)
    end)

    it('never shows a webhook address, a convar secret or a statement\'s values, to anybody', function()
        stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK
        Natives.convars.mysql_connection_string = 'mysql://root:hunter2secret@localhost/qbox'
        Log.started()
        Log.always('posting alerts to ' .. HOOK .. ' failed')
        Log.debug('oxmysql: user=root;password=hunter2secret;host=127.0.0.1 refused')
        Log.debug('could not reach mysql://root:hunter2secret@localhost/qbox')
        Log.debug('a webhook typed by hand: discord.com/api/webhooks/999/other-token')
        Log.always('crimson-hitman was unable to execute a query!\nQuery: UPDATE crimson_contracts '
            .. 'SET reason = ? WHERE id = ?\n["Vic Marlowe owes","ct00000001"]\nDeadlock found')
        Log.debug('served at https://photos.example.com/crimson-hitman/p/unguessableName.jpg')
        for _, src in ipairs({ 6, 7, 8 }) do
            local reply = ask(src, 'console', {})
            eq(reply.ok, true)
            for _, text in ipairs(strings(reply)) do
                for _, needle in ipairs({ 'hook-token-secret', '123456', 'hunter2secret', 'other-token',
                                          'owes', 'unguessableName' }) do
                    falsy(text:find(needle, 1, true), ('%s reached staff %d: %s'):format(needle, src, text))
                end
            end
            local recent = reply.data.recent
            truthy(lineWith(recent, 'Deadlock found'), 'the database\'s own words are kept')
            truthy(lineWith(recent, 'https://photos.example.com'), 'and an address\'s host')
            truthy(lineWith(recent, 'posting alerts to'), 'and the line around a secret')
        end
    end)

    it('puts a staff command as the panel\'s own place for it', function()
        stack()
        Log.started()
        Log.always(('left for staff: see /%s'):format(Config.Admin.Commands.stuck))
        local text = ask(7, 'console', {}).data.recent[1].text
        falsy(text:find('/' .. Config.Admin.Commands.stuck, 1, true), text)
        truthy(text:find('Stuck escrow', 1, true), text)
    end)
end)

--------------------------------------------------------------------------
-- Removing the kill photos kept from before
--------------------------------------------------------------------------

describe('the button that removes the kill photos kept from before', function()
    it('is offered only while kill photos are off and some are kept', function()
        local none = stack()
        falsy(ask(6, 'settings', {}).data.keptPhotos, 'none kept: no button')
        local s = stack()
        keepPhotos(s.storage)
        withConfig({ { Config.Completion, 'KillPhotos', true } }, function()
            falsy(ask(6, 'settings', {}).data.keptPhotos, 'kill photos on: no button')
        end)
        local kept = ask(6, 'settings', {}).data.keptPhotos
        truthy(kept, 'off, with photos kept: the button')
        eq(kept.count, 5)
        eq(kept.files, 2)
        eq(kept.links, 2)
        eq(kept.open, 0)
        eq(ask(6, 'removePhotos', {}).ok, true)
        falsy(ask(6, 'settings', {}).data.keptPhotos, 'and none once they are removed')
        truthy(none, 'a stack with none')
    end)

    it('removes every record and every file, and forgets the links, on every store', function()
        local s, f = stack()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local jsonStore = require('crimson-hitman.server.storage.json')
        jsonStore.open()
        Exec.install(Natives)
        local mysqlStore = require('crimson-hitman.server.storage.mysql')
        mysqlStore.open()
        for _, b in ipairs({ { name = 'memory', store = s.storage }, { name = 'json', store = jsonStore },
                             { name = 'mysql', store = mysqlStore } }) do
            local store = b.store
            s.photos.init({ storage = store, audit = s.audit })
            keepPhotos(store)
            openOne(s, store, f)
            local done = s.photos.removeAll()
            eq(done.removed, 5, b.name)
            eq(done.files, 2, b.name .. ': both files here deleted')
            eq(done.links, 2, b.name .. ': both on the image host forgotten')
            eq(done.left, 0, b.name)
            eq(done.waiting, 1, b.name .. ': the open one left to its view')
            for _, id in ipairs({ 'ph0000000fa1', 'ph0000000fa2', 'ph0000000fa3', 'ph0000000ur1',
                                  'ph0000000ur2' }) do
                falsy(store.readPhoto(id), b.name .. ': ' .. id .. ' is gone')
            end
            eq(Natives.files['data/photos/ph0000000fa1.jpg'], nil, b.name)
            eq(Natives.files['data/photos/kept/ph0000000fa2.jpg'], nil, b.name)
            eq(store.readPhoto('ph0000000op1').state, CH.PHOTO.OPEN, b.name .. ': never mid-view')
            eq(store.photoCounts().total, 1, b.name)

            -- The view closes: then it goes.
            local closed = s.photos.decide(f.creator, 'ph0000000op1', 'delete')
            truthy(closed, b.name .. ': the client\'s choice is answered')
            falsy(store.readPhoto('ph0000000op1'), b.name .. ': removed when its view closed')
            eq(store.photoCounts().total, 0, b.name)
            falsy(store.anyPhoto(), b.name)

            local again = s.photos.removeAll()
            eq(again.removed + again.waiting, 0, b.name .. ': the second time does nothing')
        end
    end)

    it('leaves a photo opened while it runs to that view, on every store', function()
        local s, f = stack()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local jsonStore = require('crimson-hitman.server.storage.json')
        jsonStore.open()
        Exec.install(Natives)
        local mysqlStore = require('crimson-hitman.server.storage.mysql')
        mysqlStore.open()
        for _, b in ipairs({ { name = 'memory', store = s.storage }, { name = 'json', store = jsonStore },
                             { name = 'mysql', store = mysqlStore } }) do
            -- The client opens one between the read and the delete.
            local racing = setmetatable({
                deletePhotosIn = function(list)
                    b.store.openPhoto('ph0000000ur1', os.time())
                    return b.store.deletePhotosIn(list)
                end,
            }, { __index = b.store })
            s.photos.init({ storage = racing, audit = s.audit })
            keepPhotos(b.store)
            local done = s.photos.removeAll()
            eq(done.removed, 4, b.name)
            eq(done.waiting, 1, b.name)
            eq(b.store.readPhoto('ph0000000ur1').state, CH.PHOTO.OPEN, b.name .. ': left open')
            truthy(s.photos.decide(f.creator, 'ph0000000ur1', 'save'), b.name .. ': saved to the phone')
            falsy(b.store.readPhoto('ph0000000ur1'), b.name .. ': and removed then')
        end
    end)

    it('removes one left open when it times out, and tells a client who keeps it that it is gone', function()
        local s, f = stack()
        openOne(s, s.storage, f)
        s.storage.writePhoto({ id = 'ph0000000op2', kind = 'url', url = 'https://cdn.fivemanage.com/two.png',
            state = CH.PHOTO.PENDING, contract_id = 'ct00000008', slot = 1, owner_cid = 'CREATOR1',
            created_at = os.time() - 5 })
        truthy(s.photos.open(f.creator, 'ph0000000op2'))
        local reply = ask(6, 'removePhotos', {})
        eq(reply.ok, true)
        eq(reply.data.waiting, 2)
        truthy(reply.message:find('2 open on a phone right now: each is removed when that view closes', 1, true),
            reply.message)
        local kept, err = s.photos.decide(f.creator, 'ph0000000op2', 'keep')
        falsy(kept, 'not kept in the app')
        eq(err, CH.ERR.PHOTO_GONE)
        falsy(s.storage.readPhoto('ph0000000op2'), 'removed as its view closed')
        truthy(s.storage.readPhoto('ph0000000op1'), 'the other is still open')
        Env.advance((tonumber(Config.Completion.PhotoOpenSeconds) or 600) + 1)
        s.photos.expire()
        falsy(s.storage.readPhoto('ph0000000op1'), 'removed once it timed out')
    end)

    it('says the pictures on the image host stay there, and what it deleted here', function()
        local s = stack()
        keepPhotos(s.storage)
        local reply = ask(6, 'removePhotos', {})
        eq(reply.ok, true, tostring(reply.message))
        truthy(reply.message:find('Removed 5 kill photo(s).', 1, true), reply.message)
        truthy(reply.message:find('2 file(s) deleted from this server.', 1, true), reply.message)
        truthy(reply.message:find('2 were on lb-phone\'s image host: this server has forgotten them, and the '
            .. 'pictures stay on the host.', 1, true), reply.message)
        local again = ask(6, 'removePhotos', {})
        eq(again.ok, true)
        eq(again.message, 'No kill photos are kept from before; nothing to remove.')
    end)

    it('needs the ACE itself, is on the record with the count, and spends the write allowance', function()
        local s = stack()
        keepPhotos(s.storage)
        eq(ask(7, 'removePhotos', {}).err, 'not_allowed', 'an extra ACE only reads')
        eq(ask(3, 'removePhotos', {}).err, 'not_allowed', 'a player does nothing')
        truthy(s.storage.readPhoto('ph0000000fa1'), 'nothing removed')
        withConfig({ { Config.Completion, 'KillPhotos', true } }, function()
            local on = ask(6, 'removePhotos', {})
            eq(on.err, 'photos_on')
            truthy(on.message:find('turn them off first', 1, true), on.message)
        end)
        truthy(s.storage.readPhoto('ph0000000fa1'), 'nothing removed while kill photos are on')
        Config.Cooldowns.adminWrite = { per = 60, burst = 2 }
        eq(ask(6, 'removePhotos', {}).ok, true)
        eq(ask(6, 'removePhotos', {}).ok, true, 'safe to run twice')
        eq(ask(6, 'removePhotos', {}).err, 'rate_limited')
        s.audit.flush()
        local rows = s.storage.auditByAction('admin_photos_removed')
        eq(#rows, 2, 'each one on the record')
        local counts = {}
        for _, row in ipairs(rows) do
            eq(row.actor_cid, 'ADMIN001')
            counts[#counts + 1] = row.detail.count
        end
        table.sort(counts)
        eq(counts[1], 0, 'the second removed nothing')
        eq(counts[2], 5, 'the first, with the count')
    end)
end)
