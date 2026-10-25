-- Filename: eljayPlugins/characterLog.lua
-- Purpose: Per-character, per-day session logging via rune.log (GMCP name)
-- Version: 2.11
-- Date: 2026-Oct-25
--[[
- insert planning notes here between revisions.
]]
--
-- Changelog:
--   2.11 Defer reload resume to the housekeeping timer; fix help output;
--        persist debug state.
--   2.10 Footer restored to true/false values; file under 16000 bytes.
--   2.9  Help rows use the short alias; store saves re-read first.
--   2.0-2.8  Daily files, charname.lua, reload-safe marker, toggles,
--        jmc-style output, load time and char= in the footer.
--
-- How it works:
--   * The character name comes from charname.lua (get / on_change),
--     lowercased for file names; without that module, GMCP Char.Base is
--     used. One log file per character per day, appended on re-login:
--         <config_dir>/logs/<character>/<character>_<YYYY-MM-DD>.log
--     A session running past midnight rolls over to the next day's file.
--   * On load/login one row is printed: the full log path, which
--     includes the character name.
--   * Lines seen before the name is known are buffered, then written.
--   * Reload-safe: a session marker (name + time) is refreshed in
--     rune.store every 30s; a fresh one at load resumes on the next
--     housekeeping tick and takes over a log already running for that
--     character.
--   * Settings (auto, raw, time) are saved per character; on/off and
--     debug are global. Every save re-reads rune.store first. Prompts and
--     rune.echo output are not logged; Rune's "log-echo" hook still
--     writes your own input.
--
-- Commands (short alias: charlog; bare command shows the summary):
--     charlog on|off          enable / disable the plugin (default on)
--     charlog start | stop    start / stop logging now
--     charlog status | name   show log state / current character name
--     charlog debug [on|off]  toggle debug messages (default off)
--     charlog auto on|off     start logging on login (default on)
--     charlog raw on|off      keep ANSI colours (default on; `less -R`)
--     charlog time on|off     prefix server lines with [HH:MM:SS] (default on)

local T0 = os.clock()
local VERSION = "2.11"

-- Command names: full command and short alias.
local NAME = "characterLog"
local SHORT = "charlog"

local GMCP_PACKAGE = "Char.Base"          -- fallback name source
local TIME_FORMAT = "[%H:%M:%S] "
local PENDING_CAP = 300
local TICK_SECONDS = 5
local HEARTBEAT_TICKS = 6                 -- 6 x 5s = 30s
local SESSION_MAX_AGE = 90

-- Store keys keep their original names so saved settings survive renames.
local SESSION_KEY = "charlog.session"
local ENABLED_KEY = "charlog.enabled"
local DEBUG_KEY = "charlog.debug"
local SETTINGS_PREFIX = "charlog.settings."

local okCN, CN = pcall(require, "charname")
if not okCN or type(CN) ~= "table" then CN = nil end

-- helpstyle is loaded on first help (keeps load time down).
local H
local function helpstyle()
    if not H then
        local ok, mod = pcall(require, "helpstyle")
        if ok and type(mod) == "table" then
            H = mod
        else
            local same = function(t) return t end
            H = {
                title = same,
                section = same,
                foot = same,
                line = function(c, d) return "  " .. c .. "  " .. d end
            }
        end
    end
    return H
end

local function paint(color, text)
    local fn = rune.style and rune.style[color]
    if type(fn) == "function" then
        local ok, out = pcall(fn, text)
        if ok and out then return out end
    end
    return text
end

local function say(msg)
    rune.echo(paint("cyan", "[" .. NAME .. "] ") .. msg)
end

local debug_on = false                    -- default off
local function dbg(msg)
    if debug_on then
        rune.echo(paint("blue", "[" .. NAME .. ":debug] ") .. msg)
    end
end

-- Platform helpers (Windows uses cmd.exe, others a POSIX shell).
local IS_WIN = package.config:sub(1, 1) == "\\"

local function norm(p)
    return (tostring(p):gsub("\\", "/"))
end

