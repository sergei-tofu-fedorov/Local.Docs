# Amplitude user identity & the owner-vs-worker attribution gotcha

Every Amplitude event is keyed by a `user_id`. It is set in **two independent places** that must agree,
or events land under the wrong user:

- **Clients** call Amplitude `setUserId` directly on their own events.
- **The BFF** (`Invoices.Backend`) *reconstructs* a `user_id` for events it emits server-side (a
  background/callback event has no logged-in user — only `accountId` + `productKey`).

## What each client sets as `user_id`

| Platform | Amplitude `user_id` | Truncated? | Evidence |
|---|---|---|---|
| **Web** | `userPlatformId` (from `/authenticate/auth`) | no — full | `Tofu.Web.Frontend` `src/features/auth/model/platform-auth.ts:224-228`; setter `src/external/analytics/amplitude.ts:34-36` |
| **Android** | `userId.public` = `secret[0..24]` | yes — first **25** chars | `InitializationUseCase.kt:130-146`; `IdImpl.kt:10-11` (`secret.slice(0..24)`) |
| **iOS** | `platformID.publicId` / master id | yes — ~25, derived in `Tofu.Common.iOS` | call sites in `Invoices.Apps.iOS` (`ClarityInitializer.swift:39/45`); actual slicing + Amplitude `setUserId` in external SPM pkg `Tofu.Common.iOS` |
| **WorkerApp** | worker's own `masterUserId` | **no — not truncated** | `AnalyticsManager.kt:222` → `AnalyticsDepsImpl.kt:101-103`; applied `AnalyticsReporterImpl.kt:52-53` |

`account_id` is always sent as an event **property** (Android `accountId.public`; WorkerApp
`businesses[0].accountId`; web via Intercom/identifiers only). It is *not* the identity — never
resolve identity from `account_id`.

## How the BFF reconstructs `user_id`

Path (all in `Src/Invoices.Analytics/Analytics.cs`):

1. Caller: `_analytics.WithContext(new Context(accountId, productKey))` then `_analytics.Log(event)`.
   **`Context` is only `(AccountId, ProductKey)`** — the acting/authenticated user is dropped here
   (`Src/Invoices.Core/Analytics/Context.cs:3`). ~16 call sites (Payments, Email callbacks,
   Notifications, Jobs push, Invitations, Worker operation handlers).
2. `FlushAll` (`Analytics.cs:78`) groups buffered events by `AccountId`, then
   `masterUserRepository.FindOwnerForAccountId(accountId)` (`Analytics.cs:98`).
   The Mongo query is `OwnedAccounts.Any(oa => oa.AccountId == accountId)`
   (`Src/Invoices.Implementation.MongoDb/Repositories/MasterUserRepository.cs:133`) → returns the
   account **owner** master user. **A worker lives in `MemberAccounts` (role `Worker`), not
   `OwnedAccounts`, so this query never returns the worker.**
3. `ResolveUserId` (`Analytics.cs:133`) → `ResolveUserIdFromMaster(owner, productKey)` (`:147`):
   - `owner.FindPlatformUserLinkByProduct(productKey)` (`MasterUser.cs:171`) → owner's earliest link
     for that product;
   - if a link: `Account.GetShortUserId(link.PlatformId, link.Platform)` (`Account.cs:74`) —
     `Platform.Web` → full `PlatformId`; iOS/Android → `PlatformId[..25]` (first 25 chars, "because
     that's what AF does too", `Account.cs:72`);
   - no link → fall back to `owner.Id` (the master user id).
   - Accounts with no resolvable master (legacy/anonymous) fall back to
     `accountsRepository.FindIdentifiersAsync` (`Analytics.cs:101`).

So the reconstructed id matches web/Android/iOS **owner** events, but for a worker it is always the
**owner's** id.

## The gotcha

A Field Service **worker shares the business owner's `accountId`** (worker = member of that account).
Any resolution from `accountId` alone yields the **owner**.

- **Clients are correct.** WorkerApp sets `user_id` to the worker's own `masterUserId`.
- **BFF-emitted worker events are wrong.** Exactly two server events hard-code
  `ProductConst.FieldServiceWorker` as the Context ProductKey and are therefore attribution-sensitive:
  - `VisitAssignedPushSent` — `Src/Jobs/Jobs.Application/Services/Push/JobNotificationService.cs:111`
  - `VisitChangedPushSent` — `JobNotificationService.cs:130` and
    `Src/Notifications/Notifications.Application/WorkerVisits/WorkerVisitChangedNotificationProcessor.cs:45`

  Both resolve via `FindOwnerForAccountId` → the owner, so the worker's push events are attributed to
  the business owner.

## Fix direction (server-side)

The domain model already has what's needed — the fix does not touch clients:

- `Context` must carry the **acting** master user id. At API call sites it is available as
  `AuthenticationInfo.MasterUserId` (`BaseController`); at worker/notification call sites the visit's
  assigned worker id is known.
- `ResolveUserId` should prefer the acting worker's master + platform link over
  `FindOwnerForAccountId`. The model distinguishes membership already:
  `MasterUser.IsWorkerIn(accountId)` (`MasterUser.cs:184`) and `MemberAccount.WorkerRole`
  (`MasterUser.cs:218`).
- **Truncation mismatch to decide:** WorkerApp sends the **full** `masterUserId` (no `[..25]`), while
  `GetShortUserId` truncates non-Web ids to 25. When you make the server resolve the worker, choose
  explicitly whether to emit the full `masterUserId` or its 25-char prefix so the server stream joins
  the client stream.

## Reconciliation subtleties (warehouse ↔ backend)

- **Prefix, not equality, for mobile.** Android/iOS Amplitude `user_id` = first 25 chars of a longer
  secret; the backend holds the full secret. Join with a **prefix match**.
- **iOS identity is out-of-repo.** `publicId` derivation and the worker-vs-owner `setUserId` decision
  live in `Tofu.Common.iOS` — verify there before assuming iOS worker behavior.
- **`account_id` on events ≠ Mongo/invoices account id** necessarily — it is the public/truncated form.
