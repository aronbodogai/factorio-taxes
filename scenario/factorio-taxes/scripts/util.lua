-- Small helpers shared by every module. Keep this file dependency-free apart
-- from config, so any module can require it without creating a cycle.

local config = require("scripts.config")

local util = {}

--- The surface the scenario runs on, or nil if it somehow does not exist.
function util.surface()
  return game.surfaces[config.SURFACE_NAME]
end

--- The force taxes are levied against.
function util.player_force()
  return game.forces.player
end

--- Announce something to every player, with an optional sound.
-- @param message LocalisedString
-- @param sound string|nil a sound path such as "utility/new_objective"
function util.announce(message, sound)
  game.print(message)
  if sound then
    for _, player in pairs(game.connected_players) do
      player.play_sound({ path = sound })
    end
  end
end

--- Format a tick count as M:SS for display.
function util.format_ticks(ticks)
  if ticks < 0 then ticks = 0 end
  local total_seconds = math.floor(ticks / 60)
  return string.format("%d:%02d", math.floor(total_seconds / 60), total_seconds % 60)
end

--- Stack size of an item prototype, defaulting to 1 for anything unexpected.
function util.stack_size(item_name)
  local proto = prototypes.item[item_name]
  return proto and proto.stack_size or 1
end

--- True if the entity is live and belongs to the immutable tax infrastructure.
function util.is_tax_entity(entity)
  if not (entity and entity.valid and entity.unit_number) then return false end
  local infra = storage.taxes and storage.taxes.infra
  return infra ~= nil and infra.entities[entity.unit_number] == true
end

--- Mark an entity as permanent tax infrastructure: unbreakable, unminable, and
--- recorded in state so the protection handlers recognise it after a reload.
-- @param entity LuaEntity
-- @param operable boolean whether the player may open its GUI
function util.protect(entity, operable)
  if not (entity and entity.valid) then return end
  entity.destructible = false
  entity.minable = false
  entity.rotatable = false
  entity.operable = operable and true or false
  if entity.unit_number then
    storage.taxes.infra.entities[entity.unit_number] = true
  end
end

--- Stop tracking an entity, used when a tax train is despawned.
function util.unprotect(entity)
  if entity and entity.valid and entity.unit_number then
    storage.taxes.infra.entities[entity.unit_number] = nil
  end
end

--- Centroid of the player force base, used to aim attacks. Falls back to the
--- spawn point when the force owns nothing yet.
function util.base_centroid()
  local surface = util.surface()
  local force = util.player_force()
  if not (surface and force) then return { x = 0, y = 0 } end

  local sum_x, sum_y, count = 0, 0, 0
  for _, entity in pairs(surface.find_entities_filtered({ force = force, is_military_target = true })) do
    sum_x = sum_x + entity.position.x
    sum_y = sum_y + entity.position.y
    count = count + 1
  end

  if count == 0 then
    return force.get_spawn_position(surface)
  end
  return { x = sum_x / count, y = sum_y / count }
end

--- Pick one entry from a list using per-entry weights.
-- @param entries table array of entries
-- @param weight_of function(entry) -> number, must return a positive number
function util.weighted_pick(entries, weight_of)
  local total = 0
  for _, entry in pairs(entries) do
    total = total + weight_of(entry)
  end
  if total <= 0 then return entries[1] end

  local roll = math.random() * total
  for _, entry in pairs(entries) do
    roll = roll - weight_of(entry)
    if roll <= 0 then return entry end
  end
  return entries[#entries]
end

return util
