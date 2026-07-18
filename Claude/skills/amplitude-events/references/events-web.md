# Web — Amplitude events catalog

- Vendor/SDK: Amplitude via `@amplitude/unified` (`initAll`, `track`, `setUserId`, `identify`/`Identify`). Initialized in `src/external/analytics/amplitude.ts:22` (`initAll(env.AMPLITUDE_KEY, …)`); `appVersion` injected at init when set. Production autocapture: `attribution`, `sessions`, `frustrationInteractions` (network/webVitals/perf off). Dev/staging autocapture off.
- Central send point: `src/external/analytics/amplitude.ts:52-67` — `trackEvent(name: string, payload = {})`; effect wrapper `trackEventFx({ name, payload })` at `:88-90`; page-view hook `usePageShownEvent(payload)` at `:69-81` (fires `Page Shown`, dedupes on JSON payload). Every `trackEvent` ALSO fans out to GTM via `pushDataLayer(buildDataLayerEvent(...))` (`:43-50`, `:58/:65`) — GTM event object is `{ event: name, ...payload }` (a payload key literally named `event` is remapped to `payload_event`).
- Identity (user_id): `setUserId(userPlatformId)` — `userPlatformId` from `/authenticate/auth`, set full/untruncated via `setUserIdToAnalyticsFx` in `src/features/auth/model/platform-auth.ts:224-228`. Effect defined `src/external/analytics/amplitude.ts:92-100`. Also called speculatively from URL `user_id` param in `src/features/auth/ui/form/initial-view/index.tsx:46`.
- Standard params: `trackEvent` injects NO per-event global props of its own. Global context comes only from (a) Amplitude SDK autocapture/session/attribution in production, (b) the `user_id` identity, (c) `appVersion` at init. GTM fan-out adds none beyond remapping `event`.
- Definition style: inline string-literal event names. Two patterns: (1) per-feature `src/features/*/model/analytics.ts` (or `shared/analytics.ts`) modules define effector `createEvent` → `sample(... fn → { name, payload })` → `trackEventFx`; (2) direct `trackEvent('Name', {...})` calls inline in UI components / pages / hooks. The enum `src/shared/lib/events/index.ts` holds only 4 values and is not the source of truth.

## Events (grouped by feature module)

#### Core / Page views (`external/analytics` + pages + business-onboarding)
### `Page Shown`
- Fired at: `src/external/analytics/amplitude.ts:77` (via `usePageShownEvent`), plus direct `trackEvent('Page Shown', …)` sites. Call sites & their `page_name`:
  - `pages/home-page/index.tsx:18` → `home_page`; `pages/estimate/index.tsx:13` → `estimates_details`; `pages/estimates/index.tsx:20,58` → `estimates_list`; `features/onboarding-first-job/model/analytics.ts:12` → `onboarding_success`.
  - `usePageShownEvent` sites: `workers`, `clients_list`, `client_details`, `job_details`, `items_list`, `invoices_list`, `invoice_details`, `invitation_profile_setup`, `schedule`, `jobs_list`, `subscription`, `online_payments`, `business` (settings), `account`, `sign_in_email`, `sign_in_code`, `jobber_import`, `business_name` (onboarding feature), and onboarding-quiz steps (`onboarding_welcome`, `onboarding_industry`, `onboarding_industry_list`, `onboarding_industry_subtype`, `onboarding_team_size`, `business_name`, `onboarding_payments`, `onboarding_pain_point` — from `ONBOARDING_STEPS[*].pageName`, `src/domain/business-profile/config.ts:155-162`).
- Props:
  | prop | provenance |
  |------|------------|
  | `page_name` | `literal:<per-call-site>` (onboarding steps: `client:ONBOARDING_STEPS[*].pageName` constant) |
  | `context` | mixed: `literal:onboarding` / `literal:settings` / `literal:client_details` etc., or `client:router location.state?.context ?? 'none'` (list/detail pages), or `client:workers page context` |

