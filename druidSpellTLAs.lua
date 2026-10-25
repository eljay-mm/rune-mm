-- Filename: eljayPlugins/druidSpellTLAs.lua
-- Purpose: Druid spells with three-letter acronyms (TLAs).
-- Version: 2.7
-- Date: 2026-Oct-20
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.7  Removed the spell-alias section from help; added a list subcommand that displays
--        every TLA, the command it sends, and its analogue, grouping equivalent commands.
--   2.6  Command renamed druidSpellTLAs with druid as the short alias; one-row loader line;
--        all spell TLAs now share a single alias; duplicate-TLA check; settings no longer
--        re-saved on load.
--   2.5  Added enabled/debug toggles and persisted settings; aliases respect the enabled state.
--
-- How it works:
--   * Each row in the spells table maps a shorthand alias to a verb + element,
--     e.g. "dfi orc" -> "evoke fire orc".
--   * A bare spell alias sends "<verb> <element>"; an optional target is appended once.
--   * TLAs come from analogue spell names or direct d + i/e + element-initial forms.
--   * All spell TLAs are matched by one alias built from the table.
--   * Use "druid list" to display spell aliases, commands, and analogues.
--   * When disabled, spell aliases do nothing; settings persist in rune.store.
--
-- Commands (type without "/"; "druid" is a short alias for "druidSpellTLAs"):
--   druidSpellTLAs                show this help
--   druid                         short alias for druidSpellTLAs
--   druidSpellTLAs list           list spell aliases and analogues
--   druidSpellTLAs on|off         enable / disable all druid TLAs
--   druidSpellTLAs debug on|off   enable / disable debug messages
--
-- Tweaks (top of file):
--   * spells    spell TLA, verb and element mappings

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "druidSpellTLAs"
local SHORT = "druid"

local VERSION = "2.7"
local SETTINGS_KEY = "druidSpellTLAs.settings"
local LOAD_MS = 0

local H = require("helpstyle")

local enabled = true
local debug_enabled = false

local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, settings = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(settings) == "table" then
    if type(settings.enabled) == "boolean" then
      enabled = settings.enabled
    end
    if type(settings.debug) == "boolean" then
      debug_enabled = settings.debug
    end
  end
end

local function save_settings()
  if rune and rune.store and type(rune.store.set) == "function" then
    pcall(rune.store.set, SETTINGS_KEY, {
      enabled = enabled,
      debug = debug_enabled,
    })
  end
end

load_settings()

local function onoff(value)
  return value and "on" or "off"
end

local function say(message)
  local label = "[" .. NAME .. "] "
  if rune.style and type(rune.style.cyan) == "function" then
    local ok, styled = pcall(rune.style.cyan, label)
    if ok and type(styled) == "string" then
      label = styled
    end
  end
  rune.echo(label .. message)
end

local function dbg(format, ...)
  if not debug_enabled then
    return
  end

  local ok, message = pcall(string.format, format, ...)
  say("debug: " .. (ok and message or tostring(format)))
end

