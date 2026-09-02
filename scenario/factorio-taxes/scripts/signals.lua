-- The circuit readout beside the tax station. A constant combinator publishes
-- the upcoming demand as one signal per demanded item or fluid, plus the phase
-- countdown and the cycle number, so the tax can be paid by an automated system
-- wired into the base rather than by hand. See docs/DESIGN.md section 13.
--
-- Nothing in this file may throw. publish() is called from the on_tick handler
-- once a second, where a raised error takes the whole game down, so every API
-- call is guarded and every unusable input is skipped quietly instead.

local util = require("scripts.util")

local signals = {}

local COMBINATOR_NAME = "constant-combinator"

-- The two numbers that are not part of the demand itself. Letter signals are
-- base game virtual signals, so this needs no prototype of its own.
local TIME_SIGNAL = "signal-T"
local CYCLE_SIGNAL = "signal-C"

-- Circuit network values are 32 bit signed. A value outside that range is
-- rejected by the engine, and the rejection costs the whole section rather than
-- the one entry, so everything published is clamped into it first.
local MAX_SIGNAL = 2147483647
local MIN_SIGNAL = -2147483648

-- How far from the recorded station position to look for the combinator when
-- the engine cannot resolve a unit number directly. Deliberately bounded: this
-- runs on a readout that refreshes every second and must never become a scan of
-- the whole surface.
local SEARCH_RADIUS = 8

-- How often the filters are written even when nothing about the demand has
-- changed. The combinator is the one piece of tax infrastructure the player may
-- open, which also means the player can edit its filters; rewriting them on a
-- slow heartbeat is what makes such an edit heal itself rather than stick.
local REPUBLISH_INTERVAL = 10 * 60

-- The resolved combinator. Derived state, like train_manager's rolling stock
-- cache, so it lives in a module local rather than in storage: it costs one
-- lookup to rebuild after a load, and there is then nothing that can disagree
-- with the unit number the schema owns.
local cache = { entity = nil, unit_number = nil, resolved_tick = nil }

-- The filters last written, as a signature string, so a refresh that changes
-- nothing costs no API call at all. Cleared whenever the combinator changes or a
-- write fails, so the next publish always writes.
local last_signature = nil
local last_write_tick = nil

-- Set once a write has been refused, so a combinator that keeps refusing writes
-- one line to the log rather than sixty a minute for the rest of the game.
local warned = false

-- Reused across calls. publish() runs once a second for the life of the game, so
-- the filter tables are mutated in place instead of being rebuilt: after the
-- first call a refresh allocates only the handful of short strings the signature
-- is made of.
local buffer = {}
local signature_parts = {}
local seen = {}

-- State access ---------------------------------------------------------------

--- The infrastructure record, or nil if the scenario has not populated it yet.
--- A console call can reach this module before on_init has run, so none of this
--- may assume the state exists.
local function infra_state()
  if type(storage) ~= "table" then return nil end
  local taxes = storage.taxes
  if type(taxes) ~= "table" then return nil end
  local infra = taxes.infra
  if type(infra) ~= "table" then return nil end
  return infra
end

-- Entity resolution ----------------------------------------------------------

--- Find the combinator a recorded unit number names.
---
--- get_entity_by_unit_number is the direct route and is what keeps this cheap
--- enough to sit behind a once-a-second refresh. The surface search behind it is
--- a fallback for the case where that lookup is unavailable or has been given a
--- number from another surface: it is bounded to a few tiles around the station,
--- never a scan of the map.
local function resolve_entity(unit_number, infra)
  local ok, entity = pcall(function() return game.get_entity_by_unit_number(unit_number) end)
  if ok and entity and entity.valid and entity.name == COMBINATOR_NAME then
    return entity
  end

  local surface = util.surface()
  local position = infra and infra.stop_position
  if not (surface and surface.valid and type(position) == "table") then return nil end

  local found
  local searched = pcall(function()
    found = surface.find_entities_filtered({
      name = COMBINATOR_NAME,
      position = position,
      radius = SEARCH_RADIUS,
    })
  end)
  if not (searched and type(found) == "table") then return nil end

  for _, candidate in pairs(found) do
    if candidate.valid and candidate.unit_number == unit_number then return candidate end
  end
  return nil
end

