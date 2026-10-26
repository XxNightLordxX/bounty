--- Staff commands in F8, and as buttons (server/bridges.lua, server/panel.lua).
---
--- A command a player runs prints its whole answer in their own F8 console,
--- never in chat, batched in order under the net event size limit, with
--- FiveM's colour codes taken out of what players wrote and one notice on
--- their screen saying where it went. The server console prints there as
--- before. Every command has a button or form in the admin panel that does
--- the same thing with the same permission, the same two clicks and the
--- same audit row, and nothing in the panel names a command.

--- Three staff beside the usual three players: crimson.admin, an extra ACE
--- only (reads), and crimson.admin with crimson.identity.
local function stack()
    local s = newStack()
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
    s.bridges.install(s)
    return s, f
end

local function place(s, f, opts)
    opts = opts or {}
    local c, err = s.contracts.create(f.creator, {
        targetCid = opts.target or 'TARGET01', reason = opts.reason or 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } }, anonymous = opts.anonymous,
    })
    truthy(c, 'placing it: ' .. tostring(err))
    if opts.accept then truthy(s.contracts.accept(f.hitman, c.id, false)) end
    return c
end

--- Run a command as a source and collect what it sent where.
local function run(src, key, args)
    Env.clientEvents, Env.chat, Env.console = {}, {}, {}
    local name = key == 'bailout' and Config.Bailout.Command or Config.Admin.Commands[key]
    local handler = Env.commands[name]
    truthy(handler, 'no command registered as ' .. tostring(name))
    local ok, err = pcall(handler, src, args or {})
    truthy(ok, name .. ' raised: ' .. tostring(err))
    local out = { f8 = {}, chat = {}, notices = {}, events = 0, console = {} }
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:commandOutput' then
            out.events = out.events + 1
            eq(event.target, src, 'sent to whoever ran it, and nobody else')
            for _, line in ipairs(event.args[1]) do out.f8[#out.f8 + 1] = line end
        elseif event.name == 'chat:addMessage' then
            out.chat[#out.chat + 1] = event
        elseif event.name == 'crimson-hitman:notify' then
            out.notices[#out.notices + 1] = event
        end
    end
    for _, line in ipairs(Env.console) do out.console[#out.console + 1] = line end
    return out
end

--- One request from the panel's page, as its client sends it.
local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 9 })
    _G.source = nil
    truthy(fired, 'the panel request raised: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

local function rows(s, action)
    s.audit.flush()
    return #(s.storage.auditByAction(action, 200) or {})
end

--- Every string in a value, keys and all.
local function strings(value, out)
    out = out or {}
    if type(value) == 'string' then
        out[#out + 1] = value
    elseif type(value) == 'table' then
        for k, v in pairs(value) do
            strings(k, out)
            strings(v, out)
        end
    end
    return out
end

--- What in a value names a command: '/ch-', '/hitmanadmin', or '/' and the
--- name of any of Config.Admin.Commands.
local function commandMention(value)
    local needles = { '/ch-', '/hitmanadmin' }
    for _, name in pairs(Config.Admin.Commands) do needles[#needles + 1] = '/' .. name end
    for _, text in ipairs(strings(value)) do
        for _, needle in ipairs(needles) do
            if text:find(needle, 1, true) then return text end
        end
    end
    return nil
end

describe('a staff command\'s answer', function()
    it('goes to the player\'s F8 console, never to chat, with one notice to look there', function()
        local s = stack()
        local out = run(6, 'stuck')
        eq(#out.chat, 0, 'nothing in chat')
        eq(out.events, 1, 'one event')
        eq(table.concat(out.f8, '|'), 'No interrupted releases.')
        eq(#out.notices, 1, 'one notice')
        eq(out.notices[1].target, 6)
        eq(out.notices[1].args[1].content, 'Printed to your F8 console')
        eq(#out.console, 0, 'and nothing in the server console')
        local _ = s
    end)

    it('is printed in the server console when the console ran it, whatever Debug says', function()
        stack()
        Config.Debug = false
        local out = run(0, 'stuck')
        eq(table.concat(out.console, '|'), 'No interrupted releases.')
        eq(out.events, 0, 'no client event')
        eq(#out.notices, 0)
        eq(#out.chat, 0)
    end)

    it('is the same answer in F8 as in the console, line for line', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        local atConsole = run(0, 'timeline', { c.id }).console
        local inF8 = run(6, 'timeline', { c.id }).f8
        truthy(#atConsole > 3, 'a few lines to compare')
        eq(table.concat(inF8, '\n'), table.concat(atConsole, '\n'))
    end)

    it('says so in F8 when the player may not run it', function()
        stack()
        local out = run(7, 'void', { 'ct00000001' })
        truthy(table.concat(out.f8, ' '):find('Not authorised', 1, true), table.concat(out.f8, ' '))
        eq(#out.chat, 0)
        eq(#out.notices, 1)
    end)

    -- The players' buyout command is not one of Config.Admin.Commands: a
    -- target the app is closed to looks for its answer where they typed it.
    it('leaves the players\' buyout command answering in chat, not in F8', function()
        stack()
        local out = run(2, 'bailout')
        eq(#out.f8, 0, 'nothing in F8')
        eq(out.events, 0)
        eq(#out.notices, 0, 'no "Printed to your F8 console" notice')
        eq(#out.chat, 1, 'its answer in chat')
        eq(out.chat[1].target, 2, 'to whoever ran it')
        eq(out.chat[1].args[1].args[2], 'Nothing is out on you.')
    end)

    it('takes the colour codes out of what players wrote', function()
        local s, f = stack()
        Env.players[1].PlayerData.charinfo.firstname = '^1Vic^7'
        Env.players[2].PlayerData.charinfo.lastname = 'Re^3yes'
        f.creator = s.identity.resolve(1)
        local c = place(s, f)
        local out = run(8, 'whois', { c.id })
        local said = table.concat(out.f8, '\n')
        truthy(said:find('Vic', 1, true) and said:find('Reyes', 1, true), said)
        falsy(said:find('%^%d'), 'a colour code reached F8: ' .. said)
        local console = table.concat(run(0, 'whois', { c.id }).console, '\n')
        falsy(console:find('%^%d'), 'or the server console: ' .. console)
        eq(s.bridges.plainLine('a^1b^9c^x^'), 'abc^x^', 'only ^ and a digit')
    end)

    -- One pass took the inner code out of '^^11' and left the outer one
    -- live: '^1Vic' in staff F8, colouring the rest of the line.
    it('takes nested colour codes out until none is left', function()
        local s, f = stack()
        eq(s.bridges.plainLine('^^11Dana ^^^222x'), 'Dana x')
        eq(s.bridges.plainLine('^^^111Vic'), 'Vic')
        eq(s.bridges.plainLine('^^1'), '^', 'a caret with no digit after it is text')
        Env.players[1].PlayerData.charinfo.firstname = '^^11Vic'
        f.creator = s.identity.resolve(1)
        local c = place(s, f)
        local said = table.concat(run(8, 'whois', { c.id }).f8, '\n')
        truthy(said:find('Vic Marlowe', 1, true), said)
        falsy(said:find('%^%d'), 'a colour code reached F8: ' .. said)
        local console = table.concat(run(0, 'whois', { c.id }).console, '\n')
        falsy(console:find('%^%d'), 'or the server console: ' .. console)
    end)
end)

describe('the page log the diagnosis asks a player\'s app for', function()
    --- Player 2's page answering what it was asked, as it does.
    local function pageAnswers(src, stackText)
        _G.source = src
        local ok, err = pcall(Env.events['crimson-hitman:pageError'], {
            what = 'page diagnostics', where = 'requested', stack = stackText, build = 'test' })
        _G.source = nil
        truthy(ok, tostring(err))
    end

    local function sent(name, target)
        local out = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == name then
                eq(event.target, target, 'sent to whoever asked, and nobody else')
                out[#out + 1] = event
            end
        end
        return out
    end

    it('goes to the F8 console of the staff member who asked, never the server console', function()
        local s = stack()
        s.app.init(s)
        Config.Debug = false
        local asked = run(6, 'diagnose', { '2' })
        local report = table.concat(asked.f8, '\n')
        truthy(report:find('the answer follows here', 1, true), report)
        falsy(report:find('server console within', 1, true), report)

        Env.clientEvents, Env.console = {}, {}
        pageAnswers(2, '1.0s post list || 1.2s ^^11reply list ok')
        local events = sent('crimson-hitman:commandOutput', 6)
        eq(#events, 1, 'the whole log in one event')
        local said = table.concat(events[1].args[1], '\n')
        truthy(said:find('page: 1.0s post list', 1, true), said)
        truthy(said:find('page: 1.2s reply list ok', 1, true), said)
        falsy(said:find('%^%d'), 'a colour code reached F8: ' .. said)
        eq(#Env.console, 0, 'nothing in the server console: ' .. table.concat(Env.console, '\n'))
    end)

    it('goes to the open admin panel of the staff member who ran the diagnosis there', function()
        local s = stack()
        s.app.init(s)
        Config.Debug = false
        local reply = ask(6, 'diag', { subject = 2 })
        truthy(reply and reply.ok, tostring(reply and reply.message))
        local report = table.concat(reply.data.lines, '\n')
        truthy(report:find('the answer follows here', 1, true), report)

        Env.clientEvents, Env.console = {}, {}
        pageAnswers(2, 'first event || second event')
        local lines = {}
        for _, event in ipairs(sent('crimson-hitman:adminPush', 6)) do
            eq(event.args[1].kind, 'diag')
            lines[#lines + 1] = event.args[1].line
        end
        local said = table.concat(lines, '\n')
        truthy(said:find('page: first event', 1, true) and said:find('page: second event', 1, true), said)
        eq(#sent('crimson-hitman:commandOutput', 6), 0, 'not to F8')
        eq(#Env.console, 0, 'nor the server console')
    end)

    it('is printed in the server console when the console asked, whatever Debug says', function()
        local s = stack()
        s.app.init(s)
        Config.Debug = false
        run(0, 'diagnose', { '2' })
        Env.clientEvents, Env.console = {}, {}
        pageAnswers(2, 'first event || second event')
        local said = table.concat(Env.console, '\n')
        truthy(said:find('page: first event', 1, true) and said:find('page: second event', 1, true), said)
        eq(#sent('crimson-hitman:commandOutput', 6), 0)
    end)

    --- The diagnosis runs the whitelisted-job view's read for a player the
    --- app bars, and asks their page for its log as it asks anybody's: the
    --- answer comes back through the page's fault report, which refused them.
    it('comes back from a player on the whitelisted-job view, as from anybody', function()
        local s = stack()
        s.app.init(s)
        Config.Debug = false
        Env.players[2].PlayerData.job = { name = 'police', label = 'Police', type = 'leo', onduty = true }
        local report = table.concat(run(6, 'diagnose', { '2' }).f8, '\n')
        truthy(report:find('whitelistedView', 1, true), 'the view\'s read is run: ' .. report)
        truthy(report:find('the answer follows here', 1, true), report)

        Env.clientEvents, Env.console = {}, {}
        pageAnswers(2, 'post whitelistedView || reply whitelistedView ok')
        local events = sent('crimson-hitman:commandOutput', 6)
        eq(#events, 1, 'the log reached the staff member who asked')
        local said = table.concat(events[1].args[1], '\n')
        truthy(said:find('page: reply whitelistedView ok', 1, true), said)
        eq(#Env.console, 0, 'and nothing reached the server console')
    end)

    it('is said not to come from a player the app bars while the view is off', function()
        local s = stack()
        s.app.init(s)
        Config.WhitelistedView.Enabled = false
        Env.players[2].PlayerData.job = { name = 'police', label = 'Police', type = 'leo', onduty = true }
        local report = table.concat(run(6, 'diagnose', { '2' }).f8, '\n')
        truthy(report:find('their app cannot send its log', 1, true), report)
        falsy(report:find('the answer follows here', 1, true), 'nothing is promised: ' .. report)
    end)
end)

describe('batching a command\'s answer', function()
    local function sent()
        local events = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:commandOutput' then events[#events + 1] = event.args[1] end
        end
        return events
    end

    it('sends a long answer in as few events as fit, in order, each under the limit', function()
        local s = stack()
        local limit = s.bridges.OUTPUT_EVENT_BYTES
        local lines, total = {}, 0
        for i = 1, 300 do
            lines[i] = ('line %03d '):format(i) .. string.rep('x', 90)
            total = total + #lines[i]
        end
        Env.clientEvents = {}
        local events = s.bridges.sendOutput(6, lines, true)
        local batches = sent()
        eq(events, #batches)
        eq(#batches, math.ceil(total / limit), 'as few as fit')
        local joined = {}
        for _, batch in ipairs(batches) do
            local size = 0
            for _, line in ipairs(batch) do
                size = size + #line
                joined[#joined + 1] = line
            end
            truthy(size <= limit, 'a batch of ' .. size .. ' bytes')
        end
        eq(table.concat(joined, '\n'), table.concat(lines, '\n'), 'every line, in order')
        local notices = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:notify' then notices = notices + 1 end
        end
        eq(notices, 1, 'one notice for the whole answer')
    end)

    it('sends a line longer than the limit in pieces, in order', function()
        local s = stack()
        local limit = s.bridges.OUTPUT_EVENT_BYTES
        local long = {}
        for i = 1, 2500 do long[i] = tostring(i % 10) end
        local line = table.concat(long) .. string.rep('y', limit * 2)
        Env.clientEvents = {}
        s.bridges.sendOutput(6, { 'before', line, 'after' }, false)
        local pieces = {}
        for _, batch in ipairs(sent()) do
            for _, piece in ipairs(batch) do
                truthy(#piece <= limit)
                pieces[#pieces + 1] = piece
            end
        end
        eq(pieces[1], 'before')
        eq(pieces[#pieces], 'after')
        eq(table.concat(pieces, '', 2, #pieces - 1), line, 'the long line whole, in order')

        -- Never cut inside a character.
        local dashes = string.rep('—', limit)   -- three bytes each
        Env.clientEvents = {}
        s.bridges.sendOutput(6, { dashes }, false)
        local whole = {}
        for _, batch in ipairs(sent()) do
            for _, piece in ipairs(batch) do
                truthy(utf8.len(piece), 'a piece that is not whole characters')
                whole[#whole + 1] = piece
            end
        end
        eq(table.concat(whole), dashes)
    end)

    --- A player's game prints at most CH.OUTPUT_LINES_MAX lines of one
    --- event (client/admin.lua), and short lines fit far more than that
    --- under the byte limit: the rest were dropped without a word.
    it('starts a new event at the most lines a player\'s game prints of one', function()
        local s = stack()
        local lines = {}
        for i = 1, 1200 do lines[i] = tostring(i % 10) end
        Env.clientEvents = {}
        eq(s.bridges.sendOutput(6, lines, false), 3, 'three events of four hundred')
        local joined = {}
        for _, batch in ipairs(sent()) do
            truthy(#batch <= CH.OUTPUT_LINES_MAX, 'a batch of ' .. #batch .. ' lines')
            for _, line in ipairs(batch) do joined[#joined + 1] = line end
        end
        eq(table.concat(joined), table.concat(lines), 'every line, in order')
        truthy(read_file('crimson-hitman/client/admin.lua'):find('= CH.OUTPUT_LINES_MAX', 1, true),
            'and the client prints by the same number')
    end)

    it('sends nothing, and no notice, for an answer with no lines', function()
        local s = stack()
        Env.clientEvents = {}
        eq(s.bridges.sendOutput(6, {}, true), 0)
        eq(#Env.clientEvents, 0)
    end)
end)

describe('every staff command has a button in the admin panel', function()
    --- The command's gate, as it answers: 'read' if an extra ACE opens it,
    --- 'identity' if crimson.admin alone does not, 'write' otherwise.
    local function gateOf(key)
        local refusedReader = table.concat(run(7, key, {}).f8, ' '):find('Not authorised', 1, true)
        if not refusedReader then return 'read' end
        local refusedAdmin = table.concat(run(6, key, {}).f8, ' '):find('Not authorised', 1, true)
        return refusedAdmin and 'identity' or 'write'
    end

    it('lists every command, and fails for one with no button', function()
        local s = stack()
        local main = require('crimson-hitman.server.main')
        local keys = {}
        for key in pairs(Config.Admin.Commands) do keys[key] = true end
        for key in pairs(main.configDefaults.Admin.Commands) do keys[key] = true end
        for key in pairs(keys) do
            if key ~= 'panel' then
                local entry = s.panel.COMMANDS[key]
                truthy(entry, ('the command %s has no button or form in the admin panel '
                    .. '(Panel.COMMANDS)'):format(key))
                for _, op in ipairs(entry.ops) do
                    truthy(s.panel.OPS[op], key .. ': the panel answers no op ' .. op)
                end
            end
        end
        -- And nothing is registered that is not one of them, the panel's own
        -- or the buyout command.
        local known = { [Config.Bailout.Command] = true }
        for key, name in pairs(Config.Admin.Commands) do known[name] = key end
        for name in pairs(Env.commands) do
            truthy(known[name], name .. ' is a command with no button in the admin panel')
        end
    end)

    it('asks for each of those from the page', function()
        local s = stack()
        local page = read_file('crimson-hitman/ui/admin.js')
        for key, entry in pairs(s.panel.COMMANDS) do
            for _, op in ipairs(entry.ops) do
                truthy(page:find("ask('" .. op .. "'", 1, true) or page:find("write('" .. op .. "'", 1, true),
                    ('%s: the page never asks for %s'):format(key, op))
            end
        end
    end)

    it('with the permission the command has', function()
        local s = stack()
        local LEVELS = s.panel.LEVELS
        for key, entry in pairs(s.panel.COMMANDS) do
            local gate = gateOf(key)
            eq(entry.level, LEVELS[gate:upper()], key .. ': the command is ' .. gate
                .. ', the panel ' .. tostring(entry.level))
            -- The op that does it needs as much in the panel, and no more.
            local most
            for _, op in ipairs(entry.ops) do
                local level = s.panel.OPS[op]
                if not most or level == LEVELS.IDENTITY
                    or (level == LEVELS.WRITE and most == LEVELS.READ) then most = level end
            end
            eq(most, entry.level, key .. ': its ops need ' .. tostring(most))
            if entry.level ~= LEVELS.READ then
                local refused = ask(7, entry.ops[#entry.ops], {})
                eq(refused.ok, false, key .. ' in the panel to an extra ACE')
            end
        end
    end)

    it('writes the same audit row from the button as from the command', function()
        local s, f = stack()
        local function both(key, command, op)
            local action = s.panel.COMMANDS[key].audit
            truthy(action, key .. ' names its row')
            local before = rows(s, action)
            command()
            eq(rows(s, action), before + 1, key .. ': the command wrote ' .. action)
            op()
            eq(rows(s, action), before + 2, key .. ': the button wrote ' .. action)
        end

        -- The second on somebody else: one live contract per player on one target.
        Env.addPlayer({ source = 9, citizenid = 'TARGET02', license = 'license:t2',
            cash = 100, bank = 100, firstname = 'Kit', lastname = 'Bell' })
        local a, b = place(s, f), place(s, f, { reason = 'second', target = 'TARGET02' })
        both('void', function() run(6, 'void', { a.id, 'checked' }) end,
            function() truthy(ask(6, 'void', { id = b.id, reason = 'checked' }).ok) end)
        both('stuck', function() run(6, 'stuck') end, function() truthy(ask(6, 'stuck').ok) end)
        both('contracts', function() run(6, 'contracts', { 'CREATOR1' }) end,
            function() truthy(ask(6, 'player', { subject = 'CREATOR1' }).ok) end)
        both('whois', function() run(8, 'whois', { a.id }) end,
            function() truthy(ask(8, 'whois', { id = a.id }).ok) end)
        both('refresh', function() run(6, 'refresh', { 'timers' }) end,
            function() truthy(ask(6, 'refresh').ok) end)

        local first = s.review.open({ kind = 'escrow_settle_lost', contract_id = a.id,
            cids = { recipient = 'HITMAN01' } })
        local second = s.review.open({ kind = 'escrow_settle_lost', contract_id = b.id,
            cids = { recipient = 'HITMAN01' } })
        both('review', function() run(6, 'review', { first, 'dismiss', 'checked' }) end,
            function() truthy(ask(6, 'resolve', { id = second, action = 'dismiss', note = 'checked' }).ok) end)

        -- A settle, on two lines a give that kept raising left for staff.
        local c = place(s, f, { accept = true })
        local d = place(s, f, { accept = true, reason = 'fourth', target = 'TARGET02' })
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        for _, contract in ipairs({ c, d }) do
            local line = s.storage.readEscrow(contract.id)[1]
            for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
                pcall(s.escrow.release, contract.id, 'HITMAN01', { line = line.id }, 'test')
            end
        end
        p.Functions.AddMoney = real
        local lc, ld = s.storage.readEscrow(c.id)[1], s.storage.readEscrow(d.id)[1]
        both('settle', function() run(6, 'settle', { lc.id, 'delivered' }) end,
            function() truthy(ask(6, 'settle', { line = ld.id, disposition = 'delivered' }).ok) end)
    end)
end)

describe('the stuck listing in the admin panel', function()
    it('lists every line left for staff with what settles it, and the review queue\'s count', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
            pcall(s.escrow.release, c.id, 'HITMAN01', { line = line.id }, 'test')
        end
        p.Functions.AddMoney = real
        s.review.open({ kind = 'escrow_settle_lost', contract_id = c.id, cids = { recipient = 'HITMAN01' } })

        local reply = ask(7, 'stuck')
        truthy(reply.ok, 'a read, open to the extra ACEs as the command is')
        eq(#reply.data.lines, 1)
        eq(reply.data.lines[1].line, line.id)
        eq(reply.data.lines[1].contract, c.id)
        truthy(table.concat(reply.data.lines[1].actions, ','):find('delivered', 1, true))
        eq(reply.data.reviews, 1)
        eq(reply.data.lines[1].intended, 'an operative', 'a role, to staff without crimson.identity')
    end)

    it('lists nothing while recovery runs', function()
        local s = stack()
        s.app.ready = false
        local reply = ask(6, 'stuck')
        truthy(reply.ok)
        eq(reply.data.lines, nil)
        eq(reply.data.recovery, 'recovering')
        s.app.ready = true
    end)
end)

describe('nothing in the admin panel names a command', function()
    it('in any answer it is sent, refusals and errors included', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        s.review.open({ kind = 'escrow_settle_lost', contract_id = c.id, cids = { recipient = 'HITMAN01' } })
        local requests = {
            { 6, 'access' }, { 6, 'overview' }, { 6, 'contracts', { query = 'Dana' } },
            { 6, 'contract', { id = c.id } }, { 6, 'contract', { id = 'ct99999999' } },
            { 6, 'stuck' }, { 6, 'reviews', { all = true } }, { 6, 'logs' }, { 6, 'settings' },
            { 6, 'player', { subject = 'CREATOR1' } }, { 6, 'player', { subject = 'NOBODY99' } },
            { 6, 'diag' }, { 6, 'diag', { subject = 2 } }, { 8, 'whois', { id = c.id } },
            { 6, 'whois', { id = c.id } }, { 7, 'void', { id = c.id } }, { 7, 'settle', { line = 'x' } },
            { 6, 'void', { id = 'nope' } }, { 6, 'settle', { line = 'ct00000001:1', disposition = 'pay' } },
            { 6, 'settle', { line = 'ct00000001:1' } }, { 6, 'resolve', { id = 'rv00000001', action = 'dismiss' } },
            { 6, 'resolve', { id = 'rv99999999', action = 'pay', who = 'payer' } },
            { 6, 'resolve', { id = 'rv00000001', action = 'refund' } }, { 6, 'nonsense' },
            { 6, 'setSetting', { key = 'Admin.Enabled', value = false } },
            { 6, 'setSetting', { key = 'Bailout.Enabled', value = 'maybe' } },
            { 6, 'resetSetting', { key = 'Bailout.Enabled' } }, { 6, 'refresh' }, { 6, 'flush' },
        }
        for _, r in ipairs(requests) do
            local reply = ask(r[1], r[2], r[3])
            truthy(reply, r[2] .. ' answered')
            local found = commandMention(reply)
            falsy(found, ('%s answers the panel with a command in it: %s'):format(r[2], tostring(found)))
        end

        -- While recovery runs, and after it failed.
        for _, state in ipairs({ 'recovering', 'recovery_failed' }) do
            s.app.ready, s.app.recoveryFailed = false, state == 'recovery_failed'
            for _, op in ipairs({ 'void', 'settle', 'resolve', 'stuck', 'overview' }) do
                falsy(commandMention(ask(6, op, { id = c.id, line = 'ct00000001:1' })), op .. ' ' .. state)
            end
        end
        s.app.ready, s.app.recoveryFailed = true, false
    end)

    it('in the words of every answer to a void, a settle or a review', function()
        local s = stack()
        local errs = { 'recovering', 'recovery_failed', 'stalled_claim', 'live', 'ending_unfinished',
            'queued', 'requeued', 'parked', 'already_queued', 'pay_only', 'owes_less', 'not_left',
            'raised', CH.ERR.LOCKED, CH.ERR.NOT_FOUND, CH.ERR.ALREADY_SETTLED, CH.ERR.BUSY,
            'note_required', 'no_party', 'which_money', 'nothing_recorded', 'over_recorded',
            'being_resolved', 'unwritten', 'nothing_missing', 'not_yet', 'something_else' }
        for _, err in ipairs(errs) do
            for _, ok in ipairs({ true, false }) do
                for _, detail in ipairs({ 'refused', 'ct00000001', { action = 'pay', parked = 1 },
                                          'open', 'resolving' }) do
                    local said = {
                        s.admin.voidAnswer('ct00000001', ok, err, true),
                        s.admin.settleAnswer(ok, err, detail, true),
                        s.admin.reviewAnswer('rv00000001', ok, err, type(detail) == 'table' and detail or nil, true),
                    }
                    falsy(commandMention(said), err .. ': ' .. tostring(commandMention(said)))
                end
            end
        end
        falsy(commandMention(s.admin.howToAuthorise(Config.Admin.Ace, true)))
        -- And the same answers to a command keep the command's words.
        truthy(s.admin.settleAnswer(false, 'parked', nil):find('/' .. Config.Admin.Commands.stuck, 1, true))
        truthy(s.admin.reviewAnswer('rv1', false, 'note_required'):find('/' .. Config.Admin.Commands.review, 1, true))
    end)

    it('in the diagnosis, the console\'s own lines included', function()
        local s, f = stack()
        local c = place(s, f)
        -- Lines the console keeps that name a command: a review left for staff.
        s.review.open({ kind = 'escrow_settle_lost', contract_id = c.id, cids = { recipient = 'HITMAN01' } })
        local lines = s.admin.diagnose(6, nil, nil, { panel = true })
        falsy(commandMention(lines), tostring(commandMention(lines)))
        truthy(table.concat(lines, '\n'):find('see Stuck escrow', 1, true), table.concat(lines, '\n'))
        local atConsole = table.concat(s.admin.diagnose(0), '\n')
        truthy(atConsole:find('/' .. Config.Admin.Commands.stuck, 1, true), 'the console keeps its words')
        eq(s.admin.panelWords('left for staff (/ch-stuck) and /ch-settle <line>; /ch-stucker'),
            'left for staff (Stuck escrow) and Stuck escrow <line>; /ch-stucker')
    end)

    --- A line written with '/ch-diag' in it named a command that does not
    --- exist on a server that renamed them, and the panel, which reads each
    --- configured name as its place, showed it as written.
    it('with the commands renamed, a console line in the diagnosis included', function()
        local s = stack()
        for key, name in pairs(Config.Admin.Commands) do
            if type(name) == 'string' then Config.Admin.Commands[key] = name:gsub('^ch%-', 'hm-') end
        end
        Config.Diagnostics.SlowJobMs = 1
        s.timing.record('audit.flush', 50)
        local reply = ask(6, 'diag', {})
        truthy(reply and reply.ok, tostring(reply and reply.message))
        local text = table.concat(reply.data.lines, '\n')
        truthy(text:find('took 50.0 ms', 1, true), 'the slow job is listed: ' .. text)
        falsy(commandMention(reply.data.lines), tostring(commandMention(reply.data.lines)))
    end)

    it('in no line the server prints: each names the command as configured', function()
        local found = {}
        local list = io.popen('ls crimson-hitman/server/*.lua crimson-hitman/server/*/*.lua')
        for path in list:lines() do
            local n = 0
            for line in io.lines(path) do
                n = n + 1
                if not line:match('^%s*%-%-') and line:find('/ch-', 1, true) then
                    found[#found + 1] = path .. ':' .. n
                end
            end
        end
        list:close()
        eq(#found, 0, 'a command named as /ch-: ' .. table.concat(found, ', '))
    end)
end)

--------------------------------------------------------------------------
-- Money staff send by hand, and what the money commands answer
--------------------------------------------------------------------------

describe('money staff send to a citizen id they type', function()
    --- A held line of a contract never stored, as escrow written before
    --- lines said whose they were leaves one: it names nobody.
    local function orphan(s, id, extra)
        local contractId = id:match('^([^:]+)')
        local line = { id = id, contract_id = contractId, slot = 1, portion = CH.PORTION.BASELINE,
            source = 'bank', amount = 700, state = CH.ESCROW_STATE.HELD }
        for k, v in pairs(extra or {}) do line[k] = v end
        s.storage.writeEscrow(contractId, { line })
        return line
    end
    local function bank(src) return Env.players[src].PlayerData.money.bank end
    local function text(out) return table.concat(out.f8, '\n') end

    it('A01: /ch-settle return takes only a citizen id somebody has, as the server keeps it', function()
        local s = stack()
        orphan(s, 'ct00000099:1')
        orphan(s, 'ct00000098:1')
        orphan(s, 'ct00000097:1')
        -- Owed to an id no character has, as an older build left one: that
        -- it is some line's owed_to does not vouch for it.
        orphan(s, 'ct00000096:1', { portion = CH.PORTION.OWED, owed_to = 'GHOST001' })
        s.storage.queuePending('GHOST001', 'ct00000096', 'ct00000096:1')
        local before = bank(1)

        for _, typo in ipairs({ 'craetor1', 'GHOST001' }) do
            local out = run(6, 'settle', { 'ct00000098:1', 'return', typo })
            truthy(text(out):find('nobody on this server has that citizen id', 1, true), text(out))
            local line = s.storage.readEscrowLine('ct00000098:1')
            eq(line.state, CH.ESCROW_STATE.HELD, typo .. ': nothing moved')
            eq(line.owed_to, nil, typo .. ': owed to nobody still')
            local queued = #s.storage.readPending(typo)
                + (typo:upper() ~= typo and #s.storage.readPending(typo:upper()) or 0)
            eq(queued, typo == 'GHOST001' and 1 or 0, typo .. ': nothing more queued for it')
        end

        local out = run(6, 'settle', { 'ct00000099:1', 'return', 'creator1' })
        local line = s.storage.readEscrowLine('ct00000099:1')
        eq(line.state, CH.ESCROW_STATE.SETTLED, text(out))
        eq(line.settled_to, 'CREATOR1', 'in the form the server keeps it')
        eq(bank(1) - before, 700)

        -- Away, and never a party to anything here: qbx_core's offline
        -- lookup knows the character.
        Env.characters['OFFLINE1'] = true
        run(6, 'settle', { 'ct00000097:1', 'return', 'offline1' })
        eq(s.storage.readEscrowLine('ct00000097:1').owed_to, 'OFFLINE1')
        eq(#s.storage.readPending('OFFLINE1'), 1, 'queued for their next login')
    end)

    it('A01: the panel\'s Return to checks the id the same way', function()
        local s = stack()
        orphan(s, 'ct00000099:1')
        local reply = ask(6, 'settle', { line = 'ct00000099:1', disposition = 'return', owner = 'craetor1' })
        eq(reply.ok, false)
        eq(reply.err, 'no_such_player')
        truthy(reply.message:find('check how it is spelt', 1, true), reply.message)
        eq(s.storage.readEscrowLine('ct00000099:1').state, CH.ESCROW_STATE.HELD)
        eq(ask(6, 'settle', { line = 'ct00000099:1', disposition = 'return', owner = 'creator1' }).ok, true)
        eq(s.storage.readEscrowLine('ct00000099:1').settled_to, 'CREATOR1')
    end)

    it('A01: without qbx_core\'s offline lookup, an id nobody here has is refused, and says why', function()
        local s = stack()
        orphan(s, 'ct00000099:1')
        Natives.noOfflineLookup = true
        local ok, err, detail = s.admin.settleLine(6, 'ct00000099:1', 'return', 'AWAY0001')
        Natives.noOfflineLookup = nil
        falsy(ok)
        eq(err, 'no_such_player')
        eq(detail, 'unchecked')
        truthy(s.admin.settleAnswer(ok, err, detail):find('Try again when they are in the city', 1, true))
        eq(s.storage.readEscrowLine('ct00000099:1').state, CH.ESCROW_STATE.HELD)
    end)

    it('W129: /ch-review takes a role the item names, or an id somebody has, and nothing else', function()
        local s = stack()
        local id = s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01' }, amount = 5000, account = 'bank' })
        for _, word in ipairs({ 'client', 'target02', 'not-a-cid' }) do
            local out = run(6, 'review', { id, 'pay', word })
            truthy(text(out):find('a role the item names (payer)', 1, true), word .. ': ' .. text(out))
            eq(s.storage.readReview(id).state, 'open', word .. ': still open')
        end
        eq(s.storage.readEscrowLine(id .. ':1'), nil, 'no line owed to a word nobody has')

        local before = bank(2)
        local out = run(6, 'review', { id, 'pay', 'Payer' })
        eq(s.storage.readReview(id).state, 'resolved', text(out))
        eq(bank(2) - before, 5000, 'paid to the payer the item names')

        -- And an id typed in lower case is the player the server knows.
        local other = s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01' }, amount = 100, account = 'bank' })
        truthy(s.admin.resolveReview(0, other, { 'pay', 'target01' }))
        eq(s.storage.readReview(other).resolution.cid, 'TARGET01')
    end)

    it('W129: lists a line owed and queued to an id nobody has, and moves it to the right one', function()
        local s = stack()
        -- Left so before ids were checked: returned to 'creator1'.
        orphan(s, 'ct00000099:1', { owed_to = 'creator1' })
        s.storage.queuePending('creator1', 'ct00000099', 'ct00000099:1')
        Env.removePlayer(1)

        local listed = ask(6, 'stuck').data.lines
        eq(#listed, 1)
        eq(listed[1].why, 'owed_to_nobody')
        eq(table.concat(listed[1].actions, ','), 'return_owner')
        eq(listed[1].intended, 'a citizen id no character has', 'not the id, without crimson.identity')
        eq(ask(8, 'stuck').data.lines[1].intended, 'creator1', 'the id, with it')
        local out = run(6, 'stuck')
        truthy(text(out):find('owed and queued to a citizen id no character has', 1, true), text(out))
        truthy(text(out):find('ct00000099:1 return <citizenid>', 1, true), text(out))

        -- Pay has nobody to go to, and a typo is refused as before.
        out = run(6, 'settle', { 'ct00000099:1', 'pay' })
        truthy(text(out):find('so nothing would ever give it', 1, true), text(out))
        out = run(6, 'settle', { 'ct00000099:1', 'return', 'craetor1' })
        truthy(text(out):find('nobody on this server has that citizen id', 1, true), text(out))

        out = run(6, 'settle', { 'ct00000099:1', 'return', 'CREATOR1' })
        truthy(text(out):find('Re-pointed', 1, true), text(out))
        local line = s.storage.readEscrowLine('ct00000099:1')
        eq(line.owed_to, 'CREATOR1')
        eq(line.state, CH.ESCROW_STATE.HELD, 'away, so held for their login')
        eq(#s.storage.readPending('CREATOR1'), 1, 'queued for them, once')
        eq(#s.storage.readPending('creator1'), 0, 'and no longer for nobody')
        s.audit.flush()
        local rows = s.storage.auditByAction('admin_settle_repointed', 10)
        eq(#rows, 1, 'on the record')
        eq(rows[1].detail.from, 'creator1')
        eq(rows[1].detail.to, 'CREATOR1')
        eq(#ask(6, 'stuck').data.lines, 0, 'and no longer waiting for staff')
    end)

    it('W129: one whose id could not be checked is listed so, and not moved', function()
        local s = stack()
        orphan(s, 'ct00000099:1', { owed_to = 'creator1' })
        s.storage.queuePending('creator1', 'ct00000099', 'ct00000099:1')
        Natives.noOfflineLookup = true
        local listed = s.admin.interrupted(0, true)
        local ok, err = s.admin.settleLine(0, 'ct00000099:1', 'return', 'CREATOR1')
        Natives.noOfflineLookup = nil
        eq(#listed, 1)
        eq(listed[1].why, 'owed_to_unchecked')
        falsy(ok)
        eq(err, 'unchecked')
        eq(s.storage.readEscrowLine('ct00000099:1').owed_to, 'creator1', 'left where it was')
    end)
end)

describe('what the money commands answer', function()
    it('W135: puts every refusal of a void or a settle into a sentence with a next step', function()
        local s, f = stack()
        local c = place(s, f)
        local function said(key, args)
            return table.concat(run(6, key, args).f8, '\n')
        end
        local cases = {
            { 'void', {}, 'Usage: /' .. Config.Admin.Commands.void },
            { 'void', { 'ct99999999' }, 'No contract has that id' },
            { 'settle', {}, 'Usage: /' .. Config.Admin.Commands.settle },
            { 'settle', { 'ct99999999:1', 'pay' }, 'No escrow line has that id' },
            { 'settle', { c.id .. ':1', 'nonsense' }, 'Usage: /' .. Config.Admin.Commands.settle },
        }
        for _, case in ipairs(cases) do
            local out = said(case[1], case[2])
            truthy(out:find(case[3], 1, true), case[1] .. ': ' .. out)
            falsy(out:find('invalid_input', 1, true) or out:find('not_found', 1, true), out)
        end
        truthy(s.admin.void(0, c.id, 'checked'))
        local again = said('void', { c.id })
        truthy(again:find('Already closed', 1, true), again)
        falsy(again:find('already_settled', 1, true), again)

        -- Every code a void or a settle answers is a sentence, both ways,
        -- never the fallback that says the code.
        local codes = {
            settle = { CH.ERR.INVALID_INPUT, CH.ERR.NOT_FOUND, CH.ERR.ALREADY_SETTLED, CH.ERR.LOCKED,
                'no_such_player', 'owed_to_nobody', 'unchecked', 'return_only', 'pay_only',
                'owes_less', 'raised', 'live', 'ending_unfinished', 'already_queued', 'not_left' },
            void = { CH.ERR.INVALID_INPUT, CH.ERR.NOT_FOUND, CH.ERR.ALREADY_SETTLED, CH.ERR.LOCKED,
                'raised', 'stalled_claim' },
        }
        for _, panel in ipairs({ false, true }) do
            for _, err in ipairs(codes.settle) do
                local line = s.admin.settleAnswer(false, err, 5000, panel)
                falsy(line:find('(' .. err .. ')', 1, true), err .. ' said raw: ' .. line)
            end
            for _, err in ipairs(codes.void) do
                for _, detail in ipairs({ 'closed', 'open' }) do
                    local line = s.admin.voidAnswer(c.id, false, err, panel, detail)
                    falsy(line:find('(' .. err .. ')', 1, true), err .. ' said raw: ' .. line)
                end
            end
        end
        truthy(s.admin.settleAnswer(false, 'owes_less', 4000):find('owes only 4000', 1, true))
        truthy(s.admin.reviewAnswer('rv1', false, 'no_party', 'payer, creator')
            :find('(payer, creator)', 1, true))
    end)
end)


--- W131, W137: a resolution that raised part-way leaves the item being
--- resolved with its decision on it. "/ch-review <id> finishes it" printed
--- the usage line, and another action's words carried out the stored one:
--- money moved under Dismiss. The id alone finishes it now, in the command
--- and as the panel's one button, and nothing else does.
describe('a review item left part-way resolved', function()
    local function bank(src) return Env.players[src].PlayerData.money.bank end

    local function stranded(s)
        return s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01' }, amount = 5000, account = 'bank' })
    end

    local function leftResolving(s)
        local id = stranded(s)
        truthy(s.storage.setReviewState(id, 'open', 'resolving', {
            resolution = { action = 'refund', cid = 'TARGET01',
                lines = { { id = id .. ':1', source = 'bank', amount = 5000 } } },
            resolved_by = 'console' }))
        return id
    end

    local function said(key, args)
        return table.concat(run(6, key, args).f8, '\n')
    end

    it('/ch-review <id> alone finishes it as decided, and another action is refused', function()
        local s = stack()
        local id = leftResolving(s)
        local before = bank(2)
        local out = said('review', { id, 'dismiss', 'nothing', 'owed' })
        truthy(out:find('being resolved already', 1, true), out)
        truthy(out:find(('/%s %s alone finishes it'):format(Config.Admin.Commands.review, id), 1, true), out)
        eq(bank(2), before, 'nothing moved under a dismiss')
        eq(s.storage.readReview(id).state, 'resolving')

        out = said('review', { id })
        truthy(out:find('Resolved', 1, true), out)
        truthy(out:find('finished as decided', 1, true), out)
        eq(bank(2) - before, 5000, 'finished as it was decided')
        eq(s.storage.readReview(id).state, 'resolved')

        local open = stranded(s)
        out = said('review', { open })
        truthy(out:find('Usage', 1, true), 'an open one still needs an action: ' .. out)
        eq(s.storage.readReview(open).state, 'open')
    end)

    it('the panel finishes it with one button, and refuses another action on it', function()
        local s = stack()
        local id = leftResolving(s)
        local before = bank(2)
        local reply = ask(6, 'resolve', { id = id, action = 'dismiss', note = 'nothing owed after all' })
        eq(reply.ok, false)
        eq(reply.err, 'being_resolved')
        truthy(reply.message:find('Finish as decided', 1, true), reply.message)
        falsy(commandMention(reply.message), reply.message)
        eq(bank(2), before, 'nothing moved under Dismiss')

        reply = ask(6, 'resolve', { id = id, action = 'finish' })
        eq(reply.ok, true, tostring(reply.message))
        eq(bank(2) - before, 5000)
        eq(ask(6, 'resolve', { id = id, action = 'finish' }).ok, false, 'once')
        eq(bank(2) - before, 5000)
    end)

    it('a raise says whether anything was decided, from the item as it is after it', function()
        local s = stack()
        local id = stranded(s)
        local real = s.storage.setReviewState
        s.storage.setReviewState = function() error('connection lost', 0) end
        local out = said('review', { id, 'refund', 'payer', '5000' })
        s.storage.setReviewState = real
        truthy(out:find('before anything was decided', 1, true), out)
        falsy(out:find('finishes it', 1, true), 'nothing to finish: ' .. out)
        eq(s.storage.readReview(id).state, 'open')

        local realRelease = s.escrow.release
        s.escrow.release = function() error('a payout hook raised', 0) end
        out = said('review', { id, 'refund', 'payer', '5000' })
        s.escrow.release = realRelease
        truthy(out:find('part-way', 1, true), out)
        truthy(out:find(('/%s %s finishes it'):format(Config.Admin.Commands.review, id), 1, true), out)
        eq(s.storage.readReview(id).state, 'resolving')
        truthy(said('review', { id }):find('Resolved', 1, true), 'and the id alone does')
    end)
end)
