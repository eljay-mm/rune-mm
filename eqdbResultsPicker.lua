-- Filename: eljayPlugins/eqdbResultsPicker.lua
-- Purpose: Equipment search results -> picker -> eqlookup
-- Version: 1.0
-- Date: 2026-Oct-09
--
-- How it works:
--  * A multi-line (span) trigger starts at the "--- Searching for ---" header
--    and collects every line up to the "---------- N results ----------" footer.
--  * Each result line of the form
--        3    [check eqlookup <hash>] a flake of Lord Bloodbane's tourmaline
--    is parsed into: result number, hash, item name.
--  * When the footer arrives, the items are placed in a Rune picker
--    (rune.ui.picker.show, modal). Type to fuzzy-filter, up/down to move,
--    enter/tab to select, esc to cancel.
--  * Selecting an item sends "eqlookup <hash>" to the game, then the picker
--    re-opens with the same items so you can choose several in a row.
--    The picker stays up until you cancel it with ESC.
--  * The original output is left untouched in the main window.
--  * The last result set is remembered, so /eqdb re-opens the picker later.
--
-- Commands:
--  * /eqdb            re-open the picker with the last search results
--  * /eqdb auto       toggle opening the picker automatically (default: on)
--  * /eqdb auto on|off
--  * /eqdb keep       toggle re-opening after each selection (default: on)
--  * /eqdb keep on|off
--
-- Tweaks (top of file):
--  * LOOKUP_CMD       the command sent for a selection ("eqlookup")
--  * MAX_LINES        safety limit for how many lines one search may span
--  * REOPEN_DELAY     seconds to wait before re-opening the picker, so the
--                     previous picker has fully closed first

local LOOKUP_CMD   = "check eqlookup"
local MAX_LINES    = 200
local REOPEN_DELAY = 0.05

local last_items = {}
local auto_open  = true
local keep_open  = true

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Run fn shortly after the current callback returns (falls back to a direct call).
local function defer(fn)
    if rune.timer and rune.timer.after then
        local ok = pcall(rune.timer.after, REOPEN_DELAY, fn)
        if ok then return end
    end
    fn()
end

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
    local items = {}
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
            end
        end
    end
    return items
end

local open_picker

open_picker = function(items)
    if not items or #items == 0 then
        rune.echo("[eqdb] no results to show")
        return
    end
    rune.ui.picker.show({
        title = "Equipment (" .. #items .. ")",
        items = items,
        match_description = false,
        on_select = function(hash)
            if hash and hash ~= "" then
                rune.send(LOOKUP_CMD .. " " .. hash)
            end
            -- ESC never reaches here, so it ends the loop.
            if keep_open then
                defer(function() open_picker(items) end)
            end
        end,
    })
end

-- Span trigger: header ... footer
rune.trigger.regex("^\\s*--- Searching for ---\\s*$", function(matches, ctx)
    local items = build_items(ctx.lines)
    last_items = items
    if auto_open and #items > 0 then
        open_picker(items)
    end
end, {
    name = "eqdb",
    span = { to = "^\\s*-+\\s*\\d+\\s+results?\\s*-+\\s*$", max = MAX_LINES },
})

local function toggle(current, arg)
    if arg == "on" then return true end
    if arg == "off" then return false end
    return not current
end

rune.command.add("eqdb", function(args)
    args = trim(args or "")
    local word, rest = args:match("^(%S+)%s*(.-)$")

    if word == "auto" then
        auto_open = toggle(auto_open, rest)
        rune.echo("[eqdb] auto-open picker: " .. (auto_open and "on" or "off"))
        return
    elseif word == "keep" then
        keep_open = toggle(keep_open, rest)
        rune.echo("[eqdb] keep picker open after selecting: " .. (keep_open and "on" or "off"))
        return
    end

    open_picker(last_items)
end, "Re-open the last equipment search picker (/eqdb auto, /eqdb keep toggle behaviour)")