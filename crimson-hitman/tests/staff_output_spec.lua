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
        targetCid = 'TARGET01', reason = opts.reason or 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
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

    it('goes to F8 for the buyout command too', function()
        stack()
        local out = run(2, 'bailout')
        truthy(#out.f8 > 0, 'it answered')
        eq(#out.chat, 0, 'not in chat')
        eq(#out.notices, 1)
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

        local a, b = place(s, f), place(s, f, { reason = 'second' })
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
        local d = place(s, f, { accept = true, reason = 'fourth' })
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
            'something_else' }
        for _, err in ipairs(errs) do
            for _, ok in ipairs({ true, false }) do
                for _, detail in ipairs({ 'refused', 'ct00000001', { action = 'pay', parked = 1 } }) do
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
end)
