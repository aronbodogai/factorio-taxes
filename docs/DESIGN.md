# Factorio Taxes — Design Specification

Target: Factorio **2.0.77**, base game only. No Space Age, no elevated rails, no
quality. Delivered as a **scenario** (server-side only, no client mod download).

Verified environment facts (do not re-derive):

* Factorio 2.0 renamed `global` to `storage`. Use `storage`. `global` is gone.
* Rail prototypes: `straight-rail`, `curved-rail-a`, `curved-rail-b`,
  `half-diagonal-rail`. The legacy 1.1 `curved-rail` is now `legacy-curved-rail`.
* Rolling stock: `locomotive`, `cargo-wagon`, `fluid-wagon`. Station: `train-stop`.
* Headless server: `~/factorio-taxes-server/factorio` inside WSL Ubuntu.
* The repo is visible from WSL at `/mnt/b/repos/factorio-taxes`.

---

## 1. Concept

A pre-placed, indestructible rail line and station exist from map generation. On a
recurring cycle a tax train arrives, demands a quantity of items or fluids, and
gives the player a limited loading window. Shortfalls trigger a biter attack whose
size is proportional to the fraction of the demand that went unpaid.

## 2. Cycle state machine

`storage.taxes.phase` moves through:

| Phase | Meaning | Ends after |
| --- | --- | --- |
| `cooldown` | Quiet period between cycles. | `config.CYCLE_PERIOD` |
| `announced` | Demand generated and broadcast. Train not yet spawned. | `config.ANNOUNCE_LEAD` |
| `inbound` | Train spawned at the west end, pathing to the station. | Arrival, or `config.ARRIVAL_TIMEOUT` |
| `loading` | Player loads the wagons. Countdown visible. | `config.LOADING_WINDOW` |
| `departing` | Contents evaluated, demand deducted, train drives east. | Train reaches the east end |

`departing` settles the cycle: it increments `storage.taxes.cycle`, triggers the
punishment if there was a shortfall, then returns to `cooldown`.

## 3. Persistent state schema

This schema is a contract between modules. Do not add or rename top-level fields
without updating this document.

```lua
storage.taxes = {
  cycle             = 0,        -- number of settled cycles
  phase             = "cooldown",
  phase_end_tick    = 0,        -- tick at which the current phase expires
  demand            = {         -- array, current cycle demand
    { kind = "item", name = "iron-plate", count = 100, delivered = 0, settled = false },
  },
  infra = {
    surface_index    = 1,
    stop_unit_number = nil,     -- unit_number of the tax train-stop
    stop_position    = nil,     -- MapPosition of the stop
    west_end         = nil,     -- MapPosition, train spawn point
    east_end         = nil,     -- MapPosition, train despawn point
    entities         = {},      -- set: [unit_number] = true, all immutable infra
    built            = false,
  },
  train = {
    loco_unit_numbers  = {},
    wagon_unit_numbers = {},    -- cargo and fluid wagons, in order
    train_id           = nil,   -- LuaTrain.id, refreshed if a split changes it
    departing          = false, -- set while a hand-pushed train still needs nudging
  },
  stats = { paid = 0, missed = 0, waves = 0, last_shortfall = 0 },
}
```

## 4. Rail infrastructure (map generation)

Built once in `on_init`, and re-verified on load.

* Surface: `nauvis` (`config.SURFACE_NAME`).
* A single **straight, horizontal** rail line at `y = config.RAIL_Y` (default `-31`,
  north of spawn). No curves — this keeps train pathing trivially solvable.
* `straight-rail` is a 2x2 entity and snaps to ODD tile coordinates (see
  docs/API_NOTES.md), so build directly on the odd grid: `x` from
  `-config.RAIL_HALF_LENGTH + 1` to `config.RAIL_HALF_LENGTH - 1` step 2, at
  `y = config.RAIL_Y`, which is itself odd.
* Corridor preparation, before placing rail: within `±config.CORRIDOR_HALF_WIDTH`
  tiles of the line, replace water and other non-buildable tiles with `grass-1`
  via `surface.set_tiles`, and `destroy()` every tree, rock, and cliff.
* Train stop named `config.STATION_NAME` ("Tax Station") on the south side of the
  line at `x = 0`, oriented so trains travelling east stop at it.
* `west_end` and `east_end` are the two extremes of the line; the train spawns at
  the former and despawns at the latter.
* Chart a radius around the station for the player force so it is visible from the
  first tick.

### Immutability

Every rail, signal, and the train stop, plus every rolling stock entity of a live
tax train, must be:

* `destructible = false`
* `minable = false`
* `rotatable = false`
* recorded in `storage.taxes.infra.entities` by `unit_number`

and guarded by handlers that cancel:

* `on_pre_player_mined_item` / `on_robot_pre_mined` — cancel and warn
* `on_marked_for_deconstruction` — immediately `cancel_deconstruction`
* `on_player_driving_changed_state` — eject any player who enters a tax locomotive

Locomotives and the train stop get `operable = false` so the player cannot edit the
schedule or rename the station. Cargo and fluid wagons stay operable — the player
has to be able to insert into them.

## 5. Demand generation

Catalogue lives in `scripts/data/taxable_items.lua`: an array of entries

