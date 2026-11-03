-- Filename: eljayPlugins/statusTray.lua
-- Purpose: Compact bottom-row status bar: CRYSTAL x y | SEXTANT x y | TELL
-- Version: 1.14
-- Date: 2026-Nov-02
--[[
Todo:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.14 TELL also clears when you answer ("You tell <name> '...", formation
--        tells excluded) and on comms show|toggle|all.
--   1.0-1.13 Bottom-row bar, TELL indicator with sender name, exact aliases,
--        cached text, read-modify-write saves, lazy helpstyle, load time.
--
-- How it works:
--   * Registers the bar "status_tray" and wraps rune.ui.layout (once) so it
--     is appended to column layouts; an existing layout is rebuilt once.
--   * The bar shows: CRYSTAL x y | SEXTANT x y | TELL. Missing coordinates
--     show "--". TELL reads "TELL (none)" normally and a red "TELL Received
--     from <sender>" after a tell (the latest sender is shown).
--   * Other plugins can require("eljayPlugins/statusTray") and call
--     set_/clear_ crystal, sextant and tell (set_tell(value, sender)) and
--     set_enabled.
--   * A trigger on "<sender> tells you '..." (any sender, except those in
--     IGNORED_SPEAKERS) turns TELL on. It turns off when the game echoes
--     "You tell <name> '..." (your answer; formation tells excluded) or when
--     you type reply or comms tell|clear|show|toggle|all. The game text is
--     never changed. "tray off" disables all three registrations.
--   * The bar text is cached; SEXTANT is re-read from rune.store at most
--     once a second (fauxSextant writes it).
--   * Values are stripped of control characters and length-limited. Saves
--     write one field into the latest stored table; debug is never saved.
--   * Commands are typed bare (no slash) and match the help output:
--
--     statusTray  (alias: tray)
--     Commands
--       statusTray                  show this help
--       tray on|off                 enable / disable bar and tell tracking
--       tray debug on|off           toggle debug messages (default off)
--       tray set crystal <x> <y>    set crystal coords
--       tray set sextant <x> <y>    set sextant coords
--       tray set tell <text>        set tell text (shown red)
--       tray clear <field>          crystal, sextant or tell
--       tray show                   echo current bar text
--       tray                        short alias for statusTray
--     v1.11  enabled=true  debug=false  load=<n>ms

local t0 = os.clock()

local VERSION = "1.14"
local SETTINGS_KEY = "statustray.settings"
local BAR_NAME = "status_tray"
local MAX_COORD, MAX_TEXT = 16, 24 -- longest coordinate part / text

-- Command names: full command and short alias.
local NAME = "statusTray"
local SHORT = "tray"

-- Senders whose tells must NOT turn TELL on (case-insensitive).
local IGNORED_SPEAKERS = { "The imp", "Wrinkled Leccinum" }

local state = {
    enabled = true, debug = false, -- debug is never persisted
    crystal = nil, sextant = nil,  -- "x y" or nil
    tell = "OFF", sender = nil,    -- "ON"/"OFF"/short text; last tell sender
}
local load_ms = 0
local cache = { text = nil, dirty = true, synced = 0 }

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
    if type(t.tell) == "string" then state.tell = clean(t.tell, MAX_TEXT) end
    if type(t.sender) == "string" and t.sender ~= "" then
        state.sender = clean(t.sender, MAX_TEXT)
    end
end

-- Read-modify-write on the latest stored table; refreshes the local copy.
local function save_field(key, value, key2, value2)
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    local t = (ok and type(saved) == "table") and saved or {}
    t[key] = value
    if key2 then t[key2] = value2 end
    t.debug = nil
    t.quest = nil -- obsolete field from earlier versions
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
        tell = color("red", "TELL Received"
            .. (state.sender and " from " .. state.sender or ""))
    elseif v ~= "OFF" then
        tell = color("red", "TELL " .. v) -- custom text from "set tell"
    end
    return "CRYSTAL " .. (state.crystal or "--")
        .. " | SEXTANT " .. (state.sextant or "--")
        .. " | " .. tell
end

-- Runs ~4x a second; real work only on change (force re-reads the store).
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

-- Setters sanitise input; they save and refresh only on change.
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

-- set_tell(value, sender): the sender is only kept while the value is "ON".
function M.set_tell(v, sender)
    v = norm_text(v)
    local who = nil
    if v == "ON" and sender ~= nil then
        who = clean(sender, MAX_TEXT)
        if who == "" then who = nil end
    end
    if state.tell ~= v or state.sender ~= who then
        state.tell, state.sender = v, who
        save_field("tell", v, "sender", who)
        refresh()
        dbg("tell -> " .. v .. (who and " from " .. who or ""))
    end
end

function M.clear_crystal() M.set_crystal(nil) end
function M.clear_sextant() M.set_sextant(nil) end
function M.clear_tell() M.set_tell(nil) end

-- Tell tracking
-- Names make /reload replace these registrations.
local TELL_IN, TELL_OUT, TELL_HOOK =
    "statustray-tell-on", "statustray-tell-answered", "statustray-tell-off"

local ignored = {} -- lower-cased lookup built once
for _, who in ipairs(IGNORED_SPEAKERS) do
    ignored[tostring(who):lower()] = true
end

-- Typed input that clears TELL: "reply", or "comms <sub>" for these subs.
local CLEAR_SUB = { tell = true, clear = true, show = true, toggle = true, all = true }
local function is_clear_command(s)
    local w, sub = s:match("^%s*(%a+)%s*(%a*)")
    return w == "reply" or (w == "comms" and CLEAR_SUB[sub] == true)
end

local function install_tell_tracking()
    rune.trigger.regex("^.+ tells you '", function(_, ctx)
        if state.enabled then
            local line = ctx and ctx.line and ctx.line:clean() or ""
            local speaker = line:match("^(.-) tells you '")
            if not speaker or (speaker:sub(1, 8) ~= "You tell"
                and not ignored[speaker:lower()]) then
                M.set_tell("ON", speaker)
            end
        end
        return nil
    end, { name = TELL_IN })

    -- Your own answer clears the flag (not formation tells).
    rune.trigger.regex("^You tell .+ '", function(_, ctx)
        if state.tell ~= "OFF" and state.enabled then
            local line = ctx and ctx.line and ctx.line:clean() or ""
            if line:sub(1, 22) ~= "You tell the formation" then M.clear_tell() end
        end
        return nil
    end, { name = TELL_OUT })

    rune.hooks.on("input", function(text)
        if state.tell ~= "OFF" and state.enabled and type(text) == "string"
            and is_clear_command(text:lower()) then
            M.clear_tell()
        end
        return nil
    end, { name = TELL_HOOK })
end

pcall(install_tell_tracking)

-- Switch the triggers and hook with the bar.
apply_enabled = function()
    local verb = state.enabled and "enable" or "disable"
    for _, name in ipairs({ TELL_IN, TELL_OUT }) do
        pcall(function() rune.trigger[verb](name) end)
    end
    pcall(function() rune.hooks[verb](TELL_HOOK) end)
end
if not state.enabled then apply_enabled() end -- saved as off: stay off

-- Help
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

local function help_commands()
    return {
        { NAME, "show this help" },
        { SHORT .. " on|off", "enable / disable bar and tell tracking" },
        { SHORT .. " debug on|off", "toggle debug messages (default off)" },
        { SHORT .. " set crystal <x> <y>", "set crystal coords" },
        { SHORT .. " set sextant <x> <y>", "set sextant coords" },
        { SHORT .. " set tell <text>", "set tell text (shown red)" },
        { SHORT .. " clear <field>", "crystal, sextant or tell" },
        { SHORT .. " show", "echo current bar text" },
        { SHORT, "short alias for " .. NAME },
    }
end

-- Build all rows first; print only if all built.
local function build_help_rows(H, commands)
    local rows = {
        H.title(NAME .. "  (alias: " .. SHORT .. ")"),
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
    for _, c in ipairs(commands) do emit(c[1] .. "  " .. c[2]) end
    emit(status_line())
end

-- Commands
local SETTERS = {
    crystal = { M.set_crystal, true },  -- { setter, takes "x y" }
    sextant = { M.set_sextant, true },
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
            return say("usage: " .. SHORT .. " set|clear crystal|sextant|tell")
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