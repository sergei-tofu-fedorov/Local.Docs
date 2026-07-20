# FS-1241 Cross-Sell — Backend test results (staging)

One-line purpose: results of exercising the recurring-offer backend end-to-end on staging, plus the discrepancies found.

**Date:** 2026-07-18 · **Env:** `https://staging.tofu.com/api` · **Branch:** `FS-1304` (BFF) + current Tofu.AI · **Scope:** backend only (BFF `OffersController` + Tofu.AI cohort read + `planGrants`). UI/Amplitude/OneLink not covered.

## System under test

| Layer | Component |
|---|---|
| BFF `Invoices.Backend` | `OffersController` (api-version 3.0): `GET /api/offers/recurring`, `POST /api/offers/recurring/accept`. Master-only, `billing.manage`. |
| Tofu.AI.Backend | gRPC `GetRecurringOffer` → `BigQueryRecurringOfferRepository` reads `mart_recurring_offer_cohort`. |
| Warehouse (staging) | **`invoicesapp-project-test.ai_analysis_us.mart_recurring_offer_cohort`** — the dataset staging Tofu.AI reads (not prod `inv-project`). |
| Grant store | Mongo `invoicesDB.planGrants` (staging cluster). |

## Test data seeding

Direct `INSERT` of one eligible row into `mart_recurring_offer_cohort` (analog of `@TofuHelpBot insert into offer cohort`). Row: `fsm_industry='cleaning'`, `recur_max_repeats=4`, `recur_clients=2`, two groups — hero client "Kathryn Murphy" / "Deep cleaning" / amount 200 / weekly / repeatCount 4 (⇒ `monthlyAmount=800`), plus a biweekly second client. Reads are **live** (no cache): the eligibility flips `false→true` immediately after the insert.

> The cohort table is `CREATE OR REPLACE`d by the daily `refresh_recurring_offer` scheduled query — a manual seed is **ephemeral** and only valid until the next rebuild.

## Results

| # | Case | Result |
|---|---|---|
| B2 | `GET` for a cohort account → `isEligible:true` + full payload | ✅ `200`, hero + all fields correct |
| B3 | Monthly-amount math (weekly ×4) | ✅ 200 × 4 = 800 |
| B4 | Account not in cohort → not eligible | ✅ `isEligible:false, industry:null, recurring:null` |
| B5 | One-time guard: existing grant → `GET` short-circuits to not eligible (Tofu.AI not called) | ✅ |
| B6 | `POST accept` → one `planGrant` (`fsm_team`, +60 d) | ✅ verified in Mongo: `Source:recurring-offer`, `ProductType:5`, `ProductKeys:[tofu, tofu-fieldservice, tofu-fieldservice-worker]`, expiry +60 d |
| B7 | accept idempotency (2 calls → 1 grant, same expiry) | ✅ single Mongo doc |
| B8 | Auth gate: missing / invalid auth | ⚠️ returns **403** (contract states 401) |
| — | ProductKey does not gate `GET` (`tofu` / `invoices` / worker all `200`) | ✅ confirmed |

## iOS consumer (cross-checked)

Consuming branch: **`feature_im/FS-1242-clientActivation`** (`Invoices.Apps.iOS`), files under `Modules/InvoicesModule*/…/RecurringOfferService/` + DTO `DTOs/RecurringOffer/RecurringOffer.swift`. `getOffer()` → `GET offers/recurring`; `accept()` → `POST offers/recurring/accept` with an empty-dictionary body. Responses are decoded through the platform's `ResponseBase<T>` envelope (`ApiImplBase`).

## Findings / candidate bugs

### 🔴 Confirmed real bug

1. **`industry` enum mismatch breaks 2 of the 4 target industries.** The BFF returns the raw warehouse `fsm_industry` (`cleaning` / `lawn_care_maintenance` / `landscaping` / `pool_spa_service`), but the iOS enum `RecurringOfferIndustry` decodes only `cleaning` / `lawnCare` / `landscaping` / `pool`. So `lawn_care_maintenance` and `pool_spa_service` **fail to decode**; because `industry` carries a present, non-null, invalid value, `decodeIfPresent` throws, the whole `RecurringOffer` decode fails, `getOffer()` throws, and the carousel/banner never appear for those accounts. `cleaning`/`landscaping` happen to line up.
   - **Verified live on staging:** seeding `fsm_industry='lawn_care_maintenance'` → BFF returns `"industry":"lawn_care_maintenance"` verbatim.
   - **Root cause (backend):** no mapping in `RecurringOfferService`/`ToDto`/gRPC `Map` — the raw value flows straight from `mart_recurring_offer_cohort` to the DTO.
   - **Fix:** map on the backend to the contract enum (`lawn_care_maintenance → lawnCare`, `pool_spa_service → pool`), per `carousel-contract.md`. (Or, less ideal, teach the iOS enum the raw taxonomy.)

### 🟠 Worth fixing

2. **`POST /accept` with an empty body and no `Content-Length` → `411 Length Required`** from the GCP load balancer (request never reaches the app). iOS currently sends `body: [String:String]()`, which serialises to `{}` and sets a Content-Length — so the real client is fine; but any caller sending a truly empty POST fails. Confirm iOS keeps sending the `{}` body (it does on `FS-1242-clientActivation`). Flagged because it bit the raw-curl test of §14.
3. **`durationDays:60` is returned even when `isEligible:false`** (harmless; copy uses it only when eligible).
4. **No hard ">5-day interval" recurrence filter** (code): the 5-day floor only affects the `cadence` label; two invoices with the same amount + item-set group regardless of the gap. Diverges from the PDF criteria — decide whether that's intended.

### ⚪ Doc-only (not client-affecting) — correct `carousel-contract.md`

5. **Response envelope:** the contract says the DTO is returned without a `result` wrapper, but the endpoint returns `{"result": …}` — which is exactly what the iOS `ResponseBase<T>` decoder expects. The **doc** is wrong, not the code.
6. **Auth code:** missing/invalid auth returns **403** (anonymous → fails `billing.manage`), while the contract says 401. iOS maps any non-200 without a known body `errCode` to `System_HTTP_<code>` and neither 401 nor 403 triggers re-auth/logout for this endpoint, so there is no client impact — fix the doc.

### ℹ️ Notes

7. Cohort seed is **ephemeral** (daily `CREATE OR REPLACE` by `refresh_recurring_offer`).
8. One-time guard checks **any** overlapping grant for the master (any `Source`), not just `recurring-offer`.

## Not covered (follow-up)

- **Cohort formation rules** (industry-out-of-3A / <3 repeats / <2 clients / different amounts, no active subscription) via the actual `build_recurring_offer_*` routines — only the read path was tested via a direct seed.
- accept under backend timeout/error (§14 idempotency-on-failure).
- All UI, Amplitude events, OneLink/CPP/deep-link, Tofu onboarding — iOS side.

## Post-test environment state

- Test grant deleted (`planGrants`); the test master has 0 grants. Two unrelated pre-existing grants untouched.
- Cohort row re-seeded → the test account is currently **eligible with the offer unused**, ready for further/iOS testing.
