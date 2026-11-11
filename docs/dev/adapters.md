# Adapters: the other scripts this resource works with

Every call into another resource goes through a small adapter, one per
**kind** of script. The server owner picks which adapter answers each kind
in `config/config.lua`:

```lua
Config.Integrations = {
    Dispatch = 'auto',  -- 'auto' | 'sc-dispatch' | 'none'
    ...
}
```

- `'auto'` (as shipped): the first adapter, in list order, whose resource is
  started now.
- `'<name>'`: that adapter only, while its resource is started.
- `'none'`: no adapter. What needs one is off, or falls back to what the
  resource did without it (the table below).

The choice is read at the moment of each call, so a script started or stopped
later is picked up or let go at once. The start says one console line for each
kind left with no adapter: printed whatever `Config.Debug` says when a feature
that uses the kind is switched on, a Debug line when none is. A start or stop
of the script afterwards says the change. `/ch-diag` lists what answers each
kind (`other scripts: ...`), and the admin panel offers every choice under
Developer, **Other scripts** (client kinds are sent to every player's game).

## The kinds

| Kind (`Config.Integrations.`) | Shipped adapters | Side | Without one | Source read |
|---|---|---|---|---|
| `Framework` | `qbx_core` | server | Required: the resource waits for it (no `'none'`) | qbx_core 1.24 |
| `Inventory` | `ox_inventory` | server | Item, weapon and dirty-money rewards, burner phones and proof items are off; cash and bank work | ox_inventory 2.48 |
| `Target` | `ox_target` | client | Step markers and organisation spots get no third-eye option; map markers still show | ox_target 1.18.1 |
| `Dispatch` | `sc-dispatch` | server | Nothing filed in the police MDT; officers' phones are still told | escrowed: the two calls the resource always made, as the house rules document them |
| `Ambulance` | `sc-ambulance`, `qbx_medical` | both | Death and last stand from the framework's player metadata and the game | sc-ambulance escrowed (its `IsDead` / `IsLaststand`, as always called); qbx_medical read |
| `Banking` | `Renewed-Banking` | server | The organisation's funds in this resource's own ledger (chosen once, kept) | Renewed-Banking 2.1.4 |
| `Phone` | `lb-phone` | both | No phone app; notices shown in the game's feed | lb-phone 2.9 documented exports |
| `Keys` | `qbx_vehiclekeys` | server | The disposal vehicle is left unlocked, no keys | its `GiveKeys(source, vehicle)` as qbx_core calls it |
| `Mugshot` | `MugShotBase64` | client | No target headshots | MugShotBase64 read |
| `Clothing` | `qb-clothing`, `illenium-appearance`, `rcore_clothing` | client | A change of clothes does not refresh the headshot early | events only, as always listened for; not read |
| `Progression` | `sc-blackmarket` | server | No trust per completion | escrowed: `AddTrust(cid, amount)`, as always called |

Police jobs are not a script: who counts as police comes from
`Config.Advisory.RecipientJobTypes` / `RecipientJobNames` (`Police.jobs()`),
and the dispatch adapter is handed that list.

Three configurable provider exports stay as they were, for a server's own
script: `Config.Kidnap.RestraintProvider` (`IsRestrained`),
`Config.Immunity.PlaytimeProvider` and `Config.Relay.CallExport`, called
through `Bridge.call`.

## The interface

An adapter is a Lua table. Its functions have the names, arguments and
answers of the shipped adapter's resource (the reference): another inventory
implements `GetItem`, `AddItem` and the rest as `ox_inventory`'s exports
answer them. Read the shipped file of the kind for the exact list; each one
documents every function:

| Kind | Functions |
|---|---|
| framework | `GetPlayer`, `GetPlayerByCitizenId`, `GetOfflinePlayer`, `GetMetadata`, `Save`, `GetMoney`, `AddMoney`, `RemoveMoney`, `GetJob`, `CreateJobs`, `UpsertJobData`, `UpsertJobGrade`, `RemoveJobGrade`, `AddPlayerToJob`, `SetPlayerPrimaryJob`, `RemovePlayerFromJob`, and optionally `SetJobDuty` (the organisation's Duty: without it, qbx duty is left as it is) |
| inventory | `GetItem`, `GetItemCount`, `Search`, `AddItem`, `RemoveItem`, `CanCarryItem`, `GetInventoryItems`, `GetInventory` |
| dispatch | `AddNotification(alert)`, `ClearNotification(uniqueId, jobs)` |
| ambulance | `deathState(source) -> dead, lastStand` (server; leave it out when the server cannot tell) |
| banking | `installed()`, `CreateJobAccount`, `getAccountMoney`, `addAccountMoney`, `removeAccountMoney`, `handleTransaction` |
| phone (server) | `GetEquippedPhoneNumber`, `SendNotification`, `ContainsBlacklistedWord`, `IsInCall`, `EndCall`, `GetConfig`, `PostBirdy`, `canCall()`, `CreateCall` |
| phone (client) | `AddCustomApp`, `RemoveCustomApp`, `SendCustomAppMessage`, `SendNotification`, `SaveToGallery`, `EnableWalkableCam`, `DisableWalkableCam`, `SetCameraComponent` |
| keys | `GiveKeys(source, vehicle)` |
| target | `addSphereZone`, `removeZone`, `addLocalEntity`, `removeLocalEntity` |
| mugshot | `GetMugShotBase64(ped, transparent)` |
| clothing | `events = { 'their:outfitChanged', ... }` (no functions) |
| progression | `AddTrust(cid, amount)` |

Every adapter also has:

- `resource`: the resource it stands for (defaults to its name). 'auto' asks
  `GetResourceState(resource) == 'started'`.
- `detect` (optional): a function answering true while it can be used, in
  place of the resource check.

Functions may raise: every caller already calls them inside `pcall`, or
through `Integrations.call(kind, fn, ...)` (server), which is
`Bridge.invoke`: no adapter answers `false, 'off'`, a raise answers
`false, err` and prints one line a minute at most. Never call another
resource from anywhere but an adapter.

Code: `shared/integrations.lua` (the registry and the choice, both sides),
`server/adapters/init.lua` (loads the server adapters, `Integrations.call`,
the console lines), `server/adapters/list.lua` (which adapters exist, in
'auto' order), `server/adapters/<kind>/<name>.lua`,
`client/adapters/<kind>/<name>.lua`.

## Adding your own

1. Copy the template: `server/adapters/TEMPLATE.lua` to
   `server/adapters/<kind>/<your-resource>.lua` (a server kind), or
   `client/adapters/TEMPLATE.lua` to
   `client/adapters/<kind>/<your-resource>.lua` (a client kind; the manifest
   loads every `client/adapters/*/*.lua`). For phone and ambulance, which
   are on both sides, write both.
2. Fill in each function from **your script's own documentation or source**.
   Never guess an export: one that does not exist raises, and the feature is
   off with a line a minute in the console.
3. Add its name to `server/adapters/list.lua` under the kind, in front of the
   shipped one to try it first.
4. Set `Config.Integrations.<Kind> = '<your-resource>'` (or leave `'auto'`),
   restart the resource, and check `/ch-diag`: `other scripts: <kind>=<your-resource>`.

## Tests

`tests/adapters_spec.lua`: the detection matrix (auto, a name, none, stopped,
unknown), the owner's server picking what it used before, each kind set to
`'none'` saying one line and never raising, and what turns off without each.
