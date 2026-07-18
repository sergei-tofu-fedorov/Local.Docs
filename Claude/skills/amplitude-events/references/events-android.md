# Android — Amplitude events catalog

- Vendor/SDK: **Amplitude** (`com.amplitude.api.AmplitudeClient`) via `AmplitudeReporter`. Firebase Analytics (`FirebaseReporter`) is also a live target. Mixpanel + AppsFlyer reporters exist in code but are **not registered** in `generatedAnalyticModule.kt` — so despite `Targets:` lines that name them, only **Amplitude + Firebase** actually receive events.
- Central send point: `common/analytics/src/main/java/com/tofu/common/analytics/api/ReporterWrapper.kt:9` — `fun ReporterWrapper.report(event, targets, vararg params)`; dispatched by `internal/CompositeReporter.kt:17` (`report(event, targets, params)` → filters blank params, adds common params, fans out to registered `TargetReporter`s). Entry object: `GeneratedAnalytics` (`typealias G`), `api/GeneratedAnalytics.kt:12`. Amplitude sink: `internal/target/AmplitudeReporter.kt:16` (`amplitude.logEvent`).
- Identity (user_id): Amplitude `setUserId = account.userId.public`, set in `app/.../domain/usecases/InitializationUseCase.kt:135` (`amplitude.userId = userId`, reacting to `accountGateway.observeAccount()`). `.public` = first 25 chars of the secret id — `feature/accountstorage/.../entity/IdImpl.kt:11` (`secret.slice(0..24)`). Same value also set on Firebase (`:142-143`) and AppsFlyer (`:139`).
- Standard params (auto-added to EVERY event by `app/.../utils/ReporterParamsInterceptor.kt:21`, applied in `CompositeReporter.kt:19`):
  - `is_first_time` — `standard` / computed: true on first emission of that event name, then persisted false in DataStore (`ReporterParamsInterceptor.kt:24-27`).
  - `account_id` — `standard` / client: `accountGateway.observeAccount().accountId.public` (local account model; first 25 chars of account secret id).
  - Note: `CompositeReporter.kt:19` drops any param whose value is blank (`""`) before sending — so unset optional params never reach Amplitude.
- Definition style: **events.md → code-gen.** Markdown files under `common/analytics/events/*.md` (`events.md`, `account.md`, `invoice.md`, `navigation.md`, `promo.md`, `purchase.md`, `wasm.md`) are parsed at build time by `buildSrc/.../analytics/Parser.kt` and emitted as Kotlin extension functions `fun ReporterWrapper.<eventName>(...)` by `Generator.kt` (`generateCategoryFile`). Event name = the `####` heading verbatim; function name = camelCase, letters-only (`asFieldName`). Each generated fn calls `report("<Event Name>", listOf(targets), "key" to value,…)`. Empty `Targets:` → all registered targets. Enum params send `.tag`; optional params default `null` and serialize to `""` (then stripped). Call sites supply the argument values catalogued below.

User properties (Amplitude `setUserProperties`, via `G.setProperty`, NOT per-event; keys in `api/UserProperties.kt`):
- `user_email` ← `app/.../usecases/ClaimEmailUseCase.kt:15`. `invoices_notpaid`/`invoices_paid`/`invoices_total` ← `feature/invoicestorage/.../InvoiceDatabaseWriter.kt:94-96` (local DB counts). `catalog_clients`/`catalog_items` ← `feature/catalogstorage/.../CatalogSyncDelegate.kt:46,87` + `CatalogLocalStorageRepo.kt` (local DB counts). `is_push_enabled` ← `feature/invoicedetails/.../InvoiceDetailsScreen.kt:57` (OS notification permission). `subscription_product`/`renew_product` ← `feature/billingstorage/.../SubscriptionStorageRepo.kt:104,107` (Google Play sub status). `local_exp_percentile` ← `feature/abtesting/.../LocalPercentileProvider.kt:32`. Constants `trial_active`, `campaign_id` are declared but not set anywhere in the repo.

## Events

### `Demo event`
- Fired at: **no call sites** (documentation sample in `events.md`; generated fn `demoEvent` unused).
- Targets: Amplitude, Appsflyer, Firebase, Mixpanel (declared; effective Amplitude+Firebase).
- Props: `some_text`, `optional_text`, `some_number`, `some_flag`, `some_enumeration` — all `unknown` (never fired).

