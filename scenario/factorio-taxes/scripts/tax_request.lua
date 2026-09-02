-- Demand generation, per DESIGN.md section 5.
--
-- The catalogue in scripts/data/taxable_items.lua supplies the raw entries.
-- Everything here narrows that catalogue down to what the player force can
-- actually hand over on this cycle, and scales the quantities with the cycle
-- number. Nothing in this module touches storage: a demand is derived purely
-- from the cycle number, the force's researched technologies, and the game RNG,
-- which keeps it deterministic and safe to call from any phase transition.

local config = require("scripts.config")
local util = require("scripts.util")
local catalogue = require("scripts.data.taxable_items")

local tax_request = {}

-- A fluid demand is clamped to this many full fluid wagons. config.lua has no
-- key for it because the number only means anything here: it is the fluid-side
-- twin of config.MAX_DEMAND_STACKS, keeping a late-game demand short enough
-- that the train still fits beside the station.
local MAX_FLUID_WAGONS = 2

-- The one entry that is guaranteed to work in any base game, used only if the
-- catalogue somehow filters down to nothing. Iron plate is craftable from the
-- first tick, so a demand built from it can never be undeliverable.
local FALLBACK_ENTRY = { name = "iron-plate", kind = "item", tier = 1, tech = nil, unit = 200 }

-- Technology and prototype names the catalogue references but the loaded game
-- does not define. These tables are log de-duplicators and hold no game state,
-- so they deliberately live outside storage; losing them on reload costs one
-- repeated log line and nothing else.
local warned_technologies = {}
local warned_prototypes = {}

--- True if the prototype a catalogue entry names exists in this game.
-- A missing prototype could never be delivered, so it must not reach a demand
-- even if the gating technology reads as researched.
local function prototype_exists(entry)
  local exists
  if entry.kind == "fluid" then
    exists = prototypes.fluid[entry.name] ~= nil
  else
    exists = prototypes.item[entry.name] ~= nil
  end
  -- A misspelled item name would otherwise vanish without trace, which is the
  -- exact failure this catalogue is most likely to develop. Log it once, the
  -- same way an unknown technology name is logged.
  if not exists and not warned_prototypes[entry.name] then
    warned_prototypes[entry.name] = true
    log("[taxes] catalogue names a " .. tostring(entry.kind) .. " prototype that does "
      .. "not exist in this game: " .. tostring(entry.name))
  end
  return exists
end

--- True if the force has unlocked the entry.
-- A technology name that does not exist is a typo in the catalogue rather than
-- a runtime condition, so it is logged once and the entry is skipped. Crashing
-- a live game over a data mistake would be far worse than quietly taxing
-- something else.
local function is_unlocked(force, entry)
  if entry.tech == nil then return true end

  local technology = force.technologies[entry.tech]
  if technology == nil then
    if not warned_technologies[entry.tech] then
      warned_technologies[entry.tech] = true
      log("factorio-taxes: taxable entry '" .. tostring(entry.name) .. "' names unknown technology '"
        .. tostring(entry.tech) .. "'; it will never be demanded.")
    end
    return false
  end

  return technology.researched
end

--- Weight used when drawing an entry, biased hard toward the deeper tiers.
-- The tier floor of 1 keeps the exponentiation well defined if a catalogue
-- entry is ever given a zero or negative tier.
local function tier_weight(entry)
  local tier = entry.tier
  if tier < 1 then tier = 1 end
  return tier ^ config.TIER_BIAS
end

--- Entries within config.TIER_WINDOW of the deepest tier that is available.
-- This is the rule that makes the game ask for red circuits instead of green
-- ones once red circuits exist: paying a modern tax with an obsolete product
-- would cost the player almost nothing.
local function top_tier_window(entries)
  local max_tier = 0
  for _, entry in ipairs(entries) do
    if entry.tier > max_tier then max_tier = entry.tier end
  end

  local floor_tier = max_tier - config.TIER_WINDOW
  local window = {}
  for _, entry in ipairs(entries) do
    if entry.tier >= floor_tier then
      window[#window + 1] = entry
    end
  end
  return window
end

--- Demanded quantity for one entry on a given cycle.
-- Growth compounds, so the clamps are what stop a long game from asking for a
-- quantity no train could carry.
local function quantity_for(entry, cycle)
  -- Growth is capped rather than left to compound. `unit` is calibrated as the
  -- effort at cycle 0, but a late-game item only becomes available once the
  -- multiplier is already large, so uncapped compounding made the first blue
  -- circuit demand arrive pre-multiplied into the thousands. Measured before
  -- the cap: 24000 utility science packs per ten-minute cycle, a sustained 40
  -- per second, which no reasonable base produces.
  local multiplier = (1 + config.GROWTH_RATE) ^ cycle
  if multiplier > config.MAX_GROWTH_MULTIPLIER then
    multiplier = config.MAX_GROWTH_MULTIPLIER
  end

  local count = math.ceil(entry.unit * multiplier)

  local cap
  if entry.kind == "fluid" then
    cap = MAX_FLUID_WAGONS * config.FLUID_WAGON_CAPACITY
  else
    cap = config.MAX_DEMAND_STACKS * util.stack_size(entry.name)
  end

  if count > cap then count = cap end
  if count < 1 then count = 1 end
  return count
end

--- Build the demand row a settlement and the UI both read.
local function demand_entry(entry, cycle)
  return {
    kind      = entry.kind,
    name      = entry.name,
    count     = quantity_for(entry, cycle),
    delivered = 0,
  }
end

--- Catalogue entries the given force could deliver right now.
-- @param force LuaForce, defaulting to the force taxes are levied against
-- @return table array of catalogue entries, sharing storage with the catalogue
function tax_request.available(force)
  force = force or util.player_force()

  local result = {}
  if not force then return result end

  for _, entry in ipairs(catalogue) do
    if prototype_exists(entry) and is_unlocked(force, entry) then
      result[#result + 1] = entry
    end
  end
  return result
end

--- Generate the demand for a cycle, per DESIGN.md section 5.
-- @param cycle number the cycle index, 0 for the first one
-- @return table array of { kind, name, count, delivered } — never empty
function tax_request.generate(cycle)
  cycle = cycle or 0

  local pool = top_tier_window(tax_request.available(util.player_force()))

  -- An empty demand would settle as fully paid and turn the whole cycle into a
  -- no-op, so fall back rather than return nothing.
  if #pool == 0 then
    return { demand_entry(FALLBACK_ENTRY, cycle) }
  end

  local wanted = math.min(config.MAX_DEMAND_TYPES,
                          1 + math.floor(cycle / config.TYPES_PER_CYCLE_DIVISOR))
  if wanted > #pool then wanted = #pool end
  if wanted < 1 then wanted = 1 end

  -- Draw without replacement from a copy of the pool. Removing each pick is
  -- what makes the selection distinct; independent weighted draws would happily
  -- demand the same item twice and the wagon filters could not express that.
  local remaining = {}
  for index, entry in ipairs(pool) do
    remaining[index] = entry
  end

  local demand = {}
  for _ = 1, wanted do
    local picked = util.weighted_pick(remaining, tier_weight)
    if not picked then break end

    for index = #remaining, 1, -1 do
      if remaining[index] == picked then
        table.remove(remaining, index)
        break
      end
    end

    demand[#demand + 1] = demand_entry(picked, cycle)
  end

  return demand
end

return tax_request
