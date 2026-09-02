-- Developer and testing commands.
--
-- Every stage of the cycle can be driven by hand from here, so the scenario can
-- be exercised without waiting out real timers, and so the headless test harness
-- can assert against each stage in isolation. These are debug tools rather than
-- player-facing UI, so their help text is plain English on purpose.

local config = require("scripts.config")
local util = require("scripts.util")
local rail_infra = require("scripts.rail_infra")
local tax_request = require("scripts.tax_request")
local train_manager = require("scripts.train_manager")
local punishment = require("scripts.punishment")
local tax_schedule = require("scripts.tax_schedule")
local gui = require("scripts.gui")

local module = {}

--- Report back to whoever ran the command: a player in game, the console in a
--- headless server, and the RCON caller when there is one.
local function respond(command, message)
  local player = command.player_index and game.get_player(command.player_index)
  if player then
    player.print(message)
  else
    game.print(message)
  end
  if rcon then
    rcon.print(message)
  end
end

--- Parse the command parameter as a number, or return the fallback.
local function number_arg(command, fallback)
  local value = tonumber(command.parameter)
  if value == nil then return fallback end
  return value
end

local function describe_demand()
  local parts = {}
  for _, entry in pairs(storage.taxes.demand or {}) do
    parts[#parts + 1] = string.format("%s %d/%d", entry.name, entry.delivered or 0, entry.count)
  end
  if #parts == 0 then return "none" end
  return table.concat(parts, ", ")
end

local definitions = {
  {
    name = "tax-status",
    help = "Print the current phase, cycle, demand, and train state.",
    handler = function(command)
      local state = storage.taxes
      respond(command, string.format(
        "phase=%s cycle=%d ends_in=%s train=%s at_station=%s demand=[%s] paid=%d missed=%d waves=%d",
        state.phase, state.cycle,
        util.format_ticks(state.phase_end_tick - game.tick),
        tostring(train_manager.has_train()),
        tostring(train_manager.at_station()),
        describe_demand(),
        state.stats.paid, state.stats.missed, state.stats.waves))
    end,
  },
  {
    name = "tax-build",
    help = "Rebuild the tax rail line and station.",
    handler = function(command)
      rail_infra.build()
      local station = rail_infra.station()
      respond(command, "infrastructure built, station=" .. tostring(station and station.valid))
    end,
  },
  {
    name = "tax-demand",
    help = "Generate a fresh demand. Optional argument: the cycle number to generate for.",
    handler = function(command)
      local cycle = number_arg(command, storage.taxes.cycle)
      storage.taxes.demand = tax_request.generate(cycle)
      gui.build_all()
      respond(command, "demand for cycle " .. cycle .. ": " .. describe_demand())
    end,
  },
  {
    name = "tax-train",
    help = "Spawn the tax train immediately for the current demand.",
    handler = function(command)
      if not storage.taxes.demand or #storage.taxes.demand == 0 then
        storage.taxes.demand = tax_request.generate(storage.taxes.cycle)
      end
      train_manager.destroy()
      tax_schedule.dispatch_train()
      respond(command, "train dispatched, demand: " .. describe_demand())
    end,
  },
  {
    name = "tax-arrive",
    help = "Force the inbound train to the station without waiting for it to path.",
    handler = function(command)
      train_manager.force_to_station()
      tax_schedule.enter("loading", config.LOADING_WINDOW)
      respond(command, "train forced to station, loading window open")
    end,
  },
  {
    name = "tax-fill",
    help = "Fill the tax wagons with a fraction of the demand. Argument 0..1, default 1.",
    handler = function(command)
      local fraction = math.max(0, math.min(1, number_arg(command, 1)))
      local filled = {}
      for _, entry in pairs(storage.taxes.demand or {}) do
        local amount = math.floor(entry.count * fraction)
        if amount > 0 then
          local inserted = train_manager.insert(entry, amount)
          filled[#filled + 1] = string.format("%s %d/%d", entry.name, inserted, amount)
        end
      end
      respond(command, "filled " .. (next(filled) and table.concat(filled, ", ") or "nothing"))
    end,
  },
  {
    name = "tax-settle",
    help = "Settle the current cycle now: deduct what was paid and punish the shortfall.",
    handler = function(command)
      tax_schedule.settle()
      respond(command, "settled, phase=" .. storage.taxes.phase .. " cycle=" .. storage.taxes.cycle)
    end,
  },
  {
    name = "tax-depart",
    help = "Send the tax train away without settling.",
    handler = function(command)
      train_manager.depart()
      respond(command, "train departing")
    end,
  },
  {
    name = "tax-despawn",
    help = "Destroy the tax train immediately.",
    handler = function(command)
      train_manager.destroy()
      respond(command, "train destroyed")
    end,
  },
  {
    name = "tax-attack",
    help = "Spawn a punishment wave directly. Argument: shortfall 0..1, default 1.",
    handler = function(command)
      local shortfall = math.max(0, math.min(1, number_arg(command, 1)))
      local spawned = punishment.spawn_wave(shortfall) or 0
      respond(command, "spawned " .. spawned .. " units for shortfall " .. shortfall)
    end,
  },
  {
    name = "tax-cycle",
    help = "Set the cycle counter, to test escalation. Argument: the new cycle number.",
    handler = function(command)
      local cycle = math.max(0, math.floor(number_arg(command, 0)))
      storage.taxes.cycle = cycle
      respond(command, "cycle set to " .. cycle)
    end,
  },
  {
    name = "tax-phase",
    help = "Jump to a phase. Arguments: <cooldown|announced|inbound|loading|departing> [seconds].",
    handler = function(command)
      local phase, seconds = string.match(command.parameter or "", "^(%a+)%s*(%d*)$")
      local valid = { cooldown = true, announced = true, inbound = true,
                      loading = true, departing = true }
      if not (phase and valid[phase]) then
        respond(command, "usage: /tax-phase <cooldown|announced|inbound|loading|departing> [seconds]")
        return
      end
      tax_schedule.enter(phase, (tonumber(seconds) or 10) * 60)
      respond(command, "phase set to " .. phase)
    end,
  },
  {
    name = "tax-skip",
    help = "Expire the current phase immediately so the next transition happens next tick.",
    handler = function(command)
      storage.taxes.phase_end_tick = game.tick
      respond(command, "phase " .. storage.taxes.phase .. " expired")
    end,
  },
}

function module.register()
  for _, definition in pairs(definitions) do
    -- Wrap every handler so a debug command can never take the game down; the
    -- error is reported to the caller instead.
    commands.add_command(definition.name, definition.help, function(command)
      local ok, err = pcall(definition.handler, command)
      if not ok then
        respond(command, "ERROR in /" .. definition.name .. ": " .. tostring(err))
      end
    end)
  end
end

return module
