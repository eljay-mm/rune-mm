-- Filename: eljayPlugins/vitalsChanges.lua
-- Purpose: Shows hp/sp/st losses and gains in the main window (GMCP-driven).
-- Version: 2.5
-- Date: 2026-Oct-13
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
-- Commands:
--   vitals                 show this summary
--   vitals on | off        enable / disable the change output
--   vitals color on|off    ANSI colours in the output (default on)
--   vitals debug           toggle raw GMCP debug output
--   vitals check           show current values and settings

local H = require("helpstyle")

local VERSION = "2.5"
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
local function emit(text)
  rune.echo(text)
end

local function dbg(text)
  if DEBUG then
    emit("[vitals] " .. tostring(text))
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
        emit(fmt("hp", dh) .. " " .. fmt("sp", ds) .. " " .. fmt("st", dt))
      end
    end

    cur.hp, cur.sp, cur.st = hp, sp, st
  end
end

-- Commands
local function status_line()
  return string.format("v%s | output %s | colour %s | debug %s",
    VERSION,
    enabled and "on" or "off",
    use_color and "on" or "off",
    DEBUG and "on" or "off")
end

local function show_help()
  rune.echo(H.title("vitals changes (hp/sp/st gains and losses)"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("vitals on | off", "enable/disable the change output"))
  rune.echo(H.line("vitals color on|off", "ANSI colours (default on)"))
  rune.echo(H.line("vitals debug", "toggle raw GMCP debug output"))
  rune.echo(H.line("vitals check", "show current values and settings"))
  rune.echo(H.foot(status_line()))
end

local function show_check()
  local pk = {}
  for k in pairs(seen_packages) do pk[#pk + 1] = k end
  table.sort(pk)

  emit(string.format("vitals: hp=%s sp=%s st=%s",
    tostring(cur.hp), tostring(cur.sp), tostring(cur.st)))
  emit(string.format("enabled=%s color=%s debug=%s packages seen: %s",
    tostring(enabled), tostring(use_color), tostring(DEBUG),
    #pk > 0 and table.concat(pk, ", ") or "none yet"))
end

local function run_command_impl(arg_text)
  local words = {}
  for word in tostring(arg_text or ""):gmatch("%S+") do
    words[#words + 1] = word:lower()
  end

  local action = words[1] or ""

  if action == "off" then
    enabled = false
    save_settings()
    emit("vitals: change output OFF")
  elseif action == "on" then
    enabled = true
    save_settings()
    emit("vitals: change output ON")
  elseif action == "color" or action == "colour" then
    use_color = (words[2] ~= "off")
    save_settings()
    emit("vitals: colour " .. (use_color and "ON" or "OFF"))
  elseif action == "debug" then
    DEBUG = not DEBUG
    emit("vitals: debug " .. (DEBUG and "ON" or "OFF"))
  elseif action == "check" then
    show_check()
  else
    show_help()
  end
end

local function run_command(arg_text)
  local ok, err = pcall(run_command_impl, arg_text)
  if not ok then
    emit("vitals error: " .. tostring(err))
  end
end

-- Setup
rune.alias.regex("^/?vitals( .*)?$", function(m)
  run_command(m[1])
end, { name = "vitals" })

for _, package in ipairs(PACKAGES) do
  rune.gmcp.on(package, on_vitals(package))
end

-- Forget the baseline on disconnect so the next login does not print a bogus change.
rune.hooks.on("disconnected", function()
  cur.hp, cur.sp, cur.st = nil, nil, nil
end, { name = "vitals-disconnected" })

load_settings()
emit("-- vitalsChanges loaded (v" .. VERSION .. ") -- type 'vitals' for help --")