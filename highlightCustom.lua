-- Filename: eljayPlugins/highlightCustom.lua
-- Purpose: Highlight words and phrases in game output on the fly per-character.
-- Version: 1.7
-- Date: 2026-Oct-25
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.7  Remove the unsupported charname command from help and error text.
--   1.6  Fix punctuation boundaries, validate stored data, and harden callbacks.
--   1.5  Brought to standard, trimmed under 16000 bytes, help within 76
--        columns, shared helpers; behaviour unchanged.
--   1.4  Removed the manual charname set command.
--   1.3  Per-character saving via charname.lua.
--   1.2  One combined trigger; grouped export.  1.1  Export.
--   1.0  Convert the MUSHclient Highlighter_MM plugin to Rune.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Enelya.
--   * Highlights saved words and phrases in game output per character.
--   * All saved phrases share one combined trigger, rebuilt on changes.
--   * Settings use charname.lua for per-character storage keys.
--   * Writes wait until the character name is known; older shared
--     highlights are used as a starting point on the first save.
--   * Stored phrases and colours are validated before trigger registration.
--
-- Commands (type without "/"; "hlc" is a short alias for "highlightCustom"):
--   hlc <text> <colour>       highlight a word or phrase
--   hlc import <list> <colour> import phrases separated by | or commas
--   hlc export                show and copy import commands
--   hlc colour|color          list available colours
--   hlc on|off                enable / disable highlights
--   hlc debug on|off          enable / disable debug messages
--   hlc list                  show saved highlights
--   hlc clearall              remove all highlights
--   hlc <text> clear          remove a word or phrase highlight
--   hlc                      show this help; short alias for highlightCustom
--
-- Tweaks (top of file):
--   * No user-tweakable constants.

local LOAD_STARTED = os.clock()
local VERSION = "1.7"

-- Command names: full command and short alias.
local NAME = "highlightCustom"
local SHORT = "hlc"

local STORE_KEY = NAME .. ".data"
local TRIGGER = NAME .. ".highlights"
local MAX_PHRASE = 120
local style = rune.style
local H = require("helpstyle")

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
  local ok, result = pcall(rune.store.set, key, value)
  if not ok or result == false then
    say(paint("yellow", "Could not save settings: " .. tostring(result)))
    return false
  end
  return true
end

