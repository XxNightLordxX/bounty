CrimsonBoot.define('server.versioncheck', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/versioncheck.lua                 ║
    ║          Whether a newer version is out: one ask at start, if on          ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Off as shipped (Config.VersionCheck.Enabled = false), and inert while
--- Config.VersionCheck.Url is empty, as shipped: nothing is asked.
---
--- On, with an address: one HTTPS GET to it, once, after the start. It sends
--- nothing of this server's: no body, no headers of its own (only what
--- FiveM's HTTP client always sends), and an address with a query (?) or a
--- fragment (#), or a user name in it, is refused without asking, so not
--- even the address can carry anything. What answers is read for the first
--- version number in it (1.2.0, in plain text or inside JSON); when it is
--- newer than this resource's (fxmanifest.lua's version), the console says
--- so in one line. Anything else (no answer, an error, no number, the same
--- or older) is a debug line at most.

local Log = CrimsonBoot.requireShared('log')

local VersionCheck = {}

--- The most of an answer read for the number.
VersionCheck.MAX_BODY = 65536

--- Whether the one ask was made this run (it is made once).
local asked = false

--- A version's three numbers: '1.2.0' -> { 1, 2, 0 }; nil for none, and
--- for a part longer than nine digits (no version is, and a longer one is
--- no integer Lua can print with %d).
---@param text any
---@return integer[]|nil
function VersionCheck.parse(text)
    if type(text) ~= 'string' then return nil end
    local body = text:sub(1, VersionCheck.MAX_BODY)
    -- JSON with it in (docs/running.md): read from its "version" or
    -- "tag_name" field. The first dotted number anywhere was a rating
    -- (4.5) or a date (2026.11.13) as often as the version.
    if body:match('^%s*{') then
        local field = body:match('"version"%s*:%s*"v?([^"]*)"')
            or body:match('"tag_name"%s*:%s*"v?([^"]*)"')
        if not field then return nil end
        body = field
    end
    local a, b, c = body:match('(%d+)%.(%d+)%.?(%d*)')
    if not a then return nil end
    if #a > 9 or #b > 9 or #c > 9 then return nil end
    return { math.tointeger(tonumber(a)), math.tointeger(tonumber(b)), math.tointeger(tonumber(c)) or 0 }
end

--- Whether `latest` is newer than `mine`.
---@param mine integer[]
---@param latest integer[]
---@return boolean
function VersionCheck.newer(mine, latest)
    for i = 1, 3 do
        local x, y = mine[i] or 0, latest[i] or 0
        if y ~= x then return y > x end
    end
    return false
end

--- Whether an address may be asked: https, with no query, fragment, user
--- name or white space, at most 512 characters. nil and why when not.
---@param url any
---@return boolean ok
---@return string|nil why
function VersionCheck.allowed(url)
    if type(url) ~= 'string' or url == '' then return false, 'no address' end
    if #url > 512 then return false, 'longer than 512 characters' end
    if not url:match('^https://[%w%.%-]+[:/]?') then return false, 'not an https:// address' end
    if url:find('[%?#%s]') then return false, 'it carries a query, a fragment or a space' end
    if url:match('^https://[^/]*@') then return false, 'it carries a user name' end
    return true
end

--- This resource's version, as fxmanifest.lua gives it.
---@return string
local function mine()
    local ok, version = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
    return (ok and type(version) == 'string') and version or '0.0.0'
end

--- Ask once, if switched on and given an address. Answers what it did:
--- 'off', 'inert' (no address), 'refused' (an address it will not ask),
--- 'asked', or 'already'.
---@return string
function VersionCheck.run()
    local cfg = type(Config.VersionCheck) == 'table' and Config.VersionCheck or {}
    if cfg.Enabled ~= true then return 'off' end
    if asked then return 'already' end
    local url = cfg.Url
    if type(url) ~= 'string' or url == '' then
        Log.debug('version check: on, with no address (Config.VersionCheck.Url): nothing is asked')
        return 'inert'
    end
    local ok, why = VersionCheck.allowed(url)
    if not ok then
        Log.always(('version check: Config.VersionCheck.Url is not asked: %s. Give a plain '
            .. 'https:// address with nothing after a ? or #.'):format(why))
        return 'refused'
    end
    asked = true
    local current = mine()
    -- Whatever the host answers is a line at most: never a script error.
    local function answered(status, body)
        local latest = tonumber(status) == 200 and VersionCheck.parse(body) or nil
        local have = VersionCheck.parse(current) or { 0, 0, 0 }
        if latest and VersionCheck.newer(have, latest) then
            Log.always(('version check: %d.%d.%d is out (this is %s): see where you got this resource')
                :format(latest[1], latest[2], latest[3], current))
        else
            Log.debug(('version check: %s, answered %s'):format(latest and 'up to date' or 'no version read',
                tostring(status)))
        end
    end
    local sent = pcall(PerformHttpRequest, url, function(status, body)
        local okA, err = pcall(answered, status, body)
        if not okA then Log.debug('version check: the answer could not be read: ' .. tostring(err)) end
    end, 'GET', '', {})
    if not sent then Log.debug('version check: the request could not be made') end
    return 'asked'
end

--- Forget the ask (tests).
function VersionCheck.reset()
    asked = false
end

return VersionCheck
end)
