-- Filename: eljayPlugins/clipCommandOutput.lua
-- Purpose: Copy the output of a command to the clipboard.
-- Version: 2.3
-- Date: 2026-Oct-16
-- Changelog:
--   2.3    Persist settings; enforce the byte cap during capture; bound idle wait; expand a leading ~ in file paths.
--   2.2    Full command is clipCommandOutput (clip stays as the short alias); added on/off toggle; coloured loader line; status footer starts with the version.
--   2.1.2  Added the repo-standard command summary in the header and cleaned the help/footer format.
-- How it works:
--   * `clip <command>` is an alias: it starts a capture, then sends `<command>` to the MUD with rune.send.
--   * `clip next` arms a capture for the next command you send instead.
--   * The capture hooks (output, prompt, input) stay disabled until needed, so the plugin costs nothing while you play normally.
--   * While capturing, the output hook records complete server lines with line:clean() (without ANSI colour codes), subject to line and byte caps.
--   * A capture ends when a GA/EOR-confirmed prompt arrives after at least one line was captured, when no new line has arrived for the idle time, or when a safety cap is reached.
--   * The text is sanitized (control characters and ESC are removed) and copied with rune.clipboard.set.
--   * Optional fallback: set CONFIG.FILE_COPY to a path to also write each capture to a file (off by default).
--   * `clip on|off` enables or disables the plugin; `clip debug on|off` toggles debug messages (default off).
--   * Typing `clip` or `clipCommandOutput` alone shows the command summary.
--   * Hooks and timers are registered with names, so /reload never stacks duplicates.
--
-- Commands (clip is the short alias of clipCommandOutput):
--   clip                 show this command summary
--   clip <command>       send <command> and copy its output
--   clip next            copy the output of the next command you send
--   clip last            copy the previous capture again
--   clip show            echo the last capture locally
--   clip cancel          abort a capture in progress
--   clip idle <secs>     change the "output finished" wait
--   clip on|off          enable or disable the plugin
--   clip debug on|off    toggle debug messages
--
-- Tweaks (top of file):
--   IDLE       seconds without new output before the capture ends (0.2–30)
--   FIRST_WAIT seconds to wait for the first line of output
--   MAX_LINES  maximum captured lines
--   MAX_BYTES  maximum captured bytes
--   FILE_COPY  optional path for an additional file copy; nil = off
--   TRIM_BLANK drop leading/trailing blank lines from the copied text

local NAME    = "clipCommandOutput"
local VERSION = "2.3"

local STORE_KEY = "eljay.clipCommandOutput."
local MIN_IDLE = 0.2
local MAX_IDLE = 30

local CONFIG = {
    ENABLED     = true,
    DEBUG       = false,
    IDLE        = 1.0,
    FIRST_WAIT  = 3.0,
    MAX_LINES   = 1000,
    MAX_BYTES   = 100000,
    FILE_COPY   = nil,
    TRIM_BLANK  = true,
}

local TIMER_NAME = "clip_idle"

local state = {
    capturing = false,
    armed     = false,
    lines     = {},
    bytes     = 0,
    last      = "",
    command   = nil,
}

local function store_get(key)
    local ok, value = pcall(rune.store.get, STORE_KEY .. key)
    if ok then return value end
    return nil
end

local function store_set(key, value)
    local ok, err = pcall(rune.store.set, STORE_KEY .. key, value)
    if not ok then
        return false, err
    end
    return true
end

local function load_settings()
    local enabled = store_get("enabled")
    local debug = store_get("debug")
    local idle = tonumber(store_get("idle"))

    if type(enabled) == "boolean" then CONFIG.ENABLED = enabled end
    if type(debug) == "boolean" then CONFIG.DEBUG = debug end
    if idle and idle >= MIN_IDLE and idle <= MAX_IDLE then CONFIG.IDLE = idle end
end

load_settings()

-- ------------------------------------------------------------- messages ---

local function paint(text)
    local ok, s = pcall(function() return rune.style.cyan(text) end)
    if ok and type(s) == "string" then return s end
    return text
end

local function say(msg)
    rune.echo(paint("[" .. NAME .. "] ") .. msg)
end

local function dbg(msg)
    if CONFIG.DEBUG then
        rune.echo(paint("[" .. NAME .. ":debug] ") .. msg)
    end
end

local function persist(key, value)
    local ok, err = store_set(key, value)
    if not ok then
        dbg("could not persist " .. key .. ": " .. tostring(err))
    end
end

-- ----------------------------------------------------------------- help ---

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
    H = nil
end

local function status_line()
    return string.format(
        "v%s  enabled=%s capturing=%s armed=%s idle=%.1fs debug=%s last=%d bytes",
        VERSION,
        CONFIG.ENABLED and "on" or "off",
        state.capturing and "yes" or "no",
        state.armed and "yes" or "no",
        CONFIG.IDLE,
        CONFIG.DEBUG and "on" or "off",
        #state.last
    )
