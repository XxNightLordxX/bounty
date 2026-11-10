--- Capabilities that left their old name on purpose, and where each now
--- lives. tests/capability_inventory_spec.lua accepts a baseline item that
--- is no longer extracted only when it is listed here, and fails when the
--- place it names is not itself a current item.
---
--- Format: [old item] = 'new item', or { to = 'new item', note = 'why' }.
--- Items are written as the baseline writes them, 'category:name':
---
---     ['op:freeze'] = 'op:holdPlace',
---     ['config:Informant.Enabled'] = { to = 'config:Intel.Informant.Enabled',
---                                      note = 'informants merged under Intel' },
---
--- Once the baseline is regenerated after a merge, the entries it has folded
--- in may be removed from here (docs/dev/map.md, "Capability inventory").

return {
}