#### paywall (`features/paywall/model/analytics.ts`)
### `Pricing Shown`
- Fired at: `features/paywall/model/analytics.ts:66`
- Props:
  | prop | provenance |
  |------|------------|
  | `feature` | `client:caller arg (PaywallFeature)` |
  | `context` | `client:caller arg (PaywallContext)` |
  | `flow_type` | `client:caller arg (PaywallFlowType)` |
  | `deeplink_source` / `deeplink_plan` / `deeplink_duration` | `client:PaywallDeeplinkIntent (parsed from URL)`, null when absent |

### `free_trial_paywall_shown_from_client_page`
- Fired at: `features/paywall/model/analytics.ts:74` (only when `feature==='jobs' && context==='client_details'`)
- Props: none

### `Waiting For Payment Confirmation`
- Fired at: `features/paywall/model/analytics.ts:84`
- Props: `feature`, `context`, `flow_type` = `client:caller args`; `deeplink_*` = `client:deeplink intent`

### `Click Check Payment Status`
- Fired at: `features/paywall/model/analytics.ts:93`
- Props: `flow_type` = `client:caller arg`

### `Payment Failed Screen Shown`
- Fired at: `features/paywall/model/analytics.ts:99`
- Props: `feature`, `flow_type` = `client:caller args`

### `Payment Error`
- Fired at: `features/paywall/model/analytics.ts:106`
- Props: `feature`, `flow_type` = `client:caller args`; `reason` = `client:optional caller arg` (omitted if absent)

### `Feature Unlocked Screen Shown`
- Fired at: `features/paywall/model/analytics.ts:119`
- Props: `feature`, `context`, `flow_type` = `client:caller args`; `deeplink_*` = `client:deeplink intent`

### `upgrade_clicked`
- Fired at: `features/paywall/model/analytics.ts:129` (only jobs + client_details)
- Props: none

### `Paywall Plan Selected`
- Fired at: `features/paywall/model/analytics.ts:146`
- Props: `plan_id` (`client:solo|team|business`), `interval` (`client:month|year`), `cta` (`client:trial|continue|switch|current|unavailable`), `context` (`client:PaywallContext`), `deeplink_*` (`client:deeplink intent`)

### `Paywall Billing Period Toggled`
- Fired at: `features/paywall/model/analytics.ts:161`
- Props: `from`, `to` = `client:interval args`; `context` = `client:arg`; `deeplink_*` = `client:deeplink intent`

### `Paywall Current Plan Shown`
- Fired at: `features/paywall/model/analytics.ts:174`
- Props: `plan_id`, `context` = `client:args`; `deeplink_*` = `client:deeplink intent`

### `Paywall Unavailable Plan Shown`
- Fired at: `features/paywall/model/analytics.ts:186`
- Props: `plan_id`, `context` = `client:args`; `deeplink_*` = `client:deeplink intent`

### `Paywall Recommended Plan Shown`
- Fired at: `features/paywall/model/analytics.ts:198`
- Props: `plan_id`, `context` = `client:args`; `deeplink_*` = `client:deeplink intent`

### `Paywall Deeplink Opened`
- Fired at: `features/paywall/model/analytics.ts:208`
- Props: `deeplink_source`, `deeplink_plan`, `deeplink_duration` = `client:PaywallDeeplinkIntent (from URL params)`

### `Paywall Deeplink Invalid Params`
- Fired at: `features/paywall/model/analytics.ts:216`
- Props: `errors` (`client:validation errors[]`), `received` (`client:raw URL params record`)

### `Paywall Deeplink Subscription Timeout`
- Fired at: `features/paywall/model/analytics.ts:223`
- Props: `deeplink_source`, `deeplink_plan`, `deeplink_duration` = `client:deeplink intent`

### `Paywall Deeplink Recommendation Skipped`
- Fired at: `features/paywall/model/analytics.ts:236`
- Props: `deeplink_source`, `deeplink_plan` (`client:intent`), `reason` (`client:target_below_current_tier|target_is_current_plan`)

#### create-estimate (`features/create-estimate/model/analytics.ts`)
### `Click Create Estimate`
- Fired at: `features/create-estimate/model/analytics.ts:37` (via effector, after `getEstimateBalance`)
- Props:
  | prop | provenance |
  |------|------------|
  | `context` | `client:caller arg (CreateEstimateContext)` |
  | `is_first_time` | `bff:getEstimateBalance() → balances.length === 0` |

