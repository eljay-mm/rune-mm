-- Filename: eljayPlugins/annwnQuestSearch.lua
-- Purpose: Search the Annwn quest database and copy the search URL
-- Version: 2.1
-- Date: 2026-Oct-11
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * A regex trigger watches for the quest line
--     "This quest [N] is called '<quest name>',".
--   * The quest name (second capture) is URL-encoded and appended to the
--     annwn.info quest search address.
--   * The resulting URL is copied to the system clipboard (rune.clipboard.set,
--     which uses OSC 52, so the terminal must allow clipboard writes).
--   * The quest name and the URL are echoed locally so you can see what was
--     copied. Nothing is sent to the game.
--   * The trigger is registered under a fixed name, so /reload replaces it
--     instead of stacking a duplicate.

local SEARCH_URL = "https://annwn.info/quest/search/?search=quest&keyword="


-- Percent-encode everything except unreserved URL characters.
-- The parentheses drop gsub's second return value (the match count).
local function url_encode(value)
  return (tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end


local function annwn_quest_search(matches, ctx)
  local quest_name = matches[2]

  if not quest_name or quest_name == "" then
    return
  end

  local url = SEARCH_URL .. url_encode(quest_name)

  -- Copy the search URL to the system clipboard.
  rune.clipboard.set(url)

  -- Keep the currently working display behavior.
  rune.echo("[Annwn quest search copied] " .. quest_name)
  rune.echo(url)
end


rune.trigger.regex("^This quest \\[([0-9]+)\\] is called '(.+)',$", annwn_quest_search, { name = "annwn-quest-search" })
