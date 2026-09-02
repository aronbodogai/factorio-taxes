-- Factorio Taxes — scenario entry point.
--
-- Bootstrap only at this stage: it establishes the persistent state described in
-- docs/DESIGN.md section 3 and exposes a probe command so the headless test
-- harness can assert against the live game. Modules are wired in as they land.

local config = require("scripts.config")

local function default_state()
  return {
    cycle = 0,
    phase = "cooldown",
    phase_end_tick = 0,
    demand = {},
    infra = {
      surface_index = nil,
      stop_unit_number = nil,
      stop_position = nil,
      west_end = nil,
      east_end = nil,
      entities = {},
      built = false,
    },
    train = {
      loco_unit_numbers = {},
      wagon_unit_numbers = {},
      train_id = nil,
    },
    stats = { paid = 0, missed = 0, waves = 0 },
  }
end

script.on_init(function()
  storage.taxes = default_state()
  local surface = game.surfaces[config.SURFACE_NAME]
  storage.taxes.infra.surface_index = surface and surface.index or 1
  log("[taxes] initialised, cycle period " .. config.CYCLE_PERIOD .. " ticks")
end)

script.on_configuration_changed(function()
  storage.taxes = storage.taxes or default_state()
end)