local spells = {
  -- Magma
  { "dcf", "evoke", "magma" }, -- circle of fire
  { "dfs", "invoke", "magma" }, -- fireshield

  -- Minerals / Ice / Salt
  { "dcs", "evoke", "minerals" }, -- cure serious
  { "des", "invoke", "minerals" }, -- enhanced strength
  { "dho", "evoke", "ice" }, -- heals someone else
  { "dsh", "invoke", "ice" }, -- shield
  { "dcp", "evoke", "salt" }, -- cure poison
  { "dcd", "invoke", "salt" }, -- cure disease

  -- Ooze
  { "deo", "evoke", "ooze" },
  { "dss", "invoke", "ooze" }, -- stone skin

  -- Vacuum / Air
  { "dblink", "invoke", "vacuum" }, -- blink
  { "dev", "evoke", "vacuum" },
  { "dle", "invoke", "air" }, -- levitation
  { "dea", "evoke", "air" },

  -- Radiance / Smoke / Water
  { "dre", "invoke", "radiance" }, -- refresh
  { "drv", "evoke", "radiance" }, -- reveal
  { "dbl", "evoke", "smoke" }, -- blindness
  { "dis", "invoke", "smoke" },
  { "dew", "evoke", "water" },
  { "diw", "invoke", "water" },

  -- Steam / Ash / Life / Dust
  { "dst", "evoke", "steam" },
  { "dpd", "invoke", "steam" }, -- pass door
  { "dpn", "invoke", "ash" },
  { "dhb", "invoke", "life" }, -- heal blindness
  { "dlf", "evoke", "life" },
  { "dcb", "invoke", "dust" }, -- combat blink
  { "dia", "evoke", "dust" }, -- imprint aura

  -- Earth / Fire / Ether
  { "dwe", "evoke", "earth" }, -- web
  { "dhs", "invoke", "earth" }, -- heal self
  { "dfi", "evoke", "fire" }, -- fireball
  { "dsa", "invoke", "fire" }, -- sanctuary
  { "die", "invoke", "ether" },
  { "dee", "evoke", "ether" },

  -- Lightning
  { "dha", "invoke", "lightning" }, -- haste
  { "dli", "evoke", "lightning" }, -- lightning bolt

  -- Direct evoke aliases
  { "deas", "evoke", "ash" }, -- 4th letter: air owns dea
  { "ded", "evoke", "dust" }, -- imprint aura
  { "deea", "evoke", "earth" }, -- 4th letter: ether owns dee
  { "def", "evoke", "fire" }, -- fireball
  { "dei", "evoke", "ice" }, -- heal other
  { "del", "evoke", "lightning" }, -- lightning bolt
  { "deli", "evoke", "life" }, -- 4th letter: lightning owns del
  { "dem", "evoke", "magma" }, -- circle of fire
  { "demi", "evoke", "minerals" }, -- 4th letter: magma owns dem
  { "der", "evoke", "radiance" }, -- reveal
  { "desa", "evoke", "salt" }, -- 4th letter: des is enhanced strength
  { "desm", "evoke", "smoke" }, -- 4th letter: des is enhanced strength
  { "dest", "evoke", "steam" }, -- 4th letter: des is enhanced strength

  -- Direct invoke aliases
  { "diai", "invoke", "air" }, -- 4th letter: dia is imprint aura
  { "dias", "invoke", "ash" }, -- 4th letter: air owns dia
  { "did", "invoke", "dust" }, -- combat blink
  { "diea", "invoke", "earth" }, -- 4th letter: ether owns die
  { "dif", "invoke", "fire" }, -- sanctuary
  { "dii", "invoke", "ice" }, -- shield
  { "dil", "invoke", "lightning" }, -- haste
  { "dili", "invoke", "life" }, -- 4th letter: lightning owns dil
  { "dim", "invoke", "magma" }, -- fireshield
  { "dimi", "invoke", "minerals" }, -- 4th letter: magma owns dim
  { "dio", "invoke", "ooze" }, -- stone skin
  { "dir", "invoke", "radiance" }, -- refresh
  { "disa", "invoke", "salt" }, -- 4th letter: smoke owns dis
  { "dist", "invoke", "steam" }, -- 4th letter: smoke owns dis
  { "div", "invoke", "vacuum" }, -- blink
}

