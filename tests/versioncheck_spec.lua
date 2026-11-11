--- The version check (X4, server/versioncheck.lua): off as shipped, inert
--- with no address, and when on, one HTTPS GET at the start that sends
--- nothing of this server's, and one console line when a newer version is
--- out.

local VersionCheck = require('server.versioncheck')
local Log = require('crimson-hitman.shared.log')
local Natives = require('tests.harness.natives')

local function capture(fn)
    local said, realAlways = {}, Log.always
    Log.always = function(text) said[#said + 1] = text end
    local ok, err = pcall(fn)
    Log.always = realAlways
    if not ok then error(err, 0) end
    return said
end

local function asks(url)
    local n = 0
    for _, call in ipairs(Natives.calls.http or {}) do if call.url == url then n = n + 1 end end
    return n
end

describe('version check', function()
    it('is off as shipped, with no address, and asks nothing', function()
        newStack()
        eq(Config.VersionCheck.Enabled, false)
        eq(Config.VersionCheck.Url, '')
        Natives.calls.http = {}
        VersionCheck.reset()
        eq(VersionCheck.run(), 'off')
        eq(#Natives.calls.http, 0, 'nothing asked')
        Config.VersionCheck.Enabled = true
        eq(VersionCheck.run(), 'inert', 'on with no address: still nothing asked')
        eq(#Natives.calls.http, 0)
    end)

    it('asks once, with a GET, no body and no headers, and says a newer version in one line', function()
        newStack()
        local url = 'https://example.invalid/crimson-hitman/version.txt'
        Config.VersionCheck.Enabled, Config.VersionCheck.Url = true, url
        Natives.calls.http = {}
        local seen
        Natives.httpAnswer = function(u, method, body, headers)
            seen = { url = u, method = method, body = body, headers = headers }
            return 200, '{"version":"99.0.1"}', {}
        end
        VersionCheck.reset()
        local said = capture(function()
            eq(VersionCheck.run(), 'asked')
            eq(VersionCheck.run(), 'already', 'once a start')
        end)
        Natives.httpAnswer = nil
        eq(asks(url), 1)
        eq(seen.method, 'GET')
        eq(seen.body, '', 'no body')
        eq(next(seen.headers or {}), nil, 'no headers of its own')
        eq(#said, 1, 'one console line')
        truthy(said[1]:find('99.0.1 is out', 1, true), said[1])
    end)

    it('says nothing when it is up to date or the answer has no version', function()
        newStack()
        Config.VersionCheck.Enabled, Config.VersionCheck.Url = true, 'https://example.invalid/v'
        for _, body in ipairs({ '1.0.0', 'not found', '' }) do
            Natives.httpAnswer = function() return 200, body, {} end
            VersionCheck.reset()
            local said = capture(function() VersionCheck.run() end)
            eq(#said, 0, 'quiet for ' .. body .. ': ' .. tostring(said[1]))
        end
        Natives.httpAnswer = function() return 500, '9.9.9', {} end
        VersionCheck.reset()
        eq(#capture(function() VersionCheck.run() end), 0, 'quiet on an error')
        Natives.httpAnswer = nil
    end)

    it('never asks an address that could carry anything, or that is not https', function()
        newStack()
        Config.VersionCheck.Enabled = true
        for _, url in ipairs({ 'http://example.invalid/v', 'https://example.invalid/v?server=me',
            'https://example.invalid/v#x', 'https://me@example.invalid/v', 'ftp://example.invalid' }) do
            Config.VersionCheck.Url = url
            Natives.calls.http = {}
            VersionCheck.reset()
            local said = capture(function() eq(VersionCheck.run(), 'refused', url) end)
            eq(#Natives.calls.http, 0, 'not asked: ' .. url)
            eq(#said, 1, 'said once: ' .. url)
        end
    end)

    it('compares versions by number', function()
        truthy(VersionCheck.newer({ 1, 2, 0 }, { 1, 10, 0 }))
        falsy(VersionCheck.newer({ 1, 2, 0 }, { 1, 2, 0 }))
        falsy(VersionCheck.newer({ 2, 0, 0 }, { 1, 9, 9 }))
        eq(VersionCheck.parse('v1.3')[2], 3)
        eq(VersionCheck.parse('nothing'), nil)
    end)

    it('runs at the start, from main.lua, and the start asks nothing as shipped', function()
        local main = read_file('crimson-hitman/server/main.lua')
        truthy(main:find("CrimsonBoot.require('server.versioncheck').run", 1, true))
        Natives.calls.http = {}
        newStack()
        local asked = 0
        for _, call in ipairs(Natives.calls.http or {}) do
            if call.method == 'GET' then asked = asked + 1 end
        end
        eq(asked, 0)
    end)
end)
