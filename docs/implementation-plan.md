# Crimson Bounty System — Implementation Plan

**Resource name:** `crimson-bounty`
**App name:** Crimson Bounty System
**UI:** red / black
**Spec:** `docs/bounty-hunter-app-spec.md` (§ references below point there)

---

## 1. Confirmed target environment

Read directly from the uploaded server resources, not assumed:

| Component | Finding | Consequence |
|---|---|---|
| Framework | `qbx_core` (17mov bridge lists it; sc-* resources target QBox) | Identity via `exports.qbx_core:GetPlayer(source)` |
| Inventory | **ox_inventory** — `data/items.lua` is ox format (`weight`, `server.export`), user confirmed | All item/weapon escrow through `ox_inventory` exports |
| Phone | **lb-phone 2.8.0**, escrowed core, `oxmysql` dependency | Custom app via `AddCustomApp`; UI is a plain HTML page served by our resource |
| Multichar | **17mov character system**, bridges to `qbx_core` | Character = citizenid; account-level identity needed separately (§13.1) |
| Dirty money | item **`black_money`** ("Dirty Money") | Escrow source and payout currency |
| Crypto | item **`cryptostick`** — item only, no balance resource found | Treated as an item, not a currency |
| Black market | `sc-blackmarket`, `Config.BlackMoneyRate = 0.85` | **Dirty money is worth ~1.18× clean money there** — see §2 decision |
| Police/EMS jobs | `police, sheriff, leo, trooper, sasp, bcso, fib, ranger, doj, lawyer, ambulance`; job **types** `leo`, `police` | The spec's 5-name blacklist is insufficient — see §2 decision |
| Mugshots | `MugShotBase64` → `exports.MugShotBase64:GetMugShotBase64(ped, transparent)` | Client-side render source for §7.2 |
| Word filter | lb-phone `exports["lb-phone"]:ContainsBlacklistedWord(source, text)` | Reused for contract reason and relay messages (§14.30) |
| Photo capture | `SetCameraComponent{ cb = function(src) end }`, `SaveToGallery(link)` | Camera flow for §7.4 / §14.20 |
| Notifications | `exports["lb-phone"]:SendNotification{ app, title, content }` | §7.3 alerts |

## 2. Decisions taken (owner delegated these)

1. **Dirty-money payouts are source-faithful by default.** Escrow pays out in exactly the sources it holds (§14.10). Cross-currency conversion is a separate, explicit, **opt-in and lossy** step: `Config.Payout.AllowConversion = false`, and when enabled `Config.Payout.DirtyConversionRate = 0.85` — deliberately matching `sc-blackmarket`'s rate so converting is value-neutral rather than profitable. This closes the clean→dirty laundering arbitrage without removing the flavour.
2. **Job blacklist is by type *and* name.** Blocked job types: `leo`, `police`, `ems`, `fire`. Blocked names: `police, sheriff, leo, trooper, sasp, bcso, fib, ranger, doj, lawyer, ambulance, fire`. Both lists are config-editable; the type check is what stops a new LEO job from silently gaining access.
3. **Crypto = `cryptostick` item.** No crypto balance integration until one exists on the server.
4. **Account identity for anti-alt checks** comes from the player's license identifier, resolved server-side, never from the client (§13.1, §14.7).

## 3. Module layout

