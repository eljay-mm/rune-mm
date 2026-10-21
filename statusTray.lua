-- Filename: eljayPlugins/statusTray.lua
-- Purpose: Compact bottom-row status bar: CRYSTAL x y | QUEST | SEXTANT x y | TELL
-- Version: 1.9
-- Date: 2026-Oct-21
--[[
Todo:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.9  Brought to current standard. Bare commands are exact aliases taking
--        (args, ctx) and all output goes through one emit() helper (display
--        method of annwnQuestSearch.lua). NAME/SHORT command-name locals,
--        with a short-alias help row before the footer. The footer now ends
--        with load=<n>ms. Faster load: helpstyle is required only when help
--        is shown, the help table is built on demand, and the start-up debug
--        line is gone. Saves are now read-modify-write: only the changed
--        field is written into a freshly loaded table (so a SEXTANT value
--        written by fauxSextant is never overwritten with a stale copy), then
--        the in-memory copy is refreshed. The help screen is built before
--        anything is printed. "statusTray off" now also disables the tell
--        trigger and the input hook, not just the bar. IGNORED_SPEAKERS
--        keeps the user's additions.
--   1.8  Fix: "statusTray" and "tray" did nothing when typed bare, because
--        rune.command.add only creates slash commands (/statusTray); they are
--        now aliases, so the bare commands work. The incoming-tell trigger
--        accepts one-word or multi-word speakers, and speakers listed in
--        IGNORED_SPEAKERS (starting with "The imp") are skipped.
--   1.7  Brought to current standard: command renamed to statusTray with
--        tray as the short alias, loader line "[statusTray] v1.7 loaded
--        (statusTray for help)". TELL shows "TELL (none)" when off. The
--        incoming-tell trigger now uses the pattern from comms.lua (one-word
--        speaker, quoted message), which also leaves out "the imp tells
--        you", so the separate ignore list was removed.
--   1.6  TELL display: plain "TELL" (default colour) when off, red
--        "TELL Received" when on.
--   1.5  TELL is also cleared by typing "reply" or "comms clear"; tells from
--        "the imp" no longer turn TELL on.
--   1.4  Performance: the bar text is cached and rebuilt only when a value
--        changes, the SEXTANT store read is throttled to once per second
--        (was four times per second), colour calls happen on rebuild only,
--        and the tell trigger/input hook skip all work when the flag is
--        already in the target state.
--   1.3  TELL turns ON (red) on an incoming tell and back OFF (default
--        colour) when "comms tell" is typed.
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
--   * The bar shows: CRYSTAL x y | QUEST <text> | SEXTANT x y | TELL.
--     Missing coordinates show "--"; quest defaults to OFF. TELL reads
--     "TELL (none)" in the default colour and "TELL Received" in red.
--   * Other plugins can require("eljayPlugins/statusTray") and call the
--     setters set_crystal/clear_crystal, set_sextant/clear_sextant,
--     set_quest, set_tell/clear_tell, set_enabled and get_state.
--   * TELL is driven by two registrations. A trigger on incoming
--     "<speaker> tells you '<message>'" lines (one-word or multi-word
--     speaker) turns it on, unless the speaker is listed in IGNORED_SPEAKERS
--     near the top of this file. An input hook turns it off when
--     "comms tell", "comms clear" or "reply" is typed. "statusTray off"
--     disables both (and hides the bar); neither registration ever changes
--     the game text.
--   * The bar text is cached and rebuilt only when a value changes. SEXTANT
--     is re-read from rune.store ("statustray.settings") at most once per
--     second, so fauxSextant can update it without calling this module.
--   * Values are sanitised (control characters removed) and length-limited
--     before they reach the bar.
--   * The enabled flag and the values are saved with rune.store, one field at
--     a time into the latest stored table; debug is not saved and is always
--     off when the plugin loads.
--   * Commands are exact aliases, typed bare (no slash): "statusTray" (short
--     alias "tray") alone shows help; "statusTray on|off" enables/disables
--     the bar and the tell tracking; "statusTray debug on|off" toggles debug
--     output (default off); "statusTray set|clear
--     <crystal|sextant|quest|tell>" edits values; "statusTray show" echoes
--     the bar text. The help footer shows the version, settings and load time.

local t0 = os.clock()

local VERSION = "1.9"
local SETTINGS_KEY = "statustray.settings"
local BAR_NAME = "status_tray"
local MAX_COORD = 16 -- longest stored coordinate part (bytes)
local MAX_TEXT = 24  -- longest stored quest/tell text (bytes)

-- Command names: full command and short alias.
local NAME = "statusTray"
local SHORT = "tray"

-- Speakers whose tells must NOT turn TELL on. Edit this list: names are
-- compared case-insensitively against the whole speaker, one- or multi-word.
local IGNORED_SPEAKERS = { "The imp", "Wrinkled Leccinum" }

-- Internal state (kept as simple strings or nil)
local state = {
    enabled = true,
    debug = false,  -- never persisted: always off when the plugin loads
    crystal = nil,  -- "x y" or nil
    quest = "OFF",  -- short status string
    sextant = nil,  -- "x y" or nil
    tell = "OFF",   -- "ON"/"OFF" or short text
}

local load_ms = 0 -- set once the plugin has finished loading

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

-- Red text for the bar; plain text if rune.style.red is unavailable.
local function red(text)
    local st = rune.style
    if st ~= nil then
        local ok, out = pcall(function() return st.red(text) end)
        if ok and type(out) == "string" then return out end
    end
    return text
end

-- One output path for everything the plugin prints.
local function emit(line)
    if not pcall(rune.echo, line) then print(tostring(line)) end
end

local function say(msg)
    emit(paint("[" .. NAME .. "] ") .. msg)
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

-- Quest/tell text: sanitised once, "OFF" when empty or nil.
local function norm_text(v)
    if v == nil then return "OFF" end
    local s = clean(v, MAX_TEXT)
    if s == "" then return "OFF" end
    return s
end

local function onoff(flag) return flag and "on" or "off" end

-- Bar text cache: rebuilt only when a value changed (dirty) or when the
-- throttled SEXTANT sync finds a new value.
local cache = { text = nil, dirty = true, synced = 0 }

local function refresh()
    cache.dirty = true
    pcall(rune.ui.refresh_bars)
end

-- Load/save --------------------------------------------------------------
-- fauxSextant writes the sextant field of the stored table, so the in-memory
-- copy is refreshed from the latest stored table whenever one is read.
local function adopt_sextant(t)
    local new = nil
    if type(t.sextant) == "string" then
        new = pair(t.sextant)
    elseif t.sextant ~= nil then
        return -- unexpected type: leave the current value alone
    end

    if state.sextant ~= new then
        state.sextant = new
        cache.dirty = true
    end
end

local function load_settings()
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if not ok or type(saved) ~= "table" then return end

    if type(saved.enabled) == "boolean" then state.enabled = saved.enabled end
    if type(saved.crystal) == "string" then state.crystal = pair(saved.crystal) end
    if type(saved.sextant) == "string" then state.sextant = pair(saved.sextant) end
    if type(saved.quest) == "string" then state.quest = clean(saved.quest, MAX_TEXT) end
    if type(saved.tell) == "string" then state.tell = clean(saved.tell, MAX_TEXT) end
end

-- Read-modify-write: load the latest stored table (it may hold fields written
-- by another plugin), change only the one field, save it back, then refresh
-- the in-memory copy of the fields other plugins write.
local function save_field(key, value)
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    local t = (ok and type(saved) == "table") and saved or {}
    t[key] = value
    t.debug = nil -- debug is not persisted
    if pcall(rune.store.set, SETTINGS_KEY, t) then adopt_sextant(t) end
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
    if ok and type(saved) == "table" then adopt_sextant(saved) end
end

local function build_text()
    local tell_value = tostring(state.tell or "OFF")
    local tell = "TELL (none)"
    if tell_value == "ON" then
        tell = red("TELL Received")
    elseif tell_value ~= "OFF" then
        tell = red("TELL " .. tell_value) -- custom text from "set tell <text>"
    end

    return "CRYSTAL " .. fmt_coord(state.crystal)
        .. " | QUEST " .. tostring(state.quest or "OFF")
        .. " | SEXTANT " .. fmt_coord(state.sextant)
        .. " | " .. tell
end

-- Called by the bar about four times a second, so it only does real work
-- when something changed. force = true re-reads the store immediately.
local function render_one(force)
    local now = os.time()
    if force or now ~= cache.synced then
        cache.synced = now
        sync_sextant_from_store()
    end

    if cache.dirty or not cache.text then
        cache.text = build_text()
        cache.dirty = false
    end
    return cache.text
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
local apply_enabled -- defined with the tell tracking below

local M = {}

-- All setters sanitise input, then save and refresh only when the value
-- changed; they tolerate nil/invalid input.
function M.set_enabled(on)
    local new = (on == true)
    if state.enabled ~= new then
        state.enabled = new
        save_field("enabled", new)
        if apply_enabled then apply_enabled() end
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
        save_field("crystal", s)
        refresh()
        dbg("crystal -> " .. tostring(s))
    end
end

function M.clear_crystal()
    M.set_crystal(nil)
end

function M.set_quest(v)
    v = norm_text(v)
    if state.quest ~= v then
        state.quest = v
        save_field("quest", v)
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
        save_field("sextant", s)
        refresh()
        dbg("sextant -> " .. tostring(s))
    end
end

function M.clear_sextant()
    M.set_sextant(nil)
end

function M.set_tell(v)
    v = norm_text(v)
    if state.tell ~= v then
        state.tell = v
        save_field("tell", v)
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

-- Tell tracking ----------------------------------------------------------
-- Names make /reload replace these registrations instead of stacking them.
local TELL_TRIGGER = "statustray-tell-on"
local TELL_HOOK = "statustray-tell-off"

-- Lower-cased lookup built once from IGNORED_SPEAKERS.
local ignored = {}
for _, who in ipairs(IGNORED_SPEAKERS) do
    ignored[tostring(who):lower()] = true
end

-- Typed commands that clear TELL (input is lower-cased before matching).
local function is_clear_command(lower)
    return lower:find("^%s*comms%s+tell%f[%W]") ~= nil
        or lower:find("^%s*comms%s+clear%f[%W]") ~= nil
        or lower:find("^%s*reply%f[%W]") ~= nil
end

local function install_tell_tracking()
    -- Incoming tell: "<speaker> tells you '<message>'", where the speaker may
    -- be one or several words. Skipped for speakers in IGNORED_SPEAKERS.
    -- Nothing from the line is stored or echoed; it passes through unchanged.
    rune.trigger.regex("^(.+) tells you '(.+)'$", function(_, ctx)
        if state.tell ~= "ON" and state.enabled then
            local line = ctx and ctx.line and ctx.line:clean() or ""
            local speaker = line:match("^(.-) tells you '")
            if speaker and ignored[speaker:lower()] then
                dbg("tell ignored from: " .. speaker:sub(1, 40))
            else
                dbg("incoming tell")
                M.set_tell("ON")
            end
        end
        return nil
    end, { name = TELL_TRIGGER })

    -- Typing a clear command turns the flag back OFF. The input passes
    -- through unchanged, so the game and the comms plugin still get it.
    rune.hooks.on("input", function(text)
        if state.tell ~= "OFF" and state.enabled and type(text) == "string"
            and is_clear_command(text:lower()) then
            dbg("tell cleared by typed command")
            M.clear_tell()
        end
        return nil
    end, { name = TELL_HOOK })
end

local okTell, errTell = pcall(install_tell_tracking)
if not okTell then dbg("tell tracking not installed: " .. tostring(errTell)) end

-- Switch the trigger and the input hook with the bar. The callbacks also
-- check state.enabled, so this stays safe if a registry call is missing.
apply_enabled = function()
    local verb = state.enabled and "enable" or "disable"
    pcall(function() rune.trigger[verb](TELL_TRIGGER) end)
    pcall(function() rune.hooks[verb](TELL_HOOK) end)
end
if not state.enabled then apply_enabled() end -- saved as off: stay off

-- Command and help -------------------------------------------------------
-- Version first, no plugin name, one footer row, load time last.
local function status_line()
    return string.format("v%s  enabled=%s  debug=%s  load=%dms",
        VERSION, tostring(state.enabled), tostring(state.debug), load_ms)
end

-- helpstyle and the command table are only needed when help is shown, so
-- neither costs anything at load.
local H_cache = nil -- nil = not tried yet, false = unavailable
local function get_helpstyle()
    if H_cache == nil then
        local ok, mod = pcall(require, "helpstyle")
        H_cache = (ok and type(mod) == "table") and mod or false
    end
    return H_cache or nil
end

local function help_commands()
    return {
        { NAME, "show this summary" },
        { NAME .. " on|off", "enable / disable the bar and tell tracking" },
        { NAME .. " debug on|off", "toggle debug messages (default off)" },
        { NAME .. " set crystal <x> <y>", "set crystal coords" },
        { NAME .. " clear crystal", "clear crystal coords" },
        { NAME .. " set sextant <x> <y>", "set sextant coords" },
        { NAME .. " clear sextant", "clear sextant coords" },
        { NAME .. " set quest <text>", "set quest status (short)" },
        { NAME .. " clear quest", "reset quest status to OFF" },
        { NAME .. " set tell <ON|OFF|text>", "set tell indicator (OFF = TELL (none), ON = red TELL Received)" },
        { NAME .. " clear tell", "reset tell indicator to OFF" },
        { NAME .. " show", "echo current bar text" },
        { SHORT, "short alias for " .. NAME },
    }
end

-- Build every row first and print only when all of them built, so a
-- helpstyle error can never leave a half-printed screen.
local function build_help_rows(H, commands)
    local rows = {}
    rows[#rows + 1] = H.title("Bottom status (CRYSTAL | QUEST | SEXTANT | TELL)")
    rows[#rows + 1] = H.section("Commands")
    for _, c in ipairs(commands) do
        rows[#rows + 1] = H.line(c[1], c[2])
    end
    rows[#rows + 1] = H.foot(status_line())
    return rows
end

local function show_help()
    local commands = help_commands()

    local H = get_helpstyle()
    if H then
        local ok, rows = pcall(build_help_rows, H, commands)
        if ok and type(rows) == "table" then
            for _, row in ipairs(rows) do emit(row) end
            return
        end
    end

    emit("Bottom status - CRYSTAL | QUEST | SEXTANT | TELL")
    for _, c in ipairs(commands) do
        emit(string.format("  %-34s %s", c[1], c[2]))
    end
    emit(status_line())
end

-- Parse a small whitespace-separated argument list.
local function words_of(s)
    local t = {}
    for w in tostring(s or ""):gmatch("%S+") do
        t[#t + 1] = w
    end
    return t
end

local function on_command(args)
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
            say("usage: " .. NAME .. " debug on|off")
            return
        end

        say("debug " .. onoff(state.debug))
        return
    end

    if cmd == "set" then
        local what = (w[2] or ""):lower()

        if what == "crystal" then
            if not w[3] then
                say("usage: " .. NAME .. " set crystal <x> <y>")
                return
            end

            M.set_crystal(w[3], w[4])
            say("crystal -> " .. tostring(state.crystal))
            return
        elseif what == "sextant" then
            if not w[3] then
                say("usage: " .. NAME .. " set sextant <x> <y>")
                return
            end

            M.set_sextant(w[3], w[4])
            say("sextant -> " .. tostring(state.sextant))
            return
        elseif what == "quest" then
            local rest = a:match("^%S+%s+%S+%s+(.*)$")
            if not rest or rest == "" then
                say("usage: " .. NAME .. " set quest <text>")
                return
            end

            M.set_quest(rest)
            say("quest -> " .. tostring(state.quest))
            return
        elseif what == "tell" then
            local rest = w[3] or ""
            if rest == "" then
                say("usage: " .. NAME .. " set tell <ON|OFF|text>")
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

        say("usage: " .. NAME .. " clear crystal|sextant|quest|tell")
        return
    end

    if cmd == "toggle" then
        local what = (w[2] or ""):lower()
        if what == "enabled" then
            M.toggle_enabled()
            say("enabled -> " .. tostring(state.enabled))
            return
        end

        say("usage: " .. NAME .. " toggle enabled")
        return
    end

    if cmd == "show" then
        emit(render_one(true))
        return
    end

    show_help()
end

-- Bare commands (no slash): exact aliases receive (args, ctx), where args is
-- everything typed after the phrase. The handler returns nothing, so the
-- input is consumed and never reaches the game.
for _, phrase in ipairs({ NAME, SHORT }) do
    local ok, err = pcall(rune.alias.exact, phrase, function(args, ctx)
        on_command(args)
    end)
    if not ok then say("could not register '" .. phrase .. "': " .. tostring(err)) end
end

-- Init -------------------------------------------------------------------
-- Single-row load message.
load_ms = math.floor((os.clock() - t0) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")

-- Export module for other plugins to require and call setters.
return M