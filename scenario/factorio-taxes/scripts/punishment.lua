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
local MAX_PLACEMENT_ATTEMPTS = 8 -- re-tries, at fresh angles and wider searches, before a unit is abandoned
local PLACEMENT_SEARCH_RADIUS = 3 -- radius of the first find_non_colliding_position search, in tiles
local GROUP_SIZE = 5 -- units per attack cluster, so one blocked cluster cannot stall the rest
local GROUP_ARC_HALF_WIDTH = math.pi / 24 -- half the arc one cluster spawns within, so it lands as a wave and not a cordon
local ATTACK_COMMAND_RADIUS = 50 -- attack_area radius; wide enough to cover a typical base footprint from its centroid
local MIN_WAVE_FRACTION = 0.9 -- below this share of the requested size the wave is called out as reduced

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

--- Find a non-colliding spawn point for `unit_name` on the attack ring around
--- `centre`, near `group_angle` so the cluster stays together. Every retry uses
--- a fresh angle, a wider arc, and a larger collision search, because a spawn
--- band that crosses water or cliffs blocks a whole sector: resampling the same
--- narrow arc at the same tiny search radius would just fail eight times and
--- silently shrink the wave. The final attempts widen to the full ring, so a
--- unit is only abandoned when the entire ring is unusable for it.
-- @return MapPosition|nil
local function find_ring_position(surface, unit_name, centre, group_angle)
  for attempt = 1, MAX_PLACEMENT_ATTEMPTS do
    -- Early attempts stay inside the cluster's own arc to keep it together.
    -- Once half the attempts are spent the sector is probably blocked outright,
    -- so fall back to the whole ring rather than dropping the unit.
    local arc = math.min(GROUP_ARC_HALF_WIDTH * attempt, math.pi)
    if attempt > MAX_PLACEMENT_ATTEMPTS / 2 then arc = math.pi end
    local angle = group_angle + (math.random() * 2 - 1) * arc
    local radius = config.ATTACK_SPAWN_RADIUS + (math.random() * 2 - 1) * config.ATTACK_SPAWN_JITTER
    local candidate = {
      x = centre.x + radius * math.cos(angle),
      y = centre.y + radius * math.sin(angle),
    }
    local found = surface.find_non_colliding_position(unit_name, candidate,
      PLACEMENT_SEARCH_RADIUS * attempt, 1)
    if found then return found end
  end
  return nil
end

