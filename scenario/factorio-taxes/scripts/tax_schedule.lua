-- The cycle state machine. This module owns storage.taxes.phase and is the only
-- place that advances it, so every other module can treat the phase as read-only.
--
-- cooldown -> announced -> inbound -> loading -> departing -> cooldown

local config = require("scripts.config")
local util = require("scripts.util")
local rail_infra = require("scripts.rail_infra")
local tax_request = require("scripts.tax_request")
local train_manager = require("scripts.train_manager")
local punishment = require("scripts.punishment")
local gui = require("scripts.gui")
local signals = require("scripts.signals")

local tax_schedule = {}

--- Seconds left in the current phase, which is what the combinator publishes as
--- signal-T. During loading it is the time left to pay, and during cooldown it
--- is the time left to prepare, so a circuit can use it in either phase.
local function seconds_remaining()
  local state = storage.taxes
  local ticks = (state.phase_end_tick or 0) - game.tick
  if ticks < 0 then ticks = 0 end
  return math.floor(ticks / 60)
end

--- Generate the demand for the current cycle and put it on the wire.
--- Called as soon as the quiet period begins rather than when the train is
--- announced, so the combinator advertises the next tax for the whole cooldown
--- and a player can have the items staged before the train is even dispatched.
local function prepare_demand()
  local state = storage.taxes
  state.demand = tax_request.generate(state.cycle)
  signals.publish(state.demand, seconds_remaining(), state.cycle)
end

--- Move to a phase and set the tick at which it expires. A duration of nil means
--- the phase ends on an event rather than a timer, so the deadline becomes a
--- failsafe rather than the normal exit.
local function enter(phase, duration)
  local state = storage.taxes
  state.phase = phase
  state.phase_end_tick = game.tick + (duration or 0)
  gui.build_all()
  log("[taxes] phase -> " .. phase .. " until tick " .. state.phase_end_tick)
end

--- Total demanded units, used to weight the shortfall calculation and to decide
--- whether a demand is worth announcing at all.
local function demand_total(demand)
  local total = 0
  for _, entry in pairs(demand or {}) do
    total = total + (entry.count or 0)
  end
  return total
end

--- Generate the demand for the coming cycle and warn the players.
function tax_schedule.begin_cycle()
  local state = storage.taxes

  -- The demand is normally already standing, prepared when the quiet period
  -- began. Only generate one here if it is missing or belongs to a cycle that
  -- has already been settled, so the tax announced is the tax the combinator
  -- has been advertising all along.
  local stale = not state.demand or #state.demand == 0
  if not stale then
    for _, entry in pairs(state.demand) do
      if entry.settled then
        stale = true
        break
      end
    end
  end
  if stale then
    state.demand = tax_request.generate(state.cycle)
  end

  if demand_total(state.demand) <= 0 then
    -- Nothing could be demanded, which should be impossible. Rather than stall
    -- the game, wait out another cooldown and try again.
    log("[taxes] empty demand generated, retrying after a cooldown")
    enter("cooldown", config.CYCLE_PERIOD)
    return
  end

  for _, entry in pairs(state.demand) do
    util.announce({ "taxes.demand-line", entry.count, entry.kind == "fluid"
      and { "fluid-name." .. entry.name } or { "item-name." .. entry.name } })
  end
  util.announce({ "taxes.train-announced", math.floor(config.ANNOUNCE_LEAD / 60) },
    "utility/new_objective")

  enter("announced", config.ANNOUNCE_LEAD)
end

--- Spawn the train and hand control to the arrival watcher.
function tax_schedule.dispatch_train()
  rail_infra.ensure()
  train_manager.spawn(storage.taxes.demand)
  enter("inbound", config.ARRIVAL_TIMEOUT)
end

--- Settle the cycle: deduct what was paid, punish what was not, send the train
--- away, and count the cycle as done.
function tax_schedule.settle()
  local state = storage.taxes

  -- train_manager.settle is idempotent, but the bookkeeping around it is not.
  -- /tax-settle is a debug command a tester will run twice, and without this a
  -- second call would count the cycle again, re-announce the result, and fire a
  -- second wave. train_manager marks each entry as it settles it, so a demand
  -- whose entries are all marked has already been paid up.
  local already_settled = #state.demand > 0
  for _, entry in pairs(state.demand) do
    if not entry.settled then
      already_settled = false
      break
    end
  end
  if already_settled then
    train_manager.depart()
    enter("departing", config.DEPART_TIMEOUT)
    return
  end

  local shortfall = train_manager.settle(state.demand) or 0
  -- Recorded so the settlement can be asserted directly rather than inferred
  -- from the size of the wave it produced.
  state.stats.last_shortfall = shortfall

  if shortfall <= 0 then
    state.stats.paid = state.stats.paid + 1
    util.announce({ "taxes.paid-in-full" }, "utility/research_completed")
  else
    state.stats.missed = state.stats.missed + 1
    util.announce({ "taxes.shortfall", string.format("%.0f", shortfall * 100) },
      "utility/console_message")
    punishment.spawn_wave(shortfall)
  end

  state.cycle = state.cycle + 1
  train_manager.depart()
  enter("departing", config.DEPART_TIMEOUT)
end

--- Advance the machine. Called every tick, but only does real work when a
--- deadline expires or the phase is waiting on a game event.
function tax_schedule.on_tick(event)
  local state = storage.taxes
  if not state then return end

  local phase = state.phase
  local expired = event.tick >= state.phase_end_tick

  -- Republish on the UI cadence rather than every tick: the item signals rarely
  -- change, but signal-T is a countdown and has to stay live for a circuit to
  -- act on it. This also picks up a demand set by hand from /tax-demand.
  if event.tick % config.UI_REFRESH == 0 then
    signals.publish(state.demand, seconds_remaining(), state.cycle)
  end

  if phase == "cooldown" then
    if expired then tax_schedule.begin_cycle() end

  elseif phase == "announced" then
    if expired then tax_schedule.dispatch_train() end

  elseif phase == "inbound" then
    if train_manager.at_station() then
      util.announce({ "taxes.train-arrived", math.floor(config.LOADING_WINDOW / 60) },
        "utility/new_objective")
      enter("loading", config.LOADING_WINDOW)
    elseif expired then
      -- Pathing failed. Put the train at the station by hand so a bad map can
      -- never stall the cycle.
      log("[taxes] arrival timed out, forcing the train to the station")
      train_manager.force_to_station()
      enter("loading", config.LOADING_WINDOW)
    end

  elseif phase == "loading" then
    if expired then tax_schedule.settle() end

  elseif phase == "departing" then
    if train_manager.check_despawn() or expired then
      train_manager.destroy()
      enter("cooldown", config.CYCLE_PERIOD)
      -- The quiet period is the players preparation time, so the next tax goes
      -- on the wire the moment it starts rather than when it is announced.
      prepare_demand()
    end

  else
    -- Unknown phase, most likely from an older save. Reset to a safe state.
    enter("cooldown", config.CYCLE_PERIOD)
  end
end

--- First-run setup.
function tax_schedule.init()
  rail_infra.build()
  enter("cooldown", config.CYCLE_PERIOD)
  prepare_demand()
end

--- Exposed so debug commands can jump the machine around during testing.
tax_schedule.enter = enter

return tax_schedule
