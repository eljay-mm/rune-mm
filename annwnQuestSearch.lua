-- Filename: eljayPlugins/annwnQuestSearch.lua
-- Purpose: Search the Annwn quest database, copy the search URL and show a clickable link.
-- Version: 2.6
-- Date: 2026-Oct-13
-- Changelog:
--   2.6  Added persisted on/off toggle, repo-style help output, and house-style compliance fixes.
--   2.5  Added safe URL encoding, input sanitation and link output.
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * A regex trigger watches for the quest line "This quest [N] is called '<quest name>',".
--   * The quest name (second capture) is URL-encoded and appended to the Annwn search URL.
--   * The resulting URL is copied to the system clipboard using rune.clipboard.set.
--   * The script prints a confirmation line, a clickable OSC 8 hyperlink, and the plain URL text.
--   * Typing "annwn" alone shows the command summary.
--   * The trigger and alias are registered under fixed names so /reload replaces them instead of stacking duplicates.
--   * Safety: control characters are stripped before echo and the quest name is capped before URL generation.
--   * Settings are saved with rune.store, and the trigger can be disabled without editing files.

local SEARCH_URL      = "https://annwn.info/quest/search/?search=quest&keyword="
local MAX_NAME_LENGTH = 200
local PREFIX          = "[annwnQuestSearch] "
local SETTINGS_KEY    = "annwnQuestSearch.settings"

local ANSI_LINK  = "\27[4;36m"
local ANSI_RESET = "\27[0m"

local enabled = true
local debug_enabled = false

local helpstyle_ok, H = pcall(require, "helpstyle")
if not helpstyle_ok then
  H = nil
end

local function dbg(message)
  if debug_enabled then
    rune.echo(PREFIX .. tostring(message))
  end
end

local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then
      enabled = saved.enabled
    end
    if type(saved.debug) == "boolean" then
      debug_enabled = saved.debug
    end
  end
end

local function save_settings()
  if not (rune and rune.store and type(rune.store.set) == "function") then
    return
  end

  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = enabled,
    debug = debug_enabled,
  })
end

-- Percent-encode everything except unreserved URL characters.
local function url_encode(value)
  return (tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

-- Remove control characters so server text cannot inject terminal escapes.
local function sanitize(value)
  return (tostring(value or ""):gsub("%c", ""))
end

-- OSC 8 terminal hyperlink: ESC ] 8 ; ; URL BEL  label  ESC ] 8 ; ; BEL
local function hyperlink(url, label)
  return "\27]8;;" .. url .. "\7" .. ANSI_LINK .. label .. ANSI_RESET .. "\27]8;;\7"
end

local function emit(text)
  if text ~= nil then
    rune.echo(text)
  end
end

local function show_help()
  local status = "v2.6  enabled=" .. tostring(enabled) .. " debug=" .. tostring(debug_enabled)

  local styled = H and pcall(function()
    emit(H.title("Annwn quest search"))
    emit(H.section("Commands"))
    emit(H.line("annwn", "show this summary"))
    emit(H.line("annwn on|off", "enable or disable the trigger"))
    emit(H.line("annwn debug on|off", "toggle debug messages (default off)"))
    emit(H.section("Usage"))
    emit(H.line("quest status", "copies the search URL and shows an Annwn link"))
    emit(H.line("Ctrl+Shift+click", "open the link or URL in the browser (Ghostty)"))
    emit(H.foot(status))
  end)

  if styled then
    return
  end

  rune.echo("Annwn quest search")
  rune.echo("  annwn                show this summary")
  rune.echo("  annwn on|off         enable or disable the trigger")
  rune.echo("  annwn debug on|off   toggle debug messages (default off)")
  rune.echo("  Ctrl+Shift+click     open the link or URL in the browser (Ghostty)")
  rune.echo(status)
end

local function annwn_command(args, ctx)
  local text = tostring(args or ""):lower()
  local command = text:match("^(%S*)") or ""
  local value = text:match("^%S+%s*(.*)$") or ""

  if command == "" or command == "help" then
    show_help()
    return
  end

  if command == "on" then
    enabled = true
    save_settings()
    rune.echo(PREFIX .. "enabled")
    return
  end

  if command == "off" then
    enabled = false
    save_settings()
    rune.echo(PREFIX .. "disabled")
    return
  end

  if command == "debug" then
    if value == "on" then
      debug_enabled = true
    elseif value == "off" then
      debug_enabled = false
    elseif value ~= "" then
      show_help()
      return
    end

    save_settings()
    rune.echo(PREFIX .. "debug is " .. tostring(debug_enabled))
    return
  end

  show_help()
end

local function annwn_quest_search(matches, ctx)
  if not enabled then
    dbg("trigger ignored because plugin is disabled")
    return
  end

  local quest_name = matches[2]

  if not quest_name or quest_name == "" then
    dbg("trigger matched but no quest name was captured")
    return
  end

  quest_name = quest_name:sub(1, MAX_NAME_LENGTH)
  local safe_name = sanitize(quest_name)
  local url = SEARCH_URL .. url_encode(quest_name)

  dbg("quest name is " .. safe_name)

  if rune.clipboard and type(rune.clipboard.set) == "function" then
    rune.clipboard.set(url)
  else
    dbg("clipboard API not available")
  end

  rune.echo("[Annwn quest search copied] " .. safe_name)
  rune.echo("  " .. hyperlink(url, "Open '" .. safe_name .. "' on annwn.info"))
  rune.echo("  Annwn quest '" .. safe_name .. "': " .. url)
end

rune.alias.exact("annwn", annwn_command)
rune.trigger.regex("^This quest \\[([0-9]+)\\] is called '(.+)',$", annwn_quest_search, { name = "annwn-quest-search" })

load_settings()
save_settings()