CrimsonBoot.define('server.police', function() --- Police & press: everything this resource tells the police or the city.
---
--- The threat advisories (posted, accepted, tip, cancelled: Notify.advisory,
--- tipAdvisory, cancelAdvisory), the hitman heat bulletin
--- (server/record/heat.lua), the witness report (server/rp_consequences.lua)
--- and the city news post (Config.Roleplay.CityNews) each say what they say
--- here, through one path each:
---   Police.tell      the phones of every officer online (who counts as one:
---                    Config.Advisory.RecipientJobTypes / RecipientJobNames,
---                    Identity.isAdvisoryRecipient), less whoever the
---                    caller leaves out
---   Police.dispatch  the one call that files an entry with sc-dispatch, for
---                    Police.jobs(); Police.clear the one that takes it off
---   Police.press     the one post to the city's news (lb-phone's Birdy, or
---                    a server event of the owner's)
--- What each says, when, and to whom besides the police stays with its
--- feature; none of them names a placer or an operative, and nothing here
--- adds anybody.

local Log = CrimsonBoot.requireShared('log')
local Integrations = CrimsonBoot.require('server.adapters.init')

local Police = {}

local Identity, Notify

--- The last time a city news post that could not be made was said (one
--- line a minute at most).
local saidPressFailAt = -math.huge

--- The departments a dispatch entry is for: the job names configured to
--- receive advisories, so the MDT and the phones are told the same people;
--- police where none is switched on.
---@return string[]
function Police.jobs()
    local jobs = {}
    for name, on in pairs(Config.Advisory and Config.Advisory.RecipientJobNames or {}) do
        if on == true and type(name) == 'string' then jobs[#jobs + 1] = name end
    end
    table.sort(jobs)
    if #jobs == 0 then jobs = { 'police' } end
    return jobs
end

--- Every officer online (an advisory recipient by job), less any `skip`
--- says to leave out.
---@param skip function|nil function(actor) -> true to leave them out
---@return table[] actors
function Police.recipients(skip)
    local out = {}
    for _, actor in ipairs(Identity.online() or {}) do
        if Identity.isAdvisoryRecipient(actor.job) and not (skip and skip(actor)) then
            out[#out + 1] = actor
        end
    end
    return out
end

--- The same words on every officer's phone, past their notice budget.
---@param title string
---@param text string
---@param skip function|nil as Police.recipients
---@return integer told
function Police.tell(title, text, skip)
    local told = Police.recipients(skip)
    for i = 1, #told do
        Notify.toCitizen(told[i].cid, title, text, { bypassBudget = true })
    end
    return #told
end

--- File one entry with sc-dispatch, for Police.jobs(). `entry` carries the
--- title, message, caller, priority, unique_id and, where the feature
--- gives them, coords and street; the unique id is held to 60 characters,
--- the caller to 60 and the street to 100, as sc-dispatch takes them.
---@param entry table
---@return boolean filed false with no dispatch adapter (Config.Integrations.Dispatch), or a raise
function Police.dispatch(entry)
    local alert = {}
    for k, v in pairs(entry) do alert[k] = v end
    alert.job_table = Police.jobs()
    if type(alert.unique_id) == 'string' then alert.unique_id = alert.unique_id:sub(1, 60) end
    if type(alert.caller) == 'string' then alert.caller = alert.caller:sub(1, 60) end
    if type(alert.street) == 'string' then alert.street = alert.street:sub(1, 100) end
    return (Integrations.call('dispatch', 'AddNotification', alert))
end

--- Take an entry off sc-dispatch by its unique id. Clearing one never
--- filed does nothing.
---@param uid string
function Police.clear(uid)
    Integrations.call('dispatch', 'ClearNotification', uid, Police.jobs())
end

--- Post one item to the city's news: lb-phone's PostBirdy as cfg.Account
--- (docs.lbscripts.com, server exports: PostBirdy(username, content,
--- attachments, replyTo, hashtags, source), answering success and the
--- post's id), or with cfg.App = 'event' the local server event cfg.Event,
--- { account, text }, another resource posts it from, for a News app with
--- no server export.
--- One that could not be made is said on the console, once a minute at
--- most.
---@param cfg table Config.Roleplay.CityNews
---@param text string
---@return boolean posted
function Police.press(cfg, text)
    local posted, why = false, nil
    if cfg.App == 'event' then
        posted = pcall(TriggerEvent, cfg.Event, { account = cfg.Account, text = text })
    elseif Integrations.has('phone') then
        local ran, ok = Integrations.call('phone', 'PostBirdy', cfg.Account, text, nil, nil, nil, nil)
        posted = ran and ok ~= false
        if not ran then why = tostring(ok) end
    else
        why = 'no phone adapter answers (Config.Integrations.Phone)'
    end
    if not posted and os.time() - saidPressFailAt >= 60 then
        saidPressFailAt = os.time()
        Log.always(('city news: the post was not made (%s). Check Config.Roleplay.CityNews: the '
            .. 'Birdy account must exist in lb-phone.'):format(why or 'refused'))
    end
    return posted
end

--- Wired by Notify.init: who is online, and the phone notice.
---@param d table { identity, notify }
function Police.init(d)
    Identity, Notify = d.identity, d.notify
    saidPressFailAt = -math.huge
end

return Police
end)
