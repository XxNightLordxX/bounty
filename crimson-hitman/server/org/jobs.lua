--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/org/jobs.lua                    ║
    ║        The organisation as a qbx_core job: registered and kept in step    ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- This resource's own tables are the source of truth (server/org/init.lua);
--- qbx_core is told. Every call here is to qbx_core 1.24's server exports,
--- inside pcall:
---
---   CreateJobs(jobs)                         at start, and for a whole new job
---   UpsertJobData(name, data)                label, type, defaultDuty, offDutyPay
---   UpsertJobGrade(name, grade, data)        one role: name, payment, isboss, bankAuth
---   RemoveJobGrade(name, grade)              a role deleted
---   AddPlayerToJob(cid, name, grade)         hire, promote, demote (online or offline)
---   RemovePlayerFromJob(cid, name)           fire (online or offline)
---   SetPlayerPrimaryJob(cid, name)           a hire, where Config says so
---
--- Never commitToFile (it drops the job type and rewrites qbx_core's own
--- jobs.lua). The jobs are made again at every start, before players load
--- where the start order allows, and every online player is brought back
--- in step afterwards for a start that came late (Jobs.resync).
---
--- bankAuth is never set: Renewed-Banking's own bank screen would then let
--- a role draw on the society account past every rule here. isboss is set
--- only with Config.Organisation.QbxBossFlag, for the same reason: qbx_management
--- and lb-phone's Services boss tab check little beyond it.

local Log = CrimsonBoot.requireShared('log')
local Integrations = CrimsonBoot.require('server.adapters.init')

--- The adapters answering now (server/adapters/): nil while none does.
local function Framework() return Integrations.get('framework') end

local Jobs = {}

--- Things said once a process: [key] = true.
local said = {}

--- The citizen ids whose job this resource is changing right now, so the
--- qbx_core events those calls fire are not read as changes from elsewhere.
--- [cid] = depth
local applying = {}

local function sayOnce(key, text, loud)
    if said[key] then return end
    said[key] = true
    if loud then Log.always(text) end
    Log.problem(text)
end

--- Forget what was said, for a fresh start (and a test's).
function Jobs.reset()
    said, applying = {}, {}
end

--- Whether a call into qbx_core is ours, for a citizen id.
---@param cid string
---@return boolean
function Jobs.applying(cid)
    return (applying[cid] or 0) > 0
end

--- Call one of the framework adapter's job functions (Integrations.call:
--- guarded, a raise said once a minute), only while its resource is
--- started, with the citizen id marked as ours while it runs.
---@return boolean ran
---@return any ok
---@return any err
local function core(cid, name, ...)
    if cid then applying[cid] = (applying[cid] or 0) + 1 end
    local adapter = Framework()
    local ran, ok, err = false, 'not started', nil
    if adapter and Integrations.up(adapter) then ran, ok, err = Integrations.call('framework', name, ...) end
    if cid then
        applying[cid] = (applying[cid] or 1) - 1
        if applying[cid] <= 0 then applying[cid] = nil end
    end
    return ran, ok, err
end

--- The job definition qbx_core takes, from an organisation's state.
---@param org table
---@return table job
function Jobs.definition(org)
    local grades = {}
    for grade, role in pairs(org.roles) do
        grades[grade] = {
            name = role.label or role.name or ('Grade ' .. grade),
            payment = math.max(0, math.floor(tonumber(role.pay) or 0)),
            isboss = (Config.Organisation.QbxBossFlag == true and role.is_boss == true) or nil,
        }
    end
    if next(grades) == nil then grades[0] = { name = 'Member', payment = 0 } end
    return {
        label = org.label or org.job,
        type = org.jobType,
        defaultDuty = Config.Organisation.DefaultDuty ~= false,
        offDutyPay = false,
        grades = grades,
    }
end

--- Register the organisation's job, whole (CreateJobs).
---@param org table
---@return boolean ok
function Jobs.register(org)
    local ran, ok, msg = core(nil, 'CreateJobs', { [org.job] = Jobs.definition(org) })
    if not ran or ok == false then
        sayOnce('create:' .. org.job, ('warning: qbx_core would not register the organisation job %s (%s); '
            .. 'members keep their place here and are put back once it registers'):format(org.job,
            tostring(msg or ok)), true)
        return false
    end
    Jobs.checkStartOrder(org)
    return true
end

--- The job's label, type and duty (UpsertJobData).
function Jobs.upsertData(org)
    local def = Jobs.definition(org)
    core(nil, 'UpsertJobData', org.job, { label = def.label, type = def.type,
        defaultDuty = def.defaultDuty, offDutyPay = def.offDutyPay })
end

--- One role (UpsertJobGrade), or its removal (RemoveJobGrade).
function Jobs.upsertGrade(org, grade)
    local def = Jobs.definition(org)
    if def.grades[grade] and org.roles[grade] then
        core(nil, 'UpsertJobGrade', org.job, grade, def.grades[grade])
    else
        core(nil, 'RemoveJobGrade', org.job, grade)
    end
