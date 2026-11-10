--- Player checks every module shares: a citizen id to the server id they
--- are on now (Identity.sourceOf, used by the meeting point, the step
--- markers and the death watch), and the staff member a panel write is made
--- by (Panel.staffActor, used by the reward and reassign ops).

describe('Identity.sourceOf: a citizen id to their server id, while they are in the city', function()
    it('answers the source of a player online, and nil for anyone else', function()
        local s = newStack()
        fixture(s)
        eq(s.identity.sourceOf('CREATOR1'), 1)
        eq(s.identity.sourceOf('HITMAN01'), 3)
        eq(s.identity.sourceOf('NOBODY99'), nil, 'nobody by that id online')
        eq(s.identity.sourceOf(nil), nil)
        eq(s.identity.sourceOf('bad id!'), nil, 'not a citizen id')
        eq(s.identity.sourceOf({}), nil)
    end)

    it('says nil once they have left', function()
        local s = newStack()
        fixture(s)
        Env.players[3] = nil
        Env.byCitizen['HITMAN01'] = nil
        eq(s.identity.sourceOf('HITMAN01'), nil)
    end)
end)

describe('Panel.staffActor: who a panel write is made by', function()
    it('names a staff member in the city by their character', function()
        local s = newStack()
        fixture(s)
        local staff = s.panel.staffActor(1)
        eq(staff.cid, 'CREATOR1')
        eq(staff.source, 1)
        truthy(type(staff.name) == 'string' and staff.name ~= '', 'and their name')
    end)

    it('names the console, or a source with no character, by the panel\'s own word', function()
        local s = newStack()
        local staff = s.panel.staffActor(0)
        eq(staff.source, 0)
        eq(staff.name, nil)
        eq(staff.cid, select(1, s.panel.staffOf(0)), 'as Panel.staffOf names them')
    end)
end)
