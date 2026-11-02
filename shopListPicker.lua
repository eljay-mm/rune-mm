-- Filename: eljayPlugins/shopListPicker.lua
-- Purpose: Turns a shop's item list into a searchable picker with identify and buy actions, for repeat purchases (thesis shops excluded).
-- Version: 1.12
-- Date: 2026-Nov-01
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.12 Menu label and wording say Identify instead of Info.
--   1.11 The identify command is now "shop identify <n>" everywhere; id is the default mode.
--   1.10 Added a persistent mode: menu (action menu), buy (direct "shop buy <n>") or id (direct "shop identify <n>").
--   1.9  Selecting an item opens an action menu: "shop identify <n>" first (default), then "shop buy <n>", then Back.
--   1.0-1.8  New plugin (based on researchNotesPicker.lua v1.7, opposite trigger), persistent on/off and debug,
--        slp short alias, item cap, repository baseline, other-currency shops, one regex alias row.
--
-- How it works:
--   * Watches shop-list rows and collects the item number, name, level, amount and cost (gold or any other
--     currency), then opens a picker after 0.4 seconds of silence.
--   * Skips rows whose item name starts with "A thesis pertaining to", leaving research lists to researchNotesPicker.
--   * The mode decides what selecting an item does (default id, saved in rune.store):
--       menu  opens a small action menu: Identify ("shop identify <number>", default), Buy ("shop buy <number>"), Back.
--             Identify keeps the menu open so you can buy right after reading; Buy and Back return to the list.
--       buy   sends "shop buy <number>" at once and returns to the list.
--       id    sends "shop identify <number>" at once and returns to the list.
--     Esc finishes in every mode.
--   * Typing in the picker fuzzy-filters by item name, number or cost. At most 200 rows are kept.
--   * Only digits captured from a shop row are sent to the server. Shop output is not gagged.
--   * Trigger, debug and mode settings persist in rune.store; defaults are trigger on, debug off, mode id.
--   * Inspired by researchNotesPicker.lua (same picker flow, opposite trigger).
--
-- Commands (type without "/"; "slp" is a short alias for "shopListPicker"):
--   Commands
--     shopListPicker        show this help
--     slp on|off            enable / disable the trigger
--     slp open              reopen the picker with the last shop list
--     slp mode menu|buy|id  what selecting an item does (menu, direct buy, direct identify)
--     slp debug on|off      enable / disable debug messages
--     slp                   short alias for shopListPicker
--
-- Tweaks (top of file):
--   * DEBOUNCE   seconds of silence after the last shop row before opening the picker
--   * MAX_ITEMS  maximum number of captured rows
--   * ACTIONS    action menu entries in order (label, server command, again = stay on the menu afterwards)

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "shopListPicker"
local SHORT = "slp"

local VERSION = "1.12" -- Keep in sync with the Version line in the header.

local DEBOUNCE = 0.4
local THESIS = "A thesis pertaining to"
local MAX_ITEMS = 200

-- Action menu: the first entry is the default. The item number is appended to cmd.
local ACTIONS = {
  { label = "Identify", cmd = "shop identify", again = true, mode = "id" },
  { label = "Buy", cmd = "shop buy", again = false, mode = "buy" },
}

-- Modes: what selecting an item does, and the hint shown in the picker title.
local MODES = {
  menu = "Enter for actions",
  buy = "Enter to buy",
  id = "Enter to identify",
}

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

-- Settings: read from rune.store on first use, cached, saved when changed.
local cfg
local function settings()
  if not cfg then
    cfg = {
      enabled = rune.store.get(NAME .. ".enabled") ~= false,
      debug = rune.store.get(NAME .. ".debug") == true,
      mode = rune.store.get(NAME .. ".mode"),
    }
    if not MODES[cfg.mode] then cfg.mode = "id" end
  end
  return cfg
end

local function dbg(msg)
  if settings().debug then
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

-- Pickers.
local open_picker, open_actions

-- Reopen a picker right after the current one closes (only while the trigger is on).
local function later(fn)
  cancel_timer(reopen_timer)
  reopen_timer = rune.timer.after(0.05, function()
    if settings().enabled then fn() end
  end, { name = NAME .. "-reopen" })
end

local function item_name(num)
  for _, it in ipairs(items) do
    if it.value == num then return it.text end
  end
  return "#" .. num
end

local function run(cmd, num)
  if not tostring(num):match("^%d+$") then return end
  dbg(cmd .. " " .. num)
  rune.send(cmd .. " " .. num)
end

