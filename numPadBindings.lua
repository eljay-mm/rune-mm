-- Filename: eljayPlugins/numPadBindings.lua
-- Purpose: Numpad bindings for movement, look, and door accelerators.
-- Version: 2.2
-- Date: 2026-Oct-13
-- Changelog:
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
--   * Every command is a fixed literal built at load time; nothing is ever taken from game output.
--   * Typing "numpad" alone shows the status and a command summary.
--   * numpad on|off pauses/resumes every binding while leaving the handlers registered.
--   * numpad debug on|off echoes each key and the command it sends.
--
-- Commands:
--   numpad                 status + command summary
--   numpad on|off          enable / disable the accelerators
--   numpad list            show every binding
--   numpad debug on|off    echo keypresses and emitted commands

rune.config.set("numpad", true)

local enabled = true
local debug_on = false

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

local H = nil
pcall(function() H = require("helpstyle") end)

local function echo(text)
  if rune and rune.echo then
    rune.echo(text)
  end
end

local function style(fname, text)
  if not H or type(H[fname]) ~= "function" then
    echo(text)
    return
  end

  local ok, out = pcall(H[fname], text)
  if ok and type(out) == "string" then
    echo(out)
    return
  end

  echo(text)
end

local function dbg(text)
  if debug_on then
    echo("[numpad] " .. text)
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
local function show_summary()
  style("title", "Numpad accelerators")
  style("section", "Commands")
  style("line", "numpad on | off        enable / disable the bindings")
  style("line", "numpad list            show every binding")
  style("line", "numpad debug on|off    echo keypresses (default off)")
  style("section", "Layers")
  style("line", "numpad    walk (5 = look)")
  style("line", "alt+      look <dir> (5 = scan)")
  style("line", "ctrl+     open <dir> door")
  style("foot", string.format("accelerators: %s | debug: %s | bindings: %d",
    enabled and "on" or "off", debug_on and "on" or "off", #bindings))
end

local function show_list()
  style("title", "Numpad bindings")

  for _, b in ipairs(bindings) do
    style("line", string.format("%-14s -> %s", b[1], b[2]))
  end

  style("foot", string.format("%d bindings | accelerators %s",
    #bindings, enabled and "on" or "off"))
end

local function run_command_impl(arg_text)
  local words = {}
  for word in tostring(arg_text or ""):gmatch("%S+") do
    words[#words + 1] = word:lower()
  end

  local action = words[1] or ""

  if action == "on" or action == "off" then
    enabled = (action == "on")
    style("foot", "numpad accelerators " .. action)
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
    style("foot", "numpad debug " .. (debug_on and "on" or "off"))
  else
    show_summary()
  end
end

local function run_command(arg_text)
  local ok, err = pcall(run_command_impl, arg_text)
  if not ok then
    echo("numpad error: " .. tostring(err))
  end
end

local function args_to_text(args)
  if type(args) == "table" then
    return table.concat(args, " ")
  end
  return tostring(args or "")
end

-- Alias for plain `numpad ...` plus a safe client registration for `/numpad ...`.
if rune.alias and rune.alias.regex then
  pcall(rune.alias.regex, "^/?numpad(.*)$", function(match)
    run_command(match[1])
  end, { name = "numpad-cmd" })
end

if rune.command then
  local ok = false
  for _, fname in ipairs({ "add", "register", "create", "define", "set", "on" }) do
    local f = rune.command[fname]
    if type(f) == "function" then
      local status = pcall(f, "numpad", function(args)
        run_command(args_to_text(args))
      end)
      if status then
        ok = true
        break
      end
    end
  end
end