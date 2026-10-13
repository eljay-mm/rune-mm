-- Filename: eljayPlugins/fauxSextant.lua
-- Purpose: Update the statusTray SEXTANT field from GMCP coordinates
-- Version: 2.1
-- Date: 2026-Oct-13
-- Changelog:
--   2.1  Align commands, help, toggles, and settings with plugin conventions.
--
-- How it works
--   * Reads coordinates from GMCP Room.Info and updates the statusTray SEXTANT field.
--   * Provides fauxSextant and fs commands to control updates and display coordinates.
--   * Saves the enabled and debug settings with rune.store.
--

local PLUGIN_NAME = "fauxSextant"
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

local function update_status_tray(coord)
    local x = type(coord) == "table" and tonumber(coord.x) or nil
    local y = type(coord) == "table" and tonumber(coord.y) or nil

    local ok, settings = pcall(rune.store.get, TRAY_STORE_KEY)
    if not ok or type(settings) ~= "table" then
        settings = {}
    end

    local value
    if enabled and x and y then
        value = tostring(x) .. " " .. tostring(y)
    end

    -- Avoid writing and refreshing the bar when its value has not changed.
    if settings.sextant == value then
        return
    end

    settings.sextant = value
    local saved, err = pcall(rune.store.set, TRAY_STORE_KEY, settings)
    if not saved then
        debug_log("could not update statusTray: " .. tostring(err))
        return
    end

    rune.ui.refresh_bars()
end

local function set_enabled(on)
    if enabled == on then
        say(on and rune.style.green("already on") or rune.style.red("already off"))
        return
    end

    enabled = on
    save_settings()
    update_status_tray(last_coord)
    say(on and rune.style.green("on") or rune.style.red("off"))
end

local function help()
    require("helpstyle")
    local H = helpstyle or {}

    rune.echo(H.title("Faux Sextant"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("fauxSextant or fs"))
    rune.echo(H.line("fauxSextant on|off  (also: fs on|off)"))
    rune.echo(H.line("fauxSextant show|status  (also: fs show|status)"))
    rune.echo(H.line("fauxSextant debug on|off  (also: fs debug on|off)"))
    rune.echo(H.foot("v2.1  enabled=" .. tostring(enabled)
        .. " debug=" .. tostring(debug)))
end

local function handle_command(args)
    local words = {}
    for word in tostring(args or ""):lower():gmatch("%S+") do
        words[#words + 1] = word
    end

    local action, value = words[1] or "", words[2] or ""

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
    elseif action == "debug" and (value == "on" or value == "off") then
        debug = value == "on"
        save_settings()
        say("debug " .. (debug and rune.style.green("on") or rune.style.red("off")))
    else
        say("usage: fauxSextant [on|off|toggle|show|status|debug on|off]")
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

rune.command.add("fauxSextant", handle_command,
    "Update the statusTray SEXTANT field from GMCP coordinates")
rune.command.add("fs", handle_command,
    "Short command for fauxSextant")
