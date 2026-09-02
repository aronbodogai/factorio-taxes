-- The player-facing tax status panel: a frame in the top-left corner showing
-- the current phase, a countdown, the cycle number, and one row per demanded
-- item or fluid. Every function here tolerates being called with a missing
-- player, a missing frame, or a missing storage.taxes, and never throws, so
-- it is always safe to poke by hand from a console command while testing.

local util = require("scripts.util")

local gui = {}

local PANEL_NAME = "taxes-panel"
local DEMAND_FLOW_NAME = "taxes-demand-flow"
local EMPTY_ROW_NAME = "taxes-demand-empty"

-- Maps a phase name to the localised string shown for it. Kept as a lookup
-- table so an unrecognised phase (a stale save, a typo from a debug command)
-- falls back to a generic label instead of throwing.
local PHASE_CAPTIONS = {
  cooldown  = { "taxes.phase-cooldown" },
  announced = { "taxes.phase-announced" },
  inbound   = { "taxes.phase-inbound" },
  loading   = { "taxes.phase-loading" },
  departing = { "taxes.phase-departing" },
}

--- The localised label for a phase, or a generic fallback for anything this
--- module does not recognise.
local function phase_caption(phase)
  return PHASE_CAPTIONS[phase] or { "taxes.phase-unknown" }
end

--- The sprite path for a demand entry, following the item/fluid split from
--- docs/DESIGN.md section 8. Returns nil for a malformed entry with no name,
--- so a bad entry can never crash the panel over a string concatenation.
local function sprite_path(entry)
  if not entry.name then return nil end
  if entry.kind == "fluid" then
    return "fluid/" .. entry.name
  end
  return "item/" .. entry.name
end

--- The localised prototype name shown as the icon's tooltip, or nil (meaning
--- no tooltip) for a malformed entry with no name.
local function name_tooltip(entry)
  if not entry.name then return nil end
  if entry.kind == "fluid" then
    return { "fluid-name." .. entry.name }
  end
  return { "item-name." .. entry.name }
end

--- Deterministic, collision-free element name for one demand row. Doubles as
--- the row's identity when refresh() decides whether the demand shape changed.
local function row_name(entry)
  return "taxes-row__" .. tostring(entry.kind) .. "__" .. tostring(entry.name)
end

