# Progress

Task tracker for the Factorio Taxes scenario. Spec: [docs/DESIGN.md](docs/DESIGN.md).

Status key: `TODO` / `WIP` / `REVIEW` (built, awaiting adversarial check) /
`DONE` (built and the review found nothing outstanding).

## Phase 0 — Foundation

| # | Task | Owner | Status |
| --- | --- | --- | --- |
| 0.1 | Repository, `.gitignore`, `README.md` | lead | DONE |
| 0.2 | Factorio 2.0.77 headless server in WSL Ubuntu | lead | DONE |
| 0.3 | `docs/DESIGN.md` specification | lead | DONE |
| 0.4 | `scripts/config.lua` — every tunable | lead | DONE |
| 0.5 | `scripts/util.lua` — shared helpers | lead | DONE |
| 0.6 | `description.json`, locale skeleton | lead | DONE |
| 0.7 | `tools/` — deploy and headless run scripts, RCON client | lead | DONE |

## Phase 1 — Modules

Each module is built by a builder subagent, then checked by an adversarial judge
subagent that runs against the spec and the headless server.

| # | Task | File | Status |
| --- | --- | --- | --- |
| 1.1 | Rail line, station, terrain corridor, immutability | `scripts/rail_infra.lua` | DONE |
| 1.2 | Taxable item catalogue, base game only | `scripts/data/taxable_items.lua` | DONE |
| 1.3 | Tech-gated randomised demand generation | `scripts/tax_request.lua` | DONE |
| 1.4 | Train spawn, composition, filters, arrival, departure, settlement | `scripts/train_manager.lua` | DONE |
| 1.5 | Proportional biter punishment waves | `scripts/punishment.lua` | DONE |
| 1.6 | Player-facing UI and locale strings | `scripts/gui.lua` | DONE |
| 1.7 | Cycle state machine tying the modules together | `scripts/tax_schedule.lua` | DONE |
| 1.8 | Scenario entry point and event wiring | `control.lua`, `scripts/taxes.lua` | DONE |
| 1.9 | Debug commands so every stage can be driven by hand | `scripts/commands.lua` | DONE |

## Phase 2 — Verification

| # | Task | Status |
| --- | --- | --- |
| 2.1 | Scenario loads headless with no Lua error | DONE |
| 2.2 | Rail, station, and corridor exist and are indestructible at tick 0 | DONE |
| 2.3 | A full cycle runs end to end under accelerated timings | DONE |
| 2.4 | Demand tracks the researched tech tree, biased to higher tiers | DONE |
| 2.5 | Underpayment spawns a wave proportional to the shortfall | DONE |
| 2.6 | Wagon filters match the demand exactly | DONE |
| 2.7 | Player cannot mine, deconstruct, damage, or drive tax infrastructure | DONE |
| 2.8 | Save, reload, and resume mid-cycle without desync or error | DONE |

## Phase 3 — Polish

| # | Task | Status |
| --- | --- | --- |
| 3.1 | Balance pass on growth rates and wave sizes | TODO |
| 3.2 | Optional mod wrapper so the scenario can ship as a mod | TODO |
| 3.3 | Player-facing README with install instructions | DONE |

## Notes

* Factorio 2.0 uses `storage`, not `global`.
* Prototype access is `prototypes.item`, not `game.item_prototypes`.
* Test edits go through `tools/deploy.sh`, which syncs the scenario into the WSL
  headless install; never edit the deployed copy directly.

## Test coverage caveats

* `tests/protection.rcon` asserts the engine-level protection: `minable = false`,
  `destructible = false`, damage immunity, and deconstruction orders being
  cancelled. The player-mining and player-driving paths need a real connected
  player, which a headless RCON run has none of. `minable = false` is what makes
  mining impossible in the first place, so the handlers are a warning path rather
  than the protection itself.
* The same test confirms tracked infrastructure does not grow without bound:
  123 entities with a train present, 121 after it despawns, still 121 after three
  further train cycles.
