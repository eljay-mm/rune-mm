-- Filename: eljayPlugins/characterLog.lua
-- Purpose: Per-character, per-day session logging via rune.log (GMCP name)
-- Version: 2.8
-- Date: 2026-Oct-19
--[[
- insert planning notes here between revisions.
]]
--
-- Changelog:
--   2.8  Help footer row now shows the detected character name (char=).
--   2.7  Help output fixed: the alias row used undefined SHORT / NAME (a
--        runtime error); both are now defined once and used for the alias
--        row, the help rows and the alias pattern. Help follows the jmcSolver layout:
--        "Commands:" section, command rows, short-alias row, then the
--        footer row (no blank row).
--   2.6  Faster load: helpstyle is loaded on first help, the housekeeping
--        timer starts when the character is first known, and the log
--        directory is only created if rune.log.start fails (no shell spawn
--        in the common case). Character name now comes from horstgs'
--        charname.lua (GMCP Char.Base kept as fallback and as the re-login
--        nudge). Load time is reported in the help footer. `characterLog on`
--        now starts logging immediately if the name is already known.
--        Fixed VERSION constant (said 2.4).
--   2.5  Main command renamed to `characterLog`, `charlog` kept as the short
--        alias (one alias row). Message prefix is "[characterLog]".
--   2.0-2.4  Daily files, reload-safe session marker, timestamps, on/off and
--        debug toggles, jmc-style coloured output, cross-platform paths,
--        single-row load output, log pruning removed.
--
-- How it works:
--   * The character name comes from charname.lua (charname.get() and
--     charname.on_change()), lowercased for file and directory names. If
--     that module is missing, GMCP Char.Base is used directly. One log file
--     per character per day; logon/logoff within the same day appends:
--         <config_dir>/logs/<character>/<character>_<YYYY-MM-DD>.log
--     A session that runs past midnight rolls over to the next day's file.
--   * On load/login the plugin prints one row, with the coloured plugin
--     name: the full log path, which includes the character name.
--   * Logging starts when the character name is known. Server lines
--     received before that are buffered and written once the log starts.
--   * Reload-safe: while a character is known, a session marker (name +
--     time) is refreshed in the store every 30s. If the plugin loads and
--     finds a fresh marker, it resumes immediately instead of waiting for
--     the name, and takes over a log that is already running for that
--     character.
--   * Settings (auto, raw, time) are saved per character in rune.store.
--     The plugin on/off state is saved globally in rune.store.
--
-- Commands (short alias: charlog; type `characterLog` alone for the summary):
--     characterLog on|off          enable / disable the plugin (default on)
--     characterLog start | stop    start / stop logging now
--     characterLog status          show whether/where logging is active
--     characterLog name            show the current character name
--     characterLog debug [on|off]  toggle debug messages (default off)
--     characterLog auto on|off     start logging automatically on login (default on)
--     characterLog raw on|off      keep ANSI colours in the log (default on;
--                                  view with `less -R`)
--     characterLog time on|off     prefix each logged server line with [HH:MM:SS]
--                                  (default on; takes effect immediately)
--
-- Notes:
--   * The built-in policy does not log prompts or client messages
--     (rune.echo), so vitals change lines from vitalsChanges.lua are not
--     logged.
--   * Timestamps apply to server output lines. The echo of your own input
--     is still written by Rune's default "log-echo" hook, without a timestamp.
--   * Saved per-character settings override the defaults below.

local T0 = os.clock()

local VERSION = "2.8"

-- Command names: full command and short alias.
local NAME = "characterLog"
local SHORT = "charlog"

-- Fallback name source if charname.lua is unavailable.
local GMCP_PACKAGE = "Char.Base"
local NAME_FIELDS = { "name", "charname", "character", "char" }

local TIME_FORMAT = "[%H:%M:%S] "
local PENDING_CAP = 300

-- Housekeeping tick (status sync + midnight rollover), and heartbeat cadence.
local TICK_SECONDS = 5
local HEARTBEAT_TICKS = 6          -- 6 x 5s = 30s
local SESSION_MAX_AGE = 90

