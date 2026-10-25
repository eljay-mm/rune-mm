-- Filename: eljayPlugins/mapperShortKeys.lua
-- Purpose: Mapper shortcut aliases for common locations and the Iron Worm hand-in.
-- Version: 2.11
-- Date: 2026-Oct-25
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.11 Add available shortcut comments to the list output.
--   2.10 Add a list command that displays registered aliases in cyan.
--   2.9  Use exact bare-command aliases without the ignored name option.
--   2.8  Load time: one regex dispatcher alias replaces about 40 rune.alias.exact registrations
--        (each cost roughly 0.8ms); helpstyle and saved settings load on first use. Fixed the Iron
--        Worm input check, where %z could reject any item containing the letter z.
--   2.7  Persist debug state, report measured load time, complete the header, and validate Iron Worm input.
--   2.6  Rebuilt display and commands on the working annwnQuestSearch pattern.
--   2.5  Added output helper with fallbacks (superseded by 2.6).
--   2.4  Separated bare and argument aliases (superseded by 2.6).
--   2.3  Added loader line, help, toggles, table-driven shortcuts, and short alias maps.
--   2.2  Added repo-standard header and help sections.
--   2.1  Original alias conversion from XML; no dependencies.
--
-- How it works:
--   * Exact bare-command aliases route mapper shortcuts through lookup tables.
--   * Prefix shortcuts send mapper commands; fixed shortcuts go to saved room IDs.
--   * wo handles the Iron Worm trip, purchase, and token hand-in.
--   * msk list displays all registered aliases and their meanings.
--   * Shortcuts are kept in one table below, grouped by area.
--   * No triggers or network calls; enabled and debug settings use rune.store.
--   * Settings and helpstyle are loaded on first use, not at startup.
--   * Commands are typed without a / prefix. mapperShortKeys and msk show help.
--   * When shortcuts are off, mapper shortcuts say so and send nothing.
--
-- Commands (type without "/"; "msk" is a short alias for "mapperShortKeys"):
--   mapperShortKeys / msk       show this help
--   msk list                    display all registered aliases and their meanings
--   msk on|off                  enable / disable shortcut aliases
--   msk debug on|off            enable / disable debug messages
--   mapf/mapg/mapb/mapw <text>  mapper nearby / goto / bookmark / where
--   mapi                        mapper roominfo
--   wo <item>                   Iron Worm purchase and token hand-in
--   room aliases                mapper goto fixed rooms
--
-- Tweaks:
--   * IRON_WORM   Room ID used by the Iron Worm shortcut

-- Command names: full command and short alias.
local NAME  = "mapperShortKeys"
local SHORT = "msk"

local LOAD_STARTED = os.clock()

local VERSION      = "2.11"
local SETTINGS_KEY = "mapperShortKeys.settings"
local IRON_WORM    = 10636

local enabled         = true
local debug_on        = false
local settings_loaded = false
local load_ms         = 0
local alias_count     = 0
local registered      = {}
local H               = nil
local helpstyle_tried = false

local function cyan(text)
  local style = rune and rune.style

  if type(style) == "table" and type(style.cyan) == "function" then
    local ok, colored = pcall(style.cyan, text)
    if ok and type(colored) == "string" then
      return colored
    end
  elseif type(style) == "function" then
    local ok, colored = pcall(style, "cyan", text)
    if ok and type(colored) == "string" then
      return colored
    end
  end

  return "\27[36m" .. text .. "\27[0m"
end

local function say(message)
  local prefix = cyan("[" .. NAME .. "] ")
  if not pcall(rune.echo, prefix .. tostring(message)) then
    print("[" .. NAME .. "] " .. tostring(message))
  end
end

local function dbg(message)
  if debug_on then
    say(message)
  end
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function onoff(flag)
  return flag and "on" or "off"
end

