-- Filename: eljayPlugins/researchNotesPicker.lua
-- Purpose: Turns the output of the research list into a searchable picker that stays open for repeat thesis purchases, handling the notes around the session.
-- Version: 1.9
-- Date: 2026-Oct-16
-- Changelog:
--   1.9  Brought to standard: researchNotesPicker command with rnp short alias, bare help,
--        trigger on/off toggle, debug toggle, loader line and version footer.
--   1.8  Repo-style header update and command summary cleanup; functionality preserved.
--   1.7  Original implementation.
--
-- How it works:
--   * A trigger watches for thesis rows in the research list output, e.g.
--       "     1) A thesis pertaining to Armor      75    No limit     [        253 gold]"
--     and collects number, subject, level, amount and cost. The row must contain
--     "A thesis pertaining to", so ordinary shop lists never open the picker.
--   * The list has no end-of-list marker, so a short debounce timer (0.4s after the last
--     row) decides the list is complete and opens the picker.
--   * When the picker opens, "rem notes" is sent (inventory must be free of held notes).
--   * Each selection (Enter/Tab) sends "read research buy <n>;bind thesis notes" while the
--     notes are still in inventory, then the picker reopens for the next purchase
--     (no extra "rem notes" on reopen).
--   * Esc cannot be trapped: Rune's modal picker handles all keys itself (no Lua binds run)
--     and has no cancel callback. Instead, while a session is active, an input hook sends
--     "hold notes" just before the next line you type or send (the picker is necessarily
--     closed by then). So after Esc your notes come back with your very next command, with
--     no purchase required. "done" sends "hold notes" immediately by hand.
--   * Typing in the picker fuzzy-filters on subject name, number or cost.
--   * "pick" reopens the picker with the last list without asking the server again.
--   * The rrl and rrr aliases are NOT defined here; they come from an external definition.
--   * Nothing is gagged: the normal research list output still shows in the main window.
--
-- Commands (typed bare, no / prefix; rnp is the short alias for researchNotesPicker):
--   researchNotesPicker            show this help
--   researchNotesPicker on|off     enable or disable the thesis list trigger
--   researchNotesPicker debug on|off   toggle debug messages (default off)
--   researchNotesPicker pick       reopen the last research picker (alias: rrpick)
--   researchNotesPicker done       put the notes back immediately (alias: rrdone)

local NAME     = "researchNotesPicker"
local VERSION  = "1.9"
local DEBOUNCE = 0.4    -- seconds of silence after the last row before the picker opens

local enabled   = true   -- thesis list trigger on/off
local DEBUG     = false  -- debug messages, default off

local items     = {}     -- collected rows for the current research list run
local finished  = true   -- true once the picker has opened for the current run
local active    = false  -- true while a picker session is in progress (notes removed)
local reopening = false  -- true during the short gap between a selection and the picker reopening

local open_picker

-- Display helpers (cyan "[name] " prefix, help rows via helpstyle) -----------------------
local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
  H = {
    title   = function(t) return t end,
    section = function(t) return t end,
    line    = function(a, b) return "  " .. a .. "  " .. (b or "") end,
    foot    = function(t) return t end,
  }
end

local function paint(text)
  local ok, styled = pcall(rune.style.cyan, text)
  if ok and styled then return styled end
  return text
end

local function say(msg) rune.echo(paint("[" .. NAME .. "] ") .. msg) end
local function emit(row) rune.echo(row) end
local function dbg(msg) if DEBUG then say("debug: " .. msg) end end
local function onoff(v) return v and "on" or "off" end

local function show_help()
  emit(H.title(NAME .. " (rnp)"))
  emit(H.section("Commands"))
  emit(H.line(NAME .. " | rnp", "show this help"))
  emit(H.line("rnp on|off", "enable or disable the thesis list trigger"))
  emit(H.line("rnp debug on|off", "toggle debug messages"))
  emit(H.line("rnp pick", "reopen the last research picker (rrpick)"))
  emit(H.line("rnp done", "put the notes back now (rrdone)"))
  emit(H.foot(string.format("v%s  trigger=%s debug=%s", VERSION, onoff(enabled), onoff(DEBUG))))