-- Store keys keep their original "charlog" names so saved settings survive
-- the command rename.
local SESSION_KEY = "charlog.session"
local ENABLED_KEY = "charlog.enabled"
local SETTINGS_PREFIX = "charlog.settings."

-- charname.lua (horstgs): optional, loaded once at load (already cached by
-- Rune if another plugin required it).
local okCN, CN = pcall(require, "charname")
if not okCN or type(CN) ~= "table" then CN = nil end

-- helpstyle is loaded on first use (keeps load time down).
local H
local function helpstyle()
    if H == nil then
        local ok, mod = pcall(require, "helpstyle")
        if ok and type(mod) == "table" then
            H = mod
        else
            H = {
                title   = function(t) return t end,
                section = function(t) return t end,
                line    = function(c, d) return "  " .. c .. "  " .. (d or "") end,
                foot    = function(t) return t end,
            }
        end
    end
    return H
end

-- Colour helpers (as in jmcSolver): rune.style.<colour>, plain if missing.
local function paint(color, text)
    local fn = rune.style and rune.style[color]
    if type(fn) == "function" then
        local ok, out = pcall(fn, text)
        if ok and out then return out end
    end
    return text
end

local say_prefix
local function say(msg)
    say_prefix = say_prefix or paint("cyan", "[characterLog] ")
    rune.echo(say_prefix .. msg)
end

local function sanitize(name)
    -- Safe for file names and storage keys; lowercase, never capitalised.
    local s = tostring(name or ""):gsub("[^%w_-]", "_"):lower()
    return s
end

-- Platform helpers (Windows uses cmd.exe, others a POSIX shell).
local IS_WIN = package.config:sub(1, 1) == "\\"

local function norm(p)
    return (tostring(p):gsub("\\", "/"))
end

-- Quote a path for the platform shell; returns nil if it cannot be quoted safely.
local function qpath(p)
    p = tostring(p)
    if IS_WIN then
        if p:find('["%%]') then return nil end
        return '"' .. p:gsub("/", "\\") .. '"'
    end
    return "'" .. (p:gsub("'", "'\\''")) .. "'"
end

-- Identity (set from charname.lua / GMCP)
local charname = nil
local settings_key = nil
local log_dir = nil

-- Settings (defaults; replaced by saved values)
local enabled = true
local auto_start = true
local raw_mode = true
local timestamps = true

local debug_on = false             -- debug messages, default off
local started_by_us = false
local writing = false              -- cached: is a log currently active?
local log_day = nil                -- YYYY-MM-DD of the file currently being written
local pending = {}                 -- lines received before the name is known
local dir_ready = {}               -- directories we already created
local tick_count = 0
local tick_started = false
local load_ms = 0

local dbg_prefix
local function dbg(msg)
    if not debug_on then return end
    dbg_prefix = dbg_prefix or paint("blue", "[characterLog:debug] ")
    rune.echo(dbg_prefix .. msg)
end

-----------------------------------------------------------------------
-- Cached timestamp (os.date once per second, not once per line)
-----------------------------------------------------------------------

local last_sec = 0
local last_stamp = ""

local function stamp()
    local now = os.time()
    if now ~= last_sec then
        last_sec = now
        last_stamp = os.date(TIME_FORMAT, now)
    end
    return last_stamp
end

local function today()
    return os.date("%Y-%m-%d")
end

-----------------------------------------------------------------------
-- Settings (persisted)
-----------------------------------------------------------------------

local function load_enabled()
    local ok, saved = pcall(rune.store.get, ENABLED_KEY)
    if ok and type(saved) == "table" and type(saved.on) == "boolean" then
        enabled = saved.on
    else
        enabled = true
    end
end

local function save_enabled()
    pcall(rune.store.set, ENABLED_KEY, { on = enabled })
end

local function load_settings()
    auto_start, raw_mode, timestamps = true, true, true
    if not settings_key then return end
    local ok, saved = pcall(rune.store.get, settings_key)
    if ok and type(saved) == "table" then
        if type(saved.auto) == "boolean" then auto_start = saved.auto end
        if type(saved.raw) == "boolean" then raw_mode = saved.raw end
        if type(saved.time) == "boolean" then timestamps = saved.time end
    end
end

