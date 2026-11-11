--- Scenery NPCs on the client (client/npc.lua, CrimsonNpc): the
--- logged-in check, a capped model load, a local ped made safe, removal
--- and blips. Loaded in an environment of its own with the natives it uses.

local function client(opts)
    opts = opts or {}
    local t = { calls = {}, peds = {}, made = 0, loaded = opts.loaded ~= false, waited = 0 }
    local function note(name) return function(...) t.calls[#t.calls + 1] = { name, ... } end end
    local env = setmetatable({
        joaat = function(model) return #model end,
        IsModelInCdimage = function() return opts.inGame ~= false and 1 or false end,
        IsModelValid = function() return opts.valid ~= false and 1 or false end,
        RequestModel = note('RequestModel'),
        HasModelLoaded = function() return t.loaded end,
        SetModelAsNoLongerNeeded = note('SetModelAsNoLongerNeeded'),
        Wait = function(ms) t.waited = t.waited + ms end,
        CreatePed = function(...)
            t.calls[#t.calls + 1] = { 'CreatePed', ... }
            if opts.noPed then return 0 end
            t.made = t.made + 1
            t.peds[100 + t.made] = true
            return 100 + t.made
        end,
        SetEntityInvincible = note('SetEntityInvincible'),
        FreezeEntityPosition = note('FreezeEntityPosition'),
        SetBlockingOfNonTemporaryEvents = note('SetBlockingOfNonTemporaryEvents'),
        SetPedCanRagdoll = note('SetPedCanRagdoll'),
        TaskStartScenarioInPlace = note('TaskStartScenarioInPlace'),
        DoesEntityExist = function(ped) return t.peds[ped] and 1 or false end,
        DeleteEntity = function(ped) t.peds[ped] = nil; t.calls[#t.calls + 1] = { 'DeleteEntity', ped } end,
        AddBlipForCoord = function() return 77 end,
        SetBlipSprite = note('SetBlipSprite'), SetBlipScale = note('SetBlipScale'),
        SetBlipAsShortRange = note('SetBlipAsShortRange'),
        BeginTextCommandSetBlipName = note('BeginTextCommandSetBlipName'),
        AddTextComponentSubstringPlayerName = note('AddTextComponentSubstringPlayerName'),
        EndTextCommandSetBlipName = note('EndTextCommandSetBlipName'),
        LocalPlayer = opts.state and { state = opts.state } or nil,
        GetResourceState = function(name) return name == 'ox_target' and (opts.target or 'started') or 'missing' end,
    }, { __index = _G })
    if opts.noLocalPlayer then rawset(env, 'LocalPlayer', false) end
    require('tests.harness.client_adapters')(env)
    t.npc = assert(loadfile('crimson-hitman/client/npc.lua', 't', env))()
    t.env = env
    function t.called(name)
        local out = {}
        for _, c in ipairs(t.calls) do if c[1] == name then out[#out + 1] = c end end
        return out
    end
    return t
end

describe('CrimsonNpc: scenery NPCs on the client', function()
    it('publishes itself as CrimsonNpc for the files after it', function()
        local t = client()
        eq(rawget(t.env, 'CrimsonNpc'), t.npc)
    end)

    it('reads a character as loaded from the state bag, and as loaded with no bag to read', function()
        truthy(client({ state = { isLoggedIn = true } }).npc.loggedIn())
        falsy(client({ state = { isLoggedIn = false } }).npc.loggedIn(), 'the character screen')
        falsy(client({ state = {} }).npc.loggedIn())
        truthy(client({ noLocalPlayer = true }).npc.loggedIn(), 'no bag: draws as before')
    end)

    it('says ox_target is up only while it is started', function()
        truthy(client().npc.targetUp())
        falsy(client({ target = 'stopped' }).npc.targetUp(), 'stopped')
        falsy(client({ target = 'missing' }).npc.targetUp(), 'not installed')
    end)

    it('loads a model the game has, and gives up on one it has not', function()
        local t = client()
        eq(t.npc.loadModel('g_m_m_armboss_01', 5000), #'g_m_m_armboss_01')
        eq(#t.called('RequestModel'), 1)
        eq(client({ inGame = false }).npc.loadModel('nope', 5000), nil, 'not in the game files')
        eq(client({ valid = false }).npc.loadModel('nope', 5000), nil, 'not a valid model')
        eq(client({ valid = false }).npc.loadModel('ok', 5000, { checkValid = false }), 2,
            'unless the validity check is off')
        eq(client().npc.loadModel(nil, 5000), nil, 'no model named')
        eq(client().npc.loadModel(42, 5000), nil)
    end)

    it('waits at most the cap for a model, in its steps, and never forever', function()
        local t = client({ loaded = false })
        eq(t.npc.loadModel('slow', 5000), nil)
        eq(t.waited, 5000, 'gave up at the cap')
        local s = client({ loaded = false })
        s.npc.loadModel('slow', 1000, { stepMs = 100 })
        eq(s.waited, 1000)
    end)

    it('makes a local ped, safe and still, and lets the model go', function()
        local t = client()
        local ped = t.npc.spawn(9, 1.0, 2.0, 3.0, 90.0, { ragdoll = false, scenario = 'WORLD_HUMAN_SMOKING' })
        eq(ped, 101)
        local made = t.called('CreatePed')[1]
        eq(made[5], 2.0, 'y as given')
        eq(made[6], 2.0, 'feet a metre below the point')
        eq(made[8], false, 'never networked')
        eq(made[9], false, 'not a script host ped unless asked')
        eq(#t.called('SetModelAsNoLongerNeeded'), 1)
        eq(#t.called('SetEntityInvincible'), 1)
        eq(#t.called('FreezeEntityPosition'), 1)
        eq(#t.called('SetBlockingOfNonTemporaryEvents'), 1)
        eq(#t.called('SetPedCanRagdoll'), 1)
        eq(t.called('TaskStartScenarioInPlace')[1][3], 'WORLD_HUMAN_SMOKING')
        local s = client()
        s.npc.spawn(9, 0, 0, 0, 0, { scriptHost = true, scenario = '' })
        eq(s.called('CreatePed')[1][9], true, 'a script host ped when asked')
        eq(#s.called('SetPedCanRagdoll'), 0, 'ragdoll left alone unless asked')
        eq(#s.called('TaskStartScenarioInPlace'), 0, 'no scenario for an empty name')
    end)

    it('answers nil when the game makes no ped, and still lets the model go', function()
        local t = client({ noPed = true })
        eq(t.npc.spawn(9, 0, 0, 0, 0), nil)
        eq(#t.called('SetModelAsNoLongerNeeded'), 1)
        eq(#t.called('SetEntityInvincible'), 0)
    end)

    it('removes a ped that still exists, and nothing else', function()
        local t = client()
        local ped = t.npc.spawn(9, 0, 0, 0, 0)
        t.npc.remove(ped)
        eq(#t.called('DeleteEntity'), 1)
        t.npc.remove(ped)
        t.npc.remove(nil)
        eq(#t.called('DeleteEntity'), 1, 'gone already, or none: nothing deleted')
    end)
end)