--- The readout combinator, or nil if there is not one.
---
--- A cache hit is a single validity test. A miss resolves at most once per tick,
--- because a unit number that nothing answers to would otherwise re-run the
--- lookup on every call for the rest of the game.
function signals.combinator()
  local infra = infra_state()
  local unit_number = infra and tonumber(infra.combinator_unit_number) or nil
  if not unit_number then
    cache.entity, cache.unit_number = nil, nil
    return nil
  end

  local entity = cache.entity
  if entity and entity.valid and cache.unit_number == unit_number then
    return entity
  end

  -- Either the entity is gone or rail_infra has replaced it with a new one. In
  -- both cases what the combinator is holding is no longer what we last wrote,
  -- so the next publish has to write in full.
  cache.entity, cache.unit_number = nil, nil
  last_signature = nil

  local now = game.tick
  if cache.resolved_tick == now then return nil end
  cache.resolved_tick = now

  local resolved = resolve_entity(unit_number, infra)
  if not resolved then return nil end

  cache.entity, cache.unit_number = resolved, unit_number
  return resolved
end

--- Section 1 of the combinator's control behaviour.
---
--- 2.0.77 constant combinators have no `parameters` field at all - reading it
--- raises - and carry logistic sections instead, one of which already exists on
--- a freshly created combinator (docs/API_NOTES.md). get_section is still tried
--- inside its own pcall in case a section was somehow removed, in which case
--- adding one is the repair.
local function section_of(entity)
  local ok, behavior = pcall(function() return entity.get_control_behavior() end)
  if not (ok and behavior) then return nil end

  local section
  pcall(function() section = behavior.get_section(1) end)
  if not section then
    pcall(function() section = behavior.add_section() end)
  end
  return section
end

-- Filter assembly ------------------------------------------------------------

--- Clamp a demanded amount to what a circuit network can actually carry. A value
--- outside the range, or one that is not a number at all, is clamped rather than
--- dropped so the readout keeps driving the player's inserters.
local function to_signal_value(number)
  number = tonumber(number) or 0
  -- NaN fails every comparison below and would be handed straight to the engine.
  if number ~= number then return 0 end
  number = math.floor(number)
  if number > MAX_SIGNAL then return MAX_SIGNAL end
  if number < MIN_SIGNAL then return MIN_SIGNAL end
  return number
end

--- Set the value of an already-written buffer slot, keeping the signature that
--- decides whether a write is needed in step with it.
local function set_value(index, value)
  local slot = buffer[index]
  slot.min = value
  local signal = slot.value
  signature_parts[index] = signal.type .. ":" .. signal.name .. "=" .. value
end

--- Append one filter to the buffer and return the new filter count. The slot
--- tables are reused rather than replaced, which is what stops a readout that
--- refreshes forever from allocating a table per entry per second.
local function push(count, signal_type, name, quality, value)
  count = count + 1

  local slot = buffer[count]
  if not slot then
    slot = { value = {}, min = 0 }
    buffer[count] = slot
  end

  local signal = slot.value
  signal.type = signal_type
  signal.name = name
  -- Item filters carry a quality and fluid and virtual filters must not
  -- (docs/API_NOTES.md). This is always assigned, never only set, because the
  -- slot may be left over from an entry of the other kind.
  signal.quality = quality
  signal.comparator = "="

  set_value(count, value)
  return count
end

--- Whether a prototype of this kind exists. A demand can name anything - the
--- catalogue can fall behind the game, and /tax-demand takes a typed name - and
--- handing an unknown name to the engine costs the whole section rather than the
--- one entry that named it.
local function prototype_exists(kind, name)
  local ok, proto = pcall(function() return prototypes[kind][name] end)
  return ok and proto ~= nil
end

--- The signal kind a demand entry publishes as, or nil if no prototype of any
--- kind carries that name.
---
--- The entry's own kind is preferred but still checked, and a kind that names no
--- prototype falls through to the other one: a demand assembled by hand may carry
--- no kind at all or label a fluid as an item, and publishing it under the right
--- signal type is better than dropping it from the readout.
local function kind_of(entry)
  local name = entry.name
  if type(name) ~= "string" then return nil end

  local kind = entry.kind
  if (kind == "item" or kind == "fluid") and prototype_exists(kind, name) then
    return kind
  end
  if prototype_exists("fluid", name) then return "fluid" end
  if prototype_exists("item", name) then return "item" end
  return nil
