-- Filename: eljayPlugins/shopListPicker.lua
-- Purpose: Turns a shop's item list into a searchable picker that stays open for repeat purchases (thesis shops excluded).
-- Version: 1.7
-- Date: 2026-Oct-20
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.7  Brought to repository baseline: standard header and TODO block, NAME/SHORT constants, exact bare-command
--        aliases, helpstyle layout, persistent toggles, and measured load time in the help footer.
--   1.6  Brought to standard: full command shopListPicker with slp as the short alias (one regex alias row), cyan
--        [shopListPicker] prefix and one-row loader line, settings cached in memory (rune.store read once at load,
--        written on change), turning the trigger off also cancels the pending picker timers, item cap, unknown
--        commands show the help, plain -- comments only.
--   1.5  Repo-style header and command summary cleanup; behavior preserved.
--   1.4  Help footer is one row like jmcSolver: version first, then the key=value status.
--   1.3  Settings (trigger on/off, debug on/off) persist via rune.store; help uses helpstyle as autopouch.lua does.
--   1.2  Added on/off toggle for the trigger, default on.
--   1.1  Command renamed from shoppick to shopListPicker (same as the plugin name).
--   1.0  New. Based on researchNotesPicker.lua v1.7 with the opposite trigger (thesis rows are ignored, all other
--        shop rows are collected) and no notes handling.
--
-- How it works:
--   * Watches shop-list rows and collects the item number, name, level, amount and cost, then opens a picker after
--     0.4 seconds of silence.
--   * Skips rows whose item name starts with "A thesis pertaining to", leaving research lists to researchNotesPicker.
--   * Selecting an item sends "shop buy <number>" and reopens the picker for repeat purchases; Esc finishes.
--   * Typing in the picker fuzzy-filters by item name, number or cost. At most 200 rows are kept.
--   * Only digits captured from a shop row are sent to the server. Shop output is not gagged.
--   * Trigger and debug settings persist in rune.store; trigger defaults on and debug defaults off.
--   * Inspired by researchNotesPicker.lua (same picker flow, opposite trigger).
--
-- Commands (type without "/"; "slp" is a short alias for "shopListPicker"):
--   shopListPicker                show this help
--   shopListPicker on|off         enable / disable the trigger
--   shopListPicker open           reopen the picker with the last captured shop list
--   shopListPicker debug on|off   enable / disable debug messages
--   slp                           short alias for shopListPicker
--
-- Tweaks (top of file):
--   * DEBOUNCE   seconds of silence after the last shop row before opening the picker
--   * MAX_ITEMS  maximum number of captured rows

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "shopListPicker"
local SHORT = "slp"

local VERSION = "1.7" -- Keep in sync with the Version line in the header.

local H = require("helpstyle")

local DEBOUNCE = 0.4
local THESIS = "A thesis pertaining to"
local MAX_ITEMS = 200

-- Output helpers.
local function paint(color, text)
  local style = rune.style
  local fn = style and style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out then return out end
  end
  return text
end

local function say(msg)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. msg)
end

-- Settings are cached in memory and persisted when changed.
local cfg = {
  enabled = rune.store.get(NAME .. ".enabled") ~= false,
  debug = rune.store.get(NAME .. ".debug") == true,
}

local function dbg(msg)
  if cfg.debug then
    rune.echo(paint("blue", "[" .. NAME .. ":debug] ") .. msg)
  end
end

-- State.
local items = {}
local finished = true
local open_timer
local reopen_timer
local LOAD_MS = 0

local function cancel_timer(timer)
  if timer then pcall(function() timer:remove() end) end
end

local function status()
  return string.format("v%s  enabled=%s debug=%s  items=%d  load=%dms",
    VERSION, tostring(cfg.enabled), tostring(cfg.debug), #items, LOAD_MS)
end

-- Picker.
local open_picker

local function buy(num)
  if not tostring(num):match("^%d+$") then return end
  dbg("shop buy " .. num)
  rune.send("shop buy " .. num)
end

open_picker = function()
  if #items == 0 then
    say("No shop items captured yet - run the shop's list first.")
    return
  end

  dbg("opening picker with " .. #items .. " items")
  local ok, err = pcall(rune.ui.picker.show, {
    title = "Shop (shop buy) - Esc to finish",
    items = items,
    match_description = true,
    on_select = function(value)
      buy(value)
      cancel_timer(reopen_timer)
      reopen_timer = rune.timer.after(0.05, function()
        if cfg.enabled then open_picker() end
      end, { name = NAME .. "-reopen" })
    end,
  })

  if not ok then say("Picker failed: " .. tostring(err)) end
end

-- Capture shop rows. Thesis rows are filtered in the callback.
rune.trigger.regex(
  "^\\s*(\\d+)\\)\\s+(.+?)\\s+(\\d+)\\s+(No limit|\\d+)\\s+\\[\\s*([\\d,]+)\\s+gold\\s*\\]",
  function(m)
    if not cfg.enabled then return end

    local num, name, level, amount, cost = m[1], m[2], m[3], m[4], m[5]
    if name:sub(1, #THESIS) == THESIS then
      dbg("skipped thesis row " .. num)
      return
    end

    if finished then
      items = {}
      finished = false
    end

    if #items < MAX_ITEMS then
      items[#items + 1] = {
        text = name,
        desc = string.format("#%s  %s gold  (lvl %s, %s)", num, cost, level, amount),
        value = num,
      }
    end

    cancel_timer(open_timer)
    open_timer = rune.timer.after(DEBOUNCE, function()
      finished = true
      if cfg.enabled then open_picker() end
    end, { name = NAME .. "-open" })
  end,
  { name = NAME .. "-row" }
)

local function show_help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(NAME .. " on|off", "enable / disable the trigger"))
  rune.echo(H.line(NAME .. " open", "reopen the picker with the last shop list"))
  rune.echo(H.line(NAME .. " debug on|off", "enable / disable debug messages"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(status()))
end

local function set_enabled(on)
  cfg.enabled = on
  rune.store.set(NAME .. ".enabled", on)
  if not on then
    finished = true
    cancel_timer(open_timer)
    cancel_timer(reopen_timer)
    open_timer = nil
    reopen_timer = nil
  end
  say("Trigger " .. (on and "on" or "off"))
end

local function set_debug(arg)
  arg = (arg or ""):lower()
  if arg == "on" or arg == "off" then
    cfg.debug = arg == "on"
    rune.store.set(NAME .. ".debug", cfg.debug)
    say("Debug messages " .. arg)
  else
    say("Debug messages are " .. (cfg.debug and "on" or "off")
      .. " (" .. NAME .. " debug on|off)")
  end
end

local function handle_command(args)
  args = (args or ""):match("^%s*(.-)%s*$")
  local sub, rest = args:match("^(%S+)%s*(.*)$")
  sub = (sub or ""):lower()

  if sub == "" or sub == "help" then
    show_help()
  elseif sub == "on" then
    set_enabled(true)
  elseif sub == "off" then
    set_enabled(false)
  elseif sub == "open" then
    open_picker()
  elseif sub == "debug" then
    set_debug(rest)
  else
    say("Unknown command '" .. sub .. "'.")
    show_help()
  end
end

-- Bare commands are aliases, not slash commands. The alias name is derived
-- from the first argument; rune.alias.exact does not take a name-options table.
rune.alias.exact(NAME, function(args)
  handle_command(args)
end)

rune.alias.exact(SHORT, function(args)
  handle_command(args)
end)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
