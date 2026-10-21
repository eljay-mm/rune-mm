-- Filename: eljayPlugins/highlightCustom.lua
-- Purpose: Highlight words and phrases in game output on the fly per-character.
-- Version: 1.4
-- Date: 2026-Oct-20
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.4  Remove the manual "charname set <name>" command; the name always comes
--        from charname.lua.
--   1.3  Saving is enforced per character name via charname.lua: highlights,
--        on/off and debug are stored under the character's own key; nothing is
--        saved until the name is known; reloads on a character change.
--   1.2  Brought to standard: NAME/SHORT command-name locals, one combined
--        trigger, lazy helpstyle, grouped pipe-separated export.
--   1.1  Add pipe-separated export and clipboard copy.
--   1.0  Convert the MUSHclient Highlighter_MM plugin to Rune.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Enelya.
--   * Registers case-insensitive highlights for saved words and phrases.
--   * All saved phrases share one combined trigger, rebuilt when they change.
--   * Settings are stored in rune.store under a key built by charname.lua, so
--     each character has its own highlights, on/off and debug state.
--   * Writes are refused until the character name is known. Until a character
--     has saved data of its own, the older shared highlights are used as a
--     starting point (they are copied on the first save).
--   * Every write reads the latest stored table, changes it, saves it, then
--     refreshes the in-memory copy.
--
-- Commands (type without "/"; "hlc" is a short alias for "highlightCustom"):
--   highlightCustom <text> <colour>  highlight a word or phrase
--   highlightCustom import <list> <colour>
--                                      import words or phrases separated by | or commas
--   highlightCustom export          show and copy pipe-separated import commands
--   highlightCustom colour|color    list available colours
--   highlightCustom on|off          enable / disable highlights
--   highlightCustom debug on|off    enable / disable debug messages
--   highlightCustom list            show saved highlights
--   highlightCustom clearall        remove all highlights
--   highlightCustom charname        show the detected character name and reload
--   hlc <text> clear                remove a word or phrase highlight
--   hlc                              short alias for "highlightCustom"
--
-- Tweaks (top of file):
--   * No user-tweakable constants.

local LOAD_STARTED = os.clock()

local VERSION = "1.4"

-- Command names: full command and short alias.
local NAME = "highlightCustom"
local SHORT = "hlc"

local STORE_KEY = "highlightCustom.data"
local GROUP = "highlightCustom"
local TRIGGER = "highlightCustom.highlights"
local MAX_PHRASE = 120

local style = rune.style

local function paint(color, text)
  local fn = style[color]
  if type(fn) == "function" then
    local ok, result = pcall(fn, text)
    if ok and type(result) == "string" then return result end
  end
  return text
end

local function say(message)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. message)
end

local function store_get(key)
  local ok, value = pcall(rune.store.get, key)
  if ok then return value end
  return nil
end

local function store_set(key, value)
  local ok, err = pcall(rune.store.set, key, value)
  if not ok then
    say(paint("yellow", "Could not save settings: " .. tostring(err)))
  end
  return ok
end

