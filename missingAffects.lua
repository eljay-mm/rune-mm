-- Filename: eljayPlugins/missingAffects.lua
-- Purpose: Compare listed affects with a wanted-affects list and report missing affects.
-- Version: 1.8
-- Date: 2026-Oct-16
-- Changelog:
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
--   * Compares affects in the current listing against the wanted-affects list.
--   * Matching is case-insensitive; configured similar-affect groups suppress
--     alerts when a listed affect is equivalent to a wanted one.
--   * At the listing summary, reports wanted affects that were not found.
--   * "missingAffects cast" sends one command per item in the most recent
--     missing-affects result: play '<song>' for bard songs, invoke <element> or
--     evoke <element> for druid spells (element unquoted), cast '<spell>' for
--     anything else.
--   * Names that are both a bard song and a druid analogue use the class
--     setting (bard or druid, default bard); names known to only one class
--     always use that class's method.
--   * Settings (wanted list, on/off, debug, class) are stored in rune.store per
--     character when rune.connection.character is available, and globally
--     otherwise.
--   * A listing that never reaches its summary line is discarded when the next
--     affect line arrives more than LISTING_TIMEOUT seconds later.
--
-- Commands:
--   missingAffects [help]          show help and current settings
--   ma [help]                      short alias
--   missingAffects on|off          enable or disable listing triggers
--   missingAffects debug on|off    toggle debug output (default off)
--   missingAffects class bard|druid  choose the method for shared names
--   missingAffects want <names>    replace wanted list; separate names with commas
--   missingAffects add <name>      add an affect to the wanted list
--   missingAffects remove <name>   remove an affect from the wanted list
--   missingAffects list            show wanted affects
--   missingAffects clear           clear wanted affects
--   missingAffects cast            play/invoke/evoke/cast the last missing-affects list
--   mac                            alias for "missingAffects cast"
--
-- Tweaks:
--   Edit DEFAULT_WANTED and SIMILAR_AFFECT_GROUPS to suit your character.
--   Keep BARD_SONGS and DRUID_SPELLS in step with bardSongTLAs and druidSpellTLAs.
--   Command names are validated before being sent.

local NAME = "missingAffects"
local SHORT = "ma"
local VERSION = "1.8"

local KEY_WANTED = "missingAffects.wanted"
local KEY_ENABLED = "missingAffects.enabled"
local KEY_DEBUG = "missingAffects.debug"
local KEY_CLASS = "missingAffects.class"

local LISTING_TIMEOUT = 10 -- seconds before an unfinished listing is discarded

local DEFAULT_WANTED = {}
local SIMILAR_AFFECT_GROUPS = {}

-- Bard songs (affect name -> song), from bardSongTLAs: play '<song>'.
local BARD_SONGS = {
  "battle march", "detect invisibility", "footloose", "enhanced strength",
  "epiphany", "inspirational hymn", "levitation", "light", "mass levitation",
  "shield", "traveling song", "blindness", "cacophony", "fireball", "earworm",
  "hands of wind", "harmonize", "hinder", "pensive dirge", "plodding fugue",
  "soothing nocturne", "tremolo", "ode to the moon", "tempus rigor", "calm",
  "cure light", "invigorating performance", "nights fortune", "refresh",
  "rime of the glacierbreaker", "thunderclap", "tremor",
}

-- Druid invocations (affect name -> verb, element), from druidSpellTLAs:
-- invoke <element> / evoke <element>, element unquoted.
local DRUID_SPELLS = {
  ["magma invocation"]    = { "invoke", "magma" },
  ["magma invocation"]    = { "invoke", "minerals" },
  ["ice invocation"]      = { "invoke", "ice" },
  ["ooze invocation"]     = { "invoke", "ooze" },
  ["air invocation"]      = { "invoke", "air" },
  ["steam invocation"]    = { "invoke", "steam" },
  ["dust invocation"]     = { "invoke", "dust" },
  ["fire invocation"]     = { "invoke", "fire" },
  ["lightning invocation"]= { "invoke", "lightning" },
}

local BARD_LOOKUP = {}
for _, song in ipairs(BARD_SONGS) do BARD_LOOKUP[song] = true end

local enabled = true
local debug_enabled = false
local class_mode = "bard" -- which class wins for names both classes share
local wanted = {}
local listed = {}
local missing_last = {}
local listing_active = false
local listing_stamp = 0

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

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

