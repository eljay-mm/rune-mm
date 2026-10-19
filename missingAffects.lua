-- Filename: eljayPlugins/missingAffects.lua
-- Purpose: Compare listed affects with a wanted-affects list and report missing affects.
-- Version: 1.18
-- Date: 2026-Oct-18
--[[
Todo:
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.18 The name is requested from the game at load (silently, only when it is not
--        already known and GMCP is enabled), so "missingAffects charname" is no
--        longer needed after a /reload.
--   1.17 "missingAffects charname" now reports the name itself when the game's
--        reply arrives, so it only needs to be run once.
--   1.16 Settings reload the moment the character name changes, through
--        charname.on_change; the checks at each command and listing remain as a
--        backstop.
--   1.15 Character name now comes only from horstgs' charname.lua (get/key), so the
--        own GMCP hooks, rune.connection.character and shape-guessing are removed;
--        keys are charname.key("missingAffects.<setting>"). New command
--        "missingAffects charname" asks the game for the name again and reports it.
--        v1.13 keys (base:Name) and pre-1.13 global keys are adopted once.
--   1.14 Brought to standard: load time shown in the help footer (load=Nms); faster
--        load (one regex alias for missingAffects / ma / mac, one combined trigger,
--        helpstyle and saved settings loaded on first use, GMCP hooked only when no
--        name is available otherwise); the character name is read from horstgs'
--        charname module when it can be required, then rune.connection.character,
--        then GMCP.
--   1.13 Settings are saved only under the character name (rule for this plugin).
--        Before, a plugin loaded before the character name was known read and wrote
--        one global key shared by every character, and rune.connection.character
--        may never be set. Now the name comes from rune.connection.character or,
--        failing that, from GMCP (Char.Name, Char.Base, Char.Status); settings are
--        (re)loaded when it becomes known or changes, and
--        nothing is written while it is unknown (a one-line notice says so). A
--        pre-1.13 global value is adopted once into the character's own key. The
--        footer shows char=<name>.
--   1.12 Removed the druid-analogue concept. Spells such as shield or refresh are
--        regular spells that share their name with a bard song: by default they are
--        sent as cast '<spell>', and with "missingAffects class bard" they are
--        played as songs instead. Druid invocations ("<element> invocation") are
--        unchanged and always sent as invoke <element>. Class values are now
--        spell (default) and bard.
--   1.11 Added "missingAffects cast all" and "mac all": cast every wanted affect,
--        present or not, to extend durations. "mac" is now a regex alias so it
--        accepts the "all" argument.
--   1.10 Root cause of false "missing" reports fixed: the real affects output has
--        rows such as "Spell:      shield   - Level 241, modifies ar ..." and
--        "Affect:     air invocation   - Level ...", which no trigger matched, so
--        nothing was ever recorded. One trigger now captures the name from
--        Spell/Affect/Racial/Skill rows; "You are affected by the following:"
--        starts a fresh listing; the unused "Affects:" trigger is removed.
--   1.9  Fixed false "missing" reports: each listed line is now reduced to several
--        candidate names (whole line, label removed, text before ":" "(" " - " or a
--        number) before matching, so decorated lines such as "Spell: shield : 5
--        hours" match the wanted name "shield"; trigger patterns tolerate leading
--        whitespace; "missingAffects lines" shows what the last listing captured.
--        DRUID_SPELLS fixed (duplicate "magma invocation" key lost minerals) and
--        rebuilt from rows so duplicates are detected.
--   1.8  Bard play and druid invoke/evoke reintegrated from bardSongTLAs 2.4 and
--        druidSpellTLAs 2.6: separate BARD_SONGS and DRUID_SPELLS tables, a class
--        setting picks the method for names both classes share (shield, light...),
--        and the druid analogues missing before (enhanced strength, shield,
--        levitation, refresh, blindness, fireball, haste) are added.
--   1.7  Brought to standard: annwnQuestSearch display method, bare commands as
--        rune.alias.exact handlers taking (args, ctx), loader line with short
--        alias, regex-syntax trigger patterns, stale-listing reset.
--
-- How it works:
--   * Affects output parsed (Materia Magica):
--       You are affected by the following:
--       Racial:  sense life
--       Spell:      shield        - Level 241, modifies ar   by 9 for 715 minutes.
--       Affect:     air invocation - Level 241, modifies none by 0 for 695 minutes.
--       Total of 19 magical affects.
--     The header starts a listing, each Spell/Affect/Racial/Skill row records its
--     name (repeated rows for one affect are harmless), and the "Total of ..."
--     line triggers the comparison.
--   * Loads fast: one regex alias serves missingAffects, ma and mac, one trigger
--     serves the header, rows and total, and helpstyle and saved settings are
--     read on first use. The help footer shows the measured load time.
--   * Compares affects in the current listing against the wanted-affects list.
--   * Matching is case-insensitive and exact against candidate names derived from
--     each listed line (see 1.9); configured similar-affect groups suppress
--     alerts when a listed affect is equivalent to a wanted one.
--   * "missingAffects cast all" (or "mac all") sends a command for every item in
--     the wanted list whether or not it is currently present, to refresh spells.
--   * Run "missingAffects debug on" and then "affects" to see every captured line
--     and its candidate names; "missingAffects lines" repeats the last capture.
--   * At the listing summary, reports wanted affects that were not found.
--   * "missingAffects cast" sends one command per item in the most recent
--     missing-affects result.
--   * Command per name: druid invocations ("magma invocation" and so on) are sent
--     as invoke <element>; every other name is a regular spell and is sent as
--     cast '<name>'. With "missingAffects class bard", names that are also bard
--     songs are sent as play '<song>' instead (class spell is the default).
--   * Settings (wanted list, on/off, debug, class) are stored in rune.store under
--     keys made by charname.key("missingAffects.<setting>") (horstgs' charname.lua,
--     which tracks the name from GMCP). They are never saved without a character
--     name. Settings reload as soon as charname.lua reports a new name;
--     until the name is known, changes last for the session only. Settings load
--     when the name first becomes known and again if it changes.
--   * A listing that never reaches its summary line is discarded when the next
--     affect line arrives more than LISTING_TIMEOUT seconds later.
--
-- Commands:
--   missingAffects [help]          show help and current settings
--   ma [help]                      short alias
--   missingAffects on|off          enable or disable listing triggers
--   missingAffects debug on|off    toggle debug output (default off)
--   missingAffects class spell|bard  cast spells (default) or play bard songs
--   missingAffects want <names>    replace wanted list; separate names with commas
--   missingAffects add <name>      add an affect to the wanted list
--   missingAffects remove <name>   remove an affect from the wanted list
--   missingAffects list            show wanted affects
--   missingAffects lines           show lines captured by the last affects listing
--   missingAffects charname        ask the game for the character name again and show it
--   missingAffects clear           clear wanted affects
--   missingAffects cast            play/invoke/evoke/cast the last missing-affects list
--   missingAffects cast all        cast every wanted affect, even if already present
--   mac                            alias for "missingAffects cast"
--   mac all                        alias for "missingAffects cast all"
--
-- Tweaks:
--   Edit DEFAULT_WANTED and SIMILAR_AFFECT_GROUPS to suit your character.
--   The character name needs charname.lua to be loadable with require("charname").
--   Keep BARD_SONGS and DRUID_INVOCATIONS in step with bardSongTLAs and druidSpellTLAs.
--   Song names with no regular spell of the same name need class bard to work.
--   Command names are validated before being sent.

local LOAD_START = os.clock()

local NAME = "missingAffects"
local SHORT = "ma"
local VERSION = "1.18"

local KEY_WANTED = "missingAffects.wanted"
local KEY_ENABLED = "missingAffects.enabled"
local KEY_DEBUG = "missingAffects.debug"
local KEY_CLASS = "missingAffects.class"

local LISTING_TIMEOUT = 10 -- seconds before an unfinished listing is discarded

local DEFAULT_WANTED = {}
local SIMILAR_AFFECT_GROUPS = {}

-- Bard songs, from bardSongTLAs: play '<song>' (used when class is bard).
local BARD_SONGS = {
  "battle march", "detect invisibility", "footloose", "enhanced strength",
  "epiphany", "inspirational hymn", "levitation", "light", "mass levitation",
  "shield", "traveling song", "blindness", "cacophony", "fireball", "earworm",
  "hands of wind", "harmonize", "hinder", "pensive dirge", "plodding fugue",
  "soothing nocturne", "tremolo", "ode to the moon", "tempus rigor", "calm",
  "cure light", "invigorating performance", "nights fortune", "refresh",
  "rime of the glacierbreaker", "thunderclap", "tremor",
}

-- Druid invocations: { affect name, verb, element }, from druidSpellTLAs;
-- always sent as invoke/evoke <element> (element unquoted), whatever the class setting.
local DRUID_INVOCATIONS = {
  { "magma invocation",     "invoke", "magma" },
  { "minerals invocation",  "invoke", "minerals" },
  { "ice invocation",       "invoke", "ice" },
  { "ooze invocation",      "invoke", "ooze" },
  { "air invocation",       "invoke", "air" },
  { "steam invocation",     "invoke", "steam" },
  { "dust invocation",      "invoke", "dust" },
  { "fire invocation",      "invoke", "fire" },
  { "lightning invocation", "invoke", "lightning" },
}

-- affect name -> { verb, element }; built once at load, first row wins.
local INVOCATION_LOOKUP = {}
local DRUID_DUPLICATES = {}
for _, row in ipairs(DRUID_INVOCATIONS) do
  local key = row[1]:lower()
  if INVOCATION_LOOKUP[key] then
    DRUID_DUPLICATES[#DRUID_DUPLICATES + 1] = key
  else
    INVOCATION_LOOKUP[key] = { row[2], row[3] }
  end
end

local BARD_LOOKUP = {}
for _, song in ipairs(BARD_SONGS) do BARD_LOOKUP[song] = true end

local enabled = true
local debug_enabled = false
local class_mode = "spell" -- spell: cast regular spells; bard: play songs of the same name
local wanted = {}
local loaded_for = nil -- character name the settings were last loaded for
local warned_no_char = false
local report_pending = false -- "missingAffects charname" is waiting for the game's reply
local load_ms = nil -- measured at the end of loading, shown in the help footer
local listed = {}
local last_lines = {} -- raw lines captured by the last listing, for diagnosis
local missing_last = {}
local listing_active = false
local listing_stamp = 0

-- helpstyle is loaded on first use of the help output (faster plugin load).
local helpstyle_loaded, helpstyle_module = false, nil
local function get_helpstyle()
  if not helpstyle_loaded then
    helpstyle_loaded = true
    local ok, module = pcall(require, "helpstyle")
    if ok and type(module) == "table" then helpstyle_module = module end
  end
  return helpstyle_module
end

-- ---------------------------------------------------------------------------
-- Display (annwnQuestSearch method: paint/say via rune.echo, H.* rows via emit)
-- ---------------------------------------------------------------------------

local function paint(color, text)
  if rune and rune.style and type(rune.style[color]) == "function" then
    local ok, styled = pcall(rune.style[color], text)
    if ok and type(styled) == "string" then return styled end
  end
  return text
end

local function emit(text)
  if rune and type(rune.echo) == "function" then
    rune.echo(tostring(text))
  end
end

local function say(text)
  emit(paint("cyan", "[" .. NAME .. "] ") .. tostring(text))
end

local function dbg(fmt, ...)
  if not debug_enabled then return end
  local ok, text = pcall(string.format, fmt, ...)
  say("debug: " .. (ok and text or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize(text)
  return (trim(text):lower():gsub("%s+", " "))
end

local function onoff(value)
  return value and "on" or "off"
end

local function split_names(text)
  local out = {}
  for item in tostring(text or ""):gmatch("[^,]+") do
    item = trim(item)
    if item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

local function strip_ansi(text)
  return (tostring(text or ""):gsub("\27%[[%d;]*[A-Za-z]", ""))
end

-- Reduce one listed line to candidate names: the whole line, the text after a
-- one-word label ("Spell:"), and the text before a delimiter such as ":" "(" "["
-- " - " or a number (durations). Matching stays exact against these keys, so a
-- wanted "light" never matches "cure light".
local function candidate_keys(raw)
  local keys, seen = {}, {}
  local function add(text)
    text = normalize((tostring(text or ""):gsub("[%.,;]+%s*$", "")))
    if text ~= "" and not seen[text] then
      seen[text] = true
      keys[#keys + 1] = text
    end
  end

  local text = normalize(strip_ansi(raw))
  add(text)

  local label, body = text:match("^(%a+):%s*(.+)$")
  if label then
    add(body)
  else
    body = text
  end

  add(body:match("^(.-)%s*[:%(%[]"))
  add(body:match("^(.-)%s+%-%s"))
  add(body:match("^(.-)%s+%d"))
  add(body:match("^(.-)%s+for%s"))
  return keys
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- horstgs' charname.lua (get / key), required once on first use. It keeps the
-- name from GMCP and is shared with other plugins.
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
  local module = get_charname_module()
  if not (module and type(module.get) == "function") then return nil end

  local ok, value = pcall(module.get)
  if ok and type(value) == "string" then
    value = trim(value)
    if value ~= "" then return value end
  end
  return nil
end

-- Store key for the current character, e.g. "missingAffects.wanted.littlejester".
local function store_key(base)
  local module = get_charname_module()
  if module and type(module.key) == "function" then
    local ok, key = pcall(module.key, base)
    if ok and type(key) == "string" then return key end
  end
  return nil
end

local function store_get(key)
  if not (rune and rune.store and type(rune.store.get) == "function") then
    return nil
  end
  local ok, value = pcall(rune.store.get, key)
  if ok then return value end
  return nil
end

local function default_wanted()
  local out = {}
  for _, item in ipairs(DEFAULT_WANTED) do out[#out + 1] = item end
  return out
end

local function is_boolean(v) return type(v) == "boolean" end
local function is_table(v) return type(v) == "table" end
local function is_class(v) return v == "bard" or v == "spell" end

-- Save under the character name only; never write a global key.
local function save_value(base, value)
  local char = charname()
  if not char then
    if not warned_no_char then
      warned_no_char = true
      say("character name not known yet (see missingAffects charname); changes are kept for this session only")
    end
    return false
  end

  if not (rune and rune.store and type(rune.store.set) == "function") then
    dbg("rune.store.set unavailable; %s not saved", base)
    return false
  end

  local key = store_key(base)
  if not key then
    dbg("no charname key for %s; not saved", base)
    return false
  end

  local ok, err = pcall(rune.store.set, key, value)
  if not ok then
    dbg("save failed for %s: %s", key, tostring(err))
  end
  return ok
end

-- Read one setting for a character; a pre-1.13 global value is adopted once.
local function read_setting(base, char, valid)
  local key = store_key(base)
  local value = key and store_get(key)
  if valid(value) then return value end

  -- Older layouts: v1.13 "<base>:<Name>", then pre-1.13 global "<base>".
  local legacy = store_get(base .. ":" .. char)
  if not valid(legacy) then legacy = store_get(base) end
  if valid(legacy) then
    dbg("adopting legacy %s for %s", base, char)
    save_value(base, legacy)
    return legacy
  end
  return nil
end

-- Load settings for the current character the first time its name is known and
-- whenever it changes. Cheap enough to call before every command and trigger.
local function ensure_settings(force)
  if loaded_for and not force then return end

  local char = charname()
  if not char or char == loaded_for then return end

  loaded_for = char
  warned_no_char = false

  enabled = true
  debug_enabled = false
  class_mode = "spell"
  wanted = default_wanted()

  local saved_wanted = read_setting(KEY_WANTED, char, is_table)
  if saved_wanted then wanted = saved_wanted end

  local saved_enabled = read_setting(KEY_ENABLED, char, is_boolean)
  if saved_enabled ~= nil then enabled = saved_enabled end

  local saved_debug = read_setting(KEY_DEBUG, char, is_boolean)
  if saved_debug ~= nil then debug_enabled = saved_debug end

  local saved_class = read_setting(KEY_CLASS, char, is_class)
  if saved_class then class_mode = saved_class end

  for _, key in ipairs(DRUID_DUPLICATES) do
    dbg("duplicate druid affect name ignored: %s", key)
  end
  dbg("settings loaded for %s", char)
end

local function save_wanted()
  return save_value(KEY_WANTED, wanted)
end

local function report_charname()
  local char = charname()
  if char then
    say("character name: " .. char .. " (settings key: " .. tostring(store_key(KEY_WANTED)) .. ")")
  end
  return char ~= nil
end

-- Ask the game for the name (the same requests charname.lua sends on login).
local function request_charname()
  if rune and rune.gmcp and type(rune.gmcp.is_enabled) == "function"
      and type(rune.gmcp.send) == "function" then
    local ok, enabled_gmcp = pcall(rune.gmcp.is_enabled)
    if ok and enabled_gmcp then
      pcall(rune.gmcp.send, "char.base", { [""] = "" })
      pcall(rune.gmcp.send, "char.status", { [""] = "" })
      dbg("requested char.base and char.status")
    else
      dbg("GMCP is not enabled; nothing requested")
    end
  end
end

-- "missingAffects charname": request the name again, reload settings for it, and
-- report it: now if it is known, otherwise when the game's reply arrives (see the
-- charname.on_change hook at the end of the file).
local function refresh_charname()
  if not get_charname_module() then
    say("charname.lua not found (require \"charname\" failed); cannot detect the character name")
    return
  end

  request_charname()
  ensure_settings(true)

  if report_charname() then
    report_pending = false
  else
    report_pending = true
    say("character name requested; it will be shown when the game replies")
  end
end

-- ---------------------------------------------------------------------------
-- Matching and reporting
-- ---------------------------------------------------------------------------

local function is_safe_command_name(name)
  return type(name) == "string"
    and name ~= ""
    and name:match("^[%w %-]+$") ~= nil
end

local function has_similar_match(name, found)
  local wanted_name = normalize(name)
  if found[wanted_name] then return true end

  for _, group in ipairs(SIMILAR_AFFECT_GROUPS) do
    local contains_wanted = false
    local contains_found = false

    for _, member in ipairs(group) do
      local normalized = normalize(member)
      if normalized == wanted_name then contains_wanted = true end
      if found[normalized] then contains_found = true end
    end

    if contains_wanted and contains_found then return true end
  end

  return false
end

local function report_missing()
  missing_last = {}
  for _, name in ipairs(wanted) do
    if not has_similar_match(name, listed) then
      missing_last[#missing_last + 1] = name
    end
  end

  if #missing_last == 0 then
    say("No wanted affects are missing.")
    return
  end

  say("Missing affects: " .. table.concat(missing_last, ", "))
end

local function begin_listing()
  listed = {}
  last_lines = {}
  listing_active = true
  listing_stamp = os.time()
  dbg("started affect listing")
end

local function record_affect(name)
  name = trim(strip_ansi(name))
  if name == "" then return end

  -- Discard a listing that never reached its summary line.
  if listing_active and (os.time() - listing_stamp) > LISTING_TIMEOUT then
    dbg("discarding stale listing")
    listing_active = false
  end

  if not listing_active then
    begin_listing()
  end

  listing_stamp = os.time()
  last_lines[#last_lines + 1] = name
  local keys = candidate_keys(name)
  for _, key in ipairs(keys) do listed[key] = true end
  dbg("listed: %s => [%s]", name, table.concat(keys, " | "))
end

local function finish_listing()
  if not listing_active then
    begin_listing()
  end
  listing_active = false
  report_missing()
end

-- Resolve an affect name to method, name. Druid invocations always use
-- invoke/evoke; with class bard, names that are bard songs are played; every
-- other name is a regular spell and is cast.
local function resolve_ability(name)
  local key = normalize(name)
  local invocation = INVOCATION_LOOKUP[key]

  if invocation then return invocation[1], invocation[2] end
  if class_mode == "bard" and BARD_LOOKUP[key] then return "play", key end
  return "cast", name
end

local function send_ability(name)
  if not is_safe_command_name(name) then
    say("Skipped unsafe affect name: " .. tostring(name))
    return
  end

  local method, ability_name = resolve_ability(name)

  if not is_safe_command_name(ability_name) then
    say("Skipped unsafe ability name: " .. tostring(ability_name))
    return
  end

  local command
  if method == "invoke" or method == "evoke" then
    command = method .. " " .. ability_name
  else
    command = method .. " '" .. ability_name .. "'"
  end

  dbg("sending: %s", command)
  if rune and type(rune.send) == "function" then
    rune.send(command)
  end
end

local function cast_missing()
  if #missing_last == 0 then
    say("No saved missing-affects result to cast.")
    return
  end

  for _, name in ipairs(missing_last) do
    send_ability(name)
  end
end

local function cast_all()
  if #wanted == 0 then
    say("Wanted-affects list is empty; nothing to cast.")
    return
  end

  say("Casting all wanted affects: " .. table.concat(wanted, ", "))
  for _, name in ipairs(wanted) do
    send_ability(name)
  end
end

local function show_lines()
  if #last_lines == 0 then
    say("No affect lines captured yet; run your affects command first.")
    return
  end
  say("Captured " .. #last_lines .. " line(s):")
  for _, line in ipairs(last_lines) do
    emit("  " .. line)
  end
  if #missing_last > 0 then
    say("Missing: " .. table.concat(missing_last, ", "))
  end
end

local function show_list()
  if #wanted == 0 then
    say("Wanted-affects list is empty.")
  else
    say("Wanted affects: " .. table.concat(wanted, ", "))
  end
end

-- ---------------------------------------------------------------------------
-- Help
-- ---------------------------------------------------------------------------

local function help_summary()
  local status = "v" .. VERSION
    .. "  enabled=" .. onoff(enabled)
    .. " debug=" .. onoff(debug_enabled)
    .. " class=" .. class_mode
    .. " wanted=" .. #wanted
    .. " char=" .. (charname() or "unknown")
    .. " load=" .. (load_ms or 0) .. "ms"

  local H = get_helpstyle()
  if H and H.title and H.section and H.line and H.foot then
    emit(H.title("Missing affects"))
    emit(H.section("Commands"))
    emit(H.line("missingAffects / ma", "show this help"))
    emit(H.line("missingAffects on|off", "enable or disable listing triggers"))
    emit(H.line("missingAffects debug on|off", "toggle debug output"))
    emit(H.line("missingAffects class spell|bard", "cast spells (default) or play bard songs"))
    emit(H.line("missingAffects want <names>", "replace wanted list; comma-separated"))
    emit(H.line("missingAffects add|remove <name>", "edit wanted-affects list"))
    emit(H.line("missingAffects list|clear", "show or clear wanted list"))
    emit(H.line("missingAffects lines", "show lines captured by the last listing"))
    emit(H.line("missingAffects charname", "refresh the character name from the game"))
    emit(H.line("missingAffects cast / mac", "play/invoke/evoke/cast the last missing result"))
    emit(H.line("missingAffects cast all / mac all", "cast every wanted affect, even if present"))
    emit(H.foot(status))
    return
  end

  say("Missing affects")
  say("  missingAffects / ma            show this help")
  say("  missingAffects on|off           enable or disable listing triggers")
  say("  missingAffects debug on|off     toggle debug output")
  say("  missingAffects class spell|bard cast spells (default) or play bard songs")
  say("  missingAffects want <names>     replace wanted list; comma-separated")
  say("  missingAffects add <name>       add an affect")
  say("  missingAffects remove <name>    remove an affect")
  say("  missingAffects list|clear       show or clear wanted list")
  say("  missingAffects lines            show lines captured by the last listing")
  say("  missingAffects charname         refresh the character name from the game")
  say("  missingAffects cast / mac       play/invoke/evoke/cast the last missing result")
  say("  missingAffects cast all / mac all  cast every wanted affect, even if present")
  say(status)
end

-- ---------------------------------------------------------------------------
-- Command handling
-- ---------------------------------------------------------------------------

local function handle_command(text)
  text = trim(text)
  local verb, rest = text:match("^(%S+)%s*(.-)$")
  verb = (verb or ""):lower()
  rest = trim(rest or "")

  if verb == "cast" then
    if rest:lower() == "all" then
      cast_all()
    else
      cast_missing()
    end
  elseif verb == "on" then
    enabled = true
    save_value(KEY_ENABLED, enabled)
    say("enabled")
  elseif verb == "off" then
    enabled = false
    save_value(KEY_ENABLED, enabled)
    say("disabled")
  elseif verb == "debug" then
    local setting = rest:lower()
    if setting == "on" then
      debug_enabled = true
    elseif setting == "off" then
      debug_enabled = false
    else
      help_summary()
      return
    end
    save_value(KEY_DEBUG, debug_enabled)
    say("debug " .. onoff(debug_enabled))
  elseif verb == "class" then
    local setting = rest:lower()
    if setting ~= "bard" and setting ~= "spell" then
      help_summary()
      return
    end
    class_mode = setting
    save_value(KEY_CLASS, class_mode)
    say("class " .. class_mode)
  elseif verb == "charname" then
    refresh_charname()
  elseif verb == "lines" then
    show_lines()
  elseif verb == "list" then
    show_list()
  elseif verb == "clear" then
    wanted = {}
    save_wanted()
    say("wanted-affects list cleared")
  elseif verb == "want" then
    wanted = split_names(rest)
    save_wanted()
    say("wanted-affects list replaced (" .. #wanted .. " items)")
  elseif verb == "add" then
    if rest == "" then
      help_summary()
      return
    end

    local key = normalize(rest)
    for _, item in ipairs(wanted) do
      if normalize(item) == key then
        say("already wanted: " .. rest)
        return
      end
    end

    wanted[#wanted + 1] = rest
    save_wanted()
    say("added: " .. rest)
  elseif verb == "remove" then
    if rest == "" then
      help_summary()
      return
    end

    local key = normalize(rest)
    for i = #wanted, 1, -1 do
      if normalize(wanted[i]) == key then
        table.remove(wanted, i)
      end
    end

    save_wanted()
    say("removed: " .. rest)
  else
    help_summary()
  end
end

-- ---------------------------------------------------------------------------
-- Triggers (regex syntax)
-- ---------------------------------------------------------------------------

-- One trigger for the whole listing (fewer registrations, one match per line):
--   m[1] header "You are affected by the following:"
--   m[2] row label, m[3] affect name from "Spell:      name   - Level N, modifies ..."
--        (Racial rows have no Level part)
--   m[4] total line "Total of N magical affects."
if rune and rune.trigger and type(rune.trigger.regex) == "function" then
  rune.trigger.regex("^\\s*(?:([Yy]ou are affected by the following:?)|(Spell|Affect|Racial|Skill):\\s+(.+?)(?:\\s+-\\s+Level\\b.*)?|(Total of .+ affects?\\.?))\\s*$", function(m)
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
end

-- ---------------------------------------------------------------------------
-- Alias (one regex alias for missingAffects, ma and mac; bare commands, no / prefix)
-- ---------------------------------------------------------------------------

if rune and rune.alias and type(rune.alias.regex) == "function" then
  rune.alias.regex("^(missingAffects|ma|mac)(?:[ ]+(.+))?$", function(m)
    local command = (m and m[1]) or ""
    local rest = trim((m and m[2]) or "")

    ensure_settings(true) -- re-check the character name before any command

    if command == "mac" then
      if rest:lower() == "all" then
        cast_all()
      else
        cast_missing()
      end
    else
      handle_command(rest)
    end
  end)
end

-- Reload settings as soon as charname.lua reports a new name (a backstop check also
-- runs at each command and each affects listing).
do
  local module = get_charname_module()
  if module and type(module.on_change) == "function" then
    local ok, err = pcall(module.on_change, function(old_name, new_name)
      ensure_settings(true)
      dbg("character name changed: %s -> %s", tostring(old_name), tostring(new_name))
      if report_pending and report_charname() then
        report_pending = false
      end
    end)
    if not ok then dbg("charname.on_change failed: %s", tostring(err)) end
  end

  -- After a /reload the name is lost but the game is still connected: ask for it now.
  if module and not charname() then
    request_charname()
  end
end

load_ms = math.floor((os.clock() - LOAD_START) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")