end

local HELP = {
    { "clip <command>",    "send <command> and copy its output" },
    { "clip next",         "copy the output of the next command you send" },
    { "clip last",         "copy the previous capture again" },
    { "clip show",         "echo the last capture locally" },
    { "clip cancel",       "abort a capture in progress" },
    { "clip idle <secs>",  "change the 'output finished' wait (0.2–30)" },
    { "clip on|off",       "enable or disable the plugin" },
    { "clip debug on|off", "toggle debug messages" },
}

local function emit_help_value(value)
    if type(value) == "string" and value ~= "" then
        rune.echo(value)
    elseif type(value) == "table" then
        for _, row in ipairs(value) do
            if type(row) == "string" then rune.echo(row) end
        end
    end
end

local function show_help()
    if H then
        local ok = pcall(function()
            emit_help_value(H.title(NAME .. "  (alias: clip)"))
            emit_help_value(H.section("Commands"))
            for _, row in ipairs(HELP) do
                emit_help_value(H.line(row[1], row[2]))
            end
            emit_help_value(H.foot(status_line()))
        end)
        if ok then return end
    end

    rune.echo(NAME .. " - copy command output to the clipboard (short alias: clip)")
    for _, row in ipairs(HELP) do
        rune.echo(string.format("  %-18s %s", row[1], row[2]))
    end
    rune.echo(status_line())
end

-- --------------------------------------------------------------- capture ---

local h_output, h_prompt, h_input

local function kill_timer()
    pcall(rune.timer.remove, TIMER_NAME)
end

local function set_hooks(capture_on, input_on)
    if capture_on then
        h_output:enable()
        h_prompt:enable()
    else
        h_output:disable()
        h_prompt:disable()
    end

    if input_on then
        h_input:enable()
    else
        h_input:disable()
    end
end

local function clean_line(text)
    -- Remove CR and all control characters (including ESC and BEL); keep tab.
    return (text:gsub("[%z\1-\8\11-\31\127]", ""))
end