### `Estimate Created` / `Estimate Edited`
- Fired at: `features/create-estimate/model/analytics.ts:82` (name chosen by `action` create→Created / edit→Edited)
- Props:
  | prop | provenance |
  |------|------------|
  | `amount`, `item_count`, `attachment_count`, `is_discount_applied`, `is_tax_applied`, `is_notes_added`, `currency` | `client:editor draft (caller payload)` |
  | `context` | `client:caller arg` |
  | `is_logo_added` | `literal:false` (mocked, `:73`) |
  | `is_first_time` | `bff:getEstimateBalance() → balances.length === 1` |

### `Estimate Details Edited`
- Fired at: `features/create-estimate/model/analytics.ts:100`
- Props: `is_estimate_number_changed` = `client:editor state`

#### create-invoice (`features/create-invoice/model/analytics.ts`)
### `Click Create Invoice`
- Fired at: `features/create-invoice/model/analytics.ts:39`
- Props:
  | prop | provenance |
  |------|------------|
  | `context` | `client:caller arg (CreateInvoiceContext)` |
  | `is_first_time` | `bff:getInvoicesBalance() → paidInvoicesCount + unpaidInvoicesCount === 0` |

### `Create Job First Bypass Loop`
- Fired at: `features/create-invoice/model/analytics.ts:60`
- Props: `context` = `client:caller arg`

### `Continue With Invoice Bypass Loop`
- Fired at: `features/create-invoice/model/analytics.ts:68`
- Props: `context` = `client:caller arg`

### `Invoice Created` / `Invoice Edited`
- Fired at: `features/create-invoice/model/analytics.ts:117`
- Props:
  | prop | provenance |
  |------|------------|
  | `amount`, `item_count`, `attachment_count`, `is_discount_applied`, `is_tax_applied`, `is_notes_added`, `currency`, `received_payment_amount`, `status` | `client:editor draft (caller payload)` |
  | `context` | `client:caller arg` |
  | `is_logo_added` | `bff:$chosenAccount.logoUrl (account response)` |
  | `is_first_time` | `bff:getInvoicesBalance() → paid+unpaid === 1` |

### `Invoice Details Edited`
- Fired at: `features/create-invoice/model/analytics.ts:137`
- Props: `is_invoice_number_changed`, `due_date_option`, `is_due_date_changed` = `client:editor state`

#### stripe-onboarding (`features/stripe-onboarding/model/analytics.ts`)
### `Payments Shown`
- Fired at: `features/stripe-onboarding/model/analytics.ts:16`
- Props: `context` = `client:settings|after_invoice_creation (caller)`

### `Payments Changed`
- Fired at: `features/stripe-onboarding/model/analytics.ts:32`
- Props: `is_accepted?`, `is_stripe_linked?`, `is_stripe_enabled?` = `client:caller payload` (reflects Stripe link/account state)

### `Payment Received`
- Fired at: `features/stripe-onboarding/model/analytics.ts:55`
- Props: `payment_method`, `payment_provider`, `payment_source`, `amount`, `currency` = `client:caller payload`

#### client (`features/client/model/analytics.ts`)
### `Сlient Jobs Section Clicked`  (note: leading char is Cyrillic "С")
- Fired at: `features/client/model/analytics.ts:9`
- Props: none

#### download-app-banner (`features/download-app-banner/model/analytics.ts`)
### `Click Download App`
- Fired at: `features/download-app-banner/model/analytics.ts:4`
- Props: `context` = `client:fsm_ios_banner|inv_maker_ios_banner (caller)`

#### mobile-app-banner (`features/mobile-app-banner/model/analytics.ts`)
### `Download App Banner Shown`
- Fired at: `features/mobile-app-banner/model/analytics.ts:4`
- Props: `banner_type` = `literal:mobile_fsm_ios`

### `Download App Banner Clicked`
- Fired at: `features/mobile-app-banner/model/analytics.ts:8,12`
- Props: `banner_type` = `literal:mobile_fsm_ios`; `action` = `literal:get_app` or `literal:continue_in_browser`

