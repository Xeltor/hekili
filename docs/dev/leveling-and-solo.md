# Leveling and solo development

This fork extends the existing Hekili Forever rotations for leveling and solo PvE. Use upstream's max-level rotations and WoWSims replays as the baseline for max-level group and raid play.

## Rotation changes

- Build below-cap fallbacks around learned spells and ranks, available talents, and valid weapons, forms, stances, or pets. Use the existing `leveling` and `levelingFirst` recipe hooks when they fit. Confirm that the fallbacks stay inactive in the max-level baseline.
- For solo play, consider short pulls, recovery between fights, resource conservation, defensive windows, and abilities that trigger on a kill. Use evidence from the Forever client or combat harness to choose when these recommendations apply. Fall back to the upstream priority when the context is uncertain. A single target can be a group encounter.
- Extend the shipped rotation in its priority source or recipe, and regenerate the Lua pack using the existing tooling. Use shared code for behavior that belongs to multiple classes and keep class-specific decisions in the class pack.
- Cover a representative early kit, the unlock that changes the decision, and solo and group cases when relevant. Compare max-level group and raid recommendations against upstream with the same inputs. Use the existing headless scenarios and replay gates. Record the level, spec, talents, and encounter context for in-game checks, and keep upstream replay thresholds intact.

See the [upstream development guide](../../DEVELOPMENT.md), [pack authoring guide](wowsims-packs.md), and [in-game ledger](ingame-ledger.md) for the existing tools and checks.

## Keeping current with upstream

`origin` is the fork. `upstream` is [zmsl/hekili](https://github.com/zmsl/hekili). Work on the fork's `forever` branch. When you want upstream updates, pull them into that branch from a clean checkout.

```sh
git switch forever
git pull --no-rebase upstream forever
```

If a pull touches a rotation we've extended, keep upstream's updated max-level behavior and carry forward the leveling and solo rules. Regenerate affected packs from their sources, then run the checks in the development guide. The game links point into the checkout, so finish the merge and checks before reloading in WoW.

## Testing in WoW Forever

Link each `src/<Addon>` directory containing `<Addon>.toc` as a separate entry under the client's `Interface/AddOns`. This includes `Hekili`, `Hekili_Shared`, and every class pack. On Linux use directory symlinks. For Windows and WSL see the [upstream setup instructions](../../DEVELOPMENT.md#link-the-addons-into-the-game-client).

When using Bottles via Flatpak, grant Bottles read-only access to the checkout's `src/` so it can follow the links. Restart Bottles after granting access and fully restart WoW when adding addon folders. For subsequent edits to existing Lua files, type `/reload` and use `/hekili` to check the addon. If editing an APL or recipe, regenerate its runtime pack before reloading. Keep the linked Hekili addons out of the addon manager's update cycle so it does not replace the links.
