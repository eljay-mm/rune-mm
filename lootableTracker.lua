-- Filename: eljayPlugins/lootableTracker.lua
-- Purpose: Track lootable reset times and show when items are ready again.
-- Version: 1.0
-- Date: 2026-Oct-27
--[[
TODO:
- Verify Rune GMCP and game-command API names against the installed client.
]]
-- Changelog:
--   1.0  Converted the lootable tracker to a Rune Lua plugin.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * Tracks the three Archon Boxes, Manuals Shelf, and Safe of Sin.
--   * Watches loot messages and records the next available time.
--   * Stores tracked lootables per character using charname.lua.
--
-- Commands (type without "/"):
--   lootableTracker             show this help
--   loot on|off                 enable / disable tracking triggers
--   loot debug on|off           enable / disable debug messages
--   loot list                   show tracked lootables
--   loot list -i                show indexes for editing
--   loot add n:<name> z:<zone> r:<room> rn:<room number>
--                               add a lootable
--   loot remove <index>         remove a lootable
--   loot rename <index> [name]  rename a lootable
--   loot force <index> <time>   set its next available time
--   loot offset <hours>         adjust parsed reset time
--   loot                       short alias for lootableTracker
--
-- Tweaks (top of file):
--   DEFAULT_OFFSET   hours added to the game's displayed reset time
--
local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME  = "lootableTracker"
local SHORT = "loot"

local VERSION = "1.0"
local DEFAULT_OFFSET = 1

local H = require("helpstyle")
local charname = require("charname")

local enabled = true
local debug_on = false
local lootables = {}
local offset = DEFAULT_OFFSET
local room_context = nil
local LOAD_MS = 0

local STORE_PREFIX = NAME .. ".settings"

local DEFAULT_LOOTABLES = {
  {
    name = "Archon Box",
    zone = "Lowangen",
    room = "Far End of the Dungeon",
    room_number = "16149",
  },
  {
    name = "Archon Box",
    zone = "Palace of Diocletian",
    room = "Exploring the Confusing Catacomb Passages",
    room_number = "29314",
  },
  {
    name = "Archon Box",
    zone = "Beneath A Trellis",
    room = "A Poorly-Concealed Cache",
    room_number = "80434",
  },
  {
    name = "Manuals Shelf",
    zone = "Genauras",
    room = "A Dirty House",
    room_number = "235989",
  },
  {
    name = "Safe of Sin",
    zone = "safe_of_sin_const",
    room = "",
    room_number = "",
  },
}

local function echo(text)
  rune.echo(text)
end

local function debug(text)
  if debug_on then
    echo("[" .. NAME .. "] " .. text)
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

local function save_settings(mutate)
  local name = charname.get()
  if not name or name == "" then
    echo("Character name is not available yet; settings were not saved.")
    return false
  end

  local key = charname.key(STORE_PREFIX)
  local ok, fresh = pcall(rune.store.get, key)
  if not ok or type(fresh) ~= "table" then
    fresh = {}
  end

  mutate(fresh)
  local saved = pcall(rune.store.set, key, fresh)
  if not saved then
    echo("Could not save loot tracker settings.")
    return false
  end

  lootables = type(fresh.lootables) == "table" and fresh.lootables or lootables
  offset = tonumber(fresh.offset) or DEFAULT_OFFSET
  enabled = fresh.enabled ~= false
  debug_on = fresh.debug == true
  return true
end

local function load_settings()
  local name = charname.get()
  if not name or name == "" then
    return
  end

  local key = charname.key(STORE_PREFIX)
  local ok, stored = pcall(rune.store.get, key)
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
  if rune.gmcp and rune.gmcp.get then
    local ok, info = pcall(rune.gmcp.get, "room.info")
    if ok and type(info) == "table" then
      return {
        zone = tostring(info.zone or ""),
        name = tostring(info.name or ""),
        number = tostring(info.num or info.number or ""),
      }
    end
  end
  return nil
end