#### today (`features/today/model/analytics.ts`)
### `Visit Update Error`
- Fired at: `features/today/model/analytics.ts:24`
- Props:
  | prop | provenance |
  |------|------------|
  | `context` | `literal:home` |
  | `action` | `client:assign_worker|update_status (caller)` |
  | `reason` | `literal:version_mismatch` |
  | `job_id`, `visit_id` | `client:caller (ids of loaded entity, BFF-origin)` |
  | `submitted_version` | `client:local job version` |
  | `actual_version` | `bff:server current job version (mutation error response)` |
  | `version_delta` | `computed:actualVersion - submittedVersion` (BFF-derived) |

#### job-visits (`features/job-visits/model/analytics.ts`)
### `Visit Photos Saved`
- Fired at: `features/job-visits/model/analytics.ts:22`
- Props: `job_id`, `visit_id` = `client:save params (BFF-loaded ids)`; `photo_count` = `computed:attachments.length`

### `Photo Tag Changed`
- Fired at: `features/job-visits/model/analytics.ts:37`
- Props: `job_id` (`client:$job.id`), `visit_id` (`client:$selectedPhoto.visitId`), `tag` (`client:selected tag ?? null`)

### `Photo Limit Reached`
- Fired at: `features/job-visits/model/analytics.ts:60`
- Props: `job_id` (`client:$job.id`), `visit_id` (`client:$addPhotosVisitId`)

### `Photo Deleted`
- Fired at: `features/job-visits/model/analytics.ts:74`
- Props: `job_id` (`client:$job.id`), `visit_id` (`client:delete params`)

### `Click Add Photos`
- Fired at: `features/job-visits/model/analytics.ts:91`
- Props: `context` (`client:visit_detail|job_photos_modal caller`), `job_id` (`client:$job.id`)

### `Entity Deleted`
- Fired at: `features/job-visits/model/analytics.ts:110` (visit) and `features/schedule/model/analytics.ts:35` (schedule visit)
- Props:
  | prop | provenance |
  |------|------------|
  | `entity` | `literal:visit` |
  | `job_id` | `client:$job.id` (job-visits site only) |
  | `context` | `client:$visitEditContext` (e.g. 'schedule'), or `literal:schedule` (schedule site) — omitted if none |

### `Visit Status Changed`
- Fired at: `features/job-visits/model/analytics.ts:131` and `features/schedule/model/analytics.ts:13`
- Props:
  | prop | provenance |
  |------|------------|
  | `from_status` | `bff:$job.visits[].status (loaded job entity)` (job-visits) / `client:caller` (schedule) |
  | `to_status` | `client:new status (caller)` |
  | `job_id` | `client:$job.id` (job-visits only) |
  | `context` | `client:$visitEditContext` / `literal:schedule` |

#### jobs (`features/jobs/model/analytics.ts`)
### `Click Create Job`
- Fired at: `features/jobs/model/analytics.ts:31` and `:162` (home_jobs_promo_banner); also `features/onboarding-first-job/model/analytics.ts:26,36` (context `onboarding`)
- Props: `context` = `client:CreateJobContext caller` / `literal:home_jobs_promo_banner` / `literal:onboarding`

### `Job Created`
- Fired at: `features/jobs/model/analytics.ts:54`; also `features/onboarding-first-job/model/analytics.ts:69`
- Props:
  | prop | provenance |
  |------|------------|
  | `context` | `client:caller` / `literal:onboarding` |
  | `source` | `client:estimate|manual (caller)` |
  | `estimate_id`, `estimate_status` | `client:caller (BFF-origin when from estimate)` |
  | `job_id` | `client:created job id (BFF create response)` |
  | `with_visit` | `client:caller` (omitted if undefined) |

### `Job Status Changed`
- Fired at: `features/jobs/model/analytics.ts:79`
- Props: `from_status`, `to_status` = `client:caller (entity status, BFF-origin)`

### `Product & Services Added`
- Fired at: `features/jobs/model/analytics.ts:93`
- Props: `context` = `literal:job_details`