end

--- Fill the buffer from a demand, the countdown and the cycle number.
-- @return number how many filters were written
local function assemble(demand, seconds_remaining, cycle)
  local count = 0

  -- Reused rather than reallocated, for the same reason the buffer is.
  for key in pairs(seen) do seen[key] = nil end

  if type(demand) == "table" then
    -- A demand is an array (docs/DESIGN.md section 3), and ipairs is what keeps
    -- the published order the same as the order every other module reads it in.
    for _, entry in ipairs(demand) do
      if type(entry) == "table" then
        local kind = kind_of(entry)
        local value = kind and to_signal_value(entry.count) or 0
        if kind and value ~= 0 then
          -- Two entries naming the same thing are summed instead of published
          -- twice: one section cannot hold the same signal in two slots, and the
          -- total is what a player wiring this up actually needs anyway.
          local key = kind .. "/" .. entry.name
          local existing = seen[key]
          if existing then
            set_value(existing, to_signal_value(buffer[existing].min + value))
          else
            -- Item filters carry a quality, fluid filters must not
            -- (docs/API_NOTES.md), and this scenario is base game only, so an
            -- item is always normal quality.
            local quality = kind == "item" and "normal" or nil
            count = push(count, kind, entry.name, quality, value)
            seen[key] = count
          end
        end
      end
    end
  end

  -- A countdown that is not running is not information, so it is left off the
  -- wire entirely rather than published as a zero a circuit has to special-case.
  local seconds = to_signal_value(seconds_remaining)
  if seconds > 0 then
    count = push(count, "virtual", TIME_SIGNAL, nil, seconds)
  end

  -- Cycle 0 is published as well even though a zero never reaches the wire, so
  -- the combinator's own GUI shows the number the scenario is on.
  if cycle ~= nil then
    count = push(count, "virtual", CYCLE_SIGNAL, nil, to_signal_value(cycle))
  end

  -- The engine reads the buffer as an array, so anything left over from a longer
  -- demand has to go rather than merely be ignored.
  for index = count + 1, #buffer do buffer[index] = nil end
  return count
end

-- Public interface -----------------------------------------------------------

--- Publish a demand on the combinator: one signal per demanded item or fluid
--- valued at the demanded amount, signal-T for the seconds left in the phase,
--- and signal-C for the cycle number.
---
--- Safe to call every second with anything at all. A nil or empty demand blanks
--- the output, a missing combinator is a no-op, and an entry naming a prototype
--- that does not exist is skipped while the rest of the demand is still
--- published.
-- @param demand table|nil array of { kind, name, count } entries
-- @param seconds_remaining number|nil seconds left in the current phase; nil or
--   zero omits signal-T
-- @param cycle number|nil the cycle number
-- @return boolean whether the combinator is now carrying this demand
function signals.publish(demand, seconds_remaining, cycle)
  local entity = signals.combinator()
  if not entity then return false end

  local count = assemble(demand, seconds_remaining, cycle)
  local signature = table.concat(signature_parts, "|", 1, count)

  local now = game.tick
  local changed = signature ~= last_signature
  local stale = last_write_tick == nil or (now - last_write_tick) >= REPUBLISH_INTERVAL
  if not (changed or stale) then return true end

  local section = section_of(entity)
  if not section then return false end

  if not pcall(function() section.filters = buffer end) then
    -- Forget the signature so the next refresh retries rather than believing the
    -- combinator already carries this demand. Logged once and not once a second:
    -- whatever the engine objects to will still be there on the next refresh.
    last_signature = nil
    if not warned then
      warned = true
      log("[taxes] the tax readout combinator refused the demand signals")
    end
    return false
  end

  warned = false
  last_signature = signature
  last_write_tick = now
  return true
end

--- Blank the readout, so nothing is on the wire between one demand and the next.
-- @return boolean whether the combinator was actually cleared
function signals.clear()
  -- Dropped first, so a publish that happens to carry exactly what was last
  -- written still writes it after this.
  last_signature = nil
  last_write_tick = nil

  local entity = signals.combinator()
  if not entity then return false end

  local section = section_of(entity)
  if not section then return false end

  return pcall(function() section.filters = {} end) == true
end

return signals
