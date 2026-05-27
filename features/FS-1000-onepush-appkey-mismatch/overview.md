# FS-1000 — OnePush AppKey Mismatch — Implementation Plan

## Summary

OnePush rejects ~1–3 pushes per day with `ApnsException: The device token does not match the specified topic`. The root cause is that the **AppKey we send at `POST /pushes` is taken from the caller's context** (controller `ProductKey`, invoice `ProductKey`, Hangfire param), while the **AppKey under which the device token is actually registered** (set at `PUT /accounts/{id}`) can be different. APNS treats the AppKey as the iOS bundle / topic and rejects the push when the registered topic and the send-time topic do not match.

Fix: persist the AppKey used at registration on the `Account` Mongo document, and use that **canonical AppKey** at send time instead of trusting the caller. Caller-provided `productKey` is kept only as a fallback for accounts that have not re-registered after deploy.

Where it lives:

- Mongo `accounts` collection in `invoicesDB` — shared by gateway and worker.
- Gateway registration + send — `Invoices.Backend/Src/Invoices.Common/Services/Push/PushService.cs`, `Invoices.Backend/Src/Invoices.Api/Controllers/V1/AccountController.cs`.
- Worker send — `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Push/PushService.cs`, `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Push/OnePushApiGateway.cs`.

## Current State

- **Registration** — the only point is `AccountController.PutIdentifiers` (`Invoices.Backend/Src/Invoices.Api/Controllers/V1/AccountController.cs:222`). On every `PUT /api/account/set_identifiers` with a non-empty `pushToken`, the gateway calls `_pushService.CreateOrUpdateAccountAsync(AccountId, ProductKey, platform, pushToken)`. `ProductKey` here comes from `BaseController.ProductKey` ← `XA-App-Type` header, so it reflects the **real client bundle** (`tofu-fieldservice-worker`, `tofu-fieldservice`, `invoices`, `invoices-android`, …).
- **Gateway send** — `Invoices.Backend/Src/Invoices.Common/Services/Push/PushService.cs:46` calls `_apiClient.CreatePushAsync(accountId, productKey, …)`. `productKey` is taken from the caller:
  - `EmailCallbackService.cs:203` → `template.ProductKey` (from the email-callback push template),
  - `TeamNotificationService.cs:44` → controller `ProductKey` of the inline sender,
  - `Notifications/.../PushDeliveryJob.cs:27` → `PushDeliveryParams.ProductKey` baked in at enqueue time.
- **Worker send** — `Tofu.Invoices.Backend/src/Tofu.Invoices.Worker/Job/SendPastDueDatePushJob.cs:134,189` calls `_pushService.SendWithParams(accountId, invoice.ProductKey, …)` → `OnePushApiGateway.CreatePushAsync` (`Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Push/OnePushApiGateway.cs:37`).
- **Normalisation** — both gateways apply `FixUpInvoicesAppKeyName` which collapses `invoices / demo-invoices / invoices-android → "Invoices"`. FSM bundles (`tofu-fieldservice`, `tofu-fieldservice-worker`) pass through unchanged because they are distinct iOS apps with distinct APNS topics.
- **Confirmed mismatch** — `AccountId=47e42f70`: device registered with `XA-App-Type=tofu-fieldservice-worker`, send attempt issued under a different AppKey → APNS topic mismatch → alert.
- **Shared storage** — both services connect to the same MongoDB `invoicesDB` and read/write the same `accounts` collection:
  - Gateway: `Invoices.Backend/Src/Invoices.Implementation.MongoDb/Repositories/Shared/MongoDbContext.cs:25,104` — `DatabaseName = "invoicesDB"`, `GetCollection<Account>("accounts")`.
  - Worker: `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Database/MongoDbContext.cs:41` — `mongoClient.GetDatabase("invoicesDB")`; `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Models/Account.cs:39` — `ClassifyCollection() => "accounts"`.
  - Worker reads only a minimal projection (`Timezone`, `Store`); writes are exclusive to the gateway (`AccountsRepository.InsertOrUpdateAsync` in `Invoices.Implementation.MongoDb`).

### Gaps

- **No persisted record of which AppKey owns the active device token.** Nothing on `Account` (or anywhere else in our DB) ties an `accountId` to the bundle that successfully registered with OnePush.
- **Send-time AppKey is not validated against registration-time AppKey.** Both `PushApiClient.CreatePushAsync` (gateway) and `OnePushApiGateway.CreatePushAsync` (worker) forward the caller's `productKey` straight to OnePush.
- **OnePush alert payload does not include `accountId` / stored AppKey / incoming AppKey**, so each alert requires log correlation by hand.

## Changes by Layer

Numbered sections also define execution order: each step builds on the previous.

### 1. Mongo `Account` — `RegisteredPushAppKey` field

**Modified domain models** (both target the same Mongo document — no migration script needed, the field is nullable and stays absent for legacy docs):

- Gateway: `Invoices.Backend/Src/Invoices.Core/Models/Account.cs` — add `string? RegisteredPushAppKey { get; set; }`. The field is written by the gateway and consumed by both services.
- Worker proxy: `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Models/Account.cs` — add the same `string? RegisteredPushAppKey { get; set; }` so the worker's read projection includes it.

```
// Invoices.Core.Models.Account (gateway, writer)
public class Account : ...
    public string? RegisteredPushAppKey { get; set; }   // canonical AppKey under
                                                        // which the active device token
                                                        // is registered in OnePush.

// Tofu.Invoices.Domain.Models.Account (worker, reader projection)
public class Account : VersionedEntity<Account>, IClassifyCollection
    public string? Timezone { get; set; }
    public string? Store { get; set; }
    public string? RegisteredPushAppKey { get; set; }
```

No collection schema change; MongoDB tolerates the extra property in existing documents.

### 2. Gateway — persist canonical AppKey on registration

**Modified**:
- `Invoices.Backend/Src/Invoices.Common/Services/Push/PushService.cs` — after a successful `_apiClient.PutAccountAsync`, persist the normalised AppKey on the `Account`.
- `Invoices.Backend/Src/Invoices.Core/Repositories/IAccountsRepository.cs` (and the Mongo implementation) — add `SetRegisteredPushAppKeyAsync(string accountId, string appKey, CancellationToken ct)` doing a targeted `UpdateOneAsync({_id: accountId}, $set: {RegisteredPushAppKey: appKey})`. A targeted update avoids any race with concurrent `Account` upserts and never resurrects deleted accounts.

`CreateOrUpdateAccountAsync` shape:

```
1. canonicalAppKey = FixUpInvoicesAppKeyName(productKey)
2. await _apiClient.PutAccountAsync(accountId, new PushAccountModel { AppKey = canonicalAppKey, ... })
   // OnePush is the source of truth; we only persist what it accepted.
3. await _accountsRepository.SetRegisteredPushAppKeyAsync(accountId, canonicalAppKey, ct)
```

The persistence happens **after** OnePush accepted the registration, so the stored value is guaranteed to match the topic OnePush actually associated with the device token. If step 2 fails the value is not written — the next `set_identifiers` retries.

### 3. Gateway — use canonical AppKey on send

**Modified**:
- `Invoices.Backend/Src/Invoices.Common/Services/Push/PushService.cs` — inject `IAccountsRepository`; in `SendWithParams`, resolve the registered AppKey before calling `IPushApiClient.CreatePushAsync`.
- `Invoices.Backend/Src/Invoices.Implementation.OnePush/Client/PushApiClient.cs` — no behaviour change; `FixUpInvoicesAppKeyName` stays for callers that bypass `PushService` (none today, but it is cheap defence).

`SendWithParams` shape:

```
1. account = await _accountsRepository.FindAsync(accountId, ct)
2. registered = account?.RegisteredPushAppKey
3. canonicalCaller = FixUpInvoicesAppKeyName(callerProductKey)
4. appKey = !string.IsNullOrEmpty(registered) ? registered : canonicalCaller
5. if (registered != null && registered != canonicalCaller)
       _logger.LogInformation(
         "Push AppKey overridden for '{AccountId}': caller='{Caller}', registered='{Registered}'",
         accountId, canonicalCaller, registered)
6. return await _apiClient.CreatePushAsync(accountId, appKey, templateKey, templateProps)
```

The override log gives a direct metric of how often we prevented an APNS rejection — the `LogInformation` count after deploy should track the previous alert rate.

### 4. Worker — use canonical AppKey on send