### `Visit Created`
- Fired at: `features/jobs/model/analytics.ts:115`; also `features/onboarding-first-job/model/analytics.ts:79`
- Props: `count` (`client:caller` / `literal:1`), `is_worker_assigned` (`client:caller`), `context` (`client:caller` / `literal:onboarding`, omitted if none)

### `Visit Edited`
- Fired at: `features/jobs/model/analytics.ts:133`; also `features/schedule/model/analytics.ts:23` (context `schedule`)
- Props: `is_worker_assigned` (`client:caller`), `context` (`client:caller` / `literal:schedule`, omitted if none)

### `Click Mark Paid`
- Fired at: `features/jobs/model/analytics.ts:149` (`source: job_timeline`); also `features/invoice/ui/invoice-actions/index.tsx:103` (`source: status_timeline`)
- Props: `source` = `literal:job_timeline` / `literal:status_timeline`

#### notes (`features/notes/shared/analytics.ts`)
### `Note Added`
- Fired at: `features/notes/shared/analytics.ts:17`
- Props: `context` (`client:client_details|visit_detail`), `type` (`client:NoteVisibility`)

### `Note Deleted`
- Fired at: `features/notes/shared/analytics.ts:32`
- Props: `context`, `type` = `client:caller`

### `Note Edited`
- Fired at: `features/notes/shared/analytics.ts:48`
- Props: `context`, `type` = `client:caller`

#### onboarding-first-job (`features/onboarding-first-job/model/analytics.ts`)
### `Click Skip First Job`
- Fired at: `features/onboarding-first-job/model/analytics.ts:24`
- Props: `context` = `literal:onboarding`

### `Client Created`
- Fired at: `features/onboarding-first-job/model/analytics.ts:50`
- Props: `context` (`literal:onboarding`), `is_first_time` (`literal:true`), `has_email`/`has_phone`/`has_address` (`computed:Boolean(createClient params.*)`)
- (also emits `Page Shown` onboarding_success `:12`, `Click Create Job` `:26,36`, `Job Created` `:69`, `Visit Created` `:79` — see those events)

#### schedule (`features/schedule/model/analytics.ts`)
- Emits `Visit Status Changed` (`:13`), `Visit Edited` (`:23`), `Entity Deleted` (`:35`) all with `context: literal:schedule` — see those events above.

#### survey (`features/survey/model/analytics.ts`)
### `Survey Widget Shown`
- Fired at: `features/survey/model/analytics.ts:27`
- Props: `page_name` = `computed:pathname → 'home_page' or pathname`

### `Survey Widget Cta Clicked`
- Fired at: `features/survey/model/analytics.ts:33`
- Props: `page_name` = `computed:window.location.pathname`

### `Survey Widget Dismissed`
- Fired at: `features/survey/model/analytics.ts:39`
- Props: `page_name` = `computed:window.location.pathname`

### `Survey Step Viewed`
- Fired at: `features/survey/model/analytics.ts:52`
- Props: `step_number` (`computed:ALL_LINEAR_STEPS index`), `step_name` (`client:SURVEY_STEP_META[step].analyticsName`)

### `Survey Completed`
- Fired at: `features/survey/model/analytics.ts:65`
- Props: none

### `Survey Option Selected`
- Fired at: `features/survey/model/analytics.ts:73`
- Props: `step_number` (`computed`), `step_name` (`client:step meta`), `option_value` (`client:chosen option`)

#### attachments (`features/attachments/model/analytics.ts`)
### `Click Add Attachment`
- Fired at: `features/attachments/model/analytics.ts:5`
- Props: `document_type` (`client:invoice|estimate`), `context` (`client:PaywallContext`)

#### estimate feature (UI components)
### `Click edit` (estimate + invoice)
- Fired at: `features/estimate/ui/estimate-navbar/index.tsx:74,91`; `features/invoice/ui/invoice-navbar/index.tsx:96,113`
- Props: `document_type` = `literal:estimate` / `literal:invoice`

