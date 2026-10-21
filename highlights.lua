-- Filename: eljayPlugins/highlights.lua
-- Purpose: Highlights notable items and mobs in game output for easy recognition based on static configuration for all characters.
-- Version: 2.6
-- Date: 2026-Oct-19
--[[
Todo:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.6  Help footer now reports load time (enabled/debug/load). Faster load: the per-item lookup tables
--        are built on the first match (or `highlights list`) instead of at startup. Behaviour unchanged.
--   2.5  Display aligned with annwnQuestSearch: paint/say helpers, help rows through emit(),
--        bare commands as exact aliases taking (args, ctx). Highlight behaviour is unchanged.
--   2.4  Fixed help not showing (helpstyle text is now echoed). Commands are single exact aliases.
--        `highlights off` now disables the trigger itself, so no regex runs while off.
--   2.3  One combined trigger instead of seven; category looked up only on matching lines.
--   2.2  Added on/off and debug toggles (persisted in rune.store), bare command help, loader line.
--        Removed duplicate entries inside categories.
--   2.1  House-style pass: added repo-standard header and grouped categories.
--   2.0  Original release.
-- How it works:
--   * All category lists are joined into a single named regex trigger, so each line is scanned once.
--   * Only when a line matches is the category found (first in list order wins) with plain-text lookups.
--   * Those lookup tables are built lazily on the first match, which keeps load time low.
--   * The matching line is re-emitted in the category colour using rune.style.<color>().
--   * If a colour is unavailable the line is passed through unstyled.
--   * Turning highlights off disables the trigger handle, so there is no per-line cost while off.
--   * Debug (default off) echoes the category that matched each line.
--   * Output uses paint/say helpers, and help rows from helpstyle go through emit() (rune.echo).
--   * on/off and debug are saved with rune.store and restored on load.
--   * The help footer shows version, enabled, debug and load time in milliseconds.
--
-- Commands:
--   highlights              - show this command summary
--   highlights on|off       - turn the highlight trigger on or off
--   highlights debug on|off - toggle debug output (default off)
--   highlights list         - list categories, colours and entry counts
--   hl                      - short alias for highlights

local clock   = os.clock or function() return 0 end
local T0      = clock()

local NAME    = "highlights"
local VERSION = "2.6"
local load_ms = 0

local state = { enabled = true, debug = false }

-- Output helpers ------------------------------------------------------------

local function paint(color, text)
  local fn = rune.style and rune.style[color]
  return fn and fn(text) or text
end

local function say(text)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. text)
end

-- Settings (rune.store, guarded so a missing store never breaks loading) -------

local function load_flag(key, default)
  local ok, value = pcall(function() return rune.store.get(NAME .. "." .. key) end)
  if ok and value ~= nil then return value == true or value == "true" end
  return default
end

local function save_flag(key, value)
  pcall(function() rune.store.set(NAME .. "." .. key, value) end)
end

state.enabled = load_flag("enabled", true)
state.debug   = load_flag("debug", false)

-- Highlight categories (list order = priority when a line matches several) ------

local HIGHLIGHTS = {
  {
    name = "nodrop",
    color = "gray",
    pattern = [[(a bag full of valuable tokens|the Ring of Lord Agrippa|a piece of string|a tiny yo-yo|a ring of animosity|the Medallion of Alyria|an amulet of spell delivery|a black and white silk ruff|a fool's skullcap|the skull of Riga|a goofy grin|a pet hydra sock puppet|a spectral auraf|a jester's costume|a magical belt pouch|the Stone of Alyria|Vandemaar's Enchanted Letter Box|Vandemaar's Apothecary Bottle|Vandemaar's Regent Bag|a magica, musical fig-it machine|a bag of elements|Vandemaar's Trunk|a mahogany puzzle box|a Tanglewick war chest|an antique piggy bank|a classy trophy case|a canvas travel cot|Agrippa's Puzzle|a small bronze bell|a well-crafted violin|the Glove of Lady Undya)]],
  },
  {
    name = "high_value_gear",
    color = "green",
    pattern = [[(a wing feather of a magnificent couatl|a ring of hope|a silver band of Garan's|a giant serpent's skull|the unwavering belief of heresy|the crystal of power|a faceted garnet pendant|a beautiful amulet made of white marble|an Ithrix warning amulet|a baldric band|an oxxy dragonfly pendant|the commander's helm of Divusmors|the helm of Divusmors|the boots of Divusmors|a pair of golden-spurred boots|an ogre's stomping boots|the sabots of Sir Adroit and Cunning|a spooky pair of bloodstained boots|the cape of terror|the beasmaster's pelt|a cosmic cloak|the scaly sleeves of a green dragon|a petrified moon oak scutum|Manaria crest|the belt of pain|Kezathin's toolbelt|a bracelet of the elements|a seashell bracelet|a fetish of a fox|heavy, protective obsidian wristguards|a Bracelet of Life Sustaining|Redemption from the Darkness|a heavy steel crossbow cover in zombie guts|a birch mu puch|a soulstuff axe from the spiritual plane|the sword of uncallings|a shortsword named 'Ardor'|a set of juggling knives|Divusmors' commanding axes|a long wooden spoon|the infamous lance of Bellar Bloodbane|a set of draconic cymbals|a bag of tricks|a small gold RENEWAL token|an alloy toy soldier|an iron toy shaman|a dull, inert pulsar|an ascendant miniature pulser|a moonstone cabochon|a tanzanite cabochon|a velocity token|a basilisk scale mortar|an onyx mortar and pestle|a decanter of endless water|a token from Grandmaster Glacius|A Class Remedy Token|A Race Remedy Token|a token of reimbursed respect|a greater token of multiclassing|a portable wooden hitching post|an animate sceptre of songs|A Tragaelian meteorite wand|a hand-carved viola|Divusmors' demonic blade|Divusmors' versatile armor|an armor- plated harmonica holder|shoulderplates of the Innocent|leggings of yeti's hide|a seashell belt|a paladin's crusading equipment|the Necromonicon|a trinket traded from the Glyph|the mask of a sorceror of infamy and ill repute|a black velvet cloak of the wizard|a tiled gladius|an ornamental scabbard of the Arien' dyth elite guard|the amulet of champions|a plasma ball|Jhepp's soul|an elemental list's sporran|a seven-fingered fist|the Band of Vandemaar|the pancing shoes of the heavenly host|a wizard's cloak|reinforced wristguards|a heart-shaped talisman|a heavy steel crusader's shield|a spare Duke insulator plate|a failed alchemist's recipe book|research notes|a palladium ring|the Divine Dirk of Quickness|an artifice's|the magnificent brassard of the battlemages|aegis of the stormseeker|a chronomancer's phasing barrier|webcrawling legs) ]],
  },
  {
    name = "utility_gear",
    color = "yellow",
    pattern = [[(an eye of a Kraken|a sand-colored ring|a ceramic seashell necklace|the shield of war|a Darkland belt|mosaiced gloves|an indestructible mithril spade|a platinum pocketwatch|a clever merfolk costume|the boots of the wizard of Focalt|an alligator tooth necklace|a janitor's patch|a large magnifying glass|a jasper gemstone|a capsulated bit of seaweed|a magical crystal orb|a belt of coursing water|an orb of negation|a personal log|an oilcloth travel cot|a cleverly-made lockpick|a crystal parrot|a wood and iron spade|an iron pick axe|the gaudy ring of an efreeti sandpriest|the jangling ring-belt of an efreeti sandpriest|the personal Atlas of Sir Adroit and Cunning|the emblem of hunter's|a bag bearing the insignia of the Council of Seven|a pair of yeti hide leggings|the ring of the serpent|an earthen bag|a black velvet cloak of the wizard|a pally of your item) ]],
  },
  {
    name = "quest_items",
    color = "white",
    pattern = [[(a pair of malachite boots|a shield of storms|a syringe|a scalpel|the sword of truth|the boots of the fish|a pair of seven-league boots|a pair of Darkland boots|a pair of standard issue boots|the boots of valor|the whi of death|the yo-yo of darkness|the scythe of war|the spear of the dead|the mighty mace of hope|a bucaneer's longsword|a sword of frost|an oak stake|a book of erotic poetry|the egg of the phoenix|the claws of a dungeo rat|eye of newt|a clump of dried seaweed|an enchanted portable hole|a carnation|a beautiful silk scarf|a cloth hat of magic|headband of luck|a tail feather|a holy ring of Maradas|a vial of unblessed water|a saber|a tiny needle|a crystal heart pendant|a suit of fire|the Great Flameg|a staff of a Gath shaman|a rotten old tree branch|a sturdy white banded staff|a majesty staff|a scroll of 'momentary darkness'|a midnight pearl|a black potion|an obsidian gargoyle's shield|a black tourmaline|an ebony helm|a charred silver|a scroll of 'cure poison'|a cold black stone brick|a white sapphire|a scroll of 'poison'|an iron irgaiak|a standard issue shield|an ancient iron key|an iron halberd|a large golden key|a ruby bracelet|the Falchion of Power|a small ray of lights|a ring of decay|a scroll of 'fireball'|yellow potion|a dark green druid's robe|a beautiful white rose|a mangy black feather|a camelhair paintbrush|an artist's palette|a soldier's pike|a merchant's pike|a colored pike|a pirate pike|a peaked pike|a jaded pike|a bamboo fishing pole|a bag of bits o fish|the foul carcass of a fish|a sea shell|A sea shell is buried in the sand here.|the moon ring|a city guard signet ring|a ring of protection|a steel spear|a dark spear|an ice covered spear|a firebog spear|a stone spear|a blue steel spear|a sand spear|a scroll of 'bless'|a scroll of 'protection from evil'|white shield of the holy|the Avatar's glowing spear|the holy hammer|an Alyrian horn|a silver unicorn's horn|the crimson lance|the sword of judgements|a Sigil dagger|a vespuvian dagger|a green frog statue|the soul of Rast Strikecraw|a bracelet of eyes|an obsidian gargoyle's sword|a fey action figure|a Lord Vashir doll|the spear of justice|an Eldamarian Slayer|a crystal blade|a longsword|gardening shears|the Dragon Lord armor|a sandalwood zither|a scroll of 'charm'|metal harmonica|a small banjo|a wooden lute|a scroll of 'detect illusion'|the chief thief's dagger|a scroll of 'cure critical'|a scroll of 'cure disease'|a scroll of 'death grip'|an arcane spellbook|seashell castanets|a silver thorn|an obsidian staff|a fey blade|a school book|a sapphire figurine|an Atlantan sponge|a piece of fungus|the Sacred Shrub|a basilisk horn|triceratops horn|a silverthorn plant|a copper figurine of the king|a soul in a bottle|mask) ]],
  },
  {
    name = "wanted_items",
    color = "magenta",
    pattern = [[(Yourban's shriveled soul|the crystal of power|a sparkling crystal egg|an ithrix emergency signal|an Ithrix entrapment amulet|the Will of the Sea Elves|a diamond gemstone|a haunted moonstone|an antique flip sparrey|a manual of stamina enhancement|a manual of hit point enhancement|a manual of spell point enhancement|a manual of strength|a manual of knowledge|a manual of wisdom|a manual of vitality|a manual of luck|a manual of courage|a manual of sanity|a crystal necklace|a spiderbite bracelet|a pack of big heraldic cats|a piece of salamander heraldry|a piece of heraldry depicting a bloody dove holding drums tick|an unadorned heraldic crest|a field of heraldic catrops|a coat of arms|the filigree robe of Raymatus|a pair of deerskin moccasins|a blade named 'axiom'|the sceptre of Raymatus|the orb of Raymatus|a spun silver crown|a heraldic palladium caltrops|a heraldic adamantite caltrops|a heraldic mithril caltrops|of a heraldic salamander|block of a magic cube|a magic cube|a trick or treat sack|an abstract statue embodying|a piece of a map|a Duelling Licenses|a bracelet of the unified elements|a ring of spell turning|a bracelet of the elements|a small carved lute|a silver harp|ceramic flute|a magical cube|a white robe) ]],
  },
  {
    name = "global_mark_mobs",
    color = "red",
    pattern = [[(Terra|Ophellium|reindeer|evergreen|begins muttering an incantation|loses HASTE|loses HINDER|shrugs off his sluggishness|shrugs off her sluggishness|A flying demon|A demon charmer|A filthy cockroach|A flesh devouring maggot|A repulsive naga|A bonegnasher|A deadhead|A dark raven|A shiny black scaled demon|A soul eating demon|A hungry zombie|A giant huntsman|A fanged wolf|A demon warrior|A horrendous female beast|A vortex ghoul|A dark winged beast|An archmage|A soul eater|A dark ravener|A Deathmage|Sugarbotto|Fatnosed|Pixie|Shadow demon|tortured poltergeist|Scaly snake|You’re flying backwards through the air before you realize her other foot has kicked you in the face!|A discarded, torn piece of a map of Alyria lies here.|A raven, with a message in its talons, flies here.) ]],
  },
  {
    name = "mounts",
    color = "blue",
    pattern = [[(A young pegasus) ]],
  },
}

-- Join the category patterns for the single trigger; needle tables are built lazily ------------

local patterns = {}
for i, entry in ipairs(HIGHLIGHTS) do patterns[i] = entry.pattern end

local COMBINED = table.concat(patterns, "|")

local needles_ready = false

-- Needles keep each pattern's trailing-space rule; built on the first match or `highlights list`
local function build_needles()
  if needles_ready then return end
  for _, entry in ipairs(HIGHLIGHTS) do
    local body = entry.pattern:match("^%((.*)%)%s*$")
    local suffix = entry.pattern:sub(-1) == " " and " " or ""
    entry.needles = {}
    for item in body:gmatch("[^|]+") do entry.needles[#entry.needles + 1] = item .. suffix end
  end
  needles_ready = true
end

-- Category lookup runs only on lines the combined trigger already matched ------------------

local function classify(line)
  build_needles()
  for _, entry in ipairs(HIGHLIGHTS) do
    for _, needle in ipairs(entry.needles) do
      if line:find(needle, 1, true) then return entry end
    end
  end
end

-- Named trigger: /reload replaces it instead of stacking, and the handle gives a real disable ----

local trigger = rune.trigger.regex(COMBINED, function(_, ctx)
  local line = ctx.line:clean()
  local entry = classify(line)
  if not entry then return end
  if state.debug then say("matched " .. entry.name) end
  entry.paint = entry.paint or (rune.style and rune.style[entry.color])
  return entry.paint and entry.paint(line) or line
end, { name = NAME, group = "highlight" })

if trigger and not state.enabled then trigger:disable() end

local function set_enabled(on)
  state.enabled = on
  save_flag("enabled", on)
  if trigger then
    if on then trigger:enable() else trigger:disable() end
  end
  say("highlights " .. (on and "on" or "off"))
end

-- Help -------------------------------------------------------------------------

local function status_text()
  return "v" .. VERSION .. "  enabled=" .. tostring(state.enabled) .. " debug=" .. tostring(state.debug) .. " load=" .. load_ms .. "ms"
end

-- emit: helpstyle rows are returned as text, so echo whatever comes back (string or array of strings)
local function emit(value)
  if type(value) == "string" then
    rune.echo(value)
  elseif type(value) == "table" then
    for _, text in ipairs(value) do
      if type(text) == "string" then rune.echo(text) end
    end
  end
end

local function plain_help()
  say(status_text())
  say("commands: highlights [on|off|debug on|off|list]  (hl = short alias)")
end

local function show_help()
  local ok = pcall(function()
    local H = require("helpstyle")
    emit(H.title(NAME))
    emit(H.section("Commands"))
    emit(H.line("highlights              show this command summary"))
    emit(H.line("highlights on|off       turn the highlight trigger on or off"))
    emit(H.line("highlights debug on|off toggle debug output (default off)"))
    emit(H.line("highlights list         list categories, colours and entry counts"))
    emit(H.line("hl                      short alias for highlights"))
    emit(H.foot(status_text()))
  end)
  if not ok then plain_help() end
end

local function show_list()
  build_needles()
  for _, entry in ipairs(HIGHLIGHTS) do
    rune.echo(paint(entry.color, string.format("  %-18s %-8s %d entries", entry.name, entry.color, #entry.needles)))
  end
end

-- Commands (bare exact aliases, no / prefix; args = everything typed after the word) -------

local function set_debug(arg)
  if arg ~= "on" and arg ~= "off" then return false end
  state.debug = (arg == "on")
  save_flag("debug", state.debug)
  say("debug " .. arg)
  return true
end

local function handle_command(args)
  local words = {}
  for word in tostring(args or ""):gmatch("%S+") do words[#words + 1] = word:lower() end
  local a, b = words[1], words[2]

  if a == "on" or a == "off" then
    set_enabled(a == "on")
  elseif a == "debug" and set_debug(b) then
    return
  elseif a == "list" then
    show_list()
  else
    show_help()
  end
end

local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then say("error: " .. tostring(err)) end
  end
end

for _, cmd in ipairs({ "highlights", "hl" }) do
  local ok, err = pcall(rune.alias.exact, cmd, guarded(function(args, ctx) handle_command(args) end))
  if not ok then say("alias '" .. cmd .. "' failed: " .. tostring(err)) end
end

load_ms = math.floor((clock() - T0) * 1000 + 0.5)

say("v" .. VERSION .. " loaded (highlights or hl for help)")