local function clean_text(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$") or ""
end

local function valid_color(color)
  if type(color) ~= "string" then color = "" end
  color = string.lower(color)
  if type(style[color]) == "function" then return color end
  say("Unknown style color. Use " .. NAME .. " colour to list colours.")
  return nil
end

local function valid_phrase(text)
  text = clean_text(text)
  if text == "" or #text > MAX_PHRASE or text:find("|", 1, true) then
    return nil
  end
  return text
end

-- charname.lua (horstgs) supplies each character's store key.
local cn
do
  local ok, mod = pcall(require, "charname")
  if ok and type(mod) == "table" then cn = mod end
end

local function char_name()
  if not cn then return nil end
  local ok, name = pcall(cn.get)
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

-- Per-character store key, or nil while the name is unknown.
local function char_key(suffix)
  if not char_name() then return nil end
  local ok, key = pcall(cn.key, STORE_KEY .. (suffix or ""))
  if ok and type(key) == "string" and key ~= "" then return key end
  return nil
end

local function no_name()
  say(paint("yellow",
    "Character name not known yet; nothing saved. Try again after login."))
end

local function sanitize_data(value)
  local clean = { global = {} }
  if type(value) ~= "table" or type(value.global) ~= "table" then
    return clean
  end

  for phrase, color in pairs(value.global) do
    if type(phrase) == "string" and valid_phrase(phrase)
      and type(color) == "string" and type(style[color]) == "function" then
      clean.global[phrase] = color
    end
  end
  return clean
end

local function load_data()
  local loaded
  local key = char_key()
  if key then
    loaded = store_get(key)
    -- No character-specific data yet: use the older shared highlights.
    if type(loaded) ~= "table" then loaded = store_get(STORE_KEY) end
  end
  return sanitize_data(loaded)
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
local trigger_count = 0

local function debug(message)
  if debug_on then say("debug: " .. message) end
end

-- Read the latest table, modify it, save it, then refresh the cache.
local function update_data(change)
  local key = char_key()
  if not key then
    no_name()
    return false
  end

  local latest = sanitize_data(load_data())
  change(latest)
  if not store_set(key, latest) then return false end
  data = latest
  return true
end

local function sorted_phrases()
  local phrases = {}
  for phrase in pairs(data.global) do phrases[#phrases + 1] = phrase end
  table.sort(phrases, function(a, b) return a:lower() < b:lower() end)
  return phrases
end

local function show_colours()
  local colours = {}
  for name, value in pairs(style) do
    if type(name) == "string" and type(value) == "function" then
      colours[#colours + 1] = name
    end
  end
  table.sort(colours)
  say(#colours == 0 and "No style colours found." or "Available colours:")
  for _, name in ipairs(colours) do rune.echo(paint(name, name)) end
end

-- One combined trigger for all saved phrases.
local entries = {}

local function word_char(ch)
  return ch ~= "" and ch:match("[%w_]") ~= nil
end

local function highlight_line(_, ctx)
  if not enabled or not ctx or not ctx.line then return nil end

  local line = ctx.line:clean()
  local low = line:lower()
  local spans = {}

  for _, entry in ipairs(entries) do
    local init = 1
    while true do
      local first, last = low:find(entry.key, init, true)
      if not first then break end

      if not (entry.first_word and first > 1
          and word_char(low:sub(first - 1, first - 1)))
        and not (entry.last_word and word_char(low:sub(last + 1, last + 1))) then
        spans[#spans + 1] = { first, last, entry.color }
      end
      init = last + 1
    end
  end

  if #spans == 0 then return nil end

  -- Leftmost first, longest first; overlapping spans are skipped.
  table.sort(spans, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] > b[2]
  end)

  local out, pos, applied = {}, 1, 0
  for _, span in ipairs(spans) do
    if span[1] >= pos then
      out[#out + 1] = line:sub(pos, span[1] - 1)
      out[#out + 1] = paint(span[3], line:sub(span[1], span[2]))
      pos = span[2] + 1
      applied = applied + 1
    end
  end
  out[#out + 1] = line:sub(pos)

  debug("highlighted " .. applied .. " span(s)")
  return table.concat(out)
end

local function regex_escape(text)
  return (text:gsub("([\\.^$|?*+()%[%]{}%-])", "\\%1"))
end

local function rebuild_trigger()
  pcall(rune.trigger.remove, TRIGGER)
  entries = {}
  trigger_count = 0

  local alternatives = {}
  for phrase, color in pairs(data.global) do
    local clean = valid_phrase(phrase)
    if clean and type(color) == "string" and type(style[color]) == "function" then
      entries[#entries + 1] = {
        key = clean:lower(),
        color = color,
        first_word = word_char(clean:sub(1, 1)),
        last_word = word_char(clean:sub(-1)),
      }

      local escaped = regex_escape(clean)
      if word_char(clean:sub(1, 1)) then escaped = "\\b" .. escaped end
      if word_char(clean:sub(-1)) then escaped = escaped .. "\\b" end
      alternatives[#alternatives + 1] = escaped
    end
  end

  if #alternatives == 0 then return end
  table.sort(alternatives, function(a, b) return #a > #b end)

  local pattern = "(?i)(?:" .. table.concat(alternatives, "|") .. ")"
  local ok, err = pcall(rune.trigger.regex, pattern, highlight_line, {
    name = TRIGGER,
    group = NAME,
    priority = 20,
  })
  if ok then
    trigger_count = 1
  else
    say(paint("yellow",
      "Could not register the highlight trigger: " .. tostring(err)))
  end
end

local function reload_all()
  data = load_data()
  enabled = load_flag(".enabled", true)
  debug_on = load_flag(".debug", false)
  rebuild_trigger()
end

local function import_highlights(args)
  local list, requested_color = (args or ""):match("^(.-)%s+([^%s]+)%s*$")
  if not list or clean_text(list) == "" then
    say("Usage: " .. NAME .. " import <word or phrase|word or phrase> <colour>")
    return
  end

  local color = valid_color(requested_color)
  if not color then return end

  -- Pipes take precedence, preserving commas inside phrases.
  local normalized = list
  if not list:find("|", 1, true) then normalized = list:gsub(",", "|") end

  local phrases = {}
  for phrase in (normalized .. "|"):gmatch("(.-)|") do
    phrase = valid_phrase(phrase)
    if not phrase then
      say("Empty entry, or a phrase over " .. MAX_PHRASE .. " characters.")
      return
    end
    phrases[#phrases + 1] = phrase
  end

  if update_data(function(latest)
    for _, phrase in ipairs(phrases) do latest.global[phrase] = color end
  end) then
    rebuild_trigger()
    say("Imported " .. #phrases .. " highlight(s) in " .. color .. ".")
  end
end

local function add_highlight(args)
  local text, requested_color = args:match("^(.-)%s+([^%s]+)$")
  if not text then
    say("Usage: " .. NAME .. " <text> <colour>")
    return
  end

  local phrase = valid_phrase(text)
  if not phrase then
    say("Enter a non-empty phrase of at most " .. MAX_PHRASE
      .. " characters, without |.")
    return
  end

  local color = valid_color(requested_color)
  if color and update_data(function(latest)
    latest.global[phrase] = color
  end) then
    rebuild_trigger()
    say("Highlighting “" .. phrase .. "” in " .. color .. ".")
  end
end

local function remove_highlight(phrase)
  phrase = clean_text(phrase):lower()
  local removed = {}

  if update_data(function(latest)
    for saved in pairs(latest.global) do
      if saved:lower() == phrase then removed[#removed + 1] = saved end
    end
    for _, saved in ipairs(removed) do latest.global[saved] = nil end
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
  data = load_data()
  local phrases = sorted_phrases()

  say("Saved highlights for " .. (char_name() or "unknown character")
    .. " (" .. #phrases .. "):")
  for _, phrase in ipairs(phrases) do
    rune.echo(H.line(phrase, data.global[phrase]))
  end
end

local function export_highlights()
  data = load_data()

  local by_color, colors = {}, {}
  for _, phrase in ipairs(sorted_phrases()) do
    local color = data.global[phrase]
    if not by_color[color] then
      by_color[color] = {}
      colors[#colors + 1] = color
    end
    table.insert(by_color[color], phrase)
  end

  if #colors == 0 then
    say("No saved highlights to export.")
    return
  end

  table.sort(colors)
  local commands = {}
  for _, color in ipairs(colors) do
    commands[#commands + 1] =
      SHORT .. " import " .. table.concat(by_color[color], "|") .. " " .. color
  end

  rune.echo("Export commands:")
  for _, command_line in ipairs(commands) do rune.echo(command_line) end

  local ok, err = pcall(function()
    rune.clipboard.set(table.concat(commands, "\n"))
  end)
  say(ok and "Export copied to clipboard." or "Clipboard copy failed.")
  if not ok then debug(tostring(err)) end
end

local function clear_all()
  if update_data(function(latest) latest.global = {} end) then
    rebuild_trigger()
    say("All highlights and saved definitions removed.")
  end
end

local function set_flag(suffix, value, label)
  local key = char_key(suffix)
  if not key then
    no_name()
    return false
  end
  if not store_set(key, value) then return false end
  say(label .. (value and " enabled." or " disabled."))
  return true
end

local HELP_ROWS = {
  { " <text> <colour>", "highlight a word or phrase" },
  { " import <list> <colour>", "import | or comma list" },
  { " export", "show and copy import commands" },
  { " colour|color", "list available colours" },
  { " on|off", "enable / disable highlights" },
  { " debug on|off", "enable / disable debug messages" },
  { " list", "show saved highlights" },
  { " clearall", "remove all highlights" },
}

local function help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  for _, row in ipairs(HELP_ROWS) do
    rune.echo(H.line(SHORT .. row[1], row[2]))
  end
  rune.echo(H.line(SHORT .. " <text> clear", "remove a word or phrase"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(string.format(
    "v%s  char=%s enabled=%s debug=%s triggers=%d highlights=%d load=%dms",
    VERSION, char_name() or "unknown", tostring(enabled), tostring(debug_on),
    trigger_count, #sorted_phrases(), LOAD_MS
  )))
end

local function command(args)
  args = clean_text(args or "")

  local phrase_to_clear = args:match("^(.-)%s+[Cc][Ll][Ee][Aa][Rr]$")
  if phrase_to_clear then
    remove_highlight(phrase_to_clear)
  elseif args == "" or args == "help" then
    help()
  elseif args == "on" or args == "off" then
    local value = args == "on"
    if set_flag(".enabled", value, "Highlights") then enabled = value end
  elseif args == "debug on" or args == "debug off" then
    local value = args == "debug on"
    if set_flag(".debug", value, "Debug messages") then debug_on = value end
  elseif args == "colour" or args == "color" then
    show_colours()
  elseif args == "list" then
    show_list()
  elseif args == "clearall" then
    clear_all()
  elseif args == "export" then
    export_highlights()
  elseif args:match("^import%s+") then
    import_highlights(args:match("^import%s+(.+)$"))
  else
    add_highlight(args)
  end
end

rune.alias.exact(NAME, function(args, ctx) command(args, ctx) end)
rune.alias.exact(SHORT, function(args, ctx) command(args, ctx) end)

-- Refresh on character changes; avoid letting callback errors escape.
if cn and type(cn.on_change) == "function" then
  pcall(cn.on_change, function()
    pcall(reload_all)
  end)
end

rebuild_trigger()

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
