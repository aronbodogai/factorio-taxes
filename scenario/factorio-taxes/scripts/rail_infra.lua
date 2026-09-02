-- The pre-placed, indestructible rail line, its station, and the terrain
-- corridor they sit in. See docs/DESIGN.md section 4.
--
-- The construction pass is deliberately re-runnable: every placement first looks
-- for an entity that is already there, so building twice repairs rather than
-- duplicates. build() does the whole pass; ensure() is the cheap check that
-- verifies what actually exists on the surface rather than trusting a flag, and
-- only falls back to build() when the line itself is damaged.

local config = require("scripts.config")
local util = require("scripts.util")

local rail_infra = {}

-- Laid down wherever the natural terrain will not carry rail.
local LEVEL_TILE = "grass-1"

-- Distance from the rail centre line to the train stop. A straight rail is a
-- 2x2 entity, so the neighbouring 2x2 slot is exactly two tiles away.
local STOP_OFFSET = 2

-- How far inside the last rail the spawn and despawn points sit. Kept even so
-- the points stay on the odd grid the rails use. The train is assembled
-- eastwards from west_end, so a couple of tiles of margin is enough.
local END_INSET = 4

-- Tiles per chunk edge, and the margin in CHUNKS we ask for around each chunk of
-- the corridor. See generate_corridor_chunks for why this is not a tile count.
local CHUNK_SIZE = 32
local CHUNK_MARGIN = 1

-- Only consulted if the collision layer query below is unavailable. These are
-- the base game tiles a rail cannot be built on.
local WATER_TILE_NAMES = {
  ["water"] = true,
  ["deepwater"] = true,
  ["water-green"] = true,
  ["deepwater-green"] = true,
  ["water-shallow"] = true,
  ["water-mud"] = true,
  ["water-wube"] = true,
}

-- Resolved lookup of the station entity. This is derived state, not persistent
-- state: it is empty after a load and rebuilt from storage on first use.
local station_cache = nil

-- Geometry ------------------------------------------------------------------

--- Round to the nearest odd tile coordinate. Rails and train stops snap to the
--- odd grid (docs/API_NOTES.md), so every position we ask for is pre-snapped
--- and the position the entity reports back matches what we stored.
local function to_odd(value)
  return math.floor((value - 1) / 2) * 2 + 1
end

--- The x of the first and last rail of the line, on the odd grid.
local function line_extents()
  return to_odd(-config.RAIL_HALF_LENGTH + 1), to_odd(config.RAIL_HALF_LENGTH - 1)
end

--- The rectangle the corridor covers, in tile coordinates.
local function corridor_area()
  local first_x, last_x = line_extents()
  return {
    { first_x - 1, config.RAIL_Y - config.CORRIDOR_HALF_WIDTH },
    { last_x + 1, config.RAIL_Y + config.CORRIDOR_HALF_WIDTH },
  }
end

--- The thin band the line's own rails sit in. Deliberately much narrower than
--- the corridor: a rail the player laid alongside at RAIL_Y +/- 2 has a bounding
--- box that stops a full tile short of this band, so a stray rail cannot pad the
--- count and mask a gap in our line.
local function rail_band_area()
  local first_x, last_x = line_extents()
  return {
    { first_x - 1, config.RAIL_Y - 0.5 },
    { last_x + 1, config.RAIL_Y + 0.5 },
  }
end

--- How many rails a complete line has, derived from config rather than from a
--- number we once stored, so a config change cannot leave a stale expectation.
local function expected_rail_count()
  local first_x, last_x = line_extents()
  return math.floor((last_x - first_x) / 2) + 1
end

--- How many of the line's rails actually exist right now, or nil if the count
--- could not be taken. One API call, so this is cheap enough for ensure().
local function count_line_rails(surface)
  local ok, count = pcall(function()
    return surface.count_entities_filtered({ area = rail_band_area(), name = "straight-rail" })
  end)
  if not ok then return nil end
  return count
end

--- Where the tax station belongs. Factorio serves a stop on the RIGHT-hand side
--- relative to travel, so for an eastbound train right is +y, which puts the stop
--- south of the line (docs/API_NOTES.md, docs/DESIGN.md section 4). The odd grid
--- has no tile centred on x = 0, so -1 is the nearest slot to it.
local function station_position()
  return { x = to_odd(0), y = config.RAIL_Y + STOP_OFFSET }
end

-- Corridor preparation ------------------------------------------------------

