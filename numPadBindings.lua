-- Filename: eljayPlugins/numPadBindings.lua
-- Purpose: Provides numpad bindings for movement, looking, and door commands.
-- Version: 2.9
-- Date: 2026-Oct-26
--[[
- Consider adding configurable bindings if more layouts are needed.
]]
-- Changelog:
--   2.9  Add literal substring filtering to the list command.
--   2.8  Measure load time with os.clock().
--   2.7  Guard load-time measurement when rune.time() is unavailable.
--   2.6  Measure load time with rune.time().
--   2.5  Use helpstyle rows and standardize command/help output.
--   2.4  Persist enabled and debug states with rune.store; document binding tweaks.
--   2.3  Standard pass: numPadBindings command with npb alias, bare aliases (no / prefix),
--        annwnQuestSearch-style display, loader line, version in the status footer.
--   2.2  Repo-style header cleanup and safe command registration; behavior preserved.
--   2.1  Original implementation.
--
-- How it works:
--   * rune.config.set("numpad", true) enables Rune's numpad key events.
--   * Plain numpad keys walk in their direction; numpad5 looks.
--   * Alt+numpad looks in that direction; alt+numpad5 scans.
--   * Ctrl+numpad opens the door in that direction; ctrl+numpad5 is not bound.
--   * Numpad add and subtract send "down" and "up" in each available layer.
--   * Bindings use fixed commands built at load time; no game output is used.
--   * Typing "numPadBindings" or "npb" alone shows help; on/off controls bindings.
--   * "numPadBindings list [text]" lists bindings, optionally filtered by a
--     case-insensitive literal substring in the key or command.
--   * Debug output is off by default; state is saved with rune.store.
--
-- Commands (type without "/"; "npb" is a short alias for "numPadBindings"):
--   numPadBindings                 show this help
--   npb                            show this help
--   numPadBindings on|off          enable / disable the bindings
--   numPadBindings list [text]     list bindings, optionally filtered
--   numPadBindings debug on|off    enable / disable debug messages
--
-- Tweaks (top of file):
--   * DIRS   numpad keys, movement/look directions, and door-binding enablement
--
-- Settings:
--   * rune.store keys numPadBindings.enabled and numPadBindings.debug

local LOAD_STARTED = os.clock()

local NAME = "numPadBindings"
local SHORT = "npb"
local VERSION = "2.9"

rune.config.set("numpad", true)

local function load_setting(key, default)
  if rune.store and type(rune.store.get) == "function" then
    local ok, value = pcall(rune.store.get, key)
    if ok and type(value) == "boolean" then
      return value
    end
  end
  return default
end

local function save_setting(key, value)
  if rune.store and type(rune.store.set) == "function" then
    local ok = pcall(rune.store.set, key, value)
    return ok
  end
  return false
end

local enabled = load_setting(NAME .. ".enabled", true)
local debug_on = load_setting(NAME .. ".debug", false)

-- Binding table (one row per key; edit here to rebind).
local DIRS = {
  { "numpad1",  "southwest", nil,    true  },
  { "numpad2",  "south",     nil,    true  },
  { "numpad3",  "southeast", nil,    true  },
  { "numpad4",  "west",      nil,    true  },
  { "numpad5",  "look",      "scan", false },
  { "numpad6",  "east",      nil,    true  },
  { "numpad7",  "northwest", nil,    true  },
  { "numpad8",  "north",     nil,    true  },
  { "numpad9",  "northeast", nil,    true  },
  { "add",      "down",      nil,    true  },
  { "subtract", "up",        nil,    true  },
}

local H = require("helpstyle")

local function paint(color, text)
  local fn = rune.style and rune.style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out ~= nil then
      return out
    end
  end
  return text
end

local function emit(row)
  if row ~= nil then
    rune.echo(row)
  end
end

local function say(text)
  local ok, row = pcall(function()
    return paint("cyan", "[" .. NAME .. "] ") .. text
  end)
  emit(ok and row or ("[" .. NAME .. "] " .. text))
end

