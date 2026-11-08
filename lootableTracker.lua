-- Filename: eljayPlugins/lootableTracker.lua
-- Purpose: Track lootable reset times and show when items are ready again.
-- Version: 1.2
-- Date: 2026-Nov-07
--[[
Todo:
- Verify Rune GMCP and game-command API names against the installed client.
]]
-- Changelog:
--   1.2  Removed "list -i"; list always shows indexes.
--   1.1  Brought to standard: loader line, one regex alias, fresh-store
--        saves, lazy helpstyle, GMCP Room.Info handler, parse fixes.
--   1.0  Converted the lootable tracker to a Rune Lua plugin.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * Tracks the three Archon Boxes, Manuals Shelf, and Safe of Sin.
--   * Watches loot messages and records the next available time.
--   * Stores tracked lootables per character using charname.lua.
--
-- Commands (type without "/"):
--   lootableTracker  (alias: loot)
--   Commands
--     lootableTracker      show this help
--     loot on|off          enable / disable tracking triggers
--     loot debug on|off    enable / disable debug messages
--     loot list            show tracked lootables (with indexes)
--     loot add n:<name> z:<zone> r:<room> rn:<num>
--                          add a lootable
--     loot remove <index>  remove a lootable
--     loot rename <index> <name>
--                          rename a lootable
--     loot force <index> <unix time>
--                          set its next available time
--     loot offset <hours>  adjust parsed reset time
--     loot                 short alias for lootableTracker
--
-- Tweaks (top of file):
--   DEFAULT_OFFSET   hours added to the game's displayed reset time
--
local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME  = "lootableTracker"
local SHORT = "loot"

local VERSION = "1.2"
local DEFAULT_OFFSET = 1

local charname = require("charname")

local enabled = true
local debug_on = false
local lootables = {}
local offset = DEFAULT_OFFSET
local room_context = nil
local last_room = nil
local LOAD_MS = 0
local TRIGGERS = 2

local STORE_PREFIX = NAME .. ".settings"

local DEFAULT_LOOTABLES = {
  { name = "Archon Box", zone = "Lowangen",
    room = "Far End of the Dungeon", room_number = "16149" },
  { name = "Archon Box", zone = "Palace of Diocletian",
    room = "Exploring the Confusing Catacomb Passages",
    room_number = "29314" },
  { name = "Archon Box", zone = "Beneath A Trellis",
    room = "A Poorly-Concealed Cache", room_number = "80434" },
  { name = "Manuals Shelf", zone = "Genauras",
    room = "A Dirty House", room_number = "235989" },
  { name = "Safe of Sin", zone = "safe_of_sin_const",
    room = "", room_number = "" },
}

local function echo(text)
  rune.echo(text)
end

-- Cyan text via rune.style; plain text if the style API is missing.
local function paint(text)
  local s = rune.style
  if s then
    if s.cyan then
      local ok, r = pcall(s.cyan, text)
      if ok and r then return r end
    end
    if s.paint then
      local ok, r = pcall(s.paint, "cyan", text)
      if ok and r then return r end
    end
  end
  return text
end

-- Single-row message with the coloured plugin name prefix.
local function say(text)
  echo(paint("[" .. NAME .. "] ") .. text)
end

local function debug(text)
  if debug_on then
    say(text)
  end
end

local function copy_defaults()
  local result = {}
  for i, item in ipairs(DEFAULT_LOOTABLES) do
    result[i] = {
      name = item.name,
      zone = item.zone,
      room = item.room,
      room_number = item.room_number,
      next_available = nil,
    }
  end
  return result
end

