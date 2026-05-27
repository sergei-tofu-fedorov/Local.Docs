# Endpoint Authorization Map — Invoices.Backend

Complete list of all ~180 endpoints across 50 controllers with access rules.

Each endpoint uses a single `[AuthorizeAction("key")]` attribute. The key maps to the [Access Registry](2_authorization_model.md#access-registry--full-permission-map) which defines both role and plan conditions.

**Legend:**
- `[AuthorizeAction("key")]` — the Access Registry key; look up in the registry for role + plan conditions
- `—` — no access check, any authenticated user can call
- Notes column — imperative `IAuthorizationContext` checks needed inside controller/service logic

---

# P0 — FSM Core (first priority)

## Jobs (JobsController)

| Endpoint | Action Key | Notes |
|----------|-----------|-------|
| `PUT /api/jobs` | `job.create` | |
| `DELETE /api/jobs/{id}` | `job.delete` | |
| `GET /api/jobs/paged` | `job.view` | Worker: filter by `assignedWorkerId` |
| `GET /api/jobs/{id}` | `job.view` | Worker: verify assigned to this job |
| `GET /api/jobs/count` | `job.view` | |
| `GET /api/jobs/stats` | `job.view` | |
| `GET /api/jobs/sync` | `job.view` | |
| `GET /api/jobs/{id}/timeline` | `job.view` | |
| `PATCH /api/jobs/{jobId}/visits/{visitId}/status` | `visit.update` | Worker: verify assigned to this visit |
| `POST /api/jobs/{jobId}/copy-estimate-items` | `job.create` | |
| `POST /api/jobs/from-estimate` | `job.create` | |

## Estimates (EstimatesController)

| Endpoint | Action Key |
|----------|-----------|
| `PUT /api/estimates` | `estimate.create` |
| `DELETE /api/estimates/{idWithVersion}` | `estimate.create` |
| `GET /api/estimates/{id}` | `estimate.view` |
| `GET /api/estimates` | `estimate.view` |
| `GET /api/estimates/paged` | `estimate.view` |
| `GET /api/estimates/{id}/pdf` | `estimate.view` |
| `GET /api/estimates/{id}/html-preview` | `estimate.view` |
| `POST /api/estimates/build-html-preview` | `estimate.create` |
| `POST /api/estimates/{id}/web-link` | `estimate.create` |
| `GET /api/estimates/balances` | `estimate.view` |
| `GET /api/estimates/balances-by-status` | `estimate.view` |
| `GET /api/estimates/timeline` | `estimate.view` |
| `GET /api/estimates/timeline/{entityId}` | `estimate.view` |

# P1 — Invoicing Core (second priority)

## Invoices (InvoicesController V1 + V3)

| Endpoint | Action Key | Notes |
|----------|-----------|-------|
| `PUT /api/invoices` | `invoice.create` | |
| `DELETE /api/invoices/{idWithVersion}` | `invoice.delete` | |
| `GET /api/invoices` | `invoice.view` | Workers get read-only view |
| `GET /api/invoices/{id}` | `invoice.view` | |
| `GET /api/invoices/paged` | `invoice.view` | |
| `GET /api/invoices/{id}/pdf` | `invoice.view` | |
| `GET /api/invoices/{id}/html-preview` | `invoice.view` | |
| `POST /api/invoices/build-html-preview` | `invoice.create` | |
| `POST /api/invoices/{id}/web-link` | `invoice.create` | |
| `GET /api/invoices/balances` | `invoice.view` | |
| `GET /api/invoices/pnl-report` | `invoice.view` | |
| `POST /api/invoices/calculate-table-details` | `invoice.create` | |
| `GET /api/invoices/sync` | `invoice.view` | |
| `GET /api/invoices/timeline` | `invoice.view` | |
| `GET /api/invoices/pdf` (v3) | `invoice.view` | |
| `POST /api/invoices/pdf` (v3) | `invoice.view` | |

## Team & Invitations

| Endpoint | Action Key | Notes |
|----------|-----------|-------|
| `POST /api/invitations` | `worker.invite` | Quota check: `WorkerSeats` |
| `POST /api/invitations/{id}/revoke` | `worker.invite` | |
| `GET /api/invitations` | `worker.view` | |
| `POST /api/invitations/list` | `worker.view` | |
| `GET /api/invitations/{id}` | `worker.view` | |
| `DELETE /api/team/members/{userId}` | `worker.remove` | |
| `PUT /api/team/members/{userId}/contact` | `worker.view` | |
| `GET /api/team/members` | `worker.view` | |
| `GET /api/team/members/{userId}` | `worker.view` | |

## Worker Endpoints (WorkerController)

Worker self-service endpoints — accessible to Workers and Admins. No plan check needed (plan was validated at invitation time).

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/worker/businesses` | `worker.self` |
| `GET /api/worker/invitations` | `worker.self` |
| `GET /api/worker/visits` | `worker.self` |
| `GET /api/worker/visits/stats` | `worker.self` |
| `GET /api/worker/visits/{visitId}` | `worker.self` |
| `PATCH /api/worker/visits/{visitId}/status` | `visit.update` |
| `POST /api/invitations/{token}/accept` | `worker.self` |
| `POST /api/invitations/accept-all` | `worker.self` |

## Email

| Endpoint | Action Key |
|----------|-----------|
| `POST /api/email` (v1/v2/v3) | `invoice.email.send` |
| `POST /api/email/send` (v3) | `invoice.email.send` |

# P2 — Everything Else (lower priority)

## Reports & Export

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/reports/{type}` | `report.view` |
| `GET /api/reports/stream/invoices_full_period_pdf_zip` | `report.view` |
| `GET /api/reports/stream/clients/{clientId}/*` | `report.view` |
| `GET /api/reports/clients/{clientId}/{type}` | `report.view` |
| `GET /api/reports/totalsByYears` | `report.view` |
| `POST /api/reports/send` | `report.send` |
| `GET /api/account/export` | `report.view` |

## Expenses

| Endpoint | Action Key |
|----------|-----------|
| `POST /api/expenses` | `expense.manage` |
| `GET /api/expenses` | `expense.manage` |
| `GET /api/expenses/pnl-report` | `expense.manage` |
| `POST /api/expenses/sync` | `expense.manage` |
| `POST /api/expenses/sensibill/*` | `expense.manage` |
| `POST /api/expenses/plaid/*` (6 endpoints) | `expense.manage` |
| `POST /api/expenses/sync-incomes` | `expense.manage` |
| `GET /api/expenses/incomes-pnl-report` | `expense.manage` |

## Mileage

| Endpoint | Action Key |
|----------|-----------|
| `PUT /api/mileage/trips/{id}` | `expense.manage` |
| `DELETE /api/mileage/trips/{id}` | `expense.manage` |
| `GET /api/mileage/trips` | `expense.manage` |
| `POST /api/mileage/reports` | `expense.manage` |

## Payments

| Endpoint | Action Key |
|----------|-----------|
| `POST /api/payments/sync-external-payment-data` | `billing.manage` |
| `GET /api/payments/types` | `billing.manage` |
| `POST /api/payments/availability` | `billing.manage` |
| `GET /api/payments/authenticated-types` | `billing.manage` |
| `POST /api/payments/connections/*` | `billing.manage` |
| `POST /api/payments/disconnect/*` | `billing.manage` |
| `POST /api/payouts` | `billing.manage` |
| `GET /api/payouts/balance-summary` | `billing.manage` |
| `POST /api/payouts/search-by-created-date` | `billing.manage` |

## Payment Requests

| Endpoint | Action Key |
|----------|-----------|
| `PUT /api/payment-requests` | `billing.manage` |
| `DELETE /api/payment-requests/{id}` | `billing.manage` |
| `GET /api/payment-requests` | `billing.manage` |
| `GET /api/payment-requests/{id}` | `billing.manage` |
| `POST /api/payment-requests/{id}/payment-link` | `billing.manage` |

## Clients

| Endpoint | Action Key |
|----------|-----------|
| `POST /api/clients` | `client.manage` |
| `DELETE /api/clients/{clientId}` | `client.manage` |
| `GET /api/clients` | `client.manage` |
| `GET /api/clients/{clientId}` | `client.manage` |
| `GET /api/clients/paged` | `client.manage` |

## Items

| Endpoint | Action Key |
|----------|-----------|
| `POST /api/items` | `item.manage` |
| `DELETE /api/items/{itemId}` | `item.manage` |
| `GET /api/items` | `item.manage` |
| `GET /api/items/{itemId}` | `item.manage` |
| `GET /api/items/paged` | `item.manage` |
| `GET /api/items/summary` | `item.manage` |

## Taxes

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/taxes/templates/{year}` | `tax.manage` |
| `POST /api/taxes/actualize` | `tax.manage` |
| `POST /api/taxes/calculate` | `tax.manage` |
| `POST /api/taxes/calculate-mileage-deduction` | `tax.manage` |
| `POST /api/taxes/user/location` | `tax.manage` |
| `GET /api/taxes/user/location` | `tax.manage` |
| `POST /api/taxes/pick` | `tax.manage` |

## Tap2Pay

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/tap2pay/location-id-and-token` | `billing.manage` |
| `POST /api/tap2pay/capture-payment` | `billing.manage` |
| `GET /api/tap2pay/fee` | `billing.manage` |
| `POST /api/tap2pay/calc-fees-amount` | `billing.manage` |

## Account & Identity

| Endpoint | Action Key | Notes |
|----------|-----------|-------|
| `GET /api/account` | — | |
| `PUT /api/account` | `account.settings` | |
| `PUT /api/account/{accountId}/update` | `account.settings` | |
| `DELETE /api/account` | `account.settings` | |
| `PUT /api/account/set_identifiers` | — | |
| `POST /api/account/claim-email` | — | |
| `GET /api/account/all*` (3 variants) | — | |
| `GET /api/account/subscription` | — | |
| `PUT /api/account/receipt` | — | |
| `GET /api/account/features` | — | |
| `GET /api/account/currencies` | — | |
| `GET /api/account/business-profile` | `account.settings` | |
| `PUT /api/account/business-profile` | `account.settings` | |
| `GET /api/account/pricing` | — | |

## Subscription & Plans

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/plans/current` | — |
| `GET /api/plans/active` | — |
| `POST /api/plans/upgrade-links` | `billing.manage` |
| `POST /api/plans/cancel` | `billing.manage` |
| `POST /api/plans/renew` | `billing.manage` |
| `GET /api/users/authenticated/subscription-management-link` | `billing.manage` |

## Self-Service (current user)

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/me/permissions` | — |
| `GET /api/me/contact` | — |
| `PUT /api/me/contact` | — |
| `GET /api/features` | — |
| `GET /api/onboarding` | — |
| `POST /api/onboarding/steps/{step}/skip` | — |
| `POST /api/onboarding/dismiss-modal` | — |
| `GET /api/notifications` | — |
| `POST /api/notifications/{id}/read` | — |

## Templates, Logo, Content

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/templates` | — |
| `POST /api/templates` | `account.settings` |
| `GET /api/logo` | — |
| `POST /api/logo` | `account.settings` |
| `DELETE /api/logo` | `account.settings` |
| `POST /api/contents/generate-upload-link` | `account.settings` |
| `GET /api/contents` | — |

## Config & Data

| Endpoint | Action Key |
|----------|-----------|
| `POST /api/account-configurations/set` | `account.settings` |
| `PATCH /api/account-configurations/regional` | `account.settings` |
| `GET /api/account-configurations/regional` | — |
| `PUT /api/data/{key}` | `account.settings` |
| `GET /api/data/{key}` | — |
| `DELETE /api/data/{keyWithVersion}` | `account.settings` |

## Chat (AI)

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/chat` | `account.settings` |
| `POST /api/chat/ask` | `account.settings` |

## Stripe Web Links

| Endpoint | Action Key |
|----------|-----------|
| `GET /api/stripe-links/{type}` | `billing.manage` |
| `GET /api/stripe-links/account-session/{type}` | `billing.manage` |
| `GET /api/stripe-web-links/payments` | `billing.manage` |
| `GET /api/stripe-web-links/payment-details/{paymentId}` | `billing.manage` |
| `GET /api/stripe-web-links/onboarding` | `billing.manage` |
| `GET /api/stripe-web-links/payouts` | `billing.manage` |

## Web Links (invoice/estimate views)

No user context — `AccountIdWithSignature` auth. No `[AuthorizeAction]` check.

| Endpoint | Action Key | Notes |
|----------|-----------|-------|
| `GET /api/web-links/invoices/{invoiceId}` | — | AccountIdWithSignature auth |
| `GET /api/web-links/estimates/{estimateId}` | — | AccountIdWithSignature auth |
| `GET /api/web-links/payment-requests/{id}` | — | AccountIdWithSignature auth |
| `GET /api/payments/web-link-hooks/{idWithProvider}` | — | AccountIdWithSignature auth |
| `GET /api/payment-requests/payment-link-hooks/{id}` | — | AccountIdWithSignature auth |

## Skipped (anonymous/webhook — no auth changes needed)

- `AuthenticateController` — auth/registration endpoints (`[AllowAnonymous]`)
- `OneTimePasswordsController` — OTP flow (`[AllowAnonymous]`)
- `InvoiceGeneratorController` — free PDF generator (`[AllowAnonymous]`)
- `WebCheckoutController` — checkout flow (`[AllowAnonymous]`)
- `BduiController` — BDUI templates (`[AllowAnonymous]`)
- `SharedBundlesController` — HTML bundles (`[AllowAnonymous]`)
- `SendGridCallbackController` — email webhooks (no BaseController)
- `SendinblueCallbackController` — email webhooks (no BaseController)
- `FunnelfoxCallbackController` — FunnelFox webhook (secret key auth)
- `Web2WaveCallbackController` — Web2Wave webhook (`[AllowAnonymous]`)
- `PromoController` — attribution redirect (no BaseController)
- `ImageController` — image serving (no BaseController)
- `ToolsController` — internal PDF tools
- `UsersController` — user identifiers (internal)

---

## Action Key Summary

All action keys used in this map, with their Access Registry conditions:

| Action Key | Roles | Plans | Quota |
|-----------|-------|-------|-------|
| `invoice.view` | Admin, Worker | All | — |
| `invoice.create` | Admin | All | — |
| `invoice.delete` | Admin | All | — |
| `invoice.email.send` | Admin | All | EmailsPerDay |
| `estimate.view` | Admin | All | — |
| `estimate.create` | Admin | All | — |
| `job.view` | Admin, Worker | Starter, FsmSolo, FsmTeam, FsmBusiness | — |
| `job.create` | Admin | FsmSolo, FsmTeam, FsmBusiness | FreeJobs (Starter) |
| `job.delete` | Admin | FsmSolo, FsmTeam, FsmBusiness | — |
| `visit.update` | Admin, Worker | FsmSolo, FsmTeam, FsmBusiness | — |
| `worker.invite` | Admin | FsmSolo, FsmTeam, FsmBusiness | WorkerSeats |
| `worker.view` | Admin | FsmSolo, FsmTeam, FsmBusiness | — |
| `worker.remove` | Admin | FsmSolo, FsmTeam, FsmBusiness | — |
| `worker.self` | Admin, Worker | All | — |
| `expense.manage` | Admin | All | — |
| `report.view` | Admin | All | — |
| `report.send` | Admin | All | EmailsPerDay |
| `client.manage` | Admin | All | — |
| `item.manage` | Admin | All | — |
| `tax.manage` | Admin | All | — |
| `billing.manage` | Admin | All | — |
| `account.settings` | Admin | All | — |

**"All"** = Starter, Plus, Premium, Invoicing, FsmSolo, FsmTeam, FsmBusiness.
