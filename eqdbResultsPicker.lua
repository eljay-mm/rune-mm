-- Filename: eljayPlugins/eqdbResultsPicker.lua
-- Purpose: Turns equipment search results into a picker for repeat item lookups.
-- Version: 1.5
-- Date: 2026-Oct-27
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.5  Recognizes extended eqdb search headings.
--   1.4  Brought header, help, settings, and load behavior up to standards.
--
-- How it works:
--   * A span trigger collects lines from an eqdb search heading through its footer.
--   * Result lines are parsed and their hashes are offered in a Rune picker.
--   * Selecting an item sends its lookup command; the picker can reopen.
--   * The last result set can be reopened with the show option.
--
-- Commands (type without "/"):
--   eqdbResultsPicker      show this help
--   erp show               re-open the picker with the last results
--   erp on|off             enable / disable the results trigger
--   erp auto [on|off]      toggle automatic picker opening
--   erp keep [on|off]      toggle reopening after each selection
--   erp debug [on|off]     toggle debug messages (default off)
--   erp                    short alias for eqdbResultsPicker
--
-- Tweaks:
--   * LOOKUP_CMD   command sent for a selected item
--   * MAX_LINES    maximum lines collected for one search
--   * REOPEN_DELAY delay before reopening the picker, in seconds

local LOAD_STARTED = os.clock()
local LOAD_MS = 0

-- Command names: full command and short alias.
local NAME = "eqdbResultsPicker"
local SHORT = "erp"

local VERSION = "1.5"
local LOOKUP_CMD = "check eqlookup"
local MAX_LINES = 200
local REOPEN_DELAY = 0.05

local H
local style = rune.style

local settings_loaded = false
local settings = {}
local enabled = true
local auto_open = true
local keep_open = true
local debug_on = false
local last_items = {}

local function read_settings()
    local ok, value = pcall(function()
        return rune.store.get(NAME)
    end)

    if ok and type(value) == "table" then
        return value
    end
    return {}
end

local function setting_or(value, key, fallback)
    if type(value[key]) == "boolean" then
        return value[key]
    end
    return fallback
end

local function apply_settings(value)
    settings = value
    enabled = setting_or(value, "enabled", true)
    auto_open = setting_or(value, "auto", true)
    keep_open = setting_or(value, "keep", true)
    debug_on = setting_or(value, "debug", false)
end

local function ensure_settings()
    if settings_loaded then return end
    apply_settings(read_settings())
    settings_loaded = true
end

local function ensure_helpstyle()
    if not H then H = require("helpstyle") end
end

local function update_settings(mutate)
    local ok, fresh = pcall(function()
        return rune.store.get(NAME)
    end)
    if not ok or type(fresh) ~= "table" then fresh = {} end

    mutate(fresh)
    pcall(function()
        rune.store.set(NAME, fresh)
    end)

    apply_settings(fresh)
    settings_loaded = true
end

local function say(message)
    rune.echo(style.cyan("[" .. NAME .. "] ") .. message)
end

local function dbg(message)
    if debug_on then
        say(style.dim("debug: " .. message))
    end
end

local function onoff(value)
    return value and "on" or "off"
end

local function resolve(current, argument)
    if argument == "on" then return true end
    if argument == "off" then return false end
    return not current
end

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
        local ok, text = pcall(function()
            return line:clean()
        end)

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
        else
            skipped = skipped + 1
        end
    end

    dbg(string.format("parsed %d item(s), skipped %d line(s)",
        #items, skipped))
    return items
end

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

-- Match classic and extended eqdb search headings.
rune.trigger.regex("^\\s*-+\\s*Searching for.*-+\\s*$", function(matches, ctx)
    ensure_settings()
    if not enabled then return end

    local items = build_items(ctx.lines)
    last_items = items
    if auto_open and #items > 0 then
        open_picker(items)
    end
end, {
    name = NAME,
    span = {
        to = "^\\s*-+\\s*\\d+\\s+results?\\s*-+\\s*$",
        max = MAX_LINES,
    },
})

local function show_help()
    ensure_helpstyle()
    rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line(NAME, "show this help"))
    rune.echo(H.line(SHORT .. " show", "re-open the last results"))
    rune.echo(H.line(SHORT .. " on|off", "enable / disable the trigger"))
    rune.echo(H.line(SHORT .. " auto [on|off]", "toggle automatic opening"))
    rune.echo(H.line(SHORT .. " keep [on|off]", "toggle reopening after select"))
    rune.echo(H.line(SHORT .. " debug [on|off]", "toggle debug messages"))
    rune.echo(H.line(SHORT, "short alias for " .. NAME))
    rune.echo(H.foot(string.format(
        "v%s  enabled=%s auto=%s keep=%s debug=%s bindings=2 triggers=1 load=%dms",
        VERSION,
        onoff(enabled),
        onoff(auto_open),
        onoff(keep_open),
        onoff(debug_on),
        LOAD_MS
    )))
end

local function handle(args)
    ensure_settings()

    args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local word, rest = args:match("^(%S+)%s*(.-)$")
    word = word and word:lower() or ""
    rest = rest and rest:lower() or ""

    if word == "" then
        show_help()
    elseif word == "show" then
        open_picker(last_items)
    elseif word == "on" or word == "off" then
        update_settings(function(fresh)
            fresh.enabled = word == "on"
        end)
        say("trigger " .. onoff(enabled))
    elseif word == "auto" then
        update_settings(function(fresh)
            fresh.auto = resolve(setting_or(fresh, "auto", true), rest)
        end)
        say("auto-open picker: " .. onoff(auto_open))
    elseif word == "keep" then
        update_settings(function(fresh)
            fresh.keep = resolve(setting_or(fresh, "keep", true), rest)
        end)
        say("keep picker open after selecting: " .. onoff(keep_open))
    elseif word == "debug" then
        update_settings(function(fresh)
            fresh.debug = resolve(setting_or(fresh, "debug", false), rest)
        end)
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
say(string.format("v%s loaded (%s for help)", VERSION, NAME))
