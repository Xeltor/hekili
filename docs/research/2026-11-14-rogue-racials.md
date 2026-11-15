# Rogue racial additions: evidence and limits

Checked 2026-11-14 against the repository's WoWSims pin
`e5a9cd2a2dfc9e29e63fd6ec1fc7245ad4b44664` and Blizzard's 26 October development
notes. The local DB2 extract was unavailable for a fresh query; historical DB2
facts below are retained research, cross-checked against the pinned source.

## Windshaper Skyborne

- The pinned [class/race capabilities](https://github.com/wowsims/forever/blob/e5a9cd2a2dfc9e29e63fd6ec1fc7245ad4b44664/sim/core/character_constants.go#L134-L144)
  include Windshaper Skyborne Rogues. Tauren is absent from that Rogue list, so
  War Stomp is not an applicable Rogue racial under the supported data.
- The pinned [DB2 race mapping](https://github.com/wowsims/forever/blob/e5a9cd2a2dfc9e29e63fd6ec1fc7245ad4b44664/tools/database/dbc/util.go#L41-L49)
  identifies Windshaper as ChrRaces ID 96, playable-race bit 33. Registration
  matches ID 96 as well as the unconfirmed `WindshaperSkyborne` client token.
- [Pinned racial implementation](https://github.com/wowsims/forever/blob/e5a9cd2a2dfc9e29e63fd6ec1fc7245ad4b44664/sim/core/racials.go#L206-L263):
  Skysight 1259686 casts in 0.5 seconds, uses the normal spell GCD, has a
  120-second cooldown and applies Elemental Blessing 1259688 for 15 seconds.
  The IDs, cast and cooldown agree with the retained DB2 findings in
  [the mana-regeneration research](../superpowers/plans/2026-10-26-mana-regen-wowsims.md#task-14-shared-the-high-order-skybornes-read-ley-line-and-energized).
- [Blizzard's 26 October notes](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-november-2/2360696/7)
  give 15% movement speed for 15 seconds, increased to 30% while Charged.
  The addon models the temporary aura and cooldown, not movement distance,
  elemental convergence or Charged. It refuses the cast while moving because
  no cast-while-moving exception has been established. Timing a movement
  cooldown still requires a priority with an observable, relevant situation.

## Stoneform contract

The pinned [Dwarf implementation](https://github.com/wowsims/forever/blob/e5a9cd2a2dfc9e29e63fd6ec1fc7245ad4b44664/sim/core/racials.go#L13-L44)
models Stoneform as eight seconds of physical mitigation, on the GCD, with a
three-minute cooldown. The [retained DB2 research](2026-10-15-forever-races/research.md#22-dwarf-101)
also records its poison/disease/bleed removals. A removable effect is not a
spell requirement. The shared definition therefore permits mitigation without
a dispel; each class priority decides when it is useful. Existing Warrior and
Paladin Protection recommendations retain their former poison/disease gate
explicitly in the recipe/generator, so this Rogue change does not broaden those
classes' policy. Bleed detection and exact hostile spell school remain limited
by the readable client evidence; no missing information is invented.