### `Click Delete` (estimate/invoice/job)
- Fired at: estimate `features/estimate/ui/delete-estimate.tsx:18,51,87,95`; invoice `features/invoice/ui/delete-invoice.tsx:40,137,228,236`; job `features/job/ui/delete-job/index.tsx:19,52,88,96`
- Props:
  | prop | provenance |
  |------|------------|
  | `document_type` | `literal:estimate` / `literal:invoice` / `literal:job` |
  | `context` | `literal:estimate_details|invoice_details|job_details` (open) or `literal:confirmation_pop_up` (confirm) |

### `Click Send` (estimate + invoice)
- Fired at: estimate `features/estimate/model-views/use-toolbar-pane-view-model.tsx:132,141`; invoice `features/invoice/ui/send-invoice.tsx:45`, `features/invoice/ui/invoice-actions/index.tsx:188`
- Props: `document_type` (`literal:estimate|invoice`), `button_type` (`literal:primary`)

### `Click Download` (estimate + invoice)
- Fired at: estimate `features/estimate/model-views/use-toolbar-pane-view-model.tsx:153`; invoice `features/invoice/ui/invoice-actions/index.tsx:212`
- Props: `document_type` = `literal:estimate|invoice`

### `Click Print` (estimate + invoice)
- Fired at: estimate `features/estimate/model-views/use-toolbar-pane-view-model.tsx:168`; invoice `features/invoice/ui/invoice-actions/index.tsx:227`
- Props: `document_type` = `literal:estimate|invoice`

### `Estimate Status Changed`
- Fired at: `features/estimate/model/update-status.ts:55`
- Props:
  | prop | provenance |
  |------|------------|
  | `status` | `computed:declined/mark_as_sent/<status.toLowerCase()>` from status+sentMethod |
  | `estimate_id` | `client:estimate.id (BFF-loaded estimate)` |

#### invoice feature (UI components)
### `Invoice Marked As`
- Fired at: `features/invoice/ui/invoice-status.tsx:33`; `features/invoice/ui/delete-invoice.tsx:48,145`
- Props: `to_status` = `computed:isPaid ? 'unpaid' : 'paid'` (invoice-status) / `literal:unpaid` (mark-unpaid menu)

### `Click Add Payment`
- Fired at: `features/invoice/ui/invoice-actions/index.tsx:124` (`source: status_timeline`); `features/invoice/model-views/use-timeline-view-model.tsx:212` (`source: timeline`)
- Props: `source` = `literal:status_timeline` / `literal:timeline`

### `Click Try Again`
- Fired at: `features/invoice/ui/invoice-actions/index.tsx:137`
- Props: `source` = `literal:status_timeline`

### `Click Duplicate`
- Fired at: `features/invoice/ui/invoice-actions/index.tsx:144`; `features/invoice/ui/delete-invoice.tsx:55,152`
- Props: `document_type` (`literal:invoice`), `context` (`literal:status_timeline` or `literal:invoice_details`)

#### invoices feature
### `Invoices Filter Applied`
- Fired at: `features/invoices/ui/filter-tabs.tsx:57`; `features/invoices/model-views/document-filter-view-model.tsx:124`
- Props:
  | prop | provenance |
  |------|------------|
  | `filter` | `computed:valueToAnalyticsParam(value)` / `computed:notPaid→unpaid` (from selected tab, client) |
  | `source` | `computed:matchesInvoices ? 'invoices_list' : 'client_invoices_list'` (route match) |

### `Click Export`
- Fired at: `features/invoices/ui/export-reports-for-client.tsx:41`
- Props: `context` (`literal:client`), `type` (`client:csv|pdf`)

#### estimates feature
### `Estimates Filter Applied`
- Fired at: `features/estimates/model-views/document-filter-view-model.tsx:111`
- Props: `filter` (`client:selected filter value`), `source` (`computed:matchesEstimates ? 'estimates_list' : 'client_estimates_list'`)

### `Approved Estimates Banner Shown`
- Fired at: `features/estimates/ui/estimates-conversion-banner.tsx:39` (fires when `$approvedEstimatesCountForConversion > 0`)
- Props: `context` = `client:trackingContext prop`

