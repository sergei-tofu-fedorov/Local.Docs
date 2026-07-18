---
name: amplitude-events
description: >-
  Complete reference for Amplitude analytics events across the Tofu/Invoices product — every event and
  its properties for each client (web, iOS, Android, Field Service WorkerApp) and the BFF
  (Invoices.Backend), how each property value is filled (literal / client state / from a BFF response /
  computed server-side), how each surface sets the Amplitude user_id, and the owner-vs-worker
  attribution gotcha. ALWAYS use this skill whenever the words "amplitude" or "analytics" appear and
  the task needs information about an event or a property — do not re-derive from source when this
  catalog can answer. Trigger it for questions like "what does prop X on the Y amplitude/analytics
  event mean", "does event Z exist / what props does it have / where is it fired", "where does this
  analytics prop's value come from", "how does the BFF compute this analytics field", "add or change
  an amplitude/analytics event", "why is a worker's event attributed to the owner", or "reconcile
  Amplitude data with backend records" — across web, iOS, Android, the Field Service WorkerApp, and
  the Invoices.Backend BFF. The bundled catalogs already map every event, its props, provenance, and
  file:line, so prefer them over grepping the repos.
---

# Amplitude events across Tofu/Invoices

The product's single product-analytics vendor is **Amplitude**. Events originate from four clients and
from the BFF itself. This skill is a **reference catalog**: it answers what events exist, what
properties they carry, **where each property value comes from**, how identity is set, and how the
pieces reconcile. Detailed per-surface catalogs live in `references/` — read the relevant one instead
of re-scanning source.

## How to use this skill

Route by the question, then open the matching reference file (they carry the exhaustive event lists
with `file:line`, so you rarely need to grep the repos yourself):

| The question is about… | Read |
|---|---|
| A specific **web** event / prop | `references/events-web.md` |
| A specific **iOS** event / prop (IM or FS) | `references/events-ios.md` |
| A specific **Android** event / prop | `references/events-android.md` |
| A specific **Worker app** event / prop | `references/events-worker.md` |
| A **server-emitted (BFF)** event and how its props are computed | `references/events-bff.md` |
| A client prop that is **filled from a BFF response** — how the backend computes it | `references/bff-computed-props.md` |
| **user_id / attribution / owner-vs-worker** | `references/identity.md` |

If a cited symbol has moved, the catalogs still name the class/function — grep that name rather than
re-discovering the whole flow.

## The event landscape

| Surface | Repo | Events | Central send point | Event names defined in |
|---|---|---|---|---|
| **Web** | `Tofu.Web.Frontend` | ~97 (across ~180 call sites, 15 `analytics.ts` modules) | `trackEvent(name, payload)` / `trackEventFx` — `src/external/analytics/amplitude.ts` | inline string literals in per-feature `model/analytics.ts` |
| **iOS** (IM + FS) | `Invoices.Apps.iOS` | 38 new-style + 122 old-style methods | new: `AnalyticsSender.send(_:)`; old: `TrackerService` methods | new: `*AnalyticsEvent.swift` enums (in-repo); **old: names in `Tofu.Common.iOS`** |
| **Android** | `Invoices.Apps.Android` | 63 defined (51 fired, 12 dead) | `GeneratedAnalytics.report(...)` → `CompositeReporter` | **`common/analytics/events/*.md` → build-time code-gen** |
| **Worker app** | `Tofu.FieldService.WorkerApp` | 17 | `AnalyticsReporter.report(title, params)` via `AnalyticsManager.reportEvent` | typed `onXxx(...)` methods on `AnalyticsManager` |
| **BFF** | `Invoices.Backend` | 17 `Event` subclasses | `WithContext(Context)` + `Log(Event)` → `AnalyticsService.Send` | `Event.Type` on each class in `Src/Invoices.Common/Analytics/Events/` |

Two definition styles are worth knowing before adding an event:

- **Android is contract-first.** Add/change an event by editing `common/analytics/events/*.md`
  (Markdown `####` heading + a property table); the build generates the `ReporterWrapper.<event>(...)`
  function. Don't hand-write the Kotlin call surface — regenerate from the Markdown.
- **iOS has two eras.** New per-screen `*AnalyticsEvent.swift` enums are in-repo and self-describing.
  The ~122 older `TrackerService` methods only expose their *signatures* in-repo — the actual
  **event-name strings and global super-properties are formatted inside `Tofu.Common.iOS`** (an
  external SPM package, not vendored). Treat those names as a known gap.

## Property provenance — the shared vocabulary

