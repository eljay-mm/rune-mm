-- Filename: eljayPlugins/statusTray.lua
-- Purpose: Compact bottom-row status bar: CRYSTAL x y | QUEST | SEXTANT x y | TELL
-- Version: 1.2
-- Date: 2026-Oct-13
-- Changelog:
--   1.2  Brought to current house style: "How it works" header, single-row
--        coloured load message, debug never persisted (always off at load),
--        shared-store saves keep fields written by other plugins, input
--        sanitised and length-limited, UI calls guarded with pcall, settings
--        loaded before the first render, "clear quest" added.
--   1.1  Sync the SEXTANT value from rune.store when rendering, so updates
--        from fauxSextant are reflected even if it has a separate module state.
--   1.0  Initial implementation as a standalone bottom-row status bar.
--
-- How it works:
--   * Registers one bar, "status_tray", and hooks rune.ui.layout (once) so the
--     bar is appended to column layouts; an existing layout is rebuilt on load
--     so the bar appears immediately.
--   * The bar shows: CRYSTAL x y | QUEST <text> | SEXTANT x y | TELL <text>.
--     Missing coordinates show "--"; quest and tell default to OFF.
--   * Other plugins can require("eljayPlugins/statusTray") and call the
--     setters set_crystal/clear_crystal, set_sextant/clear_sextant,
--     set_quest, set_tell/clear_tell, set_enabled and get_state.
--   * SEXTANT is re-read from rune.store ("statustray.settings") on every
--     render, so fauxSextant can update it without calling this module.
--   * Values are sanitised (control characters removed) and length-limited
--     before they reach the bar.
--   * The enabled flag and the values are saved with rune.store; debug is not
--     saved and is always off when the plugin loads.
--   * Commands: type "statustray" alone for help; "statustray on|off"
--     enables/disables the bar; "statustray debug on|off" toggles debug output
--     (default off); "statustray set|clear <crystal|sextant|quest|tell>" edits
--     values; "statustray show" echoes the bar text.

local VERSION = "1.2"
local SETTINGS_KEY = "statustray.settings"
local BAR_NAME = "status_tray"
local MAX_COORD = 16 -- longest stored coordinate part (bytes)
local MAX_TEXT = 24  -- longest stored quest/tell text (bytes)

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

-- Internal state (kept as simple strings or nil)
local state = {
    enabled = true,
    debug = false,  -- never persisted: always off when the plugin loads
    crystal = nil,  -- "x y" or nil
    quest = "OFF",  -- short status string
    sextant = nil,  -- "x y" or nil
    tell = "OFF",   -- "ON"/"OFF" or short text
}

-- Output helpers ---------------------------------------------------------
-- Cyan "[statusTray] " prefix. Tries rune.style.cyan(text) first, then
-- rune.style("cyan", text); falls back to plain text if neither works.
local function paint(text)
    local st = rune.style
    if st ~= nil then
        local ok, out = pcall(function() return st.cyan(text) end)
        if ok and type(out) == "string" then return out end
        ok, out = pcall(st, "cyan", text)
        if ok and type(out) == "string" then return out end
    end
    return text
end

local function say(msg)
    local line = paint("[statusTray] ") .. msg
    if not pcall(rune.echo, line) then print("[statusTray] " .. msg) end
end

local function dbg(msg)
    if state.debug then say("debug: " .. tostring(msg)) end
end

