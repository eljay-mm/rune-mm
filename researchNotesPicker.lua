-- Filename: eljayPlugins/researchNotesPicker.lua
-- Purpose: Turns the output of `rrl` (research research list) into a searchable picker that stays open; selecting a thesis runs `rrr <number>`. Also owns the rrl and rrr aliases.
-- Version: 1.2
-- Date: 2026-Oct-10
--
-- How it works:
--   * A trigger watches for thesis rows in the rrl output, e.g.
--       "     1) A thesis pertaining to Armor      75    No limit     [        253 gold]"
--     and collects number, subject, level, amount and cost.
--   * rrl has no end-of-list marker, so a short debounce timer (0.4s after the last row)
--     decides the list is complete and opens the picker.
--   * Picking an entry (Enter/Tab) runs the same command sequence as the rrr alias
--     ("rem notes;read research buy <n>;bind thesis notes;hold notes"), then the picker
--     reopens so you can pick the next one. Esc closes it for good.
--   * Typing in the picker fuzzy-filters on subject name, number or cost.
--   * `rrpick` reopens the picker with the last list without asking the server again.
--   * Aliases (from basicAliases.lua): `rrl` = "read research list",
--     `rrr <n>` = the buy sequence above.
--   * Nothing is gagged: the normal rrl output still shows in the main window.

local DEBOUNCE = 0.4   -- seconds of silence after the last row before the picker opens

local items    = {}    -- collected rows for the current rrl run
local finished = true  -- true once the picker has opened for the current run

local open_picker

-- Shared by the rrr alias and the picker selection.
local function buy(num)
    rune.send("rem notes;read research buy " .. num .. ";bind thesis notes;hold notes")
end

open_picker = function()
    if #items == 0 then
        rune.echo("[researchNotesPrep] No theses captured yet - run rrl first.")
        return
    end
    rune.ui.picker.show({
        title = "Research (rrr) - Esc to close",
        items = items,
        match_description = true,
        on_select = function(value)
            buy(value)
            -- keep the picker up: reopen right after this one closes
            rune.timer.after(0.05, open_picker, { name = "researchNotesPrep-reopen" })
        end,
    })
end

rune.trigger.regex(
    "^\\s*(\\d+)\\)\\s+(?:A thesis pertaining to\\s+)?(.+?)\\s+(\\d+)\\s+(.+?)\\s+\\[\\s*([\\d,]+)\\s+gold\\s*\\]",
    function(m)
        if finished then            -- first row of a new rrl run: start a fresh list
            items = {}
            finished = false
        end
        local num, subject, level, amount, cost = m[1], m[2], m[3], m[4], m[5]
        items[#items + 1] = {
            text  = subject,
            desc  = string.format("#%s  %s gold  (lvl %s, %s)", num, cost, level, amount),
            value = num,
        }
        rune.timer.after(DEBOUNCE, function()
            finished = true
            open_picker()
        end, { name = "researchNotesPrep-open" })  -- same name replaces the pending timer = debounce
    end,
    { name = "researchNotesPrep-row" }
)

rune.alias.exact("rrpick", function() open_picker() end)
