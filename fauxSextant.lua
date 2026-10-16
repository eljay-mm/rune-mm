-- Filename: eljayPlugins/fauxSextant.lua
-- Purpose: Update the statusTray SEXTANT field from GMCP coordinates
-- Version: 2.7
-- Date: 2026-Oct-16
-- Changelog:
--   2.7  Align header, commands, help, and aliases with repository conventions.
--   2.6  Fix subcommands showing help by registering a separate alias per command.
--
-- How it works:
--   * Reads coordinates from GMCP Room.Info and updates the statusTray SEXTANT field.
--   * Provides fauxSextant and fs commands to control updates and display coordinates.
--   * Saves enabled and debug settings with rune.store.
--   * Writes to statusTray and refreshes the bar only when the value changes.
--
-- Commands (type without "/"; "fs" is a short alias for "fauxSextant"):
--   fauxSextant                 show this help
--   fauxSextant on|off           enable / disable coordinate updates
--   fauxSextant toggle           toggle coordinate updates
--   fauxSextant show|status      show coordinates / enabled state
--   fauxSextant debug            toggle debug messages (default off)
--   fs                          short alias for fauxSextant
--   fs on|off|toggle|show|status|debug
--

local PLUGIN_NAME = "fauxSextant"
local SHORT = "fs"
local VERSION = "2.7"
local STORE_KEY = "fauxSextant.settings"
local TRAY_STORE_KEY = "statustray.settings"

local style = rune.style
local H = require("helpstyle")

local function say(message)
    rune.echo(style.cyan("[" .. PLUGIN_NAME .. "] ") .. message)
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
local debug = stored.debug == true
local last_coord
local pushed_value
local pushed_known = false

rune.gmcp.subscribe("Room")

local function debug_log(message)
    if debug then
        say(style.gray(message))
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
    save_settings()
    update_status_tray(last_coord, true)
    say(on and style.green("on") or style.red("off"))
end

local function help()
    rune.echo(H.title("Faux Sextant  (alias: fs)"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("fauxSextant", "show this help"))
    rune.echo(H.line("fauxSextant on|off", "enable / disable coordinate updates"))
    rune.echo(H.line("fauxSextant toggle", "toggle coordinate updates"))
    rune.echo(H.line("fauxSextant show|status", "show coordinates / enabled state"))
    rune.echo(H.line("fauxSextant debug", "toggle debug messages"))
    rune.echo(H.line("fs ...", "short alias for fauxSextant"))
    rune.echo(H.foot("v" .. VERSION .. "  enabled=" .. tostring(enabled)
        .. " debug=" .. tostring(debug)))
end

local function handle_command(action)
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
        say(text or style.gray("no coordinates for this room"))
    elseif action == "status" then
        say(enabled and style.green("on") or style.red("off"))
    elseif action == "debug" then
        debug = not debug
        save_settings()
        say("debug " .. (debug and style.green("on") or style.red("off")))
    end
end

-- Register each bare command as an exact alias so the handler does not need
-- to interpret alias callback arguments.
local COMMANDS = {
    { "", "" },
    { "help", "help" },
    { "on", "on" },
    { "off", "off" },
    { "toggle", "toggle" },
    { "show", "show" },
    { "now", "now" },
    { "status", "status" },
    { "debug", "debug" },
}

local function register_aliases(prefix)
    for _, item in ipairs(COMMANDS) do
        local suffix, action = item[1], item[2]
        local command = prefix .. (suffix ~= "" and (" " .. suffix) or "")
        local ok, err = pcall(function()
            rune.alias.exact(command, function(args, ctx)
                debug_log("command: '" .. command .. "'")
                handle_command(action)
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
end, { name = PLUGIN_NAME })

register_aliases(PLUGIN_NAME)
register_aliases(SHORT)

say("v" .. VERSION .. " loaded (fauxSextant or fs for help)")
