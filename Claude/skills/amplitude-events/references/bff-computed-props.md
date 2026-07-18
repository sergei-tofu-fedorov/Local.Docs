# BFF-computed props consumed by client analytics

How `Invoices.Backend` (BFF) produces each field that client analytics events read
from BFF responses and forward to Amplitude. Chains are controller -> service -> data
source with `file:line`. All paths are under
`C:\Git\Work\Backend\Invoices.Backend\Src\`.

Legend for "data source": **gRPC(Tofu.Invoices)** = call to the core invoices domain
service; **Tofu.Auth** = call to the auth service via `ITofuAuthApiClient`; **Mongo** =
BFF's own MongoDB (`invoicesDB`); **passthrough** = BFF echoes a value it did not compute.

---

## `userPlatformId` / `masterUserId` (client Amplitude user_id)

- **Endpoint:** `POST /api/authenticate/auth` — `AuthenticateController.Auth`
  (`Invoices.Api/Controllers/AuthenticateController.cs:44-98`). Response DTO
  `AuthResponse` (`Invoices.Api/Models/Authenticate/AuthRequest.cs:17-24`) carries
  `UserPlatformId` and `MasterUserId` (plus `IsNewMaster`, `IsFirstEverLink`,
  `IsFirstTime`).
- **Computation chain:**
  1. `AuthenticateController.Auth` calls
     `_authApiAuthenticationService.AuthenticateWithAuthApi(...)` (`AuthenticateController.cs:61`).
  2. `AuthApiAuthenticationService.AuthenticateWithAuthApi`
     (`Invoices.Implementation.Services/Authentication/AuthApiAuthenticationService.cs:26`)
     calls `_tofuAuthApiClient.GetAuthenticatedUserInfoAsync` (**Tofu.Auth**, validates the
     Firebase JWT / session cookie) and sets
     `masterUserId = $"{authenticatedUserInfo.Id}".ToLower()` (`:32`). This id (the
     Tofu.Auth user id) is the authoritative **`masterUserId`**. It is threaded through as
     `AuthenticationInfo.MasterUserId` (`:44`, `:83-88`).
  3. Back in the controller, `_authService.TryRegister(authenticationInfo, request.UserPlatformId, ...)`
     (`AuthenticateController.cs:82`) → `AuthService.TryRegister`
     (`Invoices.Implementation.Services/Authentication/AuthService.cs:71`).
  4. **`UserPlatformId`** = `platId`, resolved with this precedence
     (`AuthService.cs:81-83`):
     `request.UserPlatformId` (client-supplied; iOS only)
     `?? masterUser.FindPlatformUserLink(platform, product)?.PlatformId` (existing link in
     the BFF `MasterUser` aggregate, **Mongo**)
     `?? authenticationInfo.MasterUserId` (fallback = the master id itself).
  5. **`MasterUserId`** returned = `authenticationInfo.MasterUserId` verbatim
     (`AuthService.cs:129`; migration path `:186`).
  - `AuthResult` shape: `Invoices.Core/Authentication/IAuthService.cs:63-70`.
- **Returned account id:** the `/authenticate/auth` **response body does NOT contain an
  account id** — `AuthResponse` has no such field (`AuthRequest.cs:17-24`). Server-side an
  account id *is* resolved into `AuthenticationInfo.AccountId` from the master's accounts
  (`AuthApiAuthenticationService.cs:65-81`) but it is not serialized back. On subsequent
  requests `BaseController.AccountId` comes from the `X-Account-Id` request header via
  `AccountAuthenticationMiddleware` (`Invoices.Api/Controllers/BaseController.cs:12-13`),
  i.e. the client supplies it. So the web/iOS `account_id` event prop is the
  client-held/header account id, not an auth-response value.
- **Feeds client prop(s):** web Amplitude `user_id` = `userPlatformId` (full, untruncated);
  WorkerApp `user_id` = worker's own `masterUserId`; iOS/Android derive their `user_id`
  from the platform id (truncated to 25 chars client-side). `masterUserId` also feeds iOS
  `signInFinished(masterId, isNewMaster, isEverLinked)`.

---

## `industry` (worker `business_industry`)

- **Endpoint:** `GET /api/Account/business-profile` (api-version 3.0) —
  `AccountController.GetBusinessProfile` (`Invoices.Api/Controllers/V3/AccountController.cs:358-367`).
  Returns `BusinessProfileDto` (fields include `Industry`, `TeamSize`, `PainPoints`,
  `CleaningSubtype`, `JobMix`, `PaymentMethods`). Written by
  `PUT /api/Account/business-profile` → `SaveBusinessProfile` (`AccountController.cs:369-386`).
- **Computation chain:**
  1. `GetBusinessProfile` → `_businessProfileService.GetByAccountId(AccountId, ct)`
     (`AccountController.cs:363`).
  2. `BusinessProfileService.GetByAccountId`
     (`Invoices.Implementation.Services/BusinessProfile/BusinessProfileService.cs:20-23`)
     → `_repository.FindByAccountId(accountId, ct)`.
  3. `BusinessProfileRepository.FindByAccountId`
     (`Invoices.Implementation.MongoDb/Repositories/BusinessProfileRepository.cs:20-23`):
     **Mongo** — `context.BusinessProfiles.Find(x => x.AccountId == accountId).FirstOrDefaultAsync`.
     `industry` is a stored string field on the `BusinessProfile` document, keyed by
     `AccountId`, set on save via `Upsert` (`BusinessProfileRepository.cs:34-35`). No
     computation — plain persisted value the client itself wrote during onboarding.
- **Data source:** Mongo collection `BusinessProfiles`, one doc per account.
- **Feeds client prop(s):** WorkerApp sends it as `business_industry` on every event.
  (Web captures the same answer client-side as user property `user_industry` during the
  onboarding quiz rather than reading it back.)

---

## Invoice/estimate balances (web `is_first_time`)

Two separate endpoints; both are **thin passthroughs to gRPC(Tofu.Invoices)** — the counts
are aggregated inside the core Tofu.Invoices service, not in the BFF.

### Invoices — `getInvoicesBalance()`
- **Endpoint:** `GET /api/v3/invoices/balances` (`AuthorizeAction Invoice.View`) —
  `InvoicesController.Balances` (`Invoices.Api/Controllers/V3/InvoicesController.cs:125-139`).
  Returns `InvoicesBalancesDto` with `PaidInvoicesCount`, `UnpaidInvoicesCount`,
  `OverdueInvoicesCount`, and per-currency `Balances`
  (`Invoices.Api/Models/InvoicesBalancesDto.cs`).
- **Chain:** `_invoicesService.GetBalances(GetInvoiceBalancesRequestModel{ AccountId, ClientId }, ct)`
  (`InvoicesController.cs:132`) → `InvoicesService.GetBalances`
  (`Invoices.Api/Services/InvoicesService.cs:112-114`) → `_gateway.GetBalances` →
  `InvoicesGateway.GetBalances` (`Tofu.Invoices/InvoicesGateway.cs:21-29`): gRPC
  `_invoicesApiClient.GetInvoiceBalancesAsync(...)` with `X-Account-Id` header. Counts
  are computed by the **external Tofu.Invoices service** (not visible in this repo);
  `PaidInvoicesCount`/`UnpaidInvoicesCount` come straight off the gRPC response
  (`GetInvoiceBalancesResponseModel`, `Invoices.Core/Models/Invoices/GetInvoiceBalancesResponseModel.cs`).
- **Feeds:** web `is_first_time` = `paidInvoicesCount + unpaidInvoicesCount === 0` (Click
  Create Invoice) or `=== 1` (Invoice Created/Edited).

### Estimates — `getEstimateBalance()`
- **Endpoint:** `GET /api/estimates/balances` (`AuthorizeAction Estimate.View`) —
  `EstimatesController.Balances` (`Invoices.Api/Controllers/EstimatesController.cs:172-184`).
  Returns `EstimatesBalancesDto` (a per-currency `Balances` list;
  `Invoices.Api/Models/EstimatesBalancesDto.cs`).
- **Chain:** `_estimatesService.GetBalances(GetEstimatesBalancesRequestModel{ AccountId, ClientId }, ct)`
  (`EstimatesController.cs:177`) → `EstimatesService.GetBalances` → gateway →
  `EstimatesGateway.GetBalances` (`Tofu.Invoices/EstimatesGateway.cs:106-115`): gRPC
  `_estimatesApiClient.GetEstimatesBalancesAsync(...)` with `X-Account-Id` header.
  Aggregation done in the **external Tofu.Invoices service**.
- **Feeds:** web `is_first_time` = `balances.length === 0` (Click Create Estimate) or
  `=== 1` (Estimate Created/Edited). Web reads the *length of the currency-keyed balances
  list*, not a numeric count field.

> Note: there is a second, unrelated way the BFF surfaces counts — the auth
> `GET /api/Account/all?includeActivity=true` path returns `TotalInvoices`/`TotalEstimates`
> per account, computed in `AuthService.GetAccountActivity` via
> `_invoicesGateway.GetPaged` / `_estimatesGateway.GetPaged` `TotalCount`
> (`AuthService.cs:250-280`). This is NOT what web's `getInvoicesBalance`/`getEstimateBalance`
> `is_first_time` reads — those use the `/balances` endpoints above. Listed for completeness.

---

## Account `logoUrl` (web `is_logo_added`)

- **Endpoint:** the account list/info endpoints on `AccountController` (V3) —
  `GET /api/Account/all`, `/all-by-account-id`, `/all-by-platform-user`
  (`Invoices.Api/Controllers/V3/AccountController.cs:97-200`). Each account object carries
  `LogoUrl`. (`$chosenAccount.logoUrl` in the web store is one of these account responses.)
- **Computation chain:**
  1. Controller → `_authService.GetOwnedAccountInfos(accountIds, includeActivity, ct)`
     (e.g. `AccountController.cs:119`, `:165`, `:197`).
  2. `AuthService.GetOwnedAccountInfos` (`AuthService.cs:198-248`): after loading accounts
     from **Mongo** (`_accountsRepository.FindManyAsync`, `:205`), calls
     `_logoService.FindLogoUrls(accountIdsList, ct)` (`:208`) and sets
     `AuthedAccountInfo.LogoUrl = logoUrlByAccountId.GetValueOrDefault(a.Id)` (`:218`, `:240`).
  3. `LogoService.FindLogoUrls` (`Invoices.Common/Services/Images/LogoService.cs:85-89`):
     **Mongo** — `_repository.FindManyAsync(accountIds)` on the `Logos` collection
     (`LogosRepository`), then `FormatLogoUrl(logo.Name)` builds
     `{WebLinkOptions.BaseHost}/image/{logoName}` (`LogoService.cs:107-114`). An account
     with no `Logo` document gets **no entry** → `LogoUrl` is null/absent.
  - `AuthedAccountInfo.LogoUrl` type: `Invoices.Core/Authentication/IAuthService.cs:76`.
- **Data source:** Mongo `Logos` collection (per-account logo doc); URL is synthesized from
  the stored logo name. Presence/absence of the doc is what matters.
- **Feeds client prop(s):** web `is_logo_added` = `Boolean($chosenAccount.logoUrl)` on
  Invoice Created / Invoice Edited. (Estimate Created/Edited hardcodes `is_logo_added:false`
  on web — does not read this.)

---

## `acceptedPaymentProviders` (iOS invoiceCreated / didEditInvoice)

- **Endpoint:** any invoice read endpoint — the field lives on `InvoiceDto`
  (`Invoices.Api/Models/InvoiceDto.cs:46`, `string[]? AcceptedPaymentProviders`), returned
  by `GET /api/v3/invoices/{id}`, the paged list, etc.
- **Computation chain (read path):** it is a **passthrough**, NOT computed from
  Stripe/PayPal onboarding on the read path:
  1. Api mapping sets
     `AcceptedPaymentProviders = model.PaymentInfo?.AcceptedPaymentProviders`
     (`Invoices.Api/Models/Invoices/Mapping.cs:148`), where `model` is the domain invoice
     returned by the gateway.
  2. That `PaymentInfo` is filled from the **gRPC(Tofu.Invoices)** invoice payload:
     `Tofu.Invoices/Mapping/Mapper.cs:695-701` maps the proto `InvoiceInfo.AcceptedPaymentProviders`
     into `Models.PaymentInfo.AcceptedPaymentProviders`. Model:
     `Invoices.Core/Models/PaymentInfo.cs:5`.
  3. The value is **stored on the invoice aggregate in the core Tofu.Invoices service**. It
     is written there from what the client sends on create/edit: the BFF write mapping
     `Invoices.Api/Models/Invoices/Mapping.cs:233-237` copies
     `model.AcceptedPaymentProviders` (from the inbound `InvoiceDto`) into the domain
     invoice's `PaymentInfo` before it is persisted via gRPC.
- **Where the BFF DOES compute an accepted provider from account onboarding state:** only in
  the **web-link / email rendering** path, not the invoice API DTO.
  `AuthenticatedPaymentTypesExtensions.GetProviderName(this AuthenticatedPaymentTypes?, string[] acceptedPaymentProviders)`
  (`Invoices.Common/Extensions/AuthenticatedPaymentTypesExtensions.cs:7-31`) intersects the
  invoice's stored `acceptedPaymentProviders` with the account's connected
  `AuthenticatedPaymentTypes` (provider records with `Enabled`/`SoftEnabled`, stored in
  Mongo `AuthenticatedPaymentTypesRepository`) to pick which pay button to show. Callers are
  `WebLinkViewService.cs`, `Tofu.Email/Service/EmailTemplateService.cs`,
  `Invoices.Common/Services/Templates/HtmlBuilder.cs` — all rendering surfaces, none feed the
  `InvoiceDto.acceptedPaymentProviders` the iOS event reads.
- **Feeds client prop(s):** iOS `invoiceCreated(..., acceptedPaymentProviders:[PaymentProvider]?, ...)`
  and `didEditInvoice(..., acceptedPaymentProviders?)`. The list the client reads is the
  per-invoice stored list echoed by the BFF, i.e. the providers marked accepted on *that
  invoice* (originally chosen at create/edit time), NOT a live recomputation of the account's
  Stripe/PayPal onboarding at read time.

---

## Untraceable / needs verification

- **Counts computed inside Tofu.Invoices.** `PaidInvoicesCount` / `UnpaidInvoicesCount` /
  `OverdueInvoicesCount` and the estimate balances are produced by the external
  Tofu.Invoices gRPC service (`GetInvoiceBalancesAsync` / `GetEstimatesBalancesAsync`); the
  BFF only forwards them. The actual aggregation (Mongo pipeline vs. SQL) lives in the
  `Tofu.Invoices.Backend` repo, not here — verify there if the aggregation logic matters.
- **`acceptedPaymentProviders` origin at invoice creation.** Confirmed the BFF stores what
  the client sends and echoes it back. Whether the *client* seeds that list from the
  account's connected providers (and thus whether it indirectly reflects Stripe/PayPal
  onboarding) is a client-side decision — the iOS/Web catalogs both flag it "may reflect BFF
  payment config; verify". The BFF read path itself does no onboarding-based computation of
  this DTO field.
- **`account_id` on auth.** The `/authenticate/auth` response does not return an account id;
  clients use the account id they already hold / send as `X-Account-Id`. If a caller claims
  the auth response yields `account_id`, that is inaccurate for this BFF version.
