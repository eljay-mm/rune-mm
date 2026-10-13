-- Filename: eljayPlugins/researchNotesPicker.lua
-- Purpose: Turns the output of `rrl` (read research list) into a searchable picker that stays open for repeat purchases, handling the notes around the session (rem notes on open, hold notes on close).
-- Version: 1.8
-- Date: 2026-Oct-13
-- Changelog:
--   1.8  Repo-style header update and command summary cleanup; functionality preserved.
--   1.7  Original implementation.
--
-- How it works:
--   * A trigger watches for thesis rows in the rrl output, e.g.
--       "     1) A thesis pertaining to Armor      75    No limit     [        253 gold]"
--     and collects number, subject, level, amount and cost. The row must contain
--     "A thesis pertaining to", so ordinary shop lists never open the picker.
--   * rrl has no end-of-list marker, so a short debounce timer (0.4s after the last row)
--     decides the list is complete and opens the picker.
--   * When the picker opens, "rem notes" is sent (inventory must be free of held notes).
--   * Each selection (Enter/Tab) sends "read research buy <n>;bind thesis notes" while the
--     notes are still in inventory, then the picker reopens for the next purchase
--     (no extra "rem notes" on reopen).
--   * Esc cannot be trapped: Rune's modal picker handles all keys itself (no Lua binds run)
--     and has no cancel callback. Instead, while a session is active, an input hook sends
--     "hold notes" just before the next line you type or send (the picker is necessarily
--     closed by then). So after Esc your notes come back with your very next command, with
--     no purchase required. `rrdone` sends "hold notes" immediately by hand.
--   * Typing in the picker fuzzy-filters on subject name, number or cost.
--   * `rrpick` reopens the picker with the last list without asking the server again.
--   * The rrl and rrr aliases are NOT defined here; they come from an external definition.
--   * Nothing is gagged: the normal rrl output still shows in the main window.
--
-- Commands:
--   rrpick            reopen the last research picker
--   rrdone            put the notes back immediately

local DEBOUNCE = 0.4   -- seconds of silence after the last row before the picker opens

local items    = {}    -- collected rows for the current rrl run
local finished = true  -- true once the picker has opened for the current run
local active   = false -- true while a picker session is in progress (notes removed)
local reopening = false -- true during the short gap between a selection and the picker reopening

local open_picker

-- Single purchase: buy, then bind the thesis to the notes (notes must be in inventory).
local function buy(num)
  rune.send("read research buy " .. num .. ";bind thesis notes")
end

-- Session end: pick the notes back up.
local function finish()
  if not active then return end
  active = false
  rune.send("hold notes")
end

-- fresh = true for a new session (sends "rem notes"); false when reopening after a buy.
open_picker = function(fresh)
  if #items == 0 then
    rune.echo("[researchNotesPicker] No theses captured yet - run rrl first.")
    return
  end
  reopening = false
  if fresh then
    active = true
    rune.send("rem notes")
  end
  local selected = false
  local ok, err = pcall(rune.ui.picker.show, {
    title = "Research (read research buy) - Esc to finish",
    items = items,
    match_description = true,
    on_select = function(value)
      selected = true
      reopening = true
      buy(value)
      -- keep the picker up: reopen right after this one closes
      rune.timer.after(0.05, function() open_picker(false) end,
        { name = "researchNotesPicker-reopen" })
    end,
    on_cancel = function()
      if not selected then finish() end
    end,
  })
  if not ok then
    rune.echo("[researchNotesPicker] Picker failed: " .. tostring(err))
    finish()
  end
end

-- "A thesis pertaining to" is mandatory so regular shop listings are ignored.
rune.trigger.regex(
  "^\\s*(\\d+)\\)\\s+A thesis pertaining to\\s+(.+?)\\s+(\\d+)\\s+(.+?)\\s+\\[\\s*([\\d,]+)\\s+gold\\s*\\]",
  function(m)
    if finished then
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
      open_picker(true)
    end, { name = "researchNotesPicker-open" })
  end,
  { name = "researchNotesPicker-row" }
)

-- Esc safety net: input can only be submitted once the picker is closed, so if a session
-- is still marked active here, the picker was cancelled. Re-equip the notes first.
rune.hooks.on("input", function(text)
  if active and not reopening then finish() end
  return nil
end, { name = "researchNotesPicker-esc", priority = 10 })

rune.alias.exact("rrpick", function() open_picker(true) end)
rune.alias.exact("rrdone", function() finish() end)