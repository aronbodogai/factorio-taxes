-- The catalogue of things the tax train is allowed to demand. Base game 2.0
-- only: no Space Age prototypes and no quality, because the scenario is served
-- to vanilla clients that would not have those prototypes loaded.
--
-- Every `tech` in this file was checked against
-- `data/base/prototypes/technology.lua` in the 2.0 install, by reading the
-- `unlock-recipe` effect that actually enables the recipe. A wrong name here
-- would not crash: the entry would simply never become available, so the names
-- matter more than they look like they do.
--
-- TIER SCALE (1..7) — roughly "how many production steps deep is this, and how
-- far into the tech tree do you have to be to run that chain at scale":
--
--   1  Raw or first-smelt: mined ore, plates, coal, stone.
--   2  One assembler step off tier 1: gears, bricks, cable, magazines.
--   3  Early tech intermediates: green circuits, steel, red science, water.
--   4  The oil and logistics era opens: plastic, sulfur, engines, crude oil.
--   5  Red circuits and the chemistry that feeds them: batteries, acid.
--   6  Chemical-science era: blue science, electric engines, refined oils.
--   7  Late intermediates: blue circuits, low density structures, robot
--      frames, purple and yellow science, rocket fuel, fuel cells.
--
-- `unit` is the demanded quantity at cycle 0 and is calibrated by rough
-- raw-ore-equivalent effort rather than by item count, so that a tier-1 and a
-- tier-7 demand cost the player a comparable amount of factory. That is why a
-- plate demand is in the hundreds and a blue circuit demand is twenty.
--
-- Two deliberate rules constrain what may appear here:
--
--   * Every entry with `tech = nil` sits at tier 1 or 2. The selection window
--     in tax_request.lua only keeps the top `config.TIER_WINDOW + 1` tiers, so
--     a tech-free entry at tier 3 would push plates out of the very first
--     demand.
--   * Every entry must be something the player can physically put into a
--     wagon. Rocket parts are excluded for that reason: they are crafted
--     inside the rocket silo and cannot be removed from it.

