# Nib

Native iPad/iPhone notes app: Goodnotes 6 parity, JavaScript plugins and bring-your-own AI.

Everything lives in [`docs/`](docs/): start with [ARCHITECTURE.md](docs/ARCHITECTURE.md) (build contract and rules),
then [CONTRACTS.md](docs/CONTRACTS.md) (shared source), [FEATURES.md](docs/FEATURES.md), [PLUGIN_API.md](docs/PLUGIN_API.md),
[AI.md](docs/AI.md) and [forge-spec.json](docs/forge-spec.json) (who builds and owns what).

CI (GitHub Actions, macos-26 / Xcode 26.6) builds an unsigned IPA from `main`; `feat/<FeatureID>` branches get a fast
per-feature build and test run.
