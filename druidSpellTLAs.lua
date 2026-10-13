-- Filename: eljayPlugins/druidSpellTLAs.lua
-- Purpose: Druid spells with three-letter acronyms (TLAs).
-- Version: 2.5
-- Date: 2026-Oct-13
-- Changelog:
--   2.5  Added enabled/debug toggles and persisted settings; aliases respect the enabled state.
--   2.4  Previous release.
-- How it works:
--   * Each row maps a shorthand alias to a verb + element (e.g. "dfi orc" -> "evoke fire orc").
--   * Aliases accept an optional target: bare alias sends just "<verb> <element>".
--   * The plugin registers exact/regex aliases; when disabled they do nothing.
--
-- Commands:
--   druidSpellTLAs                show this summary
--   druidSpellTLAs on|off         enable or disable all druid TLAs
--   druidSpellTLAs debug on|off   toggle debug output

local VERSION = "2.5"
local SETTINGS_KEY = "druidSpellTLAs.settings"

local enabled = true
local debug_enabled = false

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

local function dbg(fmt, ...)
  if debug_enabled then
    local ok, s = pcall(string.format, fmt, ...)
    rune.echo("[druidSpellTLAs:debug] " .. (ok and s or tostring(fmt)))
  end
end

local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then return end
  local ok, t = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(t) == "table" then
    if type(t.enabled) == "boolean" then enabled = t.enabled end
    if type(t.debug) == "boolean" then debug_enabled = t.debug end
  end
end

local function save_settings()
  if not (rune and rune.store and type(rune.store.set) == "function") then return end
  pcall(rune.store.set, SETTINGS_KEY, { enabled = enabled, debug = debug_enabled })
end

local spells = {
  -- Magma
  { "dcf",    "evoke",  "magma" },           -- circle of fire
  { "dfs",    "invoke", "magma" },           -- fireshield

  -- Minerals / Ice / Salt
  { "dcs",    "evoke",  "minerals" },        -- cure serious
  { "des",    "invoke", "minerals" },        -- enhanced strength
  { "dho",    "evoke",  "ice" },             -- (no analogue; heals someone else)
  { "dsh",    "invoke", "ice" },             -- shield
  { "dcp",    "evoke",  "salt" },            -- cure poison
  { "dcd",    "invoke", "salt" },            -- cure disease

  -- Ooze
  { "deo",    "evoke",  "ooze" },            -- (no analogue)
  { "dss",    "invoke", "ooze" },            -- stone skin

  -- Vacuum / Air
  { "dblink", "invoke", "vacuum" },          -- blink
  { "dev",    "evoke",  "vacuum" },          -- (no analogue)
  { "dle",    "invoke", "air" },             -- levitation
  { "dea",    "evoke",  "air" },             -- (no analogue)

  -- Radiance / Smoke / Water
  { "dre",    "invoke", "radiance" },        -- refresh
  { "drv",    "evoke",  "radiance" },        -- reveal
  { "dbl",    "evoke",  "smoke" },           -- blindness
  { "dis",    "invoke", "smoke" },           -- (no analogue)
  { "dew",    "evoke",  "water" },           -- (no analogue)
  { "diw",    "invoke", "water" },           -- (no analogue)

  -- Steam / Ash / Life / Dust
  { "dst",    "evoke",  "steam" },           -- (no analogue)
  { "dpd",    "invoke", "steam" },           -- pass door
  { "dpn",    "invoke", "ash" },             -- (no analogue)
  { "dhb",    "invoke", "life" },            -- cure blindness - heal blindness
  { "dlf",    "evoke",  "life" },            -- (no analogue)
  { "dcb",    "invoke", "dust" },            -- combat blink
  { "dia",    "evoke",  "dust" },            -- imprint aura

  -- Earth / Fire / Ether
  { "dwe",    "evoke",  "earth" },           -- web
  { "dhs",    "invoke", "earth" },           -- heal self
  { "dfi",    "evoke",  "fire" },            -- fireball
  { "dsa",    "invoke", "fire" },            -- sanctuary
  { "die",    "invoke", "ether" },           -- (no analogue)
  { "dee",    "evoke",  "ether" },           -- (no analogue)

  -- Lightning
  { "dha",    "invoke", "lightning" },       -- haste
  { "dli",    "evoke",  "lightning" },       -- lightning bolt

  -- Direct evoke aliases
  { "deas",   "evoke",  "ash" },             -- 4th letter: air owns dea
  { "ded",    "evoke",  "dust" },            -- imprint aura
  { "deea",   "evoke",  "earth" },           -- 4th letter: ether owns dee; web
  { "def",    "evoke",  "fire" },            -- fireball
  { "dei",    "evoke",  "ice" },             -- heal other
  { "del",    "evoke",  "lightning" },       -- lightning bolt
  { "deli",   "evoke",  "life" },            -- 4th letter: lightning owns del
  { "dem",    "evoke",  "magma" },           -- circle of fire
  { "demi",   "evoke",  "minerals" },        -- 4th letter: magma owns dem; cure serious
  { "der",    "evoke",  "radiance" },        -- reveal
  { "desa",   "evoke",  "salt" },            -- 4th letter: des is enhanced strength; cure poison
  { "desm",   "evoke",  "smoke" },           -- 4th letter: des is enhanced strength; blindness
  { "dest",   "evoke",  "steam" },           -- 4th letter: des is enhanced strength

  -- Direct invoke aliases
  { "diai",   "invoke", "air" },             -- 4th letter: dia is imprint aura; levitation
  { "dias",   "invoke", "ash" },             -- 4th letter: air owns dia
  { "did",    "invoke", "dust" },            -- combat blink
  { "diea",   "invoke", "earth" },           -- 4th letter: ether owns die; heal
  { "dif",    "invoke", "fire" },            -- sanctuary
  { "dii",    "invoke", "ice" },             -- shield
  { "dil",    "invoke", "lightning" },       -- haste
  { "dili",   "invoke", "life" },            -- 4th letter: lightning owns dil; cure blindness
  { "dim",    "invoke", "magma" },           -- fireshield
  { "dimi",   "invoke", "minerals" },        -- 4th letter: magma owns dim; enhanced strength
  { "dio",    "invoke", "ooze" },            -- stone skin
  { "dir",    "invoke", "radiance" },        -- refresh
  { "disa",   "invoke", "salt" },            -- 4th letter: smoke owns dis; cure disease
  { "dist",   "invoke", "steam" },           -- 4th letter: smoke owns dis; pass door
  { "div",    "invoke", "vacuum" },          -- blink
}

