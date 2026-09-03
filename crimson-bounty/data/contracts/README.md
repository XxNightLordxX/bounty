# Contract files

One file per contract, written by `Config.Database.Mode = 'json'`.

This file exists so the directory does, because `SaveResourceFile` will not
create it. Deleting a contract file that `../store.json` still lists is a
contract's escrow gone: the resource refuses to start rather than continue
without it.
