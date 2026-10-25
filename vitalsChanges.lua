-- Filename: eljayPlugins/vitalsChanges.lua
-- Purpose: Shows hp/sp/st losses and gains in the main window (GMCP-driven).
-- Version: 2.7
-- Date: 2026-Oct-19
--[[
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.7  Brought to repository standard: persistent debug state, exact bare
--        command aliases, standardized help and load-time reporting.
--   2.6  Added vitalsChanges command with vitals alias, toggles, help and
--        loader line.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * Listens for GMCP vitals (Char.Vitals, plus fallback packages) and reads
--     hp/sp/st, accepting several field-name aliases.
--   * Compares complete updates with the previous values and prints changes
--     in the main window, with optional colour.
--   * The first complete update after connecting establishes the baseline;
--     the baseline is reset on disconnect.
--   * Saves output, colour and debug settings in rune.store.
--
-- Commands (vitals is the short alias for vitalsChanges):
--   vitalsChanges                 show this help
--   vitalsChanges on|off          enable / disable change output
--   vitalsChanges color on|off    enable / disable ANSI colours
--   vitalsChanges debug [on|off]  toggle / set raw GMCP debug output
--   vitalsChanges check           show current values and settings
--
-- Tweaks (top of file):
--   PACKAGES  GMCP packages checked for vitals
--   FIELDS    Field aliases accepted for hp, sp and st
--

local LOAD_STARTED = os.clock()

local H = require("helpstyle")

local NAME = "vitalsChanges"
local SHORT = "vitals"
local VERSION = "2.7"
local SETTINGS_KEY = "vitals.settings"

local PACKAGES = { "Char.Vitals", "Char.Status", "Char.Stats", "Char.Info" }

local FIELDS = {
  hp = { "hp", "hitpoints", "health" },
  sp = { "sp", "mana", "spellpoints", "mp" },
  st = { "st", "moves", "stamina", "mv", "endurance" },
}

local enabled = true
local use_color = true
local debug_enabled = false
local LOAD_MS = 0

local cur = { hp = nil, sp = nil, st = nil }
local seen_packages = {}
local resolved = {}

local function paint(color, text)
  local ok, styled = pcall(function()
    return rune.style[color](text)
  end)
  if ok and styled then return styled end
  return text
end

local function say(text)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. tostring(text))
end

local function dbg(text)
  if debug_enabled then
    say("debug: " .. tostring(text))
  end
end

local function load_settings()
  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then enabled = saved.enabled end
    if type(saved.color) == "boolean" then use_color = saved.color end
    if type(saved.debug) == "boolean" then debug_enabled = saved.debug end
  end
end

local function save_settings()
  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = enabled,
    color = use_color,
    debug = debug_enabled,
  })
end

local function fmt(label, num)
  local text = label .. " " .. (num > 0 and ("+" .. num) or tostring(num))
  if not use_color then return text end
  if num > 0 then return "\27[32m" .. text .. "\27[0m" end
  if num < 0 then return "\27[31m" .. text .. "\27[0m" end
  return text
end

local function pick(data, key)
  local cached = resolved[key]
  if cached then
    local value = tonumber(data[cached])
    if value ~= nil then return value end
  end

  for _, field in ipairs(FIELDS[key]) do
    local value = tonumber(data[field])
    if value ~= nil then
      resolved[key] = field
      return value
    end
  end

  return nil
end

local function describe(data)
  local parts = {}
  for key, value in pairs(data) do
    if type(value) ~= "table" and type(value) ~= "function" then
      parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
    end
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

local function on_vitals(package)
  return function(data)
    if type(data) ~= "table" then
      dbg(package .. " (non-table): " .. tostring(data))
      return
    end

    if debug_enabled then
      dbg(package .. ": " .. describe(data))
    end

    local hp = pick(data, "hp")
    local sp = pick(data, "sp")
    local st = pick(data, "st")

    -- Only compare complete snapshots, avoiding mixed/partial updates.
    if hp == nil or sp == nil or st == nil then return end

    seen_packages[package] = true

    if cur.hp ~= nil and enabled then
      local dh, ds, dt = hp - cur.hp, sp - cur.sp, st - cur.st
      if dh ~= 0 or ds ~= 0 or dt ~= 0 then
        rune.echo(fmt("hp", dh) .. " " .. fmt("sp", ds) .. " " .. fmt("st", dt))
      end
    end

    cur.hp, cur.sp, cur.st = hp, sp, st
  end
end

local function status_line()
  return string.format("v%s  enabled=%s color=%s debug=%s  bindings=%d  load=%dms",
    VERSION,
    enabled and "true" or "false",
    use_color and "true" or "false",
    debug_enabled and "true" or "false",
    #PACKAGES + 3,
    LOAD_MS)
end

local function show_help()
  rune.echo(H.title(NAME .. " (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable change output"))
  rune.echo(H.line(SHORT .. " color on|off", "enable / disable ANSI colours"))
  rune.echo(H.line(SHORT .. " debug [on|off]", "toggle / set raw GMCP debug output"))
  rune.echo(H.line(SHORT .. " check", "show current values and settings"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(status_line()))
end

local function show_check()
  local packages = {}
  for package in pairs(seen_packages) do
    packages[#packages + 1] = package
  end
  table.sort(packages)

  say(string.format("hp=%s sp=%s st=%s",
    tostring(cur.hp), tostring(cur.sp), tostring(cur.st)))
  say(string.format("output=%s color=%s debug=%s packages seen: %s",
    enabled and "on" or "off",
    use_color and "on" or "off",
    debug_enabled and "on" or "off",
    #packages > 0 and table.concat(packages, ", ") or "none yet"))
end

local function parse_toggle(word)
  if word == "on" then return true end
  if word == "off" then return false end
  return nil
end

local function run_command_impl(arg_text)
  local words = {}
  for word in tostring(arg_text or ""):gmatch("%S+") do
    words[#words + 1] = word:lower()
  end

  local action = words[1] or ""

  if action == "on" or action == "off" then
    enabled = action == "on"
    save_settings()
    say("change output " .. action:upper())
  elseif action == "color" or action == "colour" then
    local value = parse_toggle(words[2])
    if value == nil then
      say("usage: " .. NAME .. " color on|off")
    else
      use_color = value
      save_settings()
      say("colour " .. (use_color and "ON" or "OFF"))
    end
  elseif action == "debug" then
    local value = parse_toggle(words[2])
    if value == nil then value = not debug_enabled end
    debug_enabled = value
    save_settings()
    say("debug " .. (debug_enabled and "ON" or "OFF"))
  elseif action == "check" then
    show_check()
  else
    show_help()
  end
end

local function run_command(arg_text)
  local ok, err = pcall(run_command_impl, arg_text)
  if not ok then say("error: " .. tostring(err)) end
end

load_settings()

-- Bare commands are aliases; rune.command.add would create slash commands.
rune.alias.exact(NAME, function(args, ctx)
  run_command(args)
end, { name = NAME })

rune.alias.exact(SHORT, function(args, ctx)
  run_command(args)
end, { name = SHORT })

for _, package in ipairs(PACKAGES) do
  rune.gmcp.on(package, on_vitals(package))
end

rune.hooks.on("disconnected", function()
  cur.hp, cur.sp, cur.st = nil, nil, nil
end, { name = NAME .. "-disconnected" })

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")
