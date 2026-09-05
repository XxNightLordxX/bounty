local function call(name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return nil, 'no handler ' .. name end
    Env.clientEvents = {}
    _G.source = source
    fire(payload or {})
    _G.source = nil
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

describe('PROBE flood gate vs the real opening sequence', function()
    it('the 21st request in 10s is dropped with no reply at all', function()
        local s = newStack()
        local f = fixture(s)
        for i = 20, 40 do
            Env.addPlayer({ source = i, citizenid = 'PERSON' .. i, license = 'license:p' .. i,
                firstname = 'Ada', lastname = 'Q' .. i })
        end
        -- the page's opening sequence: list, mine, ledger, then one
        -- mugshotImage per board card (Config.Listing.PageSize = 15)
        call('list', 1, { page = 1 })
        call('mine', 1, {})
        call('ledger', 1, {})
        for i = 1, 15 do call('mugshotImage', 1, { id = 'ref' .. i }) end
        -- loadProposals: one 'amendments' per contract this player is party to
        for i = 1, 2 do call('amendments', 1, { id = 'ct0000000' .. i }) end
        -- now the player taps Place
        local w = call('rewardOptions', 1, {})
        local b = call('browseTargets', 1, { scope = 'all', query = '', page = 1 })
        io.write('\n  requests before Place: 20\n')
        io.write('  rewardOptions -> ' .. (w == nil and 'NO REPLY (flood-dropped)' or (w.ok and 'ok' or w.err)) .. '\n')
        io.write('  browseTargets -> ' .. (b == nil and 'NO REPLY (flood-dropped)' or (b.ok and ('ok people=' .. #b.data.people) or b.err)) .. '\n')
        io.write('  gameTimer during all of this: ' .. Env.gameTimer .. 'ms\n')
    end)
end)
