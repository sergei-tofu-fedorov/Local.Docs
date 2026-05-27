# INVC-3608 — Silence worker mutations on shared `tofu` web client

**Status:** in-progress
**Started:** 2026-05-08
**ClickUp:** https://app.clickup.com/t/INVC-3608
**Affected repos:** `Invoices.Backend`

## Branches

- `Invoices.Backend` → `feature/INVC-3608` (base `master`)

## Goal

Stop worker-role users from mutating owner-level account state when they hit endpoints exposed by the `tofu` web client — which is the **same client binary** for admins and workers. Today these endpoints have no role gate (e.g. `PUT /api/account/set_identifiers` carries no `[AuthorizeAction]`) and silently overwrite the owner's account record. Per `set_identifiers_findings.md`, this has happened to **10 prod accounts / 19 calls** in the last 20 days and **14 test accounts / 41 calls** in 30 days, including 5 distinct workers stomping on the same account inside a 1-minute window.

The fix is to make these endpoints **silent no-ops for non-admin callers**: return a valid-shaped response so the shared client deserializes successfully, but skip every state-mutating side effect (DB write, Subz re-keying, push registration). Detection happens in code via `IAuthorizationContext` (already exposed per request by `Tofu.Permissions`, role resolved by `SubjectIdentityProvider`), so we don't have to wait for `WEB-794` to flip `[AuthorizeAction]` to Enforce mode.

## Scope

- **In scope:**
  - `PUT /api/account/set_identifiers` (`Src/Invoices.Api/Controllers/V1/AccountController.cs:161`) — primary fix. Worker callers get a 200 with a synthesised `AccountIdentifiersResponseDto`, no `_accountsRepository.InsertOrUpdateIdentifiersAsync`, no `_subscriptionService.PutAccountAsync`, no `_pushService.CreateOrUpdateAccountAsync`.
  - Audit other un-attributed mutating account endpoints in `AccountController` (`PUT /api/account` at V1 line 108, `PUT /api/account/{accountId}/update` at V3 line 311) — both already carry `TODO(WEB-794)` notes flagging the same gap. Decide per-endpoint whether to apply the same silent-no-op pattern or defer to WEB-794.
  - Quick grep for other un-attributed mutating endpoints reachable by a `tofu`-web worker (outside `AccountController`).
  - Structured `Information`-level log on the no-op branch so the GCP query in `set_identifiers_findings.md` can be re-run post-rollout to confirm mitigation hits.
- **Out of scope:**
  - Adding `[AuthorizeAction]` to `set_identifiers` — that is `WEB-794`'s job once Enforce mode lands.
  - Backfill of the 10 prod accounts already in worker-overwritten state — separate ticket; this fix only stops the bleed forward.
  - Endpoints that already carry `[AuthorizeAction]` (Invoices, Estimates, Clients, Items, Jobs, Emails). The `WEB-794` Enforce-mode flip is the canonical fix for those.

## Affected repos

Single-repo feature.

- `Invoices.Backend` (BFF) — owns `AccountController` and the `IAuthorizationContext` registration that already resolves `Role.Admin` / `Role.Worker` via `SubjectIdentityProvider` (`Src/Invoices.Api/Authorization/Permissions/SubjectIdentityProvider.cs`). The `MasterUser.IsWorkerIn(AccountId)` helper (`Src/Invoices.Core/Models/MasterUser.cs:173`) is the underlying check the resolver leans on.

**Cross-repo notes:** none — no service boundary crossed, no proto / DTO changes, no mapper updates.

## Plan

1. [x] Inject `IAuthorizationContext` into `V1/AccountController` and gate the mutating body of `PutIdentifiers` behind `!authContext.HasRole(Role.Admin)`. Negation covers the worker case **and** the empty-roles case (caller with neither relationship to the account — `SubjectIdentityProvider` returns `[]`). Signature-auth still flows through because `SubjectIdentityProvider:51-52` synthesises `Role.Admin` for that scheme.
2. [x] On the no-op branch, return the owner's currently-stored identifiers via `_accountsRepository.FindIdentifiersAsync(AccountId)`, mapped to `AccountIdentifiersResponseDto`. When `FindIdentifiersAsync` returns null, fall back to a synthesised DTO echoing the request's `UserId` / `PublicUserId` so the shared client never sees an unexpected error from a worker session.
3. [x] Keep `_banService.CheckByUserId(identifiers.UserId)` ahead of the gate so banned UserIds still get rejected with `UserOrAccountIsBannedException` regardless of role.
4. [x] Emit `_logger.LogInformation("Worker set_identifiers no-op for AccountId '{AccountId}' ProductKey '{ProductKey}'", ...)` on the no-op branch.
5. [ ] Audit `Put` (V1, line 108) and `Put`/`update` (V3, line 311) — both flagged with `TODO(WEB-794)`. **Deferred**: WEB-794 owns the canonical fix; revisit if it slips.
6. [ ] Quick grep for other un-attributed mutating endpoints (`[Http(Put|Post|Delete|Patch)]` without `[AuthorizeAction]`) that a `tofu`-web worker could reach. **Deferred**: same rationale as #5.
7. [x] Integration test added: `AccountControllerV1Tests.PutIdentifiers_V1_AsWorker_ShouldNoOpAndReturnOwnerIdentifiers` — owner seeds identifiers, worker call returns owner's `UserId`, DB still holds owner's value (no mutation). Existing `PutIdentifiers_V1_ShouldSetAccountIdentifiers` covers the admin-writes-as-today path. Unit tests on the gate predicate skipped — the predicate is one `HasRole(Admin)` call exercised end-to-end by the integration test.

## API / DTO changes

None. Response shape stays `AccountIdentifiersResponseDto`. Behaviour change is internal.

## Breaking changes

None for legitimate callers — admins (Bearer + `OwnedAccounts` membership) and signature-auth callers take the same path as today. Worker callers on the shared `tofu` web client stop seeing their identifiers persist, which is the *point* of the fix; the shared client's UX should not regress because the response shape is preserved.

**Risk to verify before merge:** confirm no worker-only flow in the `tofu` web client depends on `set_identifiers` actually having mutated server state (e.g., a follow-up GET that expects to read what the worker just PUT). The endpoint's stated purpose is per-device push/IDFA registration — those side-effects shouldn't be wired to a worker UI flow, but the assumption needs a quick web-client check.

## Data / migration

None — no database changes. Pre-existing worker-overwritten accounts stay in their current state until the backfill ticket lands separately.

## Open questions

- [ ] Emit a metric (in addition to the log) so we can dashboard mitigation hits?
- [ ] Any worker-only flow in the `tofu` web client that reads server state set by `set_identifiers`? (Quick check before merge — see "Risk to verify".)

## Test plan

- Unit tests:
- Integration tests:
- Manual verification:
