-- Priority casts supported by Forever logs and spell data. Log data from Efficient Games (https://efficient.games),
-- CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Priority and selection are Hekili's.
-- Pinned logs: https://github.com/JIVESCORP/eg-link-output-wowf/tree/f25e0efde0c8490e4e6f356a68f7a81a703fa21c/data
-- Build numbers below refer to the source creatures.json under wowf unless marked beta. Spell effects were checked
-- against Forever 1.60.1.71091 (https://wago.tools/db2/SpellEffect?build=1.60.1.71091). Live cast evidence governs stops.

local shared = Hekili:NewShared()
if not shared.RegisterPriorityInterrupts then
    return
end

shared:RegisterPriorityInterrupts("pve_priority_interrupt", "pve_reserve_interrupt", {
    -- Outdoor quest mobs. The first two entries come from public Forever bug report attachments.
    -- https://github.com/user-attachments/files/35027309/WoWCombatLog-111826_124353.txt
    [1909] = { [5605] = true }, -- Vile Fin Lakestalker, Healing Ward.
    -- https://github.com/user-attachments/files/34589079/WoWCombatLog-110926_110944.txt
    [2376] = { [939] = true }, -- Torn Fin Oracle, Healing Wave.
    [2965] = { [332] = true }, -- Windfury Matriarch, Healing Wave (Forever beta 1.60.1.70009).
    [3280] = { [6728] = true }, -- Witchwing Windcaller, Enveloping Winds (Forever beta 1.60.1.70124).
    [4285] = { [6063] = true }, -- Scarlet Disciple, Heal (1.60.1.70959).
    [269175] = { [1303308] = true }, -- Carnivorous Weed, damaging Entangling Roots (1.60.1.70938).

    -- Ragefire Chasm and Deadmines (1.60.1.70938).
    [645] = { [5174] = true }, -- Cookie, Cookie's Cooking (self heal).
    [11319] = { [11986] = true }, -- Ragefire Shaman, Healing Wave.

    -- Ruins of Lordaeron (1.60.1.70790).
    [250654] = { [7068] = true }, -- Ghostly Citizen, Veil of Shadow (75% healing reduction).

    -- Wailing Caverns (1.60.1.70862, Cobrahn's Slumber from 1.60.1.70790).
    [3654] = { [7967] = true }, -- Mutanus the Devourer, Naralex's Nightmare.
    [3669] = { [5188] = true, [8040] = true }, -- Lord Cobrahn, Healing Touch and Druid's Slumber.
    [3670] = { [700] = true, [5187] = true }, -- Lord Pythas, Sleep and Healing Touch.
    [3671] = { [700] = true, [5187] = true }, -- Lady Anacondra, Sleep and Healing Touch.
    [3673] = { [700] = true, [6778] = true }, -- Lord Serpentis, Sleep and Healing Touch.
    [3840] = { [5187] = true, [8040] = true }, -- Druid of the Fang, Healing Touch and Druid's Slumber.
    [5761] = { [7948] = true }, -- Deviate Shambler, Wild Regeneration.

    -- Shadowfang Keep (1.60.1.70862).
    [3887] = { [7068] = true }, -- Baron Silverlaine, Veil of Shadow.
    [3914] = { [7295] = true }, -- Rethilgore, Soul Drain (root and life drain).
    [4278] = { [1026] = true }, -- Commander Springvale, Holy Light.

    -- Blackfathom Deeps (1.60.1.71037).
    [4809] = { [2055] = true }, -- Twilight Acolyte, Heal.
    [4813] = { [7645] = true }, -- Twilight Shadowmage, Dominate Mind.
    [4820] = { [6063] = true }, -- Blindlight Oracle, Heal.
    [4832] = { [8399] = true }, -- Twilight Lord Kelris, Sleep.

    -- Razorfen Kraul (1.60.1.70888 and 1.60.1.70938).
    [4424] = { [14900] = true }, -- Aggem Thorncurse, Chain Heal.
    [4427] = { [959] = true }, -- Ward Guardian, Healing Wave.
    [4428] = { [14515] = true }, -- Death Speaker Jargba, Dominate Mind.
    [4440] = { [4971] = true }, -- Razorfen Totemic, Healing Ward.
    [4517] = { [6063] = true }, -- Death's Head Priest, Heal.
    [4518] = { [4971] = true }, -- Death's Head Sage, Healing Ward.
    [4519] = { [4971] = true }, -- Death's Head Seer, Healing Ward.
    [4522] = { [6728] = true }, -- Razorfen Dustweaver, Enveloping Winds.

    -- Scarlet Monastery (1.60.1.70938 and 1.60.1.70959).
    [3977] = { [12039] = true }, -- High Inquisitor Whitemane, Heal.
    [4292] = { [3472] = true }, -- Scarlet Protector, Holy Light.
    [4293] = { [1090] = true }, -- Scarlet Scryer, Sleep.
    [4296] = { [6063] = true }, -- Scarlet Adept, Heal.
    [4303] = { [6064] = true }, -- Scarlet Abbot, Heal.
    [4542] = { [8399] = true, [12039] = true, [12096] = true }, -- High Inquisitor Fairbanks, Sleep, Heal and Fear.
    [6426] = { [7068] = true }, -- Anguished Dead, Veil of Shadow.
    [6487] = { [8988] = true, [13323] = true }, -- Arcanist Doan, Silence and Polymorph.

    -- Razorfen Downs (1.60.1.70959).
    [7352] = { [12528] = true }, -- Frozen Soul, area Silence.

    -- City of Dalaran (1.60.1.71091).
    [246016] = { [8988] = true, [1240869] = true }, -- Arcanic Enigma, Silence and Manamorph.
    [246020] = { [1303598] = true }, -- Shade of the Archmage, Mass Polymorph.
    [255072] = { [1303227] = true }, -- Dark Caster, Heal.

    -- The Drowned City (1.60.1.70959). Dreadrise, Profane Necromancer and the Elemental interrupt targets:
    -- https://wowcalc.net/en/forever/guides/dungeons/drowned-city
    [258804] = { [1283934] = true }, -- Brinescale Sorceress, Fear.
    [260042] = { [1282860] = true }, -- Captain Dreadrise, Waterbolt Volley.
    [260096] = { [1282611] = true }, -- Brinescale Priestess, Healing Wave.
    [260243] = { [1313471] = true }, -- Min'loth the Serpent, Fear.
    [260353] = { [1283680] = true }, -- Saltseer Coroner, Healing Wave.
    [263196] = { [1289213] = true }, -- Profane Necromancer, Conjure Spirit.
    [263886] = { [1290978] = true }, -- Primeval Elemental, Waterbolt.

    -- Uldaman (1.60.1.71037).
    [4847] = { [6064] = true }, -- Shadowforge Relic Hunter, Heal.
    [4848] = { [15800] = true }, -- Shadowforge Darkcaster, area Mana Burn.
    [4852] = { [5605] = true, [8005] = true }, -- Stonevault Oracle, Healing Ward and Healing Wave.
    [4863] = { [3636] = true }, -- Jadespine Basilisk, Crystalline Slumber.

    -- Krol'dok Stronghold (1.60.1.71037).
    [259285] = { [1282071] = true }, -- Terrorhowl, Frightening Howl.

    -- Zul'Farrak (1.60.1.71091).
    [5650] = { [11899] = true, [17843] = true }, -- Sandfury Witch Doctor, Healing Ward and Flash Heal.
    [7271] = { [12491] = true }, -- Witch Doctor Zum'rah, Healing Wave.
    [7273] = { [11836] = true }, -- Gahz'rilla, Freeze Solid.
    [7275] = { [12039] = true }, -- Shadowpriest Sezz'ziz, Heal.
    [7795] = { [12491] = true }, -- Hydromancer Velratha, Healing Wave.
    [8127] = { [17843] = true }, -- Antu'sul, Flash Heal.

    -- Maraudon (1.60.1.70938).
    [12224] = { [7948] = true }, -- Cavern Shambler, Wild Regeneration.

    -- Alcaz Prison (1.60.1.71037).
    [255262] = { [15586] = true }, -- Alcaz Chaplain, Heal.
    [255373] = { [13323] = true }, -- Strashaz Enchantress, Polymorph.

    -- Sunken Temple (1.60.1.71037).
    [5259] = { [11986] = true }, -- Atal'ai Witch Doctor, Healing Wave.
    [5271] = { [12096] = true }, -- Atal'ai Deathwalker, Fear.
    [5273] = { [12039] = true }, -- Atal'ai High Priest, Heal.
    [5280] = { [12098] = true }, -- Nightmare Wyrmkin, Sleep.
    [5709] = { [12890] = true }, -- Shade of Eranikus, Deep Slumber.
    [5710] = { [12492] = true }, -- Jammal'an the Prophet, Healing Wave.
    [5717] = { [11899] = true, [12492] = true }, -- Mijan, Healing Ward and Healing Wave.
    [8657] = { [6358] = true }, -- Hukku's Succubus, Seduction.

    -- Blackmaw Hold (1.60.1.71037).
    [247198] = { [1244416] = true }, -- Bonesnout the Unbroken, area Stomp.
    [247207] = { [1245154] = true }, -- Blackmaw Behemoth, Thunder Roar.
    [247209] = { [1245324] = true }, -- Elder Shaman Bloodmane, high-damage Chain Lightning.
    [247234] = { [1247087] = true }, -- Varrox Bleakhoof, area Fear.
    [247248] = { [1323802] = true }, -- Legashi Summoner, Fear.
    [258516] = { [22373] = true }, -- Blackmaw Druid, Regrowth.

    -- Forever encounter references with exact spell IDs.
    -- https://www.wowhead.com/forever/dungeon-journal/scholomance/instructor-malicia
    [10505] = { [6064] = true }, -- Instructor Malicia, Heal.
    -- https://www.wowhead.com/forever/guide/upper-blackrock-spire-dungeon-overview-location-rewards
    [10742] = { [16637] = true }, -- Blackhand Dragon Handler, Mend Dragon.
})
