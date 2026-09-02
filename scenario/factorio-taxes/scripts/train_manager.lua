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
-- stock centres sit 7 tiles apart. The headless probe confirms it: five stock
-- placed at this spacing read back as one train of five carriages. Coupling
-- happens at exactly this distance and nowhere else, so there is no wider
-- spacing to fall back to - retrying at 8, 9 or 10 would not "nearly" couple,
-- it would produce one single car train per stock. A blocked position is
-- retried from an origin shifted along the line instead.
local STOCK_SPACING = 7

-- Offsets, in tiles, applied to the whole layout when a position is blocked.
-- Kept small and even so the train stays on the rails' parity and a train
-- placed at the station is still within STATION_TOLERANCE of the stop.
local PLACEMENT_SHIFTS = { 0, 2, -2, 4, -4 }

-- How much of its assigned fluid a fluid wagon is seeded with when the train is
-- built. A fluid wagon has no fluidbox to filter - #wagon.fluidbox is 0 on
-- 2.0.77 and both get_filter and set_filter raise "index is out of range" - but
-- the engine refuses to mix two fluids in one container, so a wagon holding a
-- trace of a fluid is bound to it for the life of the train. That is the fluid
-- side of the slot filter guarantee, and one unit is all it takes.
local SEED_AMOUNT = 1