--- Force the chunks the line runs through into existence. Only the chunks
--- around spawn exist when on_init runs, and neither set_tiles nor
--- create_entity can be trusted on ground the map generator has not produced.
---
--- request_to_generate_chunks takes its radius in CHUNKS, not tiles
--- (docs/API_NOTES.md). An earlier version passed 32 from nine positions and
--- generated 5645 chunks at map start, which is a slow on_init, a bloated save,
--- and thousands of chunks of pre-generated enemy nests. The corridor is only a
--- handful of chunks wide and two tall, so walk its exact chunk span and ask for
--- a single chunk of margin around each, which keeps the total in the dozens.
--- ensure() can reach build() again mid-game, so this has to stay cheap.
-- @return number chunk positions requested
local function generate_corridor_chunks(surface)
  local area = corridor_area()
  local first_cx = math.floor(area[1][1] / CHUNK_SIZE)
  local last_cx = math.floor(area[2][1] / CHUNK_SIZE)
  local first_cy = math.floor(area[1][2] / CHUNK_SIZE)
  local last_cy = math.floor(area[2][2] / CHUNK_SIZE)
  local requested = 0

  local ok, err = pcall(function()
    for cx = first_cx, last_cx do
      for cy = first_cy, last_cy do
        surface.request_to_generate_chunks({
          x = cx * CHUNK_SIZE + CHUNK_SIZE / 2,
          y = cy * CHUNK_SIZE + CHUNK_SIZE / 2,
        }, CHUNK_MARGIN)
        requested = requested + 1
      end
    end
    surface.force_generate_chunk_requests()
  end)

  if not ok then
    log("[taxes] could not force chunk generation for the rail corridor: " .. tostring(err))
    return 0
  end
  return requested
end

--- Build the predicate that decides whether a tile has to be replaced. 2.0
--- addresses collision layers by name and water tiles collide with
--- "water_tile"; probe that once rather than paying for it on every tile. The
--- tile name list is the fallback if the layer name is ever wrong, so a rename
--- degrades into a slightly coarser test instead of levelling nothing.
--- The fallback path needs verification against a future version.
local function unbuildable_test(surface)
  local probe = surface.get_tile(0, config.RAIL_Y)
  local ok = pcall(function() return probe.collides_with("water_tile") end)
  if ok then
    return function(tile) return tile.collides_with("water_tile") end
  end
  log("[taxes] collision layer \"water_tile\" unavailable, falling back to tile names")
  return function(tile) return WATER_TILE_NAMES[tile.name] == true end
end