-- Action menu for one item: Identify (default), Buy, Back.
open_actions = function(num)
  local menu = {}
  for i, a in ipairs(ACTIONS) do
    menu[i] = { text = a.label, desc = a.cmd .. " " .. num, value = tostring(i) }
  end
  menu[#menu + 1] = { text = "Back", desc = "return to the item list", value = "back" }

  local ok, err = pcall(rune.ui.picker.show, {
    title = item_name(num) .. " - Enter to run, Esc to finish",
    items = menu,
    on_select = function(value)
      local a = ACTIONS[tonumber(value) or 0]
      if not a then
        later(open_picker)
        return
      end
      run(a.cmd, num)
      if a.again then
        later(function() open_actions(num) end)
      else
        later(open_picker)
      end
    end,
  })

  if not ok then say("Picker failed: " .. tostring(err)) end
end

open_picker = function()
  if #items == 0 then
    say("No shop items captured yet - run the shop's list first.")
    return
  end

  dbg("opening picker with " .. #items .. " items")
  local ok, err = pcall(rune.ui.picker.show, {
    title = "Shop (" .. settings().mode .. ") - " .. MODES[settings().mode] .. ", Esc to finish",
    items = items,
    match_description = true,
    on_select = function(value)
      local mode = settings().mode
      if mode == "menu" then
        later(function() open_actions(value) end)
        return
      end
      for _, a in ipairs(ACTIONS) do
        if a.mode == mode then run(a.cmd, value) end
      end
      later(open_picker)
    end,
  })

  if not ok then say("Picker failed: " .. tostring(err)) end
end

-- Capture shop rows: "  N) <item>  <level>  <amount|No limit>  [ <cost> <currency>]".
-- The currency is gold in most shops ("[ 656 gold]") or another token ("[ 1 Divusmors-essence]").
-- Thesis rows are filtered in the callback.
rune.trigger.regex(
  "^\\s*(\\d+)\\)\\s+(.+?)\\s+(\\d+)\\s+(No limit|\\d+)\\s+\\[\\s*([\\d,]+)\\s+([^\\]]+?)\\s*\\]",
  function(m)
    if not settings().enabled then return end

    local num, name, level, amount, cost, currency = m[1], m[2], m[3], m[4], m[5], m[6]
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
        desc = string.format("#%s  %s %s  (lvl %s, %s)", num, cost, currency, level, amount),
        value = num,
      }
    end

    cancel_timer(open_timer)
    open_timer = rune.timer.after(DEBOUNCE, function()
      finished = true
      if settings().enabled then open_picker() end
    end, { name = NAME .. "-open" })
  end,
  { name = NAME .. "-row" }
)

-- Help (helpstyle loaded on first use).
local function show_help()
  local c = settings()
  local H = require("helpstyle")
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable the trigger"))
  rune.echo(H.line(SHORT .. " open", "reopen the picker with the last shop list"))
  rune.echo(H.line(SHORT .. " mode menu|buy|id", "menu, direct buy or direct identify"))
  rune.echo(H.line(SHORT .. " debug on|off", "enable / disable debug messages"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(string.format("v%s  enabled=%s mode=%s debug=%s  items=%d  load=%dms",
    VERSION, tostring(c.enabled), c.mode, tostring(c.debug), #items, LOAD_MS)))
end

local function set_enabled(on)
  settings().enabled = on
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
  local c = settings()
  arg = (arg or ""):lower()
  if arg == "on" or arg == "off" then
    c.debug = arg == "on"
    rune.store.set(NAME .. ".debug", c.debug)
    say("Debug messages " .. arg)
  else
    say("Debug messages are " .. (c.debug and "on" or "off")
      .. " (" .. SHORT .. " debug on|off)")
  end
end

local function set_mode(arg)
  local c = settings()
  arg = (arg or ""):lower()
  if MODES[arg] then
    c.mode = arg
    rune.store.set(NAME .. ".mode", arg)
    say("Mode " .. arg)
  else
    say("Mode is " .. c.mode .. " (" .. SHORT .. " mode menu|buy|id)")
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
  elseif sub == "mode" then
    set_mode(rest)
  elseif sub == "debug" then
    set_debug(rest)
  else
    say("Unknown command '" .. sub .. "'.")
    show_help()
  end
end

-- One regex alias row serves both names (bare commands, no "/" prefix).
rune.alias.regex("^(?:" .. NAME .. "|" .. SHORT .. ")(?:\\s+(.*))?$", function(m, ctx)
  m = m or (ctx and ctx.matches) or {}
  handle_command(m[1])
end, { name = NAME .. "-cmd" })

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))