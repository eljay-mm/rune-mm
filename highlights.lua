-- Filename: eljayPlugins/highlights.lua
-- Purpose: Highlights configured items and mobs in game output for easy recognition based on static configuration for all characters.
-- Version: 2.9
-- Date: 2026-Oct-25
--[[
TODO:
- Consider moving phrase data into a compact, validated source format.
]]
-- Changelog:
--   2.9  Highlights phrases from multiple categories independently on one line.
--   2.8  Phrase-only colouring and footer trigger count recorded; help rows use SHORT; size pass.
--   2.2-2.7  Toggles, load time in footer, lazy lookups, annwnQuestSearch display, size pass.
--   2.0-2.1  Original release; repo-standard header.
-- How it works:
--   * One named trigger detects configured phrases in game output and colours matches by category.
--   * Phrase lookups are built on first use. Overlaps prefer the earliest, then longest match;
--     category order breaks ties.
--   * `highlights off` disables the trigger; enabled and debug states persist in rune.store.
--   * Debug (default off) reports matching categories. The help footer shows state,
--     trigger count and load time.
--
-- Commands:
--   hl              - show this command summary
--   hl on|off       - enable or disable the highlight trigger
--   hl debug on|off - enable or disable debug output
--   hl list         - list categories, colours and entry counts
--   highlights      - show this command summary
--
-- Tweaks:
--   * HIGHLIGHTS             category entries, colours and match priority

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME  = "highlights"
local SHORT = "hl"

local VERSION = "2.9"
local LOAD_MS = 0
local state = { enabled = true, debug = false }

local function paint(color, text)
  local fn = rune.style and rune.style[color]
  return fn and fn(text) or text
end

local function say(text)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. text)
end

local function load_flag(key, default)
  local ok, value = pcall(rune.store.get, NAME .. "." .. key)
  if ok and value ~= nil then
    return value == true or value == "true"
  end
  return default
end

local function save_flag(key, value)
  pcall(rune.store.set, NAME .. "." .. key, value)
end

state.enabled = load_flag("enabled", true)
state.debug = load_flag("debug", false)