-- Quote a path for the shell; nil if it cannot be quoted safely.
local function qpath(p)
    p = tostring(p)
    if IS_WIN then
        if p:find('["%%]') then return nil end
        return '"' .. p:gsub("/", "\\") .. '"'
    end
    return "'" .. (p:gsub("'", "'\\''")) .. "'"
end

-- State
local charname, settings_key, log_dir
local enabled, auto_start, raw_mode, timestamps = true, true, true, true
local started_by_us, writing = false, false
local log_day                             -- YYYY-MM-DD of the file in use
local pending = {}                        -- lines seen before the name
local dir_ready = {}
local tick_count, tick_started, load_ms = 0, false, 0
local resume_checked = false

-- Timestamp, cached per second.
local last_sec, last_stamp = 0, ""
local function stamp()
    local now = os.time()
    if now ~= last_sec then
        last_sec, last_stamp = now, os.date(TIME_FORMAT, now)
    end
    return last_stamp
end

local function today()
    return os.date("%Y-%m-%d")
end

-- Persistence: re-read, change, save, return the table.
local function store_update(key, fn)
    local ok, t = pcall(rune.store.get, key)
    if not ok or type(t) ~= "table" then t = {} end
    fn(t)
    pcall(rune.store.set, key, t)
    return t
end

local function apply_enabled(t)
    enabled = t.on ~= false
end

local function apply_opts(t)
    auto_start, raw_mode, timestamps =
        t.auto ~= false, t.raw ~= false, t.time ~= false
end

local function set_enabled(v)
    apply_enabled(store_update(ENABLED_KEY, function(t) t.on = v end))
end

local function set_debug(v)
    local t = store_update(DEBUG_KEY, function(s) s.on = v end)
    debug_on = t.on == true
end

local function set_opt(field, v)
    if settings_key then
        apply_opts(store_update(settings_key, function(t) t[field] = v end))
    else
        local t = { auto = auto_start, raw = raw_mode, time = timestamps }
        t[field] = v
        apply_opts(t)
    end
end

local function load_settings()
    local ok, t = pcall(rune.store.get, settings_key)
    apply_opts(ok and type(t) == "table" and t or {})
end

local function marker(name, t)
    store_update(SESSION_KEY, function(m)
        m.name, m.t = name, t
    end)
end

local function write_marker()
    if charname then marker(charname, os.time()) end
end

local function read_fresh_marker()
    local ok, m = pcall(rune.store.get, SESSION_KEY)
    if ok and type(m) == "table"
        and type(m.name) == "string" and m.name ~= ""
        and type(m.t) == "number"
        and os.time() - m.t <= SESSION_MAX_AGE then
        return m.name
    end
end

local function buffer_line(text)
    pending[#pending + 1] = text
    if #pending > PENDING_CAP then table.remove(pending, 1) end
end

local function flush_pending()
    for _, text in ipairs(pending) do rune.log.write(text) end
    pending = {}
end

-- Logging control
local function log_path_for(day)
    return string.format("%s/%s_%s.log", log_dir, charname, day)
end

-- Create the log directory (only called when rune.log.start failed).
local function ensure_dir()
    if dir_ready[log_dir] then return true end
    local q = qpath(log_dir)
    if not q then
        say("unsupported characters in log directory: " .. log_dir)
        return false
    end
    -- Parents are created; POSIX directories are private (logs hold chat).
    os.execute(IS_WIN and ("mkdir " .. q .. " >nul 2>&1")
                      or ("umask 077; mkdir -p " .. q))
    dir_ready[log_dir] = true
    dbg("created " .. log_dir)
    return true
end

local function start_log()
    if not enabled then
        return say("plugin is off; type '" .. SHORT .. " on' first")
    end
    if not charname then
        return say("character name not yet known; try again shortly")
    end

    local active = rune.log.status()
    if active then
        writing = true
        return say("already logging to " .. active)
    end

    local day = today()
    local target = log_path_for(day)
    -- Try first (the directory usually exists); create it only on failure.
    local path, err = rune.log.start(target, { raw = raw_mode })
    if not path then
        dbg("start failed (" .. tostring(err) .. "); creating directory")
        if not ensure_dir() then return end
        path, err = rune.log.start(target, { raw = raw_mode })
    end

    if path then
        started_by_us, writing, log_day = true, true, day
        flush_pending()
        say("logging to " .. path)
    else
        say("could not start log: " .. tostring(err))
    end
end

-- Take over a log already running in this character's directory (e.g.
-- after a reload); otherwise start one when auto-start is on.
local function claim_or_start()
    if not enabled then return end
    local active = rune.log.status()
    if active then
        writing = true
        if log_dir and norm(active):find(norm(log_dir), 1, true) then
            started_by_us = true
            log_day = norm(active):match("(%d%d%d%d%-%d%d%-%d%d)%.log$") or today()
            pending = {}
            say("logging to " .. active)
        end
    elseif auto_start then
        start_log()
    else
        say(charname .. ": auto-start off; type '" .. SHORT .. " start'")
    end
