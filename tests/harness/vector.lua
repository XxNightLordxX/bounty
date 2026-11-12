--- The game's vector values, as CfxLua has them.
---
--- On a live server GetEntityCoords, vector3(), vector4(), vec3() and the
--- coordinates a client sends in an event are not tables: type() answers
--- 'vector3' (or 'vector2', 'vector4'). A harness that handed out plain
--- tables let a `type(v) ~= 'table'` check pass here that refuses every
--- real position in game (body disposal never started, review 84 T1). So
--- the harness's vectors are tables tagged with a metatable, and the global
--- type() answers for them what CfxLua answers.
---
--- What they do, as the game's: read .x .y .z (.w), [1] [2] [3] [4] and
--- the swizzles .xy .xyz; + - * / and unary minus; # is the length; == by
--- value; tostring as 'vector3(1.0, 2.0, 3.0)'. pairs() refuses one, as
--- Lua refuses a non-table there, so code that walks coordinates as a table
--- fails here as it would in game. json.encode writes { x, y, z } (the
--- harness encoder knows them), so a stored position reads back as a plain
--- table after a restart, as from a real database.

local Vector = {}

local rawtype = type
Vector.rawtype = rawtype

local AXES = { 'x', 'y', 'z', 'w' }
local KIND = { [2] = 'vector2', [3] = 'vector3', [4] = 'vector4' }
local META = {}

local function make(n, ...)
    local args = { ... }
    local v = {}
    for i = 1, n do
        local value = args[i]
        if value == nil then value = 0.0 end
        v[AXES[i]] = value
    end
    return setmetatable(v, META[n])
end

local function size(v)
    local mt = getmetatable(v)
    return mt and mt.__vectorSize or nil
end

local function arith(op)
    return function(a, b)
        local n = size(a) or size(b)
        local out = {}
        for i = 1, n do
            local k = AXES[i]
            local x = rawtype(a) == 'number' and a or a[k]
            local y = rawtype(b) == 'number' and b or b[k]
            out[i] = op(x, y)
        end
        return make(n, table.unpack(out, 1, n))
    end
end

for n, kind in pairs(KIND) do
    local mt = {
        __vector = kind, __vectorSize = n,
        __add = arith(function(x, y) return x + y end),
        __sub = arith(function(x, y) return x - y end),
        __mul = arith(function(x, y) return x * y end),
        __div = arith(function(x, y) return x / y end),
        __unm = function(a) return arith(function(x, y) return x * y end)(a, -1) end,
        __len = function(a)
            local s = 0
            for i = 1, n do s = s + a[AXES[i]] * a[AXES[i]] end
            return math.sqrt(s)
        end,
        __eq = function(a, b)
            if size(a) ~= size(b) then return false end
            for i = 1, n do if rawget(a, AXES[i]) ~= rawget(b, AXES[i]) then return false end end
            return true
        end,
        __tostring = function(a)
            local parts = {}
            for i = 1, n do parts[i] = string.format('%.1f', a[AXES[i]]) end
            return kind .. '(' .. table.concat(parts, ', ') .. ')'
        end,
        __pairs = function() error('bad argument #1 to \'for iterator\' (table expected, got ' .. kind .. ')', 2) end,
        __index = function(a, key)
            if rawtype(key) == 'number' then
                local axis = AXES[key]
                return axis and key <= n and rawget(a, axis) or nil
            end
            if rawtype(key) == 'string' and #key >= 2 and #key <= 4 and key:match('^[xyzw]+$') then
                local out = {}
                for i = 1, #key do
                    local value = rawget(a, key:sub(i, i))
                    if value == nil then return nil end
                    out[i] = value
                end
                return make(#key, table.unpack(out))
            end
            return nil
        end,
    }
    META[n] = mt
end

function Vector.vector2(x, y) return make(2, x, y) end
function Vector.vector3(x, y, z) return make(3, x, y, z) end
function Vector.vector4(x, y, z, w) return make(4, x, y, z, w) end

--- 'vector2' / 'vector3' / 'vector4' for one of these, else nil.
function Vector.kind(v)
    if rawtype(v) ~= 'table' then return nil end
    local mt = getmetatable(v)
    return mt and mt.__vector or nil
end

--- type() as CfxLua answers it.
function Vector.type(v)
    local t = rawtype(v)
    if t == 'table' then
        local mt = getmetatable(v)
        if mt and mt.__vector then return mt.__vector end
    end
    return t
end

--- Puts the game's constructors and type() in place. Idempotent.
function Vector.install()
    _G.type = Vector.type
    _G.vector2, _G.vec2 = Vector.vector2, Vector.vector2
    _G.vector3, _G.vec3 = Vector.vector3, Vector.vector3
    _G.vector4, _G.vec4 = Vector.vector4, Vector.vector4
    _G.vec = function(...)
        local n = select('#', ...)
        return make(n, ...)
    end
end

return Vector