--- Replace everything the rail cannot be built on with plain ground. Rail
--- placement fails outright on water, so this has to run before any
--- create_entity call.
-- @return number tiles replaced
local function level_corridor(surface)
  local blocks_rail = unbuildable_test(surface)
  local area = corridor_area()
  local tiles = {}

  for x = area[1][1], area[2][1] do
    for y = area[1][2], area[2][2] do
      local tile = surface.get_tile(x, y)
      if tile and tile.valid and blocks_rail(tile) then
        tiles[#tiles + 1] = { name = LEVEL_TILE, position = { x, y } }
      end
    end
  end

  if #tiles > 0 then
    surface.set_tiles(tiles)
  end
  return #tiles
end

--- Trees, rocks, and cliffs all block rail, and so do enemy structures. The
--- ends of the line sit near the edge of the default enemy-free starting area,
--- so a spawner or a worm can easily stand in the corridor; leaving one there
--- produces a silent gap in the line that no amount of retrying will fill.
--- Worms are type "turret" while every player turret is an ammo-, electric- or
--- fluid-turret, and the force filter keeps player structures safe regardless.
-- @return number obstacles destroyed, number enemy structures destroyed
local function clear_corridor(surface)
  local area = corridor_area()
  local removed, nests = 0, 0

  for _, entity in pairs(surface.find_entities_filtered({
    area = area,
    type = { "tree", "simple-entity", "cliff" },
  })) do
    if entity.valid then
      entity.destroy()
      removed = removed + 1
    end
  end

  local ok, err = pcall(function()
    for _, entity in pairs(surface.find_entities_filtered({
      area = area,
      force = "enemy",
      type = { "unit-spawner", "turret" },
    })) do
      if entity.valid then
        entity.destroy()
        nests = nests + 1
      end
    end
  end)
  if not ok then
    log("[taxes] could not sweep enemy structures out of the rail corridor: " .. tostring(err))
  end

  return removed, nests
end

-- Placement -----------------------------------------------------------------

--- Lay the line on the odd grid, adopting anything that is already there.
-- @return number placed, number failed
local function place_rails(surface, force)
  local first_x, last_x = line_extents()
  local placed, failed = 0, 0

  for x = first_x, last_x, 2 do
    local position = { x = x, y = config.RAIL_Y }
    local rail = surface.find_entity("straight-rail", position)
    if not rail then
      rail = surface.create_entity({
        name = "straight-rail",
        position = position,
        direction = defines.direction.east,
        force = force,
      })
    end
    if rail then
      util.protect(rail, false)
      placed = placed + 1
    else
      failed = failed + 1
      log(string.format("[taxes] no rail could be placed at x = %d, y = %d", x, config.RAIL_Y))
    end
  end

  return placed, failed
end

--- Whether a stop actually latched onto the line. A stop on the wrong side of
--- the track is placed happily but is connected to nothing, and a train can then
--- never path to it. An unavailable property counts as a pass: we would rather
--- keep the stop the spec asks for than tear down one we cannot judge.
local function station_is_connected(stop)
  local ok, rail = pcall(function() return stop.connected_rail end)
  if not ok then return true end
  return rail ~= nil
end

--- Whether an existing stop is the station we want. All three tests matter: a
--- stop in the wrong slot, or one facing the wrong way, binds to a rail that
--- does not exist, and adopting it would make the fault permanent because every
--- later pass would adopt it again.
local function station_is_valid(stop)
  if not (stop and stop.valid) then return false end
  local expected = station_position()
  if stop.position.x ~= expected.x or stop.position.y ~= expected.y then return false end
  if stop.direction ~= defines.direction.east then return false end
  return station_is_connected(stop)
end

--- Place the tax station on the south side of the line, facing east.
---
--- There is deliberately no mirrored fallback. The right-hand rule is not
--- ambiguous, and the old fallback mirrored the position to RAIL_Y - 2 while
--- keeping direction = east, which binds to a rail at RAIL_Y - 4 that does not
--- exist: a single false negative from connected_rail destroyed the correct stop
--- and permanently installed an unconnectable one. A fallback that can install a
--- broken station is worse than no fallback, so a stop that reports no connected
--- rail is kept and logged loudly instead.
local function place_station(surface, force)
  local expected = station_position()

  local existing = surface.find_entity("train-stop", expected)
  if station_is_valid(existing) then
    existing.backer_name = config.STATION_NAME
    util.protect(existing, false)
    return existing
  end

  -- Anything else standing in either stop slot is wreckage from an earlier,
  -- broken placement. Remove it so the correct stop has somewhere to go.
  for _, y in pairs({ expected.y, config.RAIL_Y - STOP_OFFSET }) do
    local stale = surface.find_entity("train-stop", { x = expected.x, y = y })
    if stale and stale.valid then
      log(string.format("[taxes] removing an unusable tax station at x = %d, y = %d", expected.x, y))
      util.unprotect(stale)
      stale.destroy()
    end
  end

  local stop = surface.create_entity({
    name = "train-stop",
    position = expected,
    direction = defines.direction.east,
    force = force,
  })
  if not stop then
    return nil
  end

  if not station_is_connected(stop) then
    log(string.format(
      "[taxes] WARNING: the tax station at x = %d, y = %d reports no connected rail; look for a gap in the line beside it",
      expected.x, expected.y))
  end

  stop.backer_name = config.STATION_NAME
  -- operable = false so the player cannot rename the station or edit what
  -- stops there, per docs/DESIGN.md section 4.
  util.protect(stop, false)
  return stop
end

--- Record a freshly resolved station in state and in the cache.
local function adopt_station(infra, stop)
  station_cache = stop
  infra.stop_unit_number = stop.unit_number
  -- Store the position the game settled on, not the one we asked for, so
  -- station() can find the entity again by exact position after a load.
  infra.stop_position = { x = stop.position.x, y = stop.position.y }
end

-- Public interface ----------------------------------------------------------

--- Build the corridor, the line, and the station, and record them in state.
--- Idempotent: existing entities are adopted, so a repeat pass only repairs
--- what is missing.
-- @return boolean whether the line is usable afterwards
function rail_infra.build()
  if not (storage.taxes and storage.taxes.infra) then
    log("[taxes] rail_infra.build called before storage.taxes existed")
    return false
  end

  local surface = util.surface()
  local force = util.player_force()
  if not (surface and force) then
    log("[taxes] surface " .. tostring(config.SURFACE_NAME) .. " is missing, cannot build the tax line")
    return false
  end

  local infra = storage.taxes.infra
  infra.surface_index = surface.index
  infra.built = false

  local chunks = generate_corridor_chunks(surface)
  local levelled = level_corridor(surface)
  local cleared, nests = clear_corridor(surface)
  local placed, failed = place_rails(surface, force)

  local stop = place_station(surface, force)
  if not stop then
    log("[taxes] the tax station could not be placed, the line is unusable")
    return false
  end
  adopt_station(infra, stop)

  local first_x, last_x = line_extents()
  infra.west_end = { x = first_x + END_INSET, y = config.RAIL_Y }
  infra.east_end = { x = last_x - END_INSET, y = config.RAIL_Y }

  force.chart(surface, {
    { infra.stop_position.x - config.CHART_RADIUS, infra.stop_position.y - config.CHART_RADIUS },
    { infra.stop_position.x + config.CHART_RADIUS, infra.stop_position.y + config.CHART_RADIUS },
  })

  -- A line with a hole in it is not a line: no train can path along it, so every
  -- cycle would burn ARRIVAL_TIMEOUT, teleport the train, and still punish the
  -- players. Report the failure instead of marking the line built.
  local usable = failed == 0
  infra.built = usable

  log(string.format(
    "[taxes] rail line pass: %d rails placed, %d failed, %d tiles levelled, %d obstacles cleared, %d enemy structures cleared, %d chunk requests",
    placed, failed, levelled, cleared, nests, chunks))
  if not usable then
    log(string.format(
      "[taxes] WARNING: the tax line has %d missing rails and no train can path along it; something in the corridor is not being cleared",
      failed))
  end
  return usable
end

--- Re-verify the line. Everything is indestructible and survives in the save, so
--- the normal case is one entity lookup plus one count, which is what makes this
--- safe to call mid-cycle. The stored built flag is only ever an optimisation
--- hint, never the answer: what is actually on the surface decides.
function rail_infra.ensure()
  local infra = storage.taxes and storage.taxes.infra
  if not infra then return false end

  local surface = util.surface()
  if not surface then return rail_infra.build() end

  -- A nil count means the query itself failed, which is no evidence of damage,
  -- so do not tear the line down over it.
  local rails = count_line_rails(surface)
  local rails_ok = rails == nil or rails >= expected_rail_count()
  local stop = rail_infra.station()

  if rails_ok and station_is_valid(stop) then
    infra.built = true
    return true
  end

  local force = util.player_force()

  -- The line is intact and only the station is wrong. Re-placing a single entity
  -- costs a handful of API calls where build() re-walks several thousand tiles,
  -- and train_manager calls ensure() in the middle of a cycle.
  if rails_ok and force then
    log("[taxes] the tax station is missing or unusable, repairing it without rebuilding the line")
    local repaired = place_station(surface, force)
    if repaired then
      adopt_station(infra, repaired)
      infra.built = true
      return true
    end
  end

  if not rails_ok then
    log(string.format(
      "[taxes] WARNING: the tax line is damaged, %d of %d rails present, rebuilding it",
      rails or -1, expected_rail_count()))
  end
  return rail_infra.build()
end

--- The tax train stop, or nil if it does not exist yet.
function rail_infra.station()
  if station_cache and station_cache.valid then return station_cache end
  station_cache = nil

  local infra = storage.taxes and storage.taxes.infra
  local surface = util.surface()
  if not (infra and infra.stop_position and surface) then return nil end

  station_cache = surface.find_entity("train-stop", infra.stop_position)
  return station_cache
end

--- Where a tax train is created. Returned as a copy so a caller cannot corrupt
--- the persistent state by editing the position it was handed.
function rail_infra.west_end()
  local infra = storage.taxes and storage.taxes.infra
  local position = infra and infra.west_end
  if not position then return nil end
  return { x = position.x, y = position.y }
end

--- Where a departing tax train is destroyed. Also a copy.
function rail_infra.east_end()
  local infra = storage.taxes and storage.taxes.infra
  local position = infra and infra.east_end
  if not position then return nil end
  return { x = position.x, y = position.y }
end

--- Register an entity as immutable tax infrastructure. Other modules protect
--- the rolling stock of a live tax train through here so the rules stay in one
--- place.
function rail_infra.protect_entity(entity, operable)
  util.protect(entity, operable)
end

-- Event handlers ------------------------------------------------------------

--- Tell whoever is mining that they may not. The robot variant of the event
--- carries no player_index, so there is nobody to print to on that path and the
--- log is the only record we get.
local function warn_miner(event, entity)
  if event.player_index then
    local player = game.get_player(event.player_index)
    if player then player.print({ "taxes.cannot-mine" }) end
    return
  end
  log(string.format(
    "[taxes] a construction robot tried to mine tax infrastructure (%s at x = %s, y = %s)",
    entity.name, tostring(entity.position.x), tostring(entity.position.y)))
end

--- Warn about a mining attempt on tax infrastructure. Handles both
--- on_pre_player_mined_item and on_robot_pre_mined.
---
--- This CANNOT cancel a mine that is already under way: setting minable inside
--- the handler does not abort the operation the engine has started. The real
--- protection is minable = false set at build time, and rail_infra.on_mined is
--- the net that catches anything which slips through anyway. So this handler is
--- purely the warning path, plus a re-assertion of flags something may have
--- cleared.
function rail_infra.on_pre_mined(event)
  local entity = event and event.entity
  if not util.is_tax_entity(entity) then return end

  entity.minable = false
  entity.destructible = false

  warn_miner(event, entity)
end

--- Put back a piece of the line that was mined anyway. Handles both
--- on_player_mined_entity and on_robot_mined_entity, which fire once the mine is
--- irreversible, so restoring is the only protection left.
---
--- Only the static line is rebuilt. Rolling stock is train_manager's, tracked by
--- unit_number, and conjuring a replacement locomotive here would hand it an
--- orphan it never sees; that case is logged for a human instead.
function rail_infra.on_mined(event)
  local entity = event and event.entity
  if not util.is_tax_entity(entity) then return end

  warn_miner(event, entity)

  local rebuildable = entity.type == "straight-rail" or entity.type == "train-stop"
  if not rebuildable then
    log(string.format(
      "[taxes] tax rolling stock (%s) was mined and cannot be restored from here", entity.name))
    util.unprotect(entity)
    return
  end

  local surface = entity.surface
  local spec = {
    name = entity.name,
    position = { x = entity.position.x, y = entity.position.y },
    direction = entity.direction,
    force = entity.force,
  }
  local backer_name = nil
  if entity.type == "train-stop" then backer_name = entity.backer_name end

  -- The engine destroys the entity the moment this handler returns, so the
  -- replacement cannot be created while the original still occupies the slot.
  -- Destroying it here is what frees the ground for the rebuild.
  util.unprotect(entity)
  entity.destroy()

  -- The mined item is in the buffer and would otherwise be a free rail for
  -- rebuilding something we just put back at no cost.
  if event.buffer and event.buffer.valid then event.buffer.clear() end

  local rebuilt = surface.create_entity(spec)
  if not rebuilt then
    log(string.format(
      "[taxes] WARNING: %s at x = %s, y = %s was mined and could not be rebuilt; the line now has a gap",
      spec.name, tostring(spec.position.x), tostring(spec.position.y)))
    return
  end

  if backer_name then rebuilt.backer_name = backer_name end
  util.protect(rebuilt, false)

  if rebuilt.type == "train-stop" then
    local infra = storage.taxes and storage.taxes.infra
    if infra then adopt_station(infra, rebuilt) end
  end
  log(string.format("[taxes] restored %s that was mined out of the tax line", spec.name))
end

--- Undo a deconstruction order on tax infrastructure the moment it is placed.
--- The order belongs to the force that issued it, not to the entity, so cancel
--- for the issuing force first; an order from another force would otherwise stay
--- marked forever. The entity's own force is cancelled too when it differs, in
--- case the issuer cannot be identified from the event.
function rail_infra.on_marked_for_deconstruction(event)
  local entity = event and event.entity
  if not util.is_tax_entity(entity) then return end

  local player = nil
  if event.player_index then player = game.get_player(event.player_index) end

  local ordering_force = entity.force
  if player and player.valid then
    ordering_force = player.force
  elseif event.robot and event.robot.valid then
    ordering_force = event.robot.force
  end

  entity.cancel_deconstruction(ordering_force, player)
  if ordering_force.name ~= entity.force.name then
    entity.cancel_deconstruction(entity.force, player)
  end

  if player then player.print({ "taxes.cannot-deconstruct" }) end
end

--- Eject any player who climbs into a tax locomotive. Clearing driving raises
--- this event a second time, but by then player.vehicle is nil and the second
--- pass falls straight through, so there is no loop.
function rail_infra.on_driving_changed(event)
  if not (event and event.player_index) then return end

  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  local vehicle = player.vehicle
  if not util.is_tax_entity(vehicle) then return end

  player.driving = false
  player.print({ "taxes.cannot-drive" })
end

return rail_infra
