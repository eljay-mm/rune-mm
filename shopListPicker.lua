-- Filename: eljayPlugins/shopListPicker.lua
-- Purpose: Turns the output of a shop `list` into a searchable picker that stays open for repeat purchases; selecting an item sends "shop buy <number>".
-- Version: 1.4
-- Date: 2026-Oct-12
-- Changelog:
--   1.4  Help footer is one row like jmcSolver: version first, then the key=value status ("v1.6  trigger=on  debug=off  items=N").
--   1.3  Settings (trigger on/off, debug on/off) are now persistent via rune.store; help now uses helpstyle exactly as autopouch.lua does.
--   1.2  Added on/off toggle for the trigger (`shopListPicker on|off`, default on).
--   1.1  Command renamed from shoppick to shopListPicker (same as the plugin name).
--   1.0  New. Based on researchNotesPicker.lua v1.7 with the opposite trigger (thesis rows are ignored, all other shop rows are collected) and no notes handling.
--
-- How it works:
--   * A trigger watches for shop rows in the list output, e.g.
--       "     4) A vial of exploding oil                      5     250          [        656 gold]"
--     and collects number, item name, level, amount and cost. Amount is a number or "No limit".
--   * Rows whose item name starts with "A thesis pertaining to" are skipped, so the
--     research list (rrl) still belongs to researchNotesPicker and never opens this picker.
--   * A shop list has no end-of-list marker, so a short debounce timer (0.4s after the last
--     row) decides the list is complete and opens the picker.
--   * Each selection (Enter/Tab) sends "shop buy <number>" and the picker reopens for the next
--     purchase. Esc closes the picker for good (nothing else to clean up, no notes involved).
--   * Typing in the picker fuzzy-filters on item name, number or cost.
--   * Only the digits captured by the trigger are ever sent to the server (no free text).
--   * Settings persist across restarts in rune.store ("shopListPicker.enabled" and
--     "shopListPicker.debug"); a missing value means trigger on, debug off.
--   * Commands (typing `shopListPicker` alone shows the summary):
--       shopListPicker             command summary (also shows trigger and debug state)
--       shopListPicker on|off      enable or disable the trigger (default on); while off, shop lists are ignored
--       shopListPicker open        reopen the picker with the last list without asking the server again
--       shopListPicker debug       show debug state; "shopListPicker debug on|off" toggles it (default off)
--   * Nothing is gagged: the normal shop list output still shows in the main window.

local H = require("helpstyle")

local VERSION = "1.4"   -- keep in sync with the Version line in the header

local DEBOUNCE = 0.4       -- seconds of silence after the last row before the picker opens
local THESIS   = "A thesis pertaining to"

local items    = {}        -- collected rows for the current shop list
local finished = true      -- true once the picker has opened for the current list

-- Persistent settings --------------------------------------------------------

local function enabled()   -- default on when never set
    return rune.store.get("shopListPicker.enabled") ~= false
end

local function debug_on()  -- default off when never set
    return rune.store.get("shopListPicker.debug") == true
end

local function dbg(msg)
    if debug_on() then rune.echo("[shopListPicker] " .. msg) end
end

local function status()
    return string.format("v%s  trigger=%s  debug=%s  items=%d",
        VERSION, enabled() and "on" or "off", debug_on() and "on" or "off", #items)
end

-- Picker ---------------------------------------------------------------------

local open_picker

-- Single purchase by item number.
local function buy(num)
    dbg("shop buy " .. num)
    rune.send("shop buy " .. num)
end

open_picker = function()
    if #items == 0 then
        rune.echo("[shopListPicker] No shop items captured yet - run the shop's list first.")
        return
    end
    dbg("opening picker with " .. #items .. " items")
    local ok, err = pcall(rune.ui.picker.show, {
        title = "Shop (shop buy) - Esc to finish",
        items = items,
        match_description = true,
        on_select = function(value)
            buy(value)
            -- keep the picker up: reopen right after this one closes
            rune.timer.after(0.05, function() open_picker() end,
                { name = "shopListPicker-reopen" })
        end,
    })
    if not ok then
        rune.echo("[shopListPicker] Picker failed: " .. tostring(err))
    end
end

-- Shop row: "  N) <item>   <level>   <amount|No limit>   [ <cost> gold]".
-- Thesis rows are filtered out inside the callback (portable: no regex lookahead needed).
rune.trigger.regex(
    "^\\s*(\\d+)\\)\\s+(.+?)\\s+(\\d+)\\s+(No limit|\\d+)\\s+\\[\\s*([\\d,]+)\\s+gold\\s*\\]",
    function(m)
        if not enabled() then return end
        local num, name, level, amount, cost = m[1], m[2], m[3], m[4], m[5]
        if name:sub(1, #THESIS) == THESIS then
            dbg("skipped thesis row " .. num)
            return
        end
        if finished then            -- first row of a new list: start fresh
            items = {}
            finished = false
        end
        items[#items + 1] = {
            text  = name,
            desc  = string.format("#%s  %s gold  (lvl %s, %s)", num, cost, level, amount),
            value = num,
        }
        rune.timer.after(DEBOUNCE, function()
            finished = true
            if enabled() then open_picker() end
        end, { name = "shopListPicker-open" })  -- same name replaces the pending timer = debounce
    end,
    { name = "shopListPicker-row" }
)

-- Help (same helpstyle layout as autopouch.lua) ------------------------------

local function help()
    rune.echo(H.title("shopListPicker - pick shop items to buy"))
    rune.echo(H.section("Trigger:"))
    rune.echo(H.line("shopListPicker on | off", "enable or disable the trigger (default on)"))
    rune.echo(H.section("Picker:"))
    rune.echo(H.line("shopListPicker open", "reopen the picker with the last shop list"))
    rune.echo(H.section("Debug:"))
    rune.echo(H.line("shopListPicker debug on | off", "toggle debug messages (default off)"))
    rune.echo("")
    rune.echo(H.foot(status()))
end

-- Aliases (typed bare, no leading slash) -------------------------------------

rune.alias.regex("^shopListPicker$", help, { name = "shopListPicker-help" })

rune.alias.regex("^shopListPicker +(on|off|open)$", function(m)
    local cmd = m[1]
    if cmd == "on" then
        rune.store.set("shopListPicker.enabled", true)
        rune.echo("[shopListPicker] trigger on")
    elseif cmd == "off" then
        rune.store.set("shopListPicker.enabled", false)
        finished = true
        rune.echo("[shopListPicker] trigger off")
    else
        open_picker()
    end
end, { name = "shopListPicker-sub" })

rune.alias.regex("^shopListPicker +debug(?: +(on|off))?$", function(m)
    local v = m[1]
    if v == "on" then
        rune.store.set("shopListPicker.debug", true)
        rune.echo("[shopListPicker] debug on")
    elseif v == "off" then
        rune.store.set("shopListPicker.debug", false)
        rune.echo("[shopListPicker] debug off")
    else
        rune.echo("[shopListPicker] debug is " .. (debug_on() and "on" or "off"))
    end
end, { name = "shopListPicker-debug" })