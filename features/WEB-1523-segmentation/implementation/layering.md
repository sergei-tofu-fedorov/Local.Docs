# WEB-1523 — Data-access layering (services / repositories / collectors)

> **Status (2026-05-30).** Describes the `Analyses.{Domain,Application,Infrastructure,Persistence}` data-access layer on `feature/WEB-1557` (`Tofu.AI.Backend`) and the consistent style applied to it. **Option A is applied** (uncommitted working tree on `feature/WEB-1557`): the invoice item-names read renamed repo→`InvoiceSignalsCollector` (broader name — invoice text signals for the payload; notes etc. join later) and graduated to `Domain/Services`. The four leaf metrics collectors stay concrete (no interface) — they are infra-internal collaborators of the `IMetricsCollector` façade, injected by type. Companion to [`service.md`](service.md) (runtime shape) and [`metrics.md`](metrics.md) / [`metrics-interaction.md`](metrics-interaction.md) (what each metric means). Source of truth for the shipped code is `Tofu.AI.Backend/Docs/features/{WEB-1527,WEB-1555}/`.

## Code layout

Current `Analyses` module + the API host, annotated by role. `[Coll]` collector · `[Repo]` store-of-record repository · `[Scorer]` pure rule · `[Orch]` orchestration · `[Svc]` read service · `[Iface]` domain contract. `⚠` marks the inconsistencies this doc targets.

```
src/
├─ Analyses.Domain/                      contracts + pure rules — no I/O
│  ├─ Analysis/InputHash.cs
│  ├─ Llm/{IFsmFitLlmClient, Prompts/FsmFitPrompt}.cs            [Iface]
│  ├─ Models/                            AccountMetricsRow, AccountFsmFitRow,
│  │                                     FsmFit{Evidence,Flags,Offer,Payload,
│  │                                     RuleResult,Tier}, Industry, RecommendedOffer
│  ├─ Repositories/                                              [Iface]
│  │  ├─ IAccountMetricsRepository.cs        → BigQuery store
│  │  ├─ IAccountFsmFitRepository.cs         → BigQuery store
│  │  └─ IInvoiceItemNamesRepository.cs   ⚠ → Mongo source (named Repo, is a Collector)
│  ├─ Scorers/FsmFitScorer.cs                                    [Scorer]  decision rules
│  └─ Services/{IMetricsCollector, IAccountDiscovery}.cs         [Iface]
│
├─ Analyses.Application/                 orchestration + read side
│  ├─ Jobs/{MetricsRefreshJob, AnalyzeFsmFitJob}.cs             [Orch]
│  ├─ Read/{IFsmFitReadService, FsmFitReadService, FsmFitResponse}.cs  [Svc]
│  ├─ AnalysesMappings.cs · {Metrics,FsmFit}Options.cs · DependencyInjection.cs
│
├─ Analyses.Infrastructure/             ⚠ source reads — split nouns, uneven ifaces
│  ├─ Metrics/
│  │  ├─ Collectors/
│  │  │  ├─ InvoiceMetricsCollector.cs   ⚠ [Coll] no iface, owns CV / repeat-window rule
│  │  │  ├─ EstimateMetricsCollector.cs  ⚠ [Coll] no iface, owns conversion-rate rule
│  │  │  ├─ ClientMetricsCollector.cs    ⚠ [Coll] no iface, owns B2B regex / multi-addr rule
│  │  │  ├─ AccountMetricsCollector.cs   ⚠ [Coll] no iface
│  │  │  └─ MetricsCollector.cs              [Coll] façade — fan-out + compose (has iface)
│  │  ├─ InvoiceItemNamesRepository.cs   ⚠ [Coll] Mongo source read misnamed Repository
│  │  ├─ AccountDiscovery.cs                 [Coll] selector — eligibility gate, returns ids
│  │  └─ MetricWindow.cs
│  ├─ Mongo/   BsonReads · Collections · MongoConventions · MongoDatabaseFactory · MongoFilters
│  ├─ Llm/{OpenAiFsmFitClient, OpenAiOptions}.cs
│  └─ AnalysesConnectionStrings.cs · DependencyInjection.cs
│
├─ Analyses.Persistence/                store-of-record (BigQuery) + migrations
│  ├─ Repositories/
│  │  ├─ BigQueryAccountMetricsRepository.cs [Repo] pure row CRUD/upsert
│  │  └─ BigQueryAccountFsmFitRepository.cs  [Repo] pure row CRUD/upsert
│  ├─ BigQuery/   BigQueryMappings · Reads · Time · Options · StorageWriteApiHelper
│  ├─ Migrations/ ModuleMigration framework + Modules/BigQuery/V001..V003
│  ├─ Protos/     account_metrics.proto · account_fsm_fit.proto
│  └─ DependencyInjection.cs
│
└─ Tofu.AI.Api/                          host
   ├─ Controllers/AccountAnalysesController.cs   → FsmFitReadService
   ├─ Hangfire/{HangfireConfiguration, AnalysesHangfireOptions}.cs
   └─ Program.cs · DatabaseUpdate.cs (migrate CLI) · … (+ existing Chat* surface)
```