-- Read the stored table fresh, let mutate() change it, save it back, then
-- refresh the in-memory copies. Returns true when the save worked.
local function save_settings(mutate)
  local name = charname.get()
  if not name or name == "" then
    say("Character name is not available yet; settings were not saved.")
    return false
  end

  local key = charname.key(STORE_PREFIX)
  local ok, fresh = pcall(rune.store.get, key)
  if not ok or type(fresh) ~= "table" then
    fresh = {}
  end

  mutate(fresh)
  if not pcall(rune.store.set, key, fresh) then
    say("Could not save loot tracker settings.")
    return false
  end

  if type(fresh.lootables) == "table" then
    lootables = fresh.lootables
  end
  offset = tonumber(fresh.offset) or DEFAULT_OFFSET
  enabled = fresh.enabled ~= false
  debug_on = fresh.debug == true
  return true
end

-- Change the stored lootable list (fresh copy) and refresh the cache.
local function save_lootables(change)
  return save_settings(function(data)
    if type(data.lootables) ~= "table" then
      data.lootables = copy_defaults()
    end
    change(data.lootables)
  end)
end

local function load_settings()
  local name = charname.get()
  if not name or name == "" then
    return
  end

  local ok, stored = pcall(rune.store.get, charname.key(STORE_PREFIX))
  if ok and type(stored) == "table" then
    lootables = type(stored.lootables) == "table"
      and stored.lootables or copy_defaults()
    offset = tonumber(stored.offset) or DEFAULT_OFFSET
    enabled = stored.enabled ~= false
    debug_on = stored.debug == true
  else
    lootables = copy_defaults()
    offset = DEFAULT_OFFSET
    enabled = true
    debug_on = false
  end
end

-- Keep client-specific GMCP access in this helper.
local function current_room()
  local info = last_room
  if not info and rune.gmcp and rune.gmcp.get then
    local ok, got = pcall(rune.gmcp.get, "room.info")
    if ok and type(got) == "table" then
      info = got
    end
  end
  if type(info) ~= "table" then
    return nil
  end
  return {
    zone = tostring(info.zone or ""),
    name = tostring(info.name or ""),
    number = tostring(info.num or info.number or ""),
  }
end

-- Keep client-specific game command sending in this helper.
local function send_game_command(command)
  if rune.send then
    rune.send(command)
  else
    say("Unable to send game command (Rune send API unavailable): "
      .. command)
  end
end

local function timer_string(timestamp)
  if not timestamp then
    return "no recorded time"
  end

  local diff = timestamp - os.time()
  if diff <= 0 then
    return "ready now"
  end

  return string.format("%d days, %02d hours, %02d minutes, %02d seconds",
    math.floor(diff / 86400), math.floor(diff / 3600) % 24,
    math.floor(diff / 60) % 60, diff % 60)
end

local function compact_timer(timestamp)
  if not timestamp then
    return "no recorded time"
  end

  local diff = timestamp - os.time()
  if diff <= 0 then
    return "ready now"
  end

  return string.format("%dd %02d:%02d:%02d",
    math.floor(diff / 86400), math.floor(diff / 3600) % 24,
    math.floor(diff / 60) % 60, diff % 60)
end

local MONTHS = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

-- Parses "Tue Oct 27 14:03:21 2026" and adds the offset in hours.
local function parse_game_time(text)
  local month_text, day, hour, minute, second, year =
    text:match("%a+ (%a+)%s+(%d+) (%d+):(%d+):(%d+) (%d+)")

  local month = MONTHS[month_text]
  if not (day and month and year) then
    return nil
  end

  local stamp = os.time({
    year = tonumber(year),
    month = month,
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
  })
  return stamp and (stamp + math.floor(offset * 3600)) or nil
end

local function show_list()
  if #lootables == 0 then
    say("No lootables are being tracked.")
    return
  end

  for i, item in ipairs(lootables) do
    local display_name = tostring(item.name)
      :gsub("^Archon Box%s*%-%s*", "")

    local place
    if item.zone == "safe_of_sin_const" then
      place = "Safe of Sin"
    else
      place = tostring(item.zone) .. " / " .. tostring(item.room)
    end

    echo(string.format("%d. %s - %s",
      i, paint(compact_timer(item.next_available)), display_name))
    echo("   " .. place)
  end