-- Keep client-specific game command sending in this helper.
local function send_game_command(command)
  if rune.send then
    rune.send(command)
  else
    echo("Unable to send game command (Rune send API unavailable): " .. command)
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

  local days = math.floor(diff / 86400)
  local hours = math.floor(diff / 3600) % 24
  local minutes = math.floor(diff / 60) % 60
  local seconds = diff % 60
  return string.format("%d days, %02d hours, %02d minutes, %02d seconds",
    days, hours, minutes, seconds)
end

local function compact_timer(timestamp)
  if not timestamp then
    return "no recorded time"
  end

  local diff = timestamp - os.time()
  if diff <= 0 then
    return "ready now"
  end

  local days = math.floor(diff / 86400)
  local hours = math.floor(diff / 3600) % 24
  local minutes = math.floor(diff / 60) % 60
  local seconds = diff % 60

  return string.format("%dd %02d:%02d:%02d",
    days, hours, minutes, seconds)
end

local function cyan(text)
  if rune.style and rune.style.paint then
    return rune.style.paint("cyan", text)
  end
  return text
end

local function parse_game_time(text)
  local day, month_text, hour, minute, second, year =
    text:match("%a+ (%a+) (%d+) (%d+):(%d+):(%d+) (%d+)")

  local months = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
  }
  local month = months[month_text]
  if not (day and month and year) then
    return nil
  end

  return os.time({
    year = tonumber(year),
    month = month,
    day = tonumber(day),
    hour = (tonumber(hour) + offset) % 24,
    min = tonumber(minute),
    sec = tonumber(second),
  })
end

local function show_list(indexes)
  if #lootables == 0 then
    echo("No lootables are being tracked.")
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

    echo(string.format("%d. %s — %s",
      i, cyan(compact_timer(item.next_available)), display_name))
    echo("   " .. place)
  end

  if not indexes then
    echo("Use '" .. SHORT .. " list -i' to see indexes for rename/remove.")
  end
end

local function help()
  echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  echo(H.section("Commands"))
  echo(H.line(NAME, "show this help"))
  echo(H.line(SHORT .. " on|off", "enable / disable tracking triggers"))
  echo(H.line(SHORT .. " debug on|off", "enable / disable debug messages"))
  echo(H.line(SHORT .. " list", "show tracked lootables"))
  echo(H.line(SHORT .. " list -i", "show indexes for editing"))
  echo(H.line(SHORT .. " add n:<name> z:<zone> r:<room> rn:<number>",
    "add a lootable"))
  echo(H.line(SHORT .. " remove <index>", "remove a lootable"))
  echo(H.line(SHORT .. " rename <index> [name]", "rename a lootable"))
  echo(H.line(SHORT .. " force <index> <time>", "set its next available time"))
  echo(H.line(SHORT .. " offset <hours>", "adjust parsed reset time"))
  echo(H.line(SHORT, "short alias for " .. NAME))
  echo(H.foot(string.format("v%s  enabled=%s debug=%s  triggers=%d  load=%dms",
    VERSION, tostring(enabled), tostring(debug_on), 2, LOAD_MS)))
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
    echo(NAME .. " tracking " .. (value and "enabled." or "disabled."))

  elseif action == "debug" then
    local setting = rest:lower()
    if setting ~= "on" and setting ~= "off" then
      echo("Usage: " .. SHORT .. " debug on|off")
      return
    end
    debug_on = setting == "on"
    save_settings(function(data)
      data.debug = debug_on
    end)
    echo(NAME .. " debug " .. setting .. ".")

  elseif action == "list" then
    show_list(rest == "-i")

  elseif action == "offset" then
    local value = tonumber(rest)
    if not value then
      echo("Usage: " .. SHORT .. " offset <hours>")
      return
    end
    offset = value
    save_settings(function(data)
      data.offset = value
    end)
    echo("Loot time offset set to " .. tostring(value) .. " hours.")

  elseif action == "add" then
    local name, zone, room, room_number =
      rest:match("^n:(.-)%s+z:(.-)%s+r:(.-)%s+rn:(.-)$")
    if not name then
      echo("Usage: " .. SHORT .. " add n:<name> z:<zone> r:<room> rn:<number>")
      return
    end
    table.insert(lootables, {
      name = name,
      zone = zone,
      room = room,
      room_number = room_number,
      next_available = nil,
    })
    save_settings(function(data)
      data.lootables = lootables
    end)
    echo("Added lootable: " .. name)

  elseif action == "remove" then
    local index = valid_index(rest)
    if not index then
      echo("Invalid index; use '" .. SHORT .. " list -i'.")
      return
    end
    table.remove(lootables, index)
    save_settings(function(data)
      data.lootables = lootables
    end)
    echo("Lootable removed.")

  elseif action == "rename" then
    local number, new_name = rest:match("^(%d+)%s*(.-)$")
    local index = valid_index(number)
    if not index or new_name == "" then
      echo("Usage: " .. SHORT .. " rename <index> <new name>")
      return
    end
    lootables[index].name = new_name
    save_settings(function(data)
      data.lootables = lootables
    end)
    echo("Lootable renamed.")

  elseif action == "force" then
    local number, value = rest:match("^(%d+)%s+(%d+)$")
    local index = valid_index(number)
    if not index or not value then
      echo("Usage: " .. SHORT .. " force <index> <unix timestamp>")
      return
    end
    lootables[index].next_available = tonumber(value)
    save_settings(function(data)
      data.lootables = lootables
    end)
    echo("Lootable time updated.")

  else
    help()
  end
