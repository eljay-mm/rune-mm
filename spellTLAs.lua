-- Filename: eljayPlugins/spellTLAs.lua
-- Purpose: General spell Three Letter Aliases, optionally targettable.
-- Version: 3.7
-- Date: 2026-Oct-16
-- Changelog:
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
--   * cast("cXX", "spell name") adds a spell to a lookup table:  cXX [target] -> cast 'spell name' [target]
--   * every key starting with "c" also gets an n-alias: nXX -> aff clear 'spell name'
--       e.g. cdm = cast 'dispel magic', ndm = aff clear 'dispel magic'  (n-aliases take no target)
--   * keys not starting with "c" (ill, bbm, ssh, ssw) only get the cast alias
--   * after the table is built, ONE regex alias handles all cast keys and ONE handles all n-keys
--     (instead of ~260 separate aliases), so each input line costs at most two regex checks
--   * targets are validated: only letters, digits, spaces and . ' - _ (max 60 chars) are sent;
--     anything else (such as ";" or control characters) is refused and nothing is sent
--   * spells are grouped (buffs, cures, offense, ...) and sorted by spell name within each group
--   * "spellTLAs off" disables the cast and n-aliases (typing one only shows a notice);
--     on/off and debug are saved in rune.store and survive a reload (debug defaults to off)
--   * typing spellTLAs (or spell) alone shows a command summary; the last row shows the version
--
-- Commands:
--   spellTLAs                 show the command summary (short alias: spell)
--   spellTLAs on|off          enable or disable the cast and n-aliases
--   spellTLAs list [text]     list aliases, optionally filtered by key or spell
--   spellTLAs debug on|off    toggle debug output (default off)
--   cXX [target]              cast 'spell' [target]
--   nXX                       aff clear 'spell'  (for c-keys only)

local NAME    = "spellTLAs"
local VERSION = "3.7"
local MAX_TARGET = 60

local casts    = {}   -- key  -> spell name   (cXX, ill, bbm, ...)
local clears   = {}   -- nkey -> spell name   (nXX)
local registry = {}   -- ordered { {key, spell}, ... } used by "spellTLAs list"

-- Output helpers: cyan "[name] " prefix, one row per message.
local function paint(text)
  local ok, s = pcall(function() return rune.style.cyan(text) end)
  if ok and type(s) == "string" then return s end
  return text
end

local function say(msg)
  rune.echo(paint("[" .. NAME .. "] ") .. msg)
end

-- Persisted settings (rune.store); any failure falls back to the default.
local function load_flag(key, default)
  local ok, v = pcall(function() return rune.store.get(key) end)
  if not ok or v == nil then return default end
  if v == true or v == "true" or v == "on" or v == 1 then return true end
  if v == false or v == "false" or v == "off" or v == 0 then return false end
  return default
end

local function save_flag(key, val)
  pcall(function() rune.store.set(key, val and "on" or "off") end)
end

local ENABLED = load_flag(NAME .. ".enabled", true)
local DEBUG   = load_flag(NAME .. ".debug", false)

local function dbg(msg)
  if DEBUG then say("debug: " .. msg) end
end

-- Validate a user-supplied target before it is placed in a command.
-- Returns "" for no target, the cleaned target, or nil (refused).
local function safe_target(raw)
  if raw == nil then return "" end
  raw = raw:match("^%s*(.-)%s*$")
  if raw == "" then return "" end
  if #raw > MAX_TARGET or not raw:match("^[%w %.'_%-]+$") then
    say("target refused (allowed: letters, digits, space, . ' - _ ; max " .. MAX_TARGET .. " chars)")
    return nil
  end
  return raw
end

local function send_cast(spell, target)
  local t = safe_target(target)
  if t == nil then return end
  local cmd = "cast '" .. spell .. "'"
  if t ~= "" then cmd = cmd .. " " .. t end
  dbg("send: " .. cmd)
  rune.send(cmd)
end

-- Helper (must be defined before use)
--   cast("cXX", "spell name") records:
--     cXX [target]  ->  cast 'spell name' [target]
--     nXX           ->  aff clear 'spell name'   (only for keys starting with "c")
--   e.g. cast("cla", "portal to the laser dimension") also gives "nla".
--   Aliases are registered once, after the table below (see "Dispatcher aliases").
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

