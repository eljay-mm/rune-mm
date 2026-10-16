-- Filename: eljayPlugins/shopListPicker.lua
-- Purpose: Turns a shop's item list into a searchable picker that stays open for repeat purchases (thesis shops excluded).
-- Version: 1.6
-- Date: 2026-Oct-16
--
-- Changelog:
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
--   * A trigger watches for shop rows in a shop's list output, e.g.
--       "     4) A vial of exploding oil                      5     250          [        656 gold]"
--     and collects number, item name, level, amount and cost. Amount is a number or "No limit".
--   * Rows whose item name starts with "A thesis pertaining to" are skipped, so the research list (rrl) still belongs
--     to researchNotesPicker and never opens this picker.
--   * A shop list has no end-of-list marker, so a short debounce timer (0.4s after the last row) decides the list is
--     complete and opens the picker.
--   * Each selection (Enter/Tab) sends "shop buy <number>" and the picker reopens for the next purchase. Esc closes
--     the picker for good (nothing else to clean up, no notes involved).
--   * Typing in the picker fuzzy-filters on item name, number or cost.
--   * Only the digits captured by the trigger are ever sent to the server (no free text), and at most 200 rows are kept.
--   * Settings persist across restarts in rune.store ("shopListPicker.enabled" and "shopListPicker.debug"); a missing
--     value means trigger on, debug off. They are read once at load and written when changed.
--   * Turning the trigger off also cancels a picker that is waiting to open. Nothing is gagged: the normal shop list
--     output still shows in the main window.
--   * Typing the command alone shows the command summary, with the version and the current settings in the footer.
--   * Inspired by researchNotesPicker.lua (same picker flow, opposite trigger).
--
-- Commands (typed bare, no leading slash; slp is the short alias for shopListPicker):
--   shopListPicker                show the command summary
--   shopListPicker on|off         enable or disable the trigger (default on)
--   shopListPicker open           reopen the picker with the last captured shop list
--   shopListPicker debug on|off   toggle debug messages (default off); `debug` alone shows the state

local VERSION = "1.6"   -- keep in sync with the Version line in the header

local H = require("helpstyle")

local DEBOUNCE  = 0.4       -- seconds of silence after the last row before the picker opens
local THESIS    = "A thesis pertaining to"
local MAX_ITEMS = 200       -- safety cap on collected rows

--  Output helpers
local function paint(color, text)
  local fn = rune.style and rune.style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out then return out end
  end
  return text
end

local function say(msg)
  rune.echo(paint("cyan", "[shopListPicker] ") .. msg)
end

--  Settings (persisted in rune.store, cached in memory)
local cfg = {
  enabled = rune.store.get("shopListPicker.enabled") ~= false,   -- default on
  debug   = rune.store.get("shopListPicker.debug") == true,      -- default off
}

local function dbg(msg)
  if cfg.debug then
    rune.echo(paint("blue", "[shopListPicker:debug] ") .. msg)
  end
end

--  State
local items       = {}      -- collected rows for the current shop list
local finished    = true    -- true once the picker has opened for the current list
local open_timer  = nil     -- pending debounce timer
local reopen_timer = nil    -- pending reopen timer

local function cancel_timer(t)
  if t then pcall(function() t:remove() end) end
end

local function status()
  return string.format("v%s  trigger=%s  debug=%s  items=%d",
    VERSION, cfg.enabled and "on" or "off", cfg.debug and "on" or "off", #items)
end

--  Picker
local open_picker

-- Single purchase by item number (digits only, captured by the trigger).
local function buy(num)
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
      -- keep the picker up: reopen right after this one closes
      cancel_timer(reopen_timer)
      reopen_timer = rune.timer.after(0.05, function() open_picker() end,
        { name = "shopListPicker-reopen" })
    end,
  })
  if not ok then
    say("Picker failed: " .. tostring(err))
  end
end

--  Trigger
-- Shop row: "  N) <item>   <level>   <amount|No limit>   [ <cost> gold]".
-- Thesis rows are filtered out inside the callback (portable: no regex lookahead needed).
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
        text  = name,
        desc  = string.format("#%s  %s gold  (lvl %s, %s)", num, cost, level, amount),
        value = num,
      }
    end
    cancel_timer(open_timer)
    open_timer = rune.timer.after(DEBOUNCE, function()
      finished = true
      if cfg.enabled then open_picker() end
    end, { name = "shopListPicker-open" })
  end,
  { name = "shopListPicker-row" }
)

--  Help
local function showHelp()
  rune.echo(H.title("shopListPicker - pick shop items to buy"))
  rune.echo(H.section("Trigger:"))
  rune.echo(H.line("shopListPicker on | off", "enable or disable the trigger (default on)"))
  rune.echo(H.section("Picker:"))
  rune.echo(H.line("shopListPicker open", "reopen the picker with the last shop list"))
  rune.echo(H.section("Debug:"))
  rune.echo(H.line("shopListPicker debug on | off", "toggle debug messages (default off)"))
  rune.echo(H.section("Short alias:"))
  rune.echo(H.line("slp", "same as shopListPicker (e.g. slp open)"))
  rune.echo("")
  rune.echo(H.foot(status()))
end

--  Commands
local function setEnabled(on)
  cfg.enabled = on
  rune.store.set("shopListPicker.enabled", on)
  if not on then
    finished = true
    cancel_timer(open_timer)
    cancel_timer(reopen_timer)
  end
  say("Trigger " .. (on and "on" or "off"))
end

local function setDebug(arg)
  arg = (arg or ""):lower()
  if arg == "on" or arg == "off" then
    cfg.debug = (arg == "on")
    rune.store.set("shopListPicker.debug", cfg.debug)
    say("Debug messages " .. arg)
  else
    say("Debug messages are " .. (cfg.debug and "on" or "off") .. " (shopListPicker debug on|off)")
  end
end

local commands = {
  [""]    = showHelp,
  help    = showHelp,
  on      = function() setEnabled(true) end,
  off     = function() setEnabled(false) end,
  open    = function() open_picker() end,
  debug   = setDebug,
}

-- One row for both names: shopListPicker and slp.
rune.alias.regex("^(?:shopListPicker|slp)(?:\\s+(\\S+))?(?:\\s+(.*))?$", function(m, ctx)
  m = m or (ctx and ctx.matches) or {}
  local sub  = (m[1] or ""):lower()
  local rest = m[2] or ""
  local fn = commands[sub]
  if fn then
    fn(rest)
  else
    say("Unknown command '" .. sub .. "'.")
    showHelp()
  end
end, { name = "shopListPicker-cmd" })

say("v" .. VERSION .. " loaded (shopListPicker or slp for help)")