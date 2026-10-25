-- Filename: eljayPlugins/spellTLAs.lua
-- Purpose: General spell Three Letter Aliases, optionally targettable.
-- Version: 3.9
-- Date: 2026-Oct-21
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   3.9  Match longer spell aliases before shorter prefixes.
--   3.8  Standard pass: NAME/SHORT constants, help footer, load-time reporting, and cyan loader prefix.
--   3.7  Standard pass: spellTLAs command (short alias spell), on/off and debug persisted, loader line, version footer.
--   3.6  Repo-style header and command summary cleanup; behavior preserved.
--   3.5  cwo = word of recall (replaces wor); clre removed; header and help brought in line.
--   3.4  one dispatcher alias for casts and one for n-keys; target validation.
--   3.3  "How it works" header; help, list and debug.
--   3.2  spells added from class path spell lists.
--   3.1  spells grouped and sorted; n* "aff clear" aliases.
--   3.0  merged ySpells.xml + ySpells2.xml.
--
-- How it works:
--   * cast("cXX", "spell name") adds a spell to a lookup table: cXX [target] -> cast 'spell name' [target]
--   * every key starting with "c" also gets an n-alias: nXX -> aff clear 'spell name'
--   * keys not starting with "c" (ill, bbm, ssh, ssw) only get the cast alias
--   * one regex alias handles all cast keys and one handles all n-keys
--   * longer aliases are matched before shorter prefixes
--   * targets are validated before being sent; unsafe or overlong targets are refused
--   * spells are grouped and sorted by spell name within each group
--   * on/off and debug states are stored in rune.store; debug defaults to off
--   * typing spellTLAs or spell alone shows this command summary
--
-- Commands (type without "/"; "spell" is a short alias for "spellTLAs"):
--   spell                 	 show this help
--   spell on|off          	 enable or disable the cast and n-aliases
--   spell list [text]     	 list aliases, optionally filtered by key or spell
--   spell debug on|off        enable or disable debug output
--   spell                     short alias for spellTLAs
--   cXX [target]              cast 'spell' [target]
--   nXX                       aff clear 'spell' (c-keys only)
--
-- Tweaks (top of file):
--   * MAX_TARGET   maximum target length accepted by cast aliases

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME  = "spellTLAs"
local SHORT = "spell"

local VERSION = "3.9"
local MAX_TARGET = 60

local casts    = {}   -- key -> spell name (cXX, ill, bbm, ...)
local clears   = {}   -- nkey -> spell name (nXX)
local registry = {}   -- ordered { {key, spell}, ... } used by the list command

-- Output helpers: cyan "[name] " prefix, one row per message.
local function paint(text)
  local ok, styled = pcall(function() return rune.style.cyan(text) end)
  if ok and type(styled) == "string" then return styled end
  return text
end

local function say(msg)
  rune.echo(paint("[" .. NAME .. "] ") .. msg)
end

-- Persisted settings; failures fall back to the default.
local function load_flag(key, default)
  local ok, value = pcall(function() return rune.store.get(key) end)
  if not ok or value == nil then return default end
  if value == true or value == "true" or value == "on" or value == 1 then return true end
  if value == false or value == "false" or value == "off" or value == 0 then return false end
  return default
end

local function save_flag(key, value)
  pcall(function() rune.store.set(key, value and "on" or "off") end)
end

local ENABLED = load_flag(NAME .. ".enabled", true)
local DEBUG   = load_flag(NAME .. ".debug", false)

local function dbg(msg)
  if DEBUG then say("debug: " .. msg) end
end

-- Returns an empty string for no target, a validated target, or nil if refused.
local function safe_target(raw)
  if raw == nil then return "" end
  raw = raw:match("^%s*(.-)%s*$")
  if raw == "" then return "" end

  if #raw > MAX_TARGET or not raw:match("^[%w %.'_%-]+$") then
    say("target refused (allowed: letters, digits, space, . ' - _; max "
      .. MAX_TARGET .. " chars)")
    return nil
  end

  return raw
end

local function send_cast(spell, target)
  local safe = safe_target(target)
  if safe == nil then return end

  local command = "cast '" .. spell .. "'"
  if safe ~= "" then command = command .. " " .. safe end

  dbg("send: " .. command)
  rune.send(command)
end

