--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║       crimson-hitman - server/adapters/banking/Renewed-Banking.lua        ║
    ║                     banking adapter: Renewed-Banking                      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Read from Renewed-Banking 2.1.4 (server/main.lua). The organisation's
--- funds (server/org/funds.lua) use these, with the same arguments and
--- answers as its exports:
---   CreateJobAccount({ name, label }, startingBalance)
---   getAccountMoney(account)                    -> number | false
---   addAccountMoney(account, amount)            -> boolean
---   removeAccountMoney(account, amount)         -> boolean
---   handleTransaction(account, title, amount, message, issuer, receiver, type)
--- They may raise: the callers keep their pcall. `installed` says whether
--- it is installed at all (started, starting, or stopped), which is what
--- the funds' first choice of backend asks.

local Adapter = { resource = 'Renewed-Banking', label = 'Renewed-Banking' }

function Adapter.installed()
    local state = GetResourceState('Renewed-Banking')
    return state ~= nil and state ~= 'missing' and state ~= 'unknown'
end

function Adapter.CreateJobAccount(...) return exports['Renewed-Banking']:CreateJobAccount(...) end
function Adapter.getAccountMoney(...) return exports['Renewed-Banking']:getAccountMoney(...) end
function Adapter.addAccountMoney(...) return exports['Renewed-Banking']:addAccountMoney(...) end
function Adapter.removeAccountMoney(...) return exports['Renewed-Banking']:removeAccountMoney(...) end
function Adapter.handleTransaction(...) return exports['Renewed-Banking']:handleTransaction(...) end

return Adapter
