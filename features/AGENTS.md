# Features — index

Cross-product / cross-repo feature docs and plans. One folder per feature; `features/<TASK>/README.md` is that feature's plan, with deeper docs beside it. Up: [`../AGENTS.md`](../AGENTS.md).

## Current features

| Feature | What it is | Entry |
|---|---|---|
| `WEB-1523-segmentation` | AI-powered user-analysis platform (FSM-fit) — the framework/spec home; large tree (`analyses/`, `implementation/`, `investigation/`). | [README](WEB-1523-segmentation/README.md) |
| `WEB-1526` | CI/CD changes for the `Tofu.AI.Backend` FSM-fit pipeline. | [README](WEB-1526/README.md) |
| `WEB-1526-prep` | Groundwork: `Tofu.AI.Backend` to canonical form (src/ move, ports/adapters) + `Invoices.Kubernetes` fixes. | [README](WEB-1526-prep/README.md) |
| `WEB-1527` | Account-metrics collection implementation in `Tofu.AI.Backend`. | [README](WEB-1527/README.md) |
| `WEB-1529` | Assign admin role on business-account creation (eager path + backfill). | [README](WEB-1529/README.md) |
| `WEB-1479` | Pass auth from mobile into a Safari web view via Firebase (ID vs custom token); land users on the web-app home. | [README](WEB-1479/README.md) |
| `ai_summary` | Earlier AI-Summary / FSM-compatibility exploration (superseded by WEB-1523). | [README](ai_summary/README.md) |

## Convention

A feature folder's plan is its `README.md`. Keep this index in sync when a feature folder is added or removed.
