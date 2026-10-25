-- Filename: eljayPlugins/clipCommandOutput.lua
-- Purpose: Copy the output of a command to the clipboard.
-- Version: 2.8
-- Date: 2026-Oct-24
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.8    Finish empty captures on confirmed prompts; reset idle timers.
--   2.7    Remove optional file-copy functionality.
--   2.6    Remove next, cancel and idle commands; retain idle as a file tweak.
--   2.5    Store settings as a fresh-read table; keep help rows within 76 characters.
--   2.4    Align command names, help, toggles, loader and load-time reporting with repo conventions.
--   2.3    Persist settings; enforce the byte cap during capture; bound idle wait.
--   2.2    Full command is clipCommandOutput (clip stays as the short alias); added on/off toggle; coloured loader line; status footer starts with the version.
--   2.1.2  Added the repo-standard command summary in the header and cleaned the help/footer format.
--
-- How it works:
--   * `clip <command>` sends the command to the MUD and captures its output.
--   * Output and prompt hooks are enabled only during a capture.
--   * Captured lines are bounded and copied with rune.clipboard.set.
--   * A capture ends on a confirmed prompt, timeout, or safety limit.
--   * Typing either command without arguments shows help.
--
-- Commands (type without "/"; "clip" is the short alias for "clipCommandOutput"):
--   clipCommandOutput       show this help
--   clip <command>          send it and copy the output
--   clip last               copy the previous capture again
--   clip show               display the last capture
--   clip on|off             enable / disable the plugin
--   clip debug on|off       enable / disable debug messages
--
-- Tweaks (top of file):
--   * IDLE        seconds without new output before the capture ends (0.2–30)
--   * FIRST_WAIT  seconds to wait for the first line of output
--   * MAX_LINES   maximum captured lines
--   * MAX_BYTES   maximum captured bytes
--   * TRIM_BLANK  drop leading/trailing blank lines from copied text

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "clipCommandOutput"
local SHORT = "clip"

local VERSION = "2.8"
local STORE_KEY = "eljay.clipCommandOutput"
local MIN_IDLE = 0.2
local MAX_IDLE = 30
local BINDINGS = 2

local CONFIG = {
    ENABLED = true,
    DEBUG = false,
    IDLE = 1.0,
    FIRST_WAIT = 3.0,
    MAX_LINES = 1000,
    MAX_BYTES = 100000,
    TRIM_BLANK = true,
}

CONFIG.IDLE = math.max(MIN_IDLE, math.min(MAX_IDLE, CONFIG.IDLE))

local TIMER_NAME = "clip_idle"
local SETTINGS = {}

local state = {
    capturing = false,
    lines = {},
    bytes = 0,
    last = "",
    command = nil,
}

local function read_settings()
    local ok, settings = pcall(rune.store.get, STORE_KEY)
    if ok and type(settings) == "table" then
        return settings
    end
    return {}
end

local function apply_settings(settings)
    SETTINGS = settings
    if type(settings.enabled) == "boolean" then
        CONFIG.ENABLED = settings.enabled
    end
    if type(settings.debug) == "boolean" then
        CONFIG.DEBUG = settings.debug
    end
end

apply_settings(read_settings())

local function update_settings(mutate)
    local settings = read_settings()
    mutate(settings)

    local ok, err = pcall(rune.store.set, STORE_KEY, settings)
    if ok then
        apply_settings(settings)
    elseif CONFIG.DEBUG then
        rune.echo("[" .. NAME .. ":debug] could not persist settings: "
            .. tostring(err))
    end
end

local LOAD_MS

local function paint(text)
    local ok, styled = pcall(function()
        return rune.style.cyan(text)
    end)
    if ok and type(styled) == "string" then
        return styled
    end
    return text
end

local function say(message)
    rune.echo(paint("[" .. NAME .. "] ") .. message)
end

local function dbg(message)
    if CONFIG.DEBUG then
        rune.echo(paint("[" .. NAME .. ":debug] ") .. message)
    end
end

local H = require("helpstyle")

local h_output, h_prompt

local function status_line()
    return string.format(
        "v%s  enabled=%s debug=%s bindings=%d load=%dms",
        VERSION,
        tostring(CONFIG.ENABLED),
        tostring(CONFIG.DEBUG),
        BINDINGS,
        LOAD_MS or 0
    )
end

local HELP = {
    { NAME, "show this help" },
    { SHORT .. " <command>", "send it and copy the output" },
    { SHORT .. " last", "copy the previous capture again" },
    { SHORT .. " show", "display the last capture" },
    { SHORT .. " on|off", "enable or disable the plugin" },
    { SHORT .. " debug on|off", "toggle debug messages" },
}

local function emit(value)
    if type(value) == "string" and value ~= "" then
        rune.echo(value)
    elseif type(value) == "table" then
        for _, row in ipairs(value) do
            if type(row) == "string" then
                rune.echo(row)
            end
        end
    end
end

