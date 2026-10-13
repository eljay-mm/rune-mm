-- Filename: eljayPlugins/statusTray.lua
-- Purpose: Compact bottom-row status:
--          CRYSTAL x y | QUEST | SEXTANT x y | TELL
-- Version: 1.1
-- Date: 2026-Oct-13
-- Changelog:
--   1.0  Initial implementation as a standalone bottom-row status bar.
--   1.1  Sync the SEXTANT value from rune.store when rendering, so updates
--        from fauxSextant are reflected even if it has a separate module state.

local VERSION = "1.1"
local SETTINGS_KEY = "statustray.settings"
local BAR_NAME = "status_tray"

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

-- Internal state (kept as simple strings or nil)
local state = {
    enabled = true,
    debug = false,
    crystal = nil,  -- "x y" or nil
    quest = "OFF",  -- arbitrary short status string
    sextant = nil,  -- "x y" or nil
    tell = "OFF",   -- "ON"/"OFF" or short text
}

-- Load/save --------------------------------------------------------------
local function load_settings()
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if ok and type(saved) == "table" then
        if type(saved.enabled) == "boolean" then
            state.enabled = saved.enabled
        end
        if type(saved.debug) == "boolean" then
            state.debug = saved.debug
        end
        if type(saved.crystal) == "string" then
            state.crystal = saved.crystal
        end
        if type(saved.quest) == "string" then
            state.quest = saved.quest
        end
        if type(saved.sextant) == "string" then
            state.sextant = saved.sextant
        end
        if type(saved.tell) == "string" then
            state.tell = saved.tell
        end
    end
end

local function save_settings()
    pcall(rune.store.set, SETTINGS_KEY, {
        enabled = state.enabled,
        debug = state.debug,
        crystal = state.crystal,
        quest = state.quest,
        sextant = state.sextant,
        tell = state.tell,
    })
end

-- Utility helpers --------------------------------------------------------
local function dbg(msg)
    if state.debug then
        pcall(rune.echo, "[statusTray:debug] " .. tostring(msg))
    end
end

local function fmt_coord(s)
    if not s or s == "" then return "--" end
    return tostring(s)
end

-- fauxSextant may update this value through rune.store while statusTray
-- remains loaded. Sync the local copy before rendering the bar.
local function sync_sextant_from_store()
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if ok and type(saved) == "table" then
        if type(saved.sextant) == "string" then
            state.sextant = saved.sextant
        elseif saved.sextant == nil then
            state.sextant = nil
        end
    end
end

local function render_one()
    sync_sextant_from_store()

    local crystal = "CRYSTAL " .. fmt_coord(state.crystal)
    local quest = "QUEST " .. tostring(state.quest or "OFF")
    local sextant = "SEXTANT " .. fmt_coord(state.sextant)
    local tell = "TELL " .. tostring(state.tell or "OFF")

    return crystal .. " | " .. quest .. " | " .. sextant .. " | " .. tell
end

-- Bar registration -------------------------------------------------------
rune.ui.bar(BAR_NAME, function()
    if not state.enabled then return nil end
    return render_one()
end)

-- Ensure the bar is present in layouts by wrapping rune.ui.layout once.
if not rune.ui._statusTrayWrapped then
    local orig_layout = rune.ui.layout
    rune.ui._statusTrayWrapped = true

    rune.ui.layout = function(cfg)
        if type(cfg) == "table"
            and cfg.type == "column"
            and type(cfg.children) == "table" then
            local found = false

            for _, child in ipairs(cfg.children) do
                if type(child) == "table"
                    and child.type == "bar"
                    and child.name == BAR_NAME then
                    found = true
                    break
                end
            end

            if not found then
                table.insert(cfg.children, {
                    type = "bar",
                    name = BAR_NAME,
                })
            end
        end

        return orig_layout(cfg)
    end
end

