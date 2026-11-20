-- Locales/esES.lua
-- Spanish (esES, esMX) translation of Hekili Forever (Hekili_Rogue). Written by tools/locales.py, which keeps the translations and adds
-- new text as it appears: only edit the L[...] lines, other changes here are lost.
--
-- To translate a line, remove the "-- " in front and type the translation between the empty quotes:
--     -- L["Reset"] = ""
-- becomes
--     L["Reset"] = "..."
-- The key in L["..."] is the English text: leave it exactly as it is. Untranslated lines show in English. Keep every
-- format code (%s, %d, %.1f...), colour (|cFFFFD100...|r), texture (|T...|t) and line break (\n) of the English text.

local Locale = LibStub("AceLocale-3.0")
local L = Locale:NewLocale("Hekili_Rogue", "esES") or Locale:NewLocale("Hekili_Rogue", "esMX")
if not L then
    return
end

-- Hekili_Rogue/Rogue.lua
L["Assassination"] = "Asesinato"
L["Combat"] = "Combate"
L["Subtlety"] = "Sutileza"
-- L["Always Behind"] = ""
-- L["Allow attacks that require being behind the target when the addon cannot infer your position."] = ""
-- L["Continuous Combat"] = ""
-- L["Keep Slice and Dice on ordinary enemies when you expect to keep fighting between targets. Raid priorities are unchanged."] = ""
-- L["Stun Spacing"] = ""
-- L["Minimum seconds between our stun attempts on the same target. This conservative spacing is not a full diminishing-returns tracker. Zero disables spacing."] = ""
-- L["Poison Reminders"] = ""
-- L["Suggest poisons for uncoated weapons before combat, independently of the Potions toggle. Existing weapon coatings are kept."] = ""
-- L["Automatic"] = ""
-- L["Instant Poison"] = ""
-- L["Deadly Poison"] = ""
-- L["No Reminder"] = ""
-- L["Main Hand Poison"] = ""
-- L["Automatic uses Instant Poison. This preference only applies when the weapon is uncoated."] = ""
-- L["Off Hand Poison"] = ""
-- L["Automatic prefers Deadly Poison on durable targets and Instant Poison otherwise. This preference only applies when the weapon is uncoated."] = ""
L["Combat (wowsims.com)"] = "Combate (wowsims.com)"
L["Assassination (wowsims.com)"] = "Asesinato (wowsims.com)"
L["Subtlety (wowsims.com)"] = "Sutileza (wowsims.com)"
