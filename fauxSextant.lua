-- Filename: eljayPlugins/fauxSextant.lua
-- Purpose: Update the statusTray SEXTANT field from GMCP coordinates
-- Version: 2.10
-- Date: 2026-Oct-25
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.10  Align command constants, help, settings writes, and loader output
--        with repository conventions.
--   2.9   Measure load time once after initialization, not when help is opened.
--   2.8   Add the required Todo block, persistent debug on/off commands,
--         load-time reporting, and help for unrecognized subcommands.
--
-- How it works:
--   * Reads coordinates from GMCP Room.Info and updates the statusTray SEXTANT field.
--   * Provides fauxSextant and fs commands to control updates and display coordinates.
--   * Saves enabled and debug settings with rune.store.
--   * Writes to statusTray and refreshes the bar only when the value changes.
--
-- Commands (type without "/"; "fs" is a short alias for "fauxSextant"):
--   fauxSextant                       show this help
--   fauxSextant on|off                enable / disable coordinate updates
--   fauxSextant toggle                toggle coordinate updates
--   fauxSextant show|status           show coordinates / enabled state
--   fauxSextant debug [on|off]        toggle or set debug messages
--   fs                                short alias for fauxSextant
--   fs on|off|toggle|show|status|debug [on|off]
--

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "fauxSextant"
local SHORT = "fs"

local VERSION = "2.10"
local STORE_KEY = "fauxSextant.settings"
local TRAY_STORE_KEY = "statustray.settings"

local style = rune.style
local H = require("helpstyle")

local function say(message)
    rune.echo(style.cyan("[" .. NAME .. "] ") .. message)
end

local function load_settings()
    local ok, settings = pcall(rune.store.get, STORE_KEY)
    if ok and type(settings) == "table" then
        return settings
    end
    return {}
end

local stored = load_settings()
local enabled = stored.enabled ~= false
local debug_on = stored.debug == true
local last_coord
local pushed_value
local pushed_known = false
local LOAD_MS = 0

rune.gmcp.subscribe("Room")

local function debug_log(message)
    if debug_on then
        say(style.gray(message))
    end
end

local function update_settings(mutate)
    local ok, fresh = pcall(rune.store.get, STORE_KEY)
    if not ok or type(fresh) ~= "table" then
        fresh = {}
    end

    mutate(fresh)

    local saved, err = pcall(rune.store.set, STORE_KEY, fresh)
    if not saved then
        say("could not save settings: " .. tostring(err))
        return false
    end

    stored = fresh
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

    if not force and pushed_known and pushed_value == value then
        return
    end

    local ok, settings = pcall(rune.store.get, TRAY_STORE_KEY)
    if not ok or type(settings) ~= "table" then
        settings = {}
    end

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
        say(on and style.green("already on") or style.red("already off"))
        return
    end

    enabled = on
    update_settings(function(settings)
        settings.enabled = enabled
        settings.debug = debug_on
    end)
    update_status_tray(last_coord, true)
    say(on and style.green("on") or style.red("off"))
end

local function set_debug(on)
    if debug_on == on then
        say("debug " .. (on and style.green("already on") or style.red("already off")))
        return
    end

    debug_on = on
    update_settings(function(settings)
        settings.enabled = enabled
        settings.debug = debug_on
    end)
    say("debug " .. (on and style.green("on") or style.red("off")))
end

local function help()
    rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line(NAME, "show this help"))
    rune.echo(H.line(SHORT .. " on|off", "enable / disable coordinate updates"))
    rune.echo(H.line(SHORT .. " toggle", "toggle coordinate updates"))
    rune.echo(H.line(SHORT .. " show|status", "show coordinates / enabled state"))
    rune.echo(H.line(SHORT .. " debug [on|off]", "toggle or set debug messages"))
    rune.echo(H.line(SHORT, "short alias for " .. NAME))
    rune.echo(H.foot(string.format("v%s  enabled=%s debug=%s  load=%dms",
        VERSION, tostring(enabled), tostring(debug_on), LOAD_MS)))
end

local function handle_command(action, argument)
    if action == "" or action == "help" then
        help()
    elseif action == "toggle" then
        set_enabled(not enabled)
    elseif action == "on" then
        set_enabled(true)
    elseif action == "off" then
        set_enabled(false)
    elseif action == "show" then
        local text = describe(last_coord)
        say(text or style.gray("no coordinates for this room"))
    elseif action == "status" then
        say(enabled and style.green("on") or style.red("off"))
    elseif action == "debug" then
        if argument == "on" then
            set_debug(true)
        elseif argument == "off" then
            set_debug(false)
        elseif argument == "" then
            set_debug(not debug_on)
        else
            help()
        end
    else
        help()
    end
end

local COMMANDS = {
    { suffix = "", action = "" },
    { suffix = "help", action = "help" },
    { suffix = "on", action = "on" },
    { suffix = "off", action = "off" },
    { suffix = "toggle", action = "toggle" },
    { suffix = "show", action = "show" },
    { suffix = "status", action = "status" },
    { suffix = "debug", action = "debug" },
    { suffix = "debug on", action = "debug", argument = "on" },
    { suffix = "debug off", action = "debug", argument = "off" },
}

local function register_aliases(prefix)
    for _, item in ipairs(COMMANDS) do
        local command = prefix
        if item.suffix ~= "" then
            command = command .. " " .. item.suffix
        end

        local action = item.action
        local argument = item.argument or ""

        local ok, err = pcall(function()
            rune.alias.exact(command, function(args, ctx)
                debug_log("command: '" .. command .. "'")
                handle_command(action, argument)
            end)
        end)

        if not ok then
            say(style.red("could not register alias " .. command .. ": " .. tostring(err)))
        end
    end
end

rune.gmcp.on("Room.Info", function(data)
    local coord = type(data) == "table" and data.coord or nil
    last_coord = describe(coord) and coord or nil
    update_status_tray(last_coord)
end, { name = NAME })

register_aliases(NAME)
register_aliases(SHORT)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