**Reading the `⚠`:** every flag is in `Analyses.Infrastructure`. Two leaf-level issues — a Mongo source read named `…Repository` (`InvoiceItemNamesRepository`), and four `[Coll]` leaf collectors with no domain interface.

### As applied (Option A)

Two mechanical moves; only the changed lines are shown. The four leaf metrics collectors keep concrete injection (no interface — see note); only the cross-layer invoice-signals contract is renamed and graduated to `Domain`. The collector is named `InvoiceSignals…` (broader than item-names) so further invoice-sourced text signals — e.g. invoice notes — join it without another rename.

```
Analyses.Domain/
  Repositories/IInvoiceItemNamesRepository.cs  →  Services/IInvoiceSignalsCollector.cs   [Iface]
                                                  (public — consumed by AnalyzeFsmFitJob)

Analyses.Infrastructure/Metrics/
  Collectors/{Invoice,Estimate,Client,Account}MetricsCollector.cs  →  unchanged (concrete)  [Coll]
  Collectors/MetricsCollector.cs          →  façade — still injects the four by concrete type
  InvoiceItemNamesRepository.cs           →  Collectors/InvoiceSignalsCollector.cs           [Coll]

Analyses.Persistence/Repositories/   ← the only BigQuery `*Repository` classes (store-of-record)
  BigQueryAccountMetricsRepository.cs · BigQueryAccountFsmFitRepository.cs        [Repo]
```

> **Why the leaf collectors are not interfaced.** Each returns an infra-internal result record (`InvoiceMetricsResult`, `EstimateMetricsResult`, `ClientMetricsResult`) — an intermediate aggregation shape, not a domain concept — and is only ever consumed by the `MetricsCollector` façade within the same project. An interface buys nothing across a layer boundary here (a `Domain` interface would force those records into `Domain.Models`, and an `internal` Infra interface only abstracts a class from its single same-assembly caller), so they stay concrete. Only `IInvoiceSignalsCollector` is a genuine cross-layer port (Application → source) and keeps its interface, in `Domain/Services`; it returns the composite `InvoiceSignals { TopItemNames, Notes }` (in `Domain.Models`), built by `CollectAsync(accountIds, InvoiceSignalLimits, ct)`.

After this, the noun tells you the home: **`*Collector` ⇒ `Infrastructure` (source + rule)**, **`*Repository` ⇒ store-of-record**, **`*Scorer` ⇒ `Domain` (pure)**.

## Problem

The module is clean 4-layer DDD, but the **data-access tier uses three different nouns for one job** — "read a store and shape data" — split across two projects with uneven interface coverage. The result reads inconsistently even though every class does a variant of the same thing.

| Class | Noun | Project | Store | Owns rule logic? | Domain iface |
|---|---|---|---|---|---|
| `BigQueryAccountMetricsRepository`, `BigQueryAccountFsmFitRepository` | **Repository** | Persistence | BigQuery | No — row CRUD/upsert | ✅ |
| `InvoiceItemNamesRepository` | **Repository** | Infrastructure/Metrics | Mongo | **Yes** — unwind / group / top-N | ✅ |
| `InvoiceMetricsCollector`, `EstimateMetricsCollector`, `ClientMetricsCollector`, `AccountMetricsCollector` | **Collector** | Infrastructure/Metrics/Collectors | Mongo | **Yes** — CV, B2B regex, repeat-window, `multi_address ≥ 2`, conversion rate | ❌ (concrete `internal`) |
| `MetricsCollector` (façade) | **Collector** | Infrastructure/Metrics/Collectors | — | No — fan-out + compose | ✅ |
| `AccountDiscovery` | **Discovery** | Infrastructure/Metrics | Mongo | **Yes** — eligibility gate | ✅ |

Three concrete inconsistencies fall out of that table:

1. **Naming.** A Mongo read called `…Repository` (item-names) sits next to four Mongo reads called `…Collector` (metrics). Same store, same pattern, different word — the noun carries no information.
2. **Home.** BigQuery data access lives in `Persistence`; Mongo + Postgres data access lives in `Infrastructure`. "Which project holds a query" depends on the store, not the role.
3. **Rule placement.** Scoring rules are pure and in `Domain` (`FsmFitScorer`), but **metric rules are pushed down into Mongo BSON pipelines** in `Infrastructure`, and the four leaf collectors are concrete `internal` classes with no interface — the one group of classes carrying the most business logic is the least abstracted.

## Pushdown is deliberate — keep it

The metric formulas live inside the aggregation pipelines on purpose: `$stdDevPop`/`$avg` for the coefficient of variation, the `LLC|Inc|Corp|…` B2B regex, the 30-day / 12-month windows, `$setUnion` distinct-address counting. Pulling those into C# would stream **every live invoice / client row per account into app memory** and recompute there — see [`investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md). For this workload **the query *is* the metric definition**, and that is the right call. So the fix is **not** to relocate the rules — it is to **name the role that owns them** and apply it uniformly.

## The three roles (target vocabulary)

