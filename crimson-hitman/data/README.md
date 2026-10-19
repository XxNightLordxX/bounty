# Data directory

This directory exists so that `Config.Database.Mode = 'json'` works on a
fresh install.

FiveM's `SaveResourceFile` writes a file; it does **not** create the
directories above it. Without `data/` and `data/contracts/` already present,
every write fails silently — escrow would be taken from players and never
recorded, and a restart would lose it. The resource refuses to start in json
mode rather than run that way, and the message names this directory.

`store.json` holds the index — the sequence, the ledger, pending payouts,
the audit log and the stats. `contracts/<id>.json` holds one contract each,
with its escrow, hunters, amendments and messages, so a write touches only
the contract that changed.

Nothing here is needed in `mysql` or `memory` mode.
