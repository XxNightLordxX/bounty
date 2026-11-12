--- Finding words a page shows that are still written into it rather than
--- looked up with t('section.key') in locales/en.json (tests/locale_spec.lua).
---
--- A small JavaScript lexer: comments, regular expressions and template
--- text are skipped, and every quoted literal is reported with the call it
--- is an argument of and the tokens on either side. A literal counts as
--- words (TextScan.reads, the same rule as the Lua scan) unless it is
--- plainly not shown: an object key, one side of a comparison, an index,
--- a list of CSS classes or icons, a key prefix ('st.'), the 'use strict'
--- line, or anything inside a console call or t()/Text.* itself.

local TextScan = require('tests.harness.textscan')

local PageScan = {}

local function isName(c) return c:match('[%w_$]') ~= nil end

--- Tokens after which a '/' starts a regular expression.
local REGEX_AFTER = { ['('] = true, [','] = true, ['='] = true, [':'] = true, ['['] = true, ['!'] = true,
    ['&'] = true, ['|'] = true, ['?'] = true, ['{'] = true, ['}'] = true, [';'] = true, ['+'] = true,
    ['-'] = true, ['*'] = true, ['%'] = true, ['<'] = true, ['>'] = true, ['~'] = true, ['^'] = true,
    ['return'] = true, ['typeof'] = true, ['case'] = true, ['in'] = true, ['of'] = true, [''] = true }

