-- Filename: eljayPlugins/researchNotesPicker.lua
-- Purpose: Turns the output of the research list into a searchable picker that stays open for repeat thesis purchases, handling the notes around the session.
-- Version: 1.10
-- Date: 2026-Oct-16
-- Changelog:
--   1.10 Persisted settings, fixed debounce races, and made pick safe during an active session.
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
--   * A debounce timer opens the picker 0.4 seconds after the last captured row.
--   * When a new picker session opens, "rem notes" is sent (inventory must be free of held notes).
--   * Each selection (Enter/Tab) sends "read research buy <n>;bind thesis notes" while the
--     notes are still in inventory, then reopens the picker for the next purchase.
--   * Esc cannot be trapped: Rune's modal picker handles all keys itself and has no cancel
--     callback. While a session is active, an input hook sends "hold notes" before the next
--     line you type or send. "done" sends "hold notes" immediately.
--   * Typing in the picker fuzzy-filters on subject name, number or cost.
--   * "pick" reopens the picker with the last list without asking the server again.
--   * The rrl and rrr aliases are NOT defined here; they come from an external definition.
--   * Nothing is gagged: the normal research list output still shows in the main window.
--
-- Commands (typed bare, no / prefix; rnp is the short alias for researchNotesPicker):
--   researchNotesPicker                 show this help
--   researchNotesPicker on|off          enable or disable the thesis list trigger
--   researchNotesPicker debug on|off    enable or disable debug messages (default off)
--   researchNotesPicker pick            reopen the last research picker (alias: rrpick)
--   researchNotesPicker done            put the notes back (alias: rrdone)
--
-- Tweaks (top of file):
--   * DEBOUNCE   seconds of silence after the last row before the picker opens

local NAME     = "researchNotesPicker"
local VERSION  = "1.10"
local DEBOUNCE = 0.4 -- seconds of silence after the last row before the picker opens

local STORE_ENABLED = NAME .. ".enabled"
local STORE_DEBUG   = NAME .. ".debug"

local function stored_bool(key, default)
  local ok, value = pcall(rune.store.get, key)
  if ok and type(value) == "boolean" then return value end
  return default
end

local enabled = stored_bool(STORE_ENABLED, true)
local DEBUG   = stored_bool(STORE_DEBUG, false)

local items          = {}
local finished       = true
local active         = false
local reopening      = false
local debounce_token = 0

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
  emit(H.line("rnp debug on|off", "enable or disable debug messages"))
  emit(H.line("rnp pick | rrpick", "reopen the last research picker"))
  emit(H.line("rnp done | rrdone", "put the notes back now"))
  emit(H.foot(string.format("v%s  trigger=%s debug=%s", VERSION, onoff(enabled), onoff(DEBUG))))
end

-- Session logic ----------------------------------------------------------------------------
-- Single purchase: buy, then bind the thesis to the notes (notes must be in inventory).
local function buy(num)
  if not tostring(num):match("^%d+$") then
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
  reopening = false
  dbg("session end, hold notes")
  rune.send("hold notes")
end

-- fresh = true starts a session only if one is not already active.
open_picker = function(fresh)
  if #items == 0 then
    say("No theses captured yet - run rrl first.")
    return
  end

  if fresh and not active then
    active = true
    dbg("session start, rem notes (" .. #items .. " theses)")
    rune.send("rem notes")
  end

  reopening = false
  local ok, err = pcall(rune.ui.picker.show, {
    title = "Research (read research buy) - Esc to finish",
    items = items,
    match_description = true,
    on_select = function(value)
      reopening = true
      buy(value)
      rune.timer.after(0.05, function()
        if active then open_picker(false) end
      end, { name = NAME .. "-reopen" })
    end,
  })

  if not ok then
    say("Picker failed: " .. tostring(err))
    finish()
  end
end

-- "A thesis pertaining to" is mandatory so regular shop listings are ignored.
rune.trigger.regex(
  "^\\s*(\\d+)\\)\\s+A thesis pertaining to\\s+(.+?)\\s+(\\d+)\\s+(.+?)\\s+\\[\\s*([\\d,]+)\\s+gold\\s*]",
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

    -- Only the callback for the newest row is allowed to open the picker.
    debounce_token = debounce_token + 1
    local token = debounce_token
    rune.timer.after(DEBOUNCE, function()
      if token ~= debounce_token then return end
      finished = true
      open_picker(true)
    end, { name = NAME .. "-open" })
  end,
  { name = NAME .. "-row" }
)

-- Esc safety net: if the picker was cancelled, the next submitted input returns the notes.
rune.hooks.on("input", function(text)
  if active and not reopening then finish() end
  return nil
end, { name = NAME .. "-esc", priority = 10 })

-- Commands (no / prefix) -----------------------------------------------------------------
local function set_trigger(on)
  enabled = on
  pcall(rune.store.set, STORE_ENABLED, enabled)
  if not on then finish() end
  say("trigger " .. onoff(on))
end

local function run(sub, rest)
  sub  = (sub or ""):lower()
  rest = (rest or ""):lower()

  if sub == "" or sub == "help" then
    show_help()
  elseif sub == "on" then
    set_trigger(true)
  elseif sub == "off" then
    set_trigger(false)
  elseif sub == "debug" then
    if rest == "on" then
      DEBUG = true
    elseif rest == "off" then
      DEBUG = false
    end
    pcall(rune.store.set, STORE_DEBUG, DEBUG)
    say("debug " .. onoff(DEBUG))
  elseif sub == "pick" then
    open_picker(true)
  elseif sub == "done" then
    finish()
  else
    show_help()
  end
end

rune.alias.exact(NAME, function(args, ctx) show_help() end)
rune.alias.exact("rnp", function(args, ctx) show_help() end)
rune.alias.regex("^(?:" .. NAME .. "|rnp)\\s+(\\S+)(?:\\s+(.*))?$", function(m)
  run(m[1], m[2])
end)
rune.alias.exact("rrpick", function(args, ctx) open_picker(true) end)
rune.alias.exact("rrdone", function(args, ctx) finish() end)

say(string.format("v%s loaded (%s or rnp for help)", VERSION, NAME))
