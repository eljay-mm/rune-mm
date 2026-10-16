-- Filename: eljayPlugins/mapperShortCutKeys.lua
-- Purpose: Mapper shortcut aliases for common map locations and movement lookups.
-- Version: 2.6
-- Date: 2026-Oct-16
-- Changelog:
--   2.6  Display and commands rebuilt on the working annwnQuestSearch pattern: helpstyle rows are
--        passed to rune.echo (they return text, they do not print), and bare commands are
--        rune.alias.exact handlers. This fixes help not showing in 2.3 to 2.5.
--   2.5  Output helper with fallbacks (superseded by 2.6).
--   2.4  Separate bare and argument aliases (superseded by 2.6).
--   2.3  Standard pass: loader line, help, on/off toggle, debug toggle, table-driven shortcuts,
--        duplicate r4 removed (post office kept), short alias maps.
--   2.2  House-style pass: repo-standard header, "How it works" and "Commands" sections.
--   2.1  Original alias conversion from XML, no dependencies.
--
-- How it works:
--   * Registers short aliases that send mapper commands: mapf, mapg, mapb, mapw and mapi, plus
--     fixed "mapper goto <room id>" shortcuts for common towns and dungeons (r0, s1, hbrex, ...).
--   * Shortcuts are kept in one table below, one row per alias, grouped by area.
--   * No triggers and no network calls; the only saved setting is on/off (rune.store).
--   * Commands are typed without a / prefix. mapperShortCutKeys is the full command and maps is
--     the short alias; typing either alone shows the command summary.
--   * When shortcuts are off, the aliases say so and send nothing.
--
-- Commands (maps works in place of mapperShortCutKeys):
--   mapperShortCutKeys               show this summary
--   mapperShortCutKeys on|off        enable or disable all shortcut aliases
--   mapperShortCutKeys debug on|off  toggle debug messages (default off)

local VERSION      = "2.6"
local NAME         = "mapperShortCutKeys"
local PREFIX       = "[" .. NAME .. "] "
local SETTINGS_KEY = "mapperShortCutKeys.settings"

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


local function emit(text)
  if text ~= nil then
    rune.echo(text)
  end
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


-- Send a command to the game, with a debug echo.
local function send(command)
  dbg("send: " .. command)
  rune.send(command)
end


-- Wrap an alias handler so it only runs while shortcuts are on.
local function guard(handler)
  return function(args, ctx)
    if not enabled then
      say("shortcuts are off (mapperShortCutKeys on to enable)")
      return
    end
    handler(tostring(args or ""), ctx)
  end
end


-- Shortcut data: { alias, room id, note } -------------------------------------

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

-- Prefix aliases: "<alias> <args>" sends "<mapper command> <args>"
local PREFIXES = {
  { "mapf", "mapper nearby " },
  { "mapg", "mapper goto " },
  { "mapb", "mapper bookmark goto " },
  { "mapw", "mapper where " },
}


-- Help and command handling -----------------------------------------------------

local alias_count = 0

local function show_help()
  -- One status row, starting with the version, as the footer.
  local status = "v" .. VERSION .. "  enabled=" .. onoff(enabled) .. " debug=" .. onoff(debug_enabled)
    .. " aliases=" .. alias_count

  local styled = H and pcall(function()
    emit(H.title("Mapper shortcut keys"))
    emit(H.section("Commands"))
    emit(H.line("mapperShortCutKeys", "show this summary (short alias: maps)"))
    emit(H.line("mapperShortCutKeys on|off", "enable or disable all shortcut aliases"))
    emit(H.line("mapperShortCutKeys debug on|off", "toggle debug messages (default off)"))
    emit(H.section("Usage"))
    emit(H.line("mapf / mapg / mapb / mapw <text>", "mapper nearby / goto / bookmark goto / where"))
    emit(H.line("mapi", "mapper roominfo"))
    emit(H.line("wo <item>", "Ganuk's Iron Worm: buy <item> and hand in the token"))
    emit(H.line("r0-r9, s0-s2, m0-m3, ...", "mapper goto fixed rooms"))
    emit(H.foot(status))
  end)

  if styled then
    return
  end

  -- Plain fallback when helpstyle is missing or its API differs.
  rune.echo("Mapper shortcut keys")
  rune.echo("  mapperShortCutKeys               show this summary (short alias: maps)")
  rune.echo("  mapperShortCutKeys on|off        enable or disable all shortcut aliases")
  rune.echo("  mapperShortCutKeys debug on|off  toggle debug messages (default off)")
  rune.echo(status)
end


local function msk_command(args, ctx)
  local text    = tostring(args or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
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

    say("debug is " .. onoff(debug_enabled))
    return
  end

  -- Bare command, "help" or anything unrecognised.
  show_help()
end


-- Registration ------------------------------------------------------------------
-- Bare commands are aliases (rune.command.add would only create /slash commands).

rune.alias.exact("mapperShortCutKeys", msk_command)
rune.alias.exact("maps", msk_command)

rune.alias.exact("mapi", guard(function() send("mapper roominfo") end))
alias_count = alias_count + 1

for _, row in ipairs(PREFIXES) do
  local command = row[2]
  rune.alias.exact(row[1], guard(function(args) send(command .. args) end))
  alias_count = alias_count + 1
end

-- Ganuk's Iron Worm: go there, buy, go down, hand in the token
rune.alias.exact("wo", guard(function(args)
  send("mapper goto 10636; shop buy " .. args .. "; down; give token ganuk")
end))
alias_count = alias_count + 1

for _, row in ipairs(SHORTCUTS) do
  local command = "mapper goto " .. row[2]
  rune.alias.exact(row[1], guard(function() send(command) end))
  alias_count = alias_count + 1
end

load_settings()

-- Loader line (single row).
say("v" .. VERSION .. " loaded (mapperShortCutKeys or maps for help)")