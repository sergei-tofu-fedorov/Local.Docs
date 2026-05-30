# WEB-1523 — Metrics collection (interaction)

Runtime sequence of one `MetricsRefreshJob` tick — what the static layout in [`metrics.md`](metrics.md) § Code layout can't show: ordering, the once-per-day discovery branch, and the bounded per-account fan-out. Steps map 1:1 to `RunAsync` ([`metrics.md`](metrics.md) § Tick orchestration) and the funnel in [`../analyses/metrics.md`](../analyses/metrics.md) § Refresh strategy.

```mermaid
sequenceDiagram
    participant HF as Hangfire (in-proc)
    participant Job as MetricsRefreshJob
    participant Rdr as AccountMetricsReader
    participant Col as MetricsCollector
    participant Wtr as AccountMetricsWriter
    participant Mongo as Mongo (Federation)
    participant BQ as BigQuery account_metrics

    HF->>Job: RunAsync(ct)  %% hourly cron 0 * * * *
    Job->>Rdr: SelectExpiredAccountIdsAsync(BatchSize)
    Rdr->>BQ: SELECT WHERE expires_at < NOW() LIMIT 500
    BQ-->>Job: expired account_ids

    opt first tick of UTC day
        Job->>Mongo: invoices sweep (CreatedTime ≥ now-90d, IsDeleted in [false,null])
        Mongo-->>Job: active account_ids (~200-500k)
        Job->>Rdr: SelectMissingAccountIdsAsync(candidates)  %% BQ EXCEPT
        Rdr->>BQ: EXCEPT existing account_metrics.account_id
        BQ-->>Job: net-new candidates
        Job->>Mongo: accounts lookup (alive, non-technical)
        Mongo-->>Job: eligible net-new account_ids
    end

    loop bounded parallel, MaxConcurrentAccounts=32, per account_id
        Job->>Col: BuildAsync(accountId)
        Col->>Mongo: 4 aggregation pipelines (invoice/estimate/client/account)
        Mongo-->>Col: typed metric records
        Col-->>Job: AccountMetricsRow
        Job->>Wtr: UpsertAsync(row)
        Wtr->>BQ: Storage Write API CDC (_CHANGE_TYPE=UPSERT)
    end
```

The two stores touched per tick — Mongo and BigQuery — are independent connections ([`metrics.md`](metrics.md) § Connection wiring), no shared abstraction. The discovery branch (`opt`) writes nothing; it only enqueues `account_id`s into the same parallel loop the expired-row pass feeds. The FSM-using-account exclusion is **not** part of this tick — `account_metrics` is analysis-agnostic. Dropping FSM users is an FSM-fit audience filter applied by `AnalyzeFsmFitJob`; see [`analyze.md`](analyze.md) § Audience eligibility.

> Method name `SelectMissingAccountIdsAsync` (BQ `EXCEPT`) is illustrative — `metrics.md` describes the call but does not name the method. Reconcile with the real signature once the code lands.