-- Shortcut data: alias = room ID.
local GOTO = {
  -- Dungeon Deceit teleports
  dece1 = 17038,   -- first teleport - move west to dizzy
  dece2 = 17212,   -- second teleport
  -- Hellbent
  hbrex = 106523,  -- just outside t-rex
  hbtri = 106364,  -- triceratops
  -- Lowangen
  low1  = 16133,   -- king
  low5  = 16149,   -- lootable
  -- Maldra's Keep
  m0    = 3573738, -- safe outside
  m1    = 67947,   -- QM
  m3    = 68084,
  -- Pirate's Cove
  pc0   = 29942,   -- healer/recall
  pcw   = 3304508, -- west gate
  -- Decara
  d0    = 116022,  -- healer/recall
  -- Rune
  r0    = 10439,   -- healer/recall
  r1    = 31323,   -- QM
  r2    = 10727,   -- clanmaster
  r3    = 10636,   -- iron worm
  r4    = 10560,   -- post office
  r5    = 10407,   -- crystal guild
  r6    = 81734,   -- condos
  r7    = 10554,   -- reagents
  r8    = 15252,   -- foucault's near blarg
  r9    = 10638,   -- lottery
  rw    = 2809518, -- west gate
  -- Sigil
  s0    = 28035,   -- healer/recall
  s1    = 28450,   -- QM
  s2    = 28509,   -- clanmaster
  -- Templeton
  t5    = 46434,
  -- Vospire
  v1    = 40221,   -- king
}

-- Descriptions copied from the GOTO comments above.
-- Aliases without a comment use their room ID in the list output.
local GOTO_MEANINGS = {
  dece1 = "first teleport - move west to dizzy",
  dece2 = "second teleport",
  hbrex = "just outside t-rex",
  hbtri = "triceratops",
  low1  = "king",
  low5  = "lootable",
  m0    = "safe outside",
  m1    = "QM",
  pc0   = "healer/recall",
  pcw   = "west gate",
  d0    = "healer/recall",
  r0    = "healer/recall",
  r1    = "QM",
  r2    = "clanmaster",
  r3    = "iron worm",
  r4    = "post office",
  r5    = "crystal guild",
  r6    = "condos",
  r7    = "reagents",
  r8    = "foucault's near blarg",
  r9    = "lottery",
  rw    = "west gate",
  s0    = "healer/recall",
  s1    = "QM",
  s2    = "clanmaster",
  v1    = "king",
}

-- Prefix shortcuts: "<alias> <text>" sends "<command> <text>".
local PREFIXES = {
  mapf = "mapper nearby ",
  mapg = "mapper goto ",
  mapb = "mapper bookmark goto ",
  mapw = "mapper where ",
}

-- Fixed shortcuts: "<alias>" sends the command as-is.
local FIXED = {
  mapi = "mapper roominfo",
}