local function build_text(lines)
    local first, last = 1, #lines
    if CONFIG.TRIM_BLANK then
        while first <= last and lines[first]:match("^%s*$") do first = first + 1 end
        while last >= first and lines[last]:match("^%s*$") do last = last - 1 end
    end

    local out = {}
    for i = first, last do
        out[#out + 1] = lines[i]
    end
    return table.concat(out, "\n")
end

local function copy_text(text)
    if text == "" then
        say("nothing to copy")
        return false
    end

    local ok, err = pcall(rune.clipboard.set, text)
    if not ok then
        say("clipboard copy failed")
        dbg(tostring(err))
        return false
    end

    if CONFIG.FILE_COPY then
        local path = CONFIG.FILE_COPY
        local home = os.getenv("HOME") or os.getenv("USERPROFILE")
        if home then
            path = path:gsub("^~/", home .. "/")
            path = path:gsub("^~\\", home .. "\\")
        end

        local f, open_err = io.open(path, "w")
        if f then
            local write_ok, write_err = pcall(function()
                f:write(text, "\n")
                f:close()
            end)
            if not write_ok then
                pcall(function() f:close() end)
                dbg("file copy failed: " .. tostring(write_err))
            else
                dbg("also wrote " .. path)
            end
        else
            dbg("could not open file-copy path: " .. tostring(open_err))
        end
    end

    return true
end

local function finish(reason)
    if not state.capturing then return end

    state.capturing = false
    kill_timer()
    set_hooks(false, false)

    local count = #state.lines
    local text = build_text(state.lines)
    state.lines = {}
    state.bytes = 0
    dbg(string.format("finished (%s), %d raw line(s)", reason, count))

    if text == "" then
        say("no output captured" .. (reason == "timeout" and " (timed out)" or ""))
        return
    end

    state.last = text
    if copy_text(text) then
        local _, nl = text:gsub("\n", "")
        say(string.format("copied %d line(s), %d bytes%s",
            nl + 1, #text, state.command and (" from '" .. state.command .. "'") or ""))
    end

    if reason == "limit" or reason == "byte_limit" then
        say("note: capture stopped at the " .. CONFIG.MAX_LINES .. " line / " .. CONFIG.MAX_BYTES .. " byte safety limit")
    end
end

local function arm_timer(seconds)
    rune.timer.after(seconds, function()
        finish("timeout")
    end, { name = TIMER_NAME })
end

local function start_capture(command)
    state.capturing = true
    state.armed = false
    state.lines = {}
    state.bytes = 0
    state.command = command
    set_hooks(true, false)
    arm_timer(CONFIG.FIRST_WAIT)
    dbg("capture started for '" .. tostring(command) .. "'")
end

-- ----------------------------------------------------------------- hooks ---

h_output = rune.hooks.on("output", function(line)
    if not state.capturing then return end

    local ok, raw = pcall(function() return line:clean() end)
    if not ok or type(raw) ~= "string" then
        dbg("could not clean output line")
        return
    end

    local cleaned = clean_line(raw)
    local separator_bytes = (#state.lines > 0) and 1 or 0
    local remaining = CONFIG.MAX_BYTES - state.bytes - separator_bytes

    if remaining <= 0 then
        finish("byte_limit")
        return
    end

    if #cleaned > remaining then
        cleaned = cleaned:sub(1, remaining)
        state.lines[#state.lines + 1] = cleaned
        state.bytes = state.bytes + #cleaned + separator_bytes
        finish("byte_limit")
        return
    end

    state.lines[#state.lines + 1] = cleaned
    state.bytes = state.bytes + #cleaned + separator_bytes

    if #state.lines >= CONFIG.MAX_LINES then
        finish("limit")
    else
        arm_timer(CONFIG.IDLE)
    end
    -- Return nothing: the line is displayed as usual.
end, { name = "clip_output", priority = 10 }):disable()

h_prompt = rune.hooks.on("prompt", function(_, confirmed)
    if confirmed and state.capturing and #state.lines > 0 then
        finish("prompt")
    end
end, { name = "clip_prompt", priority = 10 }):disable()

h_input = rune.hooks.on("input", function(text)
    if CONFIG.ENABLED and state.armed
        and not text:match("^%s*clip%f[%W]")
        and not text:match("^%s*clipCommandOutput%f[%W]")
        and not text:match("^%s*$") then
        start_capture(text)
    end
    -- Return nothing: input passes through unchanged.
end, { name = "clip_input", priority = 5 }):disable()

-- -------------------------------------------------------------- commands ---

local function need_enabled()
    if CONFIG.ENABLED then return true end
    say("disabled (clip on to enable)")
    return false
end

local function cmd_next()
    if not need_enabled() then return end
    state.armed = true
    set_hooks(state.capturing, true)
    say("armed - the output of your next command will be copied")
end

local function cmd_last()
    if not need_enabled() then return end
    if state.last == "" then
        say("nothing captured yet")
        return
    end
    if copy_text(state.last) then say("copied the previous capture again") end
end

local function cmd_show()
    if state.last == "" then
        say("nothing captured yet")
        return
    end
    say("last capture:")
    for line in (state.last .. "\n"):gmatch("(.-)\n") do
        rune.echo("  " .. line)
    end
end

local function cmd_cancel(quiet)
    local was = state.capturing or state.armed
    state.armed, state.capturing, state.lines, state.bytes = false, false, {}, 0
    kill_timer()
    set_hooks(false, false)
    if not quiet then say(was and "capture cancelled" or "nothing to cancel") end
end

local function cmd_idle(rest)
    local n = tonumber(rest)
    if n and n >= MIN_IDLE and n <= MAX_IDLE then
        CONFIG.IDLE = n
        persist("idle", n)
        say(string.format("idle wait set to %.1fs", n))
    else
        say(string.format("idle wait is %.1fs  (usage: clip idle %.1f–%.0f)", CONFIG.IDLE, MIN_IDLE, MAX_IDLE))
    end
end

local function cmd_debug(rest)
    rest = rest:lower()
    if rest == "on" then
        CONFIG.DEBUG = true
    elseif rest == "off" then
        CONFIG.DEBUG = false
    else
        say("debug is " .. (CONFIG.DEBUG and "on" or "off") .. "  (usage: clip debug on|off)")
        return
    end
    persist("debug", CONFIG.DEBUG)
    say("debug " .. (CONFIG.DEBUG and "on" or "off"))
end

local function cmd_on()
    CONFIG.ENABLED = true
    persist("enabled", true)
    say("on")
end

local function cmd_off()
    cmd_cancel(true)
    CONFIG.ENABLED = false
    persist("enabled", false)
    say("off")
end

local SUBCOMMANDS = {
    next = cmd_next,
    last = cmd_last,
    show = cmd_show,
    cancel = function() cmd_cancel(false) end,
    idle = cmd_idle,
    debug = cmd_debug,
    on = cmd_on,
    off = cmd_off,
}

local function handle(args)
    args = (args or ""):match("^%s*(.-)%s*$")
    if args == "" then
        show_help()
        return
    end

    local word, rest = args:match("^(%S+)%s*(.*)$")
    local sub = SUBCOMMANDS[word:lower()]
    if sub then
        sub(rest)
        return
    end

    if not need_enabled() then return end

    if state.capturing then finish("restart") end

    start_capture(args)
    rune.send(args)
end

rune.alias.exact(NAME, handle)
rune.alias.exact("clip", handle)

say("v" .. VERSION .. " loaded (clipCommandOutput or clip for help)")