end

-- helpstyle is loaded on first use to keep load time low.
local function help()
  local ok, H = pcall(require, "helpstyle")
  if not ok or type(H) ~= "table" then
    echo(NAME .. "  (alias: " .. SHORT .. ")  - helpstyle unavailable")
    return
  end

  echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  echo(H.section("Commands"))
  echo(H.line(NAME, "show this help"))
  echo(H.line(SHORT .. " on|off", "enable / disable tracking triggers"))
  echo(H.line(SHORT .. " debug on|off", "enable / disable debug messages"))
  echo(H.line(SHORT .. " list", "show tracked lootables (with indexes)"))
  echo(H.line(SHORT .. " add n:<name> z:<zone> r:<room> rn:<num>",
    "add a lootable"))
  echo(H.line(SHORT .. " remove <index>", "remove a lootable"))
  echo(H.line(SHORT .. " rename <index> <name>", "rename a lootable"))
  echo(H.line(SHORT .. " force <index> <unix time>",
    "set its next available time"))
  echo(H.line(SHORT .. " offset <hours>", "adjust parsed reset time"))
  echo(H.line(SHORT, "short alias for " .. NAME))
  echo(H.foot(string.format("v%s  enabled=%s debug=%s  triggers=%d  load=%dms",
    VERSION, tostring(enabled), tostring(debug_on), TRIGGERS, LOAD_MS)))
end

local function valid_index(value)
  local index = tonumber(value)
  if not index or index < 1 or index > #lootables
    or index ~= math.floor(index) then
    return nil
  end
  return index
end

local function handle_command(args)
  args = (args or ""):match("^%s*(.-)%s*$")
  if args == "" then
    help()
    return
  end

  local action, rest = args:match("^(%S+)%s*(.-)$")
  action = (action or ""):lower()

  if action == "on" or action == "off" then
    local value = action == "on"
    save_settings(function(data)
      data.enabled = value
    end)
    enabled = value
    say("Tracking " .. (value and "enabled." or "disabled."))

  elseif action == "debug" then
    local setting = rest:lower()
    if setting ~= "on" and setting ~= "off" then
      say("Usage: " .. SHORT .. " debug on|off")
      return
    end
    local value = setting == "on"
    save_settings(function(data)
      data.debug = value
    end)
    debug_on = value
    say("Debug " .. setting .. ".")

  elseif action == "list" then
    show_list()

  elseif action == "offset" then
    local value = tonumber(rest)
    if not value then
      say("Usage: " .. SHORT .. " offset <hours>")
      return
    end
    save_settings(function(data)
      data.offset = value
    end)
    offset = value
    say("Loot time offset set to " .. tostring(value) .. " hours.")

  elseif action == "add" then
    local name, zone, room, room_number =
      rest:match("^n:(.-)%s+z:(.-)%s+r:(.-)%s+rn:(.-)$")
    if not name then
      say("Usage: " .. SHORT
        .. " add n:<name> z:<zone> r:<room> rn:<num>")
      return
    end
    if save_lootables(function(list)
      table.insert(list, {
        name = name,
        zone = zone,
        room = room,
        room_number = room_number,
        next_available = nil,
      })
    end) then
      say("Added lootable: " .. name)
    end

  elseif action == "remove" then
    local index = valid_index(rest)
    if not index then
      say("Invalid index; use '" .. SHORT .. " list'.")
      return
    end
    if save_lootables(function(list)
      table.remove(list, index)
    end) then
      say("Lootable removed.")
    end

  elseif action == "rename" then
    local number, new_name = rest:match("^(%d+)%s*(.-)$")
    local index = valid_index(number)
    if not index or new_name == "" then
      say("Usage: " .. SHORT .. " rename <index> <name>")
      return
    end
    if save_lootables(function(list)
      if list[index] then
        list[index].name = new_name
      end
    end) then
      say("Lootable renamed.")
    end

  elseif action == "force" then
    local number, value = rest:match("^(%d+)%s+(%d+)$")
    local index = valid_index(number)
    if not index or not value then
      say("Usage: " .. SHORT .. " force <index> <unix time>")
      return
    end
    if save_lootables(function(list)
      if list[index] then
        list[index].next_available = tonumber(value)
      end
    end) then
      say("Lootable time updated.")
    end

  else
    help()
  end