-- Categories (list order breaks ties between identical matches).
local HIGHLIGHTS = {
  { name = "nodrop", color = "gray", pattern = [[(a bag full of valuable tokens|the Ring of Lord Agrippa|a piece of string|a tiny yo-yo|a ring of animosity|the Medallion of Alyria|an amulet of spell delivery|a black and white silk ruff|a fool's skullcap|the skull of Riga|a goofy grin|a pet hydra sock puppet|a spectral auraf|a jester's costume|a magical belt pouch|the Stone of Alyria|Vandemaar's Enchanted Letter Box|Vandemaar's Apothecary Bottle|Vandemaar's Regent Bag|a magica, musical fig-it machine|a bag of elements|Vandemaar's Trunk|a mahogany puzzle box|a Tanglewick war chest|an antique piggy bank|a classy trophy case|a canvas travel cot|Agrippa's Puzzle|a small bronze bell|a well-crafted violin|the Glove of Lady Undya)]] },
  { name = "high_value_gear", color = "green", pattern = [[(the crystal of power|a faceted garnet pendant|a beautiful amulet made of white marble|an Ithrix warning amulet|a baldric band|the commander's helm of Divusmors|the helm of Divusmors|the boots of Divusmors|a pair of golden-spurred boots|an ogre's stomping boots|a spooky pair of bloodstained boots|the scaly sleeves of a green dragon|a petrified moon oak scutum|Manaria crest|the belt of pain|a bracelet of the elements|a seashell bracelet|a fetish of a fox|heavy, protective obsidian wristguards|Redemption from the Darkness|a birch mu puch|a soulstuff axe from the spiritual plane|the sword of uncallings|a shortsword named 'Ardor'|a set of juggling knives|Divusmors' commanding axes|a long wooden spoon|the infamous lance of Bellar Bloodbane|a set of draconic cymbals|a bag of tricks|a small gold RENEWAL token|an alloy toy soldier|an iron toy shaman|a dull, inert pulsar|an ascendant miniature pulser|a moonstone cabochon|a tanzanite cabochon|a velocity token|a basilisk scale mortar|an onyx mortar and pestle|a decanter of endless water|a token from Grandmaster Glacius|A Class Remedy Token|A Race Remedy Token|a token of reimbursed respect|a greater token of multiclassing|a portable wooden hitching post|an animate sceptre of songs|A Tragaelian meteorite wand|a hand-carved viola|Divusmors' demonic blade|Divusmors' versatile armor|an armor- plated harmonica holder|shoulderplates of the Innocent|leggings of yeti's hide|a seashell belt|a paladin's crusading equipment|the Necromonicon|a trinket traded from the Glyph|the mask of a sorceror of infamy and ill repute|a black velvet cloak of the wizard|a tiled gladius|an ornamental scabbard of the Arien' dyth elite guard|the amulet of champions|a plasma ball|Jhepp's soul|an elemental list's sporran|a seven-fingered fist|the Band of Vandemaar|the pancing shoes of the heavenly host|a wizard's cloak|reinforced wristguards|a heart-shaped talisman|a heavy steel crusader's shield|a spare Duke insulator plate|a failed alchemist's recipe book|research notes|a palladium ring|the Divine Dirk of Quickness|an artificer's|the magnificent brassard of the battlemages|aegis of the stormseeker|a chronomancer's phasing barrier|webcrawling legs) ]] },
  { name = "utility_gear", color = "yellow", pattern = [[(a ceramic seashell necklace|mosaiced gloves|a platinum pocketwatch|a clever merfolk costume|the boots of the wizard of Focault|a large magnifying glass|a jasper gemstone|a capsulated bit of seaweed|a magical crystal orb|a belt of coursing water|an orb of negation|a personal log|an oilcloth travel cot|a cleverly-made lockpick|a crystal parrot|a wood and iron spade|an iron pick axe|the gaudy ring of an efreeti sandpriest|the jangling ring-belt of an efreeti sandpriest|the personal Atlas of Sir Adroit and Cunning|the emblem of hunter's|a bag bearing the insignia of the Council of Seven|an earthen bag) ]] },
  { name = "quest_items", color = "cyan", pattern = [[(a pair of malachite boots|a shield of storms|a syringe|a scalpel|the sword of truth|the boots of the fish|a pair of seven-league boots|a pair of Darkland boots|a pair of standard issue boots|the boots of valor|the whi of death|the yo-yo of darkness|the scythe of war|the spear of the dead|the mighty mace of hope|a bucaneer's longsword|a sword of frost|an oak stake|a book of erotic poetry|the egg of the phoenix|the claws of a dungeo rat|eye of newt|a clump of dried seaweed|an enchanted portable hole|a carnation|a beautiful silk scarf|a cloth hat of magic|headband of luck|a tail feather|a holy ring of Maradas|a vial of unblessed water|a saber|a tiny needle|a crystal heart pendant|a suit of fire|the Great Flameg|a staff of a Gath shaman|a rotten old tree branch|a sturdy white banded staff|a majesty staff|a scroll of 'momentary darkness'|a midnight pearl|a black potion|an obsidian gargoyle's shield|a black tourmaline|an ebony helm|a charred silver|a scroll of 'cure poison'|a cold black stone brick|a white sapphire|a scroll of 'poison'|an iron irgaiak|a standard issue shield|an ancient iron key|an iron halberd|a large golden key|a ruby bracelet|the Falchion of Power|a small ray of lights|a ring of decay|a scroll of 'fireball'|yellow potion|a dark green druid's robe|a beautiful white rose|a mangy black feather|a camelhair paintbrush|an artist's palette|a soldier's pike|a merchant's pike|a colored pike|a pirate pike|a peaked pike|a jaded pike|a bamboo fishing pole|a bag of bits o fish|the foul carcass of a fish|a sea shell|A sea shell is buried in the sand here.|the moon ring|a city guard signet ring|a ring of protection|a steel spear|a dark spear|an ice covered spear|a firebog spear|a stone spear|a blue steel spear|a sand spear|a scroll of 'bless'|a scroll of 'protection from evil'|white shield of the holy|the Avatar's glowing spear|the holy hammer|an Alyrian horn|a silver unicorn's horn|the crimson lance|the sword of judgements|a Sigil dagger|a vespuvian dagger|a green frog statue|the soul of Rast Strikecraw|a bracelet of eyes|an obsidian gargoyle's sword|a fey action figure|a Lord Vashir doll|the spear of justice|an Eldamarian Slayer|a crystal blade|a longsword|gardening shears|the Dragon Lord armor|a sandalwood zither|a scroll of 'charm'|metal harmonica|a small banjo|a wooden lute|a scroll of 'detect illusion'|the chief thief's dagger|a scroll of 'cure critical'|a scroll of 'cure disease'|a scroll of 'death grip'|an arcane spellbook|seashell castanets|a silver thorn|an obsidian staff|a fey blade|a school book|a sapphire figurine|an Atlantan sponge|a piece of fungus|the Sacred Shrub|a basilisk horn|triceratops horn|a silverthorn plant|a copper figurine of the king|a soul in a bottle|mask) ]] },
  { name = "wanted_items", color = "magenta", pattern = [[(Yourban's shriveled soul|an ithrix emergency signal|an Ithrix entrapment amulet|a diamond gemstone|a haunted moonstone|a manual of stamina enhancement|a manual of hit point enhancement|a manual of spell point enhancement|a manual of strength|a manual of knowledge|a manual of wisdom|a manual of vitality|a manual of luck|a manual of courage|a manual of sanity|a spiderbite bracelet|a pack of big heraldic cats|a piece of salamander heraldry|a piece of heraldry depicting a bloody dove holding drums tick|an unadorned heraldic crest|a field of heraldic catrops|a coat of arms|the filigree robe of Raymatus|a pair of deerskin moccasins|a blade named 'axiom'|the sceptre of Raymatus|the orb of Raymatus|a spun silver crown|a heraldic palladium caltrops|a heraldic adamantite caltrops|a heraldic mithril caltrops|of a heraldic salamander|block of a magic cube|a magic cube|a trick or treat sack|an abstract statue embodying|a piece of a map|a Duelling Licenses|a bracelet of the unified elements|a small carved lute|a silver harp|ceramic flute|a magical cube|a white robe) ]] },
  { name = "global_mark_mobs", color = "red", pattern = [[(Terra Ophellium|begins muttering an incantation|loses HASTE|loses HINDER|shrugs off his sluggishness|shrugs off her sluggishness|A flying demon|A demon charmer|A filthy cockroach|A flesh devouring maggot|A repulsive naga|A bonegnasher|A deadhead|A dark raven|A shiny black scaled demon|A soul eating demon|A hungry zombie|A giant huntsman|A fanged wolf|A demon warrior|A horrendous female beast|A vortex ghoul|A dark winged beast|An archmage|A soul eater|A dark ravener|A Deathmage|A discarded, torn piece of a map of Alyria lies here.|A raven, with a message in its talons, flies here.) ]] },
  { name = "mounts", color = "blue", pattern = [[(A young pegasus) ]] },
}

local patterns = {}
for i, entry in ipairs(HIGHLIGHTS) do
  patterns[i] = entry.pattern
end

local needles_ready = false

-- Build literal phrases once, on the first match or `list`.
local function build_needles()
  if needles_ready then return end

  for _, entry in ipairs(HIGHLIGHTS) do
    local suffix = entry.pattern:sub(-1) == " " and " " or ""
    local alternatives = entry.pattern:match("^%((.*)%)%s*$")
    entry.needles = {}

    if alternatives then
      for item in alternatives:gmatch("[^|]+") do
        entry.needles[#entry.needles + 1] = item .. suffix
      end
    end
  end

  needles_ready = true
end

-- Colour every configured phrase on the line; leave other text untouched.
local function highlight_matches(line)
  build_needles()

  local out, matched, pos = {}, {}, 1

  while pos <= #line do
    local best_start, best_end, best_entry

    for _, entry in ipairs(HIGHLIGHTS) do
      for _, needle in ipairs(entry.needles) do
        local first, last = line:find(needle, pos, true)
        if first and (not best_start
            or first < best_start
            or (first == best_start and last > best_end)) then
          best_start, best_end, best_entry = first, last, entry
        end
      end
    end

    if not best_start then
      out[#out + 1] = line:sub(pos)
      break
    end

    if best_start > pos then
      out[#out + 1] = line:sub(pos, best_start - 1)
    end

    out[#out + 1] = paint(best_entry.color, line:sub(best_start, best_end))
    matched[best_entry.name] = true
    pos = best_end + 1
  end

  return table.concat(out), matched
end

-- Named trigger: /reload replaces it instead of stacking.
local trigger = rune.trigger.regex(table.concat(patterns, "|"), function(_, ctx)
  local line = ctx.line:clean()
  local highlighted, matched = highlight_matches(line)

  if state.debug then
    for _, entry in ipairs(HIGHLIGHTS) do
      if matched[entry.name] then
        say("matched " .. entry.name)
      end
    end
  end

  return highlighted
end, { name = NAME, group = "highlight" })

if trigger and not state.enabled then
  trigger:disable()
end

local function set_enabled(on)
  state.enabled = on
  save_flag("enabled", on)

  if trigger then
    if on then
      trigger:enable()
    else
      trigger:disable()
    end
  end

  say(NAME .. " " .. (on and "on" or "off"))
end

local function status_text()
  return "v" .. VERSION
    .. "  enabled=" .. tostring(state.enabled)
    .. " debug=" .. tostring(state.debug)
    .. " triggers=1"
    .. "  load=" .. LOAD_MS .. "ms"
end

local function emit(value)
  for _, text in ipairs(type(value) == "table" and value or { value }) do
    rune.echo(text)
  end
end

local function show_help()
  local ok = pcall(function()
    local H = require("helpstyle")
    emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))
    emit(H.line(NAME, "show this help"))
    emit(H.line(SHORT .. " on|off", "enable or disable the highlight trigger"))
    emit(H.line(SHORT .. " debug on|off", "enable or disable debug output"))
    emit(H.line(SHORT .. " list", "list categories, colours and entry counts"))
    emit(H.line(SHORT, "short alias for " .. NAME))
    emit(H.foot(status_text()))
  end)

  if not ok then
    say(status_text())
  end
end

local function show_list()
  build_needles()

  for _, entry in ipairs(HIGHLIGHTS) do
    rune.echo(paint(entry.color, string.format(
      "  %-18s %-8s %d entries",
      entry.name, entry.color, #entry.needles
    )))
  end
end

local function handle_command(args)
  local a, b = tostring(args or ""):lower():match("^%s*(%S*)%s*(%S*)")

  if a == "on" or a == "off" then
    set_enabled(a == "on")
  elseif a == "debug" and (b == "on" or b == "off") then
    state.debug = b == "on"
    save_flag("debug", state.debug)
    say("debug " .. b)
  elseif a == "list" then
    show_list()
  else
    show_help()
  end
end

local function run(args)
  local ok, err = pcall(handle_command, args)
  if not ok then
    say("error: " .. tostring(err))
  end
end

-- Bare exact aliases (no / prefix); args are the text after the command.
for _, cmd in ipairs({ NAME, SHORT }) do
  local ok, err = pcall(rune.alias.exact, cmd, function(args, ctx)
    run(args)
  end)

  if not ok then
    say("alias '" .. cmd .. "' failed: " .. tostring(err))
  end
end

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")
