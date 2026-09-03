--- A storage backend that returns deep copies from every read, the way a
--- real database does.
---
--- The memory and json backends hand back shared table references, so a
--- caller mutating a record it read earlier accidentally works. MySQL does
--- not behave that way. Running the conformance suite against this wrapper
--- catches code that depends on reference sharing before it reaches a live
--- server.

local function deepCopy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[k] = deepCopy(v, seen) end
    return out
end

return function(inner)
    local wrapper = {}

    -- Reads that must not leak a live reference.
    local COPYING_READS = {
        readContract = true, allContracts = true, readEscrow = true,
        readEscrowLine = true, readHunters = true, readHunter = true,
        readAmendment = true, readOpenAmendments = true, readMessages = true,
        readLedger = true, readPending = true, readAudit = true,
    }

    for name, fn in pairs(inner) do
        if type(fn) == 'function' then
            if COPYING_READS[name] then
                wrapper[name] = function(...) return deepCopy(fn(...)) end
            else
                wrapper[name] = fn
            end
        else
            wrapper[name] = fn
        end
    end

    return wrapper
end
