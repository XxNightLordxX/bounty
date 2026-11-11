--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║        crimson-hitman - server/adapters/inventory/ox_inventory.lua        ║
    ║                      inventory adapter: ox_inventory                      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Read from ox_inventory 2.48 (modules/inventory/server.lua). Each
--- function is the export of the same name, with the same arguments and
--- answers:
---   GetItem(inv, item, metadata, returnsCount)
---   GetItemCount(inv, item, metadata, strict)
---   Search(inv, 'slots' | 'count', items, metadata)
---   AddItem(inv, item, count, metadata, slot)          -> success, response
---   RemoveItem(inv, item, count, metadata, slot)       -> success, response
---   CanCarryItem(inv, item, count, metadata)           -> boolean | nil
---   GetInventoryItems(inv), GetInventory(inv)
--- They may raise: the callers keep their pcall.

local Adapter = { resource = 'ox_inventory', label = 'ox_inventory' }

function Adapter.GetItem(...) return exports.ox_inventory:GetItem(...) end
function Adapter.GetItemCount(...) return exports.ox_inventory:GetItemCount(...) end
function Adapter.Search(...) return exports.ox_inventory:Search(...) end
function Adapter.AddItem(...) return exports.ox_inventory:AddItem(...) end
function Adapter.RemoveItem(...) return exports.ox_inventory:RemoveItem(...) end
function Adapter.CanCarryItem(...) return exports.ox_inventory:CanCarryItem(...) end
function Adapter.GetInventoryItems(...) return exports.ox_inventory:GetInventoryItems(...) end
function Adapter.GetInventory(...) return exports.ox_inventory:GetInventory(...) end

return Adapter