```lua
{ name = "electronic-circuit", kind = "item", tier = 3, tech = "electronics", unit = 50 }
```

* `tech = nil` means always available (e.g. iron plate, copper plate, coal).
* `unit` is the demanded quantity at cycle 0, chosen so entries of different tiers
  represent roughly comparable effort.
* Only base-game items and fluids. No Space Age, no quality.

Selection at the start of each cycle:

1. `available` = entries whose `tech` is `nil` or researched by the player force.
2. `max_tier` = highest tier in `available`.
3. Restrict to entries with `tier >= max_tier - config.TIER_WINDOW` (default `1`).
   This is what makes the game ask for red chips, not green, once red chips exist.
4. Pick `1 + floor(cycle / config.TYPES_PER_CYCLE_DIVISOR)` distinct entries, capped
   at `config.MAX_DEMAND_TYPES`, weighted by `tier ^ config.TIER_BIAS`.
5. Quantity per entry: `ceil(unit * (1 + config.GROWTH_RATE) ^ cycle)`, then clamped
   to `config.MAX_DEMAND_STACKS` stacks so a demand always physically fits on a train.

## 6. Train composition

Derived from the demand, so the train is exactly as long as it needs to be.

* Item entries: `stacks = ceil(count / stack_size)`; a `cargo-wagon` holds 40 slots.
* Fluid entries: a `fluid-wagon` holds 50 000 units; one wagon per fluid entry, more
  if the demand exceeds capacity.
* `wagons = ceil(total_item_stacks / 40) + fluid_wagons`, at least 1.
* `locomotives = max(1, ceil(wagons / 4))`, placed at the front.
* Every cargo wagon has **every slot filtered** to the demanded items, proportional
  to each item's share of the required stacks, via `inventory.set_filter(i, name)`.
  A filtered wagon makes it impossible to pay the tax in the wrong currency.

Departure: the schedule is retargeted to a temporary stop at `east_end`; once the
train is within `config.DESPAWN_RADIUS` of that point, every entity is destroyed and
`storage.taxes.train` is cleared. If the train never arrives within
`config.ARRIVAL_TIMEOUT`, it is destroyed and re-created parked at the station, so a
pathing failure can never stall the cycle.

## 7. Settlement and punishment

At the end of `loading`:

* For each demand entry, read the actual contents of the tax train wagons,
  `delivered = min(found, count)`, and remove exactly `delivered` from the wagons.
* `shortfall = 1 - (sum of delivered / sum of demanded)`, weighted by each entry
  share of the total demand, clamped to `[0, 1]`.
* If `shortfall > 0`, spawn a punitive wave:
  * `wave = ceil(config.BASE_WAVE * shortfall * (1 + cycle * config.WAVE_GROWTH))`,
    capped at `config.MAX_WAVE`.
  * Unit mix is drawn from the enemy force evolution factor on that surface, using
    the same tiering vanilla uses (small / medium / big / behemoth biters and
    spitters).
  * Spawn on a ring of radius `config.ATTACK_SPAWN_RADIUS` around the player base
    centroid, each unit placed with `surface.find_non_colliding_position`.
  * Group them and issue `defines.command.attack_area` at the base centroid.
* A fully paid tax prints a confirmation and awards nothing else — the reward for
  paying is not being attacked.

## 8. User interface

A top-left frame, rebuilt on phase change and refreshed once per second:

* Current phase and a countdown to the next transition.
* Cycle number.
* One row per demanded item: sprite, `delivered / demanded`, progress bar. During
  `loading` these read live from the wagon contents.

All player-facing strings go through `locale/en/strings.cfg`. No hardcoded English
in Lua.

## 9. Configuration

Every tunable lives in `scripts/config.lua`. Defaults:

| Key | Default | Meaning |
| --- | --- | --- |
| `CYCLE_PERIOD` | `5 * 60 * 60` | Quiet ticks between cycles (5 min) |
| `ANNOUNCE_LEAD` | `2 * 60 * 60` | Warning time before the train spawns |
| `LOADING_WINDOW` | `3 * 60 * 60` | Loading time once the train is at the station |
| `ARRIVAL_TIMEOUT` | `2 * 60 * 60` | Failsafe before the train is force-placed |
| `GRACE_CYCLES` | `1` | Cycles at the start with no punishment |
| `GROWTH_RATE` | `0.15` | Per-cycle demand growth |
| `TIER_BIAS` | `2.5` | Exponent biasing selection toward higher tiers |
| `TIER_WINDOW` | `1` | How many tiers below the top stay eligible |
| `MAX_DEMAND_TYPES` | `4` | Cap on distinct demanded items per cycle |
| `RAIL_Y` | `-31` | Rail line offset from spawn |
| `RAIL_HALF_LENGTH` | `120` | Half the rail line length, in tiles |
| `BASE_WAVE` | `12` | Units in a fully unpaid wave at cycle 0 |
| `MAX_WAVE` | `200` | Hard cap on wave size |

## 10. Non-goals

* No Space Age, elevated rails, or quality prototypes.
* No new item, entity, or technology prototypes at all — this is runtime-only.
* No multi-surface support beyond `nauvis`.
