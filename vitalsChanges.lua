-- Filename: eljayPlugins/vitalsChanges.lua
-- Purpose: Shows hp/sp/st losses and gains in the main window (GMCP-driven).
-- Version: 2.6
-- Changes:
--   2.6  Brought to standard: vitalsChanges command with vitals alias, no
--        / prefix, on|off and debug on|off toggles, version in help footer,
--        loader line.
-- Date: 2026-Oct-15
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * Listens for GMCP vitals (Char.Vitals, plus a few fallback packages)
--     and reads hp/sp/st, accepting several field-name aliases.
--   * Compares each update with the previous values and, when anything
--     changed, prints one line such as "hp -12 sp +3 st 0" in the main
--     window (green for gains, red for losses, if colour is on).
--   * The first update after connecting only sets the baseline; nothing is
--     printed for it, and the baseline is reset on disconnect.
--   * The on/off and colour settings are kept in rune.store (no files).
--
-- Commands (vitals is the short alias for vitalsChanges):
--   vitalsChanges                 show the command summary
--   vitalsChanges on | off        enable / disable the change output
--   vitalsChanges color on|off    ANSI colours in the output (default on)
--   vitalsChanges debug [on|off]  toggle raw GMCP debug output (default off)
--   vitalsChanges check           show current values and settings

local H = require("helpstyle")

local NAME = "vitalsChanges"
local VERSION = "2.6"
local SETTINGS_KEY = "vitals.settings"

-- GMCP packages that might carry vitals.
local PACKAGES = { "Char.Vitals", "Char.Status", "Char.Stats", "Char.Info" }

-- Field aliases per vital, in priority order.
local FIELDS = {
  hp = { "hp", "hitpoints", "health" },
  sp = { "sp", "mana", "spellpoints", "mp" },
  st = { "st", "moves", "stamina", "mv", "endurance" },
}

local enabled = true
local DEBUG = false
local use_color = true

local cur = { hp = nil, sp = nil, st = nil }
local seen_packages = {}
local resolved = {}            -- cached field name per vital once found

-- Output
local function paint(color, text)
  local ok, styled = pcall(function() return rune.style[color](text) end)
  if ok and styled then return styled end
  return text
end

local function say(text)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. text)
end

local function dbg(text)
  if DEBUG then
    say("debug: " .. tostring(text))
  end
end

-- Settings (rune.store)
local function load_settings()
  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then enabled = saved.enabled end
    if type(saved.color) == "boolean" then use_color = saved.color end
  end
end

local function save_settings()
  pcall(rune.store.set, SETTINGS_KEY, { enabled = enabled, color = use_color })
end

-- Formatting
local function fmt(label, num)
  local s = label .. " " .. ((num > 0) and ("+" .. num) or tostring(num))
  if not use_color then return s end
  if num > 0 then return "\27[32m" .. s .. "\27[0m" end
  if num < 0 then return "\27[31m" .. s .. "\27[0m" end
  return s
end

-- GMCP handling
local function pick(data, key)
  local cached = resolved[key]
  if cached then
    local v = tonumber(data[cached])
    if v then return v end
  end
  for _, name in ipairs(FIELDS[key]) do
    local v = tonumber(data[name])
    if v then
      resolved[key] = name
      return v
    end
  end
  return nil
end

local function describe(data)
  local parts = {}
  for k, v in pairs(data) do
    if type(v) ~= "table" and type(v) ~= "function" then
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
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

    if DEBUG then
      dbg(package .. ": " .. describe(data))
    end

    local hp = pick(data, "hp")
    local sp = pick(data, "sp")
    local st = pick(data, "st")

    if not (hp and sp and st) then
      return
    end

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

-- Commands
local function status_line()
  return string.format("v%s  output=%s color=%s debug=%s",
    VERSION,
    enabled and "on" or "off",
    use_color and "on" or "off",
    DEBUG and "on" or "off")
end

local function show_help()
  rune.echo(H.title("vitalsChanges (hp/sp/st gains and losses)"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("vitalsChanges on | off", "enable/disable the change output"))
  rune.echo(H.line("vitalsChanges color on|off", "ANSI colours (default on)"))
  rune.echo(H.line("vitalsChanges debug [on|off]", "toggle raw GMCP debug output"))
  rune.echo(H.line("vitalsChanges check", "show current values and settings"))
  rune.echo(H.line("vitals", "short alias for vitalsChanges"))
  rune.echo(H.foot(status_line()))
end

local function show_check()
  local pk = {}
  for k in pairs(seen_packages) do pk[#pk + 1] = k end
  table.sort(pk)

  say(string.format("hp=%s sp=%s st=%s",
    tostring(cur.hp), tostring(cur.sp), tostring(cur.st)))
  say(string.format("output=%s color=%s debug=%s packages seen: %s",
    enabled and "on" or "off", use_color and "on" or "off",
    DEBUG and "on" or "off",
    #pk > 0 and table.concat(pk, ", ") or "none yet"))
end

-- Returns true for "on", false for "off", nil for anything else.
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
    enabled = (action == "on")
    save_settings()
    say("change output " .. (enabled and "ON" or "OFF"))
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
    if value == nil then value = not DEBUG end
    DEBUG = value
    say("debug " .. (DEBUG and "ON" or "OFF"))
  elseif action == "check" then
    show_check()
  else
    show_help()
  end
end

local function run_command(arg_text)
  local ok, err = pcall(run_command_impl, arg_text)
  if not ok then
    say("error: " .. tostring(err))
  end
end

-- Setup
rune.alias.regex("^(vitalsChanges|vitals)( .*)?$", function(m)
  run_command(m[2])
end, { name = "vitalsChanges" })

for _, package in ipairs(PACKAGES) do
  rune.gmcp.on(package, on_vitals(package))
end

-- Forget the baseline on disconnect so the next login does not print a bogus change.
rune.hooks.on("disconnected", function()
  cur.hp, cur.sp, cur.st = nil, nil, nil
end, { name = "vitalsChanges-disconnected" })

load_settings()
say("v" .. VERSION .. " loaded (" .. NAME .. " or vitals for help)")