-- What a player can actually deliver into a seeded wagon. Composition has to
-- use this rather than the raw capacity, otherwise a demand of exactly four
-- wagonloads is one unit short of payable and fires a wave over the seed.
local USABLE_FLUID_CAPACITY = config.FLUID_WAGON_CAPACITY - SEED_AMOUNT

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
  -- departing and fluid_seeds are this module's own fields and postdate the
  -- first saves, so a load from an older revision arrives without them.
  -- Normalising them here is what lets every read treat them as a plain boolean
  -- and a plain table.
  if taxes.train.departing == nil then taxes.train.departing = false end
  taxes.train.fluid_seeds = taxes.train.fluid_seeds or {}
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

  -- A unit number that nothing on the surface answers to is gone for good: the
  -- entity was destroyed, or a save was edited. Leaving it in the record would
  -- keep cache_matches false forever, and that turns this function into an
  -- unfiltered whole-surface search for every piece of rolling stock in the
  -- game, once per tick, for the rest of the phase. So an unresolvable record
  -- prunes itself and the cache is allowed to settle.
  local dropped = 0
  for _, field in ipairs({ "loco_unit_numbers", "wagon_unit_numbers" }) do
    local resolved = field == "loco_unit_numbers" and cache.locos or cache.wagons
    local kept = {}
    for _, unit_number in ipairs(record[field]) do
      local entity = by_unit[unit_number]
      if entity then
        resolved[#resolved + 1] = entity
        kept[#kept + 1] = unit_number
      else
        dropped = dropped + 1
      end
    end
    record[field] = kept
  end

  if dropped > 0 then
    log("[taxes] " .. dropped .. " piece(s) of tax rolling stock no longer exist; forgetting them")
  end
  return cache.locos, cache.wagons
end

--- The LuaTrain the tracked stock belongs to, or nil. Resolved through an
--- entity rather than through the stored id, because an entity reference stays
--- authoritative even if the train was split and renumbered.
local function get_train()
  local taxes = ensure_state()
  local locos, wagons = resolve()
  for _, list in ipairs({ locos, wagons }) do
    for _, entity in ipairs(list) do
      if entity.valid then
        local ok, train = pcall(function() return entity.train end)
        if ok and train and train.valid then
          -- The schema owns train_id, and a train that was split and recoupled
          -- comes back under a new one, so keep the record honest here rather
          -- than leaving a stale id in the save for a later reader to trust.
          local got, id = pcall(function() return train.id end)
          if taxes and got and taxes.train.train_id ~= id then
            taxes.train.train_id = id
          end
          return train
        end
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

--- The usable entries of a demand, in order. A demand is an array (DESIGN
--- section 3) and ordered iteration is what lets the composition, the fluid
--- wagon filters and insert() agree on which wagon belongs to which entry, so
--- this deliberately walks it with ipairs rather than pairs.
local function demand_entries(demand)
  local entries = {}
  if type(demand) ~= "table" then return entries end
  for _, entry in ipairs(demand) do
    if type(entry) == "table" and type(entry.name) == "string"
        and (tonumber(entry.count) or 0) > 0 then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

--- Which demanded fluid each fluid wagon belongs to, front to back: every fluid
--- entry claims as many consecutive wagons as its volume needs, and no wagon is
--- ever shared. This is the single source of truth for the assignment, so the
--- wagon a fluid is budgeted for, the wagon the engine filters for it, and the
--- wagon insert() puts it in cannot drift apart.
-- @param limit number|nil stop after this many wagons, for when the train that
--   was actually built is shorter than the one the demand asked for
local function fluid_wagon_names(demand, limit)
  local names = {}
  for _, entry in ipairs(demand_entries(demand)) do
    if is_fluid_entry(entry) then
      local count = tonumber(entry.count) or 0
      -- A fluid wagon cannot mix two fluids, so every distinct fluid entry
      -- claims a wagon of its own before capacity is considered at all. What is
      -- left of a wagon once it is seeded is what the player can deliver into
      -- it, so a demand of exactly four wagonloads gets a fifth wagon rather
      -- than being one unit short of payable.
      local needed = math.max(1, math.ceil(count / USABLE_FLUID_CAPACITY))
      for _ = 1, needed do
        if limit and #names >= limit then return names end
        names[#names + 1] = entry.name
      end
    end
  end
  return names
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

--- Re-derive everything that follows from the wagon counts: the fluid wagon
--- total, the locomotive count, and the cargo slot filters. compose() calls it
--- once and every trim calls it again, so a shortened train gets filters sized
--- for the wagons it actually has instead of a truncated copy of the filters
--- the full length train would have had.
local function refresh_composition(comp)
  comp.fluid_filters = comp.fluid_filters or {}
  comp.fluid_wagons = #comp.fluid_filters
  comp.wagons = comp.cargo_wagons + comp.fluid_wagons
  comp.locomotives = math.max(1, math.ceil(comp.wagons / config.WAGONS_PER_LOCO))

  local filters = {}
  local items = comp.items or {}
  local slots = comp.cargo_wagons * config.CARGO_WAGON_SLOTS
  if #items > 0 and slots > 0 and (comp.total_stacks or 0) > 0 then
    local allocation = allocate_slots(items, comp.total_stacks, slots)
    for index, item in ipairs(items) do
      for _ = 1, allocation[index] do filters[#filters + 1] = item.name end
    end
    -- Belt and braces: the invariant the design asks for is that no slot is ever
    -- left unfiltered, so pad rather than trust the arithmetic above.
    while #filters < slots do filters[#filters + 1] = items[1].name end
  end
  comp.filters = filters
end

--- Work out the train a demand needs. Safe to call with nil, an empty table or
--- a partially filled demand; it always returns a usable composition.
-- @return table { locomotives, cargo_wagons, fluid_wagons, wagons, filters,
--   fluid_filters, items, total_stacks } where filters is one item name per
--   cargo wagon slot and fluid_filters one fluid name per fluid wagon, front
--   wagon first in both cases.
function train_manager.compose(demand)
  local items, total_stacks = {}, 0

  for _, entry in ipairs(demand_entries(demand)) do
    if not is_fluid_entry(entry) then
      local count = tonumber(entry.count) or 0
      local stacks = math.max(1, math.ceil(count / util.stack_size(entry.name)))
      items[#items + 1] = { name = entry.name, stacks = stacks }
      total_stacks = total_stacks + stacks
    end
  end

  local fluid_filters = fluid_wagon_names(demand, nil)
  local cargo_wagons = math.ceil(total_stacks / config.CARGO_WAGON_SLOTS)
  if cargo_wagons + #fluid_filters < 1 then
    -- An empty or unreadable demand still gets a one wagon train so the rest of
    -- the cycle has something to drive to the station.
    cargo_wagons = 1
  end

  local comp = {
    cargo_wagons = cargo_wagons,
    fluid_filters = fluid_filters,
    -- Kept on the composition so a trim can rebuild the slot filters, and so it
    -- can tell whether the item half of the demand still has a wagon to go in.
    items = items,
    total_stacks = total_stacks,
  }
  refresh_composition(comp)
  return comp
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

--- Remove stock we created but are not going to keep. Unprotecting first is
--- what stops storage.taxes.infra.entities filling up with the unit numbers of
--- entities that no longer exist, which would otherwise make util.is_tax_entity
--- lie about whatever entity the engine hands that number to next.
local function discard(entities)
  for _, entity in ipairs(entities or {}) do
    if entity and entity.valid then
      pcall(util.unprotect, entity)
      pcall(function() entity.destroy() end)
    end
  end
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
      log(string.format("[taxes] could not place %s at %.1f,%.1f (spacing %d), retrying from a shifted origin",
        name, position.x, position.y, spacing))
      discard(created)
      return nil
    end
    created[#created + 1] = entity
  end
  return created
end

--- The single train every piece of created stock belongs to, or nil if it did
--- not couple. Coupling is the entire reason the spacing is what it is, and it
--- fails silently: the engine hands back one single car train per stock and
--- every later call still works, so it is checked rather than assumed.
local function coupled_train(created)
  for _, entity in ipairs(created) do
    if entity.valid then
      local ok, train = pcall(function() return entity.train end)
      if not (ok and train and train.valid) then return nil end

      local counted, carriages = pcall(function() return train.carriages end)
      if not (counted and type(carriages) == "table") then
        -- The train exists but its carriage list cannot be read, so there is no
        -- evidence either way. Refusing the train over an unreadable property
        -- would cost the cycle its train for no reason; say so and accept it.
        log("[taxes] could not read the carriage list, so the tax train's coupling is unverified")
        return train
      end

      if #carriages < #created then
        log(string.format("[taxes] tax stock did not couple: the train holds %d carriages, %d were placed",
          #carriages, #created))
        return nil
      end
      if #carriages > #created then
        -- Stock that was already on the line coupled onto ours. Everything we
        -- placed is still in one train, which is all this check is about.
        log(string.format("[taxes] the tax train holds %d carriages but only %d of them are ours",
          #carriages, #created))
      end
      return train
    end
  end
  return nil
end

--- Place a whole train at the one spacing that couples, shifting the whole
--- layout along the line if a position is blocked or the stock refuses to
--- couple. Returns the created entities front to back plus the LuaTrain they
--- form, or nil if no attempt produced a single coupled train.
-- @param anchor_mode string "front" pins the leading stock at anchor_x,
--   "tail" pins the last stock there so the train grows east from that point.
-- @param min_x number|nil westmost tile the tail may occupy
-- @param max_x number|nil eastmost tile the front may occupy
local function build_train(surface, force, comp, anchor_mode, anchor_x, y, min_x, max_x)
  local order = stock_order(comp)
  local length = (#order - 1) * STOCK_SPACING

  for _, shift in ipairs(PLACEMENT_SHIFTS) do
    local front_x = anchor_x + shift
    if anchor_mode == "tail" then front_x = front_x + length end
    local tail_x = front_x - length

    -- A layout that runs off the end of the line cannot be placed at all, so do
    -- not spend a create_entity call per stock proving it.
    local in_bounds = (min_x == nil or tail_x >= min_x - 0.5)
      and (max_x == nil or front_x <= max_x + 0.5)

    if in_bounds then
      local created = build_attempt(surface, force, order, math.floor(front_x + 0.5), y, STOCK_SPACING)
      if created then
        local train = coupled_train(created)
        if train then
          if shift ~= 0 then
            log("[taxes] tax train placed " .. shift .. " tiles along the line from the ideal position")
          end
          return created, train
        end
        -- Uncoupled stock is worse than no stock: it cannot be driven, it
        -- cannot be despawned as one train, and it would sit on the line
        -- blocking the next cycle. Take it away before shifting and retrying.
        discard(created)
      end
    end
  end
  return nil
end

--- Hand an entity to rail_infra so it is registered as immutable, falling back
--- to util.protect if that module is not loaded or rejects the call. Either way
--- the entity ends up recorded in storage.taxes.infra.entities.
local function protect(entity, operable)
  if not (entity and entity.valid) then return end
  if pcall(rail_infra.protect_entity, entity, operable) then return end

  -- rail_infra.protect_entity is a thin wrapper over util.protect, so the
  -- fallback is the very call that just failed and can fail the same way. This
  -- runs inside on_tick, where an error takes the whole game down, so guard it
  -- and carry on with an unprotected entity rather than raising.
  if not pcall(util.protect, entity, operable) then
    log("[taxes] could not protect a piece of tax rolling stock; it stays mutable for this cycle")
  end
end

--- Bind a fluid wagon to one fluid at the engine level by seeding it with a
--- trace of that fluid. A fluid wagon exposes no fluidbox to filter, but the
--- engine will not put a second fluid in beside the first, so the seed is the
--- binding: measured on 2.0.77, a wagon holding one unit of light oil rejects
--- 5000 heavy oil outright and still accepts light oil up to capacity.
-- @return number how much was actually seeded, 0 if the wagon refused it
local function seed_fluid_wagon(wagon, name)
  local ok, accepted = pcall(function()
    return wagon.insert_fluid({ name = name, amount = SEED_AMOUNT })
  end)
  if ok and type(accepted) == "number" and accepted > 0 then return accepted end

  -- An unseeded wagon is simply the old, unbound behaviour. That is a worse
  -- cycle, not a broken one, so it is never a reason to abandon the train.
  log("[taxes] could not seed a fluid wagon with " .. tostring(name)
    .. "; it stays unbound and the wrong fluid can still be pumped into it")
  return 0
end

--- The seed recorded against a wagon, as { name, amount }, or nil. Recorded per
--- wagon rather than assumed, so a wagon whose seeding failed is not credited
--- with a unit it never received.
local function seed_record(wagon)
  local taxes = storage.taxes
  local seeds = taxes and taxes.train and taxes.train.fluid_seeds
  if type(seeds) ~= "table" then return nil end

  local got, unit_number = pcall(function() return wagon.unit_number end)
  if not (got and unit_number) then return nil end

  local seed = seeds[unit_number]
  if type(seed) ~= "table" then return nil end
  return seed
end

--- How much of `name` in this wagon is the scenario's own seed rather than
--- something the player delivered. Everything that reads or removes fluid goes
--- through this, so contents(), settle() and insert() cannot disagree about it.
local function seed_in(wagon, name)
  local seed = seed_record(wagon)
  if not (seed and seed.name == name) then return 0 end
  return tonumber(seed.amount) or 0
end

--- Bind the wagons so the tax can only be paid in the demanded currency: every
--- cargo slot filtered to a demanded item, and every fluid wagon seeded with
--- exactly one demanded fluid. Each call is guarded on its own so one bad
--- prototype name cannot leave the rest of the train wide open.
---
--- The fluid half matters as much as the cargo half. A late game demand
--- routinely names two fluids - light oil, heavy oil and lubricant are all tier
--- 6 - and with nothing binding the wagons a player who pumps the first fluid
--- into every one makes the second physically undeliverable and is punished for
--- it through no fault of their own.
-- @return table the seeds actually placed, as [unit_number] = { name, amount }
local function apply_filters(wagons, filters, fluid_filters)
  filters = type(filters) == "table" and filters or {}
  fluid_filters = type(fluid_filters) == "table" and fluid_filters or {}

  local seeds = {}
  local cursor, fluid_index = 1, 0
  for _, wagon in ipairs(wagons) do
    if wagon.valid and wagon.name == "cargo-wagon" and #filters > 0 then
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
    elseif wagon.valid and wagon.name == "fluid-wagon" then
      -- Wagons are created in composition order, so the nth fluid wagon takes
      -- the nth name of the assignment fluid_wagon_names() built.
      fluid_index = fluid_index + 1
      local name = fluid_filters[fluid_index]
      if name then
        local seeded = seed_fluid_wagon(wagon, name)
        local got, unit_number = pcall(function() return wagon.unit_number end)
        if seeded > 0 and got and unit_number then
          seeds[unit_number] = { name = name, amount = seeded }
        end
      end
    end
  end

  return seeds
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
-- @param train LuaTrain|nil the coupled train build_train() resolved
-- @return LuaTrain|nil nil when the train could not be recorded, in which case
--   nothing of it is left on the map
-- Fuels the tax train, best available first. A locomotive with an empty burner
-- reports state on_the_path with a valid path and simply never moves, which is
-- indistinguishable from a pathing failure unless you look at the burner. Every
-- automated test reached the station through force_to_station(), which teleports
-- the train, so an unfuelled train passed the whole suite and then sat still the
-- moment it had to drive itself.
-- Items the world yields without a recipe, so they are available from the first
-- tick. Derived from the resource and tree prototypes rather than hardcoded,
-- and cached because prototypes cannot change while a game is running. On the
-- base game this resolves to coal, wood, and the ores.
local mineable_items

local function mineable_item_set()
  if mineable_items then return mineable_items end

  mineable_items = {}
  for _, proto in pairs(prototypes.entity) do
    if proto.type == "resource" or proto.type == "tree" then
      local mineable = proto.mineable_properties
      if mineable and mineable.products then
        for _, product in pairs(mineable.products) do
          if product.type == "item" then
            mineable_items[product.name] = true
          end
        end
      end
    end
  end
  return mineable_items
end

--- The best fuel this force could actually make for itself right now.
-- The tax train burns what the player has unlocked rather than a fixed choice,
-- so an early game train runs on coal and a late one on nuclear fuel. Nothing
-- here is hardcoded: the accepted categories come from the locomotive's own
-- burner, the candidates from every item with a fuel value, and availability
-- from the force's enabled recipes plus what can simply be mined.
local function best_available_fuel(force)
  local loco_proto = prototypes.entity["locomotive"]
  local burner = loco_proto and loco_proto.burner_prototype
  local categories = burner and burner.fuel_categories
  if not categories then return nil end

  local obtainable = {}
  for name in pairs(mineable_item_set()) do
    obtainable[name] = true
  end
  if force then
    for _, recipe in pairs(force.recipes) do
      if recipe.enabled then
        for _, product in pairs(recipe.products) do
          if product.type == "item" then
            obtainable[product.name] = true
          end
        end
      end
    end
  end

  local best, best_value
  for name, proto in pairs(prototypes.item) do
    local value = proto.fuel_value or 0
    -- A locomotive burns chemical fuel only, so uranium fuel cells are
    -- correctly excluded despite having by far the highest fuel value.
    if value > 0 and categories[proto.fuel_category] and obtainable[name] then
      if not best_value or value > best_value then
        best, best_value = name, value
      end
    end
  end
  return best
end

local function fuel_locomotives(locos, force)
  local fuel_name = best_available_fuel(force)
  if not fuel_name then
    log("[taxes] no usable fuel is available to this force; the tax train cannot "
      .. "move under its own power")
    return
  end

  local stack_size = util.stack_size(fuel_name)
  for _, loco in ipairs(locos) do
    local ok = pcall(function()
      local inventory = loco.get_inventory(defines.inventory.fuel)
      if not inventory then return end
      -- Fill every slot: the train has to reach the station and then drive off
      -- the far end of the line, and it must never strand itself mid-cycle.
      for slot = 1, #inventory do
        if not inventory[slot].valid_for_read then
          inventory[slot].set_stack({ name = fuel_name, count = stack_size })
        end
      end
    end)
    if not ok then
      log("[taxes] could not fuel a tax locomotive with " .. fuel_name)
    end
  end
end

local function commission(taxes, comp, created, train)
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

  -- Fuel before the schedule is set, so the train can act on it immediately.
  fuel_locomotives(locos, util.player_force())

  -- The seeds have to be recorded before anything reads the wagons back, so
  -- contents(), settle() and insert() all know which unit of fluid is ours.
  taxes.train.fluid_seeds = apply_filters(wagons, comp.filters, comp.fluid_filters)
  local fluid_seeds = taxes.train.fluid_seeds

  if not (train and train.valid) then train = coupled_train(created) end
  set_station_schedule(train)

  -- unit_number raises on a dead entity, and this runs inside on_tick where a
  -- raised error takes the whole game down, which is exactly what this file's
  -- header promises never to do. Stock that cannot be recorded cannot be
  -- tracked, despawned or protected either, so the commission is abandoned
  -- whole rather than left half done with orphans on the line.
  local loco_unit_numbers, wagon_unit_numbers = {}, {}
  local recorded = pcall(function()
    for _, entity in ipairs(locos) do loco_unit_numbers[#loco_unit_numbers + 1] = entity.unit_number end
    for _, entity in ipairs(wagons) do wagon_unit_numbers[#wagon_unit_numbers + 1] = entity.unit_number end
  end)

  if not (recorded and #loco_unit_numbers == #locos and #wagon_unit_numbers == #wagons
      and #loco_unit_numbers > 0) then
    log("[taxes] the tax train could not be recorded in state; removing it rather than "
      .. "leaving untracked stock on the line")
    discard(created)
    taxes.train = {
      loco_unit_numbers = {},
      wagon_unit_numbers = {},
      train_id = nil,
      departing = false,
      fluid_seeds = {},
    }
    cache.locos, cache.wagons, cache.scanned_tick = {}, {}, nil
    return nil
  end

  -- id on a dead LuaTrain raises like any other property read, so it goes
  -- through a pcall as well; a missing id costs nothing, get_train() fills it
  -- back in the first time it resolves the train.
  local got_id, train_id = pcall(function() return train and train.valid and train.id or nil end)

  taxes.train = {
    loco_unit_numbers = loco_unit_numbers,
    wagon_unit_numbers = wagon_unit_numbers,
    train_id = got_id and train_id or nil,
    -- Module private: set once depart() has released the train eastwards, so
    -- check_despawn knows a hand pushed train still needs nudging.
    departing = false,
    -- Module private: the trace of fluid each fluid wagon was bound with, so
    -- the scenario's own seed is never mistaken for a player's delivery.
    fluid_seeds = fluid_seeds,
  }
  cache.locos, cache.wagons, cache.scanned_tick = locos, wagons, game.tick

  return train
end

--- How many pieces of stock fit in a span of `span` tiles. Only the gaps
--- between stock cost a spacing, the first one costs nothing, hence the +1.
local function stock_capacity(span, spacing)
  if span < 0 then span = 0 end
  local capacity = math.floor(span / spacing) + 1
  -- One locomotive and one wagon is the shortest train that is any use. A line
  -- with no room even for that is a broken config, and a two stock train that
  -- overhangs slightly is still far better for the cycle than no train at all.
  if capacity < 2 then capacity = 2 end
  return capacity
end

--- Drop one fluid wagon, taking it from whichever fluid has the most wagons, so
--- a fluid never loses its last wagon while another still has a spare.
-- @return boolean whether a wagon was actually dropped
local function drop_fluid_wagon(comp)
  local names = comp.fluid_filters or {}
  if #names == 0 then return false end

  local counts = {}
  for _, name in ipairs(names) do counts[name] = (counts[name] or 0) + 1 end

  local victim, most = nil, 0
  for index = #names, 1, -1 do
    local count = counts[names[index]]
    if count > most then victim, most = index, count end
  end
  if not victim then return false end

  table.remove(names, victim)
  return true
end

--- Trim a composition so the train physically fits the stretch of line it has.
--- This should never fire with the shipped config for a spawn; the failsafe
--- placement at the station has far less line to work with and does rely on it.
local function trim_to_capacity(comp, capacity)
  local total = comp.locomotives + comp.wagons
  if total <= capacity then return comp end

  log("[taxes] a tax train of " .. total .. " stock does not fit the " .. capacity
    .. " stock the line has room for, trimming it")

  -- The item half of the demand needs somewhere to go: trimming the last cargo
  -- wagon away deletes every slot filter with it and leaves the demanded items
  -- physically unpayable, which then punishes the player for a config problem.
  local min_cargo = (#(comp.items or {}) > 0) and 1 or 0

  -- How many wagons the fluids need to keep one each. Anything above that is a
  -- second wagon for a single fluid, which can be given up first because that
  -- fluid is then only part payable rather than not payable at all.
  local distinct_fluids = 0
  local seen = {}
  for _, name in ipairs(comp.fluid_filters or {}) do
    if not seen[name] then
      seen[name] = true
      distinct_fluids = distinct_fluids + 1
    end
  end

  while comp.locomotives + comp.wagons > capacity and comp.wagons > 1 do
    local dropped = false
    if comp.fluid_wagons > distinct_fluids then
      dropped = drop_fluid_wagon(comp)
    elseif comp.cargo_wagons > min_cargo then
      comp.cargo_wagons = comp.cargo_wagons - 1
      dropped = true
    else
      -- Everything above the floors is gone, so a fluid does have to lose its
      -- only wagon now; that is still better than an unplaceable train.
      dropped = drop_fluid_wagon(comp)
      if dropped then distinct_fluids = math.max(0, distinct_fluids - 1) end
    end
    if not dropped then break end
    refresh_composition(comp)
  end

  refresh_composition(comp)
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
  -- The train is assembled eastwards from the west end and has to come to a
  -- stand before the despawn ring at the far end, so that stretch, not the
  -- whole line, is the room it has.
  local comp = trim_to_capacity(train_manager.compose(demand or taxes.demand),
    stock_capacity(math.abs(east.x - west.x) - config.DESPAWN_RADIUS, STOCK_SPACING))

  local created, placed = build_train(surface, util.player_force(), comp, "tail",
    west.x, west.y, west.x, east.x)
  if not created then
    log("[taxes] tax train could not be placed or coupled anywhere near " .. west.x .. "," .. west.y)
    util.announce({ "taxes.train-spawn-failed" })
    return nil
  end

  local train = commission(taxes, comp, created, placed)
  if not train then
    util.announce({ "taxes.train-spawn-failed" })
    return nil
  end

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

  -- The stop sits beside the line, so the train goes on the rail's y, not the
  -- stop's. Anchoring the leading stock a half stock length west of the marker
  -- puts it where the automatic driver would have parked it anyway.
  local front_x = position.x - STOP_FRONT_OFFSET

  -- Everything behind that leading stock grows WEST, so the line between the
  -- station and the west end is the only room this placement has: with the
  -- shipped geometry that is about sixteen stock, and a late cycle train is
  -- longer than that. Putting its tail past the end of the rail used to fail
  -- every attempt and return nil, which left the cycle with no train at all,
  -- settled as a total shortfall and fired a full wave for it. So clamp to what
  -- the rail can actually carry and place a shorter train instead.
  local comp = trim_to_capacity(train_manager.compose(taxes.demand),
    stock_capacity(front_x - west.x, STOCK_SPACING))

  local created, placed = build_train(surface, util.player_force(), comp, "front",
    front_x, west.y, west.x, east.x)

  if not created then
    -- This is the failsafe, so it must not fail quietly itself. Fall back to
    -- the shortest train that is any use, which needs two stock lengths of
    -- clear line and nothing else.
    log("[taxes] force_to_station could not place a " .. (comp.locomotives + comp.wagons)
      .. " stock train at the station; falling back to the shortest possible one")
    comp = trim_to_capacity(train_manager.compose(taxes.demand), 2)
    created, placed = build_train(surface, util.player_force(), comp, "front",
      front_x, west.y, west.x, east.x)
  end

  if not created then
    log("[taxes] force_to_station could not place a train at the station at all")
    util.announce({ "taxes.train-spawn-failed" })
    return nil
  end

  local train = commission(taxes, comp, created, placed)
  if not train then
    util.announce({ "taxes.train-spawn-failed" })
    return nil
  end

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
              -- The seed that binds the wagon to this fluid is the scenario's
              -- own and was never delivered by anybody, so it is not reported.
              -- Otherwise the progress bar would start at one unit filled and a
              -- one unit demand would read as paid before anyone touched it.
              local delivered = amount - seed_in(wagon, name)
              if delivered > 0 then result[name] = (result[name] or 0) + delivered end
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

--- The fluid wagons of a train, in the order they were recorded, which is the
--- order fluid_wagon_names() assigns fluids in.
local function fluid_wagons_of(wagons)
  local list = {}
  for _, wagon in ipairs(wagons) do
    if wagon.valid and wagon.name == "fluid-wagon" then list[#list + 1] = wagon end
  end
  return list
end

--- How much fluid a wagon is already holding, in units. Needed because
--- insert_fluid knows the wagon's capacity but not what an earlier call already
--- put in, and the room left is the difference.
local function fluid_level(wagon)
  local ok, fluids = pcall(function() return wagon.get_fluid_contents() end)
  if not (ok and type(fluids) == "table") then return 0 end

  local total = 0
  for _, amount in pairs(fluids) do
    if type(amount) == "number" then total = total + amount end
  end
  return total
end

--- Which fluid a wagon is bound to: the fluid it was seeded with, otherwise
--- whatever it already holds, otherwise nil for a wagon nothing has claimed.
local function wagon_fluid(wagon)
  local seed = seed_record(wagon)
  if seed and type(seed.name) == "string" then return seed.name end

  -- A wagon with fluid in it and no recorded seed is still spoken for: the
  -- engine will not let a second fluid in beside the first.
  local held_ok, fluids = pcall(function() return wagon.get_fluid_contents() end)
  if held_ok and type(fluids) == "table" then
    for held in pairs(fluids) do
      if type(held) == "string" then return held end
    end
  end
  return nil
end

--- The wagons a fluid may be put into, following the same assignment the seeds
--- were placed from, so a fluid can never spill into the wagon the next demand
--- entry is relying on.
local function wagons_for_fluid(wagons, demand, name)
  local fluid_wagons = fluid_wagons_of(wagons)
  local assignment = fluid_wagon_names(demand, #fluid_wagons)

  local targets, unassigned = {}, {}
  for index, wagon in ipairs(fluid_wagons) do
    -- What the wagon was actually seeded with outranks the assignment
    -- recomputed from the demand: a train trimmed to fit the line carries fewer
    -- wagons than the demand asked for, and the seed is what the engine will
    -- actually enforce.
    local bound = wagon_fluid(wagon) or assignment[index]
    if bound == name then
      targets[#targets + 1] = wagon
    elseif bound == nil then
      unassigned[#unassigned + 1] = wagon
    end
  end

  -- A console call can name a fluid the current demand never asked for. It has
  -- no wagon of its own, so it may use any wagon no demanded fluid claimed.
  if #targets == 0 then return unassigned end
  return targets
end

--- Take up to `wanted` of a fluid out of the fluid wagons. Every wagon is
--- searched rather than only the ones assigned to this fluid: remove_fluid
--- names the fluid it takes, so a wagon assigned elsewhere can only ever give
--- back what belongs to this entry anyway, and a fluid that somehow ended up in
--- the wrong wagon still counts as paid.
---
--- The seed each wagon was bound with is left where it is and never counted as
--- delivered: it is the scenario's own unit, and banking it would let a small
--- demand settle as paid when the player contributed nothing.
local function take_fluid(wagons, name, wanted)
  local taken = 0
  for _, wagon in ipairs(wagons) do
    if taken >= wanted then break end
    if wagon.valid and wagon.name == "fluid-wagon" then
      local held = 0
      local got, amount = pcall(function() return wagon.get_fluid_count(name) end)
      if got and type(amount) == "number" then held = amount end

      local available = held - seed_in(wagon, name)
      if available > 0 then
        local ok, removed = pcall(function()
          return wagon.remove_fluid({ name = name, amount = math.min(wanted - taken, available) })
        end)
        if ok and type(removed) == "number" then taken = taken + removed end
      end
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

  local taxes = ensure_state()
  local _, wagons = resolve()
  if #wagons == 0 then return 0 end

  local inserted = 0
  if is_fluid_entry(entry) then
    for _, wagon in ipairs(wagons_for_fluid(wagons, taxes and taxes.demand, entry.name)) do
      if inserted >= amount then break end
      -- insert_fluid stops at the wagon's own capacity and refuses a wagon
      -- holding a different fluid, but it has no idea what a previous call
      -- already put in there. Asking for a full wagon's worth regardless is
      -- what let a second /tax-fill push a fluid past its demanded total.
      --
      -- The seed counts against the room because it physically occupies it, but
      -- it is never added to `inserted`: what this returns is only ever what
      -- insert_fluid accepted from the caller. Composition already reserves the
      -- seed's unit, so the demand still fits.
      local room = math.min(amount - inserted, config.FLUID_WAGON_CAPACITY - fluid_level(wagon))
      if room > 0 then
        local ok, accepted = pcall(function()
          return wagon.insert_fluid({ name = entry.name, amount = room })
        end)
        if ok and type(accepted) == "number" then inserted = inserted + accepted end
      end
    end
    -- Fluid amounts are floats, so report whole units.
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

  -- Report what actually went in, not what was asked for: a clamp here would
  -- hide an over-insertion instead of preventing one, and the caller prints
  -- this figure back to the tester as the truth about the wagons.
  return inserted
end

--- Whether this demand has already been through settle(). Recorded on each
--- entry rather than as a flag beside them, because a demand is an array and
--- other modules walk it with pairs: a non integer key in there would be picked
--- up as an entry and indexed as one.
local function already_settled(demand)
  local any = false
  for _, entry in ipairs(demand) do
    if type(entry) == "table" and type(entry.name) == "string" then
      any = true
      if not entry.settled then return false end
    end
  end
  return any
end

--- Settle the cycle: bank what was delivered and report what was not.
---
--- Settles a given demand at most once. /tax-settle is a debug command and a
--- tester will run it twice; the second run used to remove the residue of an
--- over-delivered demand all over again, report a shortfall on a cycle that had
--- been paid in full, and fire a punitive wave for it. A repeat call now
--- recomputes the same answer from what was already banked and takes nothing.
-- @param demand table|nil defaults to the current cycle's demand
-- @return number shortfall in [0, 1]; 0 for an empty demand, never a division
--   by zero, and 1 when the train is gone and nothing could be collected
function train_manager.settle(demand)
  local taxes = ensure_state()
  demand = demand or (taxes and taxes.demand)
  if type(demand) ~= "table" then return 0 end

  local settled = already_settled(demand)
  local wagons = {}
  if not settled then
    local _
    _, wagons = resolve()
  end

  -- DESIGN section 7 asks for a shortfall weighted by each entry's share, which
  -- is the mean of the per entry shortfalls and not the ratio of the summed
  -- counts. Items are counted in units and fluids in tens of thousands, so
  -- summing raw counts lets a single fluid entry drown out every item entry: a
  -- demand of 12000 iron plate and 200000 crude oil with the iron skipped
  -- entirely used to read as a 6% shortfall, a one unit wave for half a tax
  -- unpaid. Each entry now carries the same weight whatever its magnitude.
  local entries, shortfall_sum = 0, 0

  for _, entry in ipairs(demand) do
    if type(entry) == "table" and type(entry.name) == "string" then
      local count = tonumber(entry.count) or 0
      if count > 0 then
        local delivered
        if settled then
          -- Nothing more is taken: the figure banked by the first pass is the
          -- answer, so a repeat call cannot punish an already paid cycle.
          delivered = tonumber(entry.delivered) or 0
        elseif is_fluid_entry(entry) then
          -- Read and remove per entry rather than from a snapshot, so a demand
          -- that lists the same name twice cannot be paid once and counted
          -- twice.
          delivered = take_fluid(wagons, entry.name, count)
        else
          delivered = take_item(wagons, entry.name, count)
        end
        if delivered > count then delivered = count end
        if delivered < 0 then delivered = 0 end
        entry.delivered = delivered
        entry.settled = true
        entries = entries + 1
        shortfall_sum = shortfall_sum + (1 - delivered / count)
      else
        entry.delivered = tonumber(entry.delivered) or 0
        entry.settled = true
      end
    end
  end

  -- A demand that asks for nothing is trivially paid in full.
  if entries <= 0 then return 0 end

  local shortfall = shortfall_sum / entries
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

--- Positive evidence that a train is actually going somewhere, rather than that
--- a call about it did not raise. An unpathable schedule is accepted happily
--- and leaves the train standing in no_path, so a pcall around the schedule
--- edit says nothing at all about whether the train left.
local function is_under_way(train)
  if not (train and train.valid) then return false end

  -- Already rolling is the strongest evidence there is, and it is the only kind
  -- a hand pushed train in manual mode offers.
  local speed_ok, speed = pcall(function() return train.speed end)
  if speed_ok and type(speed) == "number" and math.abs(speed) > 0.01 then return true end

  -- Standing still only counts if the automatic driver has somewhere to go. A
  -- train left in manual control, no_path or destination_full does not.
  local manual_ok, manual = pcall(function() return train.manual_mode end)
  if manual_ok and manual == true then return false end

  local path_ok, has_path = pcall(function() return train.has_path end)
  if path_ok and has_path == true then return true end

  local state_ok, state = pcall(function() return train.state end)
  if state_ok and type(state) == "number" and type(defines.train_state) == "table" then
    local states = defines.train_state
    if state == states.on_the_path or state == states.arrive_signal
        or state == states.wait_signal or state == states.arrive_station then
      return true
    end
  end
  return false
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
      local applied = pcall(function()
        local schedule = train.get_schedule()
        schedule.clear_records()
        schedule.add_record({ rail = rail, temporary = true })
        schedule.go_to_station(1)
        train.manual_mode = false
      end)
      -- A schedule the engine accepted is not the same thing as a train that is
      -- leaving: an unreachable target is taken without complaint and the train
      -- sits in no_path on the station for the whole DEPART_TIMEOUT. So ask the
      -- train what it is doing rather than trusting that nothing raised.
      moving = applied and is_under_way(train)
    end
  end

  if not moving then
    -- A rail targeted schedule record is the one part of the 2.0 schedule API
    -- the probes never exercised, so if it is rejected, or accepted and then
    -- unpathable, the train is driven east by hand instead and check_despawn
    -- keeps it rolling.
    log("[taxes] departure schedule did not move the train near " .. east.x .. "," .. east.y
      .. ", pushing it east by hand")
    moving = push_east(train) and is_under_way(train)
  end

  if taxes and taxes.train then taxes.train.departing = true end
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
  -- departing postdates the first saves of this scenario, so it can be nil on a
  -- load from an older revision; nil simply means "was never released".
  if taxes and taxes.train and taxes.train.departing then
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
    fluid_seeds = {},
  }
  cache.locos, cache.wagons, cache.scanned_tick = {}, {}, nil

  return removed
end

return train_manager