### `Approved Estimates Convert Clicked`
- Fired at: `features/estimates/ui/estimates-conversion-banner.tsx:47`
- Props: `context` = `client:trackingContext prop`

#### jobs / worker-jobs (filter view models)
### `Jobs Filter Applied`
- Fired at: `features/jobs/model-views/document-filter-view-model.tsx:84`
- Props: `filter` (`client:selected JobFilterType`), `source` (`literal:jobs_list`)

### `Worker Jobs Filter Applied`
- Fired at: `features/worker-jobs/model-views/document-filter-view-model.ts:48`
- Props: `filter` (`client:WorkerJobFilterType`), `source` (`literal:worker_jobs_list`)

#### items / clients (search)
### `Search Performed`
- Fired at: `features/items/ui/index.tsx:55`; `features/clients/ui/index.tsx:31`
- Props:
  | prop | provenance |
  |------|------------|
  | `context` | `literal:items_list` / `literal:clients_list` |
  | `status` | `computed:results.length > 0 ? 'success' : 'no results'` |
  | `filter` | `computed:recordTypeToAnalyticsFilter(recordType)` (items) / `literal:none` (clients) |

### `Click Import from Jobber`
- Fired at: `features/clients/ui/index.tsx:58`
- Props: `context` = `literal:clients_list`

#### jobber-import
### `Jobber Import Started`
- Fired at: `features/jobber-import/model/import.ts:188`
- Props: `client_count` (`computed:queue length`), `mode` (`client:import mode`), `file_count` (`computed:parseResult.filenames.length`)

### `Jobber Import Completed`
- Fired at: `features/jobber-import/model/import.ts:209`
- Props: `total`, `succeeded`, `failed` (`computed:import loop results`), `duration_ms` (`computed:Date.now()-startedAt`), `mode` (`client`), `fingerprint` (`computed:parseResult.fingerprint`), `outcome` (`computed:cancelled?'cancelled':'finished'`)

### `Jobber Import Click Force Re-import`
- Fired at: `features/jobber-import/ui/preview-step.tsx:123`
- Props: `context` (`literal:jobber_import_preview`), `client_count` (`computed:parseResult.parsed.length`)

### `Jobber Click Cancel`
- Fired at: `features/jobber-import/ui/importing-step.tsx:89`
- Props: `context` (`literal:jobber_import_in_progress`), `sent`/`total` (`client:progress state`)

#### settings / subscription
### `Click Subscription Link`
- Fired at: `features/settings/ui/subscription-content/subscription-manager.tsx:32`
- Props: `subscription_action` = `client:manage_plan|change_payment_method|cancel_subscription`

### `Subscription Cancel Popup Shown`
- Fired at: `features/settings/ui/subscription-content/cancellation-modals.tsx:30,90`
- Props: `type` = `literal:confirmation` / `literal:feedback_reason`

### `Subscription Final Cancel Popup Click`
- Fired at: `features/settings/ui/subscription-content/cancellation-modals.tsx:97`
- Props: `button` = `literal:keep_plan`

#### workers
### `Worker Removed`
- Fired at: `features/workers/model/remove.ts:34`
- Props: none

### `Worker Invite Sent`
- Fired at: `features/workers/model/invite.ts:114`
- Props: `context` = `client:$inviteContext` (omitted if none)

#### auth
### `Error Shown`
- Fired at: `features/auth/ui/master-migration-conflict-modal.tsx:35`
- Props: `error_type` (`literal:account_already_exists`), `context` (`literal:sign_in`)

### `Tap Submit Email`
- Fired at: `features/auth/ui/form/email-view.tsx:40`
- Props: `context` = `literal:sign_in_email_screen`

### `Tap Resend Code`
- Fired at: `features/auth/ui/form/otp-view.tsx:71`
- Props: `context` = `literal:sign_in_code_screen`

### `Sign in screen shown`
- Fired at: `features/auth/ui/form/initial-view/index.tsx:58,62,66`
- Props: `context` = `literal:sign_in_after_purchase` / `client:entrySource (URL entry_source param)` / `literal:direct_link`