**Modified**:
- `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Push/PushService.cs` — inject `IAccountsRepository`; resolve the registered AppKey before calling the gateway.
- `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Push/OnePushApiGateway.cs` — no behaviour change; `FixUpInvoicesAppKeyName` stays as a defence.

`SendWithParams` shape (mirror of step 3):

```
1. account = await _accountsRepository.Get(accountId, token)
   // `Get` already exists; we re-use the same call SendPastDueDatePushJob makes
   // a few lines later, so callers can be refactored to pass `account` in to avoid
   // a duplicate read if desired.
2. registered = account?.RegisteredPushAppKey
3. canonicalCaller = FixUpInvoicesAppKeyName(callerProductKey)
4. appKey = !string.IsNullOrEmpty(registered) ? registered : canonicalCaller
5. if (registered != null && registered != canonicalCaller)
       _logger.LogInformation(
         "Push AppKey overridden for '{AccountId}': caller='{Caller}', registered='{Registered}'",
         accountId, canonicalCaller, registered)
6. return await _apiGateway.CreatePushAsync(accountId, appKey, templateKey, templateProps, token)
```

Worker never writes `RegisteredPushAppKey` — only the gateway does, on `set_identifiers`.

### 5. Wiring & DI

- Gateway: `PushService` already takes `IPushApiClient` + `ILogger`; add `IAccountsRepository`. Already registered in the Mongo module — no new DI binding.
- Worker: `Tofu.Invoices.Infrastructure/ServiceCollectionExtensions.cs:50` (`services.AddScoped<IPushService, PushService>()`) stays as is; `IAccountsRepository` is already registered and resolvable from the worker scope.

### 6. Logging & metrics

- `Push AppKey overridden` (`LogInformation`) is the primary observability signal. Surface it in Grafana as an aggregate over `accountId` and `caller → registered` pairs. Expected post-deploy: counts roughly equal to previous alert volume in `#fax-push-alerts` then decaying as senders use the canonical AppKey directly.
- No new exception types; OnePush exceptions stay surfaced via the existing `PushAccountNotFoundException` / `PushApiException` paths.

## Behaviour

### `POST /pushes` body (outgoing to OnePush)

`AppKey` in the request body is the **registered** value if known, otherwise the normalised caller value. All other fields are unchanged.

Example — gateway path, `accountId` registered as `tofu-fieldservice-worker`, caller passes `productKey="invoices"`:

```json
{
  "accountId": "47e42f70...",
  "appKey": "tofu-fieldservice-worker",
  "templateKey": "InvoicesAlert",
  "templateProps": { ... }
}
```

Same scenario before the fix would have sent `"appKey": "Invoices"` and been rejected by APNS.

### `PUT /api/account/set_identifiers` (no protocol change)

Request body, headers, and response are unchanged. The new effect is a side-write of `RegisteredPushAppKey` on the Mongo `accounts` document **after** OnePush accepts the registration.

### Fallback semantics

| Scenario | `appKey` sent to OnePush |
|---|---|
| `RegisteredPushAppKey` present and matches normalised caller | unchanged from today (caller value) |
| `RegisteredPushAppKey` present and differs from caller | **registered value** — override + `LogInformation` |
| `RegisteredPushAppKey` absent (pre-deploy account, no re-registration yet) | normalised caller value — same as today |
| `accountId` not found in Mongo `accounts` | normalised caller value — same as today; OnePush will still 4xx with `AccountNotFound` if it does not know the token, identical to current behaviour |

## Backward Compatibility

- Additive: a new nullable Mongo field, a new repository method, additional reads from `PushService`. No data migration.
- Existing pushes for accounts that have not re-registered since deploy keep behaving as today — same caller `productKey`, same outcome. The fix is non-disruptive while it gradually takes effect.
- Public push API (`IPushService.SendWithParams`, `IPushService.CreateOrUpdateAccountAsync`) signatures are unchanged. All resolution happens inside the implementation.
- OnePush API contract (`PUT /accounts`, `POST /pushes`) is untouched — no coordination with OnePush owners required.

## Backfill / Rollout

No active backfill. `RegisteredPushAppKey` is populated lazily on the next `set_identifiers` call from each client, which happens on every app launch. Until the field is populated, the affected account keeps using the caller-provided `productKey` — i.e. the previous behaviour — so accounts whose alert was caused by the mismatch will continue to generate ~1–3 alerts per day for roughly one to two weeks while clients re-register naturally.

