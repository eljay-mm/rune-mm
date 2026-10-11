-- Filename: eljayPlugins/numPadBindings.lua
-- Purpose: Numpad bindings for movement, look, and door accelerators
-- Version: 2.1
-- Date: 2026-Oct-11
--
-- How it works:
--   * rune.config.set("numpad", true) makes Rune deliver numpad key events.
--   * Three layers share one direction table (DIRS), one row per key:
--       - plain numpad  : walk in that direction (numpad5 = look)
--       - alt+numpad    : "look <direction>" (alt+numpad5 = scan)
--       - ctrl+numpad   : "open <direction> door" (no ctrl+numpad5)
--   * "add" (numpad +) is down and "subtract" (numpad -) is up in all layers.
--   * Every command is a fixed literal built at load time; nothing is ever
--     taken from game output, so a hostile line cannot inject a command.
--   * Typing  numpad  alone shows the status and a command summary.
--   * numpad on|off pauses/resumes every binding (handlers stay registered
--     and just return early, so no unbind API is needed).
--   * numpad debug on|off echoes each key and the command it sends.
--     Debug defaults to off.
--
-- Commands:
--     numpad                 status + command summary
--     numpad on | off        enable / disable the accelerators
--     numpad list            show every binding
--     numpad debug on|off    echo each keypress and command (default off)
--

rune.config.set("numpad", true)

local enabled = true
local debug_on = false

-----------------------------------------------------------------------
-- Binding table (one row per key; edit here to rebind)
-----------------------------------------------------------------------

-- key, direction, look-layer override, door-layer allowed
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

-----------------------------------------------------------------------
-- Output (help style, same as autopouch.lua)
-----------------------------------------------------------------------

local H = nil
pcall(function() H = require("helpstyle") end)

local function echo(text)
    if rune.echo then
        rune.echo(text)
    end
end

-- helpstyle functions may return a string or print themselves; handle both.
local function style(fname, text)
    local f = H and H[fname]

    if type(f) == "function" then
        local ok, res = pcall(f, text)

        if ok then
            if type(res) == "string" then
                echo(res)
            end
            return
        end
    end

    echo(text)
end

local function dbg(text)
    if debug_on then
        echo("[numpad] " .. text)
    end
end

-----------------------------------------------------------------------
-- Bindings
-----------------------------------------------------------------------

local bindings = {}   -- { key, command } rows, kept for "numpad list"

local function bind(key, command)
    bindings[#bindings + 1] = { key, command }

    rune.bind(key, function()
        if not enabled then
            return
        end

        dbg(key .. " -> " .. command)
        rune.send(command)
    end)
end

for _, d in ipairs(DIRS) do
    local key, dir, scan, door = d[1], d[2], d[3], d[4]

    bind(key, dir)
    bind("alt+" .. key, scan or ("look " .. dir))

    if door then
        bind("ctrl+" .. key, "open " .. dir .. " door")
    end
end

-----------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------

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
        debug_on = (words[2] == "on")
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

-- Alias for plain `numpad ...` plus a client command for `/numpad ...`.
if rune.alias and rune.alias.regex then
    pcall(rune.alias.regex, "^/?numpad(.*)$", function(match)
        run_command(match[1])
    end, { name = "numpad-cmd" })
end

if type(rune.command) == "table" then
    for _, fname in ipairs({
        "add", "register", "create", "define", "set", "on",
    }) do
        local f = rune.command[fname]

        if type(f) == "function" then
            local ok = pcall(f, "numpad", function(args)
                run_command(args_to_text(args))
            end)

            if ok then
                break
            end
        end
    end
end
