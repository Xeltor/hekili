# Hekili Forever fork

- Treat [Hekili Forever upstream](https://github.com/zmsl/hekili/tree/forever) as the authority for max-level rotations and their WoWSims baselines. Keep the default max-level group and raid recommendations aligned with upstream.
- Focus fork work on leveling and solo PvE. Scope below-cap fallbacks to the character's available kit, and apply solo rules only when the relevant solo context is known.
- Extend the existing class rotations in their priority sources or recipes. Reuse the upstream content API and rotation generator, and regenerate checked-in pack output with the upstream tooling.
- Follow [DEVELOPMENT.md](DEVELOPMENT.md) for the core and content boundary, client secret-value safety, pack generation, and validation. Exercise the relevant leveling and solo scenarios alongside upstream's max-level replay and regression checks.
- Develop on the fork's `forever` branch. Pull from `upstream/forever` when an update is wanted. The linked WoW client reads the checked-out files.

See [Leveling and solo development](docs/dev/leveling-and-solo.md) for the design rules, sync workflow, and linked installation.