end

-- Session logic ----------------------------------------------------------------------------
-- Single purchase: buy, then bind the thesis to the notes (notes must be in inventory).
local function buy(num)
  if not tostring(num):match("^%d+$") then  -- hardening: only ever send a plain number
    dbg("refused non-numeric selection: " .. tostring(num))
    return
  end
  dbg("buy " .. num)
  rune.send("read research buy " .. num .. ";bind thesis notes")
end

-- Session end: pick the notes back up.
local function finish()
  if not active then return end
  active = false
  dbg("session end, hold notes")
  rune.send("hold notes")
end

-- fresh = true for a new session (sends "rem notes"); false when reopening after a buy.
open_picker = function(fresh)
  if #items == 0 then
    say("No theses captured yet - run rrl first.")
    return
  end
  reopening = false
  if fresh then
    active = true
    dbg("session start, rem notes (" .. #items .. " theses)")
    rune.send("rem notes")
  end
  local ok, err = pcall(rune.ui.picker.show, {
    title = "Research (read research buy) - Esc to finish",
    items = items,
    match_description = true,
    on_select = function(value)
      reopening = true
      buy(value)
      -- keep the picker up: reopen right after this one closes
      rune.timer.after(0.05, function() open_picker(false) end,
        { name = NAME .. "-reopen" })
    end,
  })
  if not ok then
    say("Picker failed: " .. tostring(err))
    finish()
  end
end

-- "A thesis pertaining to" is mandatory so regular shop listings are ignored.
rune.trigger.regex(
  "^\\s*(\\d+)\\)\\s+A thesis pertaining to\\s+(.+?)\\s+(\\d+)\\s+(.+?)\\s+\\[\\s*([\\d,]+)\\s+gold\\s*\\]",
  function(m)
    if not enabled then return end
    if finished then
      items = {}
      finished = false
    end
    local num, subject, level, amount, cost = m[1], m[2], m[3], m[4], m[5]
    items[#items + 1] = {
      text  = subject,
      desc  = string.format("#%s  %s gold  (lvl %s, %s)", num, cost, level, amount),
      value = num,
    }
    rune.timer.after(DEBOUNCE, function()
      finished = true
      open_picker(true)
    end, { name = NAME .. "-open" })
  end,
  { name = NAME .. "-row" }
)

-- Esc safety net: input can only be submitted once the picker is closed, so if a session
-- is still marked active here, the picker was cancelled. Re-equip the notes first.
rune.hooks.on("input", function(text)
  if active and not reopening then finish() end
  return nil
end, { name = NAME .. "-esc", priority = 10 })

-- Commands (no / prefix) -----------------------------------------------------------------
local function set_trigger(on)
  enabled = on
  if not on then finish() end
  say("trigger " .. onoff(on))
end

local function run(sub, rest)
  sub  = (sub or ""):lower()
  rest = (rest or ""):lower()
  if sub == "" or sub == "help" then show_help()
  elseif sub == "on"   then set_trigger(true)
  elseif sub == "off"  then set_trigger(false)
  elseif sub == "debug" then
    if rest == "on" then DEBUG = true elseif rest == "off" then DEBUG = false end
    say("debug " .. onoff(DEBUG))
  elseif sub == "pick" then open_picker(true)
  elseif sub == "done" then finish()
  else show_help() end
end

rune.alias.exact(NAME, function(args, ctx) show_help() end)
rune.alias.exact("rnp", function(args, ctx) show_help() end)
rune.alias.regex("^(?:" .. NAME .. "|rnp)\\s+(\\S+)(?:\\s+(.*))?$", function(m) run(m[1], m[2]) end)
rune.alias.exact("rrpick", function(args, ctx) open_picker(true) end)
rune.alias.exact("rrdone", function(args, ctx) finish() end)

say(string.format("v%s loaded (%s or rnp for help)", VERSION, NAME))