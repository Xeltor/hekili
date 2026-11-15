-- Locales/enUS.lua
-- The English string table of Hekili_Rogue (AceLocale-3.0, silent): every L[...] key its code uses, each its own text.
-- Written by tools/locales.py: do not edit. It loads first, so its NewLocale is the app's first (the one whose
-- `silent` counts): a key no table holds answers itself.

local L = LibStub("AceLocale-3.0"):NewLocale("Hekili_Rogue", "enUS", true, true)

-- Hekili_Rogue/Rogue.lua
L["Assassination"] = true
L["Combat"] = true
L["Subtlety"] = true
L["Always Behind"] = true
L["Allow attacks that require being behind the target when the addon cannot infer your position."] = true
L["Continuous Combat"] = true
L["Keep Slice and Dice on ordinary enemies when you expect to keep fighting between targets. Raid priorities are unchanged."] = true
L["Stun Spacing"] = true
L["Minimum seconds between our stun attempts on the same target. This conservative spacing is not a full diminishing-returns tracker. Zero disables spacing."] = true
L["Poison Reminders"] = true
L["Suggest poisons for uncoated weapons before combat, independently of the Potions toggle. Existing weapon coatings are kept."] = true
L["Automatic"] = true
L["Instant Poison"] = true
L["Deadly Poison"] = true
L["No Reminder"] = true
L["Main Hand Poison"] = true
L["Automatic uses Instant Poison. This preference only applies when the weapon is uncoated."] = true
L["Off Hand Poison"] = true
L["Automatic prefers Deadly Poison on durable targets and Instant Poison otherwise. This preference only applies when the weapon is uncoated."] = true
L["Combat (wowsims.com)"] = true
L["Assassination (wowsims.com)"] = true
L["Subtlety (wowsims.com)"] = true
