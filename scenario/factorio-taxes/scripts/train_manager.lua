-- The tax train: composition from a demand, spawning at the west end of the
-- rail line, slot filters, arrival, settlement, departure and despawn.
--
-- Every entry point here is written to be callable from the console at any time
-- and in any order, because this module is tested by hand as well as by the
-- headless harness. Nothing in this file may throw: a call that cannot do
-- anything sensible returns nil, false or zero instead of raising.

local config = require("scripts.config")
local util = require("scripts.util")
local rail_infra = require("scripts.rail_infra")

local train_manager = {}

-- Rolling stock is 6 tiles long and needs a 1 tile coupling gap, so consecutive
-- stock centres sit 7 tiles apart. That is arithmetic rather than something the
-- headless probes confirmed, so placement retries at the wider spacings before
-- giving up; a wider spacing leaves the stock uncoupled but still recoverable,
-- which beats failing to spawn a train at all.
local SPACINGS = { 7, 8, 9, 10 }
local STOCK_SPACING = SPACINGS[1]

-- A train stopped at an east facing stop lines its leading edge up with the stop
-- marker, so the leading stock centre sits half a stock length west of it.
local STOP_FRONT_OFFSET = 3

-- How close the nearest stock has to be to the stop before a train counts as
-- parked when the engine has not published train.station yet. One stock length,
-- which is tight enough that a train passing through cannot satisfy it while
-- also standing still.
local STATION_TOLERANCE = 6

-- How far from the east end to look for a rail to use as the departure target.
local RAIL_SEARCH_RADIUS = 16

-- Speed, in tiles per tick, used when a train has to be pushed east by hand
-- because the schedule refused a rail target. Roughly 130 km/h.
local MANUAL_DEPART_SPEED = 0.6

-- The cycle state machine, not the train, decides when the tax train leaves, so
-- the wait condition on the station record exists only as a backstop: if the
-- scenario ever loses its own timer the train still releases the station instead
-- of parking on it forever.
local HOLD_TICKS = config.LOADING_WINDOW + config.ARRIVAL_TIMEOUT + config.DEPART_TIMEOUT

local STOCK_NAMES = { "locomotive", "cargo-wagon", "fluid-wagon" }

-- Resolved rolling stock for the tracked train. This is derived state, so it
-- lives in a module local rather than in storage: after a load it costs one
-- surface scan to rebuild, and keeping it out of storage means there is one
-- fewer thing that can disagree with the unit numbers the schema owns.
local cache = { locos = {}, wagons = {}, scanned_tick = nil }

-- State access ---------------------------------------------------------------

--- The persistent tax state, creating only the tables this module touches so a
--- half populated load, or a console call before the rest of the scenario has
--- run, cannot turn into an index-a-nil error.
local function ensure_state()
  if type(storage) ~= "table" then return nil end
  storage.taxes = storage.taxes or {}
  local taxes = storage.taxes
  taxes.infra = taxes.infra or {}
  -- util.protect writes into this set, so it has to exist before any placement.
  taxes.infra.entities = taxes.infra.entities or {}
  taxes.train = taxes.train or {}
  taxes.train.loco_unit_numbers = taxes.train.loco_unit_numbers or {}
  taxes.train.wagon_unit_numbers = taxes.train.wagon_unit_numbers or {}
  return taxes
end

-- Geometry -------------------------------------------------------------------

--- Accept either MapPosition shape and return the table form, or nil.
local function normalise(position)
  if type(position) ~= "table" then return nil end
  local x = position.x or position[1]
  local y = position.y or position[2]
  if type(x) ~= "number" or type(y) ~= "number" then return nil end
  return { x = x, y = y }
end

--- Ask rail_infra first, fall back to the recorded state, and finally to the
--- geometry config implies. Any of the three can be missing when a tester calls
--- into this module before the infrastructure has been built.
local function line_end(getter, stored_key, default_x)
  local ok, position = pcall(getter)
  local resolved = ok and normalise(position) or nil
  if resolved then return resolved end

  local taxes = storage.taxes
  resolved = taxes and taxes.infra and normalise(taxes.infra[stored_key]) or nil
  if resolved then return resolved end

  return { x = default_x, y = config.RAIL_Y }
end