end

--- What qbx_core's member exports answer, as a refusal code here.
local function refusal(err)
    if type(err) == 'table' then return tostring(err.code or 'refused'), err.message end
    return 'refused', err
end

--- Put a citizen in the job at a grade, online or away (AddPlayerToJob).
---@return boolean ok
---@return string|nil code qbx_core's own ('max_jobs', 'job_missing_grade', ...)
function Jobs.setMember(org, cid, grade, primary)
    local ran, ok, err = core(cid, 'AddPlayerToJob', cid, org.job, grade)
    if not ran then return false, 'raised' end
    if ok == false then return false, refusal(err) end
    if primary then core(cid, 'SetPlayerPrimaryJob', cid, org.job) end
    return true
end

--- Take a citizen out of the job (RemovePlayerFromJob). One qbx_core does
--- not hold the job for answers so, which is no failure here.
function Jobs.removeMember(org, cid)
    local ran, ok, err = core(cid, 'RemovePlayerFromJob', cid, org.job)
    if not ran then return false, 'raised' end
    if ok == false then
        local code = refusal(err)
        if code == 'player_not_in_job' or code == 'job_not_found' then return true end
        return false, code
    end
    return true
end

--- What qbx_core says one loaded player holds of the job: their grade, or
--- nil; and whether it is their primary job.
---@return integer|nil grade
---@return boolean primary
function Jobs.heldBy(org, src)
    local ok, player = pcall(function() return Framework().GetPlayer(src) end)
    local data = ok and type(player) == 'table' and player.PlayerData or nil
    if type(data) ~= 'table' then return nil, false end
    local jobs = type(data.jobs) == 'table' and data.jobs or {}
    -- PlayerData.jobs holds every job the character has, the primary one
    -- included; a primary job missing from it is one core kept by name
    -- only (registered after they loaded), so not held.
    local grade = jobs[org.job]
    local primary = type(data.job) == 'table' and data.job.name == org.job
    if type(grade) == 'table' then grade = grade.level end
    return tonumber(grade), primary
end

--- Whether qbx:cleanPlayerGroups is on: qbx_core then deletes the members
--- of a job not registered yet at its start, so a removal it shows is not
--- one anybody made.
---@return boolean
function Jobs.cleansGroups()
    local clean = tostring(GetConvar('qbx:cleanPlayerGroups', 'false')):lower()
    return clean == 'true' or clean == '1'
end

--------------------------------------------------------------------------
-- Start-up checks, said once
--------------------------------------------------------------------------

--- The qbx_core settings that undo what this resource does, read from the
--- server's convars, and Renewed-Banking's start order. Each is said once,
--- to the console and kept for /ch-diag.
---@param org table|nil
---@return string[] lines what was found, for the panel
function Jobs.checkConvars()
    local out = {}
    local clean = tostring(GetConvar('qbx:cleanPlayerGroups', 'false')):lower()
    if clean == 'true' or clean == '1' then
        local text = 'warning: qbx:cleanPlayerGroups is on: at every qbx_core start it deletes the '
            .. 'members of any job not yet registered, which is the hitman organisation\'s every time. '
            .. 'Set it false in server.cfg; this resource puts its members back, but their job is gone '
            .. 'until it does.'
        sayOnce('cleanPlayerGroups', text, true)
        out[#out + 1] = text
    end
    local manage = tostring(GetConvar('qbx:enableGroupManagement', 'false')):lower()
    if manage == 'true' or manage == '1' then
        local text = 'warning: qbx:enableGroupManagement is on: qbx_management copies the organisation '
            .. 'job into its own table, overwrites its type, and lets a qbx boss menu change its '
            .. 'grades. Set it false while this resource owns the job.'
        sayOnce('enableGroupManagement', text, false)
        out[#out + 1] = text
    end
    local maxJobs = tonumber(GetConvar('qbx:max_jobs_per_player', '1')) or 1
    if maxJobs < 2 then
        local text = 'note: qbx:max_jobs_per_player is 1, so a player who already has a job cannot be '
            .. 'hired into the organisation (qbx_core answers max_jobs). Set it to 2 or more for both.'
        sayOnce('maxJobs', text, false)
        out[#out + 1] = text
    end
    return out
end

--- Renewed-Banking reads the job list once, when it starts. Started before
--- this registered the organisation, its own bank screen raises for every
--- member who opens it until it restarts.
function Jobs.checkStartOrder(org)
    local bank = Integrations.get('banking')
    if not bank or bank.resource ~= 'Renewed-Banking' then return end
    sayOnce('rbOrder:' .. org.job, ('warning: Renewed-Banking started before the %s job was registered: '
        .. 'its bank screen does not know the job until it restarts. Ensure crimson-hitman before '
        .. 'Renewed-Banking in server.cfg, or restart Renewed-Banking once; the organisation\'s funds '
        .. 'work either way.'):format(org.job), false)
end

return Jobs