end

local function on_reset_time(line)
  if not enabled then
    return
  end

  local text = line:match("^You can loot this again at (.-)%.$")
  if not text then
    return
  end

  local room = current_room()
  local timestamp = parse_game_time(text)
  if not timestamp then
    echo("Could not parse loot reset time: " .. text)
    return
  end

  if room then
    for _, item in ipairs(lootables) do
      if item.room_number == room.number
        or (item.zone == "safe_of_sin_const"
          and room.number == room_context) then
        item.next_available = timestamp
        save_settings(function(data)
          data.lootables = lootables
        end)
        echo(item.name .. " can be looted again in "
          .. timer_string(timestamp) .. ".")
        return
      end
    end
  end

  debug("Reset time received, but no tracked lootable matched the current room.")
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
  if container == "a safe belonging to the Commissioner of Sin" then
    room_context = room and room.number or nil
  end

  if room then
    for _, item in ipairs(lootables) do
      if item.room_number == room.number
        or (item.zone == "safe_of_sin_const" and room_context == room.number) then
        send_game_command("take stuff '" .. container:gsub("'", "") .. "'")
        return
      end
    end

    echo("Untracked lootable: " .. container .. " (" .. room.zone .. ")")
    echo("Add it with: " .. SHORT .. " add n:" .. container
      .. " z:" .. room.zone .. " r:" .. room.name .. " rn:" .. room.number)
  end
end

load_settings()
LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

rune.alias.exact(NAME, function(args)
  handle_command(args)
end)

rune.alias.exact(SHORT, function(args)
  handle_command(args)
end)

-- Use Rune's contains triggers; pass the cleaned incoming line to handlers.
rune.trigger.contains("You can loot this again at", function(matches, ctx)
  on_reset_time(ctx.line:clean())
end)

rune.trigger.contains("You gently pry ", function(matches, ctx)
  on_loot_message(ctx.line:clean())
end)

if charname.on_change then
  charname.on_change(function(_, new)
    if new and new ~= "" then
      pcall(load_settings)
    end
  end)
end

local function load_message(text)
  if rune.style and rune.style.paint and rune.say then
    rune.say(rune.style.paint("cyan", "[" .. NAME .. "] ") .. text)
  else
    echo("[" .. NAME .. "] " .. text)
  end
end

load_message("v" .. VERSION .. " loaded (" .. SHORT .. " for help)")