-- If a layout already exists, rebuild it once so the bar appears immediately.
if type(rune_build_layout) == "function" then
    pcall(rune_build_layout, rune.store.get("quest_title"))
end

-- Setters and getters ----------------------------------------------------
local M = {}

-- All setters call refresh and save; they tolerate nil/invalid input.
function M.set_enabled(on)
    local new = (on == true)
    if state.enabled ~= new then
        state.enabled = new
        save_settings()
        rune.ui.refresh_bars()
        dbg("enabled -> " .. tostring(new))
    end
end

function M.toggle_enabled()
    M.set_enabled(not state.enabled)
end

function M.set_debug(on)
    local new = (on == true)
    if state.debug ~= new then
        state.debug = new
        save_settings()
        dbg("debug -> " .. tostring(new))
    end
end

function M.set_crystal(x, y)
    local s = nil
    if x ~= nil then
        s = tostring(x) .. (y ~= nil and (" " .. tostring(y)) or "")
    end

    if state.crystal ~= s then
        state.crystal = s
        save_settings()
        rune.ui.refresh_bars()
        dbg("crystal -> " .. tostring(s))
    end
end

function M.clear_crystal()
    M.set_crystal(nil)
end

function M.set_quest(v)
    v = v and tostring(v) or "OFF"

    if state.quest ~= v then
        state.quest = v
        save_settings()
        rune.ui.refresh_bars()
        dbg("quest -> " .. tostring(v))
    end
end

function M.set_sextant(x, y)
    local s = nil
    if x ~= nil then
        s = tostring(x) .. (y ~= nil and (" " .. tostring(y)) or "")
    end

    if state.sextant ~= s then
        state.sextant = s
        save_settings()
        rune.ui.refresh_bars()
        dbg("sextant -> " .. tostring(s))
    end
end

function M.clear_sextant()
    M.set_sextant(nil)
end

function M.set_tell(v)
    v = v and tostring(v) or "OFF"

    if state.tell ~= v then
        state.tell = v
        save_settings()
        rune.ui.refresh_bars()
        dbg("tell -> " .. tostring(v))
    end
end

function M.clear_tell()
    M.set_tell("OFF")
end

function M.get_state()
    sync_sextant_from_store()

    return {
        enabled = state.enabled,
        debug = state.debug,
        crystal = state.crystal,
        quest = state.quest,
        sextant = state.sextant,
        tell = state.tell,
    }
end

-- Command and help -------------------------------------------------------
local function status_line()
    return string.format(
        "v%s  bar=%s  debug=%s",
        VERSION,
        state.enabled and "on" or "off",
        state.debug and "on" or "off"
    )
end

local function show_help()
    if H then
        pcall(function()
            rune.echo(H.title("Bottom status (CRYSTAL | QUEST | SEXTANT | TELL)"))
            rune.echo(H.section("Commands"))
            rune.echo(H.line("statustray", "show this summary"))
            rune.echo(H.line("statustray on|off", "enable / disable the bar"))
            rune.echo(H.line("statustray debug on|off", "toggle debug messages (default off)"))
            rune.echo(H.line("statustray set crystal <x> <y>", "set crystal coords"))
            rune.echo(H.line("statustray clear crystal", "clear crystal coords"))
            rune.echo(H.line("statustray set sextant <x> <y>", "set sextant coords"))
            rune.echo(H.line("statustray clear sextant", "clear sextant coords"))
            rune.echo(H.line("statustray set quest <text>", "set quest status (short)"))
            rune.echo(H.line("statustray set tell <ON|OFF|text>", "set tell indicator"))
            rune.echo(H.line("statustray show", "echo current bar text"))
            rune.echo(H.foot(status_line()))
        end)
        return
    end

    rune.echo("Bottom status - CRYSTAL | QUEST | SEXTANT | TELL")
    rune.echo("  statustray                show this summary")
    rune.echo("  statustray on|off         enable / disable the bar")
    rune.echo("  statustray debug on|off   toggle debug messages (default off)")
    rune.echo("  statustray set crystal <x> <y>")
    rune.echo("  statustray clear crystal")
    rune.echo("  statustray set sextant <x> <y>")
    rune.echo("  statustray clear sextant")
    rune.echo("  statustray set quest <text>")
    rune.echo("  statustray set tell <ON|OFF|text>")
    rune.echo("  statustray show")
    rune.echo(status_line())