Collapse the data-access tier onto **three roles, each with one home and one responsibility**:

| Role | Responsibility | Owns rule logic? | Store(s) | Home project |
|---|---|---|---|---|
| **Collector** | Read a **source** system and compute a metric/signal contribution. The pipeline *is* the rule (pushdown). | **Yes — source-side rules** | Mongo | `Infrastructure` |
| **Repository** | Read/write the analyses **store-of-record** as typed rows. No business rules — pure persistence. | No | BigQuery | `Persistence` |
| **Scorer / Rule** | Pure in-memory **decision** over already-fetched data. No I/O. | **Yes — decision rules** | — | `Domain` |

Rule logic ends up in exactly two honest places — **Collector** (source-side, inseparable from the query) and **Scorer** (decision-side, pure) — and the **store Repository stays rule-free**, so the boundary is clean and predictable. This is the recommended end state; the options below differ only in *how far* you push toward it.

---

## Options

### Option A — Name the Collector role *(recommended)*

Make **Collector** a first-class, interfaced role; reserve **Repository** for the BigQuery store-of-record only. Smallest churn, addresses all three inconsistencies, keeps pushdown.

- **Rename** `InvoiceItemNamesRepository` → `InvoiceSignalsCollector` (it reads a source + shapes — it is a collector, not a store repo; named for its role — invoice text signals for the payload — not the single field, so notes etc. fit later). `AccountDiscovery` stays, documented as a *selector* collector (returns ids, computes no metric).
- **Interface only the cross-layer collectors.** The invoice-signals read becomes `IInvoiceSignalsCollector` in `Domain/Services` (consumed by Application). The four leaf metrics collectors stay concrete `internal` — they are same-project collaborators of the `IMetricsCollector` façade, so an interface buys nothing (see § "As applied" note). `IMetricsCollector` / `IAccountDiscovery` keep their existing contracts.
- **Rule reserved for the store**: only `Analyses.Persistence` holds classes named `*Repository` (the two BigQuery ones), so every source read is a Collector with zero exceptions.
- **Document the rule each collector encodes**: one line of XML-doc per collector pointing at its [`metrics.md`](metrics.md) definition, so the pushdown rule is discoverable without reading BSON.

**Pros:** one noun per role; rules in two honest homes; keeps Mongo pushdown perf; ~5 renames + interfaces, no logic moves. **Cons:** "Collector owns business logic" is a deliberate exception to textbook DDD; metric rules remain integration-tested, not unit-tested (mitigate by documenting + a Mongo functional test per collector).

### Option B — Everything that reads a store is a Repository

Drop "Collector" entirely; rename the four leaf collectors → `…MetricsRepository`, keep them in `Infrastructure`, accept fat repositories that own pushdown rules.

**Pros:** a single noun across the whole tier — minimum vocabulary. **Cons:** does **not** resolve inconsistency #3 — "Repository" now means both *rule-free store CRUD* (BigQuery) and *rule-bearing source aggregation* (Mongo), so the one word that was overloaded stays overloaded. Naming becomes uniform while the underlying split it is hiding gets worse. Not recommended.

### Option C — Extract metric rules into Domain (purist)

Collectors/repositories fetch **raw projections only**; every formula (CV, conversion rate, B2B classification, multi-address threshold) moves into pure `Domain` rule classes mirroring `FsmFitScorer`; orchestration becomes *fetch raw → compute in C# → compose row*.

**Pros:** all business logic in `Domain`, fully unit-testable, one rule style across metrics **and** scoring. **Cons:** abandons pushdown — streams full per-account invoice/client sets into app memory and recomputes `stdDev`/grouping in C#; directly contradicts the Mongo read-isolation decision. Heavy churn, real perf regression. Hold as a *future* direction only if metrics ever need to be reused outside the Mongo path.

---

## Recommendation

**Option A.** It is the only option that makes the tier uniform *and* keeps the pushdown the perf design depends on. Net change is mechanical: rename one repo→collector, lift four collectors to interfaces, fix the folder/home rule (`*Repository` ⇒ `Persistence`/store-of-record only), and add a doc-link per collector. After it lands, the rule for any future reader is one sentence:

> **Collector** reads a source and computes a signal (rules live here, pushed down). **Repository** reads/writes the BigQuery store-of-record (no rules). **Scorer** decides in memory (no I/O).

## Decision checklist

- [x] Interface the leaf collectors? — **No.** They are infra-internal collaborators of the `IMetricsCollector` façade, consumed only within `Analyses.Infrastructure`, so an interface abstracts a class from its single same-assembly caller and buys nothing. They stay concrete `internal`, injected by type. (A shared `IMetricContributionCollector<TResult>` was also rejected — the four `CollectBatchAsync` signatures differ: invoices/estimates take a `MetricWindow`, clients/accounts don't, and account returns `string?` not a record.)
- [ ] Folder shape under `Infrastructure` — single `Collectors/` (metrics + signals + discovery together) vs. the current `Metrics/Collectors/` + `Postgres/` + discovery split. **Left as-is** for now; revisit if a second analysis adds more source collectors.
