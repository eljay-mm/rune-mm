-- Filename: eljayPlugins/eqdbResultsPicker.lua
-- Purpose: Turns equipment search results into a picker that stays open for repeat item lookups.
-- Version: 1.1
-- Date: 2026-Oct-13
--
-- Changelog:
--  * 1.1  Command is now eqdbResultsPicker (alias erp) so it no longer clashes with the
--         in-game eqdb command; typed without "/"; bare command shows help; added on/off
--         and debug toggles; settings kept in rune.store; single-row load message;
--         hash is validated as hex before it is sent.
--  * 1.0  Picker over "--- Searching for ---" results that reopens after each selection.
--
-- How it works:
--  * A multi-line (span) trigger starts at the "--- Searching for ---" header
--    and collects every line up to the "---------- N results ----------" footer.
--  * Each result line of the form
--        3    [check eqlookup <hash>] a flake of Lord Bloodbane's treasured tourmaline
--    is parsed into: result number, hash, item name. Only hex hashes are accepted.
--  * When the footer arrives, the items are placed in a Rune picker
--    (rune.ui.picker.show, modal). Type to fuzzy-filter, up/down to move,
--    enter/tab to select, esc to cancel.
--  * Selecting an item sends "check eqlookup <hash>" to the game, then the picker
--    re-opens with the same items so you can choose several in a row.
--    The picker stays up until you cancel it with ESC (Rune gives no callback for ESC,
--    so the loop simply ends when no selection is made).
--  * The original output is left untouched in the main window.
--  * The last result set is remembered, so "eqdbResultsPicker show" re-opens it later.
--
-- Commands (type without "/"; "erp" is a short alias for "eqdbResultsPicker"):
--  * eqdbResultsPicker              show this help
--  * eqdbResultsPicker show         re-open the picker with the last search results
--  * eqdbResultsPicker on|off       enable / disable the results trigger
--  * eqdbResultsPicker auto [on|off]  toggle opening the picker automatically
--  * eqdbResultsPicker keep [on|off]  toggle re-opening the picker after each selection
--  * eqdbResultsPicker debug [on|off] toggle debug messages (default off)
--
-- Tweaks (top of file):
--  * LOOKUP_CMD       the command sent for a selection
--  * MAX_LINES        safety limit for how many lines one search may span
--  * REOPEN_DELAY     seconds to wait before re-opening the picker, so the
--                     previous picker has fully closed first

local NAME         = "eqdbResultsPicker"
local VERSION      = "1.1"
local LOOKUP_CMD   = "check eqlookup"
local MAX_LINES    = 200
local REOPEN_DELAY = 0.05

local style = rune.style

-- helpstyle comes from the base configuration; fall back to plain text if it is missing.
local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
    local function plain(s) return s end
    H = {
        title   = plain,
        section = plain,
        foot    = plain,
        line    = function(cmd, desc, width)
            return string.format(" %-" .. (width or 30) .. "s %s", cmd, desc or "")
        end,
    }
end

-- Settings (kept in rune.store) -----------------------------------------------------------

local function load_setting(key, default)
    local ok, v = pcall(function() return rune.store.get(NAME .. "." .. key) end)
    if ok and type(v) == "boolean" then return v end
    return default
end

local function save_setting(key, value)
    pcall(function() rune.store.set(NAME .. "." .. key, value) end)
end

local enabled   = load_setting("enabled", true)
local auto_open = load_setting("auto", true)
local keep_open = load_setting("keep", true)
local debug_on  = load_setting("debug", false)

local last_items = {}

-- Output helpers --------------------------------------------------------------------------

local function say(msg)
    rune.echo(style.cyan("[" .. NAME .. "] ") .. msg)
end

local function dbg(msg)
    if debug_on then say(style.dim("debug: " .. msg)) end
end

local function onoff(v) return v and "on" or "off" end

-- Parsing ---------------------------------------------------------------------------------

-- Parse one clean line. Returns number, hash, name (or nil if not a result line).
local function parse_line(text)
    local num, hash, name = text:match("^%s*(%d+)%s+%[check%s+eqlookup%s+(%x+)%]%s*(.-)%s*$")
    if not hash then
        -- tolerate a link without the leading "check"
        num, hash, name = text:match("^%s*(%d+)%s+%[eqlookup%s+(%x+)%]%s*(.-)%s*$")
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
                    text  = name ~= "" and name or hash,
                    desc  = "#" .. tostring(num),
                    value = hash,
                }
            else
                skipped = skipped + 1
            end
        end
    end
    dbg(string.format("parsed %d item(s), skipped %d non-result line(s)", #items, skipped))
    return items
end

-- Picker ----------------------------------------------------------------------------------

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
            -- ESC never reaches here, so it ends the loop.
            if keep_open then
                rune.timer.after(REOPEN_DELAY, function() open_picker(items) end,
                    { name = NAME .. "-reopen" })
            end
        end,
    })
    if not ok then
        say("picker failed: " .. tostring(err))
    end
end

-- Trigger: header ... footer --------------------------------------------------------------

rune.trigger.regex("^\\s*--- Searching for ---\\s*$", function(matches, ctx)
    if not enabled then return end
    local items = build_items(ctx.lines)
    last_items = items
    if auto_open and #items > 0 then
        open_picker(items)
    end
end, {
    name = NAME,
    span = { to = "^\\s*-+\\s*\\d+\\s+results?\\s*-+\\s*$", max = MAX_LINES },
})

-- Commands --------------------------------------------------------------------------------

local function show_help()
    rune.echo(H.title(NAME .. "  (alias: erp)"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line(NAME,                  "show this help"))
    rune.echo(H.line(NAME .. " show",       "re-open the picker with the last results"))
    rune.echo(H.line(NAME .. " on|off",     "enable / disable the results trigger"))
    rune.echo(H.line(NAME .. " auto",       "toggle opening the picker automatically"))
    rune.echo(H.line(NAME .. " keep",       "toggle re-opening after each selection"))
    rune.echo(H.line(NAME .. " debug",      "toggle debug messages"))
    rune.echo(H.foot(string.format("v%s  on=%s auto=%s keep=%s debug=%s  items=%d",
        VERSION, onoff(enabled), onoff(auto_open), onoff(keep_open), onoff(debug_on), #last_items)))
end

-- Explicit on/off wins; otherwise flip the current value.
local function resolve(current, arg)
    if arg == "on" then return true end
    if arg == "off" then return false end
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
        enabled = (word == "on")
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

-- One alias covers the full name and the short form, with optional arguments.
rune.alias.regex("^(?:eqdbResultsPicker|erp)(?:\\s+(.*))?$", function(m)
    handle(m and m[1] or "")
end)

say(string.format("v%s loaded (eqdbResultsPicker or erp for help)",
    VERSION))