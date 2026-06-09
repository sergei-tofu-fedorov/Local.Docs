# Analytics events flows — Amplitude & the event bus

How product/billing events reach Amplitude (and GA4/AppsFlyer/BigQuery). Two **independent** pipelines carry **non-overlapping** event sets — verified against prod infra and the BQ audit tables on 2026-06-05.

## Path 1 — product analytics: `Tofu.Analytics.Backend` (store-and-forward)

Backend services push product events over HTTP to a dedicated analytics microservice, which outboxes them in Postgres and forwards to Amplitude.

```
Invoices.Backend (BFF)                       Tofu.Invoices.Backend
  Invoices.Analytics/AnalyticsService          Infrastructure/Analytics/AnalyticsApiGateway
       │  POST /api/events — fire-and-forget (send errors swallowed + logged)
       ▼
Tofu.Analytics.Api  /api/events  (NewEventEndpoint → NewAnalyticEventUseCase)
       │
       ▼
Postgres outbox (ConnectionStrings:pgsql_db, EF Core)
       │  SendingAnalyticsWorker — every 5 min
       │  SendAnalyticEventsUseCase: read batch → send → delete; ≤3 retries then DROP (warning log)
       ▼
AmplitudeProvider → POST https://api.amplitude.com/2/httpapi  (one event per request)
```

| Aspect | Detail |
|---|---|
| BFF sender | `Invoices.Backend/Src/Invoices.Analytics/AnalyticsService.cs` — payload `{productKey, eventType, payload:{occuredAt, userId, accountId, properties, userProperties}, id}`; target `ConnectionStrings:AnalyticsService` = `http://analytics-api-service` (in-cluster) |
| Provider config | `Analytics:Products:<Product>:Providers` (per-product list); **Amplitude is the only implemented provider** (`AnalyticsProviderFactory`) |
| Env routing | event `environment` property selects **sandbox vs prod Amplitude API key** (`AmplitudeProvider`) |
| Identity | Amplitude `user_id` = our userId; `accountId` injected into `event_properties` |
| Delivery | Lossy by design: BFF swallows HTTP errors; worker drops an event after 3 failed sends. Latency up to ~5 min (worker poll) |
| Event types (BFF-defined) | `"Email Notification Sent"`, `"Payment account status"`, `"Payment received"`, `"Payout received"`, `"Push sent"` (`Invoices.Common/Analytics/Events/*`); Tofu.Invoices adds its own via `AnalyticsApiGateway` |

## Path 2 — billing lifecycle: `Subz` event bus (Pub/Sub fan-out)

A subscription-processing pipeline (**"Subz" — owner outside this workspace**, no Pub/Sub client code exists in any workspace repo) publishes normalized account/subscription lifecycle events to Pub/Sub, which fan out to marketing tools and a BigQuery audit:

```
(store S2S notifications: topics apple_server_to_server_notifications,
 android_developer_notifications_topic — also BQ-audited to pubsub_audit.*)
        │
        ▼  Subz pipeline (external to this workspace)
topic: event_stream_incoming_events ──[BQ sub]──► event_stream.incoming_events_audit
        │ (enrichment consumer — external)
        ▼
topic: event_stream_enriched_events ──[BQ sub]──► event_stream.enriched_events_audit
        ├──► pull sub: Amplitude     (consumer external)
        ├──► pull sub: GA4           (consumer external)
        └──► pull sub: AppsFlyer     (consumer external)
```

Event types on the bus (counts from `event_stream.incoming_events_audit`, 2024-12 → 2026-06; envelope: `attributes.eventType` + JSON `data` with `AccountId`, `ProductKey`, `AdapterType`, `PublicId` e.g. Stripe `cus_*`, `Details`):

| `Subz.EventStream.Contracts.Events.*` | Count |
|---|---|
| `AccountUpdatedEvent` | 1.37M |
| `SubscriptionPaidEvent` | 1.10M |
| `AccountCreatedEvent` | 593K |
| `SubscriptionExpiredEvent` | 223K |
| `SubscriptionRenewalChangedEvent` | 173K |
| `SubscriptionBillingRetriedEvent` | 130K — **dunning / involuntary-churn signal, already normalized** |
| `SubscriptionTrialStartedEvent` | 100K |
| `AccountPlatformEventLinked` | 14K |
| `SubscriptionRefundedEvent` | 13K |
| `SubscriptionProductChangedEvent` | 121 |

## No overlap between the paths

Path 1 = product events named in app language ("Payment received"); Path 2 = billing lifecycle contracts (`Subz.*`). Verified by aggregating `eventType` over the full BQ audit (249 MB scan): **zero shared event types.** Retiring either path loses its event set in Amplitude.

## Adjacent touchpoints

- **Web frontend** sends to Amplitude **directly client-side** (e.g. `error_message` on HTTP failures — [`../../Web/backend_error_handling.md`](../../Web/backend_error_handling.md)).
- **Amplitude data returns** to the org via Playfair DWH (`amplitude_users_in_experiments_clean` AB-test marts in `playfair-project`).
- BQ datasets fed by this wiring (`event_stream`, `pubsub_audit`) — sizes/schemas/cost gotchas in [`../Storage/bigquery-sources.md`](../Storage/bigquery-sources.md).

## Subz pipeline ownership (resolved 2026-06-05)

The Subz repo lives at `C:\Git\Work\Subz` (deploys into `inv-project` per its README). Its `Subz.EventStream.Worker` owns the whole bus: enrichment (`Handler.Incoming`) **and** all fan-out consumers (`Handler.Amplitude`, `Handler.GoogleAnalytics4`, `Handler.AppsFlyer`, `Handler.BigQuery`) — the `Amplitude`/`GA4`/`AppsFlyer` pull subs are consumed by that worker, not by separate services.

`Handler.BigQuery` streaming-inserts all 13 events (no filtering) into per-product tables — **it is the writer of `inv-project:analytics.events` / `analytics_android.events` / `events_tofu-fieldservice*`** (the "backend" source in the `analytics.all_events` view = Subz, not our BFF). Destination filters: Amplitude all 13 + user-property Identify calls (`is_trial`, `subscription_product`, `renew_product`, cumulative `ltv`); AppsFlyer only 4 events and only when `IsInitialAccount ∧ IsBelongPurchaser ∧ IsProduction`; GA4 6 events when `IsInitialAccount ∧ IsBelongPurchaser`. Full per-event field reference: `C:\Git\Work\Subz\docs\analytics-events.md`.

Notable for integrations: `Subz.EventStream.Handler.Webhook` is a ready-made, **currently unused** webhook delivery channel — per-product config (`Webhook:Products:<productKey>` → `Url`, `EventTypes[]` filter), auto-provisioned `webhook-{productKey}` Pub/Sub subscription on `event_stream_enriched_events`, POSTs `{eventType, timestamp, productKey, data}` with an ES256-signed JWT (`subscription.paid`, `subscription.expired`, … — see `Subz.EventStream.Contracts/Webhook/WebhookEventTypes.cs`). Pub/Sub-backed retries (nack → redelivery with backoff). Event catalog: `C:\Git\Work\Subz\docs\analytics-events.md` (13 event types incl. one-time purchases).

Gotcha: neither raw nor enriched subscription events carry `ExpirationTime` — only `Duration`. Consumers needing subscription *state* should treat events as triggers and fetch authoritative state from the Subz API.