-- Cast Spells (with optional targets), grouped, then sorted by spell name

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
cast("cla", "portal to the laser dimension")   -- also gives "nla"
cast("crp", "radiant prayer")
cast("creq", "requiem")
cast("crv", "revert catastrophe")
cast("cso", "soul sacrifice")
cast("cwo", "word of recall")


-- Dispatcher aliases: one regex for all cast keys, one for all n-keys
local function key_pattern(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  return table.concat(keys, "|")
end

local function off_notice()
  say("aliases are off (" .. NAME .. " on to enable)")
end

rune.alias.regex("^(" .. key_pattern(casts) .. ")(?:[ ]+(.+))?$", function(m)
  if not ENABLED then off_notice() return end
  local spell = casts[m[1]]
  if spell then send_cast(spell, m[2]) end
end)

rune.alias.regex("^(" .. key_pattern(clears) .. ")$", function(m)
  if not ENABLED then off_notice() return end
  local spell = clears[m[1]]
  if spell then
    local cmd = "aff clear '" .. spell .. "'"
    dbg("send: " .. cmd)
    rune.send(cmd)
  end
end)

-- Help / list / on-off / debug command
local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
  H = {
    title   = function(t) return "== " .. t .. " ==" end,
    section = function(t) return "-- " .. t end,
    line    = function(a, b) return string.format("  %-24s %s", a, b or "") end,
    foot    = function(t) return t end,
  }
end

local function emit(row) rune.echo(row) end

local function status_row()
  return string.format("v%s  on=%s debug=%s aliases=%d", VERSION,
    ENABLED and "on" or "off", DEBUG and "on" or "off", #registry)
end

local function show_help()
  emit(H.title(NAME))
  emit(H.section("Commands"))
  emit(H.line("spellTLAs", "this summary (short alias: spell)"))
  emit(H.line("spellTLAs on|off", "enable or disable the aliases"))
  emit(H.line("spellTLAs list [text]", "list aliases, optionally filtered"))
  emit(H.line("spellTLAs debug on|off", "echo every command sent"))
  emit(H.section("Aliases"))
  emit(H.line("cXX [target]", "cast 'spell' [target]"))
  emit(H.line("nXX", "aff clear 'spell'  (c-keys only)"))
  emit(H.foot(status_row()))
end

local function show_list(filter)
  filter = filter and filter:lower() or ""
  local n = 0
  emit(H.title(NAME .. " list"))
  for _, e in ipairs(registry) do
    if filter == "" or e[1]:find(filter, 1, true) or e[2]:find(filter, 1, true) then
      local nk = e[1]:sub(1, 1) == "c" and ("n" .. e[1]:sub(2)) or "-"
      emit(H.line(e[1] .. " / " .. nk, e[2]))
      n = n + 1
    end
  end
  emit(H.foot(status_row() .. " shown=" .. n))
end

local function set_flag(which, arg)
  arg = arg:lower()
  if which == "enabled" then
    if arg == "on" then ENABLED = true elseif arg == "off" then ENABLED = false else ENABLED = not ENABLED end
    save_flag(NAME .. ".enabled", ENABLED)
    say("aliases " .. (ENABLED and "on" or "off"))
  else
    if arg == "on" then DEBUG = true elseif arg == "off" then DEBUG = false else DEBUG = not DEBUG end
    save_flag(NAME .. ".debug", DEBUG)
    say("debug " .. (DEBUG and "on" or "off"))
  end
end

local function handle(line)
  local arg = (line or ""):match("^%s*(.-)%s*$")
  local cmd, rest = arg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "on" or cmd == "off" then
    set_flag("enabled", cmd)
  elseif cmd == "list" then
    show_list(rest)
  elseif cmd == "debug" then
    set_flag("debug", rest or "")
  else
    show_help()
  end
end

-- Bare commands are exact aliases; commands with arguments are regex aliases.
rune.alias.exact("spellTLAs", function(args, ctx) show_help() end)
rune.alias.exact("spell", function(args, ctx) show_help() end)
rune.alias.regex("^(?:spellTLAs|spell)[ ]+(.+)$", function(m) handle(m[1]) end)

say(string.format("v%s loaded (%s or spell for help)", VERSION, NAME))