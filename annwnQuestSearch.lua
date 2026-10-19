-- Filename: eljayPlugins/annwnQuestSearch.lua
-- Purpose: Looks up the quest you are reading about on annwn.info, as a clipboard copy and clickable link
-- Version: 2.8
-- Date: 2026-Oct-19
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.8  Added standard help footer with trigger count and measured load time;
--        persisted the debug setting and added explicit debug on|off support.
--   2.7  Full command is annwnQuestSearch, aqs kept as the short alias; loader
--        line in the standard format with the coloured prefix; Purpose aligned
--        with README.md; only the on/off setting is saved (debug always starts
--        off); settings are no longer rewritten on every load.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * A regex trigger watches for the quest line "This quest [N] is called '<quest name>',".
--   * The quest name is URL-encoded and appended to the annwn.info quest search address.
--   * The resulting URL is copied to the system clipboard using rune.clipboard.set (OSC 52).
--   * Three lines are echoed locally (nothing is sent to the game): a copy
--     confirmation, a clickable OSC 8 hyperlink, and the plain URL text. In
--     Ghostty, Ctrl+Shift+click opens either one in the default browser.
--   * Commands are typed without a / prefix. annwnQuestSearch is the full
--     command and aqs is the short alias; typing either alone shows this help.
--   * The enabled and debug settings are saved with rune.store.
--   * The trigger and aliases are registered under fixed names, so a reload
--     replaces them instead of stacking duplicates.
--   * Safety: control characters are stripped before echo and the quest name
--     is capped before URL generation.
--
-- Commands (aqs works in place of annwnQuestSearch):
--   annwnQuestSearch               show this help
--   annwnQuestSearch on|off        enable or disable the trigger
--   annwnQuestSearch debug on|off  enable or disable debug messages
--
-- Tweaks (top of file):
--   * MAX_NAME_LENGTH  Maximum quest name length used for URL generation

local LOAD_STARTED = os.clock()
local LOAD_MS

local VERSION         = "2.8"
local NAME            = "annwnQuestSearch"
local SHORT           = "aqs"
local SEARCH_URL      = "https://annwn.info/quest/search/?search=quest&keyword="
local MAX_NAME_LENGTH = 200
local SETTINGS_KEY    = "annwnQuestSearch.settings"

local ANSI_LINK  = "\27[4;36m"
local ANSI_CYAN  = "\27[36m"
local ANSI_RESET = "\27[0m"

local enabled       = true
local debug_enabled = false

local H = require("helpstyle")

local function paint(message)
  local prefix
  local style = rune and rune.style

  if type(style) == "table" and type(style.cyan) == "function" then
    local ok, text = pcall(style.cyan, "[" .. NAME .. "] ")
    if ok and type(text) == "string" then
      prefix = text
    end
  elseif type(style) == "function" then
    local ok, text = pcall(style, "cyan", "[" .. NAME .. "] ")
    if ok and type(text) == "string" then
      prefix = text
    end
  end

  prefix = prefix or (ANSI_CYAN .. "[" .. NAME .. "] " .. ANSI_RESET)
  return prefix .. tostring(message)
end

local function say(message)
  rune.echo(paint(message))
end

local function dbg(message)
  if debug_enabled then
    say(message)
  end
end

local function onoff(flag)
  return flag and "on" or "off"
end

local function load_settings()
  if not (rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then
      enabled = saved.enabled
    end
    if type(saved.debug_enabled) == "boolean" then
      debug_enabled = saved.debug_enabled
    end
  end
end

local function save_settings()
  if not (rune.store and type(rune.store.set) == "function") then
    return
  end

  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = enabled,
    debug_enabled = debug_enabled,
  })
end

local function url_encode(value)
  return (tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

local function sanitize(value)
  return (tostring(value or ""):gsub("%c", ""))
end

local function hyperlink(url, label)
  return "\27]8;;" .. url .. "\7"
    .. ANSI_LINK .. label .. ANSI_RESET
    .. "\27]8;;\7"
end

local function emit(text)
  if text ~= nil then
    rune.echo(text)
  end
end

local function show_help()
  emit(H.title("Annwn quest search  (alias: " .. SHORT .. ")"))
  emit(H.section("Commands"))
  emit(H.line(NAME, "show this help"))
  emit(H.line(NAME .. " on|off", "enable or disable the trigger"))
  emit(H.line(NAME .. " debug on|off", "enable or disable debug messages"))
  emit(H.section("Usage"))
  emit(H.line("quest status", "copies the search URL and shows an Annwn link"))
  emit(H.line("Ctrl+Shift+click", "open the link or URL in the browser (Ghostty)"))
  emit(H.foot(string.format(
    "v%s  enabled=%s debug=%s triggers=1  load=%dms",
    VERSION,
    tostring(enabled),
    tostring(debug_enabled),
    LOAD_MS
  )))
end

local function annwn_command(args, ctx)
  local text = tostring(args or ""):lower():match("^%s*(.-)%s*$")
  local command, value = text:match("^(%S+)%s*(.-)$")

  if command == "on" or command == "off" then
    enabled = command == "on"
    save_settings()
    say("trigger is " .. onoff(enabled))
    return
  end

  if command == "debug" then
    if value == "on" then
      debug_enabled = true
    elseif value == "off" then
      debug_enabled = false
    else
      show_help()
      return
    end

    save_settings()
    say("debug is " .. onoff(debug_enabled))
    return
  end

  show_help()
end

local function annwn_quest_search(matches, ctx)
  if not enabled then
    dbg("trigger ignored because the plugin is off")
    return
  end

  local quest_name = matches[2]
  if not quest_name or quest_name == "" then
    dbg("trigger matched but no quest name was captured")
    return
  end

  quest_name = sanitize(quest_name):sub(1, MAX_NAME_LENGTH)
  local url = SEARCH_URL .. url_encode(quest_name)

  dbg("quest [" .. tostring(matches[1]) .. "] " .. quest_name)

  if rune.clipboard and type(rune.clipboard.set) == "function" then
    local ok, err = pcall(rune.clipboard.set, url)
    if not ok then
      dbg("clipboard copy failed: " .. sanitize(err))
    end
  else
    dbg("clipboard API not available")
  end

  rune.echo("[Annwn quest search copied] " .. quest_name)
  rune.echo("  " .. hyperlink(url, "Open '" .. quest_name .. "' on annwn.info"))
  rune.echo("  Annwn quest '" .. quest_name .. "': " .. url)
end

rune.alias.exact(NAME, annwn_command)
rune.alias.exact(SHORT, annwn_command)

rune.trigger.regex(
  "^This quest \\[([0-9]+)\\] is called '(.+)',$",
  annwn_quest_search,
  { name = "annwn-quest-search" }
)

load_settings()

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")
