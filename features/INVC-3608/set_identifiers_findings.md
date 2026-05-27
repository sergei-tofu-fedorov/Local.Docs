# INVC-3608 — `set_identifiers` worker-overwrite findings (logs)

**Captured:** 2026-05-09
**Scope of this doc:** every `PUT /api/account/set_identifiers` call observed in GCP logs where the caller is a Worker-role user (not the account owner). Each such call silently overwrites the **owner's** account-level identifiers (`UserId`, `PushToken`, `IDFA`, `AppsflyerId`, `FirebaseId`) and re-keys the `SubzAccount` in the subscription service to the worker's identity. The endpoint has **no `[AuthorizeAction]`** at the controller or endpoint level (`Invoices.Backend/Src/Invoices.Api/Controllers/V1/AccountController.cs:38, 161`).

This is the evidence base for INVC-3608's fix. The `invoices`, `invoices-android`, and `tofu-fieldservice` apps don't show this pattern in the logs because their middleware resolves `AccountId` to an account the caller owns. The `tofu` web app — the **shared** binary used by both admins and workers — has no such resolution, so every worker `set_identifiers` call from `tofu` web targets an account they do not own.

## Methodology

1. **Identify Worker-role users**: filter `RequestLoggingMiddleware` logs for `GET /api/me/permissions` returning a Worker-shaped response body (only `invoice.view` + `invoice.list` abilities; signature substring `"action":"list"}]}}`). Admin shape contains 7 abilities including `user.roles.assign`.
2. **List `set_identifiers` calls** from those `MasterUserId`s, capturing `AccountId`, `ProductKey`, `UserEmail`, `timestamp`.
3. **Flag cross-contamination**: an `AccountId` modified by ≥ 2 distinct worker `MasterUserId`s — every later call layers another worker's identifiers over the previous one.

**Caveats:**
- Only the **Worker** role is detected here. Manager-tier or other non-owner roles could also be hitting `set_identifiers` on accounts they don't own; they're not in this list.
- Test logs cover **30 days**; prod logs cover **20 days** as requested.
- `RequestLoggingMiddleware` log retention may exclude older entries — counts are lower bounds, not exhaustive.

---

## Prod (`inv-project`) — 19 calls, 10 accounts, 8 worker users

All calls returned `200`, all from `ProductKey=tofu` (web), `XA-App-Type` empty.

