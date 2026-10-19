-- Filename: eljayPlugins/mapperShortCutKeys.lua
-- Purpose: Mapper shortcut aliases for common map locations, movement lookups, and the Iron Worm token hand-in.
-- Version: 2.8
-- Date: 2026-Oct-19
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
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
--   * One regex alias matches every shortcut name and routes it through lookup tables, so loading
--     registers a single alias however many shortcuts there are.
--   * Prefix shortcuts send a mapper command: mapf, mapg, mapb, mapw and mapi, plus fixed
--     "mapper goto <room id>" shortcuts for common towns and dungeons.
--   * wo handles the Iron Worm trip, purchase, and token hand-in.
--   * Shortcuts are kept in one table below, one row per alias, grouped by area.
--   * No triggers or network calls; enabled and debug settings are saved with rune.store.
--   * Settings and helpstyle are loaded on first use, not at startup.
--   * Commands are typed without a / prefix. mapperShortCutKeys and maps show this help.
--   * When shortcuts are off, the aliases say so and send nothing.
--
-- Commands (maps works in place of mapperShortCutKeys):
--   mapperShortCutKeys / maps             show this summary
--   mapperShortCutKeys on|off             enable or disable all shortcut aliases
--   mapperShortCutKeys debug on|off       enable or disable debug messages
--   mapf / mapg / mapb / mapw <text>      mapper nearby / goto / bookmark goto / where
--   mapi                                  mapper roominfo
--   wo <item>                             Iron Worm purchase and token hand-in
--   r0-r9, s0-s2, m0-m3, ...              mapper goto fixed rooms

local LOAD_START = os.clock()

local VERSION      = "2.8"
local NAME         = "mapperShortCutKeys"
local PREFIX       = "[" .. NAME .. "] "
local SETTINGS_KEY = "mapperShortCutKeys.settings"
local IRON_WORM    = 10636

local ANSI_CYAN  = "\27[36m"
local ANSI_RESET = "\27[0m"

local enabled         = true
local debug_enabled   = false
local settings_loaded = false
local load_ms         = 0
local prefix_text     = nil
local H               = nil
local helpstyle_tried = false