local function save_settings()
    if not settings_key then return end
    pcall(rune.store.set, settings_key,
        { auto = auto_start, raw = raw_mode, time = timestamps })
end

-----------------------------------------------------------------------
-- Session marker
-----------------------------------------------------------------------

local function write_marker()
    if charname then
        pcall(rune.store.set, SESSION_KEY, { name = charname, t = os.time() })
    end
end

local function clear_marker()
    pcall(rune.store.set, SESSION_KEY, { name = "", t = 0 })
end

local function read_fresh_marker()
    local ok, m = pcall(rune.store.get, SESSION_KEY)
    if ok and type(m) == "table"
        and type(m.name) == "string" and m.name ~= ""
        and type(m.t) == "number"
        and (os.time() - m.t) <= SESSION_MAX_AGE then
        return m.name
    end
    return nil
end

-----------------------------------------------------------------------
-- Pending buffer (lines before the name is known); trimmed in batches
-----------------------------------------------------------------------

local function buffer_line(text)
    pending[#pending + 1] = text
    local n = #pending
    if n > PENDING_CAP * 2 then
        local trimmed = {}
        for i = n - PENDING_CAP + 1, n do
            trimmed[#trimmed + 1] = pending[i]
        end
        pending = trimmed
    end
end

local function flush_pending()
    local n = #pending
    local first = n - PENDING_CAP + 1
    if first < 1 then first = 1 end
    for i = first, n do
        rune.log.write(pending[i])
    end
    pending = {}
end

-----------------------------------------------------------------------
-- Logging control
-----------------------------------------------------------------------

local function sync_writing()
    writing = (rune.log.status() ~= nil)
end

local function log_path_for(day)
    return string.format("%s/%s_%s.log", log_dir, charname, day)
end

-- Create the log directory (only called when rune.log.start failed).
local function ensure_dir()
    if dir_ready[log_dir] then return true end
    local q = qpath(log_dir)
    if not q then
        say("log directory path has unsupported characters: " .. log_dir)
        return false
    end
    if IS_WIN then
        -- mkdir creates parents; errors (already exists) are silenced.
        os.execute("mkdir " .. q .. " >nul 2>&1")
    else
        -- Private directory (logs hold chat).
        os.execute("umask 077; mkdir -p " .. q)
    end
    dir_ready[log_dir] = true
    dbg("created log directory " .. log_dir)
    return true
end

local function start_log()
    if not enabled then
        say("plugin is off; type 'characterLog on' first")
        return
    end
    if not charname then
        say("character name not yet known; try again shortly")
        return
    end

    local active = rune.log.status()
    if active then
        say("already logging to " .. active)
        writing = true
        return
    end

    local day = today()
    local target = log_path_for(day)

    -- Try first (directory usually exists); only spawn a shell to create
    -- the directory if the start fails, then retry once.
    local path, err = rune.log.start(target, { raw = raw_mode })
    if not path then
        dbg("log start failed (" .. tostring(err) .. "); creating directory")
        if not ensure_dir() then return end
        path, err = rune.log.start(target, { raw = raw_mode })
    end

    if path then
        started_by_us = true
        writing = true
        log_day = day
        flush_pending()
        say("logging to " .. path)
    else
        say("could not start log: " .. tostring(err))
    end
end

-- If a log is already running in this character's directory (e.g. the
-- plugin was reloaded), take it over; otherwise start one when auto is on.
local function claim_or_start()
    if not enabled then return end
    local active = rune.log.status()
    if active then
        writing = true
        if log_dir and string.find(norm(active), norm(log_dir), 1, true) then
            started_by_us = true
            log_day = norm(active):match("(%d%d%d%d%-%d%d%-%d%d)%.log$") or today()
            pending = {}
            say("logging to " .. active)
        end
        return
    end

    if auto_start then
        start_log()
    else
        say(charname .. ": auto-start off; type 'characterLog start'")
    end
end

local function stop_log(quiet)
    if rune.log.stop() then
        started_by_us = false
        writing = false
        log_day = nil
        if not quiet then say("logging stopped") end
    elseif not quiet then
        say("not logging")
    end
end

-----------------------------------------------------------------------
-- Character identity (charname.lua, GMCP fallback, or session marker)
-----------------------------------------------------------------------

local function name_from(data)
    if type(data) == "string" then
        return data
    end
    if type(data) == "table" then
        for _, field in ipairs(NAME_FIELDS) do
            local v = data[field]
            if type(v) == "string" and v ~= "" then
                return v
            end
        end
    end
    return nil
end

-- Current name: charname.lua first, otherwise whatever the data carries.
local function current_name(data)
    if CN and CN.get then
        local ok, n = pcall(CN.get)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return name_from(data)
end

local function describe(data)
    if type(data) ~= "table" then return tostring(data) end
    local parts = {}
    for k, v in pairs(data) do
        if type(v) ~= "table" and type(v) ~= "function" then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- Housekeeping tick: status sync, midnight rollover, marker heartbeat.
local function tick()
    if not enabled or not charname then return end

    -- Pick up logs started or stopped outside this plugin (e.g. `log`).
    sync_writing()

    -- Midnight rollover: move to the new day's file.
    if started_by_us and log_day and writing and today() ~= log_day then
        dbg("midnight rollover from " .. log_day)
        rune.log.stop()
        started_by_us = false
        writing = false
        log_day = nil
        start_log()
    end

    -- Session marker heartbeat (every HEARTBEAT_TICKS ticks).
    tick_count = tick_count + 1
    if tick_count >= HEARTBEAT_TICKS then
        tick_count = 0
        write_marker()
    end
end

-- The timer is only registered once a character is known.
local function ensure_tick()
    if tick_started then return end
    tick_started = true
    rune.timer.every(TICK_SECONDS, tick, { name = "charlog-tick" })
end

local function adopt_name(raw_name)
    local name = sanitize(raw_name)
    if name == "" or name == charname then return end

    -- Switched characters: close the previous character's log.
    if charname and started_by_us and rune.log.status() then
        rune.log.stop()
        started_by_us = false
        writing = false
        log_day = nil
    end

    charname = name
    settings_key = SETTINGS_PREFIX .. name
    log_dir = (rune.config_dir or ".") .. "/logs/" .. name
    load_settings()
    write_marker()
    ensure_tick()

    dbg("character " .. name .. ", log directory " .. log_dir)

    if not auto_start then
        pending = {}
    end
    claim_or_start()
end

-----------------------------------------------------------------------
-- Status and help
-----------------------------------------------------------------------

local function status_line()
    local active = rune.log.status()
    return string.format("v%s  char=%s on=%s auto=%s raw=%s time=%s debug=%s log=%s load=%dms",
        VERSION, charname or current_name() or "none", tostring(enabled), tostring(auto_start), tostring(raw_mode),
        tostring(timestamps), tostring(debug_on), active and "active" or "idle",
        load_ms)
end

local function show_status()
    local active = rune.log.status()
    say("character: " .. (charname or current_name() or "(not yet known)"))
    say(active and ("logging to " .. active) or "not logging")
    if log_dir then
        say("log directory: " .. log_dir)
    end
    say(status_line())
end

local function show_help()
    local h = helpstyle()
    rune.echo(h.title(NAME .. " - per-character daily session logging"))
    rune.echo(h.section("Commands:"))
    rune.echo(h.line(NAME .. " on|off", "enable or disable the plugin (default on)"))
    rune.echo(h.line(NAME .. " start | stop", "start or stop logging now"))
    rune.echo(h.line(NAME .. " status | name", "show log state / character name"))
    rune.echo(h.line(NAME .. " debug [on|off]", "toggle debug messages (default off)"))
    rune.echo(h.line(NAME .. " auto on|off", "start logging on login (default on)"))
    rune.echo(h.line(NAME .. " raw on|off", "keep ANSI colours (default on; less -R)"))
    rune.echo(h.line(NAME .. " time on|off", "timestamp each logged line (default on)"))
    rune.echo(h.line(SHORT, "short alias for " .. NAME))
    rune.echo(h.foot(status_line()))
end

-----------------------------------------------------------------------
-- Name sources
-----------------------------------------------------------------------

load_enabled()

-- charname.lua tells us when the name changes (login, character switch).
if CN and CN.on_change then
    pcall(CN.on_change, function(new)
        if not enabled then return end
        local n = (type(new) == "string" and new ~= "") and new or current_name()
        if n then adopt_name(n) end
    end)
end

-- One GMCP listener: the only source when charname.lua is missing, and the
-- nudge that restarts logging when the same character logs back in (the
-- name is unchanged, so on_change does not fire).
if rune.gmcp and rune.gmcp.on then
    pcall(rune.gmcp.on, GMCP_PACKAGE, function(data)
        if not enabled then return end
        if debug_on then
            dbg(GMCP_PACKAGE .. ": " .. describe(data))
        end
        local n = name_from(data) or current_name()
        if n then adopt_name(n) end
    end)
end

-----------------------------------------------------------------------
-- Output logging policy
-----------------------------------------------------------------------
-- Replaces Rune's default "log-output" hook so timestamps can be added.
-- Hot path: when disabled, or the name is known but no log is active,
-- return at once without touching the line.

pcall(rune.hooks.disable, "log-output")

rune.hooks.on("output", function(line)
    if not enabled then
        return
    end
    if charname and not writing then
        return
    end

    local text
    if raw_mode then
        text = line:raw()
    else
        text = line:clean()
    end

    if timestamps then
        text = stamp() .. text
    end

    if charname then
        rune.log.write(text)
    else
        buffer_line(text)
    end
end, { priority = 200, name = "charlog-output" })

-----------------------------------------------------------------------
-- Alias
-----------------------------------------------------------------------

local function on_off(word, current)
    if word == "on" then return true end
    if word == "off" then return false end
    return current
end

-- One alias row: `characterLog` (main command) and `charlog` (short alias).
rune.alias.regex("^(?:" .. NAME .. "|" .. SHORT .. ")(\\s.*)?$", function(m)
    local words = {}
    for word in tostring(m[1] or ""):gmatch("%S+") do
        words[#words + 1] = word:lower()
    end

    local action = words[1] or ""

    if action == "on" or action == "off" then
        enabled = (action == "on")
        save_enabled()
        if enabled then
            say("plugin ON")
            if charname then
                claim_or_start()
            else
                local n = current_name()
                if n then adopt_name(n) end
            end
        else
            if started_by_us and rune.log.status() then stop_log(true) end
            pending = {}
            say("plugin OFF")
        end
    elseif action == "start" then
        start_log()
    elseif action == "stop" then
        stop_log()
    elseif action == "status" then
        show_status()
    elseif action == "name" then
        say("character: " .. (charname or current_name() or "(not yet known)"))
    elseif action == "debug" then
        debug_on = on_off(words[2], not debug_on)
        say("debug " .. (debug_on and "ON" or "OFF"))
    elseif action == "auto" then
        auto_start = (words[2] ~= "off")
        save_settings()
        say("auto-start " .. (auto_start and "ON" or "OFF"))
    elseif action == "raw" then
        raw_mode = (words[2] ~= "off")
        save_settings()
        say("raw mode " .. (raw_mode and "ON" or "OFF")
            .. " (applies to the next log started)")
    elseif action == "time" then
        timestamps = (words[2] ~= "off")
        save_settings()
        say("timestamps " .. (timestamps and "ON" or "OFF"))
    else
        show_help()
    end
end, { name = "charlog" })

-----------------------------------------------------------------------
-- Hooks
-----------------------------------------------------------------------

-- On disconnect: close our log and forget the character, so the next
-- connection (same or different character) starts cleanly when its name
-- arrives.
rune.hooks.on("disconnected", function()
    if started_by_us and rune.log.status() then
        rune.log.stop()
    end
    started_by_us = false
    writing = false
    log_day = nil
    charname = nil
    settings_key = nil
    log_dir = nil
    pending = {}
    clear_marker()
end, { name = "charlog-disconnected" })

-----------------------------------------------------------------------
-- Init: resume after a reload while connected
-----------------------------------------------------------------------

sync_writing()

local resumed = enabled and read_fresh_marker() or nil
if resumed then
    adopt_name(resumed)
elseif not enabled then
    say("plugin OFF; type 'characterLog on'")
end

load_ms = math.floor((os.clock() - T0) * 1000 + 0.5)