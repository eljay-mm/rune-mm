-- Filename: eljayPlugins/myExamplePlugin.lua
-- Purpose: Provide a baseline template for rune-mm plugins.
-- Version: 1.1
-- Date: 2026-Oct-26
--[[
TODO:
- Replace the example setting and state with plugin-specific behavior.
]]
-- Changelog:
--   1.1  Corrected command handling, persistence, and load-time reporting.
--   1.0  Initial baseline template delivery.
--
-- How it works:
--   * Shows help and accepts bare full-name and short-alias commands.
--   * Persists enabled and debug states per character with rune.store.
--   * Demonstrates a minimal place to add plugin-specific behavior.
--
-- Commands (type without "/"; "mep" is a short alias for "myExamplePlugin"):
--   myExamplePlugin            show this help
--   mep on|off                 enable / disable the plugin
--   mep debug on|off           enable / disable debug messages
--
-- Tweaks (top of file):
--   * SAMPLE_TWEAK   example setting for plugin-specific behavior
--

local LOAD_STARTED = os.clock()

-- Tweaks:
local SAMPLE_TWEAK = "default_value"

-- Command names: full command and short alias.
local NAME  = "myExamplePlugin"
local SHORT = "mep"

local VERSION = "1.1"

local H        = require("helpstyle")
local charname = require("charname")
local style    = rune.style

local enabled  = true
local debug_on = false
local cache    = {}
local LOAD_MS

local function say(msg)
  rune.echo(style.cyan("[" .. NAME .. "] ") .. msg)
end

local function debug_log(msg)
  if debug_on then
    rune.echo(style.cyan("[" .. NAME .. " DEBUG] ") .. tostring(msg))
  end
end

local function store_key()
  if not charname.get() then return nil end
  return charname.key(NAME)
end

local function update_settings(mutate)
  local key = store_key()
  if not key then return end

  local ok, fresh = pcall(rune.store.get, key)
  if not ok or type(fresh) ~= "table" then fresh = {} end

  mutate(fresh)

  local saved = pcall(rune.store.set, key, fresh)
  if saved then cache = fresh end
end

local function load_for(name)
  if not name or name == "" then return end

  local key = charname.key(NAME)
  local ok, data = pcall(rune.store.get, key)

  if ok and type(data) == "table" then
    cache = data
  else
    cache = {}
  end

  enabled = cache.enabled ~= false
  debug_on = cache.debug_on == true
end

local function help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(SHORT, "show this help"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable the plugin"))
  rune.echo(H.line(SHORT .. " debug on|off", "enable / disable debug"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s bindings=2  load=%dms",
    VERSION, tostring(enabled), tostring(debug_on), LOAD_MS
  )))
end

local function handle_command(args, ctx)
  local command, value = (args or ""):match("^%s*(%S*)%s*(%S*)")
  command = (command or ""):lower()
  value = (value or ""):lower()

  if command == "" then
    help()
  elseif command == "on" or command == "off" then
    enabled = command == "on"
    update_settings(function(settings)
      settings.enabled = enabled
    end)
    say(enabled and "Enabled." or "Disabled.")
  elseif command == "debug" and (value == "on" or value == "off") then
    debug_on = value == "on"
    update_settings(function(settings)
      settings.debug_on = debug_on
    end)
    say("Debug mode set to: " .. tostring(debug_on))
  else
    help()
  end
end

rune.alias.exact(NAME, handle_command)
rune.alias.exact(SHORT, handle_command)

if charname.get() then
  load_for(charname.get())
end

charname.on_change(function(old, new)
  if new and new ~= "" then
    pcall(load_for, new)
  end
end)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
