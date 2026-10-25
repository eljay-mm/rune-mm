-- Filename: eljayPlugins/myExamplePlugin.lua
-- Purpose: Provide a baseline template adhering to rune-mm house style guidelines.
-- Version: 1.0
-- Date: 2026-Oct-20
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.0  Initial baseline template delivery.
--
-- How it works:
--   * Provide a baseline template adhering to rune-mm house style guidelines.
--   * Safely reads and writes to rune.store on a per-character basis.
--   * Registers bare alias commands and handles standard on/off toggles.
--
-- Commands (type without "/"; "example" is a short alias for "myExamplePlugin"):
--   myExamplePlugin            show this help
--   myExamplePlugin on|off     enable / disable the trigger(s)
--   myExamplePlugin debug      toggle debug messages (default off)
--
-- Tweaks (top of file):
--   * SAMPLE_TWEAK   an example constant value meant to be adjusted by the user
--

-- Capture start time immediately to track load duration
local LOAD_STARTED = os.clock()

-- Tweaks:
local SAMPLE_TWEAK = "default_value"

-- Command names: full command and short alias.
local NAME  = "myExamplePlugin"
local SHORT = "example"

-- Version tracking (must match header)
local VERSION = "1.0"

-- Required modules
local H        = require("helpstyle")
local charname = require("charname")
local style    = rune.style

-- State tracking
local enabled  = true
local debug_on = false
local cache    = {}

-- Pre-calculate unique character key securely
local function get_store_key(char_name)
  if not char_name or char_name == "" then return nil end
  return charname.key(NAME)
end

-- Safe database interaction pattern
local function update_settings(mutate)
  local name = charname.get()
  local key = get_store_key(name)
  if not key then return end

  local ok, fresh = pcall(rune.store.get, key)
  if not ok or type(fresh) ~= "table" then fresh = {} end
  
  mutate(fresh)
  pcall(rune.store.set, key, fresh)
  cache = fresh
end

-- Local persistence initializer
local function load_for(name)
  local key = get_store_key(name)
  if not key then return end

  local ok, data = pcall(rune.store.get, key)
  if ok and type(data) == "table" then
    cache = data
    if cache.enabled ~= nil then enabled = cache.enabled end
    if cache.debug_on ~= nil then debug_on = cache.debug_on end
  else
    cache = {}
  end
end

-- Contextual message display
local function say(msg)
  rune.echo(style.cyan("[" .. NAME .. "] ") .. msg)
end

local function debug_log(msg)
  if debug_on then
    rune.echo(style.cyan("[" .. NAME .. " DEBUG] ") .. tostring(msg))
  end
end

-- Render standardized help configuration UI
local function help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME,              "show this help"))
  rune.echo(H.line(NAME .. " on|off", "enable / disable the trigger(s)"))
  rune.echo(H.line(NAME .. " debug",  "toggle debug messages"))
  rune.echo(H.line(SHORT,             "short alias for " .. NAME))
  
  -- Calculate load metric exactly once at startup and render cached value
  rune.echo(H.foot(string.format("v%s  enabled=%s debug=%s  load=%dms",
    VERSION, tostring(enabled), tostring(debug_on), LOAD_MS)))
end

-- Input command route handler
local function handle_command(args, ctx)
  local cmd = args and args:match("^%s*(%S+)")
  
  if not cmd or cmd == "" then
    help()
    return
  end
  
  cmd = cmd:lower()
  
  if cmd == "on" then
    enabled = true
    update_settings(function(t) t.enabled = true end)
    say("Triggers enabled.")
  elseif cmd == "off" then
    enabled = false
    update_settings(function(t) t.enabled = false end)
    say("Triggers disabled.")
  elseif cmd == "debug" then
    debug_on = not debug_on
    update_settings(function(t) t.debug_on = debug_on end)
    say("Debug mode set to: " .. tostring(debug_on))
  else
    help()
  end
end

-- Bind bare commands via explicit exact aliases
rune.alias.exact(NAME, handle_command)
rune.alias.exact(SHORT, handle_command)

-- Safe initialization around asynchronous charname deliveries
if charname.get() then 
  load_for(charname.get()) 
end

charname.on_change(function(old, new)
  if new and new ~= "" then 
    pcall(load_for, new) 
  end
end)

-- Compute and store load time before printing the entry line
LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

-- Print a single standardized initialization message
say(string.format("v%s loaded (%s for help)", VERSION, SHORT))
