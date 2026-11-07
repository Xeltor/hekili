# Hekili Forever fork

- Treat [Hekili Forever upstream](https://github.com/zmsl/hekili/tree/forever) as the authority for max-level damage priorities and their WoWSims baselines.
- Extend those priorities across levels 1–60 with learned-spell fallbacks and situational PvE utility and survivability. Apply outdoor pull rules by encounter context in both solo and party play.
- Extend the existing class rotations in their priority sources or recipes. Reuse the upstream content API and rotation generator, and regenerate checked-in pack output with the upstream tooling.
- Verify spell requirements against Forever data, including learned ranks, equipment, permitted stances or forms, and target or range limits. Cover the allowed and blocked cases when adding a recommendation.
- Follow [DEVELOPMENT.md](DEVELOPMENT.md) for the core and content boundary, client secret-value safety, pack generation, and validation. Exercise the relevant leveling and solo scenarios alongside upstream's max-level replay and regression checks.
- Develop on the fork's `forever` branch and push only to `origin`. Pull from `upstream/forever` when an update is wanted. The linked WoW client reads the checked-out files.

See [Leveling and PvE development](docs/dev/leveling-and-solo.md) for the design rules, sync workflow, and linked installation.
