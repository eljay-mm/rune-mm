-- Filename: eljayPlugins/eqdbResultsPicker.lua
-- Purpose: Turns equipment search results into a picker that stays open for repeat item lookups.
-- Version: 1.2
-- Date: 2026-Oct-20
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.2  Matched repository command, help, load-time, and loader conventions.
--   1.1  Command is now eqdbResultsPicker (alias erp); added toggles and persistent settings.
--   1.0  Picker over equipment search results that reopens after each selection.
--
-- How it works:
--   * A span trigger collects lines from the search header through the results footer.
--   * Result lines are parsed and hex hashes are offered in a Rune picker.
--   * Selecting an item sends its lookup command; the picker can reopen for repeat lookups.
--   * The last result set can be reopened with the show option.
--
-- Commands (type without "/"; "erp" is a short alias for "eqdbResultsPicker"):
--   eqdbResultsPicker                 show this help
--   eqdbResultsPicker show            re-open the picker with the last results
--   eqdbResultsPicker on|off          enable / disable the results trigger
--   eqdbResultsPicker auto [on|off]   toggle automatic picker opening
--   eqdbResultsPicker keep [on|off]   toggle reopening after each selection
--   eqdbResultsPicker debug [on|off]  toggle debug messages (default off)
--   erp                               short alias for eqdbResultsPicker
--
-- Tweaks (top of file):
--   * LOOKUP_CMD    command sent for a selected item
--   * MAX_LINES     maximum lines collected for one search
--   * REOPEN_DELAY  delay before reopening the picker, in seconds

local LOAD_STARTED = os.clock()
local LOAD_MS = 0

-- Command names: full command and short alias.
local NAME  = "eqdbResultsPicker"
local SHORT = "erp"

local VERSION      = "1.2"
local LOOKUP_CMD   = "check eqlookup"
local MAX_LINES    = 200
local REOPEN_DELAY = 0.05

local style = rune.style
local H = require("helpstyle")

-- Settings (kept in rune.store).
local function load_setting(key, default)
    local ok, value = pcall(function()
        return rune.store.get(NAME .. "." .. key)
    end)
    if ok and type(value) == "boolean" then return value end
    return default
end

local function save_setting(key, value)
    pcall(function()
        rune.store.set(NAME .. "." .. key, value)
    end)
end

local enabled    = load_setting("enabled", true)
local auto_open  = load_setting("auto", true)
local keep_open  = load_setting("keep", true)
local debug_on   = load_setting("debug", false)
local last_items = {}

-- Output helpers.
local function say(message)
    rune.echo(style.cyan("[" .. NAME .. "] ") .. message)
end

local function dbg(message)
    if debug_on then say(style.dim("debug: " .. message)) end
end

local function onoff(value)
    return value and "on" or "off"
end

-- Parse one result line. Returns result number, hash, and item name.
local function parse_line(text)
    local num, hash, name =
        text:match("^%s*(%d+)%s+%[check%s+eqlookup%s+(%x+)%]%s*(.-)%s*$")

    if not hash then
        num, hash, name =
            text:match("^%s*(%d+)%s+%[eqlookup%s+(%x+)%]%s*(.-)%s*$")
    end

    if not hash then return nil end
    return tonumber(num), hash, name
end

local function build_items(lines)
    local items, skipped = {}, 0

    for _, line in ipairs(lines or {}) do
        local ok, text = pcall(function() return line:clean() end)
        if ok and type(text) == "string" then
            local num, hash, name = parse_line(text)
            if hash then
                items[#items + 1] = {
                    text = name ~= "" and name or hash,
                    desc = "#" .. tostring(num),
                    value = hash,
                }
            else
                skipped = skipped + 1
            end
        end
    end

    dbg(string.format("parsed %d item(s), skipped %d non-result line(s)",
        #items, skipped))
    return items
end

-- Picker.
local open_picker

open_picker = function(items)
    if not items or #items == 0 then
        say("no results to show")
        return
    end

    dbg("opening picker with " .. #items .. " item(s)")
    local ok, err = pcall(rune.ui.picker.show, {
        title = "Equipment (" .. #items .. ") - Esc to finish",
        items = items,
        match_description = false,
        on_select = function(hash)
            if type(hash) == "string" and hash:match("^%x+$") then
                dbg("sending: " .. LOOKUP_CMD .. " " .. hash)
                rune.send(LOOKUP_CMD .. " " .. hash)
            end

            if keep_open then
                rune.timer.after(REOPEN_DELAY, function()
                    open_picker(items)
                end, { name = NAME .. "-reopen" })
            end
        end,
    })

    if not ok then
        say("picker failed: " .. tostring(err))
    end
end

-- Capture search results from the header through the results footer.
rune.trigger.regex("^\\s*--- Searching for ---\\s*$", function(matches, ctx)
    if not enabled then return end

    local items = build_items(ctx.lines)
    last_items = items
    if auto_open and #items > 0 then open_picker(items) end
end, {
    name = NAME,
    span = { to = "^\\s*-+\\s*\\d+\\s+results?\\s*-+\\s*$", max = MAX_LINES },
})

-- Help and commands.
local function show_help()
    rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line(NAME, "show this help"))
    rune.echo(H.line(NAME .. " show", "re-open the picker with the last results"))
    rune.echo(H.line(NAME .. " on|off", "enable / disable the results trigger"))
    rune.echo(H.line(NAME .. " auto [on|off]", "toggle automatic picker opening"))
    rune.echo(H.line(NAME .. " keep [on|off]", "toggle reopening after each selection"))
    rune.echo(H.line(NAME .. " debug [on|off]", "toggle debug messages"))
    rune.echo(H.line(SHORT, "short alias for " .. NAME))
    rune.echo(H.foot(string.format(
        "v%s  enabled=%s auto=%s keep=%s debug=%s triggers=1 load=%dms",
        VERSION, tostring(enabled), tostring(auto_open), tostring(keep_open),
        tostring(debug_on), LOAD_MS)))
end

local function resolve(current, argument)
    if argument == "on" then return true end
    if argument == "off" then return false end
    return not current
end

local function handle(args)
    args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local word, rest = args:match("^(%S+)%s*(.-)$")
    word = word and word:lower() or ""
    rest = rest and rest:lower() or ""

    if word == "" then
        show_help()
    elseif word == "show" then
        open_picker(last_items)
    elseif word == "on" or word == "off" then
        enabled = word == "on"
        save_setting("enabled", enabled)
        say("trigger " .. onoff(enabled))
    elseif word == "auto" then
        auto_open = resolve(auto_open, rest)
        save_setting("auto", auto_open)
        say("auto-open picker: " .. onoff(auto_open))
    elseif word == "keep" then
        keep_open = resolve(keep_open, rest)
        save_setting("keep", keep_open)
        say("keep picker open after selecting: " .. onoff(keep_open))
    elseif word == "debug" then
        debug_on = resolve(debug_on, rest)
        save_setting("debug", debug_on)
        say("debug: " .. onoff(debug_on))
    else
        say("unknown option '" .. word .. "'")
        show_help()
    end
end

rune.alias.exact(NAME, function(args, ctx)
    handle(args)
end)

rune.alias.exact(SHORT, function(args, ctx)
    handle(args)
end)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
