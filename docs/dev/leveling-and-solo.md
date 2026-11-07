# Leveling and PvE development

This fork extends Hekili Forever's existing endgame rotations across levels 1–60. Upstream's max-level damage priorities and WoWSims replays are the baseline for sustained group and raid fights.

## Rotation changes

- Build below-cap fallbacks around learned spells and ranks, available talents, and valid weapons, forms, stances, or pets. Use the existing `leveling` and `levelingFirst` recipe hooks when they fit. Confirm that the fallbacks stay inactive in the max-level baseline.
- Add interrupts, recovery, and defensives where their conditions justify them in PvE. Use outdoor context for choices such as short-pull rage spending and armor stacks. Apply those rules in regular parties as well as solo play. Use client evidence or the combat harness to verify the conditions.
- Extend the shipped rotation in its priority source or recipe, and regenerate the Lua pack using the existing tooling. Use shared code for behavior that belongs to multiple classes and keep class-specific decisions in the class pack.
- Cover a representative early kit, the unlock that changes the decision, and solo and group cases when relevant. Compare max-level group and raid recommendations against upstream with the same inputs. Use the existing headless scenarios and replay gates. Record the level, spec, talents, and encounter context for in-game checks, and keep upstream replay thresholds intact.

See the [upstream development guide](../../DEVELOPMENT.md), [pack authoring guide](wowsims-packs.md), and [in-game ledger](ingame-ledger.md) for the existing tools and checks.

The level 40 Arms scenario uses the [Icy Veins WoW Forever leveling build](https://www.icy-veins.com/wow-forever/arms-warrior-leveling#leveling-talent-build). The separate raid replay uses the pinned simulator fight and its historical spell cooldowns.

## Keeping current with upstream

`origin` is the fork. `upstream` is [zmsl/hekili](https://github.com/zmsl/hekili). Work on the fork's `forever` branch. When you want upstream updates, pull them into that branch from a clean checkout.

```sh
git switch forever
git pull --no-rebase upstream forever
```

If a pull touches a rotation we've extended, keep upstream's updated max-level damage priority and carry forward the leveling and PvE rules. Regenerate affected packs from their sources, then run the checks in the development guide. The game links point into the checkout, so finish the merge and checks before reloading in WoW.

## Testing in WoW Forever

Link each `src/<Addon>` directory containing `<Addon>.toc` as a separate entry under the client's `Interface/AddOns`. This includes `Hekili`, `Hekili_Shared`, and every class pack. On Linux use directory symlinks. For Windows and WSL see the [upstream setup instructions](../../DEVELOPMENT.md#link-the-addons-into-the-game-client).

When using Bottles via Flatpak, grant Bottles read-only access to the checkout's `src/` so it can follow the links. Restart Bottles after granting access and fully restart WoW when adding addon folders. For subsequent edits to existing Lua files, type `/reload` and use `/hekili` to check the addon. If editing an APL or recipe, regenerate its runtime pack before reloading. Keep the linked Hekili addons out of the addon manager's update cycle so it does not replace the links.
