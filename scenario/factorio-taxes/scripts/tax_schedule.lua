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

local tax_schedule = {}

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
  state.demand = tax_request.generate(state.cycle)

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
  local shortfall = train_manager.settle(state.demand) or 0

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
end

--- Exposed so debug commands can jump the machine around during testing.
tax_schedule.enter = enter

return tax_schedule