-- Shortcut data: alias = room id ------------------------------------------------
local GOTO = {
  -- Dungeon Deceit teleports
  dece1 = 17138,   -- first teleport
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

-- Prefix shortcuts: "<alias> <text>" sends "<command> <text>".
local PREFIXES = {
  mapf = "mapper nearby ",
  mapg = "mapper goto ",
  mapb = "mapper bookmark goto ",
  mapw = "mapper where ",
}

-- Fixed shortcuts: "<alias>" sends the command as is.
local FIXED = {
  mapi = "mapper roominfo",
}

-- Output helpers ----------------------------------------------------------------

-- Cyan "[name] " prefix, resolved once: rune.style.cyan, then rune.style("cyan", ...),
-- then a plain ANSI escape.
local function paint(message)
  if not prefix_text then
    local style = rune and rune.style

    if type(style) == "table" and type(style.cyan) == "function" then
      local ok, text = pcall(style.cyan, PREFIX)
      if ok and type(text) == "string" then
        prefix_text = text
      end
    elseif type(style) == "function" then
      local ok, text = pcall(style, "cyan", PREFIX)
      if ok and type(text) == "string" then
        prefix_text = text
      end
    end

    prefix_text = prefix_text or (ANSI_CYAN .. PREFIX .. ANSI_RESET)
  end

  return prefix_text .. tostring(message)
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

local function emit(text)
  if text ~= nil then
    rune.echo(text)
  end
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Settings (read on first use, written only when changed) --------------------------

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

local function send(command)
  dbg("send: " .. command)
  rune.send(command)
end

-- Help ---------------------------------------------------------------------------

local alias_count = 0

local function show_help()
  if not helpstyle_tried then
    helpstyle_tried = true
    local ok, module = pcall(require, "helpstyle")
    if ok then
      H = module
    end
  end

  local status = string.format(
    "v%s  enabled=%s debug=%s aliases=%d load=%dms",
    VERSION,
    onoff(enabled),
    onoff(debug_enabled),
    alias_count,
    load_ms
  )

  local styled = H
    and type(H.title) == "function"
    and type(H.section) == "function"
    and type(H.line) == "function"
    and type(H.foot) == "function"

  if styled then
    local ok = pcall(function()
      emit(H.title("Mapper shortcut keys"))
      emit(H.section("Commands"))
      emit(H.line("mapperShortCutKeys / maps", "show this summary"))
      emit(H.line("mapperShortCutKeys on|off", "enable or disable all shortcut aliases"))
      emit(H.line("mapperShortCutKeys debug on|off", "enable or disable debug messages"))
      emit(H.section("Usage"))
      emit(H.line("mapf / mapg / mapb / mapw <text>", "mapper nearby / goto / bookmark goto / where"))
      emit(H.line("mapi", "mapper roominfo"))
      emit(H.line("wo <item>", "Iron Worm purchase and token hand-in"))
      emit(H.line("r0-r9, s0-s2, m0-m3, ...", "mapper goto fixed rooms"))
      emit(H.foot(status))
    end)

    if ok then
      return
    end
  end

  rune.echo("Mapper shortcut keys")
  rune.echo("  mapperShortCutKeys / maps        show this summary")
  rune.echo("  mapperShortCutKeys on|off        enable or disable all shortcut aliases")
  rune.echo("  mapperShortCutKeys debug on|off  enable or disable debug messages")
  rune.echo("  mapf / mapg / mapb / mapw <text> mapper nearby / goto / bookmark goto / where")
  rune.echo("  mapi                             mapper roominfo")
  rune.echo("  wo <item>                        Iron Worm purchase and token hand-in")
  rune.echo("  r0-r9, s0-s2, m0-m3, ...         mapper goto fixed rooms")
  rune.echo(status)
end

-- Command handling ------------------------------------------------------------------

local function msk_command(args)
  local text    = trim(args):lower()
  local command = text:match("^(%S*)") or ""
  local value   = text:match("^%S+%s*(.*)$") or ""

  if command == "on" or command == "off" then
    enabled = (command == "on")
    save_settings()
    say("shortcuts are " .. onoff(enabled))
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
    say("debug is " .. onoff(debug_enabled))
    return
  end

  show_help()
end

-- Iron Worm: go there, buy the requested item, go down, hand in the token.
local function iron_worm(args)
  local item = trim(args)

  if item == "" then
    say("usage: wo <item>")
    return
  end

  -- Prevent command chaining and control characters (%c covers CR, LF and NUL).
  if item:find("[;%c]") then
    say("item text cannot contain semicolons or control characters")
    return
  end

  send("mapper goto " .. IRON_WORM .. "; shop buy " .. item .. "; down; give token ganuk")
end

-- Dispatcher --------------------------------------------------------------------------

local function dispatch(matches)
  local name = matches[1]
  local args = matches[2] or ""

  load_settings()

  if name == NAME or name == "maps" then
    msk_command(args)
    return
  end

  if not enabled then
    say("shortcuts are off (mapperShortCutKeys on to enable)")
    return
  end

  local room = GOTO[name]
  if room then
    send("mapper goto " .. room)
    return
  end

  local prefix = PREFIXES[name]
  if prefix then
    send(prefix .. trim(args))
    return
  end

  local fixed = FIXED[name]
  if fixed then
    send(fixed)
    return
  end

  if name == "wo" then
    iron_worm(args)
  end
end

-- Registration: one regex alias for every name (bare commands are aliases;
-- rune.command.add would create /slash commands).
local names = { NAME, "maps", "wo" }

for alias in pairs(GOTO) do
  names[#names + 1] = alias
  alias_count = alias_count + 1
end

for alias in pairs(PREFIXES) do
  names[#names + 1] = alias
  alias_count = alias_count + 1
end

for alias in pairs(FIXED) do
  names[#names + 1] = alias
  alias_count = alias_count + 1
end

alias_count = alias_count + 1  -- wo

rune.alias.regex("^(" .. table.concat(names, "|") .. ")( .*)?$", dispatch, { name = NAME })

-- Capture load duration after registration; settings and helpstyle load on first use.
load_ms = math.floor((os.clock() - LOAD_START) * 1000 + 0.5)

say("v" .. VERSION .. " loaded (mapperShortCutKeys or maps for help)")