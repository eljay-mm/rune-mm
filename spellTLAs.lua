-- Filename: eljayPlugins/spellTLAs.lua
-- Purpose: General spell Three Letter Aliases, optionally targettable
-- Version: 3.5 (word of recall now cwo; header cleanup)
-- Date: 2026-Oct-12
--
-- Changelog:
--   3.5  cwo = word of recall (replaces wor); clre removed; header and help brought in line
--   3.4  one dispatcher alias for casts and one for n-keys; target validation
--   3.3  "How it works" header; spelltla help, list and debug
--   3.2  spells added from class path spell lists
--   3.1  spells grouped and sorted; n* "aff clear" aliases
--   3.0  merged ySpells.xml + ySpells2.xml
--
-- How it works:
--   * cast("cXX", "spell name") adds a spell to a lookup table:  cXX [target]  ->  cast 'spell name' [target]
--   * every key starting with "c" also gets an n-alias: nXX  ->  aff clear 'spell name'
--       e.g. cdm = cast 'dispel magic', ndm = aff clear 'dispel magic'  (n-aliases take no target)
--   * keys not starting with "c" (ill, bbm, ssh, ssw) only get the cast alias
--   * after the table is built, ONE regex alias handles all cast keys and ONE handles all n-keys
--     (instead of ~260 separate aliases), so each input line costs at most two regex checks
--   * targets are validated: only letters, digits, spaces and . ' - _ (max 60 chars) are sent;
--     anything else (such as ";" or control characters) is refused and nothing is sent
--   * spells are grouped (buffs, cures, offense, ...) and sorted by spell name within each group
--   * spelltla is the only standalone alias (wor became cwo; clre was removed)
--   * "spelltla" alone shows a command summary; "spelltla list [text]" lists aliases;
--     "spelltla debug on|off" echoes every command sent (default off, resets on reload)

local DEBUG = false
local MAX_TARGET = 60

local casts    = {}   -- key  -> spell name   (cXX, ill, bbm, ...)
local clears   = {}   -- nkey -> spell name   (nXX)
local registry = {}   -- ordered { {key, spell}, ... } used by "spelltla list"

local function dbg(msg)
  if DEBUG then rune.echo("[spellTLAs] " .. msg) end
end

-- Validate a user-supplied target before it is placed in a command.
-- Returns "" for no target, the cleaned target, or nil (refused).
local function safe_target(raw)
  if raw == nil then return "" end
  raw = raw:match("^%s*(.-)%s*$")
  if raw == "" then return "" end
  if #raw > MAX_TARGET or not raw:match("^[%w %.'_%-]+$") then
    rune.echo("[spellTLAs] target refused (allowed: letters, digits, space, . ' - _ ; max "
      .. MAX_TARGET .. " chars)")
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

--[[ Helper (must be defined before use)
     cast("cXX", "spell name") records:
       cXX [target]  ->  cast 'spell name' [target]
       nXX           ->  aff clear 'spell name'   (only for keys starting with "c")
     e.g. cast("cla", "portal to the laser dimension") also gives "nla".
     Aliases are registered once, after the table below (see "Dispatcher aliases").
]]--
local function cast(key, spell)
  if casts[key] then
    rune.echo("[spellTLAs] duplicate key ignored: " .. key)
    return
  end
  casts[key] = spell
  registry[#registry + 1] = { key, spell }
  if key:sub(1, 1) == "c" then
    local nkey = "n" .. key:sub(2)
    if clears[nkey] or casts[nkey] then
      rune.echo("[spellTLAs] n-alias clash ignored: " .. nkey)
    else
      clears[nkey] = spell
    end
  end
end

--[[ Cast Spells (with optional targets), grouped, then sorted by spell name ]]--

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

--[[ Dispatcher aliases: one regex for all cast keys, one for all n-keys ]]--
local function key_pattern(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  return table.concat(keys, "|")
end

rune.alias.regex("^(" .. key_pattern(casts) .. ")(?:[ ]+(.+))?$", function(m)
  local spell = casts[m[1]]
  if spell then send_cast(spell, m[2]) end
end)

rune.alias.regex("^(" .. key_pattern(clears) .. ")$", function(m)
  local spell = clears[m[1]]
  if spell then
    local cmd = "aff clear '" .. spell .. "'"
    dbg("send: " .. cmd)
    rune.send(cmd)
  end
end)

--[[ Help / list / debug command ]]--
local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
  H = {
    title   = function(t) return "== " .. t .. " ==" end,
    section = function(t) return "-- " .. t end,
    line    = function(a, b) return string.format("  %-22s %s", a, b or "") end,
    foot    = function(t) return t end,
  }
end

local function show_help()
  rune.echo(H.title("spellTLAs"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("spelltla", "this summary"))
  rune.echo(H.line("spelltla list [text]", "list aliases (optionally filtered by key or spell)"))
  rune.echo(H.line("spelltla debug on|off", "echo every command sent"))
  rune.echo(H.section("Aliases"))
  rune.echo(H.line("cXX [target]", "cast 'spell' [target]"))
  rune.echo(H.line("nXX", "aff clear 'spell'  (c-keys only)"))
  rune.echo(H.foot(string.format("%d spell aliases | debug: %s", #registry, DEBUG and "on" or "off")))
end

local function show_list(filter)
  filter = filter and filter:lower() or ""
  local n = 0
  rune.echo(H.title("spellTLAs list"))
  for _, e in ipairs(registry) do
    if filter == "" or e[1]:find(filter, 1, true) or e[2]:find(filter, 1, true) then
      local nk = e[1]:sub(1, 1) == "c" and ("n" .. e[1]:sub(2)) or "-"
      rune.echo(H.line(e[1] .. " / " .. nk, e[2]))
      n = n + 1
    end
  end
  rune.echo(H.foot(n .. " shown"))
end

rune.alias.regex("^spelltla(?:[ ]+(.*))?$", function(m)
  local arg = (m[1] or ""):match("^%s*(.-)%s*$")
  local cmd, rest = arg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    show_help()
  elseif cmd == "list" then
    show_list(rest)
  elseif cmd == "debug" then
    rest = rest:lower()
    if rest == "on" then DEBUG = true elseif rest == "off" then DEBUG = false
    else DEBUG = not DEBUG end
    rune.echo("[spellTLAs] debug " .. (DEBUG and "on" or "off"))
  else
    show_help()
  end
end)
