# rune-mm

Eljay's collection of Lua plugins for the [Rune](https://runemud.com) MUD client
([mmcdole/rune on GitHub](https://github.com/mmcdole/rune)), extending horstgs' base
configuration for [Materia Magica](https://www.materiamagica.com) (MM).

Developed with Rune running in the [Ghostty](https://ghostty.org) terminal on Debian 13.
The plugins are written to work on Linux, macOS and Windows; see
[Windows notes](#windows-notes) for the few caveats.

## Requirements

- The Rune client (runemud.com).
- horstgs' Rune configuration for Materia Magica (provides `mapper.lua` and `helpstyle`,
  used by `spdxyCoordinates` and by the plugins' help screens).
- A terminal that supports OSC 52 (clipboard) and OSC 8 (hyperlinks). Ghostty does; open
  links with **Ctrl+Shift+click**. For clipboard copies, Ghostty needs
  `clipboard-write = allow` in its config.

## Installation: Linux / macOS

Your Rune config directory is `~/.config/rune`. Put the plugins in its `eljayPlugins`
subdirectory:

```sh
git clone https://github.com/eljay-mm/rune-mm.git ~/.config/rune/eljayPlugins
```

Then append this line to `~/.config/rune/init.lua`:

```lua
require("eljayPlugins/initEljay")
```

To update later: `cd ~/.config/rune/eljayPlugins && git pull`, then restart Rune.

## Installation: Windows (download ZIP)

1. Find your Rune config folder, the folder that already contains your `init.lua` from
   horstgs' configuration. Depending on how Rune was set up this is typically
   `%USERPROFILE%\.config\rune` or `%APPDATA%\rune`. (The client exposes the path to
   plugins as `rune.config_dir`.)
2. On the repository page, choose **Code > Download ZIP**, or open
   `https://github.com/eljay-mm/rune-mm/archive/refs/heads/main.zip`.
3. Extract the ZIP. It unpacks to a folder named `rune-mm-main`.
4. Create a folder named `eljayPlugins` inside your Rune config folder and move the
   `.lua` files from `rune-mm-main` into it. The files must sit directly in
   `eljayPlugins`, for example `...\rune\eljayPlugins\initEljay.lua`, not in a nested
   `rune-mm-main` folder.
5. Open `init.lua` in a text editor (Notepad is fine) and add this line at the end.
   Use forward slashes, even on Windows:

   ```lua
   require("eljayPlugins/initEljay")
   ```
6. Restart Rune.

To update, download a fresh ZIP and copy the new `.lua` files over the old ones.

## Disabling a plugin

`initEljay.lua` loads every plugin named in its `PLUGINS` list, in order. To disable a
plugin:

1. Open `eljayPlugins/initEljay.lua` in a text editor.
2. Put `--` at the start of that plugin's line in the `PLUGINS` list (or delete the line),
   for example:

   ```lua
   local PLUGINS = {
     "fauxSextant",
     -- "hangmanSolver",
     "highlights",
   }
   ```
3. Save the file and restart Rune (or reload your config).

To enable it again, remove the `--`. Things to know:

- Each plugin loads under `pcall`, so one that fails is skipped and the plugins after it
  still load. At start-up `initEljay` prints one row, `[initEljay] v2.3  loaded N/M
  plugins`, and only if something broke it adds a `failed to load <name>: <error>` row
  per failed plugin. You only need to disable a plugin yourself if you don't want it.
- A plugin only runs if it is listed in `PLUGINS`. A `.lua` file that is present but not
  listed (for example a newly added one) stays off until you add its name.
- The list is alphabetical. Only move a plugin lower if it depends on another one having
  loaded first.
- `researchNotesPicker` relies on the `rrl` and `rrr` aliases defined in `basicAliases`,
  so keep `basicAliases` enabled if you use it.
- Plugins that provide an on/off command (for example `hangmanSolver on|off`) can also be
  switched off for the current session without editing any file; see each plugin's
  header comment or help screen.
- If Rune stops at start-up with a timeout ("runaway loop"), a plugin is stuck in an
  endless loop, which `pcall` cannot catch. Set `DEBUG = true` at the top of
  `initEljay.lua`: it appends `loading <name>` and `ok <name>` lines to
  `rune-init-progress.log` in your temp folder (the load row then shows the full path),
  and the last `loading` line without an `ok` is the plugin that hangs. Set `DEBUG`
  back to `false` afterwards.

## Plugins

| Plugin | What it does |
| --- | --- |
| `annwnQuestSearch.lua` | Looks up the quest you are reading about on annwn.info, as a clipboard copy and clickable link. |
| `asciiMapPane.lua` | ASCII map pane for the current area. |
| `bardSongTLAs.lua` | Bard songs with three-letter acronyms. |
| `basicAliases.lua` | General-purpose aliases and triggers for all characters. |
| `characterLog.lua` | Per-character, per-day session logging, named from GMCP. |
| `clipCommandOutput.lua` | Copies the output of a command to the clipboard. |
| `crystalLocator.lua` | Locates crystals by sending a scroll's map block to the OOC crystal finder. |
| `druidSpellTLAs.lua` | Druid invoke and evoke spells with three-letter acronyms. |
| `eqdbResultsPicker.lua` | Turns equipment search results into a picker that runs `eqlookup`. |
| `fauxSextant.lua` | Sextant coordinate display built from GMCP data. |
| `hangmanSolver.lua` | Solves hangman puzzles using an online solver (needs `curl`). |
| `highlights.lua` | Item highlights for easy recognition. |
| `jmcSolver.lua` | Solves the Joint Magical Consortium mirror puzzle locally and lists every solution. |
| `mapperShortCutKeys.lua` | Keyboard shortcuts for the mapper. |
| `numPadBindings.lua` | Numpad movement, look and door keys. |
| `oocWikiSearch.lua` | Searches the Materia Magica OOC wiki. |
| `researchNotesPicker.lua` | Searchable picker over the research thesis list, built for repeat purchases, which handles your notes automatically. |
| `shopListPicker.lua` | Picker over shop lists (not thesis shops) that buys your selection. |
| `spdxyCoordinates.lua` | Walks to sextant coordinates and towns using the mapper. |
| `spellTLAs.lua` | General spell three-letter aliases, optionally targetable. |
| `vitalsChanges.lua` | Shows HP, SP and ST changes in the main window. |

Each plugin's header comment has its full "How it works" description, its commands and
its changelog. Typing a plugin's command on its own prints a help summary.

## Conventions

Every plugin follows the same house style:

- **Header:** `Filename`, `Purpose`, `Version`, `Date`, a short changelog, then a
  "How it works" section.
- **Help:** typing a plugin's command on its own prints a summary using `helpstyle`; the
  last row shows the plugin's version and current settings.
- **Toggles:** a debug toggle (off by default) and an on/off toggle for the plugin's
  triggers.
- **Settings:** saved with `rune.store`, not in separate config files.
- **Commands:** defined without a `/` prefix, so you type `clip`, not `/clip`.
- **Naming:** `eljayPlugins/<camelName>.lua`, no prefix.

Older plugins are being brought up to this standard as they are revised.

## Windows notes

- `hangmanSolver.lua` (v2.3) works on Windows: it uses `curl.exe`, which is included with
  current versions of Windows 10 and 11, and `cmd.exe` quoting.
- `characterLog.lua` (v2.4) works on Windows: it creates its log folder with `cmd.exe`'s
  `mkdir` (Linux and macOS use `mkdir -p` with a private umask). Two differences:
  - A config path containing `"` or `%` is refused with a message, because it cannot be
    quoted safely for `cmd.exe`.
  - Windows does not get the private-folder permissions Linux does; the logs inherit
    your user profile's permissions, and they hold chat, so keep them there.
- Logs keep ANSI colour codes by default (`charlog raw on`). Open them in a viewer that
  understands ANSI colours, or run `charlog raw off` for plain text. On Linux and macOS
  `less -R` works.
- `initEljay.lua` (v2.3) needs nothing special on Windows: its debug progress file goes
  to your `TEMP` folder automatically (`TMPDIR` on Linux and macOS, `/tmp` as a last
  resort), and its install line is the same as on Linux.
- Clipboard features (`clipCommandOutput` and the link and clipboard helpers) need a
  terminal with OSC 52 support.

## Notes

- `characterLog.lua` writes under `<config>/logs/`. If your Rune config directory is a git
  checkout, add `logs/` to `.gitignore` so session logs are never committed.
- If a plugin fails to load, look for the `[initEljay] failed to load <name>` row under
  the start-up summary, then fix the plugin or comment out its name in the `PLUGINS` list.

## Credits

- [Rune](https://runemud.com) by mmcdole.
- Base Materia Magica configuration, `mapper.lua` and `helpstyle` by horstgs.
- Many plugins began as conversions of MUSHclient XML plugins by Ruthgul, Elbereth, Ferdinand, or Oona.
