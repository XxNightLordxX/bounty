CrimsonBoot.define('server.discord', function() --- Every post this resource makes to Discord, through one sender: the
--- alerts (server/alerts.lua), the audit mirror (server/audit.lua), the
--- daily summary (server/summary.lua) and the weekly stats
--- (server/imp_weekly.lua).
---
--- Webhooks come from server convars only, read on every post so one set
--- from the console works without a restart; never config.lua, which every
--- player's game downloads. Set them in server.cfg with `set`, never `setr`
--- (setr sends the value to every player too). Which convars a channel reads
--- (Discord.CHANNELS), first set wins:
---   alerts  crimson_hitman_alert_webhook, else crimson_hitman_webhook
---   staff   crimson_hitman_webhook
---   stats   crimson_hitman_stats_webhook, else the alerts' two
---
--- What every post gets, whoever sent it (Discord.text): no mention pings
--- anybody (an @ is followed by a zero-width space), every link is left out
--- ('(a link)'), and it is cut to Discord.MAX characters. Discord answering
--- 429 holds that webhook for as long as it asks (Retry-After, else
--- Discord.HOLD_SECONDS), for every sender: a post with tries to spare waits
--- it out, one with none is refused ('held'). A post Discord refuses is
--- tried again after a longer wait each time (opts.every, doubled each try,
--- never sooner than Retry-After), up to opts.tries tries.

local Util = CrimsonBoot.requireShared('util')
--- The words players and staff read (locales/en.lua, Config.Locale).
local L = CrimsonBoot.requireShared('locale').t
local Log = CrimsonBoot.requireShared('log')

local Discord = {}

--- Tries a post gets unless its sender says otherwise.
Discord.TRIES = 3
--- The first wait before a post is tried again, in ms (doubled each try).
Discord.RETRY_MS = 10000
--- How long a webhook is held after a 429 that names no wait, in seconds.
Discord.HOLD_SECONDS = 5
--- At most this many characters a post (Discord's own limit is 2000).
Discord.MAX = 1900

--- The convars each channel reads, first set wins, and the word the panel
--- shows for each (never the url).
Discord.CHANNELS = {
    alerts = { { 'crimson_hitman_alert_webhook', 'alert' }, { 'crimson_hitman_webhook', 'staff' } },
    staff  = { { 'crimson_hitman_webhook', 'staff' } },
    stats  = { { 'crimson_hitman_stats_webhook', 'stats' }, { 'crimson_hitman_alert_webhook', 'alert' },
               { 'crimson_hitman_webhook', 'staff' } },
}

--- Webhooks held after a 429: [url] = Util.monotonicMs() it may post again.
local heldUntil = {}

--- The webhook a channel posts to, and which convar named it; never shown.
---@param channel string 'alerts' | 'staff' | 'stats'
---@return string|nil url
---@return string|nil which 'alert' | 'staff' | 'stats'
function Discord.url(channel)
    if type(GetConvar) ~= 'function' then return nil, nil end
    for _, pair in ipairs(Discord.CHANNELS[channel] or {}) do
        local url = GetConvar(pair[1], '')
        if type(url) == 'string' and url ~= '' then return url, pair[2] end
    end
    return nil, nil
end

local ZWSP_AT = '@\226\128\139'

--- Text as any post carries it: every @ defused (said twice, it is still
--- defused once), every link left out, and, given `max`, cut to it.
---@param text any
---@param max integer|nil
---@return string
function Discord.text(text, max)
    text = tostring(text or ''):gsub(ZWSP_AT, '@'):gsub('https?://%S+', L('discord.a_link')):gsub('@', ZWSP_AT)
    if max and #text > max then text = Util.toValidUtf8(text:sub(1, max - 3)) .. '...' end
    return text
end

--- Whether a webhook is held after a 429, and for how many ms more.
local function heldFor(url)
    local untilMs = heldUntil[url]
    if not untilMs then return 0 end
    local left = untilMs - Util.monotonicMs()
    if left <= 0 then
        heldUntil[url] = nil
        return 0
    end
    return left
end

--- Post `content` to a channel's webhook.
---
--- opts (all optional):
---   tries  how many tries at most (Discord.TRIES)
---   every  the first wait before another, ms (Discord.RETRY_MS)
---   still  function() -> boolean, asked before every try after the first:
---          false drops the post (switched off meanwhile)
---   done   function(ok, status, tries), once, when it went or was given up
---          (status 0: the request raised; nil: dropped by still or no
---          webhook left). Without it a give-up is one debug line.
---@param channel string 'alerts' | 'staff' | 'stats'
---@param content string
---@param opts table|nil
---@return boolean queued
---@return string|nil err 'no_webhook' | 'held' | 'unavailable'
function Discord.post(channel, content, opts)
    opts = opts or {}
    local url = Discord.url(channel)
    if not url then return false, 'no_webhook' end
    local tries = math.max(1, math.floor(tonumber(opts.tries) or Discord.TRIES))
    local every = tonumber(opts.every) or Discord.RETRY_MS
    if tries == 1 and heldFor(url) > 0 then return false, 'held' end
    local body = json.encode({ content = Discord.text(content, Discord.MAX) })

    local function finish(ok, code, n)
        if opts.done then
            pcall(opts.done, ok, code, n)
        elseif not ok and code then
            Log.debug(('a staff post could not be sent to Discord: given up after %d tries (HTTP %d)')
                :format(n, code))
        end
    end

    local try
    try = function(n)
        if n > 1 then
            if opts.still and not opts.still() then return finish(false, nil, n - 1) end
            url = Discord.url(channel)
            if not url then return finish(false, nil, n - 1) end
        end
        local wait = heldFor(url)
        if wait > 0 then
            SetTimeout(math.floor(wait), function() try(n) end)
            return
        end
        local function answered(status, _, headers)
            local code = tonumber(status) or 0
            if code >= 200 and code < 300 then return finish(true, code, n) end
            local after = type(headers) == 'table'
                and tonumber(headers['Retry-After'] or headers['retry-after']) or nil
            if code == 429 then
                heldUntil[url] = Util.monotonicMs() + math.max(1, after or Discord.HOLD_SECONDS) * 1000
            end
            if n >= tries then return finish(false, code, n) end
            local again = every * 2 ^ (n - 1)
            if after then again = math.max(again, after * 1000) end
            SetTimeout(math.floor(again), function() try(n + 1) end)
        end
        local ok = pcall(PerformHttpRequest, url, answered, 'POST', body,
            { ['Content-Type'] = 'application/json' })
        if not ok then
            -- The first try raising with none to spare: the sender hears it now.
            if n == 1 and tries == 1 then return 'raised' end
            answered(0, nil, nil)
        end
    end
    if try(1) == 'raised' then return false, 'unavailable' end
    return true
end

return Discord
end)
