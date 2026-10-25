-- Filename: eljayPlugins/researchNotesPicker.lua
-- Purpose: Turns research-list output into a searchable picker for repeat thesis purchases and handles the notes around the session.
-- Version: 1.14
-- Date: 2026-Oct-24
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.14 Added standalone rrl and rrr aliases; no longer depends on
--        basicAliases for research-list and research-buy commands.
--   1.13 Standardized help and command handling; clarified trigger and debug toggles.
--   1.12 Measure load time once after initialization and show the fixed value in help.
--   1.11 Brought help, persistent toggles, load timing and footer in line with repo conventions.
--   1.10 Persisted settings, fixed debounce races, and made pick safe during an active session.
--   1.9  Brought to standard: researchNotesPicker command with rnp short alias, bare help,
--        trigger on/off toggle, debug toggle, loader line and version footer.
--   1.8  Repo-style header update and command summary cleanup; functionality preserved.
--   1.7  Original implementation.
--
-- How it works:
--   * A trigger watches for thesis rows in research-list output and collects the number,
--     subject, level, amount and cost. Rows must contain "A thesis pertaining to", so
--     ordinary shop lists do not open the picker.
--   * A debounce timer opens the picker 0.4 seconds after the last captured row.
--   * A new picker session sends "rem notes". Selecting a thesis sends
--     "read research buy <n>;bind thesis notes", then reopens the picker for repeat purchases.
--   * The picker filters by subject, number or cost. "pick" reopens the last list;
--     "done" sends "hold notes". If the picker is dismissed, the next submitted input
--     sends "hold notes".
--   * The standalone rrl alias sends "read research list"; rrr <item> buys research
--     and handles the notes. These aliases are registered by this plugin.
--   * Nothing is gagged: the normal research-list output remains visible.
--
-- Commands (typed bare, no "/"; rnp is the short alias for researchNotesPicker):
--   researchNotesPicker                 show this help
--   rnp                                 show this help
--   researchNotesPicker on|off          enable or disable the thesis-list trigger
--   researchNotesPicker debug on|off    enable or disable debug messages
--   researchNotesPicker pick            reopen the last research picker
--   researchNotesPicker done            put the notes back now
--   rrl                                 show the research list
--   rrr <item>                          buy research and handle the notes
--
-- Tweaks (top of file):
--   * DEBOUNCE   seconds of silence after the last row before the picker opens

local LOAD_STARTED = os.clock()

local NAME     = "researchNotesPicker"
local VERSION  = "1.14"
local SHORT    = "rnp"
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
local LOAD_MS

local open_picker

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
  H = {
    title   = function(text) return text end,
    section = function(text) return text end,
    line    = function(label, text) return "  " .. label .. "  " .. (text or "") end,
    foot    = function(text) return text end,
  }
end

local function paint(text)
  local ok, styled = pcall(rune.style.cyan, text)
  if ok and styled then return styled end
  return text
end

local function say(message)
  rune.echo(paint("[" .. NAME .. "] ") .. message)
end

local function emit(row)
  rune.echo(row)
end

local function dbg(message)
  if DEBUG then say("debug: " .. message) end
end

local function show_help()
  emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  emit(H.section("Commands"))
  emit(H.line(NAME, "show this help"))
  emit(H.line(SHORT .. " on|off", "enable or disable the thesis-list trigger"))
  emit(H.line(SHORT .. " debug on|off", "enable or disable debug messages"))
  emit(H.line(SHORT .. " pick", "reopen the last research picker"))
  emit(H.line(SHORT .. " done", "put the notes back now"))
  emit(H.line(SHORT, "short alias for " .. NAME))
  emit(H.line("rrl", "show the research list"))
  emit(H.line("rrr <item>", "buy research and handle the notes"))
  emit(H.foot(string.format(
    "v%s  enabled=%s debug=%s triggers=1  load=%dms",
    VERSION, tostring(enabled), tostring(DEBUG), LOAD_MS or 0
  )))
end

-- Send only a numeric research-list selection to the game.
local function buy(num)
  num = tostring(num)
  if not num:match("^%d+$") then
    dbg("refused non-numeric selection")
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

-- If the picker was dismissed, return notes on the next submitted input.
rune.hooks.on("input", function()
  if active and not reopening then finish() end
  return nil
end, { name = NAME .. "-esc", priority = 10 })

local function set_trigger(on)
  enabled = on
  pcall(rune.store.set, STORE_ENABLED, enabled)

  if not on then
    -- Prevent a previously scheduled debounce callback from opening the picker.
    debounce_token = debounce_token + 1
    finish()
  end

  say("trigger " .. (on and "on" or "off"))
end

local function run(sub, rest)
  sub = (sub or ""):lower()
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
    say("debug " .. (DEBUG and "on" or "off"))
  elseif sub == "pick" then
    open_picker(true)
  elseif sub == "done" then
    finish()
  else
    show_help()
  end
end

local function handle_command(args)
  local text = type(args) == "string" and args or ""
  local sub, rest = text:match("^%s*(%S*)%s*(.-)%s*$")
  run(sub, rest)
end

-- Standalone research aliases previously supplied by basicAliases.lua.
rune.alias.exact("rrl", function()
  rune.send("read research list")
end)

rune.alias.exact("rrr", function(args)
  local item = type(args) == "string" and args:match("^%s*(.-)%s*$") or ""
  if item == "" or item:find("[%c;]") then
    say("Usage: rrr <item>")
    return
  end

  rune.send(
    "rem notes;read research buy " .. item ..
    ";bind thesis notes;hold notes"
  )
end)

rune.alias.exact(NAME, handle_command)
rune.alias.exact(SHORT, handle_command)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
