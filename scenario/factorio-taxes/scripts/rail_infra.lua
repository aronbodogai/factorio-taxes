-- The pre-placed, indestructible rail line, its station, and the terrain
-- corridor they sit in. See docs/DESIGN.md section 4.
--
-- The construction pass is deliberately re-runnable: every placement first looks
-- for an entity that is already there, so building twice repairs rather than
-- duplicates. build() does the whole pass; ensure() is the cheap post-load
-- check that only falls back to build() when something is actually missing.

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

-- Corridor preparation ------------------------------------------------------

--- Force the chunks the line runs through into existence. Only the chunks
--- around spawn exist when on_init runs, and neither set_tiles nor
--- create_entity can be trusted on ground the map generator has not produced.
local function generate_corridor_chunks(surface)
  local ok, err = pcall(function()
    for x = -config.RAIL_HALF_LENGTH, config.RAIL_HALF_LENGTH + 31, 32 do
      surface.request_to_generate_chunks({ x = x, y = config.RAIL_Y }, 32)
    end
    surface.force_generate_chunk_requests()
  end)
  if not ok then
    log("[taxes] could not force chunk generation for the rail corridor: " .. tostring(err))
  end
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

--- Trees, rocks, and cliffs all block rail. This is the same filter the probe
--- in docs/API_NOTES.md used to clear the corridor completely.
-- @return number entities destroyed
local function clear_corridor(surface)
  local removed = 0
  local obstacles = surface.find_entities_filtered({
    area = corridor_area(),
    type = { "tree", "simple-entity", "cliff" },
  })
  for _, entity in pairs(obstacles) do
    if entity.valid then
      entity.destroy()
      removed = removed + 1
    end
  end
  return removed
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
    end
  end

  return placed, failed
end

--- Whether a freshly placed stop actually latched onto the line. A stop on the
--- wrong side of the track is placed happily but is connected to nothing, and a
--- train can then never path to it. An unavailable property counts as a pass:
--- we would rather keep the stop the spec asks for than tear down one we cannot
--- judge. Needs verification on the headless server.
local function station_is_connected(stop)
  local ok, rail = pcall(function() return stop.connected_rail end)
  if not ok then return true end
  return rail ~= nil
end

--- Place the tax station. A train stop serves the track that passes on its
--- left, so a stop for eastbound trains sits on the south side of the line,
--- which is +y in Factorio. docs/API_NOTES.md records a probe that put one on
--- the north side, but that probe only asserted that create_entity succeeded,
--- not that a train could reach it, so we place to the south per
--- docs/DESIGN.md section 4 and mirror it only if it fails to connect.
local function place_station(surface, force)
  -- The odd grid has no tile centred on x = 0; -1 is the nearest slot to it.
  local x = to_odd(0)
  local south_y = config.RAIL_Y + STOP_OFFSET
  local north_y = config.RAIL_Y - STOP_OFFSET

  local stop = surface.find_entity("train-stop", { x = x, y = south_y })
    or surface.find_entity("train-stop", { x = x, y = north_y })

  if not stop then
    stop = surface.create_entity({
      name = "train-stop",
      position = { x = x, y = south_y },
      direction = defines.direction.east,
      force = force,
    })
    if stop and not station_is_connected(stop) then
      stop.destroy()
      stop = surface.create_entity({
        name = "train-stop",
        position = { x = x, y = north_y },
        direction = defines.direction.east,
        force = force,
      })
      if stop and not station_is_connected(stop) then
        log("[taxes] the tax station is connected to no rail on either side of the line")
      end
    end
  end

  if not stop then return nil end

  stop.backer_name = config.STATION_NAME
  -- operable = false so the player cannot rename the station or edit what
  -- stops there, per docs/DESIGN.md section 4.
  util.protect(stop, false)
  return stop
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

  generate_corridor_chunks(surface)
  local levelled = level_corridor(surface)
  local cleared = clear_corridor(surface)
  local placed, failed = place_rails(surface, force)

  local stop = place_station(surface, force)
  if not stop then
    log("[taxes] the tax station could not be placed, the line is unusable")
    return false
  end
  station_cache = stop

  infra.stop_unit_number = stop.unit_number
  -- Store the position the game settled on, not the one we asked for, so
  -- station() can find the entity again by exact position after a load.
  infra.stop_position = { x = stop.position.x, y = stop.position.y }

  local first_x, last_x = line_extents()
  infra.west_end = { x = first_x + END_INSET, y = config.RAIL_Y }
  infra.east_end = { x = last_x - END_INSET, y = config.RAIL_Y }

  force.chart(surface, {
    { infra.stop_position.x - config.CHART_RADIUS, infra.stop_position.y - config.CHART_RADIUS },
    { infra.stop_position.x + config.CHART_RADIUS, infra.stop_position.y + config.CHART_RADIUS },
  })

  infra.built = true
  log(string.format(
    "[taxes] rail line built: %d rails placed, %d failed, %d tiles levelled, %d obstacles cleared",
    placed, failed, levelled, cleared))
  return true
end

--- Re-verify the line after a load. Everything is indestructible and survives
--- in the save, so the normal case is a single validity check and nothing else.
function rail_infra.ensure()
  local infra = storage.taxes and storage.taxes.infra
  if not infra then return false end
  if infra.built and rail_infra.station() then return true end
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

--- Cancel a mining attempt on tax infrastructure. Handles both
--- on_pre_player_mined_item and on_robot_pre_mined. The entities are already
--- minable = false so this should never fire; it re-asserts the flags in case
--- something cleared them and explains the refusal to the player.
function rail_infra.on_pre_mined(event)
  local entity = event and event.entity
  if not util.is_tax_entity(entity) then return end

  entity.minable = false
  entity.destructible = false

  if event.player_index then
    local player = game.get_player(event.player_index)
    if player then player.print({ "taxes.cannot-mine" }) end
  end
end

--- Undo a deconstruction order on tax infrastructure the moment it is placed.
function rail_infra.on_marked_for_deconstruction(event)
  local entity = event and event.entity
  if not util.is_tax_entity(entity) then return end

  local player = nil
  if event.player_index then player = game.get_player(event.player_index) end

  entity.cancel_deconstruction(entity.force, player)
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
