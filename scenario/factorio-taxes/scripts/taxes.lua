-- The scenario as an event_handler library, so it composes with base freeplay
-- instead of replacing it. Players still get the crash site, the starting items,
-- and the rocket goal; the tax cycle runs alongside them.

local config = require("scripts.config")
local rail_infra = require("scripts.rail_infra")
local tax_schedule = require("scripts.tax_schedule")
local gui = require("scripts.gui")
local debug_commands = require("scripts.commands")

local taxes = {}

--- The shape described in docs/DESIGN.md section 3. Kept in one place so that
--- on_init and the repair path in on_configuration_changed cannot drift apart.
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
      departing = false,
      fluid_seeds = {},
    },
    stats = { paid = 0, missed = 0, waves = 0, last_shortfall = 0 },
  }
end

--- Fill in anything a save from an older revision is missing, without discarding
--- state the player has already accumulated.
local function repair_state()
  storage.taxes = storage.taxes or default_state()
  local defaults = default_state()
  for key, value in pairs(defaults) do
    if storage.taxes[key] == nil then
      storage.taxes[key] = value
    end
  end
  for key, value in pairs(defaults.infra) do
    if storage.taxes.infra[key] == nil then
      storage.taxes.infra[key] = value
    end
  end
  for key, value in pairs(defaults.stats) do
    if storage.taxes.stats[key] == nil then
      storage.taxes.stats[key] = value
    end
  end
end

taxes.on_init = function()
  storage.taxes = default_state()
  local surface = game.surfaces[config.SURFACE_NAME]
  storage.taxes.infra.surface_index = surface and surface.index or 1
  tax_schedule.init()
  log("[taxes] initialised on " .. config.SURFACE_NAME)
end

taxes.on_configuration_changed = function()
  repair_state()
  rail_infra.ensure()
end

-- Debug commands are registered by event_handler on both init and load, because
-- command registration is not part of the save.
taxes.add_commands = function()
  debug_commands.register()
end

taxes.events = {
  [defines.events.on_tick] = function(event)
    tax_schedule.on_tick(event)
    if event.tick % config.UI_REFRESH == 0 then
      gui.refresh_all()
    end
  end,

  [defines.events.on_player_created] = function(event)
    local player = game.get_player(event.player_index)
    if player then gui.build(player) end
  end,

  [defines.events.on_player_joined_game] = function(event)
    local player = game.get_player(event.player_index)
    if player then gui.build(player) end
  end,

  -- Registration lives here rather than in gui.lua so that every handler in the
  -- scenario goes through the one event_handler library and none of them race
  -- base freeplay for the same event slot.
  [defines.events.on_player_left_game] = function(event)
    local player = game.get_player(event.player_index)
    if player then gui.destroy(player) end
  end,

  [defines.events.on_pre_player_mined_item] = function(event)
    rail_infra.on_pre_mined(event)
  end,

  [defines.events.on_robot_pre_mined] = function(event)
    rail_infra.on_pre_mined(event)
  end,

  -- The pre-mined events cannot cancel a mine that is already under way, so they
  -- are only a warning. These two are the actual repair: anything that did get
  -- mined is put back and re-protected.
  [defines.events.on_player_mined_entity] = function(event)
    rail_infra.on_mined(event)
  end,

  [defines.events.on_robot_mined_entity] = function(event)
    rail_infra.on_mined(event)
  end,

  [defines.events.on_marked_for_deconstruction] = function(event)
    rail_infra.on_marked_for_deconstruction(event)
  end,

  [defines.events.on_player_driving_changed_state] = function(event)
    rail_infra.on_driving_changed(event)
  end,
}

return taxes
