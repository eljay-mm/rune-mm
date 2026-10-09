-- Filename: eljayPlugins/characterLog.lua
-- Purpose: Per-character, per-day session logging via rune.log (GMCP name)
-- Version: 2.0
-- Date: 2026-Oct-09
--
-- The character name comes from GMCP (see PACKAGES / NAME_FIELDS below),
-- lowercased for file and directory names. One log file per character per
-- day; logon/logoff within the same day appends to that day's file:
--     <config_dir>/logs/<character>/<character>_<YYYY-MM-DD>.log
-- A session that runs past midnight rolls over to the next day's file.
--
-- Logging starts when the character name arrives via GMCP. Server lines
-- received before that are buffered and written once the log starts.
--
-- Reload-safe: while a character is known, a session marker (name + time)
-- is refreshed in the store every 30s. If the plugin loads and finds a
-- fresh marker, it resumes immediately instead of waiting for GMCP, and
-- takes over a log that is already running for that character. The marker
-- is keyed by RUNE_CHARACTER (only to tell multiple clients apart; the
-- character name itself still comes from GMCP).
--
-- Commands:
--     charlog                 show help
--     charlog start           start logging now
--     charlog stop            stop logging
--     charlog status          show whether/where logging is active
--     charlog name            show the character name received via GMCP
--     charlog debug           toggle dumping of GMCP name packages
--     charlog auto on|off     start logging automatically on login (default on)
--     charlog raw on|off      keep ANSI colours in the log (default on;
--                             view with `less -R`)
--     charlog time on|off     prefix each logged server line with [HH:MM:SS]
--                             (default on; takes effect immediately)
--     charlog keep <days>|off delete this character's log files older than
--                             <days> days when logging starts (default off)
--
-- Notes:
--   * The built-in policy does not log prompts or client messages
--     (rune.echo), so vitals change lines from y_vitalsChanges.lua are not
--     logged.
--   * Timestamps apply to server output lines. The echo of your own input
--     is still written by Rune's default "log-echo" hook, without a timestamp.
--   * Saved per-character settings override the defaults below.

-- GMCP packages that might carry the character name, and the fields to try.
local PACKAGES = { "Char.Info", "Char.Base", "Char.Status", "Char.Name" }
local NAME_FIELDS = { "name", "charname", "character", "char" }

local TIME_FORMAT = "[%H:%M:%S] "
local PENDING_CAP = 300

-- Housekeeping tick (status sync + midnight rollover), and heartbeat cadence.
local TICK_SECONDS = 5
local HEARTBEAT_TICKS = 6          -- 6 x 5s = 30s
local SESSION_MAX_AGE = 90

local function sanitize(name)
    -- Safe for file names and storage keys; lowercase, never capitalised.
    local s = tostring(name or ""):gsub("[^%w_-]", "_"):lower()
    return s
end

-- Session marker key (distinguishes multiple client instances).
local SESSION_KEY = "charlog.session." .. sanitize(os.getenv("RUNE_CHARACTER") or "default")

-- Identity (set from GMCP)
local charname = nil
local settings_key = nil
local log_dir = nil

-- Settings (defaults; replaced by saved per-character values)
local auto_start = true
local raw_mode = true
local timestamps = true
local keep_days = 0                -- 0 = never prune

local started_by_us = false
local writing = false              -- cached: is a log currently active?
local log_day = nil                -- YYYY-MM-DD of the file currently being written
local pending = {}                 -- lines received before the name is known
local gmcp_debug = false
local dir_ready = {}               -- directories we already created
local tick_count = 0

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
-- Settings (persisted per character)
-----------------------------------------------------------------------

local function load_settings()
    auto_start, raw_mode, timestamps, keep_days = true, true, true, 0
    if not settings_key then return end
    local ok, saved = pcall(rune.store.get, settings_key)
    if ok and type(saved) == "table" then
        if type(saved.auto) == "boolean" then auto_start = saved.auto end
        if type(saved.raw) == "boolean" then raw_mode = saved.raw end
        if type(saved.time) == "boolean" then timestamps = saved.time end
        if type(saved.keep) == "number" then keep_days = saved.keep end
    end
end

local function save_settings()
    if not settings_key then return end
    pcall(rune.store.set, settings_key,
        { auto = auto_start, raw = raw_mode, time = timestamps, keep = keep_days })
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
    if dir_ready[log_dir] then return end
    -- charname is sanitised, so this is safe to pass to the shell.
    os.execute("mkdir -p '" .. log_dir .. "'")
    dir_ready[log_dir] = true
end

-- Optional retention: delete this character's old daily files.
local function prune_old()
    if keep_days <= 0 or not log_dir or not charname then return end
    os.execute(string.format(
        "find '%s' -maxdepth 1 -type f -name '%s_*.log' -mtime +%d -delete 2>/dev/null",
        log_dir, charname, keep_days))
end

