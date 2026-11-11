--- qbx_core 1.24.1's job exports and Renewed-Banking 2.1.4's account
--- exports, as the hitman organisation calls them (server/org/), faithful to
--- their signatures, answers and quirks as read in their source
--- (docs plan research, org-research.md):
---
---   * CreateJob(s) overwrite and answer true, 'success'; UpsertJobData
---     makes a job with no grades; UpsertJobGrade on an unknown job logs and
---     answers nothing; RemoveJobGrade, RemoveJob ('job_not_exists').
---   * AddPlayerToJob(cid, job, grade) answers false, { code, message } for
---     'unemployed', 'job_not_found', 'job_missing_grade', 'player_not_found'
---     and 'max_jobs' (qbx:max_jobs_per_player, 1 unset); online, it updates
---     PlayerData.jobs and fires qbx_core:server:onGroupUpdate.
---   * RemovePlayerFromJob: a primary job goes back to unemployed, fires
---     onGroupUpdate with nil and no OnJobUpdate.
---   * SetPlayerPrimaryJob needs the job held ('player_not_in_job'), sets
---     onduty to defaultDuty and fires QBCore:Server:OnJobUpdate.
---   * SetJobDuty sets the primary job's onduty and fires
---     QBCore:Server:SetDuty (source, onduty).
---   * Renewed-Banking's add/removeAccountMoney validate nothing: a negative
---     amount moves the balance the other way, as there.
---
--- Installed per test (QbxJobs.install()), reset with it.

local Natives = require('tests.harness.natives')
local Env = Natives.env