end

-- Index of the tracked lootable that belongs to this room, or nil.
local function match_item(room)
  for i, item in ipairs(lootables) do
    if item.room_number == room.number
      or (item.zone == "safe_of_sin_const"
        and room.number == room_context) then
      return i
    end
  end
  return nil
end

local function on_reset_time(line)
  if not enabled then
    return
  end

  local text = line:match("^You can loot this again at (.-)%.$")
  if not text then
    return
  end

  local timestamp = parse_game_time(text)
  if not timestamp then
    say("Could not parse loot reset time: " .. text)
    return
  end

  local room = current_room()
  local index = room and match_item(room)
  if not index then
    debug("Reset time received, but no tracked lootable matched the room.")
    return
  end

  local item = lootables[index]
  if save_lootables(function(list)
    if list[index] then
      list[index].next_available = timestamp
    end
  end) then
    say(item.name .. " can be looted again in "
      .. timer_string(timestamp) .. ".")
  end
end

local function on_loot_message(line)
  if not enabled then
    return
  end

  local container = line:match("^You gently pry (.-) out of (.-)%.$")
  if not container or container == "a lost wallet" then
    return
  end

  local room = current_room()
  if not room then
    debug("Loot message received, but the current room is unknown.")
    return
  end

  if container == "a safe belonging to the Commissioner of Sin" then
    room_context = room.number
  end

  if match_item(room) then
    send_game_command("take stuff '" .. (container:gsub("'", "")) .. "'")
    return
  end

  say("Untracked lootable: " .. container .. " (" .. room.zone .. ")")
  say("Add it with: " .. SHORT .. " add n:" .. container
    .. " z:" .. room.zone .. " r:" .. room.name .. " rn:" .. room.number)
end

load_settings()

-- One regex alias covers both the full command and the short alias.
rune.alias.regex("^(?:" .. NAME .. "|" .. SHORT .. ")(?:\\s+(.*))?$",
  function(matches)
    local args = ""
    if type(matches) == "table" then
      args = matches[2] or matches[1] or ""
    elseif type(matches) == "string" then
      args = matches
    end
    -- Drop the command word if the whole line was passed back.
    args = args:gsub("^%s*" .. NAME .. "%f[%s%z]", "")
      :gsub("^%s*" .. SHORT .. "%f[%s%z]", "")
    handle_command(args)
  end)

-- Use Rune's contains triggers; pass the cleaned incoming line to handlers.
rune.trigger.contains("You can loot this again at", function(matches, ctx)
  on_reset_time(ctx.line:clean())
end)

rune.trigger.contains("You gently pry ", function(matches, ctx)
  on_loot_message(ctx.line:clean())
end)

-- Track the current room from GMCP Room.Info (get() is only a fallback).
if rune.gmcp and rune.gmcp.on then
  if rune.gmcp.subscribe then
    pcall(rune.gmcp.subscribe, "Room")
  end
  pcall(rune.gmcp.on, "Room.Info", function(data)
    if type(data) == "table" then
      last_room = data
    end
  end, { name = NAME })
end

if charname.on_change then
  charname.on_change(function(_, new)
    if new and new ~= "" then
      pcall(load_settings)
    end
  end)
end

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

-- Loader line: single row, coloured plugin name prefix.
echo(paint("[" .. NAME .. "] ") .. "v" .. VERSION .. " loaded ("
  .. NAME .. " or " .. SHORT .. " for help)")