Every property in the catalogs is tagged with where its value comes from. This is the key to
"where does this prop's value come from" questions:

- `literal:<value>` — a constant or enum baked into the call site.
- `client:<source>` — read from local app state / view model / store / synced local DB.
- `computed:<how>` — derived locally (a count, a boolean check, screen tracking).
- `bff:<endpoint→field>` — **the value originates from a backend response.** These are the props that
  can silently break when the BFF changes. See `references/bff-computed-props.md` for how the backend
  produces them.
- `user-prop` — set via Amplitude user properties / `identify` (not per-event).
- `standard` — an auto-injected common param added to *every* event on that surface (e.g. WorkerApp's
  `reportEvent` block; Android's `is_first_time` + `account_id`; the BFF's `environment`).

## Properties filled from a BFF response (cross-surface)

These are the client props whose values come from the backend — the ones to check when analytics data
looks wrong after a backend change. Full computation chains: `references/bff-computed-props.md`.

| Prop (client) | Surface | BFF source |
|---|---|---|
| `user_id` identity | web / worker | `/authenticate/auth` → `userPlatformId` / `masterUserId` |
| `account_id` | worker | `/api/worker/businesses` → `businesses[0].accountId` |
| `business_industry` | worker (every event) | `/api/Account/business-profile` → `industry` |
| `is_first_time` | web (invoice/estimate) | `getInvoicesBalance` / `getEstimateBalance` counts |
| `is_logo_added` | web | account response `logoUrl` |
| `actual_version`, `version_delta` | web | version-mismatch mutation error |
| `error_code`, `error_message` | web / android / iOS | failed BFF response body / status |
| `masterId`, `isNewMaster`, `isEverLinked` | iOS / worker sign-in | Tofu.Auth `/authenticate/auth` response |
| `acceptedPaymentProviders` | iOS invoice events | BFF payments/account config *(verify)* |
| BDU `custom` event **name** + `value`, `set_user_props`, `slug` | iOS | Backend-Driven-UI JSON (server defines the event itself) |

Not the Tofu BFF (worth distinguishing): `variant_id` / `expId` come from **Firebase Remote Config /
remote experiment config**, and mobile billing props (`response_code`, `order_id`, …) come from the
**Google Play / StoreKit** SDKs, not the backend.

## Identity & the owner-vs-worker gotcha (summary)

Full detail in `references/identity.md`. The essentials:

- Clients set `user_id` themselves; the **BFF reconstructs** `user_id` for server-emitted events from
  `(accountId, productKey)` alone, resolving the account **owner** (`FindOwnerForAccountId`).
- A **worker shares the owner's `accountId`**, so BFF-emitted worker events
  (`VisitAssignedPushSent`, `VisitChangedPushSent`, product `tofu-fieldservice-worker`) are attributed
  to the **owner**. The WorkerApp client itself is correct (it sends the worker's own `masterUserId`).
- Fixing worker attribution is **server-side**: carry the acting `MasterUserId` in `Context` and
  resolve the worker's link instead of the owner. The model already exposes
  `MasterUser.IsWorkerIn(accountId)` / `MemberAccount.WorkerRole`.

## Known gaps

- **`Tofu.Common.iOS` is not on disk.** iOS old-style event-name strings, global super-properties, the
  real `TrackerService`/Amplitude `setUserId` implementation, and the `publicId` truncation all live
  there. `references/events-ios.md` marks these as GAPS. To close them, that SPM package must be
  cloned and cataloged.
- A few iOS props (`acceptedPaymentProviders`, `conflictType`, paywall `feature`/`plan`) are flagged
  *verify* — provenance suspected BFF/remote-config but not confirmed in-repo.

## Repos & branches

| Surface | Path | Branch cataloged |
|---|---|---|
| BFF | `C:\Git\Work\Backend\Invoices.Backend` | `feature/FS-1305`+ |
| Web | `C:\Git\Work\Tofu.Web.Frontend` | `feature/FS-1109` |
| iOS | `C:\Git\Work\Invoices.Apps.iOS` | `develop` |
| Android | `C:\Git\Work\Invoices.Apps.Android` | `main` |
| Worker app | `C:\Git\Work\Tofu.FieldService.WorkerApp` | `main` |
| iOS analytics impl (external) | `Tofu.Common.iOS` (SPM) | not on disk |

`file:line` references were accurate as of these branches — verify a cited symbol still exists before
relying on it, and when you add or move an event, update the matching `references/events-*.md` so this
catalog stays the source of truth.
