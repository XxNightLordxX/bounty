--- A page's source with its words put back (tests that read ui/app.js or
--- ui/admin.js for what a screen says, or how it says it).
---
--- The pages read every word through t('section.key'), from
--- locales/en.json. A test that looks for a sentence in the page's source
--- reads it through PageWords.resolve, which writes each t('section.key')
--- back as the English text it reads, quoted as the page wrote it before:
--- the test then asserts what it always did, about the words staff and
--- players see.

local PageWords = {}

local english = nil

local function slurp(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

--- locales/en.json, read once.
---@return table
function PageWords.english()
    if not english then english = json.decode(slurp('crimson-hitman/locales/en.json')) end
    return english
end

--- The English text of a page key ('app.cancel'), or nil.
---@param key string
---@return string|nil
function PageWords.text(key)
    local section, name = tostring(key):match('^([%w_]+)%.(.+)$')
    local words = section and PageWords.english()[section]
    return type(words) == 'table' and words[name] or nil
end

--- `src` with every t('section.key') written back as its quoted English.
---@param src string
---@return string
function PageWords.resolve(src)
    return (src:gsub("%f[%w_%.]t%('([%w_]+%.[%w_]+)'%)", function(key)
        local text = PageWords.text(key)
        if not text then return nil end
        return "'" .. text:gsub('\\', '\\\\'):gsub("'", "\\'") .. "'"
    end))
end

--- A page's source (path under crimson-hitman/) with its words put back.
---@param path string
---@return string
function PageWords.source(path)
    return PageWords.resolve(slurp('crimson-hitman/' .. path))
end

return PageWords