local taxable_items = {
  -- Tier 1 — available from the first tick, mined or smelted directly. -------
  { name = "iron-plate",              kind = "item",  tier = 1, tech = nil,                       unit = 200 },
  { name = "copper-plate",            kind = "item",  tier = 1, tech = nil,                       unit = 200 },
  { name = "coal",                    kind = "item",  tier = 1, tech = nil,                       unit = 200 },
  { name = "stone",                   kind = "item",  tier = 1, tech = nil,                       unit = 200 },

  -- Tier 2 — one crafting step further, still nearly free. -------------------
  { name = "iron-gear-wheel",         kind = "item",  tier = 2, tech = nil,                       unit = 120 },
  { name = "stone-brick",             kind = "item",  tier = 2, tech = nil,                       unit = 120 },
  { name = "firearm-magazine",        kind = "item",  tier = 2, tech = nil,                       unit = 100 },
  { name = "copper-cable",            kind = "item",  tier = 2, tech = "electronics",             unit = 300 },

  -- Tier 3 — the first real production lines. --------------------------------
  { name = "electronic-circuit",      kind = "item",  tier = 3, tech = "electronics",             unit = 100 },
  { name = "steel-plate",             kind = "item",  tier = 3, tech = "steel-processing",        unit = 60 },
  { name = "automation-science-pack", kind = "item",  tier = 3, tech = "automation-science-pack", unit = 100 },
  -- Water is gated on fluid-handling rather than steam-power because a pump is
  -- what the player actually needs to fill a fluid wagon, and fluid-handling is
  -- the technology that unlocks it.
  { name = "water",                   kind = "fluid", tier = 3, tech = "fluid-handling",          unit = 3000 },

  -- Tier 4 — oil, logistics, and the chemistry that follows them. ------------
  { name = "logistic-science-pack",   kind = "item",  tier = 4, tech = "logistic-science-pack",   unit = 80 },
  { name = "plastic-bar",             kind = "item",  tier = 4, tech = "plastics",                unit = 150 },
  { name = "sulfur",                  kind = "item",  tier = 4, tech = "sulfur-processing",       unit = 120 },
  -- Solid fuel first becomes craftable through solid-fuel-from-petroleum-gas,
  -- which the oil-processing technology unlocks.
  { name = "solid-fuel",              kind = "item",  tier = 4, tech = "oil-processing",          unit = 100 },
  { name = "engine-unit",             kind = "item",  tier = 4, tech = "engine",                  unit = 50 },
  { name = "concrete",                kind = "item",  tier = 4, tech = "concrete",                unit = 200 },
  -- oil-gathering unlocks the pumpjack and itself requires fluid-handling, so a
  -- force that can be asked for crude oil always has a pump to load it with.
  { name = "crude-oil",               kind = "fluid", tier = 4, tech = "oil-gathering",           unit = 2500 },
  { name = "petroleum-gas",           kind = "fluid", tier = 4, tech = "oil-processing",          unit = 2000 },

  -- Tier 5 — red circuits and the acid chain behind them. --------------------
  { name = "advanced-circuit",        kind = "item",  tier = 5, tech = "advanced-circuit",        unit = 60 },
  { name = "battery",                 kind = "item",  tier = 5, tech = "battery",                 unit = 80 },
  { name = "explosives",              kind = "item",  tier = 5, tech = "explosives",              unit = 80 },
  { name = "military-science-pack",   kind = "item",  tier = 5, tech = "military-science-pack",   unit = 60 },
  { name = "sulfuric-acid",           kind = "fluid", tier = 5, tech = "sulfur-processing",       unit = 1500 },

  -- Tier 6 — chemical science era. -------------------------------------------
  { name = "chemical-science-pack",   kind = "item",  tier = 6, tech = "chemical-science-pack",   unit = 50 },
  { name = "electric-engine-unit",    kind = "item",  tier = 6, tech = "electric-engine",         unit = 40 },
  -- Basic oil processing yields only petroleum gas, so light and heavy oil are
  -- genuinely gated on advanced-oil-processing.
  { name = "light-oil",               kind = "fluid", tier = 6, tech = "advanced-oil-processing", unit = 2000 },
  { name = "heavy-oil",               kind = "fluid", tier = 6, tech = "advanced-oil-processing", unit = 2000 },
  { name = "lubricant",               kind = "fluid", tier = 6, tech = "lubricant",               unit = 1200 },

  -- Tier 7 — the late intermediates a megabase is actually built out of. -----
  { name = "processing-unit",         kind = "item",  tier = 7, tech = "processing-unit",         unit = 20 },
  { name = "low-density-structure",   kind = "item",  tier = 7, tech = "low-density-structure",   unit = 20 },
  { name = "flying-robot-frame",      kind = "item",  tier = 7, tech = "robotics",                unit = 25 },
  { name = "production-science-pack", kind = "item",  tier = 7, tech = "production-science-pack", unit = 30 },
  { name = "utility-science-pack",    kind = "item",  tier = 7, tech = "utility-science-pack",    unit = 30 },
  { name = "rocket-fuel",             kind = "item",  tier = 7, tech = "rocket-fuel",             unit = 20 },
  { name = "uranium-fuel-cell",       kind = "item",  tier = 7, tech = "nuclear-power",           unit = 20 },

  -- Deliberately absent: space-science-pack. It has no crafting recipe at all,
  -- arriving only as a lump of 1000 per rocket launch, so it is a burst rather
  -- than a rate. The growth curve would demand roughly 219000 of it by cycle 60,
  -- which is 219 launches inside a three-minute loading window. It fails the
  -- same "cannot be produced in bulk on demand" test that already excluded
  -- rocket-part, so tier 7 is the top of the catalogue.
}

return taxable_items
