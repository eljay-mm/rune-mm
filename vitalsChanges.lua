-- Filename: eljayPlugins/vitalsChanges.lua
-- Purpose: Shows hp/sp/st losses and gains in the main window (GMCP-driven)
-- Inspired by the MUSHclient plugin by Ruthgul
-- Version: 2.0
-- Date: 2026-Oct-09
--
-- Commands (with or without a leading slash):
--     vitals on | off        enable / disable the change output
--     vitals color on|off    ANSI colours in the output (default on)
--     vitals log hp|sp|st    toggle logging of that vital to vitals_changes.log
--     vitals debug           toggle debug: dumps raw GMCP vitals data
--     vitals check           show current values and settings
--     vitals help
--

-- GMCP packages that might carry vitals.
local PACKAGES = { "Char.Vitals", "Char.Status", "Char.Stats", "Char.Info" }

-- Field aliases per vital, in priority order.
local FIELDS = {
    hp = { "hp", "hitpoints", "health" },
    sp = { "sp", "mana", "spellpoints", "mp" },
    st = { "st", "moves", "stamina", "mv", "endurance" },
}

local enabled = true
local DEBUG = false
local use_color = true

local log_flags = { hp = false, sp = false, st = false }

local cur = { hp = nil, sp = nil, st = nil }
local diff = { hp = 0, sp = 0, st = 0 }
local seen_packages = {}

local base_dir = (rune.config_dir or ".") .. "/eljayPlugins"
local CONFIG_PATH = base_dir .. "/vitals_config.txt"
local LOG_PATH = base_dir .. "/vitals_changes.log"

-----------------------------------------------------------------------
-- Output
-----------------------------------------------------------------------

local function emit(text)
    if type(rune.echo) == "function" then
        pcall(rune.echo, text)
    end
end

local function dbg(text)
    if DEBUG then
        emit("[vitals] " .. tostring(text))
    end
end

-----------------------------------------------------------------------
-- Config
-----------------------------------------------------------------------

local function load_config()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return end
    for line in f:lines() do
        for _, k in ipairs({ "hp", "sp", "st" }) do
            if line == "log_" .. k .. "=true" then log_flags[k] = true end
        end
    end
    f:close()
end

local function save_config()
    local f = io.open(CONFIG_PATH, "w")
    if not f then
        emit("vitals: cannot write " .. CONFIG_PATH .. " (does the directory exist?)")
        return
    end
    for _, k in ipairs({ "hp", "sp", "st" }) do
        f:write("log_" .. k .. "=" .. tostring(log_flags[k]) .. "\n")
    end
    f:close()
end

local function log_change()
    if not (log_flags.hp or log_flags.sp or log_flags.st) then return end

    local function part(k)
        return log_flags[k] and tostring(diff[k]) or "-"
    end

    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(part("hp") .. ", " .. part("sp") .. ", " .. part("st") .. "\n")
        f:close()
    end
end

-----------------------------------------------------------------------
-- Formatting
-----------------------------------------------------------------------

local function fmt(label, num)
    local s = label .. " " .. ((num > 0) and ("+" .. num) or tostring(num))
    if not use_color then return s end
    if num > 0 then return "\27[32m" .. s .. "\27[0m" end
    if num < 0 then return "\27[31m" .. s .. "\27[0m" end
    return s
end

-----------------------------------------------------------------------
-- GMCP handling
-----------------------------------------------------------------------

local function pick(data, names)
    for _, name in ipairs(names) do
        local v = tonumber(data[name])
        if v then return v end
    end
    return nil
end

local function describe(data)
    local parts = {}
    for k, v in pairs(data) do
        if type(v) ~= "table" and type(v) ~= "function" then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

