-- Filename: eljayPlugins/fauxSextant.lua
-- Purpose: Sextant display based on GMCP coordinates
-- Inspired by the MUSHclient plugin by Ruthgul
-- Version 2.0
-- Date: 2026-Oct-09
--
-- Faux sextant for Materia Magica: shows your map coordinates from GMCP
-- (Room.Info -> coord) in a one-line bar at the very bottom of the screen,
-- below the input line and the existing status bar.
--
-- The bar is empty (takes no space) when the sextant is off or the current
-- room has no coordinates (indoors, etc.).
--
-- How the bar gets into the layout: horstgs's init.lua builds the whole screen
-- with rune.ui.layout(). This plugin wraps rune.ui.layout so that any layout
-- built (now or later, e.g. when quests/comms re-declare it) gets a "sextant"
-- bar appended as the last row, then re-applies the layout once at load.
--
-- Commands:
--   /sextant          toggle on/off
--   /sextant on       turn on
--   /sextant off      turn off
--   /sextant show     print the current coordinates in the main window
--   /sextant status   show whether it is on or off

local ENABLED  = true      -- default state at load; flip here to start off
local TAG      = "[sextant]"
local BAR_NAME = "sextant"

local current  = nil       -- formatted bar text for the current room, or nil
local last_coord = nil     -- most recent coord table seen

-- Subscribe at load time; Rune's handshake sends it on connect.
rune.gmcp.subscribe("Room")

local function say(msg)
    rune.echo(rune.style.cyan(TAG) .. " " .. msg)
end

-- Build a printable string from a Room.Info coord table.
-- MM sends coord = { id = <area/map id>, name = <map name>, x = .., y = .. }
-- (plus possibly extra numeric fields, which are shown if present).
-- Returns nil when the room has no usable x/y (indoors etc.).
local function describe(c)
    if type(c) ~= "table" then return nil end

    local x, y = tonumber(c.x), tonumber(c.y)
    if not x or not y then return nil end

    local z = tonumber(c.z)
    local where = ""
    if c.name and c.name ~= "" then
        where = rune.style.yellow(tostring(c.name)) .. "  "
    end

    local text = where
        .. "x " .. rune.style.bold(tostring(x))
        .. "  y " .. rune.style.bold(tostring(y))
    if z then
        text = text .. "  z " .. rune.style.bold(tostring(z))
    end

    return text
end

rune.gmcp.on("Room.Info", function(data)
    local c = data and data.coord
    local text = describe(c)
    if text then last_coord = c end
    current = text
    rune.ui.refresh_bars()
end, { name = "fauxSextant" })

-- The bar. Returning nil gives no content, so the row disappears entirely.
rune.ui.bar(BAR_NAME, function()
    if not ENABLED or not current then return nil end
    return rune.style.cyan("Sextant") .. "  " .. current
end)

-- Layout hook ------------------------------------------------------------
-- Append the sextant bar as the last child of the root column of any layout.
if not rune.ui._fauxSextant_orig then
    local orig = rune.ui.layout
    rune.ui._fauxSextant_orig = orig

    rune.ui.layout = function(cfg)
        if type(cfg) == "table" and cfg.type == "column"
            and type(cfg.children) == "table" then
            local found = false
            for _, child in ipairs(cfg.children) do
                if type(child) == "table" and child.type == "bar"
                    and child.name == BAR_NAME then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(cfg.children, { type = "bar", name = BAR_NAME })
            end
        end
        return orig(cfg)
    end
end

-- If init.lua has already built the layout, rebuild it once so the bar
-- appears now. (If init.lua loads after this plugin, its own build call goes
-- through the wrapper above and nothing more is needed.)
if type(rune_build_layout) == "function" then
    local ok, err = pcall(rune_build_layout, rune.store.get("quest_title"))
    if not ok then
        say(rune.style.red("could not rebuild layout: ") .. tostring(err))
    end
end

local function set_enabled(on)
    ENABLED = on
    rune.ui.refresh_bars()
    say(on and rune.style.green("on") or rune.style.red("off"))
end

rune.command.add("sextant", function(args)
    local arg = (args or ""):lower():match("^%s*(%S*)") or ""

    if arg == "" or arg == "toggle" then
        set_enabled(not ENABLED)
    elseif arg == "on" then
        set_enabled(true)
    elseif arg == "off" then
        set_enabled(false)
    elseif arg == "status" then
        say(ENABLED and rune.style.green("on") or rune.style.red("off"))
    elseif arg == "show" or arg == "now" then
        local text = describe(last_coord)
        if text and current then
            say(text)
        else
            say(rune.style.gray("no coordinates for this room"))
        end
    else
        say("usage: /sextant [on|off|show|status]")
    end
end, "Toggle the faux sextant (GMCP coordinates): on|off|show|status")