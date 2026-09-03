local function P(...) io.write('    ', ..., "\n") end

describe('VERIFY', function()

  -- ================= CLAIM 1 =================
  it('C1 LOWER_PENALTY refunds a stake already forfeited to an offline creator', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 10000
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
      reward = { baseline = { cash = 5000 } }, penaltyAmount = 5000,
    })
    truthy(c, 'contract created')
    truthy(s.contracts.accept(f.hunter, c.id, false))
    eq(Env.players[3].PlayerData.money.bank, 5000, 'H1 staked 5000')

    -- creator logs out
    Env.removePlayer(1)
    truthy(s.contracts.abandon(f.hunter, c.id))
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
      if l.portion == CB.PORTION.STAKE then
        P(('after abandon: state=%s amount=%s owed_to=%s staker=%s'):format(
          tostring(l.state), tostring(l.amount), tostring(l.owed_to), tostring(l.staker)))
      end
    end
    P('pending queued for CREATOR1: ' .. #s.storage.readPending('CREATOR1'))

    -- creator returns and lowers the penalty before retryPending drains
    Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
      cash = 100000, bank = 100000, firstname = 'Vic', lastname = 'Marlowe' })
    local creator = s.identity.resolve(1)
    local ok, err = s.amendments.improve(creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 1 })
    P('improve ok=' .. tostring(ok) .. ' err=' .. tostring(err))
    P('H1 bank after: ' .. Env.players[3].PlayerData.money.bank)
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
      if l.portion == CB.PORTION.STAKE then
        P(('stake line now: state=%s amount=%s owed_to=%s'):format(
          tostring(l.state), tostring(l.amount), tostring(l.owed_to)))
      end
    end
  end)

  -- ================= CLAIM 2 =================
  it('C2 Bailout.owe line has no owed_to and is swept by an unfiltered release', function()
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x',
      reward = { baseline = { cash = 5000 } }, bailoutAmount = 5000,
    })
    truthy(c)
    truthy(s.contracts.accept(f.hunter, c.id, false))
    local ok, err = s.bailout.buy(f.target, c.id)
    P('buy ok=' .. tostring(ok) .. ' err=' .. tostring(err) ..
      ' queued=' .. tostring(s.storage.readContract(c.id).bailout_queued_at ~= nil))
    P('target bank after debit: ' .. Env.players[2].PlayerData.money.bank)

    -- claimSlot takes the COMPLETING lock and then yields on its awaits
    truthy(s.storage.compareSetContractState(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING))
    Env.removePlayer(2)                       -- target logs out
    Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
    local settled = s.bailout.processQueue()
    P('processQueue settled=' .. tostring(settled))
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
      P(('line %s slot=%s portion=%s amt=%s state=%s owed_to=%s'):format(
        l.id, tostring(l.slot), tostring(l.portion), tostring(l.amount),
        tostring(l.state), tostring(l.owed_to)))
    end
    P('pending for TARGET01: ' .. #s.storage.readPending('TARGET01'))

    -- claimSlot resumes: finalise() runs the unfiltered remainder release
    truthy(s.storage.compareSetContractState(c.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED))
    local before = Env.players[1].PlayerData.money.bank
    local ok2, err2 = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
    P('claimSlot ok=' .. tostring(ok2) .. ' err=' .. tostring(err2))
    P('creator bank delta across the completion: ' .. (Env.players[1].PlayerData.money.bank - before))
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
      if l.id:find('owed') then
        P(('owed line now: state=%s settled_to=%s'):format(tostring(l.state), tostring(l.settled_to)))
      end
    end
    -- and the target's retry finds nothing
    Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb', cash = 0, bank = 0 })
    local delivered = s.escrow.retryPending('TARGET01')
    P('target retryPending delivered=' .. tostring(delivered) ..
      ' remaining pending=' .. #s.storage.readPending('TARGET01') ..
      ' target bank=' .. Env.players[2].PlayerData.money.bank)
  end)

  -- ================= CLAIM 4 =================
  it('C4 stake is returned after the first of N slots', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 10000
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x',
      reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
      penaltyAmount = 4000,
    })
    truthy(c)
    truthy(s.contracts.accept(f.hunter, c.id, false))
    eq(Env.players[3].PlayerData.money.bank, 6000, 'staked 4000')
    local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
    truthy(ok, tostring(err))
    P('hunter bank after slot 1 of 2: ' .. Env.players[3].PlayerData.money.bank)
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
      if l.portion == CB.PORTION.STAKE then
        P(('stake line: state=%s settled_to=%s amount=%s'):format(
          tostring(l.state), tostring(l.settled_to), tostring(l.amount)))
      end
    end
    eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED, 'still live')
    local before = Env.players[1].PlayerData.money.bank
    truthy(s.contracts.abandon(f.hunter, c.id))
    P('creator gained from the forfeit: ' .. (Env.players[1].PlayerData.money.bank - before))
    P('hunter bank at the end: ' .. Env.players[3].PlayerData.money.bank)
  end)

  -- ================= CLAIM 7 =================
  it('C7 competitive accept that fails the stake leaves ACCEPTED with no hunter', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 10
    Env.players[3].PlayerData.money.cash = 10
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
      reward = { baseline = { cash = 5000 } }, penaltyAmount = 5000,
    })
    truthy(c)
    eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE)
    local ok, err = s.contracts.accept(f.hunter, c.id, false)
    P('accept ok=' .. tostring(ok) .. ' err=' .. tostring(err))
    P('contract state after the failed accept: ' .. s.storage.readContract(c.id).state)
    P('hunter records: ' .. #s.storage.readHunters(c.id))
    -- consequence: instant bailout instead of the processing delay
    local ok2, err2 = s.bailout.buy(f.target, c.id)
    P('target buyout while "accepted" with no hunter: ok=' .. tostring(ok2) ..
      ' err=' .. tostring(err2) .. ' state=' .. s.storage.readContract(c.id).state)
    -- and exclusive mode for comparison
    local s2 = newStack()
    local f2 = fixture(s2)
    Env.players[3].PlayerData.money.bank = 10
    Env.players[3].PlayerData.money.cash = 10
    local c2 = s2.contracts.create(f2.creator, {
      targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.EXCLUSIVE,
      reward = { baseline = { cash = 5000 } }, penaltyAmount = 5000,
    })
    s2.contracts.accept(f2.hunter, c2.id, false)
    P('exclusive state after the failed accept: ' .. s2.storage.readContract(c2.id).state)
  end)

  -- ================= CLAIM 8 =================
  it('C8 dirty and an item named black_money are counted separately', function()
    local s = newStack()
    local f = fixture(s)
    -- creator holds exactly 50000 black_money (see fixture)
    local spec = { baseline = { dirty = 50000, items = { { name = 'black_money', count = 50000 } } } }
    local lines, err = s.escrow.validate(f.creator, spec)
    P('validate(dirty 50000 + item 50000) -> ' .. tostring(lines and #lines) .. ' err=' .. tostring(err))

    local items = {}
    for i = 1, 10 do items[i] = { name = 'black_money', count = 100 } end
    local spec2 = { baseline = { dirty = 50000, items = items } }
    local lines2, err2 = s.escrow.validate(f.creator, spec2)
    P('validate(dirty 50000 + 10x100 item) -> ' .. tostring(lines2 and #lines2) .. ' err=' .. tostring(err2))
    if lines2 then
      local ok3, err3 = s.escrow.take(f.creator, 'ctX', lines2)
      P('take -> ok=' .. tostring(ok3) .. ' err=' .. tostring(err3))
      P('creator black_money after the failed take: ' ..
        tostring(exports.ox_inventory:GetItem(1, 'black_money', nil, true)))
      P('creator cash: ' .. Env.players[1].PlayerData.money.cash ..
        ' bank: ' .. Env.players[1].PlayerData.money.bank)
    end
  end)

  -- ================= CLAIM 9 =================
  it('C9 a weapon slot that matches nothing falls back to the first copy', function()
    local s = newStack()
    Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
      cash = 100000, bank = 100000, firstname = 'Vic', lastname = 'Marlowe',
      inventory = {
        { name = 'WEAPON_PISTOL', count = 1, slot = 1, metadata = { serial = 'GOOD', durability = 100 } },
        { name = 'WEAPON_PISTOL', count = 1, slot = 7, metadata = { serial = 'BEATEN', durability = 5 } },
      } })
    Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb', cash = 1, bank = 1 })
    local creator = s.identity.resolve(1)
    local lines = s.escrow.validate(creator, { baseline = { cash = 1000,
      weapons = { { name = 'WEAPON_PISTOL', slot = 7 } } } })
    P('exact slot 7 -> serial=' .. tostring(lines and lines[2] and lines[2].metadata.serial) ..
      ' inv_slot=' .. tostring(lines and lines[2] and lines[2].inv_slot))
    local lines2 = s.escrow.validate(creator, { baseline = { cash = 1000,
      weapons = { { name = 'WEAPON_PISTOL', slot = 99 } } } })
    P('nonexistent slot 99 -> serial=' .. tostring(lines2 and lines2[2] and lines2[2].metadata.serial) ..
      ' inv_slot=' .. tostring(lines2 and lines2[2] and lines2[2].inv_slot))
  end)

  -- ================= CLAIM 6 =================
  it('C6 retryPending drains five per login', function()
    local s = newStack()
    local f = fixture(s)
    for i = 1, 12 do
      s.storage.writeEscrow('ctZ', { { id = 'ctZ:' .. i, contract_id = 'ctZ', slot = 0,
        portion = CB.PORTION.BASELINE, source = 'bank', amount = 100,
        state = CB.ESCROW_STATE.HELD, owed_to = 'HUNTER01' } })
      s.storage.queuePending('HUNTER01', 'ctZ', 'ctZ:' .. i)
    end
    P('queued: ' .. #s.storage.readPending('HUNTER01'))
    local total = 0
    for login = 1, 4 do
      local d = s.escrow.retryPending('HUNTER01')
      total = total + d
      P(('login %d delivered %d, remaining %d'):format(login, d, #s.storage.readPending('HUNTER01')))
    end
    P('total delivered over 4 logins: ' .. total)
    -- an undeliverable line at the head
    local s2 = newStack()
    fixture(s2)
    for i = 1, 8 do
      s2.storage.writeEscrow('ctY', { { id = 'ctY:' .. i, contract_id = 'ctY', slot = 0,
        portion = CB.PORTION.BASELINE, source = i <= 5 and CB.SOURCE.ITEM or 'bank',
        item = 'anvil', quantity = 999999, amount = 100,
        state = CB.ESCROW_STATE.HELD, owed_to = 'HUNTER01' } })
      s2.storage.queuePending('HUNTER01', 'ctY', 'ctY:' .. i)
    end
    for login = 1, 3 do
      local d = s2.escrow.retryPending('HUNTER01')
      P(('blocked-head login %d delivered %d, remaining %d'):format(d and login or login, d, #s2.storage.readPending('HUNTER01')))
    end
  end)
end)