local function on_vitals(package)
    return function(data)
        if type(data) ~= "table" then
            dbg(package .. " (non-table): " .. tostring(data))
            return
        end

        if DEBUG then
            dbg(package .. ": " .. describe(data))
        end

        local hp = pick(data, FIELDS.hp)
        local sp = pick(data, FIELDS.sp)
        local st = pick(data, FIELDS.st)

        if not (hp and sp and st) then
            return
        end

        seen_packages[package] = true

        if cur.hp ~= nil then
            local dh, ds, dt = hp - cur.hp, sp - cur.sp, st - cur.st
            if dh ~= 0 or ds ~= 0 or dt ~= 0 then
                diff.hp, diff.sp, diff.st = dh, ds, dt
                log_change()

                if enabled then
                    emit(fmt("hp", dh) .. " " .. fmt("sp", ds) .. " " .. fmt("st", dt))
                end
            end
        end

        cur.hp, cur.sp, cur.st = hp, sp, st
    end
end

-----------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------

local function show_help()
    emit("vitals v2.2")
    emit("vitals on|off         enable/disable change output")
    emit("vitals color on|off   ANSI colours (default on)")
    emit("vitals log hp|sp|st   toggle logging")
    emit("vitals debug          toggle raw GMCP debug output")
    emit("vitals check          show state")
    emit("log file: " .. LOG_PATH)
end

local function show_check()
    local pk = {}
    for k in pairs(seen_packages) do pk[#pk + 1] = k end
    table.sort(pk)

    emit(string.format("vitals: hp=%s sp=%s st=%s",
        tostring(cur.hp), tostring(cur.sp), tostring(cur.st)))
    emit(string.format("logging: hp=%s sp=%s st=%s",
        tostring(log_flags.hp), tostring(log_flags.sp), tostring(log_flags.st)))
    emit(string.format("enabled=%s color=%s debug=%s packages seen: %s",
        tostring(enabled), tostring(use_color), tostring(DEBUG),
        #pk > 0 and table.concat(pk, ", ") or "none yet"))
end

local function run_command_impl(arg_text)
    local words = {}
    for word in tostring(arg_text or ""):gmatch("%S+") do
        words[#words + 1] = word:lower()
    end

    local action = words[1] or ""

    if action == "off" then
        enabled = false
        emit("vitals: change output OFF")
    elseif action == "on" then
        enabled = true
        emit("vitals: change output ON")
    elseif action == "color" or action == "colour" then
        use_color = (words[2] ~= "off")
        emit("vitals: colour " .. (use_color and "ON" or "OFF"))
    elseif action == "log" then
        local k = words[2]
        if k == "hp" or k == "sp" or k == "st" then
            log_flags[k] = not log_flags[k]
            save_config()
            emit("vitals: logging " .. k .. " " .. (log_flags[k] and "ON" or "OFF"))
        else
            emit("vitals: usage - vitals log hp|sp|st")
        end
    elseif action == "debug" then
        DEBUG = not DEBUG
        emit("vitals: debug " .. (DEBUG and "ON" or "OFF"))
    elseif action == "check" then
        show_check()
    else
        show_help()
    end
end

local function run_command(arg_text)
    local ok, err = pcall(run_command_impl, arg_text)
    if not ok then
        emit("vitals error: " .. tostring(err))
    end
end

-----------------------------------------------------------------------
-- Setup
-----------------------------------------------------------------------

if rune.alias and rune.alias.regex then
    pcall(rune.alias.regex, "^/?vitals(.*)$", function(match)
        run_command(match[1])
    end, { name = "y-vitals" })
end

if type(rune.command) == "table" then
    local function args_to_text(args)
        if type(args) == "table" then return table.concat(args, " ") end
        return tostring(args or "")
    end

    for _, fname in ipairs({ "add", "register", "create", "define", "set", "on" }) do
        local f = rune.command[fname]
        if type(f) == "function" then
            local ok = pcall(f, "vitals", function(args)
                run_command(args_to_text(args))
            end)
            if ok then break end
        end
    end
end

if rune.gmcp and rune.gmcp.on then
    for _, package in ipairs(PACKAGES) do
        pcall(rune.gmcp.on, package, on_vitals(package))
    end
end

load_config()
emit("-- vitals_changes loaded (v2.0) -- type 'vitals help' --")