-- Analogue spell for each invocation / evocation element pair.
local analogues = {
  air = {
    evoke = "—",
    invoke = "levitation",
  },
  ash = {
    evoke = "—",
    invoke = "—",
  },
  dust = {
    evoke = "imprint aura",
    invoke = "combat blink",
  },
  earth = {
    evoke = "web",
    invoke = "heal",
  },
  fire = {
    evoke = "fireball",
    invoke = "sanctuary",
  },
  ice = {
    evoke = "—",
    invoke = "shield",
  },
  lightning = {
    evoke = "lightning bolt",
    invoke = "haste",
  },
  magma = {
    evoke = "circle of fire",
    invoke = "fireshield",
  },
  minerals = {
    evoke = "cure serious",
    invoke = "enhanced strength",
  },
  ooze = {
    evoke = "—",
    invoke = "stone skin",
  },
  radiance = {
    evoke = "reveal",
    invoke = "refresh",
  },
  salt = {
    evoke = "cure poison",
    invoke = "cure disease",
  },
  smoke = {
    evoke = "blindness",
    invoke = "—",
  },
  steam = {
    evoke = "—",
    invoke = "pass door",
  },
  vacuum = {
    evoke = "—",
    invoke = "blink",
  },
  water = {
    evoke = "—",
    invoke = "—",
  },
  ether = {
    evoke = "—",
    invoke = "—",
  },
  life = {
    evoke = "—",
    invoke = "cure blindness",
  },
}

-- Build the lookup once; one regex alias handles all spell TLAs.
local lookup = {}
local names = {}

for _, spell in ipairs(spells) do
  local alias = spell[1]
  if lookup[alias] then
    dbg("duplicate TLA %s ignored", alias)
  else
    lookup[alias] = { verb = spell[2], element = spell[3] }
    names[#names + 1] = alias
  end
end

local function help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(SHORT .. " list", "list spell aliases and analogues"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable all druid TLAs"))
  rune.echo(H.line(SHORT .. " debug on|off", "enable / disable debug messages"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s bindings=3  load=%dms",
    VERSION,
    tostring(enabled),
    tostring(debug_enabled),
    LOAD_MS
  )))
end

local function list_aliases()
  local groups = {}
  local group_order = {}

  for _, alias in ipairs(names) do
    local row = lookup[alias]
    local key = row.verb .. " " .. row.element
    local group = groups[key]

    if not group then
      local element_analogues = analogues[row.element]
      local analogue = element_analogues and element_analogues[row.verb] or "—"

      group = {
        aliases = {},
        command = key,
        analogue = analogue,
      }
      groups[key] = group
      group_order[#group_order + 1] = key
    end

    group.aliases[#group.aliases + 1] = alias
  end

  rune.echo(H.title("Druid spell aliases"))
  for _, key in ipairs(group_order) do
    local group = groups[key]
    rune.echo(H.line(
      table.concat(group.aliases, " | "),
      group.command .. "  ~ " .. group.analogue
    ))
  end
end

local function command(args, _ctx)
  local text = tostring(args or ""):lower()
  local subcommand = text:match("^(%S*)") or ""
  local rest = text:match("^%S+%s*(.*)$") or ""

  if subcommand == "on" then
    enabled = true
    save_settings()
    say("enabled")
  elseif subcommand == "off" then
    enabled = false
    save_settings()
    say("disabled")
  elseif subcommand == "debug" then
    if rest == "on" then
      debug_enabled = true
    elseif rest == "off" then
      debug_enabled = false
    else
      help()
      return
    end
    save_settings()
    say("debug " .. onoff(debug_enabled))
  elseif subcommand == "list" and rest == "" then
    list_aliases()
  else
    help()
  end
end

-- Bare commands are aliases; rune.command.add creates slash commands.
rune.alias.exact(NAME, command)
rune.alias.exact(SHORT, command)

rune.alias.regex("^(" .. table.concat(names, "|") .. ")(?:[ ]+(.+))?$", function(matches)
  local name = matches and matches[1]
  local row = name and lookup[name]
  if not row then
    return
  end

  if not enabled then
    dbg("ignored %s (disabled)", name)
    return
  end

  local target = matches[2]
  if target and (target:find("[\r\n]") or target:find("%z")) then
    say("target rejected: it contains control characters")
    return
  end

  local command_text = row.verb .. " " .. row.element
  if target and target ~= "" then
    command_text = command_text .. " " .. target
  end

  dbg("sending: %s", command_text)
  rune.send(command_text)
end)

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
