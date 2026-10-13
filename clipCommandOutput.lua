-- Filename: eljayPlugins/clipCommandOutput.lua
-- Purpose: Copy the output of a command to the clipboard.
-- Version: 2.1.2
-- Date: 2026-Oct-13
-- Changelog:
--   2.1.2  Added the repo-standard command summary in the header and cleaned the help/footer format.
--   2.1.1  Original release with capture logic and clipboard copy.
-- How it works:
--   * `clip <command>` is an exact alias: it starts a capture, then sends `<command>` to the MUD with rune.send.
--   * `clip next` arms a capture for the next command you send instead.
--   * The capture hooks (output, prompt, input) stay disabled until needed, so the plugin costs nothing while you play normally.
--   * While capturing, the output hook records every complete server line with line:clean() (no ANSI colour codes).
--   * A capture ends when a GA/EOR-confirmed prompt arrives after at least one line was captured, when no new line has arrived for the idle time, or when the line/byte limit is reached.
--   * The text is sanitized (control characters and ESC are removed, so the server can never smuggle terminal escapes into the clipboard copy) and copied with rune.clipboard.set.
--   * Optional fallback: set CONFIG.FILE_COPY to a path to also write each capture to a file (off by default).
--   * `clip debug on|off` toggles debug messages (default off).
--   * Hooks and timers are registered with names, so /reload never stacks duplicates.
--
-- Commands:
--   clip                 show this command summary
--   clip <command>       send <command> and copy its output
--   clip next            copy the output of the next command you send
--   clip last            copy the previous capture again
--   clip show            echo the last capture locally
--   clip cancel          abort a capture in progress
--   clip idle <secs>     change the "output finished" wait
--   clip debug on|off    toggle debug messages

local CONFIG = {
    DEBUG       = false,  -- toggled with `clip debug on|off`
    IDLE        = 1.0,    -- seconds without new output before the capture ends
    FIRST_WAIT  = 3.0,    -- seconds to wait for the first line of output
    MAX_LINES   = 1000,   -- safety cap (lines)
    MAX_BYTES   = 100000, -- safety cap (bytes copied; OSC 52 has terminal limits)
    FILE_COPY   = nil,    -- e.g. "/home/<you>/.cache/rune_clip.txt"; nil = off
    TRIM_BLANK  = true,   -- drop leading/trailing blank lines
}

local TIMER_NAME = "clip_idle"

local state = {
    capturing = false,
    armed     = false,
    lines     = {},
    last      = "",
    command   = nil,
}

local function say(msg)
    rune.echo("[clip] " .. msg)
end

local function dbg(msg)
    if CONFIG.DEBUG then
        rune.echo("[clip:debug] " .. msg)
    end
end

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
    H = nil
end

local function status_line()
    return string.format(
        "v2.1.2  capturing=%s armed=%s idle=%.1fs debug=%s last=%d bytes",
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
    { "clip idle <secs>",  "change the 'output finished' wait" },
    { "clip debug on|off", "toggle debug messages" },
}

local function show_help()
    if H then
        local printed = 0
        local real_echo = rune.echo
        rune.echo = function(...)
            printed = printed + 1
            return real_echo(...)
        end

        local function emit(v)
            if type(v) == "string" and v ~= "" then
                real_echo(v)
                printed = printed + 1
            elseif type(v) == "table" then
                for _, s in ipairs(v) do
                    if type(s) == "string" then
                        real_echo(s)
                        printed = printed + 1
                    end
                end
            end
        end

        local ok, err = pcall(function()
            emit(H.title("clip"))
            emit(H.section("Commands"))
            for _, row in ipairs(HELP) do
                emit(H.line(row[1], row[2]))
            end
            emit(H.foot(status_line()))
        end)

        rune.echo = real_echo

        if ok and printed > 0 then
            return
        end
    end

    rune.echo("clip - copy command output to the clipboard")
    for _, row in ipairs(HELP) do
        rune.echo(string.format("  %-18s %s", row[1], row[2]))
    end
    rune.echo(status_line())
end

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