-- Input helpers ----------------------------------------------------------
-- Remove control characters (including ESC) and trim, then limit the length,
-- so nothing typed or passed in can inject escape sequences into the bar.
local function clean(v, max)
    local s = tostring(v)
    s = s:gsub("[%c\127]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return s:sub(1, max)
end

-- "x" or "x y" from one or two values; nil if there is no usable first value.
local function pair(x, y)
    if x == nil then return nil end
    local a = clean(x, MAX_COORD)
    if a == "" then return nil end
    if y ~= nil then
        local b = clean(y, MAX_COORD)
        if b ~= "" then return a .. " " .. b end
    end
    return a
end

local function onoff(flag) return flag and "on" or "off" end

local function refresh()
    pcall(function() rune.ui.refresh_bars() end)
end

-- Load/save --------------------------------------------------------------
local function load_settings()
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if not ok or type(saved) ~= "table" then return end

    if type(saved.enabled) == "boolean" then state.enabled = saved.enabled end
    if type(saved.crystal) == "string" then state.crystal = pair(saved.crystal) end
    if type(saved.sextant) == "string" then state.sextant = pair(saved.sextant) end
    if type(saved.quest) == "string" then state.quest = clean(saved.quest, MAX_TEXT) end
    if type(saved.tell) == "string" then state.tell = clean(saved.tell, MAX_TEXT) end
end

-- Update our fields inside the stored table and keep any other fields that
-- another plugin (for example fauxSextant) wrote there.
local function save_settings()
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    local t = (ok and type(saved) == "table") and saved or {}
    t.enabled = state.enabled
    t.crystal = state.crystal
    t.quest = state.quest
    t.sextant = state.sextant
    t.tell = state.tell
    t.debug = nil -- debug is not persisted
    pcall(rune.store.set, SETTINGS_KEY, t)
end

-- Rendering --------------------------------------------------------------
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
            state.sextant = pair(saved.sextant)
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

-- Settings are loaded before the bar is registered so the first render is right.
load_settings()

-- Bar registration -------------------------------------------------------
pcall(rune.ui.bar, BAR_NAME, function()
    if not state.enabled then return nil end
    return render_one()
end)

-- Ensure the bar is present in layouts by wrapping rune.ui.layout once.
local function install_layout_hook()
    if type(rune.ui) ~= "table" or rune.ui._statusTrayWrapped then return end
    local orig_layout = rune.ui.layout
    if type(orig_layout) ~= "function" then return end
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
pcall(install_layout_hook)

-- If a layout already exists, rebuild it once so the bar appears immediately.
if type(rune_build_layout) == "function" then
    pcall(function() rune_build_layout(rune.store.get("quest_title")) end)
end

-- Setters and getters ----------------------------------------------------
local M = {}

-- All setters sanitise input, then save and refresh only when the value
-- changed; they tolerate nil/invalid input.
function M.set_enabled(on)
    local new = (on == true)
    if state.enabled ~= new then
        state.enabled = new
        save_settings()
        refresh()
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
        dbg("debug -> " .. tostring(new))
    end
end

function M.set_crystal(x, y)
    local s = pair(x, y)
    if state.crystal ~= s then
        state.crystal = s
        save_settings()
        refresh()
        dbg("crystal -> " .. tostring(s))
    end
end

function M.clear_crystal()
    M.set_crystal(nil)
end

function M.set_quest(v)
    v = (v ~= nil and clean(v, MAX_TEXT) ~= "") and clean(v, MAX_TEXT) or "OFF"
    if state.quest ~= v then
        state.quest = v
        save_settings()
        refresh()
        dbg("quest -> " .. tostring(v))
    end
end

function M.clear_quest()
    M.set_quest("OFF")
end

function M.set_sextant(x, y)
    local s = pair(x, y)
    if state.sextant ~= s then
        state.sextant = s
        save_settings()
        refresh()
        dbg("sextant -> " .. tostring(s))
    end
end

function M.clear_sextant()
    M.set_sextant(nil)
end

function M.set_tell(v)
    v = (v ~= nil and clean(v, MAX_TEXT) ~= "") and clean(v, MAX_TEXT) or "OFF"
    if state.tell ~= v then
        state.tell = v
        save_settings()
        refresh()
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
-- Version first, no plugin name, one footer row.
local function status_line()
    return string.format("v%s  bar=%s  debug=%s",
        VERSION, onoff(state.enabled), onoff(state.debug))
end

local function show_help()
    if H then
        local ok = pcall(function()
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
            rune.echo(H.line("statustray clear quest", "reset quest status to OFF"))
            rune.echo(H.line("statustray set tell <ON|OFF|text>", "set tell indicator"))
            rune.echo(H.line("statustray clear tell", "reset tell indicator to OFF"))
            rune.echo(H.line("statustray show", "echo current bar text"))
            rune.echo(H.foot(status_line()))
        end)
        if ok then return end
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
    rune.echo("  statustray clear quest")
    rune.echo("  statustray set tell <ON|OFF|text>")
    rune.echo("  statustray clear tell")
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
        say("bar " .. onoff(state.enabled))
        return
    end

    if cmd == "debug" then
        local setting = (w[2] or ""):lower()
        if setting == "on" then
            M.set_debug(true)
        elseif setting == "off" then
            M.set_debug(false)
        else
            say("usage: statustray debug on|off")
            return
        end

        say("debug " .. onoff(state.debug))
        return
    end

    if cmd == "set" then
        local what = (w[2] or ""):lower()

        if what == "crystal" then
            if not w[3] then
                say("usage: statustray set crystal <x> <y>")
                return
            end

            M.set_crystal(w[3], w[4])
            say("crystal -> " .. tostring(state.crystal))
            return
        elseif what == "sextant" then
            if not w[3] then
                say("usage: statustray set sextant <x> <y>")
                return
            end

            M.set_sextant(w[3], w[4])
            say("sextant -> " .. tostring(state.sextant))
            return
        elseif what == "quest" then
            local rest = a:match("^%S+%s+%S+%s+(.*)$")
            if not rest or rest == "" then
                say("usage: statustray set quest <text>")
                return
            end

            M.set_quest(rest)
            say("quest -> " .. tostring(state.quest))
            return
        elseif what == "tell" then
            local rest = w[3] or ""
            if rest == "" then
                say("usage: statustray set tell <ON|OFF|text>")
                return
            end

            local upper = rest:upper()
            M.set_tell(upper == "ON" and "ON" or (upper == "OFF" and "OFF" or rest))
            say("tell -> " .. tostring(state.tell))
            return
        else
            say("unknown set target; use crystal|sextant|quest|tell")
            return
        end
    end

    if cmd == "clear" then
        local what = (w[2] or ""):lower()

        if what == "crystal" then
            M.clear_crystal()
            say("crystal cleared")
            return
        elseif what == "sextant" then
            M.clear_sextant()
            say("sextant cleared")
            return
        elseif what == "quest" then
            M.clear_quest()
            say("quest cleared")
            return
        elseif what == "tell" then
            M.clear_tell()
            say("tell cleared")
            return
        end

        say("usage: statustray clear crystal|sextant|quest|tell")
        return
    end

    if cmd == "toggle" then
        local what = (w[2] or ""):lower()
        if what == "enabled" then
            M.toggle_enabled()
            say("enabled -> " .. tostring(state.enabled))
            return
        end

        say("usage: statustray toggle enabled")
        return
    end

    if cmd == "show" then
        rune.echo(render_one())
        return
    end

    show_help()
end, "Bottom status bar: manage bottom row status")

-- Init -------------------------------------------------------------------
dbg("loaded settings: "
    .. tostring(state.crystal)
    .. " / "
    .. tostring(state.sextant))

-- Single-row load message.
say(status_line())

-- Export module for other plugins to require and call setters.
return M