### `Tap Sign In Method`
- Fired at: `features/auth/ui/form/initial-view/auth-section.tsx:18,30,70`
- Props: `method` (`literal:google|apple|email`), `context` (`literal:sign_in_screen`)

#### http / errors
### `Server Error Occurred`
- Fired at: `src/shared/lib/http/parsers.ts:50` (skips expected onboarding 403/404)
- Props:
  | prop | provenance |
  |------|------------|
  | `error_message` | `bff:APIError.message (server error response)` |
  | `account_id` | `bff:getAccountId() (cached from /authenticate/auth)` |
  | `error_code` | `bff:APIError.statusCode (HTTP status)` |
  | `url` | `client:res.url (request URL)` |

#### 404 page
### `404 Page Viewed`
- Fired at: `src/pages/404/index.tsx:24`
- Props: `path` (`client:location.pathname`), `referrer` (`client:document.referrer || 'direct'`)

## User properties (identify)
| prop | provenance | set at (file:line) |
|------|------------|--------------------|
| `user_industry` | `client:$selectedIndustry (onboarding quiz answer)` | `features/business-onboarding/model/onboarding.ts:413` (→ `setUserPropertiesFx`, `:419`) |
| `team_size` | `client:$selectedTeamSize` | `features/business-onboarding/model/onboarding.ts:414` |
| `subtype` | `client:$selectedCleaningSubtype ?? $selectedJobMix` | `features/business-onboarding/model/onboarding.ts:415` |
| `payment_methods` | `client:$selectedPaymentMethods.join(',')` | `features/business-onboarding/model/onboarding.ts:416` |
| `primary_pain` | `client:$selectedPainPoint` | `features/business-onboarding/model/onboarding.ts:417` |

- Set via `identify(Identify)` in `src/external/analytics/amplitude.ts:102-120` (`setUserPropertiesFx`), fired on `saveBusinessProfileFx.done`. All values are client-captured quiz answers (not BFF).

## Properties sourced from BFF (to trace server-side)
| prop | event(s) | BFF endpoint / response field |
|------|----------|-------------------------------|
| `is_first_time` | Click Create Estimate; Estimate Created; Estimate Edited | `getEstimateBalance({})` → `balances.length` (estimates balance endpoint) |
| `is_first_time` | Click Create Invoice; Invoice Created; Invoice Edited | `getInvoicesBalance()` → `paidInvoicesCount + unpaidInvoicesCount` (invoices balance endpoint) |
| `is_logo_added` | Invoice Created; Invoice Edited | `$chosenAccount.logoUrl` (account response — logo url presence) |
| `actual_version` | Visit Update Error | server current job version returned in the mutation version-mismatch error |
| `version_delta` | Visit Update Error | computed from `actual_version` (BFF) − submitted (client) |
| `account_id` | Server Error Occurred | `getAccountId()` — cached from `/authenticate/auth` response |
| `error_message` | Server Error Occurred | `APIError.message` from failed BFF response body |
| `error_code` | Server Error Occurred | `APIError.statusCode` — HTTP status of failed BFF call |
| `from_status` | Visit Status Changed (job-visits site) | `$job.visits[].status` — from BFF-loaded job entity |
| `estimate_id` | Estimate Status Changed | `estimate.id` — from BFF-loaded estimate (id echo) |
| `job_id` / `estimate_id` / `visit_id` | Visit Update Error, Visit Photos Saved, Photo *, Click Add Photos, Entity Deleted, Job Created, Visit Created | entity ids originating from BFF-loaded entities / create responses (id echoes; not server metrics) |

Notes:
- Genuinely server-state-derived (counts / versions / account state): `is_first_time` (both), `is_logo_added`, `actual_version`/`version_delta`, `account_id`, `error_message`, `error_code`, `from_status` (job-visits). The remaining flagged entries are entity-id echoes that originate from BFF responses but carry no server-computed metric.
- `amount`/`currency`/`item_count`/`status`/`received_payment_amount` on Invoice/Estimate Created|Edited come from the client editor draft; for edit flows the draft is seeded from a BFF-loaded document but values are the user's edited state, so classified `client`.
