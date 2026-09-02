-- Every tunable in the scenario lives here. Nothing else should hardcode a
-- number that a server owner might reasonably want to change.

local SECOND = 60
local MINUTE = 60 * SECOND

local config = {
  -- Timing -------------------------------------------------------------------
  CYCLE_PERIOD    = 5 * MINUTE, -- quiet time between one train leaving and the next demand
  ANNOUNCE_LEAD   = 2 * MINUTE, -- warning time between the demand and the train spawning
  LOADING_WINDOW  = 3 * MINUTE, -- time to fill the wagons once the train has stopped
  ARRIVAL_TIMEOUT = 2 * MINUTE, -- failsafe before an inbound train is force-placed
  DEPART_TIMEOUT  = 2 * MINUTE, -- failsafe before a departing train is force-removed
  UI_REFRESH      = 30,         -- ticks between UI refreshes

  -- Difficulty ---------------------------------------------------------------
  GRACE_CYCLES            = 1,   -- leading cycles that never punish, however badly they go
  GROWTH_RATE             = 0.15, -- per-cycle compounding growth of demanded quantities
  TIER_BIAS               = 2.5, -- exponent biasing random selection toward higher tiers
  TIER_WINDOW             = 1,   -- tiers below the highest available that stay eligible
  MAX_DEMAND_TYPES        = 4,   -- cap on distinct entries in one demand
  TYPES_PER_CYCLE_DIVISOR = 4,   -- one extra demanded type every N cycles
  MAX_DEMAND_STACKS       = 120, -- clamp so a demand always fits on a reasonable train

  -- Infrastructure -----------------------------------------------------------
  SURFACE_NAME         = "nauvis",
  STATION_NAME         = "Tax Station",
  RAIL_Y               = -31, -- rail line offset north of spawn; must be ODD (rails snap to the odd grid)
  RAIL_HALF_LENGTH     = 120, -- half the length of the line, in tiles
  CORRIDOR_HALF_WIDTH  = 6,   -- tiles cleared and levelled either side of the line
  CHART_RADIUS         = 96,  -- radius charted for the player force at map start
  DESPAWN_RADIUS       = 24,  -- how close to the east end a train must get to despawn

  -- Rolling stock ------------------------------------------------------------
  CARGO_WAGON_SLOTS    = 40,
  FLUID_WAGON_CAPACITY = 50000,
  WAGONS_PER_LOCO      = 4,

  -- Punishment ---------------------------------------------------------------
  BASE_WAVE           = 12,  -- units in a fully unpaid wave at cycle 0
  WAVE_GROWTH         = 0.2, -- per-cycle growth of wave size
  MAX_WAVE            = 200, -- hard cap so a long game cannot spawn a lag bomb
  ATTACK_SPAWN_RADIUS = 220, -- ring radius around the base centroid
  ATTACK_SPAWN_JITTER = 40,  -- random variation applied to that radius
}

return config
