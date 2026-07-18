# iOS (IM + FS) — Amplitude events catalog

- Vendor/SDK: Amplitude (+ Clarity session replay). Impl in external Tofu.Common.iOS.
- Central send points: `AnalyticsSender.send(_:)` at `Modules/InvoicesModule/Sources/InvoicesModule/Analytics/AnalyticsSender.swift:25` (new) and `TrackerService` methods (old, event-name strings formatted in Tofu.Common.iOS).
- Identity (user_id): `platformID.publicId` / master id — truncation in Tofu.Common.iOS. Clarity also gets `ClaritySDK.setCustomUserId(dataProvider.platformID.publicId)` at `Invoices/Invoices/Initializers/ClarityInitializer.swift:39,45`.
- Definition style: two coexisting styles.
  - NEW: per-screen enums conforming to `AnalyticsEvent` (protocol at `Modules/InvoicesModule/Sources/InvoicesModule/Analytics/AnalyticsEvent.swift`), each case exposes a literal `eventName` + `parameters: [String: TrackerParam?]`. Fired through an injected `AnalyticsSender` value (`analytics.send(SomeAnalyticsEvent.case)`). `AnalyticsSender.send` reduces params, replacing any `ScreenContext` marker with the sender's `context` string, then calls the underlying `_send(name, params)` (real impl in Tofu.Common.iOS).
  - OLD: ~130 strongly-typed methods on the `TrackerService` protocol (full surface mirrored in `Modules/MocksData/Sources/TrackerServiceMock.swift`). Each method maps to an Amplitude event whose NAME STRING is formatted inside Tofu.Common.iOS — not visible in this repo.

### `TrackerParam` types (in-repo, `.../Analytics/TrackerParam.swift`)
- `String`, `Decimal`, `Int`, `Bool` conform to `TrackerParam`.
- `ScreenContext` is a marker (`description = "inherit_context"`); `.screenContext` in a params dict is a placeholder that `AnalyticsSender.send` swaps for the sender's runtime `context` string. So `"context"` prop provenance = `client:AnalyticsSender.context` — set via `.with(context: <SomeContextEnum>.rawValue)` (e.g. `MainPaywallViewModel.swift:634`, `ExternalDeeplinkGateModifier.swift:92`).

## New-style events (AnalyticsEvent enums, in-repo)

38 cases across 12 non-empty enums (4 enum files are empty stubs: `VisitPhotoAnalyticsEvent`, `JobPhotoAnalyticsEvent`, `EditJobTitleAnalyticsEvent`, `AttachmentDetailsAnalyticsEvent` — all `switch self {}`, no cases).

#### TeamMembersAnalyticsEvent (`Modules/MyTofu/Sources/Modules/TeamMembers/TeamMembersAnalyticsEvent.swift`)

### `Open workers` (from TeamMembersAnalyticsEvent.openWorkers)
- Fired at: `Modules/MyTofu/Sources/Modules/TeamMembers/TeamMembersViewModel.swift:158`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `Invite worker` (from TeamMembersAnalyticsEvent.inviteWorker)
- Fired at: `TeamMembersViewModel.swift:144`
- Props: none (empty dict)

### `Revoke invite` (from TeamMembersAnalyticsEvent.revokeInvite)
- Fired at: `TeamMembersViewModel.swift:125`
- Props: none

### `Resend invite` (from TeamMembersAnalyticsEvent.resendInvite)
- Fired at: `TeamMembersViewModel.swift:109`
- Props: none

#### ClientStepAnalyticsEvent (`Modules/MyTofu/Sources/Modules/ScheduleJobFlow/Steps/Client/ClientStepAnalyticsEvent.swift`)

### `Add client` (from ClientStepAnalyticsEvent.createNew)
- Fired at: `Modules/MyTofu/Sources/Modules/ScheduleJobFlow/Steps/Client/ClientStepViewModel.swift:183`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

#### ScheduleJobFlowAnalyticsEvent (`Modules/MyTofu/Sources/Modules/ScheduleJobFlow/ScheduleJobFlowAnalyticsEvent.swift`)