--- Every quoted literal in `src`: { text, line, callee, before, after }.
---@param src string
---@return table[]
function PageScan.literals(src)
    local out, stack = {}, {}
    local i, n, line = 1, #src, 1
    local last, lastName = '', nil
    local pendingCallee = nil
    while i <= n do
        local c = src:sub(i, i)
        local two = src:sub(i, i + 1)
        if c == '\n' then line = line + 1; i = i + 1
        elseif c:match('%s') then i = i + 1
        elseif two == '//' then i = (src:find('\n', i, true) or n + 1)
        elseif two == '/*' then
            local close = src:find('*/', i + 2, true) or n
            for _ in src:sub(i, close):gmatch('\n') do line = line + 1 end
            i = close + 2
        elseif c == '/' and REGEX_AFTER[last] then
            local j, class = i + 1, false
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 1
                elseif d == '[' then class = true
                elseif d == ']' then class = false
                elseif d == '/' and not class then break
                elseif d == '\n' then break end
                j = j + 1
            end
            i = j + 1
            while i <= n and src:sub(i, i):match('%a') do i = i + 1 end
            last = 'regex'
        elseif c == '\'' or c == '"' or c == '`' then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c then break
                else
                    if d == '\n' then line = line + 1 end
                    j = j + 1
                end
            end
            if c ~= '`' then
                local frame = stack[#stack]
                local skipCall = false
                for k = 1, #stack do if stack[k].skip then skipCall = true end end
                -- t()/tn(): the key is not words; the values after it may be.
                for k = 1, #stack do
                    if stack[k].key and stack[k].args == 0 then
                        skipCall = true
                    end
                end
                local after = src:match('^%s*([^%s])', j + 1) or ''
                local after2 = src:match('^%s*([=!]=)', j + 1)
                -- The nearest call it is inside, through any bare brackets
                -- ('a' + (b ? ' c' : '')): which argument of el() it is.
                local outer
                for k = #stack, 1, -1 do
                    if stack[k].callee then outer = stack[k]; break end
                end
                local lineStart = src:sub(1, i - 1):match('.*\n()') or 1
                out[#out + 1] = { text = src:sub(i + 1, j - 1), line = line,
                    callee = frame and frame.callee, arg = frame and frame.args or 0, inCall = skipCall,
                    before = last, after = after2 or after,
                    outer = outer and outer.callee, outerArg = outer and outer.args or 0,
                    lead = src:sub(lineStart, i - 1) }
            end
            i = j + 1
            last = 'string'
        elseif isName(c) then
            local j = i
            while j <= n and isName(src:sub(j, j)) do j = j + 1 end
            local word = src:sub(i, j - 1)
            if last == '.' and lastName then lastName = lastName .. '.' .. word else lastName = word end
            last = word
            i = j
        elseif c == '(' then
            local callee = (last ~= 'string' and last ~= ')' and lastName and isName(last:sub(1, 1))) and lastName or nil
            -- warn is the Text block's own console line.
            local skip = callee ~= nil and (callee:match('^console%.') ~= nil
                or callee == 'warn' or callee:match('^Text%.') ~= nil)
            local key = callee == 't' or callee == 'tn'
            stack[#stack + 1] = { callee = callee, skip = skip, key = key, args = 0 }
            last, lastName = '(', nil
            i = i + 1
        elseif c == ')' then
            stack[#stack] = nil
            last, lastName = ')', nil
            i = i + 1
        else
            if c == ',' and stack[#stack] then stack[#stack].args = stack[#stack].args + 1 end
            local op = src:match('^[=!]==?', i) or src:match('^[&|]+', i) or c
            if c ~= '.' then lastName = (c == '.' and lastName) or nil end
            last = (op:sub(1, 1) == '=' or op:sub(1, 1) == '!') and op or c
            i = i + #op
        end
    end
    return out
end

--- The CSS classes a page's style sheets define.
---@param cssTexts string[]
---@return table<string, boolean>
function PageScan.classes(cssTexts)
    local out = {}
    for _, css in ipairs(cssTexts) do
        for name in css:gmatch('%.(%-?[_%a][%w_%-]*)') do out[name] = true end
    end
    return out
end

local function classy(text, classes)
    local any = false
    for tok in text:gmatch('%S+') do
        any = true
        if not (classes[tok] or tok:match('^[ih][sa]?%-[%w%-]+$') or tok:match('^fa%-')
            or tok:match('^i%-') or tok:match('^%l+%-[%l%d%-]+$')) then
            return false
        end
    end
    return any
end

--- The literals in a page that read as words and are shown, minus those
--- `allow` names ([text] = true).
---@param src string
---@param classes table<string, boolean>
---@param allow table|nil
---@return table[]
function PageScan.hardCoded(src, classes, allow)
    local found = {}
    for _, lit in ipairs(PageScan.literals(src)) do
        local text = lit.text
        -- 'Roles & pay' is words too.
        local shown = not lit.inCall and (TextScan.reads(text) or TextScan.reads((text:gsub('&', 'and'))))
            and lit.after ~= ':' and lit.after ~= '==' and lit.after ~= '===' and lit.after ~= '!=' and lit.after ~= '!=='
            and lit.after ~= ']' and lit.before ~= '==' and lit.before ~= '===' and lit.before ~= '!=' and lit.before ~= '!=='
            and lit.before ~= 'case' and text ~= 'use strict'
            and not classy(text, classes)
            and not (text:match('^[%a_][%w_%.]*%.$') and not text:find('%s') and not text:match('^%u%l+%.$'))
        if shown and not (allow and allow[text]) then found[#found + 1] = lit end
    end
    return found
end

--- Whether a literal is where a page puts CSS classes: el()'s class
--- argument, or after `className =`, `class:` or `classList.` on its line.
--- Not merely words that happen to be class names: ' more', 'with ' and
--- ' switch' are classes in the style sheets and English in the sentence
--- they were joined to (8g).
local function asClass(lit)
    if lit.outer == 'el' and lit.outerArg == 1 then return true end
    local lead = lit.lead or ''
    return lead:find('className%s*%+?=') ~= nil or lead:find('class%s*:') ~= nil
        or lead:find('classList%.') ~= nil
end

--- English joined to other text with `+` (L1): ' of ', ' minute', ' ago',
--- 'Stake: '. Each is a piece of a sentence a translator cannot reorder,
--- and one word is enough, which hardCoded (two words or a title) lets by.
--- A literal next to a `+` counts when it holds a word of two letters or
--- more and is not a class list where the page puts classes (asClass), a
--- key prefix ('admin.') or a lone symbol. Plurals built in place
--- ("? '' : 's'", "? '' : 'es'", "n === 1 ? ' item' : ' items'", and
--- "n === 1 ? t('a') : t('b')", two keys where tn() gives the forms) count
--- too.
---
--- Not counted: keys joined to values or to each other
--- (t('app.min_ago') after a number, t('a') + t('b')). The scan reads
--- literals, and a key's is inside t(); each piece is still a key a
--- translator can change, though not reorder. A known carve-out, left for
--- a wider pass over the pages' sentences.
---@param src string
---@param classes table<string, boolean>
---@param allow table|nil
---@return table[]
function PageScan.joined(src, classes, allow)
    local found = {}
    for _, lit in ipairs(PageScan.literals(src)) do
        local text = lit.text
        local joined = lit.before == '+' or lit.after == '+'
        if joined and not lit.inCall and text:find('%a%a') and text:find('%s')
            and not (asClass(lit) and classy(text, classes)) and not (allow and allow[text]) then
            found[#found + 1] = lit
        end
    end
    local line = 1
    for text in (src .. '\n'):gmatch('([^\n]*)\n') do
        if text:find("%?%s*''%s*:%s*'e?s'") or text:find("%?%s*'e?s'%s*:%s*''")
            or text:find("===?%s*1%s*%?%s*'[^']*%a%a[^']*'%s*:%s*'")
            or text:find("===?%s*1%s*%?%s*t%(.-:%s*t%(") then
            found[#found + 1] = { text = "'' : 's'", line = line }
        end
        line = line + 1
    end
    return found
end

--- Every t('section.key') a page asks for: key -> line.
---@param src string
---@return table<string, integer>
function PageScan.keysUsed(src)
    local used = {}
    for _, lit in ipairs(PageScan.literals(src)) do
        if (lit.callee == 't' or lit.callee == 'Text.t') and lit.arg == 0 then
            used[lit.text] = used[lit.text] or lit.line
        elseif lit.callee == 'tn' and lit.arg == 0 then
            -- A count's words: the two forms English has.
            for _, form in ipairs({ '_one', '_other' }) do
                used[lit.text .. form] = used[lit.text .. form] or lit.line
            end
        end
    end
    return used
end

return PageScan
