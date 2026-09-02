-- Punishment for an unpaid or partially paid tax cycle (see docs/DESIGN.md
-- section 7). `wave_size` and `unit_mix` are deliberately side-effect-light so
-- they can be poked from a console command while iterating on balance; only
-- `spawn_wave` touches the live game.

local config = require("scripts.config")
local util = require("scripts.util")

local punishment = {}

-- Evolution factor at which each tier starts appearing, and the relative
-- weight it carries once unlocked. Weights increase per tier so that, once a
-- higher tier is available, it quickly outnumbers everything below it while
-- earlier tiers keep spawning in shrinking numbers for flavour. Thresholds
-- mirror the rough vanilla progression named in the design doc.
local TIERS = {
  { threshold = 0.0, weight = 1, biter = "small-biter", spitter = "small-spitter" },
  { threshold = 0.2, weight = 3, biter = "medium-biter", spitter = "medium-spitter" },
  { threshold = 0.5, weight = 6, biter = "big-biter", spitter = "big-spitter" },
  { threshold = 0.9, weight = 12, biter = "behemoth-biter", spitter = "behemoth-spitter" },
}

-- Placement and grouping tunables. These are implementation details of how a
-- wave is laid out on the ring, not gameplay balance, so they live here
-- rather than in config.lua.
local MAX_PLACEMENT_ATTEMPTS = 8 -- random re-angles tried before a unit is abandoned
local PLACEMENT_SEARCH_RADIUS = 3 -- passed to find_non_colliding_position
local GROUP_SIZE = 5 -- units per attack cluster, so one blocked cluster cannot stall the rest

--- Coerce a value to a finite number, falling back to `default` for nil,
--- non-numeric input, NaN, or infinities. Used so the debug-facing functions
--- below never throw on a stray console argument.
local function safe_number(value, default)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then
    return default
  end
  return n
end

--- Size of a punitive wave. Pure: only reads `config` and its own arguments,
--- so it is safe to call from a console command with any argument to sanity
--- check balance without touching game state.
-- @param shortfall number, fraction of the demand left unpaid, expected [0, 1]
-- @param cycle number, the settled cycle index the wave belongs to
-- @return integer, clamped to [0, config.MAX_WAVE]
function punishment.wave_size(shortfall, cycle)
  shortfall = safe_number(shortfall, 0)
  cycle = safe_number(cycle, 0)

  if shortfall <= 0 then return 0 end
  if shortfall > 1 then shortfall = 1 end -- shortfall is a fraction; a bad caller could pass more
  if cycle < 0 then cycle = 0 end

  local size = math.ceil(config.BASE_WAVE * shortfall * (1 + cycle * config.WAVE_GROWTH))
  if size < 0 then size = 0 end
  if size > config.MAX_WAVE then size = config.MAX_WAVE end
  return size
end

