--- Positions and distances (shared/geo.lua): finite numbers, the server's
--- read of a player's ped, and distance checks.

local Geo = require('crimson-hitman.shared.geo')

describe('Geo: positions and distances', function()
    it('takes only finite numbers, and numeric strings unless told not to', function()
        eq(Geo.finite(1.5), 1.5)
        eq(Geo.finite('2.5'), 2.5, 'a numeric string is a number')
        eq(Geo.finite('2.5', true), nil, 'unless numbers only')
        eq(Geo.finite(3, true), 3)
        eq(Geo.finite(0 / 0), nil, 'NaN')
        eq(Geo.finite(math.huge), nil)
        eq(Geo.finite(-math.huge, true), nil)
        eq(Geo.finite('abc'), nil)
        eq(Geo.finite(nil), nil)
        eq(Geo.finite({}), nil)
        eq(Geo.finite(true, true), nil)
    end)

    it('reads where the server sees a player\'s ped, and nil when it cannot', function()
        newStack()
        Env.addPlayer({ source = 7, citizenid = 'GEO00007' })
        local at = Geo.position(7)
        truthy(at, 'a ped in the world has a position')
        truthy(type(at.x) == 'number' and type(at.y) == 'number')
        local realPed, realCoords = _G.GetPlayerPed, _G.GetEntityCoords
        _G.GetPlayerPed = function() return 0 end
        eq(Geo.position(7), nil, 'no ped')
        _G.GetPlayerPed = function() error('no such player', 0) end
        local ok, none = pcall(Geo.position, 7)
        truthy(ok, 'a read that raises never raises here')
        eq(none, nil)
        _G.GetPlayerPed = realPed
        _G.GetEntityCoords = function() error('gone', 0) end
        eq(Geo.position(7), nil)
        _G.GetEntityCoords = realCoords
    end)

    it('measures squared distance, a missing axis as 0 and a missing point as infinitely far', function()
        eq(Geo.dist2({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }), 25)
        eq(Geo.dist2({ x = 1, y = 1 }, { x = 1, y = 1, z = 2 }), 4)
        eq(Geo.dist2(nil, { x = 0 }), math.huge)
        eq(Geo.dist2({ x = 0 }, nil), math.huge)
    end)

    it('says whether two points are within a radius, the edge included', function()
        local a, b = { x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }
        truthy(Geo.near(a, b, 5), 'exactly at the edge is near')
        falsy(Geo.near(a, b, 4.99))
        falsy(Geo.near(a, nil, 1000), 'a missing point is never near')
        falsy(Geo.near(a, b, 'x'), 'a radius that is not a number is 0')
        truthy(Geo.near(a, a, 0), 'the same point at 0')
    end)
end)
