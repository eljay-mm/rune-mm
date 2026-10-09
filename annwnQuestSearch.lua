-- Filename: eljayPlugins/annwnQuestSearch.lua
-- Purpose: Search the Annwn quest database and copy the search URL
-- Inspired by the MUSHclient plugin by Ruthgul
-- Version: 2.0
-- Date: 2026-Oct-09

local function url_encode(value)
  return tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end)
end


local function annwn_quest_search(matches, ctx)
  local quest_name = matches[2]

  if not quest_name or quest_name == "" then
    return
  end

  local url =
    "https://annwn.info/quest/search/?search=quest&keyword="
    .. url_encode(quest_name)

  -- Copy the search URL to the system clipboard.
  rune.clipboard.set(url)

  -- Keep the currently working display behavior.
  rune.echo("[Annwn quest search copied] " .. quest_name)
  rune.echo(url)
end


rune.trigger.regex(
  "^This quest \\[([0-9]+)\\] is called '(.+)',$",
  annwn_quest_search,
  {
    name = "annwn-quest-search"
  }
)