--- Weighted list of enemy prototype names appropriate to an evolution factor,
--- highest tiers weighted to dominate once unlocked. Reads `prototypes.entity`
--- to skip any name that is not actually loaded, but touches nothing else, so
--- it is also safe to call directly from the console at any time.
-- @param evolution number, expected [0, 1] as returned by get_evolution_factor
-- @return array of { name = string, weight = number }, possibly empty
function punishment.unit_mix(evolution)
  evolution = safe_number(evolution, 0)
  if evolution < 0 then evolution = 0 end
  if evolution > 1 then evolution = 1 end

  local entity_protos = prototypes and prototypes.entity
  local mix = {}
  for _, tier in ipairs(TIERS) do
    if evolution >= tier.threshold then
      for _, name in ipairs({ tier.biter, tier.spitter }) do
        -- Guard against a prototype that is not present in the loaded data
        -- (e.g. removed by a future game version) rather than handing back a
        -- name that would throw when something tries to spawn it.
        if entity_protos and entity_protos[name] then
          mix[#mix + 1] = { name = name, weight = tier.weight }
        end
      end
    end
  end
  return mix
end

--- Issue the attack command for one finished cluster and reset the builder
--- state, shared by the loop in spawn_wave below.
local function finish_group(group, group_count, centre)
  if group and group.valid and group_count > 0 then
    group.set_command({
      type = defines.command.attack_area,
      destination = centre,
      radius = 50,
      distraction = defines.distraction.by_enemy,
    })
  end
end

--- Find a non-colliding spawn point for `unit_name` on the attack ring around
--- `centre`, retrying at new random angles (never the same spot twice) up to
--- MAX_PLACEMENT_ATTEMPTS times so a locally blocked patch of map cannot hang
--- the tick or silently drop the unit without a real attempt.
local function find_ring_position(surface, unit_name, centre)
  for _ = 1, MAX_PLACEMENT_ATTEMPTS do
    local angle = math.random() * 2 * math.pi
    local radius = config.ATTACK_SPAWN_RADIUS + (math.random() * 2 - 1) * config.ATTACK_SPAWN_JITTER
    local candidate = {
      x = centre.x + radius * math.cos(angle),
      y = centre.y + radius * math.sin(angle),
    }
    local found = surface.find_non_colliding_position(unit_name, candidate, PLACEMENT_SEARCH_RADIUS, 1)
    if found then return found end
  end
  return nil
end

--- Compute the wave for the current cycle's shortfall, spawn it on the attack
--- ring around the player base, and send it in. Safe to call directly from
--- the console with any argument: invalid or non-positive shortfalls, a
--- missing surface, an uninitialised `storage.taxes`, or a fully blocked ring
--- all resolve to a clean 0 rather than an error.
-- @param shortfall number, fraction of the demand left unpaid, expected [0, 1]
-- @return integer, the number of units actually spawned and put in a group
function punishment.spawn_wave(shortfall)
  local taxes = storage.taxes
  local cycle = (taxes and taxes.cycle) or 0

  local size = punishment.wave_size(shortfall, cycle)
  if size <= 0 then
    return 0
  end

  if cycle < config.GRACE_CYCLES then
    log("[taxes] punishment skipped: cycle " .. cycle .. " is within the grace period")
    return 0
  end

  local surface = util.surface()
  local enemy_force = game.forces.enemy
  if not (surface and enemy_force) then
    log("[taxes] punishment aborted: surface or enemy force unavailable")
    return 0
  end

  local evolution = enemy_force.get_evolution_factor(surface)
  local mix = punishment.unit_mix(evolution)
  if #mix == 0 then
    log("[taxes] punishment aborted: no enemy prototypes available at evolution " .. tostring(evolution))
    return 0
  end

  local centre = util.base_centroid()
  local spawned = 0
  local group, group_count = nil, 0

  for _ = 1, size do
    local unit_name = util.weighted_pick(mix, function(entry) return entry.weight end).name
    local position = find_ring_position(surface, unit_name, centre)

    if position then
      local unit = surface.create_entity({ name = unit_name, position = position, force = enemy_force })
      if unit then
        if not group then
          group = surface.create_unit_group({ position = position, force = enemy_force })
        end
        group.add_member(unit)
        group_count = group_count + 1
        spawned = spawned + 1

        -- Close the cluster once it hits the cap: several smaller groups
        -- issuing their own attack_area command are more robust than one
        -- giant group, since a single stuck member cannot stall the whole wave.
        if group_count >= GROUP_SIZE then
          finish_group(group, group_count, centre)
          group, group_count = nil, 0
        end
      end
    else
      log("[taxes] punishment: no placement found for " .. unit_name .. " after " .. MAX_PLACEMENT_ATTEMPTS .. " attempts")
    end
  end

  finish_group(group, group_count, centre) -- flush the trailing partial cluster, if any

  if spawned > 0 then
    if taxes and taxes.stats then
      taxes.stats.waves = taxes.stats.waves + 1
    end
    util.announce({ "taxes.attack-incoming", spawned })
  end

  return spawned
end

return punishment
