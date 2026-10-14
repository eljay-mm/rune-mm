-- Filename: eljayPlugins/fauxSextant.lua
-- Purpose: Update the statusTray SEXTANT field from GMCP coordinates
-- Version: 2.6
-- Date: 2026-Oct-14
-- Changelog:
--   2.6  Fix "fs on" (and other subcommands) only showing help: one alias per
--        subcommand instead of parsing alias callback arguments.
--   2.5  Debug is now a simple toggle: fauxSextant debug (fs debug).
--   2.4  Fix subcommands (on/off/toggle/show/status/debug) not reaching the handler:
--        alias argument parsing now accepts any callback shape.
--   2.3  Fix help error (helpstyle.title nil): use the module returned by
--        require("helpstyle") with plain-text fallbacks.
--   2.2  Bare fauxSextant/fs commands (aliases, no / prefix), loader line,
--        version footer in help, cached tray value to skip redundant store reads.
--   2.1  Align commands, help, toggles, and settings with plugin conventions.
--
-- How it works
--   * Reads coordinates from GMCP Room.Info and updates the statusTray SEXTANT field.
--   * Provides fauxSextant and fs commands (typed bare) to control updates and
--     display coordinates; typing the command alone shows the command summary.
--   * Saves the enabled and debug settings with rune.store.
--   * Only writes to the statusTray settings and refreshes the bar when the
--     value actually changes.
--

local PLUGIN_NAME = "fauxSextant"
local VERSION = "2.6"
local TAG = "[" .. PLUGIN_NAME .. "]"
local TRAY_STORE_KEY = "statustray.settings"
local STORE_KEY = "fauxSextant.settings"

local function load_settings()
    local ok, settings = pcall(rune.store.get, STORE_KEY)
    if ok and type(settings) == "table" then
        return settings
    end
    return {}
end

local stored = load_settings()
local enabled = stored.enabled ~= false
local debug = stored.debug == true
local last_coord
local pushed_value -- last value written to statusTray (nil = cleared / unknown)
local pushed_known = false

rune.gmcp.subscribe("Room")

local function say(message)
    rune.echo(rune.style.cyan(TAG) .. " " .. message)
end

local function debug_log(message)
    if debug then
        say(rune.style.gray(message))
    end
end

local function save_settings()
    local ok, err = pcall(rune.store.set, STORE_KEY, {
        enabled = enabled,
        debug = debug,
    })

    if not ok then
        say("could not save settings: " .. tostring(err))
        return false
    end

    return true
end

local function describe(coord)
    if type(coord) ~= "table" then
        return nil
    end

    local x, y = tonumber(coord.x), tonumber(coord.y)
    if not x or not y then
        return nil
    end

    local z = tonumber(coord.z)
    local name = type(coord.name) == "string" and coord.name ~= ""
        and (coord.name .. "  ") or ""

    local text = name .. "x " .. tostring(x) .. "  y " .. tostring(y)
    if z then
        text = text .. "  z " .. tostring(z)
    end

    return text
end

local function update_status_tray(coord, force)
    local x = type(coord) == "table" and tonumber(coord.x) or nil
    local y = type(coord) == "table" and tonumber(coord.y) or nil

    local value
    if enabled and x and y then
        value = tostring(x) .. " " .. tostring(y)
    end

    -- Skip all store work when nothing changed since our last write.
    if not force and pushed_known and pushed_value == value then
        return
    end

    local ok, settings = pcall(rune.store.get, TRAY_STORE_KEY)
    if not ok or type(settings) ~= "table" then
        settings = {}
    end

    -- Avoid writing and refreshing the bar when its value has not changed.
    if settings.sextant == value then
        pushed_value, pushed_known = value, true
        return
    end

    settings.sextant = value
    local saved, err = pcall(rune.store.set, TRAY_STORE_KEY, settings)
    if not saved then
        debug_log("could not update statusTray: " .. tostring(err))
        return
    end

    pushed_value, pushed_known = value, true
    debug_log("statusTray SEXTANT = " .. tostring(value or "--"))
    rune.ui.refresh_bars()
end

local function set_enabled(on)
    if enabled == on then
        say(on and rune.style.green("already on") or rune.style.red("already off"))
        return
    end

    enabled = on
    save_settings()
    update_status_tray(last_coord, true)
    say(on and rune.style.green("on") or rune.style.red("off"))
end

local function help()
    -- helpstyle may be returned by require or exposed as a global; fall back to
    -- plain text for any function it does not provide.
    local ok, mod = pcall(require, "helpstyle")
    local src = (ok and type(mod) == "table" and mod)
        or (type(rawget(_G, "helpstyle")) == "table" and rawget(_G, "helpstyle"))
        or {}
    local function plain(text) return tostring(text) end
    local H = {
        title = type(src.title) == "function" and src.title or plain,
        section = type(src.section) == "function" and src.section or plain,
        line = type(src.line) == "function" and src.line or plain,
        foot = type(src.foot) == "function" and src.foot or plain,
    }

    rune.echo(H.title("Faux Sextant"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("fauxSextant or fs"))
    rune.echo(H.line("fauxSextant on|off|toggle  (also: fs on|off|toggle)"))
    rune.echo(H.line("fauxSextant show|status  (also: fs show|status)"))
    rune.echo(H.line("fauxSextant debug  (also: fs debug)  toggles debug messages"))
    rune.echo(H.foot("v" .. VERSION .. "  enabled=" .. tostring(enabled)
        .. " debug=" .. tostring(debug)))
end

local function handle_command(args)
    local words = {}
    for word in tostring(args or ""):lower():gmatch("%S+") do
        words[#words + 1] = word
    end

    local action = words[1] or ""

    if action == "" or action == "help" then
        help()
    elseif action == "toggle" then
        set_enabled(not enabled)
    elseif action == "on" then
        set_enabled(true)
    elseif action == "off" then
        set_enabled(false)
    elseif action == "show" or action == "now" then
        local text = describe(last_coord)
        say(text or rune.style.gray("no coordinates for this room"))
    elseif action == "status" then
        say(enabled and rune.style.green("on") or rune.style.red("off"))
    elseif action == "debug" then
        debug = not debug
        save_settings()
        say("debug " .. (debug and rune.style.green("on") or rune.style.red("off")))
    else
        say("usage: fauxSextant [on|off|toggle|show|status|debug]")
    end
end

-- rune.command.add only creates /slash commands, so the bare commands are
-- registered as aliases. One alias is registered per subcommand, so the
-- handler never has to parse the alias callback arguments.
local ACTIONS = { "help", "toggle", "on", "off", "show", "now", "status", "debug" }

local function register_command()
    local function add(pattern, action)
        local ok, err = pcall(function()
            return rune.alias.regex(pattern, function()
                debug_log("command: '" .. action .. "'")
                handle_command(action)
            end)
        end)

        if not ok then
            say(rune.style.red("could not register alias " .. pattern .. ": " .. tostring(err)))
        end
        return ok
    end

    add("(?i)^(?:fauxSextant|fs)\\s*$", "")
    for _, action in ipairs(ACTIONS) do
        add("(?i)^(?:fauxSextant|fs)\\s+" .. action .. "\\s*$", action)
    end
end

rune.gmcp.on("Room.Info", function(data)
    local coord = type(data) == "table" and data.coord or nil
    if describe(coord) then
        last_coord = coord
    else
        last_coord = nil
    end

    update_status_tray(last_coord)
end, { name = PLUGIN_NAME })

register_command()

say("v" .. VERSION .. " loaded (fauxSextant or fs for help)")