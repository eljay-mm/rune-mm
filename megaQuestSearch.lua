-- Filename: eljayPlugins/megaQuestSearch.lua
-- Purpose: Looks up the quest you are reading about on the Megaleios wiki by Quest ID
-- Version: 1.0
-- Date: 2026-Oct-22
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.0  Initial release; builds the Megaleios wiki search URL from the
--        Quest ID in the quest status line.
--
-- How it works:
--   * A regex trigger watches for the quest line
--     "This quest [N] is called '<quest name>',".
--   * The Quest ID is appended to the Megaleios wiki search URL.
--   * The resulting URL is copied to the system clipboard using
--     rune.clipboard.set (OSC 52).
--   * Three lines are echoed locally (nothing is sent to the game): a copy
--     confirmation, a clickable OSC 8 hyperlink, and the plain URL text. In
--     Ghostty, Ctrl+Shift+click opens either one in the default browser.
--   * Commands are typed without a / prefix. megaQuestSearch is the full
--     command and mqs is the short alias; typing either alone shows this help.
--   * The enabled and debug settings are saved with rune.store.
--   * The trigger and aliases are registered under fixed names, so a reload
--     replaces them instead of stacking duplicates.
--   * Safety: the Quest ID is restricted to digits before URL generation,
--     and control characters are stripped before echo.
--
-- Commands (mqs works in place of megaQuestSearch):
--   megaQuestSearch               show this help
--   megaQuestSearch on|off        enable or disable the trigger
--   megaQuestSearch debug on|off  enable or disable debug messages
--
-- Tweaks (top of file):
--   * MAX_ID_LENGTH  Maximum Quest ID length used for URL generation

local LOAD_STARTED = os.clock()
local LOAD_MS

local VERSION       = "1.0"
-- Command names: full command and short alias.
local NAME          = "megaQuestSearch"
local SHORT         = "mqs"
local SEARCH_URL    = "https://megaleios-wiki.com/quest?q="
local MAX_ID_LENGTH = 20
local SETTINGS_KEY  = "megaQuestSearch.settings"

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
  if not (rune.store and type(rune.store.get) == "function"
      and type(rune.store.set) == "function") then
    return
  end

  local ok, fresh = pcall(rune.store.get, SETTINGS_KEY)
  if not ok or type(fresh) ~= "table" then
    fresh = {}
  end

  fresh.enabled = enabled
  fresh.debug_enabled = debug_enabled
  pcall(rune.store.set, SETTINGS_KEY, fresh)
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
  emit(H.title("Megaleios quest search  (alias: " .. SHORT .. ")"))
  emit(H.section("Commands"))
  emit(H.line(NAME, "show this help"))
  emit(H.line(NAME .. " on|off", "enable or disable the trigger"))
  emit(H.line(NAME .. " debug on|off", "enable or disable debug messages"))
  emit(H.line(SHORT, "short alias for " .. NAME))
  emit(H.section("Usage"))
  emit(H.line("quest status", "copies the wiki search URL using the Quest ID"))
  emit(H.line("Ctrl+Shift+click", "open the link or URL in the browser (Ghostty)"))
  emit(H.foot(string.format(
    "v%s  enabled=%s debug=%s triggers=1  load=%dms",
    VERSION,
    tostring(enabled),
    tostring(debug_enabled),
    LOAD_MS
  )))
end

local function mega_command(args, ctx)
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

local function mega_quest_search(matches, ctx)
  if not enabled then
    dbg("trigger ignored because the plugin is off")
    return
  end

  local quest_id = tostring(matches[1] or ""):match("^(%d+)$")
  if not quest_id then
    dbg("trigger matched but no numeric Quest ID was captured")
    return
  end

  quest_id = quest_id:sub(1, MAX_ID_LENGTH)
  local quest_name = sanitize(matches[2] or "")
  local url = SEARCH_URL .. quest_id

  dbg("Quest ID [" .. quest_id .. "] " .. quest_name)

  if rune.clipboard and type(rune.clipboard.set) == "function" then
    local ok, err = pcall(rune.clipboard.set, url)
    if not ok then
      dbg("clipboard copy failed: " .. sanitize(err))
    end
  else
    dbg("clipboard API not available")
  end

  rune.echo("[Megaleios quest search copied] Quest ID " .. quest_id)
  rune.echo("  " .. hyperlink(url, "Open Quest " .. quest_id .. " on Megaleios wiki"))
  rune.echo("  Megaleios quest '" .. quest_name .. "' (ID " .. quest_id .. "): " .. url)
end

rune.alias.exact(NAME, mega_command)
rune.alias.exact(SHORT, mega_command)

rune.trigger.regex(
  "^This quest \\[([0-9]+)\\] is called '(.+)',$",
  mega_quest_search,
  { name = "mega-quest-search" }
)

load_settings()

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")