This is acceptable:

- The alert volume is already low (~1–3/day).
- Attempting a server-side backfill (querying OnePush for the AppKey of every account, or replaying registrations) is risky and offers no meaningful win over waiting for organic re-registration.
- The override log gives a clear leading indicator: it should start firing within hours of the deploy and the residual alert count should trail to zero within ~14 days.

If decay stalls (e.g. specific accounts that never re-register), the same one-shot script can be added later — out of scope for v1.

## Out of Scope

- **OnePush-side change** to use the device-token-registered AppKey transparently on send (would obsolete this fix entirely). Tracked as an optional follow-up to the OnePush owners; this plan assumes no access to OnePush.
- **Extending `FixUpInvoicesAppKeyName`** for FSM bundles (`tofu-fieldservice`, `tofu-fieldservice-worker`). These are distinct iOS apps with distinct APNS topics — collapsing them would re-introduce the mismatch. The canonical-AppKey mechanism above is the correct fix.
- **Active backfill** of `RegisteredPushAppKey` for pre-deploy accounts (see above).
- **Improving the OnePush alert payload** to include `accountId + storedAppKey + incomingAppKey` — separate ask to OnePush owners, listed only as an optional diagnostic improvement.

## Testing

### Gateway — Unit (`Invoices.Backend/Src/Invoices.Tests`)

- `PushServiceTests`:
  - `SendWithParams` — `RegisteredPushAppKey = "tofu-fieldservice-worker"`, caller passes `productKey = "invoices"` → verifies `_apiClient.CreatePushAsync` is called with `appKey = "tofu-fieldservice-worker"` and an override log is emitted.
  - `SendWithParams` — `RegisteredPushAppKey = null` → verifies `_apiClient.CreatePushAsync` is called with the normalised caller value (fallback) and no override log is emitted.
  - `SendWithParams` — `RegisteredPushAppKey` equals the normalised caller value → no override log.
  - `CreateOrUpdateAccountAsync` — `PutAccountAsync` succeeds → `SetRegisteredPushAppKeyAsync` is called with the normalised `productKey`.
  - `CreateOrUpdateAccountAsync` — `PutAccountAsync` throws → `SetRegisteredPushAppKeyAsync` is **not** called.

### Gateway — Integration (`Invoices.Backend/Src/Invoices.IntegrationTests`)

- `AccountControllerV1Tests`: `PUT /api/account/set_identifiers` with `XA-App-Type: tofu-fieldservice-worker` and a non-empty `pushToken` → after the call, the Mongo `accounts` document for the test account has `RegisteredPushAppKey = "tofu-fieldservice-worker"`.

### Worker — Unit (`Tofu.Invoices.Backend/tests/Tofu.Invoices.UnitTests`)

- `PushServiceTests`:
  - Mirror of the gateway unit tests, but verifying `IOnePushApiGateway.CreatePushAsync` is called with the registered AppKey when present and the caller value when absent.
- `SendPastDueDatePushJobTests`:
  - Existing assertions on `_pushService.SendWithParams(invoice.AccountId, invoice.ProductKey, …)` stay valid — the test mocks `IPushService` directly, so the override logic is exercised by the `PushService` unit tests.

### Worker — Functional (`Tofu.Invoices.Backend/tests/Tofu.Invoices.FunctionalTests`)

- Seed an `Account` document with `RegisteredPushAppKey = "tofu-fieldservice-worker"` and a past-due `Invoice` with `ProductKey = "invoices"`. Run `SendPastDueDatePushJob`. Assert the recorded outbound `POST /pushes` body (via the test container's OnePush stub) has `appKey = "tofu-fieldservice-worker"`.

## Acceptance

- 7 days after deploy: no new `ApnsException: The device token does not match the specified topic` events in `#fax-push-alerts` attributable to accounts that have re-registered post-deploy. (Allow residual alerts from accounts that have not re-launched their app — see Backfill / Rollout.)
- Existing push flows (overdue invoices, payment notifications, email-callback pushes, team notifications) continue working with unchanged latency.
- Override-log volume after deploy is non-zero and trends towards previous alert volume, confirming the mechanism is exercising the override path on real traffic.