local function clean_text(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$") or ""
end

local function valid_color(color)
  color = string.lower(color or "")
  if type(style[color]) == "function" then return color end
  return nil
end

local function valid_phrase(text)
  text = clean_text(text)
  if text == "" or #text > MAX_PHRASE or text:find("|", 1, true) then return nil end
  return text
end

-- Character name (horstgs' charname.lua) ---------------------------------------

local cn
do
  local ok, mod = pcall(require, "charname")
  if ok and type(mod) == "table" then cn = mod end
end

local function char_name()
  if not cn then return nil end
  local ok, n = pcall(cn.get)
  if ok and type(n) == "string" and n ~= "" then return n end
  return nil
end

-- Per-character store key, or nil while the name is unknown.
local function char_key(suffix)
  if not char_name() then return nil end
  local ok, k = pcall(cn.key, STORE_KEY .. (suffix or ""))
  if ok and type(k) == "string" and k ~= "" then return k end
  return nil
end

local function no_name_message()
  say(paint("yellow", "Character name not known yet, so nothing was saved. Log in, or use " .. NAME .. " charname to refresh."))
end

-- Data -------------------------------------------------------------------------

local function load_data()
  local loaded
  local key = char_key()
  if key then
    loaded = store_get(key)
    -- No data of its own yet: start from the older shared highlights.
    if type(loaded) ~= "table" then loaded = store_get(STORE_KEY) end
  end
  if type(loaded) ~= "table" then loaded = {} end
  if type(loaded.global) ~= "table" then loaded.global = {} end
  return loaded
end

local function load_flag(suffix, default)
  local key = char_key(suffix)
  local value = key and store_get(key)
  if value == nil then value = store_get(STORE_KEY .. suffix) end
  if value == nil then return default end
  return value == true
end

local data = load_data()
local enabled = load_flag(".enabled", true)
local debug_on = load_flag(".debug", false)
local LOAD_MS = 0

local function debug(message)
  if debug_on then say("debug: " .. message) end
end

-- Every data write starts by reading the latest stored value for this
-- character. The change is applied to that fresh table, then the in-memory
-- copy is refreshed.
local function update_data(change)
  local key = char_key()
  if not key then
    no_name_message()
    return false
  end
  local latest = load_data()
  change(latest)
  if not store_set(key, latest) then return false end
  data = latest
  return true
end

local function refresh_data()
  data = load_data()
end

local function sorted_phrases()
  local phrases = {}
  for phrase in pairs(data.global) do phrases[#phrases + 1] = phrase end
  table.sort(phrases, function(a, b) return a:lower() < b:lower() end)
  return phrases
end

local function count_phrases()
  local count = 0
  for _ in pairs(data.global) do count = count + 1 end
  return count
end

-- Lazy helpstyle: only loaded when help or list is shown.
local H
local function help_style()
  if H then return H end
  local ok, mod = pcall(require, "helpstyle")
  if ok and type(mod) == "table" then
    H = mod
  else
    H = {
      title = function(t) return t end,
      section = function(t) return t end,
      line = function(a, b) return a .. "  " .. tostring(b) end,
      foot = function(t) return t end,
    }
  end
  return H
end

local function show_colours()
  local colours = {}
  for name, value in pairs(style) do
    if type(name) == "string" and type(value) == "function" then
      colours[#colours + 1] = name
    end
  end
  table.sort(colours)

  if #colours == 0 then
    say("No style colours found.")
    return
  end

  say("Available colours:")
  for _, name in ipairs(colours) do
    rune.echo(paint(name, name))
  end
end

-- One combined trigger -------------------------------------------------------

local entries = {}

local function escaped_regex(text)
  return (text:gsub("([\\.^$|?*+()%[%]{}%-])", "\\%1"))
end

local function word_char(ch)
  return ch ~= "" and ch:match("[%w_]") ~= nil
end

local function highlight_line(_, ctx)
  if not enabled then return nil end

  local line = ctx.line:clean()
  local low = line:lower()
  local spans = {}

  for _, e in ipairs(entries) do
    local init = 1
    while true do
      local s, f = low:find(e.key, init, true)
      if not s then break end
      local ok = true
      if e.first_word and s > 1 and word_char(low:sub(s - 1, s - 1)) then ok = false end
      if ok and e.last_word and word_char(low:sub(f + 1, f + 1)) then ok = false end
      if ok then spans[#spans + 1] = { s, f, e.color } end
      init = f + 1
    end
  end

  if #spans == 0 then return nil end

  -- Leftmost first, longest first; overlapping spans are skipped.
  table.sort(spans, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] > b[2]
  end)

  local out, pos = {}, 1
  for _, sp in ipairs(spans) do
    if sp[1] >= pos then
      out[#out + 1] = line:sub(pos, sp[1] - 1)
      out[#out + 1] = paint(sp[3], line:sub(sp[1], sp[2]))
      pos = sp[2] + 1
    end
  end
  out[#out + 1] = line:sub(pos)

  debug("highlighted " .. #spans .. " span(s)")
  return table.concat(out)
end

local function rebuild_trigger()
  pcall(rune.trigger.remove, TRIGGER)

  entries = {}
  local alternatives = {}

  for phrase, color in pairs(data.global) do
    local p = valid_phrase(phrase)
    local c = valid_color(color)
    if p and c then
      entries[#entries + 1] = {
        key = p:lower(),
        color = c,
        first_word = word_char(p:sub(1, 1)),
        last_word = word_char(p:sub(-1)),
      }
      alternatives[#alternatives + 1] = escaped_regex(p)
    end
  end

  if #alternatives == 0 then return end

  table.sort(alternatives, function(a, b) return #a > #b end)

  local pattern = "(?i)\\b(?:" .. table.concat(alternatives, "|") .. ")\\b"
  local ok, err = pcall(rune.trigger.regex, pattern, highlight_line, {
    name = TRIGGER,
    group = GROUP,
    priority = 20,
  })
  if not ok then
    say(paint("yellow", "Could not register the highlight trigger: " .. tostring(err)))
  else
    debug("trigger rebuilt with " .. #alternatives .. " phrase(s)")
  end
end

-- Reload everything for the current character.
local function reload_all()
  data = load_data()
  enabled = load_flag(".enabled", true)
  debug_on = load_flag(".debug", false)
  rebuild_trigger()
end

-- Commands ---------------------------------------------------------------------

local function parse_color_and_text(args)
  local text, requested_color = args:match("^(.-)%s+([^%s]+)$")
  if not text then
    say("Usage: " .. NAME .. " <text> <colour>")
    return nil
  end

  text = valid_phrase(text)
  if not text then
    say("Enter a non-empty phrase of at most " .. MAX_PHRASE .. " characters, without |.")
    return nil
  end

  local color = valid_color(requested_color)
  if not color then
    say("Unknown style color. Use " .. NAME .. " colour or color to list available colours.")
    return nil
  end

  return text, color
end

local function add_highlight(args)
  local phrase, color = parse_color_and_text(args)
  if not phrase then return end

  if update_data(function(latest)
    latest.global[phrase] = color
  end) then
    rebuild_trigger()
    say("Highlighting “" .. phrase .. "” in " .. color .. ".")
  end
end

local function import_highlights(args)
  local list, requested_color = (args or ""):match("^(.-)%s+([^%s]+)%s*$")
  if not list or clean_text(list) == "" then
    say("Usage: " .. NAME .. " import <word or phrase|word or phrase> <colour>")
    return
  end

  local color = valid_color(requested_color)
  if not color then
    say("Unknown style color. Use " .. NAME .. " colour or color to list available colours.")
    return
  end

  -- Pipes take precedence so commas inside phrases are preserved.
  local normalized = list
  if not list:find("|", 1, true) then normalized = list:gsub(",", "|") end

  local phrases = {}
  for phrase in (normalized .. "|"):gmatch("(.-)|") do
    phrase = valid_phrase(phrase)
    if not phrase then
      say("The import list contains an empty entry or a phrase longer than " .. MAX_PHRASE .. " characters.")
      return
    end
    phrases[#phrases + 1] = phrase
  end

  if #phrases == 0 then
    say("The import list is empty.")
    return
  end

  if update_data(function(latest)
    for _, phrase in ipairs(phrases) do
      latest.global[phrase] = color
    end
  end) then
    rebuild_trigger()
    say("Imported " .. #phrases .. " highlight(s) in " .. color .. ".")
  end
end

local function remove_highlight(phrase)
  phrase = clean_text(phrase):lower()
  local removed = {}

  if update_data(function(latest)
    -- Resolve the case-insensitive key against the freshly read table.
    for saved_phrase in pairs(latest.global) do
      if saved_phrase:lower() == phrase then removed[#removed + 1] = saved_phrase end
    end
    for _, saved_phrase in ipairs(removed) do
      latest.global[saved_phrase] = nil
    end
  end) then
    if #removed == 0 then
      say("No matching word or phrase highlight found.")
      return
    end
    rebuild_trigger()
    say("Removed highlight for “" .. removed[1] .. "”.")
  end
end

local function show_list()
  refresh_data()
  local h = help_style()

  say("Saved highlights for " .. (char_name() or "unknown character") .. " (" .. count_phrases() .. "):")
  for _, phrase in ipairs(sorted_phrases()) do
    rune.echo(h.line(phrase, data.global[phrase]))
  end
end

local function export_highlights()
  refresh_data()

  local by_color, colors = {}, {}
  for _, phrase in ipairs(sorted_phrases()) do
    local color = data.global[phrase]
    if not by_color[color] then
      by_color[color] = {}
      colors[#colors + 1] = color
    end
    local group = by_color[color]
    group[#group + 1] = phrase
  end

  if #colors == 0 then
    say("No saved highlights to export.")
    return
  end

  table.sort(colors)

  local commands = {}
  for _, color in ipairs(colors) do
    commands[#commands + 1] = SHORT .. " import " .. table.concat(by_color[color], "|") .. " " .. color
  end

  rune.echo("Export commands:")
  for _, command_line in ipairs(commands) do
    rune.echo(command_line)
  end

  local ok, err = pcall(rune.clipboard.set, table.concat(commands, "\n"))
  if ok then
    say("Export copied to clipboard.")
  else
    say("Clipboard copy failed.")
    debug(tostring(err))
  end
end

local function clear_all()
  if update_data(function(latest)
    latest.global = {}
  end) then
    rebuild_trigger()
    say("All highlights and saved definitions removed.")
  end
end

local function set_flag(suffix, value, label)
  local key = char_key(suffix)
  if not key then
    no_name_message()
    return false
  end
  if not store_set(key, value) then return false end
  say(label .. (value and " enabled." or " disabled."))
  return true
end

local function set_enabled(value)
  if set_flag(".enabled", value, "Highlights") then enabled = value end
end

local function set_debug(value)
  if set_flag(".debug", value, "Debug messages") then debug_on = value end
end

local function show_charname()
  reload_all()

  local name = char_name()
  if name then
    say("Character: " .. name .. " (" .. count_phrases() .. " highlight(s) loaded).")
  else
    no_name_message()
  end
end

local function help()
  local h = help_style()
  rune.echo(h.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(h.section("Commands"))
  rune.echo(h.line(NAME .. " <text> <colour>", "highlight a word or phrase"))
  rune.echo(h.line(NAME .. " import <list> <colour>", "import words or phrases separated by | or commas"))
  rune.echo(h.line(NAME .. " export", "show and copy pipe-separated import commands"))
  rune.echo(h.line(NAME .. " colour|color", "list available colours"))
  rune.echo(h.line(NAME .. " on|off", "enable / disable highlights"))
  rune.echo(h.line(NAME .. " debug on|off", "enable / disable debug messages"))
  rune.echo(h.line(NAME .. " list", "show saved highlights"))
  rune.echo(h.line(NAME .. " clearall", "remove all highlights"))
  rune.echo(h.line(NAME .. " charname", "show the detected character name and reload"))
  rune.echo(h.line(SHORT .. " <text> clear", "remove a word or phrase highlight"))
  rune.echo(h.line(SHORT, "short alias for " .. NAME))
  rune.echo(h.foot(string.format(
    "v%s  char=%s enabled=%s debug=%s  highlights=%d  load=%dms",
    VERSION,
    char_name() or "unknown",
    tostring(enabled),
    tostring(debug_on),
    count_phrases(),
    LOAD_MS
  )))
end

local function command(args)
  args = clean_text(args or "")

  local phrase_to_clear = args:match("^(.-)%s+[Cc][Ll][Ee][Aa][Rr]$")
  if phrase_to_clear then
    remove_highlight(phrase_to_clear)
  elseif args == "" or args == "help" then
    help()
  elseif args == "on" then
    set_enabled(true)
  elseif args == "off" then
    set_enabled(false)
  elseif args == "debug on" then
    set_debug(true)
  elseif args == "debug off" then
    set_debug(false)
  elseif args == "colour" or args == "color" then
    show_colours()
  elseif args == "list" then
    show_list()
  elseif args == "clearall" then
    clear_all()
  elseif args == "export" then
    export_highlights()
  elseif args == "charname" then
    show_charname()
  elseif args:match("^import%s+") then
    import_highlights(args:match("^import%s+(.+)$"))
  else
    add_highlight(args)
  end
end

rune.alias.exact(NAME, function(args)
  command(args)
end)

rune.alias.exact(SHORT, function(args)
  command(args)
end)

-- Reload immediately when charname.lua reports a different character.
if cn and type(cn.on_change) == "function" then
  pcall(cn.on_change, function()
    reload_all()
    local name = char_name()
    if name then
      say("Loaded " .. count_phrases() .. " highlight(s) for " .. name .. ".")
    end
  end)
end

rebuild_trigger()

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))