### `Rate dialog shown`
- Fired at: `app/src/main/java/com/tofu/invoices/domain/usecases/LaunchReviewDialogUseCase.kt:49` (Play `launchReviewFlow` completion listener).
- Targets: all (Amplitude+Firebase live).
- Props: none.

### `Server error`
- Fired at: `common/storage/src/main/java/com/tofu/common/storage/internal/SafeNetworkCall.kt:70` (HttpCallError), `:78` (ConnectionCallError, if not Cancelled), `:86` (ApiCallError).
- Targets: Amplitude (only).
- Props:
  | prop | provenance |
  |------|------------|
  | url | client: failed request path (`e.path`) |
  | error_code | **bff**: HTTP status of failed server response (`e.httpErrorCode`, `:70`) / API error code from server body (`e.code`, `:86`); computed local reason name for connection errors (`e.reason.name`, `:78`) |
  | error_message | **bff**: HTTP error message (`:70`) / API error message + info JSON (`:86`); client connection error message (`:78`) |
  | cause | computed: `response.error.cause?.message` (underlying exception) |

### `Experiment started`
- Fired at: `feature/abtesting/.../remote/RemoteExperiment.kt:59`, `feature/abtesting/.../remote/pricing/PricingExperiment.kt:92`, `feature/abtesting/.../local/LocalExperiment.kt:46`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | exp_name | client: experiment preference-key tag (`key.tag`) / literal `exp_pricing_plan_ongoing_android` (PricingExperiment) |
  | variant_id | **bff**: Firebase Remote Config value (`remoteConfig.getString`) for remote exps; computed local percentile bucket for `LocalExperiment` (`calculateValue(userPercentile)`) |

### `Applied forced variant`
- Fired at: `feature/abtesting/.../remote/RemoteExperiment.kt:48`, `feature/abtesting/.../remote/pricing/PricingExperiment.kt:79`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | exp_name | client: preference-key tag (`key.tag`) |
  | variant_id | **bff**: Firebase Remote Config value (forced variant from remote config) |

### `Remote config fetched`
- Fired at: `feature/abtesting/.../remote/firebase/FirebaseRemoteConfig.kt:34` (activate listener), `:89` (fetchAndActivate).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | success | computed: `Task.isSuccessful` of Firebase `activate()`/`fetchAndActivate()` |

### `Business name requested`
- Fired at: **no call sites** (fn `businessNameRequested` unused).
- Targets: all. Props: none.