local function help_row(kind, ...)
  local fn = H[kind]
  if type(fn) == "function" then
    local ok, row = pcall(fn, ...)
    if ok then
      emit(row)
      return
    end
  end

  -- Keep help usable if a helpstyle helper fails.
  local parts = { ... }
  emit(table.concat(parts, "  "))
end

local function dbg(text)
  if debug_on then
    say("debug: " .. text)
  end
end

local bindings = {}

local function bind(key, command)
  bindings[#bindings + 1] = { key, command }

  if type(rune.bind) == "function" then
    rune.bind(key, function()
      if not enabled then
        return
      end

      dbg(key .. " -> " .. command)
      rune.send(command)
    end)
  end
end

for _, d in ipairs(DIRS) do
  local key, dir, scan, door = d[1], d[2], d[3], d[4]

  bind(key, dir)
  bind("alt+" .. key, scan or ("look " .. dir))

  if door then
    bind("ctrl+" .. key, "open " .. dir .. " door")
  end
end

local LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

local function footer()
  help_row("foot", string.format(
    "v%s  enabled=%s debug=%s bindings=%d  load=%dms",
    VERSION,
    enabled and "on" or "off",
    debug_on and "on" or "off",
    #bindings,
    LOAD_MS
  ))
end

local function show_summary()
  help_row("title", "numPadBindings  (alias: " .. SHORT .. ")")
  help_row("section", "Commands")
  help_row("line", NAME .. " / " .. SHORT, "show this help")
  help_row("line", SHORT .. " on|off", "enable / disable the bindings")
  help_row("line", SHORT .. " list [text]", "list bindings; optional filter")
  help_row("line", SHORT .. " debug on|off", "enable / disable debug messages")
  help_row("line", SHORT .. " ", "short alias for " .. NAME)
  help_row("section", "Layers")
  help_row("line", "numpad", "walk (5 = look)")
  help_row("line", "alt+", "look <direction> (5 = scan)")
  help_row("line", "ctrl+", "open <direction> door")
  footer()
end

local function show_list(filter)
  local needle = tostring(filter or ""):lower()
  local shown = 0

  help_row("title", "numPadBindings")

  for _, binding in ipairs(bindings) do
    local key = binding[1]
    local command = binding[2]
    local searchable = (key .. " " .. command):lower()

    if needle == "" or searchable:find(needle, 1, true) then
      help_row("line", key, "-> " .. command)
      shown = shown + 1
    end
  end

  if shown == 0 then
    help_row("line", "No bindings match: " .. tostring(filter))
  end

  footer()
end

local function run_command_impl(arg_text)
  local text = tostring(arg_text or "")
  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word:lower()
  end

  local action = words[1] or ""

  if action == "on" or action == "off" then
    enabled = action == "on"
    if not save_setting(NAME .. ".enabled", enabled) then
      say("warning: could not save enabled state")
    end
    say("accelerators " .. action)
  elseif action == "list" then
    local filter = text:match("^%s*%S+%s*(.-)%s*$")
    show_list(filter)
  elseif action == "debug" then
    if words[2] == "on" then
      debug_on = true
    elseif words[2] == "off" then
      debug_on = false
    else
      debug_on = not debug_on
    end

    if not save_setting(NAME .. ".debug", debug_on) then
      say("warning: could not save debug state")
    end
    say("debug " .. (debug_on and "on" or "off"))
  else
    show_summary()
  end
end

local function run_command(arg_text)
  local ok, err = pcall(run_command_impl, arg_text)
  if not ok then
    say("error: " .. tostring(err))
  end
end

local function args_to_text(args)
  if type(args) == "table" then
    return table.concat(args, " ")
  end
  return tostring(args or "")
end

-- Bare commands are aliases; rune.command.add only creates slash commands.
if rune.alias and type(rune.alias.exact) == "function" then
  for _, word in ipairs({ NAME, SHORT }) do
    pcall(rune.alias.exact, word, function(args, ctx)
      run_command(args_to_text(args))
    end)
  end
end

if rune.alias and type(rune.alias.regex) == "function" then
  pcall(
    rune.alias.regex,
    "^(?:" .. NAME .. "|" .. SHORT .. ") +(.*)$",
    function(match)
      run_command(match[1])
    end,
    { name = NAME .. "-cmd" }
  )
end

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
