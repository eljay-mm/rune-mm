-- Filename: eljayPlugins/clipCommandOutput.lua
-- Purpose: Copy the output of a command to the clipboard.
-- Version: 2.0 
-- Date: 2026-Oct-09
--
-- Usage:
--   clip <command>     send <command> to the MUD and copy its output
--                      e.g.  clip look     clip score     clip inventory
--   clip               capture the output of the NEXT command you send
--                      (any command typed after it, or sent by another script)
--   clip last          copy the previous capture again
--   clip cancel        abort a capture in progress
--   clip idle <secs>   change the "output finished" wait (default 1.0)
--   clip show          echo the last capture locally (to check what was copied)
--
-- How it works:
--   - `clip <command>` is an exact alias. It starts a capture, then sends
--     <command> to the MUD with rune.send.
--   - A plain `clip` arms the capture; the first thing you send afterwards
--     (caught with an "input" hook at low priority) starts it.
--   - While capturing, an "output" hook records every complete server line
--     with line:clean() (no ANSI colour codes). The hook returns nothing, so
--     the lines are still displayed normally.
--   - The capture ends when a GA/EOR-confirmed prompt arrives after at least
--     one line was captured, or when no new line has arrived for the idle
--     time (default 1.0s), or when MAX_LINES is reached.
--   - The text is copied with rune.clipboard.set (OSC 52, handled by ghostty).
--     A copy of the text is also written to FILE_COPY so you can fall back to
--     wl-copy / xclip if the terminal refuses the escape sequence.
--   - Hooks/timers are registered with names, so /reload never stacks
--     duplicates.
--
-- Ghostty note: OSC 52 writes are controlled by `clipboard-write` in the
-- ghostty config (allow / ask / deny). If nothing (or only a few characters)
-- reaches the clipboard, set `clipboard-write = allow` and restart ghostty,
-- or use the file written to FILE_COPY, e.g.  wl-copy < /tmp/rune_clip.txt

local CONFIG = {
    IDLE        = 1.0,    -- seconds without new output before the capture ends
    FIRST_WAIT  = 3.0,    -- seconds to wait for the first line of output
    MAX_LINES   = 1000,   -- safety cap
    FILE_COPY   = "/tmp/rune_clip.txt",  -- set to nil/false to disable
    TRIM_BLANK  = true,   -- drop leading/trailing blank lines
}

local TIMER_NAME = "y_clip_idle"

local state = {
    capturing = false,
    armed     = false,   -- waiting for the next sent command
    lines     = {},
    last      = "",
    command   = nil,
}

local function say(msg)
    rune.echo("[clip] " .. msg)
end

local function kill_timer()
    pcall(rune.timer.remove, TIMER_NAME)
end

local function build_text(lines)
    local first, last = 1, #lines
    if CONFIG.TRIM_BLANK then
        while first <= last and lines[first]:match("^%s*$") do first = first + 1 end
        while last >= first and lines[last]:match("^%s*$") do last = last - 1 end
    end
    local out = {}
    for i = first, last do
        -- strip stray carriage returns and control characters, keep tabs
        local l = lines[i]:gsub("\r", ""):gsub("[%z\1-\8\11\12\14-\31\127]", "")
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
        end
    end
    return true
end

local function finish(reason)
    if not state.capturing then return end
    state.capturing = false
    kill_timer()

    local text = build_text(state.lines)
    local count = #state.lines
    state.lines = {}

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
    if count >= CONFIG.MAX_LINES then
        say("note: capture stopped at the " .. CONFIG.MAX_LINES .. " line limit")
    end
end

local function arm_timer(seconds)
    rune.timer.after(seconds, function() finish("timeout") end, { name = TIMER_NAME })
end

local function start_capture(command)
    state.capturing = true
    state.armed     = false
    state.lines     = {}
    state.command   = command
    arm_timer(CONFIG.FIRST_WAIT)
end

-- ---------------------------------------------------------------- hooks ---

-- Record each complete server line while a capture is running.
rune.hooks.on("output", function(line)
    if not state.capturing then return end

    state.lines[#state.lines + 1] = line:clean()

    if #state.lines >= CONFIG.MAX_LINES then
        finish("limit")
    else
        arm_timer(CONFIG.IDLE)   -- replaces the previous timer of the same name
    end
    -- return nothing: the line is displayed as usual
end, { name = "y_clip_output", priority = 10 })

-- A confirmed prompt after some output means the command has finished.
rune.hooks.on("prompt", function(line, confirmed)
    if confirmed and state.capturing and #state.lines > 0 then
        finish("prompt")
    end
end, { name = "y_clip_prompt", priority = 10 })

-- A bare `clip` arms the capture; the next command typed starts it.
rune.hooks.on("input", function(text)
    if state.armed and not text:match("^%s*clip%f[%W]") and not text:match("^%s*$") then
        start_capture(text)
    end
    -- return nothing: input passes through unchanged
end, { name = "y_clip_input", priority = 5 })

-- ---------------------------------------------------------------- alias ---

rune.alias.exact("clip", function(args)
    args = args or ""
    args = args:match("^%s*(.-)%s*$")

    if args == "" then
        state.armed = true
        say("armed - the output of your next command will be copied")
        return
    end

    local word, rest = args:match("^(%S+)%s*(.*)$")
    word = word:lower()

    if word == "last" then
        if state.last == "" then
            say("nothing captured yet")
        else
            copy_text(state.last)
            say("copied the previous capture again")
        end
        return
    elseif word == "cancel" then
        state.armed = false
        if state.capturing then
            state.capturing = false
            state.lines = {}
            kill_timer()
            say("capture cancelled")
        else
            say("nothing to cancel")
        end
        return
    elseif word == "show" then
        if state.last == "" then
            say("nothing captured yet")
        else
            say("last capture:")
            for l in (state.last .. "\n"):gmatch("(.-)\n") do
                rune.echo("  " .. l)
            end
        end
        return
    elseif word == "idle" then
        local n = tonumber(rest)
        if n and n > 0 then
            CONFIG.IDLE = n
            say("idle wait set to " .. n .. "s")
        else
            say("idle wait is " .. CONFIG.IDLE .. "s  (usage: clip idle <seconds>)")
        end
        return
    end

    -- anything else is a command to run and capture
    if state.capturing then finish("restart") end
    start_capture(args)
    rune.send(args)
end)