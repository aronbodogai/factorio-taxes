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
| 0.6 | `description.json`, locale skeleton | lead | TODO |
| 0.7 | `tools/` — deploy and headless run scripts, RCON client | lead | TODO |

## Phase 1 — Modules

Each module is built by a builder subagent, then checked by an adversarial judge
subagent that runs against the spec and the headless server.

| # | Task | File | Status |
| --- | --- | --- | --- |
| 1.1 | Rail line, station, terrain corridor, immutability | `scripts/rail_infra.lua` | TODO |
| 1.2 | Taxable item catalogue, base game only | `scripts/data/taxable_items.lua` | TODO |
| 1.3 | Tech-gated randomised demand generation | `scripts/tax_request.lua` | TODO |
| 1.4 | Train spawn, composition, filters, arrival, departure, settlement | `scripts/train_manager.lua` | TODO |
| 1.5 | Proportional biter punishment waves | `scripts/punishment.lua` | TODO |
| 1.6 | Player-facing UI and locale strings | `scripts/gui.lua` | TODO |
| 1.7 | Cycle state machine tying the modules together | `scripts/tax_schedule.lua` | TODO |
| 1.8 | Scenario entry point and event wiring | `control.lua` | TODO |

## Phase 2 — Verification

| # | Task | Status |
| --- | --- | --- |
| 2.1 | Scenario loads headless with no Lua error | TODO |
| 2.2 | Rail, station, and corridor exist and are indestructible at tick 0 | TODO |
| 2.3 | A full cycle runs end to end under accelerated timings | TODO |
| 2.4 | Demand tracks the researched tech tree, biased to higher tiers | TODO |
| 2.5 | Underpayment spawns a wave proportional to the shortfall | TODO |
| 2.6 | Wagon filters match the demand exactly | TODO |
| 2.7 | Player cannot mine, deconstruct, damage, or drive tax infrastructure | TODO |
| 2.8 | Save, reload, and resume mid-cycle without desync or error | TODO |

## Phase 3 — Polish

| # | Task | Status |
| --- | --- | --- |
| 3.1 | Balance pass on growth rates and wave sizes | TODO |
| 3.2 | Optional mod wrapper so the scenario can ship as a mod | TODO |
| 3.3 | Player-facing README with install instructions | TODO |

## Notes

* Factorio 2.0 uses `storage`, not `global`.
* Prototype access is `prototypes.item`, not `game.item_prototypes`.
* Test edits go through `tools/deploy.sh`, which syncs the scenario into the WSL
  headless install; never edit the deployed copy directly.