local function build_text(lines)
    local first, last = 1, #lines
    if CONFIG.TRIM_BLANK then
        while first <= last and lines[first]:match("^%s*$") do first = first + 1 end
        while last >= first and lines[last]:match("^%s*$") do last = last - 1 end
    end

    local out, bytes = {}, 0
    for i = first, last do
        local l = lines[i]:gsub("[%z\1-\8\11-\31\127]", "")
        bytes = bytes + #l + 1
        if bytes > CONFIG.MAX_BYTES then
            say("note: capture truncated at " .. CONFIG.MAX_BYTES .. " bytes")
            break
        end
        out[#out + 1] = l
    end

    return table.concat(out, "\n")
end

local function copy_text(text)
    if text == "" then
        say("nothing to copy")
        return false
    end

    rune.clipboard.set(text)

    if CONFIG.FILE_COPY then
        local ok, f = pcall(io.open, CONFIG.FILE_COPY, "w")
        if ok and f then
            f:write(text, "\n")
            f:close()
            dbg("also wrote " .. CONFIG.FILE_COPY)
        else
            dbg("could not write " .. CONFIG.FILE_COPY)
        end
    end

    return true
end

local function finish(reason)
    if not state.capturing then
        return
    end

    state.capturing = false
    kill_timer()
    set_hooks(false, false)

    local count = #state.lines
    local text = build_text(state.lines)
    state.lines = {}
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

    if reason == "limit" then
        say("note: capture stopped at the " .. CONFIG.MAX_LINES .. " line limit")
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
    state.command = command
    set_hooks(true, false)
    arm_timer(CONFIG.FIRST_WAIT)
    dbg("capture started for '" .. tostring(command) .. "'")
end

h_output = rune.hooks.on("output", function(line)
    if not state.capturing then
        return
    end

    state.lines[#state.lines + 1] = line:clean()
    if #state.lines >= CONFIG.MAX_LINES then
        finish("limit")
    else
        arm_timer(CONFIG.IDLE)
    end
end, { name = "clip_output", priority = 10 }):disable()

h_prompt = rune.hooks.on("prompt", function(line, confirmed)
    if confirmed and state.capturing and #state.lines > 0 then
        finish("prompt")
    end
end, { name = "clip_prompt", priority = 10 }):disable()

h_input = rune.hooks.on("input", function(text)
    if state.armed and not text:match("^%s*clip%f[%W]") and not text:match("^%s*$") then
        start_capture(text)
    end
end, { name = "clip_input", priority = 5 }):disable()

local function cmd_next()
    state.armed = true
    set_hooks(state.capturing, true)
    say("armed - the output of your next command will be copied")
end

local function cmd_last()
    if state.last == "" then
        say("nothing captured yet")
        return
    end

    if copy_text(state.last) then
        say("copied the previous capture again")
    end
end

local function cmd_show()
    if state.last == "" then
        say("nothing captured yet")
        return
    end

    say("last capture:")
    for l in (state.last .. "\n"):gmatch("(.-)\n") do
        rune.echo("  " .. l)
    end
end

local function cmd_cancel()
    local was = state.capturing or state.armed
    state.armed, state.capturing, state.lines = false, false, {}
    kill_timer()
    set_hooks(false, false)
    say(was and "capture cancelled" or "nothing to cancel")
end

local function cmd_idle(rest)
    local n = tonumber(rest)
    if n and n > 0 then
        CONFIG.IDLE = n
        say("idle wait set to " .. n .. "s")
    else
        say("idle wait is " .. CONFIG.IDLE .. "s  (usage: clip idle <seconds>)")
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

    say("debug " .. (CONFIG.DEBUG and "on" or "off"))
end

local SUBCOMMANDS = {
    ["next"] = cmd_next,
    ["last"] = cmd_last,
    ["show"] = cmd_show,
    ["cancel"] = cmd_cancel,
    ["idle"] = cmd_idle,
    ["debug"] = cmd_debug,
}

rune.alias.exact("clip", function(args)
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

    if state.capturing then
        finish("restart")
    end

    start_capture(args)
    rune.send(args)
end)