-- Records a cast alias and, for c-keys, its corresponding n-key.
local function cast(key, spell)
  if casts[key] then
    say("duplicate key ignored: " .. key)
    return
  end

  casts[key] = spell
  registry[#registry + 1] = { key, spell }

  if key:sub(1, 1) == "c" then
    local nkey = "n" .. key:sub(2)
    if clears[nkey] or casts[nkey] then
      say("n-alias clash ignored: " .. nkey)
    else
      clears[nkey] = spell
    end
  end
end

-- Protection & Buffs
cast("cae", "aegis")
cast("cah", "air halo")
cast("car", "armor")
cast("caa", "augment aura")
cast("bbm", "battlefield medic")
cast("cble", "bless")
cast("cblink", "blink")
cast("ccf", "channel faith")
cast("cca", "consecrate armor")
cast("ccw", "consecrate weapon")
cast("cdv", "demigod visage")
cast("ces", "elemental shield")
cast("cen", "enlighten")
cast("ceq", "equality")
cast("cfl", "fearless")
cast("cfz", "frenzy")
cast("cgl", "glacierskin")
cast("cpd", "inoculate ignorance")
cast("clc", "lava cloak")
cast("clev", "levitation")
cast("cls", "lightning shroud")
cast("clu", "lunar independence")
cast("cmf", "magnetic field")
cast("cng", "necromancers guile")
cast("cph", "phalanx")
cast("cpe", "protection from evil")
cast("cpg", "protection from good")
cast("crs", "rites of solemnity")
cast("csn", "sanctify")
cast("csa", "sanctuary")
cast("csh", "shield")
cast("csb", "smiting blows")
cast("css", "spell shield")
cast("cuw", "underwater breathing")
cast("cxb", "xorn blood")

-- Healing & Cures
cast("cacl", "aura cleansing")
cast("cb", "create bandage")
cast("cba", "create bandage")
cast("ccb", "cure blindness")
cast("ccc", "cure critical")
cast("ccd", "cure disease")
cast("cl", "cure light")
cast("ccl", "cure light")
cast("ccp", "cure poison")
cast("ccs", "cure serious")
cast("ch", "heal")
cast("che", "heal")
cast("clm", "lift malison")
cast("clib", "liberation")
cast("cre", "refresh")
cast("crc", "remove curse")
cast("cres", "resurrect")

-- Offense
cast("cabl", "air blast")
cast("cab", "arcane blast")
cast("cbd", "blood dance")
cast("cbc", "bubble cluster")
cast("cbu", "buffet")
cast("cli", "call lightning")
cast("cac", "cause critical")
cast("cal", "cause light")
cast("cch", "chain lightning")
cast("cdc", "diseased cloud")
cast("cec", "ember carom")
cast("ceo", "energy orb")
cast("cfw", "flame wind")
cast("cfs", "flintstrike")
cast("cfr", "first rain")
cast("cgw", "gravity well")
cast("cha", "harm")
cast("chr", "harrow")
cast("chw", "harrow")
cast("chs", "holy strike")
cast("ciw", "ice wind")
cast("ciwh", "ice whip")
cast("cld", "landslide")
cast("cmd", "magic dart")
cast("cqs", "quicksand")
cast("cfi", "reflective fireball")
cast("cst", "searing touch")
cast("ctr", "tremor")
cast("cww", "whirlwind")

-- Debuffs & Curses
cast("cbl", "blindness")
cast("ccm", "calm")
cast("cdn", "condemn")
cast("cco", "counterspell")
cast("ccu", "curse")
cast("cfg", "cursed fog")
cast("cdar", "desecrate armor")
cast("cex", "excommunicate")
cast("cff", "faerie fire")
cast("cpl", "plague")
cast("cpo", "poison")
cast("cti", "tinnitus")
cast("cwarp", "warp")
cast("cwe", "weaken")
cast("cwt", "withering touch")

-- Dispels
cast("cabj", "abjure")
cast("cda", "dispel area")
cast("cdm", "dispel magic")

-- Detection & Information
cast("cdal", "detect alignment")
cast("ill", "detect illusion")
cast("cdi", "detect illusion")
cast("cdiv", "detect invisibility")
cast("cdl", "detect lore")
cast("cde", "detect magic")
cast("cdt", "detect truth")
cast("cra", "read aura")
cast("csl", "sense life")

-- Summons & Conjuring
cast("ccel", "conjure celestial")
cast("cce", "conjure elemental")
cast("ccsp", "conjure spirit")
cast("cml", "megalith")
cast("cmo", "monument")
cast("ssh", "summon shaman")
cast("ssw", "summon wizard")
cast("cto", "totem")

-- Travel & Utility
cast("cbe", "beacon")
cast("cpa", "create parchment")
cast("cdg", "daggerportal")
cast("cdp", "daggerportal")
cast("cfo", "fountain")
cast("cgt", "gate travel")
cast("cilu", "illumination")
cast("cmu", "magic unlock")
cast("cla", "portal to the laser dimension")
cast("crp", "radiant prayer")
cast("creq", "requiem")
cast("crv", "revert catastrophe")
cast("cso", "soul sacrifice")
cast("cwo", "word of recall")

-- Build each dispatcher pattern once after the lookup tables are populated.
local function key_pattern(tbl)
  local keys = {}
  for key in pairs(tbl) do
    keys[#keys + 1] = key
  end

  -- Match the longest alias first so a shorter prefix cannot consume it.
  table.sort(keys, function(a, b)
    if #a == #b then return a < b end
    return #a > #b
  end)

  return table.concat(keys, "|")
end

local function off_notice()
  say("aliases are off (" .. NAME .. " on to enable)")
end

rune.alias.regex("^(" .. key_pattern(casts) .. ")(?:[ ]+(.+))?$", function(match)
  if not ENABLED then off_notice() return end
  local spell = casts[match[1]]
  if spell then send_cast(spell, match[2]) end
end)

rune.alias.regex("^(" .. key_pattern(clears) .. ")$", function(match)
  if not ENABLED then off_notice() return end

  local spell = clears[match[1]]
  if spell then
    local command = "aff clear '" .. spell .. "'"
    dbg("send: " .. command)
    rune.send(command)
  end
end)

local H = require("helpstyle")

local function emit(row)
  rune.echo(row)
end

local LOAD_MS

local function status_row()
  return string.format("v%s  enabled=%s debug=%s aliases=%d load=%dms",
    VERSION, tostring(ENABLED), tostring(DEBUG), #registry, LOAD_MS)
end

local function show_help()
  emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  emit(H.section("Commands"))
  emit(H.line(NAME, "show this help"))
  emit(H.line(SHORT .. " on|off", "enable or disable the aliases"))
  emit(H.line(SHORT .. " list [text]", "list aliases, optionally filtered"))
  emit(H.line(SHORT .. " debug on|off", "enable or disable debug output"))
  emit(H.line(SHORT, "short alias for " .. NAME))
  emit(H.section("Aliases"))
  emit(H.line("cXX [target]", "cast 'spell' [target]"))
  emit(H.line("nXX", "aff clear 'spell' (c-keys only)"))
  emit(H.foot(status_row()))
end

local function show_list(filter)
  filter = filter and filter:lower() or ""
  local shown = 0

  emit(H.title(NAME .. " list"))
  for _, entry in ipairs(registry) do
    if filter == ""
      or entry[1]:find(filter, 1, true)
      or entry[2]:find(filter, 1, true) then
      local nkey = entry[1]:sub(1, 1) == "c"
        and ("n" .. entry[1]:sub(2))
        or "-"
      emit(H.line(entry[1] .. " / " .. nkey, entry[2]))
      shown = shown + 1
    end
  end

  emit(H.foot(status_row() .. " shown=" .. shown))
end

local function set_flag(which, argument)
  argument = (argument or ""):lower()

  if which == "enabled" then
    if argument == "on" then
      ENABLED = true
    elseif argument == "off" then
      ENABLED = false
    else
      ENABLED = not ENABLED
    end
    save_flag(NAME .. ".enabled", ENABLED)
    say("aliases " .. (ENABLED and "on" or "off"))
  else
    if argument == "on" then
      DEBUG = true
    elseif argument == "off" then
      DEBUG = false
    else
      DEBUG = not DEBUG
    end
    save_flag(NAME .. ".debug", DEBUG)
    say("debug " .. (DEBUG and "on" or "off"))
  end
end

local function handle(line)
  local argument = (line or ""):match("^%s*(.-)%s*$")
  local command, rest = argument:match("^(%S*)%s*(.-)$")
  command = (command or ""):lower()

  if command == "on" or command == "off" then
    set_flag("enabled", command)
  elseif command == "list" then
    show_list(rest)
  elseif command == "debug" then
    set_flag("debug", rest)
  else
    show_help()
  end
end

-- Bare commands are exact aliases; commands with arguments use one regex alias.
rune.alias.exact(NAME, function(args, ctx)
  show_help()
end)

rune.alias.exact(SHORT, function(args, ctx)
  show_help()
end)

rune.alias.regex("^(" .. NAME .. "|" .. SHORT .. ")[ ]+(.+)$", function(match)
  handle(match[2])
end)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

local style = rune.style
local function say_loaded(message)
  local prefix = "[" .. NAME .. "] "
  local ok, styled = pcall(function() return style.cyan(prefix) end)
  if ok and type(styled) == "string" then prefix = styled end
  rune.echo(prefix .. message)
end

say_loaded(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
