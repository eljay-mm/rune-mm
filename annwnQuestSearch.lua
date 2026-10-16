-- Filename: eljayPlugins/annwnQuestSearch.lua
-- Purpose: Looks up the quest you are reading about on annwn.info, as a clipboard copy and clickable link
-- Version: 2.7
-- Date: 2026-Oct-15
-- Changelog:
--   2.7  Full command is annwnQuestSearch, aqs kept as the short alias; loader
--        line in the standard format with the coloured prefix; Purpose aligned
--        with README.md; only the on/off setting is saved (debug always starts
--        off); settings are no longer rewritten on every load.
--   2.6  Persisted on/off toggle, repo-style help output.
--   2.5  Safe URL encoding, input sanitation and link output.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * A regex trigger watches for the quest line "This quest [N] is called '<quest name>',".
--   * The quest name (second capture) is URL-encoded and appended to the annwn.info quest search address.
--   * The resulting URL is copied to the system clipboard using rune.clipboard.set (OSC 52).
--   * Three lines are echoed locally (nothing is sent to the game): a copy
--     confirmation, a clickable OSC 8 hyperlink, and the plain URL text. In
--     Ghostty, Ctrl+Shift+click opens either one in the default browser.
--   * Commands are typed without a / prefix. annwnQuestSearch is the full
--     command and aqs is the short alias; typing either alone shows the
--     command summary.
--   * The on/off setting is saved with rune.store; the debug toggle always
--     starts off.
--   * The trigger and aliases are registered under fixed names, so a reload
--     replaces them instead of stacking duplicates.
--   * Safety: control characters are stripped before echo and the quest name
--     is capped before URL generation.
--
-- Commands (aqs works in place of annwnQuestSearch):
--   annwnQuestSearch               show this summary
--   annwnQuestSearch on|off        enable or disable the trigger
--   annwnQuestSearch debug on|off  toggle debug messages (default off)

local VERSION         = "2.7"
local NAME            = "annwnQuestSearch"
local SEARCH_URL      = "https://annwn.info/quest/search/?search=quest&keyword="
local MAX_NAME_LENGTH = 200
local PREFIX          = "[" .. NAME .. "] "
local SETTINGS_KEY    = "annwnQuestSearch.settings"

local ANSI_LINK  = "\27[4;36m"  -- underline + cyan
local ANSI_CYAN  = "\27[36m"
local ANSI_RESET = "\27[0m"

local enabled       = true
local debug_enabled = false  -- never saved: always starts off

-- Optional shared help styling (same module autopouch.lua uses).
local helpstyle_ok, H = pcall(require, "helpstyle")
if not helpstyle_ok then
  H = nil
end


-- Cyan "[name] " prefix: rune.style.cyan, then rune.style("cyan", ...), then a
-- plain ANSI escape, so the colour shows whichever style API Rune provides.
local function paint(message)
  local prefix
  local style = rune and rune.style
  if type(style) == "table" and type(style.cyan) == "function" then
    local ok, text = pcall(style.cyan, PREFIX)
    if ok and type(text) == "string" then prefix = text end
  elseif type(style) == "function" then
    local ok, text = pcall(style, "cyan", PREFIX)
    if ok and type(text) == "string" then prefix = text end
  end
  prefix = prefix or (ANSI_CYAN .. PREFIX .. ANSI_RESET)
  return prefix .. tostring(message)
end


local function say(message)
  if not pcall(rune.echo, paint(message)) then
    print(PREFIX .. tostring(message))
  end
end


local function dbg(message)
  if debug_enabled then
    say(message)
  end
end


local function onoff(flag)
  return flag and "on" or "off"
end


-- Only the on/off setting is persisted.
local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" and type(saved.enabled) == "boolean" then
    enabled = saved.enabled
  end
end


local function save_settings()
  if not (rune and rune.store and type(rune.store.set) == "function") then
    return
  end

  pcall(rune.store.set, SETTINGS_KEY, { enabled = enabled })
end


-- Percent-encode everything except unreserved URL characters.
-- The parentheses drop gsub's second return value (the match count).
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
  -- One status row, starting with the version, as the footer.
  local status = "v" .. VERSION .. "  enabled=" .. onoff(enabled) .. " debug=" .. onoff(debug_enabled)

  local styled = H and pcall(function()
    emit(H.title("Annwn quest search"))
    emit(H.section("Commands"))
    emit(H.line("annwnQuestSearch", "show this summary (short alias: aqs)"))
    emit(H.line("annwnQuestSearch on|off", "enable or disable the trigger"))
    emit(H.line("annwnQuestSearch debug on|off", "toggle debug messages (default off)"))
    emit(H.section("Usage"))
    emit(H.line("quest status", "copies the search URL and shows an Annwn link"))
    emit(H.line("Ctrl+Shift+click", "open the link or URL in the browser (Ghostty)"))
    emit(H.foot(status))
  end)

  if styled then
    return
  end

  -- Plain fallback when helpstyle is missing or its API differs.
  rune.echo("Annwn quest search")
  rune.echo("  annwnQuestSearch               show this summary (short alias: aqs)")
  rune.echo("  annwnQuestSearch on|off        enable or disable the trigger")
  rune.echo("  annwnQuestSearch debug on|off  toggle debug messages (default off)")
  rune.echo("  Ctrl+Shift+click               open the link or URL in the browser (Ghostty)")
  rune.echo(status)
end


local function annwn_command(args, ctx)
  local text    = tostring(args or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local command = text:match("^(%S*)") or ""
  local value   = text:match("^%S+%s*(.*)$") or ""

  if command == "on" or command == "off" then
    enabled = (command == "on")
    save_settings()
    say("trigger is " .. onoff(enabled))
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

    say("debug is " .. onoff(debug_enabled))
    return
  end

  -- Bare command, "help" or anything unrecognised.
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

  quest_name = quest_name:sub(1, MAX_NAME_LENGTH)

  local safe_name = sanitize(quest_name)
  local url = SEARCH_URL .. url_encode(quest_name)

  dbg("quest [" .. tostring(matches[1]) .. "] " .. safe_name)

  -- Copy the search URL to the system clipboard.
  if rune.clipboard and type(rune.clipboard.set) == "function" then
    rune.clipboard.set(url)
  else
    dbg("clipboard API not available")
  end

  rune.echo("[Annwn quest search copied] " .. safe_name)

  -- Friendly OSC 8 link (Ctrl+Shift+click in Ghostty).
  rune.echo("  " .. hyperlink(url, "Open '" .. safe_name .. "' on annwn.info"))

  -- Friendly line; the URL stays last and plain so Ghostty can detect it.
  rune.echo("  Annwn quest '" .. safe_name .. "': " .. url)
end


-- Full command and short alias share one handler. Bare commands are aliases
-- (rune.command.add would only create /slash commands).
rune.alias.exact("annwnQuestSearch", annwn_command)
rune.alias.exact("aqs", annwn_command)

rune.trigger.regex("^This quest \\[([0-9]+)\\] is called '(.+)',$", annwn_quest_search, { name = "annwn-quest-search" })

load_settings()

-- Loader line (single row).
say("v" .. VERSION .. " loaded (annwnQuestSearch or aqs for help)")