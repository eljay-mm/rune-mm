-- Filename: eljayPlugins/missingAffects.lua
-- Purpose: Shows which wanted affects are missing from your current affects.
-- Version: 1.1
-- Date: 2026-Oct-16
-- Changelog:
--   1.1  Scope persistent settings to rune.connection.character when available;
--        fall back to global keys when Rune does not expose a character identity.
--   1.0  Convert the MUSHclient missing_affects plugin for Rune.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * Keeps a wanted-affects list in rune.store and compares it with your
--     current affects when the affects list is displayed.
--   * Settings use Rune's current character identity when available.
--   * Treats the configured similar affects as interchangeable.
--
-- Commands (type without "/"; "ma" is a short alias for "missingAffects"):
--   missingAffects            show this help
--   ma                        show this help
--   missingAffects add <affect>
--   missingAffects del <affect>
--   missingAffects list
--   missingAffects on|off     enable / disable affects tracking
--   missingAffects debug      toggle debug messages (default off)
--
-- Tweaks (top of file):
--   * MAX_AFFECT_LENGTH   Maximum affect name length accepted and stored.
--   * Similar-affect groups are defined below.
--   * Keep affect names as plain text; this plugin never sends them to the game.

local NAME, SHORT, VERSION, GROUP =
  "missingAffects", "ma", "1.1", "missingAffects"

local MAX_AFFECT_LENGTH = 20
local MAX_WANTED = 200

local ANSI_CYAN = "\27[36m"
local ANSI_RESET = "\27[0m"

local debugEnabled = false -- deliberately not persisted
local enabled = true
local wanted = {}
local currentAffects = nil

local function characterIdentity()
  local connection = rune and rune.connection
  if type(connection) ~= "table" then
    return nil
  end

  local identity = connection.character
  if type(identity) == "function" then
    local ok, value = pcall(identity)
    if ok then
      identity = value
    else
      return nil
    end
  end

  if type(identity) ~= "string" and type(identity) ~= "number" then
    return nil
  end

  identity = tostring(identity):match("^%s*(.-)%s*$")
  if not identity or identity == "" then
    return nil
  end

  -- Keep the identity safe to use as part of a storage key.
  identity = identity:lower():gsub("[^%w_.%-]", "_")
  if identity == "" then
    return nil
  end

  return identity
end

local CHARACTER_ID = characterIdentity()
local STORE_SUFFIX = CHARACTER_ID and ("." .. CHARACTER_ID) or ""

local STORE_WANTED  = "missingAffects.wanted" .. STORE_SUFFIX
local STORE_ENABLED = "missingAffects.enabled" .. STORE_SUFFIX

local helpstyle_ok, H = pcall(require, "helpstyle")
if not helpstyle_ok or type(H) ~= "table" then
  H = nil
end

local function paintCyan(text)
  local style = rune and rune.style

  if type(style) == "table" and type(style.cyan) == "function" then
    local ok, result = pcall(style.cyan, text)
    if ok and type(result) == "string" then
      return result
    end
  elseif type(style) == "function" then
    local ok, result = pcall(style, "cyan", text)
    if ok and type(result) == "string" then
      return result
    end
  end

  return ANSI_CYAN .. text .. ANSI_RESET
end

local function say(message)
  rune.echo(paintCyan("[" .. NAME .. "] ") .. tostring(message))
end

local function dbg(message)
  if debugEnabled then
    say("debug: " .. tostring(message))
  end
end

local function onoff(value)
  return value and "on" or "off"
end

local function normalize(value)
  local text = tostring(value or ""):lower():match("^%s*(.-)%s*$") or ""
  return text:sub(1, MAX_AFFECT_LENGTH)
end

