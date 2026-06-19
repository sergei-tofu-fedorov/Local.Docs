# BFF alerts clean-up (invoices-api / invoices-worker)

Goal: stop the `severity>=ERROR` alert for the Invoices BFF from being dominated by
**handled business conditions and client-side noise**, so that a real ERROR is again a
signal worth paging on. We do this by (a) downgrading the log level of expected/handled
exceptions and (b) mapping framework/client exceptions that today fall through to the
generic `Exception → LogError` handler.

## The alert this targets

```
(resource.type="k8s_container" AND resource.labels.cluster_name="tofu-cluster"
   AND resource.labels.container_name="invoices-api"    severity>=ERROR)
OR
(resource.type="k8s_container" AND resource.labels.cluster_name="tofu-cluster"
   AND resource.labels.container_name="invoices-worker" severity>=ERROR)
```

## How the data was collected

Prod project `inv-project` (alerts fire on prod), last 7 days, account `s.fedorov@tofu.com`:

```bash
gcloud logging read '<alert filter above>' \
  --project=inv-project --account=s.fedorov@tofu.com --freshness=7d --limit=1000 \
  --format='value(jsonPayload.message)' \
  | grep -vE '^\s*(at |--- )' \
  | sed -E 's/<guid>//g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn
```

Volume in the window: **~997 invoices-api + 3 invoices-worker** errors (api hit the 1000 cap).

## Root-cause catalogue

All severities below are what the entry is logged at **today**. "Handled" = the request
still completes correctly / the exception is caught and translated to a client response;
the ERROR is pure noise.

| # | Error (normalised) | ~7d | Where it's logged | Today | Kind | Action |
|---|--------------------|----:|-------------------|-------|------|--------|
| 1 | `Account '{id}' has another owner` | **560** | `AuthApiAuthenticationService.MarkUserAsAccountOwnerIfRequired` (caught + swallowed, returns user) | Error | Handled business condition (one account spamming) | → `Information` |
| 2 | `BadHttpRequestException: Reading the request body timed out` | 116 | generic `Exception` map (thrown in `RequestLoggingMiddleware.GetRequestBody`) | Error | Client slow/aborted upload (Kestrel `MinRequestBodyDataRate`) | add map → 400 + `Information` |
| 3 | `MasterHasBeenDeletedException` | 64 | `ApiExceptionHandlingMiddleware` map (line ~180) | Error | Handled, returns HTTP 200 | map → `Information` |
| 4 | `BadHttpRequestException: Unexpected end of request content` | 60 | generic `Exception` map | Error | Client disconnected mid-upload | same map as #2 |
| 5 | `JobAlreadyHasEstimateException` / `JobAlreadyHasInvoiceException` | 29 | map (lines ~59-60) | Error | Business validation, returns 400 | map → `Information` |
| 6 | `ArgumentException: ... Attachments must have unique Order values` (+ other `ArgumentException`) | 20 | `ArgumentException` map (line ~61) | Error | Client/gRPC validation, returns 400 | map → `Warning` (+ see follow-up) |
| 7 | `TaskCanceledException` / `OperationCanceledException` | 22 + 9 | generic map (when `RequestAborted` not flagged) | Error | Cancellation / downstream timeout | add `OperationCanceledException` map → 499 + `Information` |
| 8 | `Stripe.StripeException: Invalid IE postal code` (+ Checkout total, etc.) | 18 | generic map | Error | User input rejected by Stripe | add `StripeException` map → 400 + `Warning` |
| 9 | `HttpRequestException: ... 429 (Too Many Requests)` | 11 | generic map | Error | External provider rate-limit | add map (StatusCode 429) → 503 + `Warning` |
| 10 | `MasterUserNotFoundException: Should call auth first` | 7 | map (line ~87, `logLevel: Error`) | Error | Client called endpoint before `/auth` | map → `Information` |
| 11 | `CheckoutConfigNotFoundException`, `ClientArchivedException` | few | maps with explicit `logLevel: Error` | Error | Handled 4xx | → `Warning` |
| 12 | Worker `Unknown error ... SyncExternalPaymentDataOperationHandler` → `VersionMismatchException` | 3+ | `SyncExternalPaymentDataOperationHandler.TryHandleEvent` catch-all | Error | Optimistic-concurrency conflict (retryable) | add `VersionMismatchException` catch → `Warning` |
| 13 | Worker `Error occurred sending analytics` → `EntityNotFoundException` | few | `Analytics.cs` catch-all | Error | Best-effort analytics | → `Warning` |

## Proposed changes (NOT yet applied — investigation only)

> Status: no code has been changed. The list below is the proposed fix for review/approval.
> All are log-level / mapping changes — no behaviour change to responses except adding correct
> status codes for previously-unmapped exceptions.

1. `Src/Invoices.Implementation.Services/Authentication/AuthApiAuthenticationService.cs`
   — "has another owner" `LogError` → `LogInformation` (#1).
2. `Src/Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs`
   - `MasterHasBeenDeletedException`, `JobAlreadyHasEstimateException`,
     `JobAlreadyHasInvoiceException`, `MasterUserNotFoundException` → `Information` (#3, #5, #10).
   - `ArgumentException`, `CheckoutConfigNotFoundException`, `ClientArchivedException`
     → `Warning` (#6, #11).
   - New maps: `Microsoft.AspNetCore.Http.BadHttpRequestException` (covers Kestrel subtype)
     → 400 `Information` (#2, #4); `OperationCanceledException` → 499 `Information` (#7);
     `HttpRequestException` with 429 → 503 `Warning` (#9); `StripeException`
     → 400 `Warning` (#8).
3. `Src/Invoices.Worker/OperationHandlers/SyncExternalPaymentDataOperationHandler.cs`
   — catch `VersionMismatchException` → `Warning` before the generic catch (#12).
4. `Src/Invoices.Analytics/Analytics.cs` — best-effort send failure `LogError` → `LogWarning` (#13).

Expected effect: removes ~95% of the current ERROR volume from the alert while keeping
every condition visible at `Warning`/`Information` for debugging.

## Follow-ups (not pure noise — investigate, don't just silence)

- **#6 Estimate attachments "must have unique Order values"** (20/7d): the iOS/web client is
  sending estimate attachments with duplicate `Order`. Downgraded to `Warning` here, but the
  client bug should be raised — track which app version / endpoint (`PUT /api/estimates`).
- **#8 Stripe `Invalid IE postal code` / Checkout total**: ideally validated client-side or
  translated to a domain exception inside `Tofu.Stripe` rather than caught generically in the BFF.
- **#9 429 from external provider**: confirm which client (Stripe / SendGrid) and whether Polly
  retry/backoff is configured; a 429 burst may indicate a missing rate-limit guard.
- **Email send failures** (`Failed send email by 'SendGrid'` / `Sendinblue`): low volume but real
  delivery failures — confirm they alert separately rather than being lost in the noise.

## Re-run after deploy to verify

```bash
gcloud logging read '<alert filter>' \
  --project=inv-project --account=s.fedorov@tofu.com --freshness=24h --limit=1000 \
  --format='value(jsonPayload.message)' | grep -vE '^\s*(at |--- )' \
  | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head
```

Whatever still tops the list after deploy is the next round.