-- Alias handlers receive (args, ctx); args is normally the text after the command.
local function arg_text(args)
  if type(args) == "string" then return trim(args) end
  if type(args) == "table" then
    local parts = {}
    for _, v in ipairs(args) do parts[#parts + 1] = tostring(v) end
    return trim(table.concat(parts, " "))
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function character_scope()
  local character = rune and rune.connection and rune.connection.character
  if type(character) == "string" and character ~= "" then
    return ":" .. character
  end
  return ""
end

local function store_key(base)
  return base .. character_scope()
end

local function default_wanted()
  local out = {}
  for _, item in ipairs(DEFAULT_WANTED) do out[#out + 1] = item end
  return out
end

local function load_settings()
  wanted = default_wanted()

  if not (rune and rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok_wanted, saved_wanted = pcall(rune.store.get, store_key(KEY_WANTED))
  if ok_wanted and type(saved_wanted) == "table" then
    wanted = saved_wanted
  end

  local ok_enabled, saved_enabled = pcall(rune.store.get, store_key(KEY_ENABLED))
  if ok_enabled and type(saved_enabled) == "boolean" then
    enabled = saved_enabled
  end

  local ok_debug, saved_debug = pcall(rune.store.get, store_key(KEY_DEBUG))
  if ok_debug and type(saved_debug) == "boolean" then
    debug_enabled = saved_debug
  end

  local ok_class, saved_class = pcall(rune.store.get, store_key(KEY_CLASS))
  if ok_class and (saved_class == "bard" or saved_class == "druid") then
    class_mode = saved_class
  end
end

local function save_value(key, value)
  if rune and rune.store and type(rune.store.set) == "function" then
    pcall(rune.store.set, store_key(key), value)
  end
end

local function save_wanted()
  save_value(KEY_WANTED, wanted)
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
  listing_active = true
  listing_stamp = os.time()
  dbg("started affect listing")
end

local function record_affect(name)
  name = trim((tostring(name or ""):gsub("%.$", "")))
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
  listed[normalize(name)] = true
  dbg("listed affect: %s", name)
end

local function finish_listing()
  if not listing_active then
    begin_listing()
  end
  listing_active = false
  report_missing()
end

-- Resolve an affect name to { method, name }; nil verb means generic cast.
local function resolve_ability(name)
  local key = normalize(name)
  local bard = BARD_LOOKUP[key] and { "play", key } or nil
  local druid = DRUID_SPELLS[key]

  local pick
  if bard and druid then
    pick = (class_mode == "druid") and druid or bard
  else
    pick = bard or druid
  end

  if pick then return pick[1], pick[2] end
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

  if H and H.title and H.section and H.line and H.foot then
    emit(H.title("Missing affects"))
    emit(H.section("Commands"))
    emit(H.line("missingAffects / ma", "show this help"))
    emit(H.line("missingAffects on|off", "enable or disable listing triggers"))
    emit(H.line("missingAffects debug on|off", "toggle debug output"))
    emit(H.line("missingAffects class bard|druid", "method for names both classes share"))
    emit(H.line("missingAffects want <names>", "replace wanted list; comma-separated"))
    emit(H.line("missingAffects add|remove <name>", "edit wanted-affects list"))
    emit(H.line("missingAffects list|clear", "show or clear wanted list"))
    emit(H.line("missingAffects cast / mac", "play/invoke/evoke/cast the last missing result"))
    emit(H.foot(status))
    return
  end

  say("Missing affects")
  say("  missingAffects / ma            show this help")
  say("  missingAffects on|off           enable or disable listing triggers")
  say("  missingAffects debug on|off     toggle debug output")
  say("  missingAffects class bard|druid method for names both classes share")
  say("  missingAffects want <names>     replace wanted list; comma-separated")
  say("  missingAffects add <name>       add an affect")
  say("  missingAffects remove <name>    remove an affect")
  say("  missingAffects list|clear       show or clear wanted list")
  say("  missingAffects cast / mac       play/invoke/evoke/cast the last missing result")
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
    cast_missing()
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
    if setting ~= "bard" and setting ~= "druid" then
      help_summary()
      return
    end
    class_mode = setting
    save_value(KEY_CLASS, class_mode)
    say("class " .. class_mode)
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

if rune and rune.trigger and type(rune.trigger.regex) == "function" then
  rune.trigger.regex("^[Yy]ou are affected by (.+?)\\.?$", function(m)
    if enabled and m and m[1] then
      record_affect(m[1])
    end
  end)

  rune.trigger.regex("^[Aa]ffects:\\s*(.+)$", function(m)
    if enabled and m and m[1] then
      for item in tostring(m[1]):gmatch("[^,;]+") do
        record_affect(item)
      end
    end
  end)

  rune.trigger.regex("^Total of .+ affects?\\.$", function()
    if enabled then
      finish_listing()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Aliases (bare commands; rune.alias.exact does not create slash commands)
-- ---------------------------------------------------------------------------

if rune and rune.alias and type(rune.alias.exact) == "function" then
  rune.alias.exact(NAME, function(args, ctx)
    handle_command(arg_text(args))
  end)

  rune.alias.exact(SHORT, function(args, ctx)
    handle_command(arg_text(args))
  end)

  rune.alias.exact("mac", function(args, ctx)
    cast_missing()
  end)
end

load_settings()
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")