local function west_end()
  return line_end(rail_infra.west_end, "west_end", -config.RAIL_HALF_LENGTH + 1)
end

local function east_end()
  return line_end(rail_infra.east_end, "east_end", config.RAIL_HALF_LENGTH - 1)
end

--- MapPosition of the tax station, or nil if nothing knows where it is.
local function station_position()
  local ok, stop = pcall(rail_infra.station)
  if ok and stop and stop.valid then
    local position = normalise(stop.position)
    if position then return position end
  end
  local taxes = storage.taxes
  return taxes and taxes.infra and normalise(taxes.infra.stop_position) or nil
end

--- Squared distance, so the hot paths never need a square root.
local function distance_squared(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Entity resolution ----------------------------------------------------------

--- True when the cached entity lists still match the recorded unit numbers.
local function cache_matches(record)
  if #cache.locos ~= #record.loco_unit_numbers then return false end
  if #cache.wagons ~= #record.wagon_unit_numbers then return false end
  for index, entity in ipairs(cache.locos) do
    if not entity.valid then return false end
    if entity.unit_number ~= record.loco_unit_numbers[index] then return false end
  end
  for index, entity in ipairs(cache.wagons) do
    if not entity.valid then return false end
    if entity.unit_number ~= record.wagon_unit_numbers[index] then return false end
  end
  return true
end

--- Every rolling stock entity on the surface, keyed by unit number.
local function scan_stock(surface)
  local found = {}
  local ok, entities = pcall(function()
    return surface.find_entities_filtered({ name = STOCK_NAMES })
  end)
  if not (ok and type(entities) == "table") then return found end
  for _, entity in pairs(entities) do
    if entity.valid and entity.unit_number then found[entity.unit_number] = entity end
  end
  return found
end

--- The tracked locomotives and wagons as LuaEntity arrays, in recorded order.
--- Rebuilds from the unit numbers after a load or after anything was destroyed,
--- at most once per tick so a permanently broken record cannot become a scan
--- every call.
local function resolve()
  local taxes = ensure_state()
  if not taxes then return {}, {} end
  local record = taxes.train

  if cache_matches(record) then return cache.locos, cache.wagons end
  if cache.scanned_tick == game.tick then return cache.locos, cache.wagons end

  cache.scanned_tick = game.tick
  cache.locos, cache.wagons = {}, {}

  local surface = util.surface()
  if not (surface and surface.valid) then return cache.locos, cache.wagons end

  local by_unit = scan_stock(surface)
  for _, unit_number in ipairs(record.loco_unit_numbers) do
    local entity = by_unit[unit_number]
    if entity then cache.locos[#cache.locos + 1] = entity end
  end
  for _, unit_number in ipairs(record.wagon_unit_numbers) do
    local entity = by_unit[unit_number]
    if entity then cache.wagons[#cache.wagons + 1] = entity end
  end
  return cache.locos, cache.wagons
end

--- The LuaTrain the tracked stock belongs to, or nil. Resolved through an
--- entity rather than through the stored id, because an entity reference stays
--- authoritative even if the train was split and renumbered.
local function get_train()
  local locos, wagons = resolve()
  for _, list in ipairs({ locos, wagons }) do
    for _, entity in ipairs(list) do
      if entity.valid then
        local ok, train = pcall(function() return entity.train end)
        if ok and train and train.valid then return train end
      end
    end
  end
  return nil
end

-- Composition ----------------------------------------------------------------

--- Fluid entries carry kind = "fluid", but a demand typed at the console might
--- omit it, so fall back to asking the prototype list.
local function is_fluid_entry(entry)
  if entry.kind == "fluid" then return true end
  if entry.kind == "item" then return false end
  local ok, proto = pcall(function() return prototypes.fluid[entry.name] end)
  return ok and proto ~= nil
end

--- Spread `slots` filter slots over the demanded items by largest remainder, so
--- the filters mirror each item's share of the required stacks as closely as
--- whole slots allow and every demanded item keeps at least one slot.
local function allocate_slots(items, total_stacks, slots)
  local allocation, used = {}, 0
  for index, item in ipairs(items) do
    local exact = slots * item.stacks / total_stacks
    allocation[index] = math.floor(exact)
    item.remainder = exact - allocation[index]
    used = used + allocation[index]
  end

  -- An item that rounded down to nothing would be impossible to pay, so give it
  -- a slot up front and reclaim that slot from the largest allocation.
  if slots >= #items then
    for index = 1, #items do
      if allocation[index] < 1 then
        allocation[index] = 1
        used = used + 1
      end
    end
    while used > slots do
      local largest = 1
      for index = 2, #items do
        if allocation[index] > allocation[largest] then largest = index end
      end
      if allocation[largest] <= 1 then break end
      allocation[largest] = allocation[largest] - 1
      used = used - 1
    end
  end

  -- Hand the remaining slots to the largest fractional parts. The tie break on
  -- index keeps the result independent of table.sort's internal ordering, which
  -- matters because every player has to compute the same filters.
  local order = {}
  for index = 1, #items do order[index] = index end
  table.sort(order, function(a, b)
    if items[a].remainder ~= items[b].remainder then return items[a].remainder > items[b].remainder end
    return a < b
  end)

  local cursor = 1
  while used < slots and #order > 0 do
    local index = order[cursor]
    allocation[index] = allocation[index] + 1
    used = used + 1
    cursor = cursor % #order + 1
  end

  return allocation
end

--- Work out the train a demand needs. Safe to call with nil, an empty table or
--- a partially filled demand; it always returns a usable composition.
-- @return table { locomotives, cargo_wagons, fluid_wagons, wagons, filters }
--   where filters is one item name per cargo wagon slot, front wagon first.
function train_manager.compose(demand)
  local items, total_stacks, fluid_wagons = {}, 0, 0

  if type(demand) == "table" then
    for _, entry in pairs(demand) do
      if type(entry) == "table" and type(entry.name) == "string" then
        local count = tonumber(entry.count) or 0
        if count > 0 then
          if is_fluid_entry(entry) then
            -- A fluid wagon cannot mix two fluids, so every distinct fluid entry
            -- claims a wagon of its own before capacity is considered at all.
            fluid_wagons = fluid_wagons + math.max(1, math.ceil(count / config.FLUID_WAGON_CAPACITY))
          else
            local stacks = math.max(1, math.ceil(count / util.stack_size(entry.name)))
            items[#items + 1] = { name = entry.name, stacks = stacks }
            total_stacks = total_stacks + stacks
          end
        end
      end
    end
  end

  local cargo_wagons = math.ceil(total_stacks / config.CARGO_WAGON_SLOTS)
  if cargo_wagons + fluid_wagons < 1 then
    -- An empty or unreadable demand still gets a one wagon train so the rest of
    -- the cycle has something to drive to the station.
    cargo_wagons = 1
  end

  local filters = {}
  local slots = cargo_wagons * config.CARGO_WAGON_SLOTS
  if #items > 0 and slots > 0 and total_stacks > 0 then
    local allocation = allocate_slots(items, total_stacks, slots)
    for index, item in ipairs(items) do
      for _ = 1, allocation[index] do filters[#filters + 1] = item.name end
    end
    -- Belt and braces: the invariant the design asks for is that no slot is ever
    -- left unfiltered, so pad rather than trust the arithmetic above.
    while #filters < slots do filters[#filters + 1] = items[1].name end
  end

  local wagons = cargo_wagons + fluid_wagons
  return {
    locomotives = math.max(1, math.ceil(wagons / config.WAGONS_PER_LOCO)),
    cargo_wagons = cargo_wagons,
    fluid_wagons = fluid_wagons,
    wagons = wagons,
    filters = filters,
  }
end

-- Placement ------------------------------------------------------------------

--- Prototype names of every stock in the train, front (east) to back (west).
--- Locomotives come first because the train travels east, so the front of the
--- train is its east end.
local function stock_order(comp)
  local order = {}
  for _ = 1, comp.locomotives do order[#order + 1] = "locomotive" end
  for _ = 1, comp.cargo_wagons do order[#order + 1] = "cargo-wagon" end
  for _ = 1, comp.fluid_wagons do order[#order + 1] = "fluid-wagon" end
  return order
end

--- One placement attempt at a fixed spacing. All or nothing: a partial train
--- would be worse than none, so anything already built is removed on failure.
local function build_attempt(surface, force, order, front_x, y, spacing)
  local created = {}
  for index, name in ipairs(order) do
    local position = { x = front_x - (index - 1) * spacing, y = y }
    local entity
    local ok, result = pcall(function()
      return surface.create_entity({
        name = name,
        position = position,
        direction = defines.direction.east,
        force = force,
      })
    end)
    if ok then entity = result end

    if not (entity and entity.valid) then
      log(string.format("[taxes] could not place %s at %.1f,%.1f (spacing %d), retrying wider",
        name, position.x, position.y, spacing))
      for _, made in ipairs(created) do
        if made.valid then made.destroy() end
      end
      return nil
    end
    created[#created + 1] = entity
  end
  return created
end

--- Place a whole train, widening the stock spacing if the game refuses a
--- position. Returns the created entities front to back plus the spacing used,
--- or nil if every spacing failed.
-- @param anchor_mode string "front" pins the leading stock at anchor_x,
--   "tail" pins the last stock there so the train grows east from that point.
local function build_train(surface, force, comp, anchor_mode, anchor_x, y)
  local order = stock_order(comp)
  for _, spacing in ipairs(SPACINGS) do
    local front_x = anchor_x
    if anchor_mode == "tail" then front_x = anchor_x + (#order - 1) * spacing end
    local created = build_attempt(surface, force, order, math.floor(front_x + 0.5), y, spacing)
    if created then
      if spacing ~= STOCK_SPACING then
        log("[taxes] tax train placed at fallback spacing " .. spacing ..
          "; stock may not have coupled into a single train")
      end
      return created, spacing
    end
  end
  return nil
end

--- Hand an entity to rail_infra so it is registered as immutable, falling back
--- to util.protect if that module is not loaded or rejects the call. Either way
--- the entity ends up recorded in storage.taxes.infra.entities.
local function protect(entity, operable)
  local ok = pcall(rail_infra.protect_entity, entity, operable)
  if not ok then util.protect(entity, operable) end
end

--- Filter every slot of every cargo wagon. Each set_filter is guarded on its own
--- so one bad prototype name cannot leave the rest of the train wide open.
local function apply_filters(wagons, filters)
  if type(filters) ~= "table" or #filters == 0 then return end
  local cursor = 1
  for _, wagon in ipairs(wagons) do
    if wagon.valid and wagon.name == "cargo-wagon" then
      local ok, inventory = pcall(function()
        return wagon.get_inventory(defines.inventory.cargo_wagon)
      end)
      if ok and inventory and inventory.valid then
        for slot = 1, #inventory do
          -- Reusing the first filter if the list runs short keeps the invariant
          -- that no slot is left open even when a wagon reports more slots than
          -- config.CARGO_WAGON_SLOTS claims.
          local name = filters[cursor] or filters[1]
          cursor = cursor + 1
          pcall(function() inventory.set_filter(slot, name) end)
        end
      end
    end
  end
end

--- Point a train at the tax station and hand it back to the automatic driver.
local function set_station_schedule(train)
  if not (train and train.valid) then return false end
  local ok, schedule = pcall(function() return train.get_schedule() end)
  if not (ok and schedule) then return false end

  local applied = pcall(function()
    schedule.clear_records()
    schedule.add_record({
      station = config.STATION_NAME,
      wait_conditions = { { type = "time", compare_type = "or", ticks = HOLD_TICKS } },
    })
  end)
  if not applied then return false end

  pcall(function() schedule.go_to_station(1) end)
  pcall(function() train.manual_mode = false end)
  return true
end

--- Protect, filter, schedule and record a freshly built train.
-- @return LuaTrain|nil
local function commission(taxes, comp, created)
  local locos, wagons = {}, {}
  for index, entity in ipairs(created) do
    if index <= comp.locomotives then
      -- Locomotives are not operable, so the player cannot rewrite the schedule.
      protect(entity, false)
      locos[#locos + 1] = entity
    else
      -- Wagons stay operable; paying the tax means inserting into them.
      protect(entity, true)
      wagons[#wagons + 1] = entity
    end
  end

  apply_filters(wagons, comp.filters)

  local train = nil
  for _, entity in ipairs(locos) do
    if entity.valid then
      local ok, resolved = pcall(function() return entity.train end)
      if ok and resolved and resolved.valid then
        train = resolved
        break
      end
    end
  end

  set_station_schedule(train)

  local loco_unit_numbers, wagon_unit_numbers = {}, {}
  for _, entity in ipairs(locos) do loco_unit_numbers[#loco_unit_numbers + 1] = entity.unit_number end
  for _, entity in ipairs(wagons) do wagon_unit_numbers[#wagon_unit_numbers + 1] = entity.unit_number end

  taxes.train = {
    loco_unit_numbers = loco_unit_numbers,
    wagon_unit_numbers = wagon_unit_numbers,
    train_id = train and train.id or nil,
    -- Module private: set once depart() has released the train eastwards, so
    -- check_despawn knows a hand pushed train still needs nudging.
    departing = false,
  }
  cache.locos, cache.wagons, cache.scanned_tick = locos, wagons, game.tick

  return train
end

--- Trim a composition so the train physically fits between the two ends of the
--- line. This should never fire with the shipped config; it exists because a
--- server owner can shorten RAIL_HALF_LENGTH without touching the demand caps.
local function fit_to_line(comp, west, east)
  local span = math.abs(east.x - west.x) - config.DESPAWN_RADIUS
  local capacity = math.floor(span / STOCK_SPACING)
  if capacity < 2 then capacity = 2 end

  local total = comp.locomotives + comp.wagons
  if total <= capacity then return comp end

  log("[taxes] tax train of " .. total .. " stock does not fit a " .. math.floor(span) ..
    " tile line, trimming to " .. capacity)

  -- Drop wagons from the back, fluid first, until the whole train fits. The
  -- locomotive count is re-derived because it depends on the wagon count.
  while comp.locomotives + comp.wagons > capacity and comp.wagons > 1 do
    if comp.fluid_wagons > 0 then
      comp.fluid_wagons = comp.fluid_wagons - 1
    else
      comp.cargo_wagons = comp.cargo_wagons - 1
    end
    comp.wagons = comp.cargo_wagons + comp.fluid_wagons
    comp.locomotives = math.max(1, math.ceil(comp.wagons / config.WAGONS_PER_LOCO))
  end

  local slots = comp.cargo_wagons * config.CARGO_WAGON_SLOTS
  while #comp.filters > slots do comp.filters[#comp.filters] = nil end
  return comp
end

-- Public interface -----------------------------------------------------------

--- Build the tax train at the west end and send it to the station.
-- @param demand table|nil defaults to the current cycle's demand
-- @return LuaTrain|nil nil if the train could not be placed
function train_manager.spawn(demand)
  local taxes = ensure_state()
  if not taxes then return nil end

  -- A leftover train from an interrupted cycle would sit on the line and block
  -- the new one, and a tester calling spawn twice should not leak stock.
  train_manager.destroy()

  -- Cheap when the line already exists, and it means a console spawn works on a
  -- save where the infrastructure was somehow lost.
  pcall(rail_infra.ensure)

  local surface = util.surface()
  if not (surface and surface.valid) then
    log("[taxes] tax train spawn aborted: surface " .. tostring(config.SURFACE_NAME) .. " is missing")
    return nil
  end

  local west, east = west_end(), east_end()
  local comp = fit_to_line(train_manager.compose(demand or taxes.demand), west, east)

  local created = build_train(surface, util.player_force(), comp, "tail", west.x, west.y)
  if not created then
    log("[taxes] tax train could not be placed at any spacing near " .. west.x .. "," .. west.y)
    util.announce({ "taxes.train-spawn-failed" })
    return nil
  end

  local train = commission(taxes, comp, created)
  util.announce({ "taxes.train-arriving", comp.locomotives, comp.cargo_wagons, comp.fluid_wagons },
    "utility/new_objective")
  return train
end

--- Is a live tax train currently tracked?
function train_manager.has_train()
  return get_train() ~= nil
end

--- Has the tax train arrived and come to a stand at the tax station?
function train_manager.at_station()
  local train = get_train()
  if not train then return false end

  local ok, stop = pcall(function() return train.station end)
  if ok and stop and stop.valid then
    local taxes = storage.taxes
    local expected = taxes and taxes.infra and taxes.infra.stop_unit_number
    if stop.unit_number == expected or stop.backer_name == config.STATION_NAME then
      return true
    end
  end

  -- A force placed train is standing on the station before the engine has had a
  -- chance to publish train.station, so fall back to geometry.
  local position = station_position()
  if not position then return false end

  local moving = true
  local speed_ok, speed = pcall(function() return train.speed end)
  if speed_ok and type(speed) == "number" then moving = math.abs(speed) > 0.01 end
  if moving then return false end

  local locos, wagons = resolve()
  for _, list in ipairs({ locos, wagons }) do
    for _, entity in ipairs(list) do
      if entity.valid and distance_squared(entity.position, position) <= STATION_TOLERANCE * STATION_TOLERANCE then
        return true
      end
    end
  end
  return false
end

--- Failsafe for a train that never arrived: remove it and rebuild it already
--- parked at the station, so a pathing failure can never stall the cycle.
-- @return LuaTrain|nil
function train_manager.force_to_station()
  local taxes = ensure_state()
  if not taxes then return nil end

  local position = station_position()
  if not position then
    log("[taxes] force_to_station aborted: no tax station position is known")
    return nil
  end

  local surface = util.surface()
  if not (surface and surface.valid) then
    log("[taxes] force_to_station aborted: surface " .. tostring(config.SURFACE_NAME) .. " is missing")
    return nil
  end

  train_manager.destroy()
  pcall(rail_infra.ensure)

  local west, east = west_end(), east_end()
  local comp = fit_to_line(train_manager.compose(taxes.demand), west, east)

  -- The stop sits beside the line, so the train goes on the rail's y, not the
  -- stop's. Anchoring the leading stock a half stock length west of the marker
  -- puts it where the automatic driver would have parked it anyway.
  local created = build_train(surface, util.player_force(), comp, "front",
    position.x - STOP_FRONT_OFFSET, west.y)
  if not created then
    log("[taxes] force_to_station could not place a train at the station")
    util.announce({ "taxes.train-spawn-failed" })
    return nil
  end

  local train = commission(taxes, comp, created)
  util.announce({ "taxes.train-forced" })
  return train
end

--- Everything currently sitting in the tax wagons, as name -> amount. Items and
--- fluids share the map; nothing demands both under one name.
function train_manager.contents()
  local result = {}
  local _, wagons = resolve()

  for _, wagon in ipairs(wagons) do
    if wagon.valid then
      if wagon.name == "cargo-wagon" then
        local got, inventory = pcall(function()
          return wagon.get_inventory(defines.inventory.cargo_wagon)
        end)
        if got and inventory and inventory.valid then
          local ok, listing = pcall(function() return inventory.get_contents() end)
          if ok and type(listing) == "table" then
            for key, value in pairs(listing) do
              -- 2.0 returns an array of {name, count, quality}; accept the older
              -- name -> count shape too so this cannot silently read as empty.
              if type(value) == "table" and type(value.name) == "string" then
                result[value.name] = (result[value.name] or 0) + (tonumber(value.count) or 0)
              elseif type(key) == "string" and type(value) == "number" then
                result[key] = (result[key] or 0) + value
              end
            end
          end
        end
      elseif wagon.name == "fluid-wagon" then
        local ok, fluids = pcall(function() return wagon.get_fluid_contents() end)
        if ok and type(fluids) == "table" then
          for name, amount in pairs(fluids) do
            if type(name) == "string" and type(amount) == "number" then
              result[name] = (result[name] or 0) + amount
            end
          end
        end
      end
    end
  end

  return result
end

--- Take up to `wanted` of an item out of the cargo wagons.
local function take_item(wagons, name, wanted)
  local taken = 0
  for _, wagon in ipairs(wagons) do
    if taken >= wanted then break end
    if wagon.valid and wagon.name == "cargo-wagon" then
      local got, inventory = pcall(function()
        return wagon.get_inventory(defines.inventory.cargo_wagon)
      end)
      if got and inventory and inventory.valid then
        local ok, removed = pcall(function()
          return inventory.remove({ name = name, count = wanted - taken })
        end)
        if ok and type(removed) == "number" then taken = taken + removed end
      end
    end
  end
  return taken
end

--- Take up to `wanted` of a fluid out of the fluid wagons.
local function take_fluid(wagons, name, wanted)
  local taken = 0
  for _, wagon in ipairs(wagons) do
    if taken >= wanted then break end
    if wagon.valid and wagon.name == "fluid-wagon" then
      local ok, removed = pcall(function()
        return wagon.remove_fluid({ name = name, amount = wanted - taken })
      end)
      if ok and type(removed) == "number" then taken = taken + removed end
    end
  end
  -- Fluid amounts are floats, so a full delivery can read back as 999.9999.
  -- Round before that turns into a phantom shortfall.
  local rounded = math.floor(taken + 0.5)
  if rounded > wanted then rounded = wanted end
  return rounded
end

--- Put `amount` of a demand entry into the tax wagons. Exists so a tester can
--- part-fill a train from the console and exercise the shortfall path without
--- hauling anything by hand.
-- @return number how much was actually accepted, 0 if there is nowhere to put it
function train_manager.insert(entry, amount)
  if type(entry) ~= "table" or type(entry.name) ~= "string" then return 0 end
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return 0 end

  local _, wagons = resolve()
  if #wagons == 0 then return 0 end

  local inserted = 0
  if is_fluid_entry(entry) then
    for _, wagon in ipairs(wagons) do
      if inserted >= amount then break end
      if wagon.valid and wagon.name == "fluid-wagon" then
        -- insert_fluid already stops at the wagon's own capacity and refuses a
        -- wagon holding a different fluid, which is exactly the per-wagon cap
        -- and the no-mixing rule the composition assumed.
        local room = math.min(amount - inserted, config.FLUID_WAGON_CAPACITY)
        local ok, accepted = pcall(function()
          return wagon.insert_fluid({ name = entry.name, amount = room })
        end)
        if ok and type(accepted) == "number" then inserted = inserted + accepted end
      end
    end
    inserted = math.floor(inserted + 0.5)
  else
    for _, wagon in ipairs(wagons) do
      if inserted >= amount then break end
      if wagon.valid and wagon.name == "cargo-wagon" then
        local got, inventory = pcall(function()
          return wagon.get_inventory(defines.inventory.cargo_wagon)
        end)
        if got and inventory and inventory.valid then
          -- LuaInventory.insert honours slot filters, so a wagon with no slots
          -- filtered for this item simply accepts nothing and we move on.
          local ok, accepted = pcall(function()
            return inventory.insert({ name = entry.name, count = amount - inserted })
          end)
          if ok and type(accepted) == "number" then inserted = inserted + accepted end
        end
      end
    end
  end

  if inserted > amount then inserted = amount end
  return inserted
end

--- Settle the cycle: bank what was delivered and report what was not.
-- @param demand table|nil defaults to the current cycle's demand
-- @return number shortfall in [0, 1]; 0 for an empty demand, never a division
--   by zero, and 1 when the train is gone and nothing could be collected
function train_manager.settle(demand)
  local taxes = ensure_state()
  demand = demand or (taxes and taxes.demand)
  if type(demand) ~= "table" then return 0 end

  local _, wagons = resolve()
  local demanded_total, delivered_total = 0, 0

  for _, entry in pairs(demand) do
    if type(entry) == "table" and type(entry.name) == "string" then
      local count = tonumber(entry.count) or 0
      if count > 0 then
        demanded_total = demanded_total + count
        -- Read and remove per entry rather than from a snapshot, so a demand
        -- that lists the same name twice cannot be paid once and counted twice.
        local delivered
        if is_fluid_entry(entry) then
          delivered = take_fluid(wagons, entry.name, count)
        else
          delivered = take_item(wagons, entry.name, count)
        end
        if delivered > count then delivered = count end
        entry.delivered = delivered
        delivered_total = delivered_total + delivered
      else
        entry.delivered = tonumber(entry.delivered) or 0
      end
    end
  end

  -- A demand that asks for nothing is trivially paid in full.
  if demanded_total <= 0 then return 0 end

  local shortfall = 1 - delivered_total / demanded_total
  if shortfall < 0 then shortfall = 0 end
  if shortfall > 1 then shortfall = 1 end
  return shortfall
end

--- Push a train east by hand. Used when the schedule will not take a rail
--- target; train.speed is positive toward front_stock, so which sign means east
--- depends on which end of the train is currently leading.
local function push_east(train)
  if not (train and train.valid) then return false end
  return pcall(function()
    train.manual_mode = true
    local front, back = train.front_stock, train.back_stock
    local direction = 1
    if front and back and front.valid and back.valid and front.position.x < back.position.x then
      direction = -1
    end
    train.speed = MANUAL_DEPART_SPEED * direction
  end)
end

--- The rail closest to a point, or nil if the line is not there.
local function nearest_rail(surface, position)
  local ok, rails = pcall(function()
    return surface.find_entities_filtered({
      name = "straight-rail",
      position = position,
      radius = RAIL_SEARCH_RADIUS,
    })
  end)
  if not (ok and type(rails) == "table") then return nil end

  local best, best_distance
  for _, rail in pairs(rails) do
    if rail.valid then
      local distance = distance_squared(rail.position, position)
      if not best_distance or distance < best_distance then
        best, best_distance = rail, distance
      end
    end
  end
  return best
end

--- Retarget the schedule to the east end so the train leaves the station.
-- @return boolean whether anything was actually set in motion
function train_manager.depart()
  local taxes = ensure_state()
  local train = get_train()
  if not train then return false end

  local east = east_end()
  local surface = util.surface()
  local moving = false

  if surface and surface.valid then
    local rail = nearest_rail(surface, east)
    if rail then
      moving = pcall(function()
        local schedule = train.get_schedule()
        schedule.clear_records()
        schedule.add_record({ rail = rail, temporary = true })
        schedule.go_to_station(1)
        train.manual_mode = false
      end)
    end
  end

  if not moving then
    -- A rail targeted schedule record is the one part of the 2.0 schedule API
    -- the probes never exercised, so if it is rejected the train is driven east
    -- by hand instead and check_despawn keeps it rolling.
    log("[taxes] departure schedule rejected near " .. east.x .. "," .. east.y .. ", pushing the train east by hand")
    moving = push_east(train)
  end

  if taxes then taxes.train.departing = true end
  if moving then util.announce({ "taxes.train-departing" }) end
  return moving
end

--- Destroy the train once it is close enough to the east end.
-- @return boolean true when there is no longer a train to worry about, false
--   while it is still travelling
function train_manager.check_despawn()
  local taxes = ensure_state()
  local train = get_train()
  if not train then
    -- Nothing tracked, so there is nothing left to despawn.
    return true
  end

  local east = east_end()
  local locos, wagons = resolve()

  local closest
  for _, list in ipairs({ locos, wagons }) do
    for _, entity in ipairs(list) do
      if entity.valid then
        local distance = distance_squared(entity.position, east)
        if not closest or distance < closest then closest = distance end
      end
    end
  end

  if not closest then
    -- The record points at stock that no longer exists; clear it out.
    train_manager.destroy()
    return true
  end

  if closest <= config.DESPAWN_RADIUS * config.DESPAWN_RADIUS then
    train_manager.destroy()
    return true
  end

  -- Keep a hand pushed departure rolling; friction would otherwise stall it
  -- short of the east end. An automatically driven train is never in manual
  -- mode, so this cannot fight the schedule.
  if taxes and taxes.train.departing then
    pcall(function()
      if train.manual_mode and math.abs(train.speed) < 0.05 then push_east(train) end
    end)
  end

  return false
end

--- Remove any tracked tax train and forget it. Safe to call when there is none.
-- @return number how many entities were destroyed
function train_manager.destroy()
  local taxes = ensure_state()
  if not taxes then return 0 end

  local locos, wagons = resolve()
  local removed = 0
  for _, list in ipairs({ locos, wagons }) do
    for _, entity in ipairs(list) do
      if entity.valid then
        -- Stop guarding it before it goes, otherwise the unit number lingers in
        -- the protected set and can be reused by an unrelated entity later.
        util.unprotect(entity)
        if entity.destroy() then removed = removed + 1 end
      end
    end
  end

  taxes.train = {
    loco_unit_numbers = {},
    wagon_unit_numbers = {},
    train_id = nil,
    departing = false,
  }
  cache.locos, cache.wagons, cache.scanned_tick = {}, {}, nil

  return removed
end

return train_manager
