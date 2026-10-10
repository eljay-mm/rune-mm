-- Filename: eljayPlugins/druidSpellTLAs.lua
-- Purpose: Druid Spells with Three Letter Acronyms
-- Version: 2.4
-- Date: 2026-Oct-09
--
-- How it works:
--  * Each row in the table below defines one alias: { alias, verb, element }
--  * "<alias> <target>" sends "<verb> <element> <target>", e.g. "dfi orc" -> "evoke fire orc"
--  * "<alias>" with no target sends just "<verb> <element>"
--  * The trailing comment on each row is the analogue spell from "help druid analogues"
--  * Newer TLAs are built from the analogue name (dsh = shield, des = enhanced strength,
--    dre = refresh, dha = haste, dia = imprint aura)
--  * Direct aliases are d + i/e (invoke/evoke) + element initial, e.g. dii = druid invoke ice;
--    where the initial is already taken, a 4th letter (2nd letter of the element) differentiates,
--    e.g. diai = invoke air, dias = invoke ash, desa = evoke salt

local spells = {
  -- Magma
  { "dcf",    "evoke",  "magma" },           -- circle of fire
  { "dfs",    "invoke", "magma" },           -- fireshield

  -- Minerals / Ice / Salt
  { "dcs",    "evoke",  "minerals" },        -- cure serious
  { "des",    "invoke", "minerals" },        -- enhanced strength
  { "dho",    "evoke",  "ice" },             -- (no analogue; heals someone else; 'heal other')
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

  -- Direct aliases: evoke (de + initial)
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

  -- Direct aliases: invoke (di + initial)
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

for _, s in ipairs(spells) do
  local name, verb, element = s[1], s[2], s[3]
  rune.alias.regex("^" .. name .. "(?:[ ]+(.+))?$", function(m)
    local cmd = verb .. " " .. element
    local target = m[1]
    if target and target ~= "" then
      cmd = cmd .. " " .. target
    end
    rune.send(cmd)
  end)
end
