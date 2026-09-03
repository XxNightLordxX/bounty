describe('PROBE', function()

  -- Claim 3: competitive, other hunters' stakes stranded on completion
  it('C3 competitive last-slot completion strands other hunters stakes', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local h2 = Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd', cash = 0, bank = 50000, firstname='B', lastname='B' })
    local a2 = s.identity.resolve(4)
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
      reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
    })
    truthy(s.contracts.accept(f.hunter, c.id, false))
    truthy(s.contracts.accept(a2, c.id, false))
    eq(Env.players[4].PlayerData.money.bank, 40000, 'B staked')
    local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
    truthy(ok, tostring(err))
    eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
    io.write('  B bank after completion: ' .. Env.players[4].PlayerData.money.bank, "\n")
    local held = 0
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
      if l.state ~= CB.ESCROW_STATE.SETTLED then held = held + (l.amount or 0) end
    end
    io.write('  still-held escrow on terminal contract: ' .. held, "\n")
    -- what happens if B abandons afterwards?
    local creatorBefore = Env.players[1].PlayerData.money.bank
    local ok2 = s.contracts.abandon(a2, c.id)
    io.write('  abandon after completion ok=' .. tostring(ok2) ..
          ' creator bank delta=' .. (Env.players[1].PlayerData.money.bank - creatorBefore) ..
          ' B bank=' .. Env.players[4].PlayerData.money.bank)
  end)

  -- Claim 4: LOWER_PENALTY mints money
  it('C4 lower_penalty to zero then claim: money minted', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x',
      reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
    })
    truthy(s.contracts.accept(f.hunter, c.id, false))
    eq(Env.players[3].PlayerData.money.bank, 40000)
    local ok, err = s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 0 })
    io.write('  improve(amount=0) ok=' .. tostring(ok) .. ' err=' .. tostring(err), "\n")
    io.write('  hunter bank after reduction: ' .. Env.players[3].PlayerData.money.bank, "\n")
    s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
    io.write('  hunter bank after claim: ' .. Env.players[3].PlayerData.money.bank ..
          ' (started 50000, staked 10000)')
  end)

  -- Claim 7: multi-slot, stake returned on first claim
  it('C7 multi-slot stake returned on first claim leaves hunter unbonded', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
      reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
      penaltyAmount = 10000,
    })
    truthy(s.contracts.accept(f.hunter, c.id, false))
    eq(Env.players[3].PlayerData.money.bank, 40000)
    truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
    io.write('  hunter bank after slot 1: ' .. Env.players[3].PlayerData.money.bank, "\n")
    eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
    local creatorBefore = Env.players[1].PlayerData.money.bank
    truthy(s.contracts.abandon(f.hunter, c.id))
    io.write('  after abandon: creator delta=' .. (Env.players[1].PlayerData.money.bank - creatorBefore) ..
          ' hunter bank=' .. Env.players[3].PlayerData.money.bank)
  end)

  -- Claim 8: lifetime expiry forfeits stake
  it('C8 lifetime expiry forfeits stake', function()
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
      targetCid = 'TARGET01', reason = 'x',
      reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
    })
    truthy(s.contracts.accept(f.hunter, c.id, false))
    local creatorBefore = Env.players[1].PlayerData.money.bank
    s.contracts.resolve(c.id, CB.STATE.EXPIRED, 'CREATOR1', nil, 'lifetime_exceeded')
    io.write('  creator delta=' .. (Env.players[1].PlayerData.money.bank - creatorBefore) ..
          ' hunter bank=' .. Env.players[3].PlayerData.money.bank)
  end)

  -- Claim 11: does writeContract ever fail?
  it('C11 backends writeContract return values', function()
    io.write('  memory writeContract returns: ' .. tostring(s_dummy), "\n")
  end)
end)