end

local function stop_log(quiet)
    if rune.log.stop() then
        started_by_us, writing, log_day = false, false, nil
        if not quiet then say("logging stopped") end
    elseif not quiet then
        say("not logging")
    end
end

-- Character identity (charname.lua, GMCP fallback, or session marker)
local function name_from(data)
    if type(data) == "table" then data = data.name end
    if type(data) == "string" and data ~= "" then return data end
end

-- charname.lua first, otherwise whatever the data carries.
local function current_name(data)
    if CN and CN.get then
        local ok, n = pcall(CN.get)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return name_from(data)
end

-- Restore a recent session marker at most once, after the first timer tick.
local function check_resume()
    if resume_checked then return end
    resume_checked = true
    if not enabled or charname then return end
    local resumed = read_fresh_marker()
    if resumed then adopt_name(resumed) end
end

-- Housekeeping tick: status sync, midnight rollover, marker heartbeat.
local function tick()
    check_resume()
    if not enabled or not charname then return end

    writing = rune.log.status() ~= nil    -- catches logs started elsewhere

    if started_by_us and writing and log_day and today() ~= log_day then
        dbg("midnight rollover from " .. log_day)
        rune.log.stop()
        started_by_us, writing, log_day = false, false, nil
        start_log()
    end

    tick_count = tick_count + 1
    if tick_count >= HEARTBEAT_TICKS then
        tick_count = 0
        write_marker()
    end
end

function adopt_name(raw_name)
    local name = tostring(raw_name or ""):gsub("[^%w_-]", "_"):lower()
    if name == "" or name == charname then return end

    if charname and started_by_us and rune.log.status() then
        stop_log(true)                    -- switched characters
    end

    charname = name
    settings_key = SETTINGS_PREFIX .. name
    log_dir = (rune.config_dir or ".") .. "/logs/" .. name
    load_settings()
    write_marker()
    if not tick_started then
        tick_started = true
        rune.timer.every(TICK_SECONDS, tick, { name = "charlog-tick" })
    end
    dbg("character " .. name .. ", log directory " .. log_dir)
    if not auto_start then pending = {} end
    claim_or_start()
end

-- Status and help
local function status_line()
    return string.format(
        "v%s  char=%s on=%s auto=%s raw=%s time=%s debug=%s log=%s load=%dms",
        VERSION, charname or current_name() or "none", tostring(enabled),
        tostring(auto_start), tostring(raw_mode), tostring(timestamps),
        tostring(debug_on), rune.log.status() and "active" or "idle", load_ms)
end

local function show_status()
    local active = rune.log.status()
    say("character: " .. (charname or current_name() or "(not yet known)"))
    say(active and ("logging to " .. active) or "not logging")
    if log_dir then say("log directory: " .. log_dir) end
    say(status_line())
end

local HELP = {
    { " on|off", "enable or disable the plugin" },
    { " start | stop", "start or stop logging now" },
    { " status | name", "show log state / character" },
    { " debug [on|off]", "toggle debug messages" },
    { " auto on|off", "start logging on login" },
    { " raw on|off", "keep ANSI colours (less -R)" },
    { " time on|off", "timestamp logged lines" },
}