--- The row names the demand flow should contain right now, in order.
local function expected_row_names(demand)
  local names = {}
  for _, entry in pairs(demand) do
    names[#names + 1] = row_name(entry)
  end
  return names
end

--- Fraction of a demand entry that is filled in, clamped to [0, 1] so a
--- momentary over-delivery never overflows the progress bar.
local function fraction_filled(entry)
  local count = entry.count or 0
  if count <= 0 then return 0 end
  return math.min((entry.delivered or 0) / count, 1)
end

--- Build one demand row: icon, "delivered / count" label, and a progress bar.
--- A sprite path is only assigned once helpers confirms it resolves to a
--- loaded sprite, because handing an invalid path to a sprite element throws.
local function add_demand_row(parent, entry)
  local row = parent.add({ type = "flow", name = row_name(entry), direction = "horizontal" })
  row.style.vertical_align = "center"

  local icon_params = { type = "sprite", name = "icon", tooltip = name_tooltip(entry) }
  local path = sprite_path(entry)
  if path and helpers.is_valid_sprite_path(path) then
    icon_params.sprite = path
  end
  row.add(icon_params)

  row.add({
    type = "label",
    name = "amount",
    caption = { "taxes.demand-progress", entry.delivered or 0, entry.count or 0 },
  })

  local bar = row.add({ type = "progressbar", name = "bar", value = fraction_filled(entry) })
  bar.style.width = 120
end

--- Create or fully rebuild the tax panel for one player. Always starts from a
--- clean frame, so it never has to assume anything about GUI state left over
--- from a previous version of this module or a previous save.
function gui.build(player)
  if not (player and player.valid) then return end

  local left = player.gui.left
  local existing = left[PANEL_NAME]
  if existing and existing.valid then existing.destroy() end

  local frame = left.add({
    type = "frame",
    name = PANEL_NAME,
    direction = "vertical",
    caption = { "taxes.panel-title" },
  })

  local taxes = storage.taxes
  if not taxes then
    -- Nothing to show yet, most likely called before on_init has run. Render
    -- a placeholder rather than nothing, so the panel is visibly alive.
    frame.add({ type = "label", name = "taxes-loading-label", caption = { "taxes.loading" } })
    return
  end

  frame.add({
    type = "label",
    name = "taxes-phase-label",
    caption = { "taxes.phase-line", phase_caption(taxes.phase) },
  })

  local remaining = (taxes.phase_end_tick or 0) - (game and game.tick or 0)
  frame.add({
    type = "label",
    name = "taxes-countdown-label",
    caption = { "taxes.countdown-line", util.format_ticks(remaining) },
  })

  frame.add({
    type = "label",
    name = "taxes-cycle-label",
    caption = { "taxes.cycle-line", taxes.cycle or 0 },
  })

  frame.add({ type = "line", name = "taxes-separator", direction = "horizontal" })

  local demand_flow = frame.add({ type = "flow", name = DEMAND_FLOW_NAME, direction = "vertical" })
  local demand = taxes.demand or {}
  if #demand == 0 then
    demand_flow.add({ type = "label", name = EMPTY_ROW_NAME, caption = { "taxes.no-demand" } })
  else
    for _, entry in pairs(demand) do
      add_demand_row(demand_flow, entry)
    end
  end
end

--- Rebuild the panel for every connected player. Safe to call with no players
--- connected, and safe to call before storage.taxes exists.
function gui.build_all()
  if not game then return end
  for _, player in pairs(game.connected_players) do
    gui.build(player)
  end
end

--- Update the live values on an already-built panel without recreating any
--- elements. Falls back to a full rebuild whenever the frame is missing, was
--- built by an older version of this module, or the demand shape (row count
--- or which items/fluids are demanded) no longer matches what is on screen -
--- captions and progress bars alone cannot express a changed row set.
function gui.refresh(player)
  if not (player and player.valid) then return end

  local frame = player.gui.left[PANEL_NAME]
  if not (frame and frame.valid) then
    gui.build(player)
    return
  end

  local taxes = storage.taxes
  if not taxes then
    gui.build(player)
    return
  end

  local phase_label = frame["taxes-phase-label"]
  local countdown_label = frame["taxes-countdown-label"]
  local cycle_label = frame["taxes-cycle-label"]
  local demand_flow = frame[DEMAND_FLOW_NAME]
  if not (phase_label and phase_label.valid
      and countdown_label and countdown_label.valid
      and cycle_label and cycle_label.valid
      and demand_flow and demand_flow.valid) then
    gui.build(player)
    return
  end

  local demand = taxes.demand or {}
  local have = demand_flow.children
  local shape_matches
  if #demand == 0 then
    shape_matches = (#have == 1 and have[1].valid and have[1].name == EMPTY_ROW_NAME)
  else
    local want = expected_row_names(demand)
    shape_matches = (#have == #want)
    if shape_matches then
      for i = 1, #want do
        if not (have[i] and have[i].valid and have[i].name == want[i]) then
          shape_matches = false
          break
        end
      end
    end
  end

  if not shape_matches then
    gui.build(player)
    return
  end

  phase_label.caption = { "taxes.phase-line", phase_caption(taxes.phase) }
  local remaining = (taxes.phase_end_tick or 0) - (game and game.tick or 0)
  countdown_label.caption = { "taxes.countdown-line", util.format_ticks(remaining) }
  cycle_label.caption = { "taxes.cycle-line", taxes.cycle or 0 }

  for _, entry in pairs(demand) do
    local row = demand_flow[row_name(entry)]
    if row and row.valid then
      local amount = row["amount"]
      local bar = row["bar"]
      if amount and amount.valid then
        amount.caption = { "taxes.demand-progress", entry.delivered or 0, entry.count or 0 }
      end
      if bar and bar.valid then
        bar.value = fraction_filled(entry)
      end
    end
  end
end

--- Cheap per-tick refresh for every connected player.
function gui.refresh_all()
  if not game then return end
  for _, player in pairs(game.connected_players) do
    gui.refresh(player)
  end
end

--- Remove the panel for one player, if it exists.
function gui.destroy(player)
  if not (player and player.valid) then return end
  local frame = player.gui.left[PANEL_NAME]
  if frame and frame.valid then frame.destroy() end
end

return gui
