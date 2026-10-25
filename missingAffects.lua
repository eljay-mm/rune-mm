-- Filename: eljayPlugins/missingAffects.lua
-- Purpose: Compare listed affects with a wanted-affects list and report missing affects.
-- Version: 1.22
-- Date: 2026-Oct-25
--[[
Todo:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.22 Under 16000 bytes (tables from strings, similar-affect groups and old-key
--        adoption removed); saves are read back and failures reported; edits made
--        before the name arrives are saved under it; help uses the short alias.
--   1.15-1.21 charname.lua keys, class spell|bard, plan skills, safe list saves.
--
-- How it works:
--   * Parses "affects" (Materia Magica): "You are affected by the following:" starts a
--     listing, each "Spell:/Affect:/Racial:/Skill:  name  - Level ..." row records a
--     name, and "Total of N magical affects." compares them with the wanted list.
--     Matching is case-insensitive and exact. A listing that never reaches its total
--     is dropped after LISTING_TIMEOUT seconds.
--   * "cast" sends one command per missing name, "cast all" (or "mac all") sends every
--     wanted name to refresh durations. "<element> invocation" -> invoke <element>;
--     PLAN_SKILLS ('skill tag physical-spell') -> plan '<name>'; with class bard,
--     BARD_SONGS -> play '<song>'; anything else -> cast '<name>'.
--   * Settings (wanted list, on/off, debug, class) are kept in rune.store under
--     charname.key("missingAffects.<setting>") from horstgs' charname.lua, which must
--     load with require("charname"). Nothing is saved without a character name; edits
--     made before it arrives are saved under it when it does. Wanted-list edits re-read
--     the stored list, change it, save it, then refresh the in-memory copy.
--   * Loads fast: one regex alias, one trigger; helpstyle and settings load on first use.
--
-- Commands (short alias ma; mac [all] = cast [all]):
--   ma [help] | on|off | debug on|off | class spell|bard
--   ma want <a>, <b> | add|remove <name> | list | clear | lines
--   ma charname | cast [all]

local LOAD_START = os.clock()

-- Command names: full command and short alias.
local NAME = "missingAffects"
local SHORT = "ma"
local CAST_SHORT = "mac"
local VERSION = "1.22"

local KEY_WANTED, KEY_ENABLED = "missingAffects.wanted", "missingAffects.enabled"
local KEY_DEBUG, KEY_CLASS = "missingAffects.debug", "missingAffects.class"
local LISTING_TIMEOUT = 10 -- seconds before an unfinished listing is discarded

local function make_set(text)
  local set = {}
  for item in text:gmatch("[^,]+") do set[item] = true end
  return set
end

local ELEMENTS = make_set("magma,minerals,ice,ooze,air,steam,dust,fire,lightning")
local PLAN_SKILLS = make_set("ascendance,beast of burden,blood in my mouth,"
  .. "blood in your mouth,cover of darkness,frothing rage,headbutt,home on the range,"
  .. "physical reinforcement,renegade and steer clear,rites of bloodshed,summon soldier")
local BARD_SONGS = make_set("battle march,detect invisibility,footloose,"
  .. "enhanced strength,epiphany,inspirational hymn,levitation,light,mass levitation,"
  .. "shield,traveling song,blindness,cacophony,fireball,earworm,hands of wind,"
  .. "harmonize,hinder,pensive dirge,plodding fugue,soothing nocturne,tremolo,"
  .. "ode to the moon,tempus rigor,calm,cure light,invigorating performance,"
  .. "nights fortune,refresh,rime of the glacierbreaker,thunderclap,tremor")

local enabled, debug_enabled, class_mode = true, false, "spell"
local wanted, unsaved_wanted = {}, false
local loaded_for, warned_no_char, report_pending, load_ms = nil, false, false, nil
local listed, last_lines, missing_last = {}, {}, {}
local listing_active, listing_stamp = false, 0

-- Display: paint/say via rune.echo, H.* rows via emit
local function paint(color, text)
  local ok, styled = pcall(function() return rune.style[color](text) end)
  return (ok and type(styled) == "string") and styled or text
end

local function emit(text) rune.echo(tostring(text)) end
local function say(text) emit(paint("cyan", "[" .. NAME .. "] ") .. tostring(text)) end

local function dbg(fmt, ...)
  if not debug_enabled then return end
  local ok, text = pcall(string.format, fmt, ...)
  say("debug: " .. (ok and text or tostring(fmt)))
end

local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function normalize(text) return (trim(text):lower():gsub("%s+", " ")) end
local function onoff(value) return value and "on" or "off" end

local function copy_list(list)
  local out = {}
  for _, item in ipairs(list or {}) do out[#out + 1] = item end
  return out
end

-- Settings: stored per character with horstgs' charname.lua

local charname_module = nil -- nil = not tried yet, false = unavailable

local function get_charname_module()
  if charname_module == nil then
    local ok, module = pcall(require, "charname")
    charname_module = (ok and type(module) == "table") and module or false
  end
  return charname_module or nil
end

-- Character name; nil until the game has sent it.
local function charname()
  local ok, value = pcall(function() return trim(get_charname_module().get()) end)
  if ok and value ~= "" then return value end
end

-- e.g. "missingAffects.wanted.littlejester"
local function store_key(base)
  local ok, key = pcall(function() return get_charname_module().key(base) end)
  if ok and type(key) == "string" then return key end
end

local function store_get(key)
  local ok, value = pcall(function() return rune.store.get(key) end)
  if ok then return value end
end

-- Stored value of one setting for the current character, if it has type `kind`.
local function stored(base, kind)
  local value = store_get(store_key(base))
  if type(value) == kind then return value end
end

-- Save under the character name only, then read it back to confirm.
local function save_value(base, value)
  if not charname() then
    if not warned_no_char then
      warned_no_char = true
      say("character name not known yet; changes are kept until it arrives")
    end
    return false
  end

  local key = store_key(base)
  if not key then
    say("cannot save " .. base .. ": no store key")
    return false
  end

  local ok, err = pcall(function() return rune.store.set(key, value) end)
  if not ok or store_get(key) == nil then
    say("save failed for " .. key .. " (" .. tostring(ok and "not read back" or err) .. ")")
    return false
  end
  return true
end

-- Load settings the first time the name is known and whenever it changes.
local function ensure_settings(force)
  if loaded_for and not force then return end
  local char = charname()
  if not char or char == loaded_for then return end

  loaded_for, warned_no_char = char, false
  local flag = stored(KEY_ENABLED, "boolean")
  enabled = (flag == nil) or flag
  debug_enabled = stored(KEY_DEBUG, "boolean") == true
  class_mode = (stored(KEY_CLASS, "string") == "bard") and "bard" or "spell"

  local list = stored(KEY_WANTED, "table")
  if list then
    wanted = copy_list(list)
  elseif unsaved_wanted then
    save_value(KEY_WANTED, wanted) -- edits made before the name arrived
  else
    wanted = {}
  end
  unsaved_wanted = false
  dbg("settings loaded for %s", char)
end

-- Change the wanted list the safe way: read the latest list from rune.store, let
-- modify(list) change that fresh copy, save it, then refresh the in-memory list.
local function update_wanted(modify)
  local named = charname() ~= nil
  local fresh = copy_list(named and stored(KEY_WANTED, "table") or wanted)
  modify(fresh)
  unsaved_wanted = not named
  save_value(KEY_WANTED, fresh)
  wanted = fresh
end

-- Ask the game for the name (the requests charname.lua sends on login).
local function request_charname()
  local ok, active = pcall(function() return rune.gmcp.is_enabled() end)
  if ok and active then
    pcall(rune.gmcp.send, "char.base", { [""] = "" })
    pcall(rune.gmcp.send, "char.status", { [""] = "" })
  end
  dbg("requested the character name (GMCP %s)", onoff(ok and active))
end

local function report_charname()
  local char = charname()
  if not char then return false end
  local list = stored(KEY_WANTED, "table")
  say("character " .. char .. ", key " .. tostring(store_key(KEY_WANTED)) .. ", "
    .. (list and (#list .. " wanted stored") or "nothing stored yet"))
  return true
end

local function refresh_charname()
  if not get_charname_module() then
    say("charname.lua not found (require \"charname\" failed)")
    return
  end
  request_charname()
  ensure_settings(true)
  report_pending = not report_charname()
  if report_pending then say("name requested; it will be shown when the game replies") end
end

-- Listing and casting

local function begin_listing()
  listed, last_lines, listing_active, listing_stamp = {}, {}, true, os.time()
end

local function record_affect(name)
  name = trim(name)
  if name == "" then return end
  if not listing_active or os.time() - listing_stamp > LISTING_TIMEOUT then begin_listing() end
  listing_stamp = os.time()
  last_lines[#last_lines + 1] = name
  listed[normalize(name)] = true
  dbg("listed: %s", name)
end

local function finish_listing()
  if not listing_active then begin_listing() end
  listing_active, missing_last = false, {}
  for _, name in ipairs(wanted) do
    if not listed[normalize(name)] then missing_last[#missing_last + 1] = name end
  end
  say(#missing_last == 0 and "No wanted affects are missing."
    or "Missing affects: " .. table.concat(missing_last, ", "))
end

-- Affect name -> command verb and argument.
local function resolve_ability(name)
  local key = normalize(name)
  local element = key:match("^(%a+) invocation$")
  if element and ELEMENTS[element] then return "invoke", element end
  if PLAN_SKILLS[key] then return "plan", key end
  if class_mode == "bard" and BARD_SONGS[key] then return "play", key end
  return "cast", name
end

local function send_ability(name)
  local method, argument = resolve_ability(name)
  if not (name:match("^[%w %-]+$") and argument:match("^[%w %-]+$")) then
    say("Skipped unsafe name: " .. name)
    return
  end
  local command = (method == "invoke") and (method .. " " .. argument)
    or (method .. " '" .. argument .. "'")
  dbg("sending: %s", command)
  rune.send(command)
end

local function cast_list(list, label)
  if #list == 0 then
    say(label)
    return
  end
  for _, name in ipairs(list) do send_ability(name) end
end

-- Help and commands

local function help_summary()
  local status = "v" .. VERSION .. "  enabled=" .. onoff(enabled)
    .. " debug=" .. onoff(debug_enabled) .. " class=" .. class_mode
    .. " wanted=" .. #wanted .. " char=" .. (charname() or "unknown")
    .. " load=" .. (load_ms or 0) .. "ms"
  local rows = {
    { SHORT .. " on|off", "enable or disable the trigger" },
    { SHORT .. " debug on|off", "toggle debug output" },
    { SHORT .. " class spell|bard", "cast spells or play songs" },
    { SHORT .. " want <a>, <b>", "replace the wanted list" },
    { SHORT .. " add|remove <name>", "edit the wanted list" },
    { SHORT .. " list|clear", "show or clear the wanted list" },
    { SHORT .. " lines", "show the last captured listing" },
    { SHORT .. " charname", "refresh name, show stored data" },
    { SHORT .. " cast [all]", "cast missing (or all wanted)" },
    { CAST_SHORT .. " [all]", "same as " .. SHORT .. " cast [all]" },
    { SHORT, "short alias for " .. NAME },
  }

  local ok, H = pcall(require, "helpstyle") -- loaded on first use
  if not (ok and type(H) == "table") then H = nil end
  if H and H.title and H.section and H.line and H.foot then
    emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))
    for _, row in ipairs(rows) do emit(H.line(row[1], row[2])) end
    emit(H.foot(status))
    return
  end
  say("Missing affects")
  for _, row in ipairs(rows) do say("  " .. row[1] .. "  " .. row[2]) end
  say(status)
end

local function handle_command(text)
  local verb, rest = trim(text):match("^(%S+)%s*(.-)$")
  verb, rest = (verb or ""):lower(), trim(rest)
  local setting = rest:lower()

  if verb == "cast" then
    if setting == "all" then
      if #wanted > 0 then say("Casting all wanted affects") end
      cast_list(wanted, "Wanted-affects list is empty.")
    else
      cast_list(missing_last, "No saved missing-affects result to cast.")
    end
  elseif verb == "on" or verb == "off" then
    enabled = verb == "on"
    save_value(KEY_ENABLED, enabled)
    say(enabled and "enabled" or "disabled")
  elseif verb == "debug" and (setting == "on" or setting == "off") then
    debug_enabled = setting == "on"
    save_value(KEY_DEBUG, debug_enabled)
    say("debug " .. setting)
  elseif verb == "class" and (setting == "bard" or setting == "spell") then
    class_mode = setting
    save_value(KEY_CLASS, class_mode)
    say("class " .. class_mode)
  elseif verb == "charname" then
    refresh_charname()
  elseif verb == "lines" then
    say(#last_lines == 0 and "No affect lines captured yet; run affects first."
      or "Captured " .. #last_lines .. " line(s): " .. table.concat(last_lines, " | "))
  elseif verb == "list" then
    say(#wanted == 0 and "Wanted-affects list is empty."
      or "Wanted affects: " .. table.concat(wanted, ", "))
  elseif verb == "clear" then
    update_wanted(function(list) for i = #list, 1, -1 do list[i] = nil end end)
    say("wanted-affects list cleared")
  elseif verb == "want" then
    update_wanted(function(list)
      for i = #list, 1, -1 do list[i] = nil end
      for item in rest:gmatch("[^,]+") do
        item = trim(item)
        if item ~= "" then list[#list + 1] = item end
      end
    end)
    say("wanted-affects list replaced (" .. #wanted .. " items)")
  elseif (verb == "add" or verb == "remove") and rest ~= "" then
    local key, found = normalize(rest), false
    update_wanted(function(list)
      for i = #list, 1, -1 do
        if normalize(list[i]) == key then
          found = true
          if verb == "remove" then table.remove(list, i) end
        end
      end
      if verb == "add" and not found then list[#list + 1] = rest end
    end)
    say(verb == "add" and ((found and "already wanted: " or "added: ") .. rest)
      or ("removed: " .. rest))
  else
    help_summary()
  end
end

-- Trigger and alias (one of each, for load speed; bare commands, no / prefix)

-- m[1] header; m[2]/m[3] label and name of a "Spell:      name   - Level ..." row
-- (Racial rows have no Level part); m[4] "Total of N magical affects."
rune.trigger.regex("^\\s*(?:([Yy]ou are affected by the following:?)|(Spell|Affect|Racial|Skill):"
  .. "\\s+(.+?)(?:\\s+-\\s+Level\\b.*)?|(Total of .+ affects?\\.?))\\s*$", function(m)
  if not m then return end
  if m[1] and m[1] ~= "" then
    ensure_settings(true) -- re-check the character name once per listing
    if enabled then begin_listing() end
    return
  end
  ensure_settings()
  if not enabled then return end
  if m[4] and m[4] ~= "" then
    finish_listing()
  elseif m[3] and m[3] ~= "" then
    record_affect(m[3])
  end
end)

rune.alias.regex("^(" .. NAME .. "|" .. SHORT .. "|" .. CAST_SHORT .. ")(?:[ ]+(.+))?$", function(m)
  ensure_settings(true) -- re-check the character name before any command
  local rest = trim((m and m[2]) or "")
  handle_command(((m and m[1]) == CAST_SHORT) and ("cast " .. rest) or rest)
end)

-- Reload settings as soon as charname.lua reports a new name; the checks above are
-- a backstop. After a /reload the name may be lost, so ask the game for it.
local module = get_charname_module()
if module and type(module.on_change) == "function" then
  pcall(module.on_change, function()
    ensure_settings(true)
    if report_pending and report_charname() then report_pending = false end
  end)
  if not charname() then request_charname() end
end

load_ms = math.floor((os.clock() - LOAD_START) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")