local function show_help()
    local h = helpstyle()
    rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    rune.echo(h.section("Commands:"))
    rune.echo(h.line(NAME, "show this help"))
    for _, r in ipairs(HELP) do
        rune.echo(h.line(SHORT .. r[1], r[2]))
    end
    rune.echo(h.line(SHORT, "short alias for " .. NAME))
    rune.echo(h.foot(status_line()))
end

-- Load global toggle states.
do
    local ok, t = pcall(rune.store.get, ENABLED_KEY)
    apply_enabled(ok and type(t) == "table" and t or {})
    local debug_ok, d = pcall(rune.store.get, DEBUG_KEY)
    debug_on = debug_ok and type(d) == "table" and d.on == true or false
end

-- charname.lua reports login and character switches.
if CN and CN.on_change then
    pcall(CN.on_change, function(old, new)
        if not enabled then return end
        local n = (type(new) == "string" and new ~= "")
            and new or current_name()
        if n then adopt_name(n) end
    end)
end

-- Sole name source without charname.lua; with it, handles same-name logins.
if rune.gmcp and rune.gmcp.on then
    pcall(rune.gmcp.on, GMCP_PACKAGE, function(data)
        if not enabled then return end
        local n = name_from(data) or current_name()
        dbg(GMCP_PACKAGE .. " name=" .. tostring(n))
        if n then adopt_name(n) end
    end)
end

-- Replaces Rune's default "log-output" hook so timestamps can be added.
-- Hot path: returns at once when disabled or when no log is active.
pcall(rune.hooks.disable, "log-output")

rune.hooks.on("output", function(line)
    if not enabled or (charname and not writing) then return end
    local text = raw_mode and line:raw() or line:clean()
    if timestamps then text = stamp() .. text end
    if charname then
        rune.log.write(text)
    else
        buffer_line(text)
    end
end, { priority = 200, name = "charlog-output" })

-- Close our log on disconnect and forget the character.
rune.hooks.on("disconnected", function()
    if started_by_us and rune.log.status() then rune.log.stop() end
    started_by_us, writing, log_day = false, false, nil
    charname, settings_key, log_dir = nil, nil, nil
    pending = {}
    resume_checked = true
    marker("", 0)
end, { name = "charlog-disconnected" })

-- Alias: one regex row for the full command and the short alias.
local OPTS = {
    auto = { "auto-start" },
    raw = { "raw mode", " (applies to the next log started)" },
    time = { "timestamps" },
}

rune.alias.regex("^(?:" .. NAME .. "|" .. SHORT .. ")(\\s.*)?$", function(m)
    local words = {}
    for w in tostring(m[1] or ""):gmatch("%S+") do
        words[#words + 1] = w:lower()
    end
    local action, arg = words[1] or "", words[2]

    if action == "on" or action == "off" then
        set_enabled(action == "on")
        say("plugin " .. (enabled and "ON" or "OFF"))
        if enabled then
            resume_checked = false
            local n = charname or current_name()
            if charname then
                claim_or_start()
            elseif n then
                adopt_name(n)
            end
        else
            if started_by_us and rune.log.status() then stop_log(true) end
            pending = {}
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
        local value = arg == "on" or (arg ~= "off" and not debug_on)
        set_debug(value)
        say("debug " .. (debug_on and "ON" or "OFF"))
    elseif OPTS[action] then
        local on = arg ~= "off"
        set_opt(action, on)
        say(OPTS[action][1] .. " " .. (on and "ON" or "OFF")
            .. (OPTS[action][2] or ""))
    else
        show_help()
    end
end, { name = "charlog" })

-- Start the lightweight timer even if the character is not known yet.
-- It checks the reload marker on its first tick and then continues
-- housekeeping once a character is available.
if not tick_started then
    tick_started = true
    rune.timer.every(TICK_SECONDS, tick, { name = "charlog-tick" })
end

load_ms = math.floor((os.clock() - T0) * 1000 + 0.5)
