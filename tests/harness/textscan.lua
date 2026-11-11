--- Finding words players and staff read that are still written into code,
--- rather than looked up in locales/en.lua (tests/locale_spec.lua).
---
--- A small Lua lexer: comments and long strings are skipped, and every
--- quoted literal is reported with where it is and which call it sits in.
--- A literal is counted as words someone reads (TextScan.reads) when it has
--- a word in it and is shaped like a sentence or a title: two words or
--- more, a capital and small letters ('Unsettling'), or a full stop at the
--- end. Never counted: anything inside a console call (Log.*, print, error,
--- assert, Db.quiet), which stays English for the people who read the
--- console and the bug reports; SQL; paths, event names, patterns and
--- other one-word identifiers.

local TextScan = {}

--- Calls whose literals are console lines or developer messages, never
--- shown to a player or in the panel.
TextScan.CONSOLE = {
    ['Log.always'] = true, ['Log.debug'] = true, ['Log.problem'] = true, ['Log.raised'] = true,
    ['Log.notice'] = true, ['Log.plain'] = true, ['Log.console'] = true, ['Log.dropProblem'] = true,
    ['CrimsonLog.always'] = true, ['CrimsonLog.debug'] = true, ['CrimsonLog.problem'] = true,
    ['print'] = true, ['error'] = true, ['assert'] = true, ['Db.quiet'] = true, ['DebugPrint'] = true,
    ['CrimsonBoot.require'] = true, ['CrimsonBoot.requireShared'] = true, ['require'] = true,
    -- The label of a list of steps, said only in the console line a raise
    -- prints (server/lib/lifecycle.lua).
    ['Lifecycle.run'] = true,
    -- The line a store call that raised prints (server/lib/db.lua).
    ['Db.try'] = true,
}

local function isNameChar(c) return c:match('[%w_]') ~= nil end

--- Every quoted literal in `src` outside comments: { text (as written,
--- escapes left in), line, from, to (byte offsets of the quotes), callee
--- (the innermost call it is an argument of), console (inside a console
--- call at any depth) }.
---@param src string
---@return table[]
function TextScan.literals(src)
    local out = {}
    local i, n, line = 1, #src, 1
    local stack = {}            -- { callee = string|nil, console = boolean }
    local lastName, prevName = nil, nil  -- the name chain just before a '('
    while i <= n do
        local c = src:sub(i, i)
        if c == '\n' then
            line = line + 1; i = i + 1
        elseif c == '-' and src:sub(i, i + 1) == '--' then
            local eqs = src:match('^%[(=*)%[', i + 2)
            if eqs then
                local close = src:find(']' .. eqs .. ']', i + 2, true) or n
                for _ in src:sub(i, close):gmatch('\n') do line = line + 1 end
                i = close + #eqs + 2
            else
                local nl = src:find('\n', i, true) or (n + 1)
                i = nl
            end
        elseif c == '[' and src:match('^%[=*%[', i) then
            local eqs = src:match('^%[(=*)%[', i)
            local close = src:find(']' .. eqs .. ']', i, true) or n
            for _ in src:sub(i, close):gmatch('\n') do line = line + 1 end
            i = close + #eqs + 2
            lastName = nil
        elseif c == '\'' or c == '"' then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c then break
                else j = j + 1 end
            end
            local frame = stack[#stack]
            local console = false
            for k = 1, #stack do if stack[k].console then console = true end end
            out[#out + 1] = { text = src:sub(i + 1, j - 1), line = line, from = i, to = j,
                              callee = frame and frame.callee, console = console }
            i = j + 1
            lastName, prevName = nil, nil
        elseif isNameChar(c) then
            local j = i
            while j <= n and (isNameChar(src:sub(j, j))) do j = j + 1 end
            local word = src:sub(i, j - 1)
            if prevName and src:sub(i - 1, i - 1) == '.' or (prevName and src:sub(i - 1, i - 1) == ':') then
                lastName = prevName .. '.' .. word
            else
                lastName = word
            end
            prevName = lastName
            i = j
        elseif c == '(' then
            local callee = lastName
            local console = callee ~= nil and TextScan.CONSOLE[callee] == true
            stack[#stack + 1] = { callee = callee, console = console }
            lastName, prevName = nil, nil
            i = i + 1
        elseif c == ')' then
            stack[#stack] = nil
            lastName, prevName = nil, nil
            i = i + 1
        elseif c == '.' or c == ':' then
            i = i + 1
        else
            if not c:match('%s') then lastName, prevName = nil, nil end
            i = i + 1
        end
    end
    return out
end

local SQL = { SELECT = true, INSERT = true, UPDATE = true, DELETE = true, CREATE = true, ALTER = true,
              REPLACE = true, FROM = true, WHERE = true, SET = true, AND = true, ON = true }

--- Whether a literal reads as words for a player or staff member.
---@param text string
---@return boolean
function TextScan.reads(text)
    if not text:find('%a%a') then return false end
    -- Font Awesome icon names.
    if text:match('^fa%-') then return false end
    local first = text:match('^%s*(%u+)%s')
    if first and SQL[first] then return false end
    -- Two words or more.
    if text:find('%a%a+[%s]+[%a%%(]') or text:find('%a%s+%a%a') then return true end
    -- A title word: a capital, then small letters.
    if text:match('^%u%l+$') then return true end
    -- A sentence ending.
    if text:find('%a[%.!?]$') and not text:find('[_/:]') and not text:find('^[%w_]+%.[%w_]+$') then
        return true
    end
    return false
end

--- The literals in a file that read as words and are outside console
--- calls, minus those `allow` names ([text] = true).
---@param src string
---@param allow table|nil
---@return table[]
function TextScan.hardCoded(src, allow)
    local found = {}
    for _, lit in ipairs(TextScan.literals(src)) do
        if not lit.console and TextScan.reads(lit.text) and not (allow and allow[lit.text]) then
            found[#found + 1] = lit
        end
    end
    return found
end

--- Every L('key') (and Locale.t('key')) a source asks for.
---@param src string
---@return table<string, integer> key -> line
function TextScan.keysUsed(src)
    local used = {}
    for _, lit in ipairs(TextScan.literals(src)) do
        if (lit.callee == 'L' or lit.callee == 'Locale.t' or lit.callee == 'CrimsonLocale.t')
            and not used[lit.text] then
            used[lit.text] = lit.line
        end
    end
    return used
end

return TextScan
