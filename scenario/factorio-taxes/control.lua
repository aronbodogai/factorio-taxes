-- Factorio Taxes — scenario entry point.
--
-- Base freeplay is loaded first so the map plays like a normal game: crash site,
-- starting items, and the rocket goal are all still there. The tax cycle is then
-- added as a second event_handler library rather than replacing freeplay, which
-- is why this file registers no events of its own.

require("__base__/script/freeplay/control.lua")

local handler = require("event_handler")
handler.add_lib(require("scripts.taxes"))