--- Spawn one spatially coherent cluster and send it in. Every member is placed
--- within a narrow arc of a single randomly chosen angle, so the cluster
--- arrives as one wave; picking an independent angle per unit would scatter the
--- five members around the whole ring and leave the group gathering across the
--- map instead of attacking.
-- @return integer, the number of units that ended up in a commanded group
local function spawn_group(surface, enemy_force, mix, centre, count)
  local group_angle = math.random() * 2 * math.pi
  local units, sum_x, sum_y = {}, 0, 0

  for _ = 1, count do
    local unit_name = util.weighted_pick(mix, function(entry) return entry.weight end).name
    local position = find_ring_position(surface, unit_name, centre, group_angle)

    if position then
      local unit = surface.create_entity({ name = unit_name, position = position, force = enemy_force })
      if unit and unit.valid then
        units[#units + 1] = unit
        sum_x = sum_x + unit.position.x
        sum_y = sum_y + unit.position.y
      end
    else
      log("[taxes] punishment: no placement found for " .. unit_name .. " after " ..
        MAX_PLACEMENT_ATTEMPTS .. " attempts")
    end
  end

  if #units == 0 then return 0 end

  -- Create the group at the centre of the members it will actually hold, not at
  -- the first member's position, so the gathering point is inside the cluster.
  local group = surface.create_unit_group({
    position = { x = sum_x / #units, y = sum_y / #units },
    force = enemy_force,
  })
  if not (group and group.valid) then
    -- A failed group must not take the settlement tick down with it; the units
    -- stay on the map as loose enemies and are not counted as part of the wave.
    log("[taxes] punishment: create_unit_group failed; " .. #units .. " units left ungrouped")
    return 0
  end

  local added = 0
  for _, unit in ipairs(units) do
    -- add_member throws if either side went invalid between creation and here,
    -- which mid-cycle would abort settlement entirely, so failures are absorbed
    -- one member at a time.
    if group.valid and unit.valid then
      local ok, err = pcall(function() group.add_member(unit) end)
      if ok then
        added = added + 1
      else
        log("[taxes] punishment: add_member failed: " .. tostring(err))
      end
    end
  end

  if added == 0 or not group.valid then
    log("[taxes] punishment: no member could be added to the group; cluster abandoned")
    return 0
  end

  local commanded, err = pcall(function()
    group.set_command({
      type = defines.command.attack_area,
      destination = centre,
      radius = ATTACK_COMMAND_RADIUS,
      distraction = defines.distraction.by_enemy,
    })
    -- A scripted group stays in state 0 (gathering) after set_command and only
    -- flips to 1 (moving) once start_moving is called; probed on 2.0.77, see
    -- docs/API_NOTES.md. Without this the wave stands on its spawn ring forever.
    group.start_moving()
  end)
  if not commanded then
    log("[taxes] punishment: commanding the group failed: " .. tostring(err))
  end

  return added
end

--- Compute the wave for the current cycle's shortfall, spawn it on the attack
--- ring around the player base, and send it in. Safe to call directly from
--- the console with any argument: invalid or non-positive shortfalls, a
--- missing surface, an uninitialised `storage.taxes`, or a fully blocked ring
--- all resolve to a clean 0 rather than an error.
-- @param shortfall number, fraction of the demand left unpaid, expected [0, 1]
-- @return integer, the number of units actually spawned and put in a group
-- @return string, a short reason for that count ("zero-size", "grace",
--         "no-surface", "no-prototypes", "no-placement", "partial", "ok"), for
--         callers such as /tax-attack that want to explain a zero. The first
--         return value is unchanged, so existing positional callers still work.
function punishment.spawn_wave(shortfall)
  local taxes = storage.taxes
  local cycle = (taxes and taxes.cycle) or 0

  local size = punishment.wave_size(shortfall, cycle)
  if size <= 0 then
    return 0, "zero-size"
  end

  if cycle < config.GRACE_CYCLES then
    log("[taxes] punishment skipped: cycle " .. cycle .. " is within the grace period")
    return 0, "grace"
  end

  local surface = util.surface()
  local enemy_force = game.forces.enemy
  if not (surface and enemy_force) then
    log("[taxes] punishment aborted: surface or enemy force unavailable")
    return 0, "no-surface"
  end

  local evolution = enemy_force.get_evolution_factor(surface)
  local mix = punishment.unit_mix(evolution)
  if #mix == 0 then
    log("[taxes] punishment aborted: no enemy prototypes available at evolution " .. tostring(evolution))
    return 0, "no-prototypes"
  end

  local centre = util.base_centroid()
  local spawned = 0

  -- Split the wave into clusters up front: several smaller groups issuing their
  -- own attack_area command are more robust than one giant group, since a single
  -- stuck member cannot stall the whole wave.
  local remaining = size
  while remaining > 0 do
    local count = math.min(GROUP_SIZE, remaining)
    remaining = remaining - count
    spawned = spawned + spawn_group(surface, enemy_force, mix, centre, count)
  end

  if spawned == 0 then
    log("[taxes] punishment: nothing could be spawned on the attack ring for a wave of " .. size)
    return 0, "no-placement"
  end

  if taxes and taxes.stats then
    taxes.stats.waves = taxes.stats.waves + 1
  end

  local missing = size - spawned
  if missing > 0 then
    log("[taxes] punishment: wave short by " .. missing .. " of " .. size ..
      " units; the spawn ring could not take them")
  end

  -- A unit or two lost to terrain is noise, but a materially smaller wave breaks
  -- the proportional-to-shortfall contract, so say so instead of quietly letting
  -- the unpaid cycle off lightly.
  if spawned < size * MIN_WAVE_FRACTION then
    util.announce({ "taxes.attack-incoming-reduced", spawned, missing })
    return spawned, "partial"
  end

  util.announce({ "taxes.attack-incoming", spawned })
  return spawned, "ok"
end

return punishment
