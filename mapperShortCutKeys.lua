-- Filename: eljayPlugins/mapperShortCutKeys.lua
-- Purpose: Mapper shortcut aliases for common map locations and movement lookups.
-- Version: 2.3
-- Date: 2026-Oct-16
-- Changelog:
--   2.3  Standard pass: loader line, help via helpstyle, on/off toggle (persisted), debug toggle,
--        table-driven shortcuts, duplicate r4 removed (post office kept), short alias maps.
--   2.2  House-style pass: repo-standard header, "How it works" and "Commands" sections.
--   2.1  Original alias conversion from XML, no dependencies.
--
-- How it works:
--   * Registers short aliases that send mapper commands: mapf/mapg/mapb/mapw/mapi, plus
--     fixed "mapper goto <room id>" shortcuts for common towns and dungeons (r0, s1, hbrex, ...).
--   * Shortcuts are kept in one table below, one row per alias, grouped by area.
--   * No parsing, no triggers, no network calls; the only state is the on/off flag,
--     which is saved in rune.store.
--   * When shortcuts are off, the aliases report that and send nothing.
--
-- Commands:
--   mapperShortCutKeys           show help
--   maps                         short alias for mapperShortCutKeys
--   maps on|off                  enable or disable all shortcut aliases
--   maps debug on|off            show each command sent (default off)

local NAME    = "mapperShortCutKeys"
local VERSION = "2.3"
local DEBUG   = false
local enabled = true

local STORE_KEY = NAME .. ".enabled"

-- Output helpers -------------------------------------------------------------

local function cyan(s)
  local ok, r = pcall(function() return rune.style.cyan(s) end)
  if ok and r then return r end
  return s
end

local function say(msg) rune.echo(cyan("[" .. NAME .. "] ") .. msg) end
local function dbg(msg) if DEBUG then say("debug: " .. msg) end end

local function send(cmd)
  dbg("send: " .. cmd)
  rune.send(cmd)
end

-- Persistence (guarded: a store failure never breaks the plugin) -------------

local function load_enabled()
  local ok, v = pcall(function() return rune.store.get(STORE_KEY) end)
  if ok and v ~= nil then return v == true or v == "true" end
  return true
end

local function save_enabled()
  pcall(function() rune.store.set(STORE_KEY, enabled) end)
end

enabled = load_enabled()

-- Wrap a handler so it only runs while shortcuts are on
local function guard(fn)
  return function(m)
    if not enabled then
      say("shortcuts are off (type 'maps on')")
      return
    end
    fn(m or {})
  end
end

-- Shortcut data ----------------------------------------------------------------
-- { alias, room id, note }

local SHORTCUTS = {
  -- Dungeon Deceit teleports
  { "dece1", 17138,   "first teleport" },
  { "dece2", 17212,   "second teleport" },
  -- Hellbent
  { "hbrex", 106523,  "just outside t-rex" },
  { "hbtri", 106364,  "triceratops" },
  -- Lowangen
  { "low1",  16133,   "king" },
  { "low5",  16149,   "lootable" },
  -- Maldra's Keep
  { "m0",    3573738, "safe outside" },
  { "m1",    67947,   "QM" },
  { "m3",    68084,   "" },
  -- Pirate's Cove
  { "pc0",   29942,   "healer/recall" },
  { "pcw",   3304508, "west gate" },
  -- Decara
  { "d0",    116022,  "healer/recall" },
  -- Rune
  { "r0",    10439,   "healer/recall" },
  { "r1",    31323,   "QM" },
  { "r2",    10727,   "clanmaster" },
  { "r3",    10636,   "iron worm" },
  { "r4",    10560,   "post office" },
  { "r5",    10407,   "crystal guild" },
  { "r6",    81734,   "condos" },
  { "r7",    10554,   "reagents" },
  { "r8",    15252,   "foucault's near blarg" },
  { "r9",    10638,   "lottery" },
  { "rw",    2809518, "west gate" },
  -- Sigil
  { "s0",    28035,   "healer/recall" },
  { "s1",    28450,   "QM" },
  { "s2",    28509,   "clanmaster" },
  -- Templeton
  { "t5",    46434,   "" },
  -- Vospire
  { "v1",    40221,   "king" },
}

-- Prefix aliases: "<alias> <args>" -> "<mapper command> <args>"
local PREFIXES = {
  { "mapf", "mapper nearby " },
  { "mapg", "mapper goto " },
  { "mapb", "mapper bookmark goto " },
  { "mapw", "mapper where " },
}

-- Registration -------------------------------------------------------------------

local count = 0

rune.alias.regex("^mapi$", guard(function() send("mapper roominfo") end))
count = count + 1

for _, p in ipairs(PREFIXES) do
  local alias, cmd = p[1], p[2]
  rune.alias.regex("^" .. alias .. " *(.*)$", guard(function(m) send(cmd .. (m[1] or "")) end))
  count = count + 1
end

-- Ganuk's Iron Worm: go there, buy, go down, hand in the token
rune.alias.regex("^wo *(.*)$", guard(function(m)
  send("mapper goto 10636; shop buy " .. (m[1] or "") .. "; down; give token ganuk")
end))
count = count + 1

for _, s in ipairs(SHORTCUTS) do
  local cmd = "mapper goto " .. s[2]
  rune.alias.regex("^" .. s[1] .. "$", guard(function() send(cmd) end))
  count = count + 1
end

-- Help and command handling ------------------------------------------------------

local HELP = {
  { NAME,               "show this help" },
  { "maps",             "short alias for " .. NAME },
  { "maps on|off",      "enable or disable all shortcut aliases" },
  { "maps debug on|off", "show each command sent (default off)" },
}

local function show_help()
  local foot = "v" .. VERSION .. "  shortcuts=" .. (enabled and "on" or "off")
    .. "  debug=" .. (DEBUG and "on" or "off") .. "  aliases=" .. count

  local ok = pcall(function()
    local H = require("helpstyle")
    H.title(NAME)
    H.section("Commands")
    for _, row in ipairs(HELP) do H.line(row[1], row[2]) end
    H.foot(foot)
  end)

  if not ok then
    rune.echo(NAME)
    for _, row in ipairs(HELP) do rune.echo("  " .. row[1] .. "  -  " .. row[2]) end
    rune.echo(foot)
  end
end

local function handle(m)
  local arg = ((m and m[1]) or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

  if arg == "on" then
    enabled = true
    save_enabled()
    say("shortcuts on")
  elseif arg == "off" then
    enabled = false
    save_enabled()
    say("shortcuts off")
  elseif arg == "debug on" then
    DEBUG = true
    say("debug on")
  elseif arg == "debug off" then
    DEBUG = false
    say("debug off")
  else
    show_help()
  end
end

-- Commands are bare aliases (rune.command.add only creates /slash commands)
rune.alias.regex("^" .. NAME .. " *(.*)$", handle)
rune.alias.regex("^maps *(.*)$", handle)

say("v" .. VERSION .. " loaded (" .. NAME .. " or maps for help)")