local function show_help()
    emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))

    for _, row in ipairs(HELP) do
        emit(H.line(row[1], row[2]))
    end

    emit(H.line(SHORT, "short alias for " .. NAME))
    emit(H.foot(status_line()))
end

local function kill_timer()
    pcall(rune.timer.remove, TIMER_NAME)
end

local function set_hooks(enabled)
    if enabled then
        h_output:enable()
        h_prompt:enable()
    else
        h_output:disable()
        h_prompt:disable()
    end
end

local function clean_line(text)
    return (text:gsub("[%z\1-\8\11-\31\127]", ""))
end

local function build_text(lines)
    local first, last = 1, #lines

    if CONFIG.TRIM_BLANK then
        while first <= last and lines[first]:match("^%s*$") do
            first = first + 1
        end
        while last >= first and lines[last]:match("^%s*$") do
            last = last - 1
        end
    end

    local out = {}
    for index = first, last do
        out[#out + 1] = lines[index]
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

    return true
end

local function finish(reason)
    if not state.capturing then
        return
    end

    state.capturing = false
    kill_timer()
    set_hooks(false)

    local count = #state.lines
    local text = build_text(state.lines)
    state.lines = {}
    state.bytes = 0

    dbg(string.format("finished (%s), %d raw line(s)", reason, count))

    if text == "" then
        say("no output captured"
            .. (reason == "timeout" and " (timed out)" or ""))
        state.command = nil
        return
    end

    state.last = text
    if copy_text(text) then
        local _, newlines = text:gsub("\n", "")
        say(string.format(
            "copied %d line(s), %d bytes%s",
            newlines + 1,
            #text,
            state.command and (" from '" .. state.command .. "'") or ""
        ))
    end

    if reason == "limit" or reason == "byte_limit" then
        say("note: capture stopped at the "
            .. CONFIG.MAX_LINES .. " line / "
            .. CONFIG.MAX_BYTES .. " byte safety limit")
    end

    state.command = nil
end

local function arm_timer(seconds)
    kill_timer()
    rune.timer.after(seconds, function()
        finish("timeout")
    end, { name = TIMER_NAME })
end

local function start_capture(command)
    state.capturing = true
    state.lines = {}
    state.bytes = 0
    state.command = command

    set_hooks(true)
    arm_timer(CONFIG.FIRST_WAIT)
    dbg("capture started for '" .. command .. "'")
end

h_output = rune.hooks.on("output", function(line)
    if not state.capturing then
        return
    end

    local ok, raw = pcall(function()
        return line:clean()
    end)
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
end, { name = "clip_output", priority = 10 }):disable()

h_prompt = rune.hooks.on("prompt", function(_, confirmed)
    if confirmed and state.capturing then
        finish("prompt")
    end
end, { name = "clip_prompt", priority = 10 }):disable()

local function need_enabled()
    if CONFIG.ENABLED then
        return true
    end

    say("disabled (" .. SHORT .. " on to enable)")
    return false
end

local function cmd_last()
    if not need_enabled() then
        return
    end
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
    for line in (state.last .. "\n"):gmatch("(.-)\n") do
        rune.echo("  " .. line)
    end
end

local function cmd_debug(rest)
    rest = type(rest) == "string" and rest:lower() or ""

    if rest ~= "on" and rest ~= "off" then
        say("debug is " .. (CONFIG.DEBUG and "on" or "off")
            .. "  (usage: " .. SHORT .. " debug on|off)")
        return
    end

    local enabled = rest == "on"
    update_settings(function(settings)
        settings.debug = enabled
    end)
    say("debug " .. (CONFIG.DEBUG and "on" or "off"))
end

local function cmd_on()
    update_settings(function(settings)
        settings.enabled = true
    end)
    say("on")
end

local function cmd_off()
    if state.capturing then
        state.capturing = false
        state.lines = {}
        state.bytes = 0
        state.command = nil
        kill_timer()
        set_hooks(false)
    end

    update_settings(function(settings)
        settings.enabled = false
    end)
    say("off")
end

local SUBCOMMANDS = {
    last = cmd_last,
    show = cmd_show,
    debug = cmd_debug,
    on = cmd_on,
    off = cmd_off,
}

local function handle(args, ctx)
    args = type(args) == "string" and args:match("^%s*(.-)%s*$") or ""

    if args == "" then
        show_help()
        return
    end

    local word, rest = args:match("^(%S+)%s*(.*)$")
    local subcommand = SUBCOMMANDS[word:lower()]

    if subcommand then
        subcommand(rest)
        return
    end

    if not need_enabled() then
        return
    end

    if state.capturing then
        state.capturing = false
        state.lines = {}
        state.bytes = 0
        state.command = nil
        kill_timer()
        set_hooks(false)
    end

    start_capture(args)
    rune.send(args)
end

rune.alias.exact(NAME, handle)
rune.alias.exact(SHORT, handle)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
update_settings(function(settings)
    settings.load_ms = LOAD_MS
end)

rune.echo(
    paint("[" .. NAME .. "] ")
    .. string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT)
)