### `Visit Created` (from ScheduleJobFlowAnalyticsEvent.visitCreated(isWorkerAssigned:))
- Fired at: `Modules/MyTofu/Sources/Modules/ScheduleJobFlow/ScheduleJobFlowViewModel.swift:216` (hardcoded `isWorkerAssigned: false`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | is_worker_assigned | client:VM (Bool assoc value) |

### `Job Created` (from ScheduleJobFlowAnalyticsEvent.jobCreated(withVisit:))
- Fired at: `ScheduleJobFlowViewModel.swift:218` (`withVisit: visit != nil`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | with_visit | computed:visit != nil (client VM) |

#### MainPaywallAnalyticsEvent (`Modules/MyTofu/Sources/Modules/Paywalls/MainPaywall/MainPaywallAnalyticsEvent.swift`)

### `Paywall shown` (from MainPaywallAnalyticsEvent.onLoad)
- Fired at: `MainPaywallViewModel.swift:640` and `:653`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | type | literal:"main" |

### `Tap skip subscription paywall` (from MainPaywallAnalyticsEvent.close)
- Fired at: `MainPaywallViewModel.swift:375`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `Tap subscribe` (from MainPaywallAnalyticsEvent.subscribe(placement:productId:))
- Fired at: `MainPaywallViewModel.swift:388` (`productId: subscription.productIdentifier`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | type | literal:"main" |
  | product_id | client:StoreKit subscription.productIdentifier |
  | placement | enum:PaywallButtonPlacement.rawValue (client) |

### `Tap feature` (from MainPaywallAnalyticsEvent.didTapFeature(id:))
- Fired at: `MainPaywallViewModel.swift:368` (`id: item.id`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | feature | client:paywall feature item.id (see GAP — may originate from BFF paywall config) |

### `Tap plan` (from MainPaywallAnalyticsEvent.didTapPlan(id:))
- Fired at: `Modules/MyTofu/Sources/Modules/Paywalls/MainPaywall/Views/MainPaywallPlanTabs.swift:30` (`id: plan.rawValue`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | plan | enum:plan.rawValue (client) |

#### InviteTeammateAnalyticsEvent (`Modules/MyTofu/Sources/Modules/InviteTeammate/InviteTeammateAnalyticsEvent.swift`)

### `Invite send success` (from InviteTeammateAnalyticsEvent.successSend)
- Fired at: `Modules/MyTofu/Sources/Modules/InviteTeammate/InviteTeammateViewModel.swift:58` (on BFF invite call success)
- Props: none

### `Invite send failed` (from InviteTeammateAnalyticsEvent.errorSend)
- Fired at: `InviteTeammateViewModel.swift:61` (on BFF invite call error)
- Props: none

#### EntryPointAnalyticsEvent (`Modules/MyTofu/Sources/Modules/EntryPoint/EntryPointAnalyticsEvent.swift`)

### `EntryPoint opened` (from EntryPointAnalyticsEvent.open)
- Fired at: `Modules/MyTofu/Sources/Modules/EntryPoint/EntryPointViewModel.swift:18`
- Props: none (enum has no `parameters` override → nil)

### `EntryPoint Create Account` (from EntryPointAnalyticsEvent.createAccountTap)
- Fired at: `EntryPointViewModel.swift:22`
- Props: none

### `EntryPoint Have Account` (from EntryPointAnalyticsEvent.iHaveAccountTap)
- Fired at: `EntryPointViewModel.swift:27`
- Props: none

#### DoubleChargeInfoAnalyticsEvent (`Modules/MyTofu/Sources/Modules/DoubleChargeInfo/DoubleChargeInfoAnalyticsEvent.swift`)

### `DoubleChargeInfo opened` (from DoubleChargeInfoAnalyticsEvent.open)
- Fired at: `DoubleChargeInfoViewModel.swift:55`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `DoubleChargeInfo subscription loaded {invoiceMakerAppStore|tofuAppStore|web}` (from DoubleChargeInfoAnalyticsEvent.subscriptionLoaded(type:))
- Fired at: `DoubleChargeInfoViewModel.swift:86` (`type: conflictType`) — event NAME varies by `SubscriptionConflictType` (3 distinct literal names)
- Props: none (default → nil)
- Note: `conflictType` provenance is `client:VM` derived from subscription source — LIKELY BFF-influenced (subscription/conflict state from server); verify.

### `DoubleChargeInfo tap Apple Subscriptions` (from .tapAppleSubscriptions)
- Fired at: `DoubleChargeInfoViewModel.swift:110`
- Props: none

### `DoubleChargeInfo tap web subscription` (from .tapWebSubscription)
- Fired at: `DoubleChargeInfoViewModel.swift:118`
- Props: none

### `DoubleChargeInfo tap Later` (from .tapLater)
- Fired at: `DoubleChargeInfoViewModel.swift:141`
- Props: none

#### BackendDrivenUIAnalyticsEvent (`Modules/MyTofu/Sources/Modules/BackendDrivenUI/BackendDrivenUIAnalyticsEvent.swift`)

### `BDU opened` (from BackendDrivenUIAnalyticsEvent.open(slug:))
- Fired at: `Modules/MyTofu/Sources/Modules/BackendDrivenUI/BackendDrivenUIViewModel.swift:83`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | slug | client:VM slug (BDU screen slug; identifies BFF-driven screen) |

### `BDU failed load` (from BackendDrivenUIAnalyticsEvent.failedLoad(slug:))
- Fired at: `BackendDrivenUIViewModel.swift:71`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | slug | client:VM slug |

### `BDU closed` (from BackendDrivenUIAnalyticsEvent.closed)
- Fired at: `BackendDrivenUIViewModel.swift:150` and `BackendDrivenUI.swift:53`
- Props: none (empty dict)

### `<dynamic name>` (from BackendDrivenUIAnalyticsEvent.custom(name:value:))
- Fired at: `BackendDrivenUIViewModel.swift:136` — handler for BDU `send_analytics` action
- Props:
  | prop | provenance |
  | value | bff:BDU card payload["value"] (backend-driven UI JSON) |
- CRITICAL: event NAME itself = `payload["name"]` → **bff-sourced** (name string comes from backend-driven UI card JSON, `bff:BDU payload["name"]`). Fully server-defined event.

#### VisitsEditAnalyticsEvent (`Modules/Jobs/Sources/Modules/VisitsEdit/VisitsEditAnalyticsEvent.swift`)

### `Visit edited` (from VisitsEditAnalyticsEvent.visitEdit(withWoker:))
- Fired at: `Modules/Jobs/Sources/Modules/VisitsEdit/VisitsEditViewModel.swift:138` (`withWoker: visit.assignedWorkerId != nil`)
- Props:
  | prop | provenance |
  | withWoker | computed:visit.assignedWorkerId != nil (client model) [sic: key is misspelled "withWoker"] |

### `Visit Created` (from VisitsEditAnalyticsEvent.visitCreated(withWoker:visitCount:))
- Fired at: `VisitsEditViewModel.swift:133`
- Props:
  | prop | provenance |
  | withWoker | computed:visit.assignedWorkerId != nil (client) [misspelled key] |
  | visitCount | client:VM visit count (Int) |
- Note: duplicate event name "Visit Created" also emitted by ScheduleJobFlowAnalyticsEvent with different param set.

#### JobsListByClientAnalyticsEvent (`Modules/Jobs/Sources/Modules/JobsListByClient/JobsListByClientAnalyticsEvent.swift`)

### `Click Create Job` (from JobsListByClientAnalyticsEvent.createJobTapped)
- Fired at: `Modules/Jobs/Sources/Modules/JobsListByClient/JobsListByClientViewModel.swift:236`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `Job created` (from JobsListByClientAnalyticsEvent.jobCreated(clientSource:))
- Fired at: `JobsListByClientViewModel.swift:250` (`clientSource: .existing`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | client_source | enum:JobsCreateClientSource.rawValue (client) |

#### InvoiceDetailAnalyticsEvent (`Modules/Invoices/Sources/Modules/InvoiceDetail/InvoiceDetailAnalyticsEvent.swift`)
NOTE: enum is DEFINED but has NO in-repo fire site (no `analytics.send(InvoiceDetailAnalyticsEvent...)` anywhere in repo). Likely dead/pending wiring, or fired from Tofu.Common.iOS. GAP.

### `Invoice Details Page Shown` (from InvoiceDetailAnalyticsEvent.pageShown(invoiceId:))
- Fired at: NOT FOUND in-repo
- Props:
  | prop | provenance |
  | invoice_id | client:VM invoiceId (invoice master id) |

### `Invoice Created` (from InvoiceDetailAnalyticsEvent.invoiceDuplicated(originalInvoiceId:originalStatus:))
- Fired at: NOT FOUND in-repo
- Props:
  | prop | provenance |
  | context | literal:"duplicate" |
  | original_invoice_id | client:VM (invoice id) |
  | original_invoice_status | computed:InvoiceStatus.analyticsName (not_paid/marked_as_paid/paid) |

### `Onboarding Tooltip Shown` (from InvoiceDetailAnalyticsEvent.tooltipShown)
- Fired at: NOT FOUND in-repo
- Props:
  | prop | provenance |
  | page | literal:"invoice_details" |

#### ClientDetailsAnalyticsEvent (`Modules/Clients/Sources/Modules/ClientDetails/ClientDetailsAnalyticsEvent.swift`)

### `Tap create invoice` (from ClientDetailsAnalyticsEvent.tapCreateInvoice)
- Fired at: `Modules/Clients/Sources/Modules/ClientDetails/ClientDetailsViewModel.swift:168`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `Tap create estimate` (from ClientDetailsAnalyticsEvent.tapCreateEstimate)
- Fired at: `ClientDetailsViewModel.swift:169`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `Click Create Job` (from ClientDetailsAnalyticsEvent.tapCreateJob)
- Fired at: `ClientDetailsViewModel.swift:170`
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |

### `Job created` (from ClientDetailsAnalyticsEvent.jobCreated(clientSource:))
- Fired at: `ClientDetailsViewModel.swift:256` (`clientSource: .existing`)
- Props:
  | prop | provenance |
  | context | client:AnalyticsSender.context (screenContext) |
  | client_source | enum:JobsCreateClientSource.rawValue (client) |

### `Tap client quick action button` (from ClientDetailsAnalyticsEvent.tapClientQuickAction(action:))
- Fired at: `ClientDetailsViewModel.swift:188` (`action: actionType`)
- Props:
  | prop | provenance |
  | action | enum:ClientQuickActionType.analiticsName (client) [sic: "analiticsName"] |

## Old-style events (TrackerService methods; event-name string in Tofu.Common.iOS)

122 `public func` in `TrackerServiceMock.swift` (a few are lifecycle/config, not events: `append`, `initialize`, `activate`, `reconfigure`, `setCustomUser`, `update(teammateCount:)`, `update(invitationCount:)`; plus `isActivated` var). ~130 event-ish methods when overloads are counted. Event NAME string is formatted in Tofu.Common.iOS for ALL of these — GAP. Param provenance below is inferred from signatures (call sites scattered; a couple noted).

| method(params) | param provenance notes | mirror at TrackerServiceMock.swift:line |
| estimateStatusChanged(from:EstimateStatus?, to:EstimateStatus) | enum client (status change) | 27 |
| addItemToEntity(type:ObjectType, isFromCatalog, unitType:UnitType, hasDescription, hasDiscount, isTaxable, isFirstTime) | client:invoice/estimate item VM; enums client | 28 |
| purchaseFailed(productId, context:PaywallContext?, errorCodeName?, errorDescription?, underlineCode?, underlineDescription?, underlineReason?) | client:StoreKit error; productId StoreKit | 29 |
| paymentRequestShown() | — | 30 |
| reviewRequestShown(requestReviewType, reviewPlatform:RedirectDestination?, context:ReviewRequestContext) | client enums | 31 |
| signInFinished(context:SignInContext, method:SignInMethod, masterId, isNewMaster, isEverLinked) | masterId=identity (auth); isNewMaster/isEverLinked from auth/BFF sign-in response | 32 |
| signInError(method:SignInMethod, errorCode?) | client/auth | 33 |
| addClientToEntity(type:ObjectType, isFromCatalog, hasPhone, hasEmail, hasAdress, isFirstTime) | client:client model flags [sic "hasAdress"] | 35 |
| deleteRequest(status:PaymentRequestStatus, context, isFirstTime) | client | 36 |
| createRequest(amount:Decimal, currency, status, description, method:PaymentRequestMethod, isFirstTime) | client:payment request VM; currency client | 37 |
| tapCreatePaymentRequest(context, isFirstTime) | client | 38 |
| didConvertEstimate(isFirstTime, source:EstimateConversionSource) | client | 39 |
| tapConvertEstimate(isFirstTime) | client | 40 |
| editEstimateNumber(isFirstTime) | client | 41 |
| deleteEstimate(isFirstTime) | client | 42 |
| sendEstimate(toApplication, context:PreviewContext, isFirstTime, attachmentsCount) | client; toApplication=OS share target | 43 |
| tapSendEstimate(type:SendInvoiceType, context, isFirstTime) | client | 44 |
| didEditEstimate(itemsCount, itemsCountChange, hasDiscount, hasClient, hasTax, totalAmount:Decimal, currency, isFirstTime) | client:estimate model | 45 |
| tapEditEstimate(isFirstTime) | client | 46 |
| estimateCreated(withItemsCount, hasDiscount, hasClient, hasTax, totalAmount, currency, isFirst, hasLogo, attachmentsCount, context:EstimateCreateContext) | client:estimate model | 47 |
| tapCreateEstimate(isFirstTime, context:EstimateCreateContext) | client | 48 |
| tapToSettings(isFirstTime) | client | 49 |
| showMainScreen(isFirstTime) | client | 50 |
| editInvoiceNumber(isFirstTime) | client | 51 |
| editDueDate(terms:DueDateTerms, isFirstTime) | client | 52 |
| editDate(type:EntityType, isFirstTime) | client | 53 |
| addNotes(type:EntityType, isFirstTime) | client | 54 |
| addItemToEntity(type:EntityType, isFromCatalog, unitType, hasDescription, hasDiscount, isTaxable, isFirstTime) | client (overload, EntityType) | 55 |
| createdCatalogItem(type:AnalyticsCatalogItemType, context:CatalogItemContext, isFirstTime) | client | 56 |
| deleteInvoice(isFirstTime) | client | 57 |
| sendInvoice(toApplication, template:TemplateType, themeType:TemplateColorThemeType, context, isFirstTime, attachmentsCount) | client | 58 |
| tapSendInvoice(type:SendInvoiceType, context, isFirstTime) | client | 59 |
| preview(type:EntityType, context:PreviewContext, isFirstTime) | client | 60 |
| didEditInvoice(itemsCount, itemsCountChange, hasDiscount, hasTax, totalAmount, receivedPaymentsAmount, currency, status:InvoiceStatus, isFirstTime, acceptedPaymentProviders?) | client:invoice model; acceptedPaymentProviders may reflect BFF payment config | 61 |
| tapEditInvoice(isFirstTime) | client | 62 |
| tapCreateInvoice(isFirstTime, context:InvoiceCreateContext) | client | 63 |
| append(trackerService) | LIFECYCLE (not event) | 64 |
| initialize(userId, accountId) | LIFECYCLE — userId=identity, accountId | 65 |
| activate() | LIFECYCLE | 66 |
| reconfigure(accountId) | LIFECYCLE | 67 |
| launch(atFirstTime) | client | 68 |
| appFirstOpened() | client | 69 |
| tapRestore() | client | 70 |
| businessNameRequested() | client | 71 |
| didTapFirstScreen() | client | 72 |
| didAddUserEmail(isSuccess, email) | client; email=PII (user input) | 73 |
| signUp(restored, businessName?, context:SignUpContext) | client:onboarding | 74 |
| requestOnlinePayment(result:RequestOnlineResult) | client | 75 |
| invoiceCreated(withItemsCount, hasDiscount, hasTax, totalAmount, receivedPaymentsAmount, currency, status:InvoiceStatus, isFirst, hasLogo, attachmentsCount, acceptedPaymentProviders:[PaymentProvider]?, context:InvoiceCreateContext) | client:invoice model; acceptedPaymentProviders may reflect BFF payment config | 76 |
| markInvoice(toStatus:InvoiceStatus, markContext:MarkInvoiceContext, paidByProvider:PaymentProvider?) | client | 77 |
| trialExpired() | subscription state — may derive from BFF/StoreKit | 78 |
| tapPushNotification(withPushId pushId, pushType) | bff:push payload (pushId/pushType from server push) | 79 |
| openTab(with tabName) | client | 80 |
| miniBannerShown(feature) | client; feature may be BFF-config driven | 81 |
| tapMiniBanner(feature) | client/BFF-config | 82 |
| closeMiniBanner(feature) | client/BFF-config | 83 |
| didTapInvoiceBanner() | client | 84 |
| subscriptionExpired() | subscription state — BFF/StoreKit | 85 |
| showSubscriptionPaywall(context:PaywallContext, type:PaywallType, stream?) | client; stream may be experiment/BFF | 86 |
| tapSkipSubscriptionPaywall() | client | 87 |
| tapShowAllPlans() | client | 88 |
| tapSubscribe(context:PaywallContext, type:PaywallType, placement:PaywallButtonPlacement?, productId) | client:StoreKit productId | 89 |
| purchase(productId, price:Price?, receipt:Data, context:PaywallContext?) | client:StoreKit | 90 |
| purchaseFailed(productId, context?, errorCodeName?, errorDescription?) | client:StoreKit (overload) | 91 |
| restoreFinished(isSuccess) | client:StoreKit | 92 |
| failedCreateInvoicePdfFile(filePath) | client | 93 |
| deleteCatalogItem(type:AnalyticsCatalogItemType) | client | 94 |
| importContacts(context:ImportContsntContext) | client [sic typo] | 95 |
| editBusinessProfile(businessName?, hasName, hasPhone, hasEmail, hasAdress, hasTaxId, hasBusinessId, context:InvoicesBusinessContext) | client:business model | 96 |
| idfaAccessDialogShown() | client | 97 |
| idfaAccessAnswered(granted) | client:ATT | 98 |
| pushDialogShown() | client | 99 |
| pushAccessAnswered(granted) | client | 100 |
| willMoveToBackground() | client | 101 |
| paywallContentLoaded(productIds:[String]) | client:StoreKit; productIds may be BFF/remote-config paywall | 102 |
| whatsNewShown(feature) | client/BFF-config | 103 |
| tapWhatsNewButton(feature) | client/BFF-config | 104 |
| startedExperiment(withId expId, variantId) | bff/experiment service (expId/variantId from remote experiment config) | 105 |
| appliedForcedVariant(forExperimentId expId, variantId) | experiment config | 106 |
| didChangeLogo(hasLogo, context:InvoicesBusinessContext) | client | 107 |
| didTapBusinessProfileContinue(context:BusinessOnboardingType) | client | 108 |
| paymentsShown(context:PaymentsContext) | client | 109 |
| paymentsChanged(params:[String:Bool]) | client:payment toggles | 110 |
| didTapOnDescription() | client | 111 |
| choosePaymentMethod(context:PaymentRequestsContext, method:PaymentRequestMethod) | client | 112 |
| markRequest(context, toStatus:MarkRequestStatus) | client | 113 |
| sendPaymentLink(application) | client | 114 |
| tapSendRequest(type:SendInvoiceType, context) | client | 115 |
| sendRequest(toApplication app, context) | client | 116 |
| editRequest(provider:PaymentProvider?, paidDate:Date?) | client | 117 |
| stripeComponentShown(type:PaymentComponentType) | client; Stripe/BFF config | 118 |
| didCloseStripeComponent(type:PaymentComponentType) | client | 119 |
| howItWorksShown(context:GuideContext, type, screen) | client | 120 |
| didTapYearBanner() | client | 121 |
| didTapRequestInstantPayout() | client | 122 |
| didTapWithdraw() | client | 123 |
| clientFeeShown(context:ClientFeeContext) | client; fee config may be BFF | 124 |
| clientFeeChanged(isClientFeeEnabled) | client | 125 |
| selectTemplateScreenShown(context:TemplateContext) | client | 126 |
| changeTemplate(context:TemplateContext, template:TemplateType, themeType:TemplateColorThemeType) | client | 127 |
| startWasmFormBackend(context:WasmFromBackContext, errorMessage?) | client/BFF (wasm-from-backend flow) | 128 |
| reviewRequestShown(requestReviewType, reviewPlatform:RedirectDestination, context:ReviewRequestContext) | client (overload) | 129 |
| feedbackButtonTapped(rating:Int, destination) | client:user input | 130 |
| photosUploadingAlertShown(answer:PhotosUploadingAnswer, isInternetConnected) | client | 131 |
| clientDocumentsListShown(type:EntityType) | client | 132 |
| tapClientQuickAction(action:ClientQuickActionType) | client (old-style twin of new ClientDetails event) | 133 |
| didTapExport(exportType:ExportInvoicesType) | client | 134 |
| signInScreenShown(context:SignInContext) | client | 135 |
| signInStarted(method:SignInMethod) | client | 136 |
| signInFinished(method:SignInMethod, masterId, isNewMaster, isEverLinked) | masterId=identity; isNewMaster/isEverLinked from auth/BFF (overload) | 137 |
| signInError(method:SignInMethod) | client (overload) | 138 |
| logout(method:LogoutMethod) | client | 139 |
| deleteAccountPressed() | client | 140 |
| networkError(code, message?, url?) | client:URLSession error | 141 |
| serverError(code, message?, url?, traceId?) | bff:server error response (code/message/traceId from BFF response) | 142 |
| tapCreateJob(context:JobsCreateContext) | client | 143 |
| jobCreated(context:JobsCreateContext, clientSource:JobsCreateClientSource) | client (old-style twin of new Job created event) | 144 |
| visitAdded(visitCount:Int) | client:job/visit model | 145 |
| jobCompleted() | client | 146 |

## User properties

| prop | provenance | set at (file:line) |
| jobs_count | client:JobsRepository.count() | `Modules/Jobs/Sources/Modules/Managers/JobsManagerImpl.swift:81` via `AmplitudePropertySetter.set(userProperties:)` |
| teammate count | client:teammateService.countWorkers() → `TrackerService.update(teammateCount:)` | `Modules/InvoicesModuleUI/Sources/InvoicesModuleUI/Initializers/UserPropsAnalyticsInitializer.swift:25` |
| invitation count | client:invititationService.countPending() → `TrackerService.update(invitationCount:)` | `UserPropsAnalyticsInitializer.swift:24` |
| <arbitrary userProps> | bff:BDU card payload["userProps"] → `TrackerService.setCustomUser(props:)` | `Modules/MyTofu/Sources/Modules/BackendDrivenUI/BackendDrivenUIViewModel.swift:140` |
| Clarity custom user id | client:dataProvider.platformID.publicId | `Invoices/Invoices/Initializers/ClarityInitializer.swift:39,45` |

Note: exact Amplitude user-property KEY names for teammate/invitation counts are formatted inside Tofu.Common.iOS (`update(teammateCount:)` / `update(invitationCount:)` map to keys there) — GAP. Only `jobs_count` and BDU `userProps` keys are literal in-repo.

## GAPS (must verify in Tofu.Common.iOS)

- ALL old-style `TrackerService` event NAME strings (122 methods in mock) — formatted in Tofu.Common.iOS, not visible here.
- The concrete `TrackerService` protocol declaration (only the mock is on disk; real impl + protocol live in Tofu.Common.iOS/InvoicesModuleServices external package).
- The real `AnalyticsSender` wiring: `AnalyticsSender.init(send:)` closure implementation (`_send(name, params)`) that actually forwards to Amplitude — supplied from Tofu.Common.iOS.
- User-property KEY names for `update(teammateCount:)` and `update(invitationCount:)` (Amplitude prop keys formatted in Tofu.Common.iOS).
- Identity/user_id truncation logic for `platformID.publicId` / master id — in Tofu.Common.iOS.
- Global/super properties (account_id, platform, app version, experiment variants, etc.) attached to every event — likely added in Tofu.Common.iOS; none set at the in-repo send sites.
- `InvoiceDetailAnalyticsEvent` (pageShown / invoiceDuplicated / tooltipShown) — DEFINED in-repo but has NO in-repo fire site. Verify whether wired from Tofu.Common.iOS or dead code.
- `SubscriptionConflictType`, `PaywallButtonPlacement`, `JobsCreateClientSource`, `ClientQuickActionType`, `InvoiceStatus` rawValue/analytics-name mappings for old-style events resolved in Tofu.Common.iOS (new-style ones are in-repo).

## Properties sourced from BFF (to trace server-side)

| prop | event(s) | BFF endpoint / response field |
| event NAME + `value` | BDU `custom` (dynamic-name event) | Backend-Driven UI card JSON: `payload["name"]`, `payload["value"]` (BDU screen definition served by BFF) |
| userProps (arbitrary keys/values) | user-property set via BDU `set_user_props` | BDU card JSON `payload["userProps"]` (served by BFF) |
| slug | `BDU opened`, `BDU failed load` | identifies the BFF-served BDU screen (slug drives which server screen loads) |
| code / message / traceId | old-style `serverError(...)` | BFF error response (HTTP error body + `traceId` from server) |
| masterId, isNewMaster, isEverLinked | old-style `signInFinished(...)`, new `Invite send success/failed` context | auth/BFF sign-in response (Tofu.Auth) |
| expId / variantId | old-style `startedExperiment`, `appliedForcedVariant` | remote experiment/feature-config service |
| acceptedPaymentProviders | old-style `invoiceCreated`, `didEditInvoice` | payment config likely from BFF account/payments settings — verify |
| conflictType (subscription source) | new `DoubleChargeInfo subscription loaded {...}` | subscription/conflict state — verify BFF vs StoreKit |
| feature | new `Tap feature`; old `miniBannerShown`/`whatsNewShown` | paywall/feature config may be BFF/remote-config — verify |
| stream | old-style `showSubscriptionPaywall(stream:)` | experiment/remote-config stream — verify |
