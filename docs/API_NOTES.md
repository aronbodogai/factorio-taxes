# Verified 2.0.77 API notes

Everything here was confirmed by running it against the headless server
(`tests/probe_rail_train.rcon`, `tests/probe_schedule.rcon`). Treat it as ground
truth and do **not** rewrite code based on 1.1 tutorials or on memory of the old
API. If you need a fact that is not here, add a probe command to a `.rcon` file
and run `tools/headless_test.sh` to establish it, then record it here.

## Renamed since 1.1

| 1.1 | 2.0.77 |
| --- | --- |
| `global` | `storage` |
| `game.item_prototypes` | `prototypes.item` |
| `game.entity_prototypes` | `prototypes.entity` |
| `force.evolution_factor` | `force.get_evolution_factor(surface)` |
| `curved-rail` | `legacy-curved-rail` (the modern one is `curved-rail-a` / `-b`) |

## Rail geometry

`straight-rail` is a 2x2 entity and **snaps to odd tile coordinates**. Placing at
`{-40, -32}` produces an entity whose `position` reads `{-39, -31}`.

Build the line directly on the odd grid to avoid the off-by-one:

```lua
for x = -39, 39, 2 do
  surface.create_entity{ name = "straight-rail", position = { x, -31 },
                         direction = defines.direction.east, force = force }
end
```

That placed 40 of 40 rails with zero failures once the corridor terrain was
prepared. On unprepared terrain near spawn, placement fails on water, so
`set_tiles` and the tree/rock/cliff sweep must run **first**.

`defines.direction.east == 4`, `defines.direction.north == 0` (2.0 uses 16
directions, so do not assume the old 8-direction values).

## Train schedules

`LuaTrain.schedule` reads as `nil` in 2.0.77 — the legacy field is dead. Use
`LuaTrain.get_schedule()`, which returns a `LuaSchedule` userdata with:

```
add_record(function)  remove_record(function)  get_record(function)
clear_records(function)  get_record_count(function)  go_to_station(function)
set_stopped(function)  drag_record(function)  current(number)
```

Confirmed working:

```lua
local schedule = train.get_schedule()
schedule.add_record{ station = "Tax Station" }
schedule.get_record_count()          --> 1
schedule.get_record{ schedule_index = 1 }
--> { station = "Tax Station", wait_conditions = {}, temporary = false,
--    created_by_interrupt = false, allows_unloading = true }
train.manual_mode = false            --> train.state becomes 2
```

## Rolling stock

| Fact | Value |
| --- | --- |
| `cargo-wagon` inventory size | 40 slots |
| `fluid-wagon` capacity | **50000** (not 25000) |
| Cargo inventory define | `defines.inventory.cargo_wagon` |

Slot filters work and round-trip through a table, not a string:

```lua
local inventory = wagon.get_inventory(defines.inventory.cargo_wagon)
inventory.set_filter(1, "iron-plate")
inventory.get_filter(1)
--> { name = "iron-plate", quality = "normal", comparator = "=" }
```

Because `get_filter` returns a table, compare `inventory.get_filter(i).name`, never
the returned value itself.

## Station

`train-stop` accepts `backer_name` for its displayed name:

```lua
local stop = surface.create_entity{ name = "train-stop", position = { 3, -33 },
                                    direction = defines.direction.east, force = force }
stop.backer_name = "Tax Station"
```

## Enemies

`game.forces.enemy.get_evolution_factor(surface)` works and returns a number
(`4e-06` on a fresh map).

## Headless testing

`tools/headless_test.sh <file.rcon>` deploys the scenario, boots the server with
the DLC explicitly disabled, replays the command file over RCON, and fails if any
line of output starts with `FAIL` or the server log contains a genuine Lua error.

Write assertions as one command per line:

```
/silent-command rcon.print(cond and "OK label" or "FAIL label")
```

`helpers.table_to_json(t)` is available and is the easiest way to dump a table
into the RCON output.

## Scripted unit groups must be told to move

`set_command` alone does NOT make a scripted group act. Probed on 2.0.77 with a
five-member group (`tests/probe_group_and_tech.rcon`):

```
state after add_member      --> 0  (gathering)
state after set_command     --> 0  (gathering)
state after start_moving()  --> 1  (moving)
```

`defines.group_state` is
`{gathering=0, moving=1, attacking_distraction=2, attacking_target=3, finished=4, pathfinding=5, wander_in_group=6}`.

So every scripted attack must call `group.start_moving()` after `set_command`, or
the wave stands at its spawn ring forever. `create_unit_group{position, force}`
returns a value with both `set_command` and `start_moving` as functions.

## Demand does follow the tech tree

With `electronics` and `advanced-circuit` researched and nothing else, eight
consecutive demand draws produced `advanced-circuit` every time, with no
`electronic-circuit` and no tier-1 items. The tier-window rule in DESIGN.md
section 5 behaves as intended.