local function start_log()
    if not charname then
        rune.echo("[charlog] character name not yet received via GMCP; try again shortly")
        return
    end

    local active = rune.log.status()
    if active then
        rune.echo("[charlog] already logging to " .. active)
        writing = true
        return
    end

    ensure_dir()

    local day = today()
    local path, err = rune.log.start(log_path_for(day), { raw = raw_mode })
    if path then
        started_by_us = true
        writing = true
        log_day = day
        flush_pending()
        prune_old()
        rune.echo("[charlog] logging " .. charname .. " to " .. path
            .. (raw_mode and " (raw)" or "")
            .. (timestamps and " (timestamps)" or ""))
    else
        rune.echo("[charlog] could not start log: " .. tostring(err))
    end
end

-- If a log is already running in this character's directory (e.g. the
-- plugin was reloaded), take it over; otherwise start one when auto is on.
local function claim_or_start()
    local active = rune.log.status()
    if active then
        writing = true
        if log_dir and string.find(active, log_dir, 1, true) then
            started_by_us = true
            log_day = active:match("(%d%d%d%d%-%d%d%-%d%d)%.log$") or today()
            pending = {}
            rune.echo("[charlog] continuing log " .. active)
        end
        return
    end

    if auto_start then
        start_log()
    end
end

local function stop_log()
    if rune.log.stop() then
        started_by_us = false
        writing = false
        log_day = nil
        rune.echo("[charlog] logging stopped")
    else
        rune.echo("[charlog] not logging")
    end
end

local function show_status()
    local active = rune.log.status()
    rune.echo("[charlog] character: " .. (charname or "(not yet received via GMCP)"))
    rune.echo("[charlog] " .. (active and ("logging to " .. active) or "not logging"))
    rune.echo("[charlog] auto=" .. tostring(auto_start)
        .. " raw=" .. tostring(raw_mode)
        .. " time=" .. tostring(timestamps)
        .. " keep=" .. (keep_days > 0 and (keep_days .. "d") or "off"))
    if log_dir then
        rune.echo("[charlog] log directory: " .. log_dir)
    end
end

local function show_help()
    rune.echo("charlog - per-character daily session logging (name via GMCP)")
    rune.echo("  charlog start | stop | status | name | debug")
    rune.echo("  charlog auto on|off   start logging on login (default on)")
    rune.echo("  charlog raw on|off    keep ANSI colours (default on; view with less -R)")
    rune.echo("  charlog time on|off   timestamp each logged line (default on)")
    rune.echo("  charlog keep <days>|off  delete logs older than <days> (default off)")
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

    rune.echo("[charlog] character: " .. name)

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

if rune.gmcp and rune.gmcp.on then
    for _, package in ipairs(PACKAGES) do
        pcall(rune.gmcp.on, package, function(data)
            if gmcp_debug then
                rune.echo("[charlog] " .. package .. ": " .. describe(data))
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
    -- Pick up logs started or stopped outside this plugin (e.g. /log).
    sync_writing()

    -- Midnight rollover: move to the new day's file.
    if started_by_us and log_day and writing and today() ~= log_day then
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
-- Hot path: when the name is known but no log is active, return at once
-- without touching the line.

pcall(rune.hooks.disable, "log-output")

rune.hooks.on("output", function(line)
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

rune.alias.regex("^charlog(.*)$", function(m)
    local words = {}
    for word in tostring(m[1] or ""):gmatch("%S+") do
        words[#words + 1] = word:lower()
    end

    local action = words[1] or ""

    if action == "start" then
        start_log()
    elseif action == "stop" then
        stop_log()
    elseif action == "status" then
        show_status()
    elseif action == "name" then
        rune.echo("[charlog] character: " .. (charname or "(not yet received via GMCP)"))
    elseif action == "debug" then
        gmcp_debug = not gmcp_debug
        rune.echo("[charlog] GMCP debug " .. (gmcp_debug and "ON" or "OFF"))
    elseif action == "auto" then
        auto_start = (words[2] ~= "off")
        save_settings()
        rune.echo("[charlog] auto-start " .. (auto_start and "ON" or "OFF"))
    elseif action == "raw" then
        raw_mode = (words[2] ~= "off")
        save_settings()
        rune.echo("[charlog] raw mode " .. (raw_mode and "ON" or "OFF")
            .. " (applies to the next log started)")
    elseif action == "time" then
        timestamps = (words[2] ~= "off")
        save_settings()
        rune.echo("[charlog] timestamps " .. (timestamps and "ON" or "OFF"))
    elseif action == "keep" then
        local n = tonumber(words[2])
        if words[2] == "off" then
            keep_days = 0
            save_settings()
            rune.echo("[charlog] log pruning OFF")
        elseif n and n >= 1 and n <= 3650 then
            keep_days = math.floor(n)
            save_settings()
            rune.echo("[charlog] will delete logs older than " .. keep_days
                .. " days when logging starts")
        else
            rune.echo("[charlog] usage: charlog keep <days>|off")
        end
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

local resumed = read_fresh_marker()
if resumed then
    adopt_name(resumed)
    rune.echo("-- y_characterLog reloaded; resumed for '" .. tostring(charname) .. "' --")
else
    rune.echo("-- y_characterLog loaded -- type 'charlog' for help --")
end