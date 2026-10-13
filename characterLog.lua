-- Filename: eljayPlugins/characterLog.lua
-- Purpose: Per-character, per-day session logging via rune.log (GMCP name)
-- Version: 2.4
-- Date: 2026-Oct-13
--
-- Changelog:
--   2.4  Output style copied from jmcSolver: the "[charlog]" plugin name is
--        coloured (cyan; blue for debug) via rune.style. Help fixed to echo
--        the strings returned by helpstyle (H.title / H.section / H.line /
--        H.foot), as jmcSolver does. Load stays a single row.
--   2.3  Removed log pruning (`charlog keep`) entirely. Load output reduced
--        to a single row: the full log path including the character name.
--   2.2  Cross-platform (Linux/macOS/Windows): no POSIX-only shell tools.
--        Directory creation picks mkdir for the OS; log retention now lists
--        the directory and deletes with os.remove (date taken from the file
--        name) instead of `find`; path comparison ignores \ vs /.
--   2.1  Added `charlog on|off` plugin toggle (persisted) and a general
--        `charlog debug` toggle (default off). Help now uses helpstyle
--        with the version in the status footer. Shell paths are quoted
--        safely, log directories are created private (umask 077). Removed
--        the RUNE_CHARACTER dependency; renamed leftover y_ references.
--   2.0  Daily files, reload-safe session marker, timestamps, retention.
--
-- How it works:
--   * The character name comes from GMCP (see PACKAGES / NAME_FIELDS below),
--     lowercased for file and directory names. One log file per character
--     per day; logon/logoff within the same day appends to that day's file:
--         <config_dir>/logs/<character>/<character>_<YYYY-MM-DD>.log
--     A session that runs past midnight rolls over to the next day's file.
--   * On load/login the plugin prints one row, with the coloured plugin
--     name: the full log path, which includes the character name.
--   * Logging starts when the character name arrives via GMCP. Server lines
--     received before that are buffered and written once the log starts.
--   * Reload-safe: while a character is known, a session marker (name +
--     time) is refreshed in the store every 30s. If the plugin loads and
--     finds a fresh marker, it resumes immediately instead of waiting for
--     GMCP, and takes over a log that is already running for that character.
--   * Settings (auto, raw, time) are saved per character in rune.store.
--     The plugin on/off state is saved globally in rune.store.
--
-- Commands (type `charlog` alone for the summary):
--     charlog on|off          enable / disable the plugin (default on)
--     charlog start | stop    start / stop logging now
--     charlog status          show whether/where logging is active
--     charlog name            show the character name received via GMCP
--     charlog debug [on|off]  toggle debug messages (default off)
--     charlog auto on|off     start logging automatically on login (default on)
--     charlog raw on|off      keep ANSI colours in the log (default on;
--                             view with `less -R`)
--     charlog time on|off     prefix each logged server line with [HH:MM:SS]
--                             (default on; takes effect immediately)
--
-- Notes:
--   * The built-in policy does not log prompts or client messages
--     (rune.echo), so vitals change lines from vitalsChanges.lua are not
--     logged.
--   * Timestamps apply to server output lines. The echo of your own input
--     is still written by Rune's default "log-echo" hook, without a timestamp.
--   * Saved per-character settings override the defaults below.

local VERSION = "2.4"

-- GMCP packages that might carry the character name, and the fields to try.
local PACKAGES = { "Char.Info", "Char.Base", "Char.Status", "Char.Name" }
local NAME_FIELDS = { "name", "charname", "character", "char" }

local TIME_FORMAT = "[%H:%M:%S] "
local PENDING_CAP = 300

-- Housekeeping tick (status sync + midnight rollover), and heartbeat cadence.
local TICK_SECONDS = 5
local HEARTBEAT_TICKS = 6          -- 6 x 5s = 30s
local SESSION_MAX_AGE = 90

local SESSION_KEY = "charlog.session"
local ENABLED_KEY = "charlog.enabled"

-- Help styling (copied from autopouch.lua / jmcSolver.lua): the helpstyle
-- functions return strings that are printed with rune.echo. Plain fallback
-- if the module is unavailable.
local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
    H = {
        title   = function(t) return t end,
        section = function(t) return t end,
        line    = function(c, d) return "  " .. c .. "  " .. (d or "") end,
        foot    = function(t) return t end,
    }
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

local function say(msg)
    rune.echo(paint("cyan", "[charlog] ") .. msg)
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

-- Identity (set from GMCP)
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

local function dbg(msg)
    if debug_on then rune.echo(paint("blue", "[charlog:debug] ") .. msg) end
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
        say("plugin is off; type 'charlog on' first")
        return
    end
    if not charname then
        say("character name not yet received via GMCP; try again shortly")
        return
    end

    local active = rune.log.status()
    if active then
        say("already logging to " .. active)
        writing = true
        return
    end

    if not ensure_dir() then return end

    local day = today()
    local path, err = rune.log.start(log_path_for(day), { raw = raw_mode })
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
        say(charname .. ": auto-start off; type 'charlog start'")
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

local function status_line()
    local active = rune.log.status()
    return string.format("v%s  on=%s auto=%s raw=%s time=%s debug=%s log=%s",
        VERSION, tostring(enabled), tostring(auto_start), tostring(raw_mode),
        tostring(timestamps), tostring(debug_on), active and "active" or "idle")
end

local function show_status()
    local active = rune.log.status()
    say("character: " .. (charname or "(not yet received via GMCP)"))
    say((active and ("logging to " .. active) or "not logging"))
    if log_dir then
        say("log directory: " .. log_dir)
    end
    say(status_line())
end

local function show_help()
    rune.echo(H.title("charlog - per-character daily session logging (name via GMCP)"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("charlog on|off", "enable or disable the plugin (default on)"))
    rune.echo(H.line("charlog start | stop", "start or stop logging now"))
    rune.echo(H.line("charlog status | name", "show log state / GMCP character name"))
    rune.echo(H.line("charlog debug [on|off]", "toggle debug messages (default off)"))
    rune.echo(H.line("charlog auto on|off", "start logging on login (default on)"))
    rune.echo(H.line("charlog raw on|off", "keep ANSI colours (default on; less -R)"))
    rune.echo(H.line("charlog time on|off", "timestamp each logged line (default on)"))
    rune.echo("")
    rune.echo(H.foot(status_line()))
end

-----------------------------------------------------------------------
-- Character identity (GMCP, or session marker after a reload)
-----------------------------------------------------------------------

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
    settings_key = "charlog.settings." .. name
    log_dir = (rune.config_dir or ".") .. "/logs/" .. name
    load_settings()
    write_marker()

    dbg("character " .. name .. ", log directory " .. log_dir)

    if not auto_start then
        pending = {}
    end
    claim_or_start()
end

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

load_enabled()

if rune.gmcp and rune.gmcp.on then
    for _, package in ipairs(PACKAGES) do
        pcall(rune.gmcp.on, package, function(data)
            if not enabled then return end
            if debug_on then
                dbg(package .. ": " .. describe(data))
            end
            local n = name_from(data)
            if n then adopt_name(n) end
        end)
    end
end

-----------------------------------------------------------------------
-- Single housekeeping timer: status sync, midnight rollover, heartbeat
-----------------------------------------------------------------------

rune.timer.every(TICK_SECONDS, function()
    if not enabled then return end

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
end, { name = "charlog-tick" })

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

rune.alias.regex("^charlog(\\s.*)?$", function(m)
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
            if charname then claim_or_start() end
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
        say("character: " .. (charname or "(not yet received via GMCP)"))
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
    say("plugin OFF; type 'charlog on'")
end