**Cross-contamination:** none in this 20d window — each affected account was modified by exactly one worker. The damage per call is still real (owner's identifiers replaced); it just hasn't compounded across multiple workers yet because real customers don't share accounts the way test users do.

| AccountId (owner) | Worker email | Worker MasterUserId | Calls | First call | Last call |
|---|---|---|---:|---|---|
| `433b7e52-9df5-4d1d-9b25-203eb0464717` | `amiles@dndwi.com` | `ecdbfd84-cf4d-464f-92a8-a18c843ffa04` | 6 | 2026-04-29T13:35:29Z | 2026-04-30T11:27:04Z |
| `4d27f13e-287c-493a-82aa-dd227c7d15a9` | `k.balharchuk+p3w1@tofu.com` | `ab5abd9e-3536-4369-b585-02e783493beb` | 1 | 2026-05-06T14:57:17Z | 2026-05-06T14:57:17Z |
| `57d720dc-ab96-43b2-b72f-5f492cde6b24` | `amiles@dndwi.com` | `ecdbfd84-cf4d-464f-92a8-a18c843ffa04` | 1 | 2026-04-29T13:10:28Z | 2026-04-29T13:10:28Z |
| `5b2c1bf1-9c02-456b-8ef9-619c792bfc71` | `fuseproelectric@gmail.com` | `c8c2818b-bdda-4ad5-bf96-a864bde64f86` | 1 | 2026-04-23T03:16:34Z | 2026-04-23T03:16:34Z |
| `75c1gzltbb-9b3838860bdf4819a74fb55ddd33cb8a-c120983fb944cf3571e8fa6118eb257c` | `xuao583252976@gmail.com` | `b6db913a-7a36-4060-9ca4-c946a9cd7dfe` | 2 | 2026-04-20T10:36:43Z | 2026-04-20T10:37:41Z |
| `79870eec-a101-4680-bd1a-f45691921473` | `operations@amarashiaofficial.com` | `518a8cc1-b889-497a-a062-f4f55ca69bda` | 3 | 2026-04-29T07:05:14Z | 2026-04-29T07:08:42Z |
| `83a371f6-5e31-4014-b488-8347669f6d3e` | `keshawn.ford24@gmail.com` | `912ac4cd-6949-4177-8200-4288a325edf7` | 2 | 2026-05-03T23:09:01Z | 2026-05-03T23:09:01Z |
| `a95e53fc-56eb-45c2-80eb-5986a758a7aa` | `l.grigoryan@tofu.com` | `8b683dae-efd0-4c92-832a-046e8c650c96` | 1 | 2026-04-22T12:30:18Z | 2026-04-22T12:30:18Z |
| `baacb0d5-0af7-4ebe-8053-50e477f4ea83` | `operations@amarashiaofficial.com` | `518a8cc1-b889-497a-a062-f4f55ca69bda` | 1 | 2026-04-29T07:13:22Z | 2026-04-29T07:13:22Z |
| `d550d707-3873-4203-84a7-d3804b692ac7` | `tracyegleston@gmail.com` | `f0527fb4-a3c4-4283-b1eb-8fd7d51ffb42` | 1 | 2026-04-19T21:30:37Z | 2026-04-19T21:30:37Z |

Most of the worker emails above (`amiles@dndwi.com`, `fuseproelectric@gmail.com`, `xuao583252976@gmail.com`, `operations@amarashiaofficial.com`, `keshawn.ford24@gmail.com`, `tracyegleston@gmail.com`) are **real customers**, not internal QA accounts. Their owners' account-level identifiers and Subz registrations are currently in a worker-overwritten state.

---

## Test (`invoicesapp-project-test`) — 41 calls, 14 accounts, 19 worker users

All calls returned `200`. Most from `tofu` web; one account also hit by the iOS Invoices and FS admin apps from a single worker (see `ba7pspbkh6-…` below — the same worker logged into 3 different apps in the same session).

### Cross-contaminated accounts (modified by ≥ 2 distinct workers)

| AccountId | Distinct workers | Total calls | Distinct apps |
|---|---:|---:|---|
| `o73881s4ae-839903e40f7f4317a106688093703a5d-bc57bd63c14b07bfc4c3978c44b239e1` | **5** | 5 | tofu |
| `73726139-16e8-4f0b-b242-e45ba0608d71` | **4** | 8 | tofu |
| `elz432vjcr-c95ce84dd4264420836704bdbe772d5d-087f792865ec30f5517e8cd5881bd3ea` | 2 | 2 | tofu |
| `ba7pspbkh6-c56ba5e69a26438c889ebf78080ebd09-deabf8e1ac95d110e7bf5cbeb8033d9d` | 2 | 13 | tofu, tofu-fieldservice, invoices |

The account `o73881s4ae-…` is the worst case — within a single 1-minute window (2026-05-07T14:54-14:56) five different worker users (`+1`, `+2`, `+232342`, `+vv55552`, `+4442`) sequentially overwrote its identifiers. Each call replaced the previous worker's UserId/PushToken/IDFA, then re-keyed Subz again. Final owner-record state reflects whichever worker called last.

### Full call list (sorted by AccountId then timestamp)

| Timestamp | AccountId | Worker email | Worker MasterUserId | ProductKey |
|---|---|---|---|---|
| 2026-04-21T12:04:17Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w3@tofu.com` | `260e5fa9-71ba-42da-95b8-c1e2886dcd3e` | tofu |
| 2026-04-21T12:04:27Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w3@tofu.com` | `260e5fa9-71ba-42da-95b8-c1e2886dcd3e` | tofu |
| 2026-04-21T12:11:29Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w3@tofu.com` | `260e5fa9-71ba-42da-95b8-c1e2886dcd3e` | tofu |
| 2026-04-21T12:13:56Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w3@tofu.com` | `260e5fa9-71ba-42da-95b8-c1e2886dcd3e` | tofu |
| 2026-04-22T06:04:32Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w3@tofu.com` | `260e5fa9-71ba-42da-95b8-c1e2886dcd3e` | tofu |
| 2026-04-28T15:46:51Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w4@tofu.com` | `5b5caed5-35d2-4279-ae39-c9f421c1065b` | tofu |
| 2026-04-29T12:46:21Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160wd1@tofu.com` | `6bab870d-0aee-426b-acec-28ed479c7901` | tofu |
| 2026-04-30T09:29:11Z | `73726139-16e8-4f0b-b242-e45ba0608d71` | `k.balharchuk+160w5@tofu.com` | `eb283e4b-2748-4a0f-9eaf-48c1db8edcbb` | tofu |
| 2026-05-05T08:49:18Z | `4cd27fb7-ba80-4f08-8e73-0015c5fa75f4` | `k.balharchuk+170w1@tofu.com` | `680e048a-017d-4cad-a225-868f1f6e1b00` | tofu |
| 2026-05-05T12:02:15Z | `h3i89s9eol-729d43475a5347dead4fa8259e1ca3b0-98800dfb47dbd12dd575ccffa2b06fb6` | `place4name+jessworker@gmail.com` | `8a314f3d-581c-4ea5-b8f1-fdf5d6551345` | tofu |
| 2026-05-05T12:03:43Z | `8hs0g6fm9k-02b1d00fa1ca433d96216347037c831d-0932d6291797d59ff8eed29adc6c9cfc` | `place4name+jessworker@gmail.com` | `8a314f3d-581c-4ea5-b8f1-fdf5d6551345` | tofu |
| 2026-05-06T10:01:55Z | `ca5d54bb-6369-4ae6-9d78-7e4942418c91` | `a.vershinina+workernewpermission@tofu.com` | `c2024d2c-d53f-4e8b-abd8-0e5980a3d65c` | tofu |
| 2026-05-06T10:09:09Z | `ca5d54bb-6369-4ae6-9d78-7e4942418c91` | `a.vershinina+workernewpermission@tofu.com` | `c2024d2c-d53f-4e8b-abd8-0e5980a3d65c` | tofu |
| 2026-05-06T10:09:09Z | `ca5d54bb-6369-4ae6-9d78-7e4942418c91` | `a.vershinina+workernewpermission@tofu.com` | `c2024d2c-d53f-4e8b-abd8-0e5980a3d65c` | tofu |
| 2026-05-06T11:08:37Z | `517f4044-1aa4-48bd-ac0c-d35c8320b67e` | `a.vershinina+pops1@tofu.com` | `fbfd0aa3-7e10-4f2c-882a-70ee7d50cdec` | tofu |
| 2026-05-06T14:31:16Z | `517f4044-1aa4-48bd-ac0c-d35c8320b67e` | `a.vershinina+pops1@tofu.com` | `fbfd0aa3-7e10-4f2c-882a-70ee7d50cdec` | tofu |
| 2026-05-06T14:31:17Z | `7jbksd5ll6-8fe8dabc478249ae903e2604b2b8644a-9ee3e68759b9c65fceac75c549baba4a` | `a.vershinina+pops1@tofu.com` | `fbfd0aa3-7e10-4f2c-882a-70ee7d50cdec` | tofu |
| 2026-05-06T14:42:25Z | `ba7pspbkh6-…` (cross-contam) | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu-fieldservice |
| 2026-05-06T14:42:32Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu-fieldservice |
| 2026-05-06T14:47:23Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu-fieldservice |
| 2026-05-06T14:47:28Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu-fieldservice |
| 2026-05-06T15:04:03Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | invoices |
| 2026-05-06T15:04:09Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | invoices |
| 2026-05-06T15:05:09Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | invoices |
| 2026-05-06T15:05:14Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | invoices |
| 2026-05-06T15:08:23Z | `f3a0766a-d67e-4e44-9cbe-20373df7cac3` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu |
| 2026-05-06T15:09:24Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu-fieldservice |
| 2026-05-06T15:09:27Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu-fieldservice |
| 2026-05-06T15:17:39Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | tofu |
| 2026-05-06T15:28:12Z | `ba7pspbkh6-…` | `a.vershinina+link@tofu.com` | `9c326bf7-6907-4e34-80d9-1659e6bee96f` | tofu |
| 2026-04-29T13:25:23Z | `elz432vjcr-…` (cross-contam) | `k.balharchuk+wmp1@tofu.com` | `7ce2075c-77fa-4b93-8333-c427e2b38237` | tofu |
| 2026-04-29T13:25:49Z | `elz432vjcr-…` | `k.balharchuk+wmp2@tofu.com` | `50f42ebc-fb3f-4e6e-bbd9-6f70aa700e77` | tofu |
| 2026-05-07T14:54:49Z | `o73881s4ae-…` (cross-contam) | `k.balharchuk+1@tofu.com` | `e1d0b191-858e-48f9-adaf-48cb0e28986d` | tofu |
| 2026-05-07T14:54:49Z | `aa6ebe86-35bb-46f2-84f0-ec3da179f6f1` | `k.balharchuk+1@tofu.com` | `e1d0b191-858e-48f9-adaf-48cb0e28986d` | tofu |
| 2026-05-07T14:55:16Z | `o73881s4ae-…` | `k.balharchuk+2@tofu.com` | `aa9ecdad-2124-4468-a15c-4ae8b319d117` | tofu |
| 2026-05-07T14:55:16Z | `a0548c0b-7a6b-4378-9e69-1b8aaa659905` | `k.balharchuk+2@tofu.com` | `aa9ecdad-2124-4468-a15c-4ae8b319d117` | tofu |
| 2026-05-07T14:55:39Z | `o73881s4ae-…` | `k.balharchuk+232342@tofu.com` | `cd8d9ebd-70ce-47dc-bffc-1e404011926c` | tofu |
| 2026-05-07T14:56:10Z | `o73881s4ae-…` | `k.balharchuk+vv55552@tofu.com` | `a5a8b4e8-b9bf-4494-a9d5-42e42eb46672` | tofu |
| 2026-05-07T14:56:31Z | `o73881s4ae-…` | `k.balharchuk+4442@tofu.com` | `518a2fce-c0bc-4994-baf1-4faea0be1701` | tofu |
| 2026-05-08T08:54:02Z | `583ef348-ec28-405c-9cf4-82704fc65cb3` | `a.vershinina+wklink2@tofu.com` | `8a72726c-8ed1-42f1-8de2-117176d81152` | tofu |
| 2026-05-08T09:47:11Z | `ba7pspbkh6-…` | `a.vershinina+wk2@tofu.com` | `1d16a498-15a5-4528-8f36-97b6996a4ea1` | invoices |

---

## Reproduction

The exact `gcloud` queries that produced the lists above:

```bash
# 1. Identify worker MasterUserIds via /api/me/permissions response shape
gcloud logging read \
  'logName="projects/<project>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware"
   jsonPayload.properties.RequestPath:"me/permissions"
   jsonPayload.properties.RequestMethod="GET"
   jsonPayload.properties.StatusCode=200
   jsonPayload.properties.ResponseBodyText:"\"action\":\"list\"}]}}"' \
  --project=<project> --freshness=<window> --limit=2000 \
  --format='csv[no-heading,separator="|"](jsonPayload.properties.UserEmail,jsonPayload.properties.MasterUserId)' \
  | sort -u

# 2. List set_identifiers calls from those MasterUserIds
USERS='<id1> <id2> ...'
OR_CLAUSE=$(printf 'jsonPayload.properties.MasterUserId="%s" OR ' $USERS | sed 's/ OR $//')
gcloud logging read \
  "logName=\"projects/<project>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware\"
   jsonPayload.properties.RequestPath:\"set_identifiers\"
   ($OR_CLAUSE)" \
  --project=<project> --freshness=<window> --limit=500 \
  --format='csv[no-heading,separator="|"](timestamp,jsonPayload.properties.RequestMethod,jsonPayload.properties.StatusCode,jsonPayload.properties.ProductKey,jsonPayload.properties.UserEmail,jsonPayload.properties.MasterUserId,jsonPayload.properties.AccountId)'
```

Substitute `<project>` with `inv-project` (prod) or `invoicesapp-project-test` (test); `<window>` with `20d` or `30d` accordingly.

---

## Implications and recommendations

INVC-3608 covers the silent-no-op gate on `set_identifiers` (and an audit of the other un-attributed mutating endpoints in `AccountController`). Items below are adjacent work that the data here justifies but that lives outside this ticket.

1. **Long-term, also add an `[AuthorizeAction]` to `PUT /api/account/set_identifiers`**, or restructure it so it writes a per-(AccountId, MasterUserId) row instead of overwriting the account-level `Identifiers` row that all callers share. The current shape has no notion of "which user's identifiers" — every caller stomps on the previous one. INVC-3608 stops the bleed; this is the canonical fix.
2. **Decide whether `_subscriptionService.PutAccountAsync` should fire for non-owner callers** (`AccountController.cs:190-200`). Re-keying Subz from a worker's `UserId` is the part that breaks subscription resolution for the owner. The INVC-3608 silent-no-op covers this for workers; signature-auth and admin paths still re-key as today.
3. **Affected accounts may need backfill.** The 10 prod accounts above currently have a worker's identifiers in their account record and a worker-keyed `SubzAccount`. If push routing, attribution, or subscription state matters for these owners, a one-off cleanup pass to re-establish the owner's identifiers is warranted.
4. **Broader: enforce the documented role gating.** Per the auth map (`Tofu.Docs/features/permissions_and_plans/endpoint_authorization_map.md`) and the `TODO(WEB-794)` in `AccountController.cs:101-104`, the `[AuthorizeAction]` system is in audit/permissive mode — workers in prod are also creating/editing/deleting Invoices, Estimates, Clients, Items, Jobs, Emails, etc. on accounts they're invited to. `set_identifiers` is the only one with **no** attribute at all; the rest will start rejecting once Enforce mode flips.
5. **Latent Mongo write bug — `FirebaseId` column gets `AppsflyerId` value.** `Invoices.Implementation.MongoDb/Repositories/AccountsRepository.cs:68`:
   ```csharp
   .Set(o => o.AppsflyerId, accountIdentifiers.AppsflyerId)
   .Set(o => o.FirebaseId, accountIdentifiers.AppsflyerId)  // <-- should be .FirebaseId
   .Set(o => o.Idfa, accountIdentifiers.Idfa)
   ```
   Every `InsertOrUpdateIdentifiersAsync` write has been overwriting the `FirebaseId` column with the `AppsflyerId` value (likely since the line was first authored — it's a copy-paste typo). Dormant because **nothing reads `AccountIdentifiers.FirebaseId` from Mongo** today: the live `FirebaseId` flows directly from the request DTO to `SubzAccount.FirebaseId` in `AccountController.cs:220` without round-tripping through the persisted row. The Mongo column is therefore corrupt-but-unused. Two follow-ups:
   - **Fix the typo** so future readers (analytics, push routing, any new consumer) see the right value.
   - **Decide whether to backfill the column.** If no consumer is ever planned, leaving the corrupt data is harmless; if a future feature wants to read FirebaseId from Mongo, the historical column needs to be cleared first to avoid AppsflyerId values leaking through.
6. **Subz row duplication from contamination window.** Each worker `set_identifiers` call against a `tofu` AccountId pre-fix created an extra `Subz[(worker.userId, ProductKey="tofu")]` row in the subscription service — one per (worker, account) pair that hit the endpoint. Subz is keyed by `(userId, productKey)` and `PutAccountAsync` is upsert, so these rows persist with the worker's stale `firebaseId` / `idfa` / `appsflyerId` values from whatever device they were on at the time. They don't correspond to any real subscription (the worker never paid; the owner pays under their own userId). The backfill discussed in (3) should also enumerate and purge these orphan worker-on-tofu rows, otherwise Subz keeps stale per-worker push routing forever.