local function hasValue(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function removeValue(list, value)
  for i = #list, 1, -1 do
    if list[i] == value then
      table.remove(list, i)
    end
  end
end

local function saveValue(key, value)
  if rune.store and type(rune.store.set) == "function" then
    pcall(rune.store.set, key, value)
  end
end

local function sortAndSaveWanted()
  table.sort(wanted)
  saveValue(STORE_WANTED, wanted)
end

local function loadSettings()
  if not (rune.store and type(rune.store.get) == "function") then
    return
  end

  local enabledOk, savedEnabled = pcall(rune.store.get, STORE_ENABLED)
  if enabledOk and type(savedEnabled) == "boolean" then
    enabled = savedEnabled
  end

  local wantedOk, savedWanted = pcall(rune.store.get, STORE_WANTED)
  if wantedOk and type(savedWanted) == "table" then
    local seen = {}

    for _, item in ipairs(savedWanted) do
      if type(item) == "string" then
        local value = normalize(item)
        if value ~= "" and not seen[value] and #wanted < MAX_WANTED then
          wanted[#wanted + 1] = value
          seen[value] = true
        end
      end
    end

    table.sort(wanted)
  end
end

local similarAffects = {
  { "armor", "aegis", "guise of nature" },
  { "detect invisibility", "radiance invocation" },
  { "enhanced strength", "minerals invocation", "unnatural strength" },
  { "fireshield", "frostborne", "magma invocation" },
  { "haste", "lightning invocation", "whirlwind" },
  { "levitation", "air invocation", "float" },
  { "pass door", "steam invocation", "wind walk" },
  { "sanctuary", "fire invocation" },
  { "sense life", "infravision", "pense" },
  { "shield", "ice invocation", "force field" },
  { "stone skin", "ooze invocation", "statuary skin" },
  { "underwater breathing", "otolithic growth" },
}

local function emit(text)
  if text ~= nil then
    rune.echo(text)
  end
end

local function showHelp()
  local status = "v" .. VERSION ..
    "  enabled=" .. onoff(enabled) ..
    " debug=" .. onoff(debugEnabled)

  local styled = H and pcall(function()
    emit(H.title("Missing affects  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))
    emit(H.line(NAME, "show this help"))
    emit(H.line(SHORT, "show this help"))
    emit(H.line(NAME .. " add <affect>", "add an affect to the wanted list"))
    emit(H.line(NAME .. " del <affect>", "remove an affect from the wanted list"))
    emit(H.line(NAME .. " list", "show wanted affects"))
    emit(H.line(NAME .. " on|off", "enable or disable affects tracking"))
    emit(H.line(NAME .. " debug", "toggle debug messages (default off)"))
    emit(H.foot(status))
  end)

  if not styled then
    rune.echo("Missing affects  (alias: " .. SHORT .. ")")
    rune.echo("  " .. NAME .. "                 show this help")
    rune.echo("  " .. SHORT .. "                         show this help")
    rune.echo("  " .. NAME .. " add <affect>     add an affect to the wanted list")
    rune.echo("  " .. NAME .. " del <affect>     remove an affect from the wanted list")
    rune.echo("  " .. NAME .. " list            show wanted affects")
    rune.echo("  " .. NAME .. " on|off          enable or disable affects tracking")
    rune.echo("  " .. NAME .. " debug           toggle debug messages (default off)")
    rune.echo(status)
  end
end

local function listWanted()
  say("wanted affects: " ..
    (#wanted > 0 and table.concat(wanted, ", ") or "-"))
end

local function addWanted(argument)
  local affect = normalize(argument)
  if affect == "" then
    say("usage: " .. NAME .. " add <affect>")
    return
  end

  if hasValue(wanted, affect) then
    say("already wanted: " .. affect)
    return
  end

  if #wanted >= MAX_WANTED then
    say("wanted list is at its limit (" .. MAX_WANTED .. " affects)")
    return
  end

  wanted[#wanted + 1] = affect
  sortAndSaveWanted()
  listWanted()
end

local function deleteWanted(argument)
  local affect = normalize(argument)
  if affect == "" then
    say("usage: " .. NAME .. " del <affect>")
    return
  end

  removeValue(wanted, affect)
  sortAndSaveWanted()
  listWanted()
end

local function showMissing()
  local missing = {}

  for _, affect in ipairs(wanted) do
    if not currentAffects[affect] then
      missing[#missing + 1] = affect
    end
  end

  for _, group in ipairs(similarAffects) do
    local groupPresent = false

    for _, affect in ipairs(group) do
      if currentAffects[affect] then
        groupPresent = true
        break
      end
    end

    if groupPresent then
      for _, affect in ipairs(group) do
        removeValue(missing, affect)
      end
    end
  end

  if #missing > 0 then
    say("You are missing: " .. table.concat(missing, ", "))
  end
end

local function command(args)
  local text = tostring(args or ""):lower():match("^%s*(.-)%s*$") or ""
  local option, argument = text:match("^(%S*)%s*(.-)%s*$")
  option = option or ""

  if option == "" or option == "help" then
    showHelp()
  elseif option == "add" then
    addWanted(argument)
  elseif option == "del" or option == "delete" then
    deleteWanted(argument)
  elseif option == "list" then
    listWanted()
  elseif option == "on" then
    enabled = true
    saveValue(STORE_ENABLED, true)
    rune.group.enable(GROUP)
    say("affects tracking enabled")
  elseif option == "off" then
    enabled = false
    currentAffects = nil
    saveValue(STORE_ENABLED, false)
    rune.group.disable(GROUP)
    say("affects tracking disabled")
  elseif option == "debug" and argument == "" then
    debugEnabled = not debugEnabled
    say("debug " .. onoff(debugEnabled))
  else
    say("unknown command; type " .. NAME .. " for help")
  end
end

-- All triggers share a group so the on/off command controls them together.

rune.trigger.regex(
  "^You are affected by the following:",
  function()
    currentAffects = {}
    dbg("started reading affects")
  end,
  { group = GROUP }
)

rune.trigger.regex(
  "^(?:Spell|Prof):\\s+(.+?)\\s+- Level",
  function(matches)
    if not currentAffects or type(matches) ~= "table" then
      return
    end

    local affect = normalize(matches[1])
    if affect ~= "" then
      currentAffects[affect] = true
      dbg("found affect: " .. affect)
    end
  end,
  { group = GROUP }
)

-- Accept magical-only, non-magical-only, and combined totals.
rune.trigger.regex(
  "^Total of .+affects?\\.$",
  function()
    if currentAffects then
      dbg("finished reading affects")
      showMissing()
      currentAffects = nil
    end
  end,
  { group = GROUP }
)

rune.alias.exact(NAME, command)
rune.alias.exact(SHORT, command)

loadSettings()
if enabled then
  rune.group.enable(GROUP)
else
  rune.group.disable(GROUP)
end

-- Single loader row.
say("v" .. VERSION .. " loaded (" .. NAME .. " for help)")