local QbxJobs = { jobs = {}, groups = {}, calls = {}, errors = {}, bank = {}, transactions = {} }

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function note(name, ...)
    QbxJobs.calls[#QbxJobs.calls + 1] = { name = name, args = { ... } }
end

local function online(cid)
    local src = Env.byCitizen[cid]
    return src and Env.players[src] or nil, src
end

local function fire(name, ...)
    local h = Env.events['local:' .. name]
    if h then h(...) end
end

local function normalise(job)
    local grades = {}
    for k, g in pairs(job.grades or {}) do
        local level = tonumber(k)
        if level then grades[math.floor(level)] = copy(g) end
    end
    local out = copy(job)
    out.grades = grades
    return out
end

local function refreshPrimary(name)
    local job = QbxJobs.jobs[name]
    for _, p in pairs(Env.players) do
        if p.PlayerData.job and p.PlayerData.job.name == name then
            if job then
                local level = p.PlayerData.job.grade and p.PlayerData.job.grade.level or 0
                local g = job.grades[level] or {}
                p.PlayerData.job.label = job.label
                p.PlayerData.job.grade = { level = level, name = g.name }
                p.PlayerData.job.isboss = g.isboss == true
                p.PlayerData.job.bankAuth = g.bankAuth == true
                p.PlayerData.job.payment = g.payment
            else
                p.PlayerData.job = { name = 'unemployed', label = 'Civilian', grade = { level = 0 }, onduty = false }
            end
        end
    end
end

local function createJob(name, job)
    if type(name) ~= 'string' or name:lower() ~= name then
        QbxJobs.errors[#QbxJobs.errors + 1] = 'job name must be lower case: ' .. tostring(name)
        return false, 'invalid_job_name'
    end
    QbxJobs.jobs[name] = normalise(job)
    Env.jobDefinitions[name] = { label = job.label, type = job.type }
    fire('qbx_core:server:onJobUpdate', name, copy(QbxJobs.jobs[name]))
    refreshPrimary(name)
    return true, 'success'
end

local function maxJobs()
    return tonumber(Natives.convars['qbx:max_jobs_per_player']) or 1
end

function QbxJobs.reset()
    QbxJobs.jobs, QbxJobs.groups, QbxJobs.calls, QbxJobs.errors = {}, {}, {}, {}
    QbxJobs.bank, QbxJobs.transactions = {}, {}
    QbxJobs.refuse = {}
end

function QbxJobs.install()
    QbxJobs.reset()
    local core = Natives.exportTables['qbx_core']
    core.CreateJob = function(_, name, job) note('CreateJob', name) return createJob(name, job) end
    core.CreateJobs = function(_, jobs)
        note('CreateJobs', jobs)
        if QbxJobs.refuse.CreateJobs then error('qbx_core: CreateJobs refused', 0) end
        for name, job in pairs(jobs) do createJob(name, job) end
        return true, 'success'
    end
    core.RemoveJob = function(_, name)
        note('RemoveJob', name)
        if not QbxJobs.jobs[name] then return false, 'job_not_exists' end
        QbxJobs.jobs[name] = nil
        fire('qbx_core:server:onJobUpdate', name, nil)
        refreshPrimary(name)
        return true, 'success'
    end
    core.UpsertJobData = function(_, name, data)
        note('UpsertJobData', name, data)
        local job = QbxJobs.jobs[name] or { grades = {} }
        for k, v in pairs(data or {}) do job[k] = v end
        QbxJobs.jobs[name] = job
        refreshPrimary(name)
    end
    core.UpsertJobGrade = function(_, name, grade, data)
        note('UpsertJobGrade', name, grade, data)
        local job = QbxJobs.jobs[name]
        if not job then
            QbxJobs.errors[#QbxJobs.errors + 1] = 'UpsertJobGrade: job not found ' .. tostring(name)
            return
        end
        job.grades[math.floor(tonumber(grade) or 0)] = copy(data)
        refreshPrimary(name)
    end
    core.RemoveJobGrade = function(_, name, grade)
        note('RemoveJobGrade', name, grade)
        local job = QbxJobs.jobs[name]
        if job then job.grades[math.floor(tonumber(grade) or 0)] = nil end
    end
    core.GetJobs = function() return copy(QbxJobs.jobs) end
    core.GetJob = function(_, name)
        Natives.calls.getJob = (Natives.calls.getJob or 0) + 1
        return QbxJobs.jobs[name] and copy(QbxJobs.jobs[name]) or (Env.jobDefinitions and Env.jobDefinitions[name])
    end
    core.AddPlayerToJob = function(_, cid, name, grade)
        note('AddPlayerToJob', cid, name, grade)
        grade = math.floor(tonumber(grade) or 0)
        if name == 'unemployed' then return false, { code = 'unemployed', message = 'cannot add to unemployed' } end
        local job = QbxJobs.jobs[name]
        if not job then return false, { code = 'job_not_found', message = name .. ' does not exist' } end
        if not job.grades[grade] then return false, { code = 'job_missing_grade', message = 'no grade ' .. grade } end
        local player, src = online(cid)
        if not player and not (Env.characters and Env.characters[cid]) and not QbxJobs.groups[cid] then
            return false, { code = 'player_not_found', message = 'no player ' .. tostring(cid) }
        end
        local held = QbxJobs.groups[cid] or {}
        if held[name] == nil then
            local others = 0
            for other in pairs(held) do if other ~= 'unemployed' then others = others + 1 end end
            if player and player.PlayerData.job and player.PlayerData.job.name ~= 'unemployed'
                and not held[player.PlayerData.job.name] then
                others = others + 1
            end
            if others >= maxJobs() then return false, { code = 'max_jobs', message = 'too many jobs' } end
        end
        held[name] = grade
        QbxJobs.groups[cid] = held
        if player then
            player.PlayerData.jobs = player.PlayerData.jobs or {}
            player.PlayerData.jobs[name] = grade
            if player.PlayerData.job and player.PlayerData.job.name == name then
                player.PlayerData.job.grade = { level = grade, name = job.grades[grade].name }
                refreshPrimary(name)
            end
            fire('qbx_core:server:onGroupUpdate', src, name, grade)
        end
        return true
    end
    core.RemovePlayerFromJob = function(_, cid, name)
        note('RemovePlayerFromJob', cid, name)
        local held = QbxJobs.groups[cid]
        if not held or held[name] == nil then
            return false, { code = 'player_not_in_job', message = 'not in job' }
        end
        held[name] = nil
        local player, src = online(cid)
        if player then
            if player.PlayerData.jobs then player.PlayerData.jobs[name] = nil end
            if player.PlayerData.job and player.PlayerData.job.name == name then
                player.PlayerData.job = { name = 'unemployed', label = 'Civilian', grade = { level = 0 }, onduty = false }
            end
            fire('qbx_core:server:onGroupUpdate', src, name, nil)
        end
        return true
    end
    core.SetPlayerPrimaryJob = function(_, cid, name)
        note('SetPlayerPrimaryJob', cid, name)
        local held = QbxJobs.groups[cid]
        if not held or held[name] == nil then return false, { code = 'player_not_in_job', message = 'not in job' } end
        local player, src = online(cid)
        local job = QbxJobs.jobs[name]
        if player and job then
            local g = job.grades[held[name]] or {}
            player.PlayerData.job = { name = name, label = job.label, type = job.type,
                grade = { level = held[name], name = g.name }, onduty = job.defaultDuty ~= false,
                isboss = g.isboss == true, bankAuth = g.bankAuth == true, payment = g.payment }
            fire('QBCore:Server:OnJobUpdate', src, copy(player.PlayerData.job))
        end
        return true
    end
    -- server/player.lua SetJobDuty(identifier, onDuty): the primary job's
    -- onduty set, then QBCore:Server:SetDuty fired (a server event) with
    -- the source and the new duty.
    core.SetJobDuty = function(_, identifier, onDuty)
        note('SetJobDuty', identifier, onDuty)
        local src = type(identifier) == 'number' and identifier or Env.byCitizen[identifier]
        local player = src and Env.players[src]
        if not player then return end
        player.PlayerData.job = player.PlayerData.job or {}
        player.PlayerData.job.onduty = not not onDuty
        fire('QBCore:Server:SetDuty', src, player.PlayerData.job.onduty)
    end
    core.GetGroupMembers = function(_, name)
        local out = {}
        for cid, held in pairs(QbxJobs.groups) do
            if held[name] ~= nil then out[#out + 1] = { citizenid = cid, grade = held[name] } end
        end
        return out
    end

    Natives.exportTables['Renewed-Banking'] = {
        CreateJobAccount = function(_, job, balance)
            note('CreateJobAccount', job and job.name)
            if type(job) ~= 'table' or type(job.name) ~= 'string' then error('Renewed-Banking: bad job', 0) end
            if QbxJobs.bank[job.name] == nil then QbxJobs.bank[job.name] = tonumber(balance) or 0 end
            return { id = job.name, amount = QbxJobs.bank[job.name] }
        end,
        getAccountMoney = function(_, account)
            local v = QbxJobs.bank[account]
            if v == nil then return false end
            return v
        end,
        addAccountMoney = function(_, account, amount)
            note('addAccountMoney', account, amount)
            if QbxJobs.refuse.add then return false end
            if QbxJobs.bank[account] == nil then return false end
            QbxJobs.bank[account] = QbxJobs.bank[account] + amount
            return true
        end,
        removeAccountMoney = function(_, account, amount)
            note('removeAccountMoney', account, amount)
            local held = QbxJobs.bank[account]
            if held == nil or held < amount then return false end
            QbxJobs.bank[account] = held - amount
            return true
        end,
        handleTransaction = function(_, account, title, amount, message, issuer, receiver, kind)
            QbxJobs.transactions[#QbxJobs.transactions + 1] = { account = account, title = title, amount = amount,
                message = message, issuer = issuer, receiver = receiver, kind = kind }
            return { trans_id = #QbxJobs.transactions }
        end,
    }
    return QbxJobs
end

--- How many calls of one export were made.
function QbxJobs.count(name)
    local n = 0
    for _, c in ipairs(QbxJobs.calls) do if c.name == name then n = n + 1 end end
    return n
end

QbxJobs.size = count

return QbxJobs