end

-- Parse a small whitespace-separated argument list.
local function words_of(s)
    local t = {}
    for w in tostring(s or ""):gmatch("%S+") do
        t[#t + 1] = w
    end
    return t
end

rune.command.add("statustray", function(args)
    local a = tostring(args or ""):match("^%s*(.-)%s*$")
    if a == "" then
        show_help()
        return
    end

    local w = words_of(a)
    local cmd = (w[1] or ""):lower()

    if cmd == "on" or cmd == "off" then
        M.set_enabled(cmd == "on")
        rune.echo("statustray: bar " .. (state.enabled and "on" or "off"))
        return
    end

    if cmd == "debug" then
        local setting = (w[2] or ""):lower()
        if setting == "on" then
            M.set_debug(true)
        elseif setting == "off" then
            M.set_debug(false)
        else
            rune.echo("usage: statustray debug on|off")
            return
        end

        rune.echo("statustray: debug " .. (state.debug and "on" or "off"))
        return
    end

    if cmd == "set" then
        local what = (w[2] or ""):lower()

        if what == "crystal" then
            if not w[3] then
                rune.echo("usage: statustray set crystal <x> <y>")
                return
            end

            M.set_crystal(w[3], w[4])
            rune.echo("statustray: crystal -> " .. tostring(state.crystal))
            return
        elseif what == "sextant" then
            if not w[3] then
                rune.echo("usage: statustray set sextant <x> <y>")
                return
            end

            M.set_sextant(w[3], w[4])
            rune.echo("statustray: sextant -> " .. tostring(state.sextant))
            return
        elseif what == "quest" then
            local rest = a:match("^%S+%s+%S+%s+(.*)$")
            if not rest or rest == "" then
                rune.echo("usage: statustray set quest <text>")
                return
            end

            M.set_quest(rest)
            rune.echo("statustray: quest -> " .. tostring(state.quest))
            return
        elseif what == "tell" then
            local rest = w[3] or ""
            if rest == "" then
                rune.echo("usage: statustray set tell <ON|OFF|text>")
                return
            end

            local upper = rest:upper()
            M.set_tell(upper == "ON" and "ON" or (upper == "OFF" and "OFF" or rest))
            rune.echo("statustray: tell -> " .. tostring(state.tell))
            return
        else
            rune.echo("unknown set target; use crystal|sextant|quest|tell")
            return
        end
    end

    if cmd == "clear" then
        local what = (w[2] or ""):lower()

        if what == "crystal" then
            M.clear_crystal()
            rune.echo("statustray: crystal cleared")
            return
        elseif what == "sextant" then
            M.clear_sextant()
            rune.echo("statustray: sextant cleared")
            return
        elseif what == "tell" then
            M.clear_tell()
            rune.echo("statustray: tell cleared")
            return
        end

        rune.echo("usage: statustray clear crystal|sextant|tell")
        return
    end

    if cmd == "toggle" then
        local what = (w[2] or ""):lower()
        if what == "enabled" then
            M.toggle_enabled()
            rune.echo("statustray: enabled -> " .. tostring(state.enabled))
            return
        end

        rune.echo("usage: statustray toggle enabled")
        return
    end

    if cmd == "show" then
        rune.echo(render_one())
        return
    end

    show_help()
end, "Bottom status bar: manage bottom row status")

-- Init -------------------------------------------------------------------
load_settings()
dbg("loaded settings: "
    .. tostring(state.crystal)
    .. " / "
    .. tostring(state.sextant))

-- Export module for other plugins to require and call setters.
return M
