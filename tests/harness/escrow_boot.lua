--- A whole start of the resource as an escrowed build gets it, in a process
--- of its own (tests/escrow_boot_spec.lua runs it).
---
--- Every file fxmanifest.lua lists for the server runs here in the
--- manifest's order, the way the runtime's script loader runs it: that
--- loader is the one thing that decrypts an escrowed file. LoadResourceFile
--- is not: it hands back the bytes on disk, so here it answers every .lua
--- file with bytes no load() can compile. Then boot.lua's own start thread
--- runs, waits for the framework and calls StartCrimsonHitman, as on a live
--- server. The runtime's require is barred from the resource's modules, so
--- nothing reaches one by any way but CrimsonBoot.define and
--- CrimsonBoot.require.
---
--- Prints one line starting "escrow boot ok" and exits 0 when the start
--- finished with the app serving; anything else exits 1 and says why.

package.path = './?.lua;./?/init.lua;' .. package.path

local out = io.stdout
local function finish(ok, text)
    out:write((ok and 'escrow boot ok: ' or 'escrow boot FAILED: ') .. text .. '\n')
    os.exit(ok and 0 or 1)
end

local Natives = require('tests.harness.natives')
local Manifest = require('tests.harness.manifest')
local Env = Natives.env
Natives.install()
Env.reset()
Natives.resetResourceStates()

local ROOT = 'crimson-hitman/'
local SEALED = '\27FXAP\0\1sealed bytes, not Lua'
local lreads = 0
_G.LoadResourceFile = function(_, file)
    if type(file) == 'string' and file:match('%.lua$') then
        lreads = lreads + 1
        return SEALED
    end
    return Natives.files[file]
end

local realRequire = require
_G.require = function(name)
    local rel = tostring(name):gsub('^crimson%-hitman%.', '')
    if rel:match('^server%.') or rel:match('^shared%.') or rel:match('^locales%.') or rel:match('^config%.') then
        error('the runtime require reached the resource file ' .. tostring(name), 2)
    end
    return realRequire(name)
end

local scripts = Manifest.serverScripts()
if scripts[1] == nil then finish(false, 'the manifest lists no server scripts') end

local ran = 0
for _, file in ipairs(scripts) do
    local chunk, err = loadfile(ROOT .. file)
    if not chunk then finish(false, ('%s does not compile: %s'):format(file, err)) end
    local ok, raised = pcall(chunk)
    if not ok then finish(false, ('%s raised as the manifest loaded it: %s'):format(file, tostring(raised))) end
    ran = ran + 1
    -- The harness has no database: the in-process store, once the
    -- configuration has loaded (the shared scripts come first).
    if file == 'config/config.lua' then Config.Database.Mode = 'memory' end
end

if type(StartCrimsonHitman) ~= 'function' then finish(false, 'server/main.lua defined no StartCrimsonHitman') end
local started, startErr
local realStart = StartCrimsonHitman
_G.StartCrimsonHitman = function(...)
    local ok, result = pcall(realStart, ...)
    if ok then started = result else startErr = result error(result, 0) end
    return result
end

-- boot.lua's start thread, as the scheduler runs it after every script.
local threads = Env.threads
Env.threads = {}
for _, fn in ipairs(threads) do
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then finish(false, 'a start thread raised: ' .. tostring(err)) end
end

if startErr then finish(false, 'StartCrimsonHitman raised: ' .. tostring(startErr)) end
if type(started) ~= 'table' then
    local said = {}
    for i = math.max(1, #Env.console - 8), #Env.console do said[#said + 1] = Env.console[i] end
    finish(false, 'the start never ran or answered nothing; the console ended: ' .. table.concat(said, ' | '))
end
local app = started.app
if not (type(app) == 'table' and app.ready == true and not app.recoveryFailed) then
    finish(false, 'the start finished but the app is not serving')
end
for _, line in ipairs(Env.console) do
    if line:find('failed to start', 1, true) then finish(false, line) end
end

finish(true, ('%d manifest scripts, %d .lua reads of sealed bytes, app serving'):format(ran, lreads))