local function load_settings()
  if settings_loaded then
    return
  end
  settings_loaded = true

  if not (rune and rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then
      enabled = saved.enabled
    end
    if type(saved.debug) == "boolean" then
      debug_on = saved.debug
    end
  end
end

local function update_settings(mutate)
  local fresh = {}

  if rune and rune.store and type(rune.store.get) == "function" then
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if ok and type(saved) == "table" then
      fresh = saved
    end
  end

  mutate(fresh)

  if rune and rune.store and type(rune.store.set) == "function" then
    pcall(rune.store.set, SETTINGS_KEY, fresh)
  end

  if type(fresh.enabled) == "boolean" then
    enabled = fresh.enabled
  end
  if type(fresh.debug) == "boolean" then
    debug_on = fresh.debug
  end
  settings_loaded = true
end

local function send(command)
  dbg("send: " .. command)
  rune.send(command)
end

local function emit(text)
  if text ~= nil then
    rune.echo(text)
  end
end

local function alias_meaning(alias)
  if alias == NAME then
    return "show plugin help and status"
  elseif alias == SHORT then
    return "short command for plugin help and settings"
  elseif alias == "wo" then
    return "Iron Worm purchase and token hand-in"
  end

  local prefix = PREFIXES[alias]
  if prefix then
    return "send " .. trim(prefix) .. " <text>"
  end

  local fixed = FIXED[alias]
  if fixed then
    return "send " .. fixed
  end

  local room = GOTO[alias]
  if room then
    local meaning = GOTO_MEANINGS[alias]
    if meaning then
      return "mapper goto room " .. tostring(room) .. " (" .. meaning .. ")"
    end
    return "mapper goto room " .. tostring(room)
  end

  return "shortcut alias"
end

local function show_aliases()
  local aliases = {}
  for _, alias in ipairs(registered) do
    aliases[#aliases + 1] = alias
  end
  table.sort(aliases)

  rune.echo(cyan("Registered aliases") .. " (" .. #aliases .. ")")
  for _, alias in ipairs(aliases) do
    rune.echo(cyan(alias) .. " — " .. alias_meaning(alias))
  end
end

local function show_help()
  if not helpstyle_tried then
    helpstyle_tried = true
    local ok, module = pcall(require, "helpstyle")
    if ok then
      H = module
    end
  end

  local status = string.format(
    "v%s  enabled=%s debug=%s aliases=%d  load=%dms",
    VERSION, tostring(enabled), tostring(debug_on), alias_count, load_ms
  )

  local styled = H
    and type(H.title) == "function"
    and type(H.section) == "function"
    and type(H.line) == "function"
    and type(H.foot) == "function"

  if styled then
    local ok = pcall(function()
      emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
      emit(H.section("Commands"))
      emit(H.line(NAME, "show this help"))
      emit(H.line(SHORT .. " list", "display all registered aliases and their meanings"))
      emit(H.line(SHORT .. " on|off", "enable / disable shortcut aliases"))
      emit(H.line(SHORT .. " debug on|off", "enable / disable debug messages"))
      emit(H.section("Shortcuts"))
      emit(H.line("mapf/mapg/mapb/mapw <text>", "mapper nearby / goto / bookmark / where"))
      emit(H.line("mapi", "mapper roominfo"))
      emit(H.line("wo <item>", "Iron Worm purchase and token hand-in"))
      emit(H.line("room aliases", "mapper goto fixed rooms (r0, r1, r2 ...)"))
      emit(H.line(SHORT, "short alias for " .. NAME))
      emit(H.foot(status))
    end)

    if ok then
      return
    end
  end

  rune.echo(NAME .. "  (alias: " .. SHORT .. ")")
  rune.echo(SHORT .. " list                   display all registered aliases and their meanings")
  rune.echo(SHORT .. " on|off                 enable / disable shortcuts")
  rune.echo(SHORT .. " debug on|off           enable / disable debug")
  rune.echo("mapf/mapg/mapb/mapw <text>  mapper commands")
  rune.echo("mapi                     mapper roominfo")
  rune.echo("wo <item>                Iron Worm hand-in")
  rune.echo("room aliases             mapper goto fixed rooms")
  rune.echo(SHORT .. "                      short alias for " .. NAME)
  rune.echo(status)
end

local function handle_command(args)
  local text = trim(args):lower()
  local command = text:match("^(%S*)") or ""
  local value = text:match("^%S+%s*(.*)$") or ""

  if command == "list" and value == "" then
    show_aliases()
    return
  end

  if command == "on" or command == "off" then
    local value_on = command == "on"
    update_settings(function(settings)
      settings.enabled = value_on
    end)
    say("shortcuts are " .. onoff(enabled))
    return
  end

  if command == "debug" then
    if value ~= "on" and value ~= "off" then
      show_help()
      return
    end

    local value_on = value == "on"
    update_settings(function(settings)
      settings.debug = value_on
    end)
    say("debug is " .. onoff(debug_on))
    return
  end

  show_help()
end

local function iron_worm(args)
  local item = trim(args)

  if item == "" then
    say("usage: wo <item>")
    return
  end

  -- Reject command separators and control characters in the input.
  if item:find("[;%c]") then
    say("item text cannot contain semicolons or control characters")
    return
  end

  send("mapper goto " .. IRON_WORM .. "; shop buy " .. item ..
       "; down; give token ganuk")
end

local function handler(alias)
  return function(args, _ctx)
    load_settings()
    args = trim(args)

    if alias == NAME or alias == SHORT then
      handle_command(args)
      return
    end

    if not enabled then
      say("shortcuts are off (" .. SHORT .. " on to enable)")
      return
    end

    local room = GOTO[alias]
    if room then
      send("mapper goto " .. room)
      return
    end

    local prefix = PREFIXES[alias]
    if prefix then
      send(prefix .. args)
      return
    end

    local fixed = FIXED[alias]
    if fixed then
      send(fixed)
      return
    end

    if alias == "wo" then
      iron_worm(args)
    end
  end
end

local function register(alias)
  -- Exact aliases take the phrase and callback; do not pass a name option.
  rune.alias.exact(alias, handler(alias))
  registered[#registered + 1] = alias
  alias_count = alias_count + 1
end

register(NAME)
register(SHORT)
register("wo")

for alias in pairs(GOTO) do
  register(alias)
end

for alias in pairs(PREFIXES) do
  register(alias)
end

for alias in pairs(FIXED) do
  register(alias)
end

load_ms = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

rune.echo(cyan("[" .. NAME .. "] ") ..
  string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
