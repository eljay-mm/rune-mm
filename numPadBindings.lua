-- Filename: eljayPlugins/numPadBindings.lua
-- Purpose: Numpad bindings for movement, look, and door accelerators.
-- Version: 2.4
-- Date: 2026-Oct-16
-- Changelog:
--   2.4  Persist enabled and debug states with rune.store; document binding tweaks.
--   2.3  Standard pass: numPadBindings command with npb alias, bare aliases (no / prefix),
--        annwnQuestSearch-style display, loader line, version in the status footer.
--   2.2  Repo-style header cleanup and safe command registration; behavior preserved.
--   2.1  Original implementation.
--
-- How it works:
--   * rune.config.set("numpad", true) makes Rune deliver numpad key events.
--   * Three layers share one direction table:
--       - plain numpad  : walk in that direction (numpad5 = look)
--       - alt+numpad    : "look <direction>" (alt+numpad5 = scan)
--       - ctrl+numpad   : "open <direction> door" (no ctrl+numpad5)
--   * "add" (numpad +) is down and "subtract" (numpad -) is up in all layers.
--   * Every command is a fixed literal built at load time; nothing is taken from game output.
--   * Typing "numPadBindings" (or "npb") alone shows the command summary.
--   * on|off pauses/resumes every binding while leaving the handlers registered.
--   * debug on|off echoes each key and the command it sends (default off).
--
-- Commands:
--   numPadBindings               command summary (short alias: npb)
--   numPadBindings on|off        enable / disable the accelerators
--   numPadBindings list          show every binding
--   numPadBindings debug on|off  echo keypresses and emitted commands (default off)
--
-- Tweaks (top of file):
--   * DIRS   numpad keys, movement/look directions, and door-binding enablement
--
-- Settings:
--   * rune.store keys numPadBindings.enabled and numPadBindings.debug

local NAME = "numPadBindings"
local ALIAS = "npb"
local VERSION = "2.4"

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
    if not ok then
      return false
    end
    return true
  end
  return false
end

local enabled = load_setting(NAME .. ".enabled", true)
local debug_on = load_setting(NAME .. ".debug", false)

-- Binding table (one row per key; edit here to rebind)
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

-- Display helpers (paint/say via rune.echo, help rows via helpstyle)
local H = nil
pcall(function()
  H = require("helpstyle")
end)

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
  if row ~= nil and rune.echo then
    rune.echo(row)
  end
end

local function say(text)
  local ok, row = pcall(function()
    return paint("cyan", "[" .. NAME .. "] ") .. text
  end)
  emit(ok and row or ("[" .. NAME .. "] " .. text))
end

local function help_row(fname, text)
  local f = H and H[fname]
  if type(f) == "function" then
    local ok, out = pcall(f, text)
    if ok then
      emit(out)
      return
    end
  end
  emit(text)
end

local function dbg(text)
  if debug_on then
    say("debug: " .. text)
  end
end

-- Bindings
local bindings = {}

local function bind(key, command)
  bindings[#bindings + 1] = { key, command }

  if rune.bind then
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

-- Commands
local function footer()
  help_row("foot", string.format("v%s  enabled=%s debug=%s bindings=%d",
    VERSION, enabled and "on" or "off", debug_on and "on" or "off", #bindings))
end

local function show_summary()
  help_row("title", "Numpad accelerators")
  help_row("section", "Commands")
  help_row("line", NAME .. " | " .. ALIAS .. "        this summary")
  help_row("line", NAME .. " on | off     enable / disable the bindings")
  help_row("line", NAME .. " list         show every binding")
  help_row("line", NAME .. " debug on|off echo keypresses (default off)")
  help_row("section", "Layers")
  help_row("line", "numpad    walk (5 = look)")
  help_row("line", "alt+      look <dir> (5 = scan)")
  help_row("line", "ctrl+     open <dir> door")
  footer()
end

local function show_list()
  help_row("title", "Numpad bindings")

  for _, b in ipairs(bindings) do
    help_row("line", string.format("%-14s -> %s", b[1], b[2]))
  end

  footer()
end

local function run_command_impl(arg_text)
  local words = {}
  for word in tostring(arg_text or ""):gmatch("%S+") do
    words[#words + 1] = word:lower()
  end

  local action = words[1] or ""

  if action == "on" or action == "off" then
    enabled = (action == "on")
    if not save_setting(NAME .. ".enabled", enabled) then
      say("warning: could not save enabled state")
    end
    say("accelerators " .. action)
  elseif action == "list" then
    show_list()
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

-- Bare commands are aliases (rune.command only makes /slash commands).
-- The exact aliases handle the bare word; the regex alias handles "<name> <args>".
if rune.alias and rune.alias.exact then
  for _, word in ipairs({ NAME, ALIAS }) do
    pcall(rune.alias.exact, word, function(args, ctx)
      run_command(args_to_text(args))
    end)
  end
end

if rune.alias and rune.alias.regex then
  pcall(rune.alias.regex, "^(?:" .. NAME .. "|" .. ALIAS .. ") +(.*)$", function(match)
    run_command(match[1])
  end, { name = "numPadBindings-cmd" })
end

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, ALIAS))