### `Edit business profile`
- Fired at: `feature/businessprofile/.../redux/epics/SaveProfileEpic.kt:54` (on `SaveChangesAction`, reads Redux `BusinessProfileState.currentInfo`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | business_name | client: form field `currentInfo.businessName` |
  | has_adress | computed: `!currentInfo.address.isNullOrBlank()` |
  | has_email | computed: `!currentInfo.email.isNullOrBlank()` |
  | has_name | computed: `!currentInfo.name.isNullOrBlank()` |
  | has_phone | computed: `!currentInfo.phone.isNullOrBlank()` |

### `adid access answered`
- Fired at: **no call sites** (fn `adidAccessAnswered` unused).
- Targets: all. Props: `granted` — unknown (never fired).

### `adid access dialog shown`
- Fired at: **no call sites** (fn `adidAccessDialogShown` unused).
- Targets: all. Props: none.

### `Sign up`
- Fired at: `feature/onboarding/.../redux/epics/BusinessNameEpic.kt:45` (on `SaveBusinessNameAction`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | not passed → `""` (stripped) |
  | name | client: onboarding form field `OnboardingState.businessName.trim()` |
  | restored | not passed → `""` (stripped) |

### `Logo changed`
- Defined in **both** `account.md` (`has_logo` Boolean?) and `invoice.md` (`has_logo` Boolean); identical emitted event ("Logo changed", `has_logo`).
- Fired at: `feature/businessprofile/.../redux/epics/LogoEpic.kt:70` (after `logoRepo.uploadLogo`), `:83` (after `logoRepo.deleteLogo`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | has_logo | literal: `true` (upload, `:70`) / `false` (delete, `:83`) |

### `Culture changed`
- Fired at: `app/src/main/java/com/tofu/invoices/data/repo/AccountInitializationRepo.kt:49` (in `updateCultureIfNeeded`, when device locale ≠ stored `account.culture`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | newCulture | client/computed: device locale `Locale.getDefault()` as `"lang_COUNTRY"` |

### `Add client`
- Fired at: `feature/clienteditor/.../redux/epics/SaveClientEpic.kt:70`, `feature/catalog/.../redux/epics/CatalogNavigationEpic.kt:88`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | has_adress | computed: `client.address != null` (local ClientEditorState / catalog DB client) |
  | has_email | computed: `client.email != null` |
  | has_phone | computed: `client.phone != null` |
  | is_from_catalog_contacts | literal: `false` (editor) / `true` (catalog add) |
  | type | literal: `invoice` (InvoiceType.INVOICE.tag) |

### `Add item`
- Fired at: `feature/itemeditor/.../redux/epics/SaveItemEpic.kt:74`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | has_details | computed: `!item.description.isNullOrEmpty()` (local ItemEditorState) |
  | has_discount | computed: `item.discount != null` |
  | is_from_catalog_items | computed: `params.source.position == null` (screen param) |
  | is_taxable | client: `item.isTaxApplied` (local item model) |
  | type | literal: `invoice` |
  | unit_type | not passed → `""` (stripped) |

### `Add notes`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:134` (guarded by local `state.notesWasChanged`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | type | literal: `invoice` |

### `Create catalog item`
- Fired at: `feature/catalogstorage/.../CatalogLocalStorageRepo.kt:45` (client, new row), `:89` (item, new row).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | client: `CatalogContext` passed into repo `save(...)` by caller |
  | type | literal: `client` (`:45`) / `item` (`:89`) |

### `Create invoice`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:114` (branch `invoiceId == null`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | amount | computed: `filledInvoice.totalAmount.toDouble()` (locally built `state.invoice.withFilledAmounts()`) |
  | has_discount | computed: `filledInvoice.discount != null` |
  | has_logo | literal: `false` |
  | has_tax | computed: `filledInvoice.tax != null` |
  | items_count | computed: `filledInvoice.items.size` |
  | received_payments | literal: `0` |
  | status | client: `filledInvoice.status.asEvent()` (local status→event mapping) |

### `Delete catalog item`
- Fired at: `feature/clienteditor/.../redux/epics/SaveClientEpic.kt:104`, `feature/itemeditor/.../redux/epics/SaveItemEpic.kt:112`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | type | literal: `client` (`:104`) / `item` (`:112`) |

### `Delete invoice`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:145`.
- Targets: all (Amplitude+Firebase live).
- Props: none.

### `Edit date`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:155` (on SetDateAction).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | type | literal: `invoice` |

### `Edit due date`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:158` (on SetDuePeriodAction).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | select_terms | client: `action.period ?: 0` (user-selected term; default 0) |

### `Edit invoice`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:124` (branch `invoiceId != null`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | amount | computed: `filledInvoice.totalAmount.toDouble()` (locally built model) |
  | has_discount | computed: `filledInvoice.discount != null` |
  | has_tax | computed: `filledInvoice.tax != null` |
  | items_count | computed: `filledInvoice.items.size` |
  | received_payments | literal: `0` |
  | status | client: `filledInvoice.status.name` (local status enum name) |

### `Edit invoice number`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:161` (on ApplyNumberAction).
- Targets: all (Amplitude+Firebase live).
- Props: none.

### `Import contacts`
- Fired at: `feature/clienteditor/.../redux/epics/SystemContactEpic.kt:44` (after a system contact is read).
- Targets: all (Amplitude+Firebase live).
- Props: none.

### `Mark invoice`
- Fired at: `feature/invoicedetails/.../redux/epic/LoadInvoiceEpic.kt:70`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | literal: `invoice_details` (InvoiceDetailsContext.INVOICE_DETAILS.tag) |
  | to_status | client: `invoice.togglePaidStatus().status.name` — invoice from `invoiceGateway.observeInvoice(id)` (local storage, BFF-synced), status flipped client-side |

### `Send invoice`
- Fired at: `feature/invoicesharing/.../redux/epic/SendInvoiceEpic.kt:106` (email, after `api.send`), `:129` (messenger share), `:156` (pdf/link).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | application | literal: `email` (`:106`) / `pdf` (`:156`); client: chosen app from `navPort.shareInvoiceLinkIntent(...)` (`:129`) |
  | context | client: `params.source` (InvoiceSharingScreenParams) |

### `Tap create invoice`
- Fired at: `feature/invoicelist/.../InvoicesViewModel.kt:73` (called bare).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | not passed → `""` (stripped) |

### `Tap edit invoice`
- Fired at: `feature/invoicedetails/.../redux/epic/NavigateEpic.kt:46`.
- Targets: all (Amplitude+Firebase live).
- Props: none.

### `Tap preview`
- Fired at: `feature/invoiceeditor/.../redux/epics/SaveInvoiceEpic.kt:78`, `feature/invoicedetails/.../redux/epic/NavigateEpic.kt:53`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | not passed → `""` (stripped) |
  | type | literal: `invoice` |

### `Tap send invoice`
- Fired at: `feature/invoicesharing/.../redux/epic/SendInvoiceEpic.kt:174`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | not passed → `""` (stripped) |
  | type | literal: `invoice` |

### `Tap select currency`
- Fired at: `feature/invoiceeditor/.../redux/epics/InvoiceCurrencyEpic.kt:52`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | computed: local state → EMPTY/ONLY_ITEMS/FILLED/EDIT/UNKNOWN from `isNew`(`invoiceId.isNullOrEmpty()`), `hasClient`(`invoice?.client != null`), `hasItems`(`!invoice?.items.isNullOrEmpty()`) |
  | currentCurrency | client: `invoice?.currencyCode` (local invoice model, nullable) |

### `Currency selected`
- Fired at: `feature/invoiceeditor/.../redux/epics/InvoiceCurrencyEpic.kt:59`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | currencyCode | client: user pick from `navPort.currencySelectorResult(...)` (currency-selector screen result) |

### `App become active`
- Fired at: `app/src/main/java/com/tofu/invoices/TofuActivity.kt:140` (`onStart`).
- Targets: all (Amplitude+Firebase live). Props: none.

### `App launched`
- Fired at: `app/src/main/java/com/tofu/invoices/TofuActivity.kt:69` (`onCreate`). (The `appLaunched()` in `FirstLaunchDetectorRepo`/gateway is a different domain method, not analytics.)
- Targets: all (Amplitude+Firebase live). Props: none.

### `First tap on All invoices`
- Fired at: **no call sites** (fn `firstTapOnAllInvoices` unused).
- Targets: all. Props: none.

### `First tap to settings`
- Fired at: `feature/invoicelist/.../InvoicesViewModel.kt:68` (`onSettingsClick`).
- Targets: all (Amplitude+Firebase live). Props: none.

### `Main screen shown`
- Fired at: `feature/invoicelist/.../api/InvoicesScreen.kt:39` (`LaunchedEffect(Unit)`).
- Targets: all (Amplitude+Firebase live). Props: none.

### `Move to background`
- Fired at: `app/src/main/java/com/tofu/invoices/TofuActivity.kt:145` (`onStop`).
- Targets: all (Amplitude+Firebase live). Props: none.

### `Open tab`
- Fired at: **no call sites** (fn `openTab` unused).
- Targets: all. Props: `tab_name` — unknown (never fired).

### `Push access answered`
- Fired at: `feature/invoicedetails/.../api/InvoiceDetailsScreen.kt:62` (POST_NOTIFICATIONS permission dialog result).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | is_granted | client: OS permission-dialog result boolean (`granted`) |

### `Push access dialog shown`
- Fired at: `feature/invoicedetails/.../api/InvoiceDetailsScreen.kt:55` (`onShowRequest`).
- Targets: all (Amplitude+Firebase live). Props: none.

### `Push opened`
- Fired at: `app/src/main/java/com/tofu/invoices/presentation/IntentNavigation.kt:68` (`handleIntent`, when `PUSH_ID_EXTRA` present).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | push_id | **bff**: FCM push payload `data["push_id"]` (server-sent; `PushRepo.kt:122`), default `""` |
  | type | **bff**: FCM push payload `data["type"]` (server-sent; `PushRepo.kt:123`), default `""` |

### `Mini banner shown`
- Fired at: **no call sites** (fn `miniBannerShown` unused).
- Targets: all. Props: `feature` — unknown (never fired).

### `Close mini banner`
- Fired at: **no call sites** (fn `closeMiniBanner` unused).
- Targets: all. Props: `feature` — unknown (never fired).

### `Tap mini banner`
- Fired at: **no call sites** (fn `tapMiniBanner` unused).
- Targets: all. Props: `feature` — unknown (never fired).

### `Tap what's new button`
- Fired at: **no call sites** (fn `tapWhatsNewButton` unused).
- Targets: all. Props: `feature` — unknown (never fired).

### `What's new shown`
- Fired at: **no call sites** (fn `whatsNewShown` unused).
- Targets: all. Props: `feature` — unknown (never fired).

### `Purchase finished`
- Fired at: `feature/billing/.../data/PurchaseRepo.kt:84`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | client: `purchasingParams.source?.rawValue` (PurchaseSource enum from paywall launch), default `""` |
  | product_id | client: `purchasingParams.plan.productId` (Google Play SubscriptionPlan/ProductDetails) |
  | result | computed: SUCCESS/FAIL from local purchase-outcome flow (`SubsPurchaseResult`; outcome depends on Play billing + BFF `verifySubscription` receipt check — see BFF note) |

### `Billing started`
- Fired at: `feature/billing/.../data/PurchaseRepo.kt:115`.
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | product_id | client: `plan.productId` (Google Play) |
  | is_trial | client: `plan.isTrial` (Google Play SubscriptionPlan) |
  | response_code | client: `billingResponseCodeToCodeName(result.responseCode)` (Google Play BillingResult) |
  | response_message | client: `result.debugMessage` (Google Play BillingResult) |

### `Billing updated`
- Fired at: `feature/billing/.../internal/BillingClientHolder.kt:51` (`onPurchasesUpdated`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | order_id | client: `purchases?.firstOrNull()?.orderId` (Google Play Purchase) |
  | product_id | client: `purchases?.firstOrNull()?.products?.firstOrNull()` (Google Play Purchase) |
  | response_code | client: Google Play BillingResult (mapped) |
  | response_message | client: `result.debugMessage` (Google Play) |
  | purchase_count | computed: `purchases?.size ?: 0` (Google Play list) |

### `Billing acknowledged`
- Fired at: `feature/billing/.../data/PurchaseProcessRepo.kt:119` (acknowledge callback).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | order_id | client: `purchase.orderId` (Google Play) |
  | response_code | client: Google Play acknowledge BillingResult (mapped) |
  | response_message | client: `result.debugMessage` (Google Play) |

### `Billing purchase requested`
- Fired at: `feature/billing/.../data/PurchaseProcessRepo.kt:51` (`queryPurchasesAsync` callback).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | order_id | client: `purchases.firstOrNull()?.orderId` (Google Play) |
  | purchase_count | computed: `purchases.size` (Google Play query result) |
  | response_code | client: Google Play BillingResult (mapped) |
  | response_message | client: `result.debugMessage` (Google Play) |

### `Billing product requested`
- Fired at: `feature/billing/.../data/ProductsRepo.kt:97` (`queryProductDetailsAsync` callback).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | product_count | computed: `products.size` (Google Play ProductDetails list) |
  | plan_count | computed: `products.sumOf { subscriptionOfferDetails?.size ?: 0 }` (Google Play) |
  | response_code | client: Google Play BillingResult (mapped) |
  | response_message | client: `result.debugMessage` (Google Play) |

### `Restore finished`
- Fired at: `feature/billing/.../data/PurchaseRepo.kt:166` (`restorePurchase().also{}`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | result | computed: SUCCESS if `RestorePurchaseResult.Ok` else FAIL (depends on Play billing + BFF `verifySubscription` — see BFF note) |

### `Tap restore purchases`
- Fired at: `feature/settings/.../redux/epics/SubscriptionEpic.kt:39`.
- Targets: all (Amplitude+Firebase live). Props: none.

### `Tap invoice banner`
- Fired at: **no call sites** (fn `tapInvoiceBanner` unused).
- Targets: all. Props: `feature` — unknown (never fired).

### `Paywall shown`
- Fired at: `feature/paywall/.../api/PaywallScreen.kt:59`, `feature/subscriptionplans/.../api/SubscriptionPlansScreen.kt:52` (only when `source == SettingsScreen`).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | client: `params.source.rawValue` (PurchaseSource nav param), default `""` |
  | type | literal: `main` |

### `Tap show all plans`
- Fired at: `feature/paywall/.../redux/epics/NavEpic.kt:36`.
- Targets: all (Amplitude+Firebase live). Props: none.

### `Tap skip subscription paywall`
- Fired at: `feature/paywall/.../redux/epics/NavEpic.kt:46`.
- Targets: all (Amplitude+Firebase live). Props: none.

### `Tap subscribe`
- Fired at: `feature/paywall/.../redux/epics/PaywallEpic.kt:77` (ContinueAction), `feature/subscriptionplans/.../SubscriptionPlansViewModel.kt:67` (launchPurchaseFlow).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | client: `params.source?.rawValue` (nav param), default `""` |
  | product_id | client: `state.plan?.productId` / `plan.productId` (Google Play ProductDetails), default `""` |
  | type | literal: `main` |

### `Start Wasm form backend`
- Fired at: `app/.../TofuActivity.kt:58` (onCreate, port ≠ default), `:132` (onStart, `server.start()` throws); `app/.../usecases/InitializationUseCase.kt:192` (page-not-load callback), `:198` (preview-not-show callback).
- Targets: all (Amplitude+Firebase live).
- Props:
  | prop | provenance |
  |------|------------|
  | context | literal: `localhost_did_not_start` (`:58`,`:132`) / `page_did_not_load` (`:192`) / `preview_did_not_show` (`:198`) (WasmErrorContext.tag) |
  | errorMessage | computed: local chosen port string (`:58`), exception stack trace (`:132`), or local timeout value from remote config (`:192`,`:198`) |

## Properties sourced from BFF (to trace server-side)
| prop | event(s) | BFF endpoint / response field |
|------|----------|-------------------------------|
| error_code | Server error | HTTP status / API error code of the **failed Tofu server response** — `HttpCallError.httpErrorCode` (`SafeNetworkCall.kt:70`), `ApiCallError.code` (`:86`). Endpoint = the failing call's `e.path`. |
| error_message | Server error | Error message/body from the failed server response — HttpCallError message (`:70`), `ApiCallError.message + infoJson` (`:86`). |
| variant_id | Experiment started, Applied forced variant | **Firebase Remote Config** value (`remoteConfig.getString(key.tag)`) — Google Remote Config backend, NOT the Tofu BFF. Local-percentile experiments derive it client-side instead. |
| push_id | Push opened | **FCM push payload** `data["push_id"]` — delivered by the server that sends the push (`PushRepo.kt:122` → intent extra → `IntentNavigation.kt:69`). |
| type | Push opened | **FCM push payload** `data["type"]` — server-sent (`PushRepo.kt:123` → intent extra → `IntentNavigation.kt:70`). |
| result (indirect) | Purchase finished, Restore finished | Not a passed-through server field: a local SUCCESS/FAIL enum whose value **depends on** the BFF `subscriptionPort.verifySubscription(...)` receipt-verification result (`PurchaseProcessRepo.kt:89`). Flagged for completeness; the raw BFF response is not sent as a param. |

Notes:
- All Google Play Billing values (`response_code`, `response_message`, `order_id`, `product_id`, `product_count`, `plan_count`, `purchase_count`, `is_trial`) come from the **Play Billing SDK**, not the Tofu BFF — classified `client:google-play-billing`.
- Invoice metric props (`amount`, `status`, `items_count`, `received_payments`, `has_discount`, `has_tax`) are read off **locally-built/edited** `Invoice` domain models (`SaveInvoiceEpic.filledInvoice`, `LoadInvoiceEpic` toggled invoice), not off raw server responses. The underlying invoice entities sync from the BFF into local storage, but no raw server field is passed as an event arg. `received_payments` is hardcoded `0` on create/edit.
- Unused generated events (fn exists, no call site): Demo event, Business name requested, adid access answered, adid access dialog shown, First tap on All invoices, Open tab, Mini banner shown, Close mini banner, Tap mini banner, Tap what's new button, What's new shown, Tap invoice banner.
