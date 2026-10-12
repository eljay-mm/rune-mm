-- Filename: eljayPlugins/annwnQuestSearch.lua
-- Purpose: Search the Annwn quest database, copy the search URL and show a clickable link
-- Version: 2.5
-- Date: 2026-Oct-11
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * A regex trigger watches for the quest line
--     "This quest [N] is called '<quest name>',".
--   * The quest name (second capture) is URL-encoded and appended to the
--     annwn.info quest search address.
--   * The resulting URL is copied to the system clipboard (rune.clipboard.set,
--     which uses OSC 52), so you can always paste it into a browser.
--   * Three lines are echoed locally (nothing is sent to the game):
--       1. The copy confirmation with the quest name.
--       2. A friendly "Open '<quest name>' on annwn.info" link using an OSC 8
--          terminal hyperlink. In Ghostty, Ctrl+Shift+click opens it in the
--          default browser.
--       3. A friendly line, "Annwn quest '<quest name>': <url>", with the URL
--          as plain text at the end. Ghostty detects plain URLs itself, so
--          Ctrl+Shift+click works here too, even if line 2 is not passed
--          through by Rune.
--   * Commands: typing `annwn` alone shows the command summary and
--     `annwn debug on|off` toggles debug messages (default off, not saved).
--   * The trigger and the alias are registered under fixed names, so /reload
--     replaces them instead of stacking duplicates.
--   * Safety: control characters are stripped from echoed text and the quest
--     name is capped at MAX_NAME_LENGTH characters before it goes into a URL.

local SEARCH_URL      = "https://annwn.info/quest/search/?search=quest&keyword="
local MAX_NAME_LENGTH = 200
local PREFIX          = "[annwnQuestSearch] "

local ANSI_LINK  = "\27[4;36m"  -- underline + cyan
local ANSI_RESET = "\27[0m"

local debug_enabled = false

-- Optional shared help styling (same module autopouch.lua uses).
local helpstyle_ok, H = pcall(require, "helpstyle")
if not helpstyle_ok then
  H = nil
end


local function dbg(message)
  if debug_enabled then
    rune.echo(PREFIX .. message)
  end
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
  local status = "debug: " .. (debug_enabled and "on" or "off")

  local styled = H and pcall(function()
    emit(H.title("Annwn quest search"))
    emit(H.section("Commands"))
    emit(H.line("annwn", "show this summary"))
    emit(H.line("annwn debug on|off", "toggle debug messages (default off)"))
    emit(H.section("Usage"))
    emit(H.line("quest line", "copies the search URL and shows an Annwn link"))
    emit(H.line("Ctrl+Shift+click", "open the link or URL in the browser (Ghostty)"))
    emit(H.foot(status))
  end)

  if styled then
    return
  end

  -- Plain fallback when helpstyle is missing or its API differs.
  rune.echo("Annwn quest search")
  rune.echo("  annwn                show this summary")
  rune.echo("  annwn debug on|off   toggle debug messages (default off)")
  rune.echo("  Ctrl+Shift+click     open the link or URL in the browser (Ghostty)")
  rune.echo(status)
end


local function annwn_command(args, ctx)
  local subcommand, value = tostring(args or ""):lower():match("^(%S+)%s*(%S*)")

  if subcommand ~= "debug" then
    show_help()
    return
  end

  if value == "on" then
    debug_enabled = true
  elseif value == "off" then
    debug_enabled = false
  elseif value ~= "" then
    show_help()
    return
  end

  rune.echo(PREFIX .. "debug is " .. (debug_enabled and "on" or "off"))
end


local function annwn_quest_search(matches, ctx)
  local quest_name = matches[2]

  if not quest_name or quest_name == "" then
    dbg("trigger matched but no quest name was captured")
    return
  end

  quest_name = quest_name:sub(1, MAX_NAME_LENGTH)

  local url = SEARCH_URL .. url_encode(quest_name)
  local safe_name = sanitize(quest_name)

  dbg("quest [" .. tostring(matches[1]) .. "] " .. safe_name)

  -- Copy the search URL to the system clipboard.
  rune.clipboard.set(url)

  rune.echo("[Annwn quest search copied] " .. safe_name)

  -- Friendly OSC 8 link (Ctrl+Shift+click in Ghostty).
  rune.echo("  " .. hyperlink(url, "Open '" .. safe_name .. "' on annwn.info"))

  -- Friendly line; the URL stays last and plain so Ghostty can detect it.
  rune.echo("  Annwn quest '" .. safe_name .. "': " .. url)
end


rune.alias.exact("annwn", annwn_command)

rune.trigger.regex("^This quest \\[([0-9]+)\\] is called '(.+)',$", annwn_quest_search, { name = "annwn-quest-search" })
