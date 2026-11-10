--- One rules table per target class (Config.TargetClasses, step 3f), read
--- by one resolver (Util.targetRule): `default` for every target,
--- `whitelisted` for a target on a whitelisted job. The anonymity switches
--- and the per-class informant switches live there; the duplicated
--- Anonymity.WhitelistedTargets and InformantsWhitelistedTargets blocks,
--- their settings and the per-rule readers are gone (rule 4: no aliases).

local Util = require('crimson-hitman.shared.util')

describe('one rules table per target class', function()
    it('reads each rule from the class of the target', function()
        newStack()
        eq(Util.targetClass(true), 'whitelisted')
        eq(Util.targetClass(false), 'default')
        eq(Util.targetClass(nil), 'default')
        Config.TargetClasses.default.ShowPlacerOnBoard = true
        Config.TargetClasses.whitelisted.ShowPlacerOnBoard = false
        truthy(Util.targetRule('ShowPlacerOnBoard', false), 'default')
        falsy(Util.targetRule('ShowPlacerOnBoard', true), 'whitelisted')
        Config.TargetClasses.whitelisted.ShowPlacerOnBoard = 'yes'
        falsy(Util.targetRule('ShowPlacerOnBoard', true), 'anything but true is off')
        Config.TargetClasses.whitelisted = nil
        falsy(Util.targetRule('ShowOperativeNames', true), 'a class that is not a table is all off')
        falsy(Util.targetRule('NoSuchRule', false), 'an unknown rule is off')
    end)

    it('ships the behaviour of before: anonymity off, names to the target, informants by their own switch', function()
        local shipped = require('crimson-hitman.config.config')
        local classes = Config and shipped and Config.TargetClasses
        truthy(classes, 'Config.TargetClasses')
        local file = assert(io.open('crimson-hitman/config/config.lua', 'r')):read('a')
        local env = {}
        assert(load(file, 'config.lua', 't', env))()
        local tc = env.Config.TargetClasses
        for _, class in ipairs({ 'default', 'whitelisted' }) do
            eq(tc[class].AllowAnonymousPlacer, false, class)
            eq(tc[class].AllowAnonymousHitman, false, class)
            eq(tc[class].ShowOperativeNames, true, class)
            eq(tc[class].ShowPlacerOnBoard, false, class)
        end
        for _, section in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip' }) do
            eq(tc.default[section], true, 'default ' .. section .. ': as its own switch says')
            eq(tc.whitelisted[section], false, 'whitelisted ' .. section)
            eq(env.Config.Intel[section].Enabled, false, section .. ' ships off')
        end
        eq(env.Config.Anonymity.AllowAnonymousPlacer, nil)
        eq(env.Config.Anonymity.WhitelistedTargets, nil)
        eq(env.Config.InformantsWhitelistedTargets, nil)
    end)

    it('leaves no old key, setting or reader behind', function()
        local s = newStack()
        for _, key in ipairs({ 'Anonymity.AllowAnonymousPlacer', 'Anonymity.ShowOperativeNames',
            'Anonymity.WhitelistedTargets.AllowAnonymousPlacer', 'InformantsWhitelistedTargets.Informant' }) do
            eq(s.settings.entry(key), nil, key)
        end
        for _, key in ipairs({ 'TargetClasses.default.AllowAnonymousPlacer',
            'TargetClasses.default.Informant', 'TargetClasses.whitelisted.ShowPlacerOnBoard',
            'TargetClasses.whitelisted.LocationTip' }) do
            truthy(s.settings.entry(key), key)
        end
        for _, name in ipairs({ 'anonymityAllowed', 'operativeNamesShown', 'placerShownOnBoard' }) do
            eq(Util[name], nil, 'Util.' .. name)
        end
    end)

    it('sets a class switch from the panel at once, and keeps it', function()
        local s = newStack()
        local key = 'TargetClasses.whitelisted.AllowAnonymousPlacer'
        -- The other way from where it stands, so the change is real.
        local want = Config.TargetClasses.whitelisted.AllowAnonymousPlacer ~= true
        truthy(s.settings.set(key, want, 'ADMIN001'))
        eq(Util.targetRule('AllowAnonymousPlacer', true), want, 'at once')
        eq(Util.targetRule('AllowAnonymousPlacer', false), Config.TargetClasses.default.AllowAnonymousPlacer == true,
            'the other class untouched')
        eq(s.storage.readSettings()[key].value, want, 'kept')
        falsy(s.settings.set(key, 'yes', 'ADMIN001'), 'not a true or false')
    end)
end)
