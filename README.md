# Factorio Taxes

A Factorio 2.0 scenario that adds a recurring tax you have to physically pay.

A rail line and a station called **Tax Station** already exist when the map is
generated, north of your spawn. They cannot be mined, deconstructed, damaged, or
driven. Every few minutes a tax train is dispatched: you are told what it wants
and roughly when it arrives, the train pulls in, and you have a limited window to
load the wagons. The wagons are slot-filtered to exactly what was demanded, so
you cannot pay in the wrong currency. Whatever you fail to deliver is answered
with a biter attack sized in proportion to the shortfall.

What is demanded grows over time and follows your own tech tree. Once you have
researched advanced circuits, the taxman stops asking for iron plates and starts
asking for red chips.

* Factorio version: **2.0.77**
* DLC required: **none**. No Space Age, no elevated rails, no quality.
* Delivery: a **scenario**, so it is server-side only and clients download nothing.

## Installing

Copy `scenario/factorio-taxes` into your Factorio scenario directory:

| Platform | Path |
| --- | --- |
| Windows | `%APPDATA%\Factorio\scenarios\factorio-taxes` |
| Linux | `~/.factorio/scenarios/factorio-taxes` |
| macOS | `~/Library/Application Support/factorio/scenarios/factorio-taxes` |

Then start it from **Play → Scenarios → factorio-taxes**.

For a headless server:

```bash
./bin/x64/factorio --start-server-load-scenario factorio-taxes --server-settings server-settings.json
```

The scenario loads base freeplay underneath itself, so you still get the crash
site, the usual starting items, and the rocket as a goal.

## How a cycle runs

| Phase | What happens | Default |
| --- | --- | --- |
| Cooldown | Nothing. Build your factory. | 5 minutes |
| Announced | The demand is published and a train is dispatched. | 2 minutes |
| Inbound | The train is on its way to the station. | until it arrives |
| Loading | Fill the wagons. The panel tracks you live. | 3 minutes |
| Departing | What you paid is taken, what you did not is punished. | until it leaves |

Every one of those durations, and the difficulty curve behind them, lives in
`scenario/factorio-taxes/scripts/config.lua`.

## Testing commands

The scenario ships console commands so you do not have to sit through timers to
see any particular stage. They work in game and over RCON.

| Command | Effect |
| --- | --- |
| `/tax-status` | Print phase, cycle, demand, and train state |
| `/tax-build` | Rebuild the rail line and station |
| `/tax-demand [cycle]` | Generate a fresh demand, optionally for a given cycle |
| `/tax-train` | Dispatch the tax train immediately |
| `/tax-arrive` | Put the train at the station without waiting for it to path |
| `/tax-fill [0..1]` | Fill the wagons with that fraction of the demand |
| `/tax-settle` | Settle now: deduct what was paid, punish the rest |
| `/tax-depart` | Send the train away without settling |
| `/tax-despawn` | Destroy the tax train |
| `/tax-attack [0..1]` | Spawn a punishment wave for that shortfall |
| `/tax-wave [shortfall] [cycle]` | Report the wave calculation without spawning |
| `/tax-sample [n]` | Draw n demands and print a histogram, for balancing |
| `/tax-cycle <n>` | Set the cycle counter to test escalation |
| `/tax-phase <name> [seconds]` | Jump to a phase |
| `/tax-skip` | Expire the current phase immediately |

A quick end-to-end check, by hand:

```
/tax-cycle 6
/tax-demand 6
/tax-train
/tax-arrive
/tax-fill 0.5
/tax-settle
```

That demands a cycle-6 tax, brings the train in, pays half, and lets the
consequences arrive.

## Development

* `docs/DESIGN.md` — the specification every module is built against.
* `docs/API_NOTES.md` — Factorio 2.0.77 API facts established by probing the
  running game rather than from memory. Read this before changing engine calls.
* `PROGRESS.md` — task status.

Automated testing runs against a real headless server:

```bash
tools/headless_test.sh tests/cycle.rcon
tools/reload_test.sh tests/before_reload.rcon tests/after_reload.rcon
```

The harness boots the server with an explicit mod list that disables the DLC
shipped alongside the headless install, so the scenario is always exercised
against the base game only.

## Running it as a mod instead

The same code ships either way. `tools/build_mod.sh` assembles the mod form from
the scenario sources, so the scenario stays the single source of truth:

```bash
tools/build_mod.sh          # produces build/factorio-taxes_0.1.0.zip
```

Drop that zip in your `mods` directory and it applies to an ordinary freeplay
save. The only file that differs is `control.lua`: the scenario has to load base
freeplay itself, because a scenario replaces it, whereas a mod runs alongside
whatever scenario is already active.

`/tax-selftest` asserts the wiring in either form. Note that `/silent-command`
cannot see a mod's `storage`, since the level script and the mod have separate
state, so use `/tax-selftest` rather than poking at `storage.taxes` when testing
the mod.