local function make_alias(name, verb, element)
  -- register the same optional-target pattern used previously
  rune.alias.regex("^" .. name .. "(?:[ ]+(.+))?$", function(m)
    if not enabled then
      dbg("ignored alias " .. name .. " (disabled)")
      return
    end
    local cmd = verb .. " " .. element
    local target = m and m[1]
    if target and target ~= "" then
      cmd = cmd .. " " .. target
    end
    dbg("sending: " .. cmd)
    rune.send(cmd)
  end)
end

for _, s in ipairs(spells) do
  make_alias(s[1], s[2], s[3])
end

local function help_summary()
  local status = "v" .. VERSION .. "  enabled=" .. tostring(enabled) .. " debug=" .. tostring(debug_enabled)
  if H and H.title and H.section and H.line and H.foot then
    rune.echo(H.title("Druid spell TLAs"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("druidSpellTLAs", "show this summary"))
    rune.echo(H.line("druidSpellTLAs on|off", "enable or disable all aliases"))
    rune.echo(H.line("druidSpellTLAs debug on|off", "toggle debug output"))
    rune.echo(H.foot(status))
    return
  end
  rune.echo("Druid spell TLAs")
  rune.echo("  druidSpellTLAs              show this summary")
  rune.echo("  druidSpellTLAs on|off       enable or disable all aliases")
  rune.echo("  druidSpellTLAs debug on|off toggle debug output")
  rune.echo(status)
end

rune.alias.exact("druidSpellTLAs", function(args)
  local text = tostring(args or ""):lower()
  local cmd = text:match("^(%S*)") or ""
  local rest = text:match("^%S+%s*(.*)$") or ""

  if cmd == "" or cmd == "help" then
    help_summary()
    return
  end

  if cmd == "on" then
    enabled = true; save_settings(); rune.echo("[druidSpellTLAs] enabled"); return
  end
  if cmd == "off" then
    enabled = false; save_settings(); rune.echo("[druidSpellTLAs] disabled"); return
  end
  if cmd == "debug" then
    if rest == "on" then debug_enabled = true
    elseif rest == "off" then debug_enabled = false
    else help_summary(); return end
    save_settings(); rune.echo("[druidSpellTLAs] debug is " .. tostring(debug_enabled)); return
  end

  help_summary()
end)

load_settings()
save_settings()