```
crimson-bounty/
  fxmanifest.lua
  config/
    config.lua            main tunables (§8, §15 appendix)
    jobs.lua              blacklist by type + name
  shared/
    constants.lua         states, enums, error codes
    util.lua              pure helpers — validation, math, formatting
  server/
    boot.lua              startup config validation (§14.47), capability checks
    identity.lua          source → player, account id, job gate (§14.1)
    ratelimit.lua         per-citizenid token buckets (§9.5, §14.27)
    audit.lua             financial + conduct log (§9.8, §14.31)
    storage/
      init.lua            backend selection + interface
      mysql.lua  json.lua  memory.lua      (§10)
    escrow.lua            record, debit, releaseEscrow with settle-state CAS (§9.1-9.3, §14.3)
    contracts.lua         state machine, locks, limits (§9.7, §9.10, §12.5)
    amendments.lua        additive vs material, approvals (§12)
    comms.lua             masked relay threads (§11)
    bailout.lua           §5 + §14.16/14.17
    informant.lua         §6.1 + §14.29
    ledger.lua            §6.3 + §14.43
    mugshot.lua           cache + push (§7.2, §14.26)
    tracking.lua          coarse ping (§14.22)
    completion/
      death.lua           victim-sourced reports + corroboration (§14.2)
      photo.lua           capture tokens, host allowlist (§14.20, §14.35)
      kidnap.lua          single shared tick, arm gate, grace budget (§14.23-14.25)
    projection.lua        per-recipient payload building (§14.4)
    app.lua               lb-phone registration, callbacks
  client/
    main.lua  app.lua  camera.lua  mugshot.lua  tracking.lua
  ui/
    index.html  app.css  app.js    (red/black, no CDN dependencies)
  tests/
    harness/              FiveM/qbx/ox/lb-phone stubs
    *_spec.lua            headless suites
    run.lua               runner
```

**Rule of construction:** every server file's public functions take `(citizenid, ...)` already resolved by `identity.lua`. No module reads `source` except `identity.lua` and the event handlers in `app.lua`.

## 4. Data model

`contracts` — id, creator_cid, creator_account, target_cid, reason, mode (`exclusive|competitive`), state, created_at, deadline_at, paused_ms, bailout_amount, penalty_amount, anon_creator, mugshot_ref, resolved_at, resolution.
`escrow` — contract_id, portion (`baseline|bonus`), source (`cash|bank|dirty|item|weapon`), amount|item_name|qty|metadata_json, state (`held|releasing|settled`), settled_at, settled_to.
`hunters` — contract_id, hunter_cid, hunter_account, alias, anon, accepted_at, stake_amount, state.
`amendments` — contract_id, proposer, kind, diff_json, expires_at, approvals_json, outcome.
`messages` — contract_id, thread_id, from_alias, body, sent_at.
`ledger` — cid, contract_id, role, photo_ref, summary_json, resolved_at.
`audit` — ts, actor_cid, action, contract_id, detail_json.

Same shape in all three persistence modes (§10.4).

## 5. Test strategy

No FiveM server is available in this environment, so correctness is established by a **headless harness** that stubs the natives and the three external resources, then runs the real server modules:

- **Stubs:** `exports`, `RegisterNetEvent`, `TriggerClientEvent`, `GetPlayerIdentifiers`, `CreateThread`, `SetTimeout`, `GetGameTimer`, `os.time`, plus fake `qbx_core`, `ox_inventory`, `lb-phone`, and a fake MySQL.
- **Suites:**
  1. escrow math and source-faithful release
  2. full state machine — every transition and every illegal transition
  3. double-release and race guards (CAS, competitive single-winner)
  4. refund paths incl. full inventory → pending, and restart reconciliation
  5. amendments — additive immediate, material approval, expiry, decline
  6. conflict rules — self-target, self-accept, alt account, caps
  7. exploit suite — forged payload identity, spoofed proximity, replayed/foreign capture token, killer-sourced death, non-allowlisted photo host, rate-limit evasion
  8. projection — asserts the exact allowed key set per recipient role, so anonymity can't widen in a refactor
  9. persistence — all three backends against the same suite
- **Static:** `luac -p` syntax check on every file; a lint pass for the §14.1 rule (no handler reads an identity from a payload).

What this cannot prove: behaviour against the real ox_inventory/lb-phone/qbx_core builds, and UI rendering on the real phone. Those get a written in-game smoke-test checklist.

## 6. Build order

1. Harness + stubs, so every later step is testable on arrival
2. `shared/`, `config/`, `identity`, `ratelimit`, `audit`
3. `storage/` (all three) + `escrow` + its suites
4. `contracts` + state machine + limits + suites
5. Completion: death → photo → kidnap + exploit suite
6. Amendments, comms, bailout, informant, ledger
7. Projection + app registration + client + UI
8. Full suite run, static checks, security review, in-game checklist
