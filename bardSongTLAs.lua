-- Filename: eljayPlugins/bardSongTLAs.lua
-- Purpose: Bard Songs with Three Letter Acronyms
-- Version: 2.1 (converted from yBardSongs.xml; merged extra TLAs, checked against 'help music')
-- Date: 2026-Oct-09
--
-- How it works:
--  * play(tla, song) registers an exact alias that sends: play '<song>'
--  * Songs are grouped as in 'help music': Peace, Martial, Versatile

local function play(key, song)  rune.alias.exact(key, "play '" .. song .. "'") end

-- Peace Songs (only when not in combat)
play("bbm", "battle march")
play("bdi", "detect invisibility")
play("bfl", "footloose")
play("bes", "enhanced strength")
play("bep", "epiphany")
play("bih", "inspirational hymn")
play("ble", "levitation")
play("bli", "light")
play("bml", "mass levitation")
play("bsh", "shield")
play("bts", "traveling song")

-- Martial Songs (only in combat)
play("bbl", "blindness")
play("bcac", "cacophony")
play("bfi", "fireball")
play("bea", "earworm")
play("bhw", "hands of wind")
play("bha", "harmonize")
play("bsl", "hinder")
play("bpd", "pensive dirge")
play("bpf", "plodding fugue")
play("bsn", "soothing nocturne")
play("btro", "tremolo")
play("bom", "ode to the moon")
play("btrr", "tempus rigor")

-- Versatile Songs (any time)
play("bca", "calm")
play("bcl", "cure light")
play("bip", "invigorating performance")
play("bnf", "nights fortune")
play("bre", "refresh")
play("bri", "rime of the glacierbreaker")
play("bth", "thunderclap")
play("btr", "tremor")
