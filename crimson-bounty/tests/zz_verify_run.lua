package.path = './?.lua;./?/init.lua;' .. package.path
local Natives = require('crimson-bounty.tests.harness.natives')
local Env = Natives.env
Natives.install()
_G.require_shared = function(name) return require('crimson-bounty.shared.' .. name) end
_G.CB = require('crimson-bounty.shared.constants')
_G.Config = require('crimson-bounty.config.config')
local realTime = os.time
os.time = function() return Env.time end
local Suite = { total = 0, passed = 0, failed = 0, current = nil, failures = {} }
function Suite.describe(name, fn) Suite.current = name fn() end
function Suite.it(name, fn)
    Suite.total = Suite.total + 1
    io.write('\n== ' .. name .. ' ==\n')
    local ok, err = pcall(fn)
    if ok then Suite.passed = Suite.passed + 1
    else Suite.failed = Suite.failed + 1
        table.insert(Suite.failures, ('%s > %s\n    %s'):format(Suite.current, name, tostring(err))) end
end
function Suite.eq(a, e, m) if a ~= e then error(('%s: expected %s, got %s'):format(m or 'mismatch', tostring(e), tostring(a)), 2) end end
function Suite.truthy(v, m) if not v then error((m or 'expected truthy') .. ', got ' .. tostring(v), 2) end end
function Suite.falsy(v, m) if v then error((m or 'expected falsy') .. ', got ' .. tostring(v), 2) end end
_G.describe, _G.it, _G.eq, _G.truthy, _G.falsy = Suite.describe, Suite.it, Suite.eq, Suite.truthy, Suite.falsy
_G.Env, _G.Natives, _G.Suite = Env, Natives, Suite
dofile('crimson-bounty/tests/run_stack.lua')
require('crimson-bounty.tests.zz_verify_spec')
os.time = realTime
for _, f in ipairs(Suite.failures) do io.write('FAIL  ', f, '\n') end
io.write(('\n%d passed, %d failed, %d total\n'):format(Suite.passed, Suite.failed, Suite.total))
