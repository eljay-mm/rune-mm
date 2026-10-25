-- Filename: eljayPlugins/statusTray.lua
-- Purpose: Compact bottom-row status bar: CRYSTAL x y | QUEST | SEXTANT x y | TELL
-- Version: 1.10
-- Date: 2026-Oct-25
--[[
Todo:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.10 Size pass (24,722 -> under 16,000 bytes): table-driven set/clear
--        commands and setters, one colour helper, shorter header and help
--        text; help command rows use the short alias; "toggle enabled"
--        removed (use on|off).
--   1.9  Standard pass: exact aliases, emit(), NAME/SHORT, load time in the
--        footer, lazy helpstyle, read-modify-write saves, "off" also disables
--        the tell trigger and the input hook.
--   1.8  Bare commands as aliases (rune.command.add only makes slash
--        commands); multi-word tell speakers; IGNORED_SPEAKERS list.
--   1.3-1.7  TELL indicator (red on an incoming tell); cached bar text.
--   1.0-1.2  Bottom-row bar with CRYSTAL, QUEST and SEXTANT.
--
-- How it works:
--   * Registers one bar, "status_tray", and wraps rune.ui.layout (once) so
--     it is appended to column layouts; an existing layout is rebuilt once.
--   * The bar shows: CRYSTAL x y | QUEST <text> | SEXTANT x y | TELL.
--     Missing coordinates show "--"; quest defaults to OFF. TELL reads
--     "TELL (none)" normally and a red "TELL Received" after a tell.
--   * Other plugins can require("eljayPlugins/statusTray") and call
--     set_crystal/clear_crystal, set_sextant/clear_sextant, set_quest,
--     set_tell/clear_tell, set_enabled and get_state.
--   * A trigger on "<speaker> tells you '<message>'" (one- or multi-word
--     speaker, except those in IGNORED_SPEAKERS) turns TELL on; an input
--     hook turns it off when "comms tell", "comms clear" or "reply" is typed.
--     Neither changes the game text. "statusTray off" disables both.
--   * The bar text is cached and rebuilt only when a value changes; SEXTANT
--     is re-read from rune.store at most once a second (fauxSextant).
--   * Values are stripped of control characters and length-limited. Saves
--     write one field into the latest stored table; debug is never saved.
--   * Commands (bare, no slash): "statusTray" alone shows help; short alias
--     "tray". on|off, debug on|off, set|clear crystal|sextant|quest|tell,
--     show. The help footer shows version, settings and load time.

local t0 = os.clock()

local VERSION = "1.10"
local SETTINGS_KEY = "statustray.settings"
local BAR_NAME = "status_tray"
local MAX_COORD, MAX_TEXT = 16, 24 -- longest stored coordinate part / text

-- Command names: full command and short alias.
local NAME = "statusTray"
local SHORT = "tray"

-- Speakers whose tells must NOT turn TELL on (case-insensitive).
local IGNORED_SPEAKERS = { "The imp", "Wrinkled Leccinum" }

local state = {
    enabled = true,
    debug = false,  -- never persisted
    crystal = nil,  -- "x y" or nil
    quest = "OFF",
    sextant = nil,  -- "x y" or nil
    tell = "OFF",   -- "ON", "OFF" or short text
}
local load_ms = 0
local cache = { text = nil, dirty = true, synced = 0 }

-- Output helpers
local function color(name, text)
    local st = rune.style
    if st ~= nil then
        local ok, out = pcall(function() return st[name](text) end)
        if ok and type(out) == "string" then return out end
    end
    return text
end

local function emit(line)
    if not pcall(rune.echo, line) then print(tostring(line)) end
end

local function say(msg)
    emit(color("cyan", "[" .. NAME .. "] ") .. msg)
end

local function dbg(msg)
    if state.debug then say("debug: " .. tostring(msg)) end
end

-- Input helpers
-- Strip control characters (including ESC), trim, limit the length.
local function clean(v, max)
    local s = tostring(v)
    s = s:gsub("[%c\127]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return s:sub(1, max)
end

-- "x" or "x y"; nil if there is no usable first value.
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

local function norm_text(v)
    if v == nil then return "OFF" end
    local s = clean(v, MAX_TEXT)
    return s == "" and "OFF" or s
end

local function refresh()
    cache.dirty = true
    pcall(rune.ui.refresh_bars)
end

-- Load/save
-- fauxSextant writes the stored sextant field; keep the local copy current.
local function adopt_sextant(t)
    local new = nil
    if type(t.sextant) == "string" then
        new = pair(t.sextant)
    elseif t.sextant ~= nil then
        return
    end
    if state.sextant ~= new then
        state.sextant = new
        cache.dirty = true
    end
end

local function load_settings()
    local ok, t = pcall(rune.store.get, SETTINGS_KEY)
    if not ok or type(t) ~= "table" then return end
    if type(t.enabled) == "boolean" then state.enabled = t.enabled end
    if type(t.crystal) == "string" then state.crystal = pair(t.crystal) end
    if type(t.sextant) == "string" then state.sextant = pair(t.sextant) end
    if type(t.quest) == "string" then state.quest = clean(t.quest, MAX_TEXT) end
    if type(t.tell) == "string" then state.tell = clean(t.tell, MAX_TEXT) end
end

-- Read-modify-write: change one field of the latest stored table, save,
-- then refresh the local copy.
local function save_field(key, value)
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    local t = (ok and type(saved) == "table") and saved or {}
    t[key] = value
    t.debug = nil
    if pcall(rune.store.set, SETTINGS_KEY, t) then adopt_sextant(t) end
end

local function sync_sextant_from_store()
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if ok and type(saved) == "table" then adopt_sextant(saved) end
end

-- Rendering
local function build_text()
    local tell, v = "TELL (none)", tostring(state.tell or "OFF")
    if v == "ON" then
        tell = color("red", "TELL Received")
    elseif v ~= "OFF" then
        tell = color("red", "TELL " .. v) -- custom text from "set tell"
    end
    return "CRYSTAL " .. (state.crystal or "--")
        .. " | QUEST " .. tostring(state.quest or "OFF")
        .. " | SEXTANT " .. (state.sextant or "--")
        .. " | " .. tell
end

-- Runs about 4x a second: real work only on change. force re-reads the store.
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

load_settings() -- before the bar is registered, so the first render is right

pcall(rune.ui.bar, BAR_NAME, function()
    if not state.enabled then return nil end
    return render_one()
end)

-- Append the bar to column layouts by wrapping rune.ui.layout once.
local function install_layout_hook()
    if type(rune.ui) ~= "table" or rune.ui._statusTrayWrapped then return end
    local orig = rune.ui.layout
    if type(orig) ~= "function" then return end
    rune.ui._statusTrayWrapped = true

    rune.ui.layout = function(cfg)
        if type(cfg) == "table" and cfg.type == "column"
            and type(cfg.children) == "table" then
            local found = false
            for _, c in ipairs(cfg.children) do
                if type(c) == "table" and c.type == "bar" and c.name == BAR_NAME then
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
pcall(install_layout_hook)

-- If a layout already exists, rebuild it once so the bar appears at once.
if type(rune_build_layout) == "function" then
    pcall(function() rune_build_layout(rune.store.get("quest_title")) end)
end

-- Setters and getters
local apply_enabled -- defined with the tell tracking below
local M = {}

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

function M.set_debug(on)
    state.debug = (on == true)
end

-- Each setter sanitises its input, then saves and refreshes only on change.
local function make_setter(key, norm)
    return function(...)
        local v = norm(...)
        if state[key] ~= v then
            state[key] = v
            save_field(key, v)
            refresh()
            dbg(key .. " -> " .. tostring(v))
        end
    end
end

M.set_crystal = make_setter("crystal", pair)
M.set_sextant = make_setter("sextant", pair)
M.set_quest = make_setter("quest", norm_text)
M.set_tell = make_setter("tell", norm_text)

function M.clear_crystal() M.set_crystal(nil) end
function M.clear_sextant() M.set_sextant(nil) end
function M.clear_quest() M.set_quest(nil) end
function M.clear_tell() M.set_tell(nil) end

function M.get_state()
    sync_sextant_from_store()
    return {
        enabled = state.enabled, debug = state.debug,
        crystal = state.crystal, quest = state.quest,
        sextant = state.sextant, tell = state.tell,
    }
end

-- Tell tracking
-- Names make /reload replace these registrations.
local TELL_TRIGGER, TELL_HOOK = "statustray-tell-on", "statustray-tell-off"

local ignored = {} -- lower-cased lookup built once
for _, who in ipairs(IGNORED_SPEAKERS) do
    ignored[tostring(who):lower()] = true
end

-- Typed commands that clear TELL (input is lower-cased before matching).
local function is_clear_command(s)
    return s:find("^%s*comms%s+tell%f[%W]") ~= nil
        or s:find("^%s*comms%s+clear%f[%W]") ~= nil
        or s:find("^%s*reply%f[%W]") ~= nil
end

local function install_tell_tracking()
    -- Nothing from the line is stored or echoed; it passes through unchanged.
    rune.trigger.regex("^(.+) tells you '(.+)'$", function(_, ctx)
        if state.tell ~= "ON" and state.enabled then
            local line = ctx and ctx.line and ctx.line:clean() or ""
            local speaker = line:match("^(.-) tells you '")
            if speaker and ignored[speaker:lower()] then
                dbg("tell ignored")
            else
                M.set_tell("ON")
            end
        end
        return nil
    end, { name = TELL_TRIGGER })

    -- The typed input passes through, so the game still receives it.
    rune.hooks.on("input", function(text)
        if state.tell ~= "OFF" and state.enabled and type(text) == "string"
            and is_clear_command(text:lower()) then
            M.clear_tell()
        end
        return nil
    end, { name = TELL_HOOK })
end

local okTell, errTell = pcall(install_tell_tracking)
if not okTell then dbg("tell tracking failed: " .. tostring(errTell)) end

-- Switch the trigger and hook with the bar (callbacks also check enabled).
apply_enabled = function()
    local verb = state.enabled and "enable" or "disable"
    pcall(function() rune.trigger[verb](TELL_TRIGGER) end)
    pcall(function() rune.hooks[verb](TELL_HOOK) end)
end
if not state.enabled then apply_enabled() end -- saved as off: stay off

-- Help
-- Version first, no plugin name, one footer row, load time last.
local function status_line()
    return string.format("v%s  enabled=%s  debug=%s  load=%dms",
        VERSION, tostring(state.enabled), tostring(state.debug), load_ms)
end

-- helpstyle is only needed when help is shown, so it costs nothing at load.
local H_cache = nil -- nil = not tried yet, false = unavailable
local function get_helpstyle()
    if H_cache == nil then
        local ok, mod = pcall(require, "helpstyle")
        H_cache = (ok and type(mod) == "table") and mod or false
    end
    return H_cache or nil
end

-- Rows stay within 76 characters (the footer excepted).
local function help_commands()
    return {
        { NAME, "show this help" },
        { SHORT .. " on|off", "enable / disable bar and tell tracking" },
        { SHORT .. " debug on|off", "toggle debug messages (default off)" },
        { SHORT .. " set crystal <x> <y>", "set crystal coords" },
        { SHORT .. " set sextant <x> <y>", "set sextant coords" },
        { SHORT .. " set quest <text>", "set quest status (short)" },
        { SHORT .. " set tell <text>", "set tell text (shown red)" },
        { SHORT .. " clear <field>", "crystal, sextant, quest or tell" },
        { SHORT .. " show", "echo current bar text" },
        { SHORT, "short alias for " .. NAME },
    }
end

-- Build all rows first; print only if all built.
local function build_help_rows(H, commands)
    local rows = {
        H.title("statusTray  (alias: tray)"),
        H.section("Commands"),
    }
    for _, c in ipairs(commands) do rows[#rows + 1] = H.line(c[1], c[2]) end
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
        emit(string.format("  %-30s %s", c[1], c[2]))
    end
    emit(status_line())
end

-- Commands
local SETTERS = {
    crystal = { M.set_crystal, true },  -- { setter, takes "x y" }
    sextant = { M.set_sextant, true },
    quest = { M.set_quest, false },
    tell = { M.set_tell, false },
}

local function on_command(args)
    local a = tostring(args or ""):match("^%s*(.-)%s*$")
    if a == "" then return show_help() end

    local cmd, what, rest = a:match("^(%S+)%s*(%S*)%s*(.-)$")
    cmd, what = cmd:lower(), what:lower()

    if cmd == "on" or cmd == "off" then
        M.set_enabled(cmd == "on")
        return say("bar " .. cmd)
    elseif cmd == "debug" then
        if what ~= "on" and what ~= "off" then
            return say("usage: " .. SHORT .. " debug on|off")
        end
        M.set_debug(what == "on")
        return say("debug " .. what)
    elseif cmd == "show" then
        return emit(render_one(true))
    elseif cmd == "set" or cmd == "clear" then
        local s = SETTERS[what]
        if not s then
            return say("usage: " .. SHORT .. " set|clear crystal|sextant|quest|tell")
        end
        if cmd == "clear" then
            s[1](nil)
            return say(what .. " cleared")
        end
        if rest == "" then
            return say("usage: " .. SHORT .. " set " .. what
                .. (s[2] and " <x> <y>" or " <text>"))
        end
        if s[2] then
            local x, y = rest:match("^(%S+)%s*(%S*)")
            s[1](x, y ~= "" and y or nil)
        else
            local u = rest:upper()
            s[1]((u == "ON" or u == "OFF") and u or rest)
        end
        return say(what .. " -> " .. tostring(state[what]))
    end

    show_help()
end

-- Bare commands: exact aliases receive (args, ctx); returning nothing
-- consumes the input.
for _, phrase in ipairs({ NAME, SHORT }) do
    local ok, err = pcall(rune.alias.exact, phrase, function(args, ctx)
        on_command(args)
    end)
    if not ok then say("could not register '" .. phrase .. "': " .. tostring(err)) end
end

-- Init
load_ms = math.floor((os.clock() - t0) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")

return M