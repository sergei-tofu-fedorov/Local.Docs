# WEB-1617 — Web Spike: demo access in web/mobile applications

Research to inform how Tofu provides "demo / try-without-signup" access to the app across web and mobile. The feature touches identity (how a demo user authenticates without committing to signup), data (how demo data is isolated and cleaned up), and conversion (how a demo user becomes a real account). This spike surveys industry demo-access patterns, the Firebase Anonymous Auth mechanism (Tofu.Auth already runs on Firebase and already models anonymous / de-anonymized users), and multi-tenant data-isolation options — and connects each to a concrete design decision for `/plan write`.

## Questions

1. What are the dominant patterns for "demo / try-without-signup" access in SaaS web+mobile apps, and their trade-offs (shared read-only demo account vs per-session ephemeral account vs sandbox tenant vs anonymous auth + seeded data)?
2. How is demo authentication implemented without forcing signup — specifically Firebase Anonymous Auth: capabilities, token claims, limits/abuse, and the account-linking upgrade path to a permanent account?
3. How is demo data isolated and cleaned up (TTL, ephemeral/sandbox tenants, reset cadence) so it does not pollute production data?

## Sources

**Firebase (authentication mechanism):**
- [Authenticate with Firebase Anonymously on Apple Platforms](https://firebase.google.com/docs/auth/ios/anonymous-auth) — anonymous sign-in flow, IP-based sign-up limits, `linkWithCredential`, 30-day automatic cleanup.
- [Best Practices for Anonymous Authentication (Firebase blog, 2023)](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication) — when to use, abuse via REST API, App Check mitigation, conversion preserving UID, unrecoverability caveat.
- [Link Multiple Auth Providers to an Account (Web)](https://firebase.google.com/docs/auth/web/account-linking) — linking flow and the "credential already in use" merge case.
- [Control Access with Custom Claims and Security Rules](https://firebase.google.com/docs/auth/admin/custom-claims) — `firebase.sign_in_provider == 'anonymous'` claim for distinguishing anonymous users.

**Demo-access / PLG patterns:**
- [SaaS Demo complete guide (Reprise)](https://www.reprise.com/resources/blog/saas-demo-complete-guide) — sandbox/demo experience framing.
- [Demo Sandbox for SaaS (SmartCue)](https://www.getsmartcue.com/blog/demo-sandbox) — "try-before-you-buy" sandbox in a safe environment without affecting production data.
- [HowdyGo Sandbox](https://www.howdygo.com/product/sandbox) — direct-link access with no account required.
- [Your Guide to Reverse Trials (Growth Unhinged)](https://www.growthunhinged.com/p/your-guide-to-reverse-trials) and [Reverse Trial (Elena Verna / Amplitude)](https://amplitude.com/blog/reverse-trial) — reverse-trial conversion model.

**Multi-tenant data isolation:**
- [Multi-Tenant Security Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) — isolation-model comparison and row-level-security enforcement caveat.

## Findings

### Q1 — Demo-access patterns and trade-offs

The market splits demo access into two intents that are easy to conflate: **sales demos** (an SE drives a curated environment) and **end-user self-serve demos** (a prospect clicks "Try it" and lands in a working app). WEB-1617 is the latter. The recurring property across self-serve demo tooling is *"a safe, controlled environment … explore your product … without affecting production data"* ([SmartCue](https://www.getsmartcue.com/blog/demo-sandbox)), and the lowest-friction entry is a *direct link with no account required* ([HowdyGo](https://www.howdygo.com/product/sandbox)).

A related PLG framing is the **reverse trial**: give full access first, then drop to a free/paywalled tier. It is motivated by loss-aversion — *"The reverse trial is effective because it creates a sense of loss"* ([Growth Unhinged](https://www.growthunhinged.com/p/your-guide-to-reverse-trials)) — and is reported to lift freemium→premium conversion meaningfully. This matters because the demo's *exit* (what happens when the demo ends / the user wants to keep their data) is as much a design decision as its entry.

Mapping these to concrete identity/data architectures Tofu could build:

| Pattern | Identity | Data isolation | Cleanup | Conversion friction | Abuse risk | Source |
|---|---|---|---|---|---|---|
| **Shared read-only demo account** | One canned account everyone views | None — all share one dataset; must be read-only or data is trampled | None (static seed) | High — user can't keep anything they did | Low | [SmartCue](https://www.getsmartcue.com/blog/demo-sandbox) |
| **Per-session ephemeral account (anonymous auth + seeded data)** | Anonymous Firebase user, fresh UID per device | Own tenant/dataset per demo user | TTL (e.g. 30 days) | Low — link credential, keep UID + data | Medium (token issuable via REST) | [Firebase blog](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication) |
| **Sandbox tenant (pre-provisioned, reset on cadence)** | Real but shared sandbox login | Separate sandbox tenant, periodic reset | Scheduled reset | High — sandbox data is wiped | Low–Medium | [HowdyGo](https://www.howdygo.com/product/sandbox) |
| **Reverse trial (full real account, time-boxed)** | Real account from day one | Real tenant | None — converts to free tier | Lowest — it's already their account | Low (requires signup) | [Growth Unhinged](https://www.growthunhinged.com/p/your-guide-to-reverse-trials) |

The **per-session ephemeral account via anonymous auth** is the only pattern that combines no-signup entry *and* zero-friction conversion that carries data forward — and it is the one Tofu is already architecturally positioned for (Firebase + existing anonymous/de-anonymized user model in Tofu.Auth).

### Q2 — Firebase Anonymous Auth: capabilities, claims, limits, conversion

**Entry is one call.** *"call `getAuth().signInAnonymously()`. This will create a new Firebase user for the person currently using the app"* ([Firebase blog](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication)); the result carries the UID and *"an `isAnonymous` property set to true"* ([iOS docs](https://firebase.google.com/docs/auth/ios/anonymous-auth)). Works identically on web and mobile — same mechanism, satisfying the cross-platform requirement.

**The token has no verified email.** An anonymous ID token carries `firebase.sign_in_provider: "anonymous"` and no email/`email_verified` claim — Firebase's own guidance is to branch on exactly this claim: *"check if `request.auth.token.firebase.sign_in_provider != 'anonymous'`"* ([custom claims / security rules](https://firebase.google.com/docs/auth/admin/custom-claims)). **This is the single most load-bearing finding for Tofu** (see Implications): Tofu.Auth's `AddFirebaseJwt` enforces email verification, which an anonymous token cannot satisfy.

**Conversion preserves identity and data.** *"obtain authentication credentials from the desired provider, then call `linkWithCredential` … If the call … succeeds, the user's new account can access the anonymous account's Firebase data"* ([iOS docs](https://firebase.google.com/docs/auth/ios/anonymous-auth)); and *"The UID will remain the same, which means that all data the user has already created with your app is still accessible to them"* ([Firebase blog](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication)). Because the UID is stable, demo data does not need migration on conversion — it's already keyed to the user that persists.

**Conversion can collide.** *"Account linking will fail if the credentials are already linked to another user account"* — i.e. a returning user whose email already exists. The docs then require a manual merge of the two accounts' data ([Web account-linking](https://firebase.google.com/docs/auth/web/account-linking)).

**Abuse and limits are real and must be planned for.** *"Anonymous user tokens can be issued through the Firebase REST API. A malicious actor can generate an anonymous user token, and then use it to access resources"*; the recommended mitigation is *"implement AppCheck for attestation … ensures that only requests from your genuine applications are able to access your secure resources"* ([Firebase blog](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication)). There is also an inherent throttle: *"Firebase limits the number of new email/password and anonymous sign-ups that your application can have from the same IP address in a short period of time"* ([iOS docs](https://firebase.google.com/docs/auth/ios/anonymous-auth)).

**Lifecycle caveats.** Anonymous accounts are fragile by design: *"anonymous accounts are unrecoverable if the user ever gets signed out"* and don't span devices ([Firebase blog](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication)). A signed-out demo user gets a *new* demo, not their old one — acceptable for a demo, but it frames the conversion CTA as "save your work before you lose it."

### Q3 — Demo data isolation and cleanup

**Automatic cleanup exists but is gated.** *"anonymous accounts older than 30 days will be automatically deleted"* and *"won't count toward usage limits or billing quotas"*, but only after *"upgrading your project to Firebase Authentication with Identity Platform"* — and *"linked accounts are exempt from deletion"* ([iOS docs](https://firebase.google.com/docs/auth/ios/anonymous-auth), [Firebase blog](https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication)). Note this cleans up the *Firebase identity*, **not** the demo's domain data (tenant, invoices, estimates) in Tofu's own datastores — that GC is Tofu's responsibility and must be built separately, keyed on the same TTL.

**Isolation-model menu** (OWASP). The cheat sheet ranks isolation as separate-database > separate-schema > shared-tables/row-level, trading isolation against cost/manageability:

| Strategy | Isolation | Use case | Source |
|---|---|---|---|
| Separate databases | Highest | "Regulated industries, enterprise clients" | [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) |
| Separate schemas | High | "Balance of isolation and manageability" | [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) |
| Shared tables (row-level) | Medium | "Cost-sensitive, high tenant count" | [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) |

The cheat sheet *does not* formalize demo/sandbox-tenant isolation, but the row-level caveat transfers directly: with shared tables you must *"Force RLS for table owners too (important!)"* or isolation can be bypassed. Tofu's existing `Tenant` / `UserTenantRole` model already gives a tenant-scoped boundary; a demo can be a normal tenant flagged `IsDemo`, isolated by the same scoping the app already enforces — no new isolation primitive required, provided every demo query is tenant-scoped (which it already must be).

**Caveat on demo-tooling sources:** the SaaS-demo blog sources (Reprise, SmartCue, HowdyGo) are vendor/marketing pages for *sales-demo* tooling, not engineering references. They are cited only for the conceptual pattern taxonomy (entry friction, "no account", "no production impact"), not for implementation detail.

## Implications for the design

- **Recommended shape: per-session ephemeral demo = anonymous Firebase user + a demo `Tenant` seeded with sample data, TTL-cleaned.** It uniquely delivers no-signup entry *and* data-preserving conversion, and reuses primitives Tofu already has (Firebase, anonymous user model, Tenant/Role). *(Anchor: identity-model decision — reuse Tofu.Auth anonymous user + Tenant, do not invent a separate demo-account concept.)*
- **`AddFirebaseJwt`'s email-verification enforcement must be relaxed for anonymous tokens.** Anonymous tokens carry `sign_in_provider: "anonymous"` and no verified email, so they will be rejected by the current scheme. The auth scheme needs a branch: accept anonymous tokens (gate on the `sign_in_provider` claim) while still enforcing `email_verified` for all non-anonymous providers. *(Anchor: auth-scheme change — this is the critical path; flag as a breaking-behaviour change in the auth pipeline.)*
- **Demo user provisioning runs through the existing `UserRegistrationService` / de-anonymization path.** Conversion = Firebase `linkWithCredential`; the UID is stable so Tofu's user + tenant + demo data require no migration on upgrade. But Tofu.Auth currently treats de-anonymization as one-way ("anonymous cannot be reverted") — confirm that's compatible, and design the role assignment for demo users (likely Admin within their own demo tenant via the existing auto-provision path). *(Anchor: conversion flow + role provisioning.)*
- **Demo data isolation = a normal tenant flagged as demo, isolated by existing tenant-scoping; do not build a new isolation tier.** Seed sample invoices/estimates in `Tofu.Invoices` per demo tenant. Every demo read/write must be tenant-scoped (already the norm), so the OWASP "force isolation even for owners" caveat is satisfied by existing query patterns. *(Anchor: data-store / seeding decision — `IsDemo` flag on Tenant + per-tenant seed.)*
- **Two cleanup jobs, not one.** Firebase's 30-day auto-delete (requires Identity Platform upgrade) GCs the *identity*; a Tofu-side scheduled job must GC the *domain data* (demo tenant + its invoices/estimates) on the same TTL. Linked (converted) demos must be exempt from both. *(Anchor: lifecycle / worker job + a prerequisite ops task to enable Identity Platform.)*
- **Abuse controls are required, not optional.** Anonymous tokens are mintable via the Firebase REST API; plan App Check attestation and rely on the per-IP anonymous-signup throttle. Consider a per-IP / per-device cap on demo-tenant creation on Tofu's side too, since demo tenants + seed data are heavier than a bare Firebase identity. *(Anchor: abuse/rate-limit decision — App Check + server-side demo-creation throttle.)*
- **Design the conversion CTA around loss-aversion and the unrecoverability caveat.** A signed-out anonymous user loses their demo; surface "create an account to keep your work" before that can happen. The reverse-trial framing (full access now, convert to keep) fits Tofu's model. *(Anchor: product/UX contract the BFF must support — conversion endpoint + "demo expiring" signal.)*

## Open questions / follow-ups

- [ ] **Identity Platform upgrade** — is the Firebase project already on Firebase Authentication *with Identity Platform*? Auto-cleanup of anonymous accounts depends on it. (Ops/lead input.)
- [ ] **App Check status** — is App Check already deployed for iOS/web? If not, it's a prerequisite, not part of this feature. (Ops/mobile input.)
- [ ] **Demo scope** — is a demo a full real-feature sandbox (create/edit invoices) or a read-only tour? Determines whether demo tenants need write isolation + per-tenant seed, or a single shared read-only dataset. (Product decision.)
- [ ] **Conversion data carry-over** — when a demo user signs up, do they keep the demo invoices/estimates they created, or start clean? Firebase makes carry-over free (stable UID); product must decide if it's desirable. (Product decision.)
- [ ] **De-anonymization one-way constraint** — confirm Tofu.Auth's "anonymous cannot be reverted" rule doesn't block re-running a demo after conversion, and how a converted user who signs out is handled. (Tofu.Auth domain review — local, may not need web research.)
- [ ] **Web demo entry without Firebase Anonymous on web** — confirm the web client can/does use Firebase Anonymous Auth (mobile clearly can). If web uses a different session model, the demo entry-point may differ per platform. (Web team / `Tofu.AI.Agent.Context` review.)

---

# WEB-1617 — Web Spike: subscription / entitlement gating for demo access

A demo user authenticates anonymously (Section 1) but has **no Stripe subscription**, so Tofu's existing subscription gate denies every paid action. This section grounds the problem in the current `Invoices.Backend` entitlement code, then surveys how SaaS products grant feature access during a trial/demo *without* a billing record, to decide where Tofu's demo entitlement should be injected.

## Questions

4. How does Tofu's BFF gate features on subscription today, and what is the minimal change that admits a demo user? *(code-grounded — not web research)*
5. How do SaaS products grant feature entitlement during a trial/demo without a real paid subscription, and where should that decision live (billing layer vs entitlement layer)?
6. Stripe-native trial mechanics (a `trialing` subscription without a payment method) vs an app-side synthetic entitlement — which fits an anonymous demo user?

## Sources

**Stripe (billing-native trial):**
- [Use free trial periods on subscriptions](https://docs.stripe.com/billing/subscriptions/trials/free-trials) — trial without payment method; `trialing`→`active`; end-of-trial cancel/pause.
- [How subscriptions work](https://docs.stripe.com/billing/subscriptions/overview) — Stripe Entitlements: an active subscription creates an active entitlement per product feature.

**Entitlement-vs-billing decoupling:**
- [Entitlements untangled (Stigg)](https://www.stigg.io/blog-posts/entitlements-untangled-the-modern-way-to-software-monetization) — billing = "has the customer paid"; entitlements = "provisioning and access control".
- [Why billing and entitlement should be decoupled (gater)](https://usegater.com/blog/why-saas-billing-and-entitlement-should-be-decoupled) — granting access for trials/demos without touching the billing record.
- [Two aspects of SaaS entitlement management (Kill Bill)](https://blog.killbill.io/blog/two-aspects-of-saas-entitlement-management-access-and-billing/) — access vs billing as separate concerns.

**Layered gating (flag → entitlement → role):**
- [Feature flags and entitlements (Salable)](https://salable.app/blog/insights/entitlements-future-feature-management) — typical check order: feature flag → entitlement → role-based permission.
- [Feature gating (Stigg)](https://www.stigg.io/blog-posts/feature-gating) and [How to gate end-user access (Stigg, dev.to)](https://dev.to/getstigg/how-to-gate-end-user-access-to-features-shortcomings-of-plan-identifiers-authorization-feature-flags-38dh) — entitlement = "would this change if the user upgraded their subscription?".
- [Using entitlements to manage customer experience (LaunchDarkly)](https://docs.launchdarkly.com/guides/flags/entitlements) — use server-side evaluation for subscription-tier gating.

## Findings

### Q4 — How Tofu gates on subscription today (current code)

Entitlement lives in `Tofu.Permissions.Shared` and is **already decoupled from Stripe billing** — exactly the architecture the industry recommends (Q5). The decision point is `AccessEvaluator.Evaluate` (`Tofu.Permissions.Shared/Domain/AccessEvaluator.cs:24-30`):

```csharp
if (!access.IsActive)                               // access = AccountAccess value object
    return AccessResult.DeniedBySubscription(policy.Key, access.PlanTier);
if (!policy.AllowsPlan(access.PlanTier))
    return AccessResult.DeniedByPlan(policy.Key, currentPlan: access.PlanTier, ...);
```

`AccountAccess` (`AccountAccess.cs:6-13`) is a product-scoped value object `(ProductKey, PlanTier, SubscriptionState, Features, Limits)` with `IsActive => State == SubscriptionState.Active`. An account with no subscription resolves to `AccountAccess.InactiveFor(productKey)` → `State = Inactive`, `PlanTier = Unknown`, empty `Features`/`Limits` (`AccountAccess.cs:32-37`).

**Consequence for demo:** an anonymous demo user has no Stripe subscription → `InactiveFor` → `IsActive == false` → **every gated action returns `DeniedBySubscription`**. Anonymous auth fixes *entry* but not *entitlement*; without a demo entitlement the demo hits a paywall on the first gated action. Quota enforcement (`IQuotaValidator`) runs *after* this evaluator returns `Allowed` (`AccessEvaluator.cs:5-6`), so demo limits are a second, independent lever.

`PlanTier` (`PlanTier.cs`) is an ordered enum `Starter(1) … FsmBusiness(7)`; `SubscriptionState` (`SubscriptionState.cs`) is `Unknown/Inactive/Active`. A demo entitlement must therefore present `State = Active` plus a concrete `PlanTier`.

### Q5 — Granting entitlement during a trial/demo without a billing record

The industry consensus is to decouple the *access* decision from the *payment* decision:

> "while billing software is focused on the commercial aspect, entitlements are all about provisioning and access control."
> — [Stigg, Entitlements untangled](https://www.stigg.io/blog-posts/entitlements-untangled-the-modern-way-to-software-monetization)

> "By separating entitlements from billing, you can decouple pricing from access control. With this separation, you can give users access to features independently of their billing status."
> — [Stigg](https://www.stigg.io/blog-posts/entitlements-untangled-the-modern-way-to-software-monetization)

This is precisely what lets you grant trial/demo access "without touching their billing record or plan definition" ([gater](https://usegater.com/blog/why-saas-billing-and-entitlement-should-be-decoupled)). Tofu **already has** this separation: `AccountAccess` is the resolved entitlement, independent of how Stripe state was read. So a demo entitlement can be injected at the entitlement-resolution layer with no Stripe object at all.

Gating is also layered. The recommended order is flag → entitlement → role ([Salable](https://salable.app/blog/insights/entitlements-future-feature-management)), and tier gating must be **server-side** ([LaunchDarkly](https://docs.launchdarkly.com/guides/flags/entitlements)). Tofu's `AccessEvaluator` already enforces *both* role (`roles.Any(policy.AllowsRole)`) and plan (`AllowsPlan`), server-side — so a demo user must satisfy **both**: a role (existing auto-provision Admin within the demo tenant) **and** an active entitlement (the synthetic `AccountAccess`).

### Q6 — Stripe-native trial vs app-side synthetic entitlement

Stripe supports trials with no payment method: *"You can sign customers up for a free trial of a subscription without collecting their payment details"* and the subscription sits in `trialing` until it *"moves to active when the trial period is over"* ([Stripe](https://docs.stripe.com/billing/subscriptions/trials/free-trials)); an active/trialing subscription also creates an active Stripe Entitlement per product feature ([overview](https://docs.stripe.com/billing/subscriptions/overview)). But every Stripe trial creates a **Customer + Subscription billing record** — undesirable for a throwaway anonymous demo.

| Option | Billing record created? | Fit for anonymous demo | Notes | Source |
|---|---|---|---|---|
| **App-side synthetic `AccountAccess`** for `IsDemo` tenant (Active + chosen PlanTier + small Limits) | None | **Best** — no Stripe object, trivial GC | Inject at the `AccountAccess` resolution seam; reuses existing gate untouched | current code + [Stigg](https://www.stigg.io/blog-posts/entitlements-untangled-the-modern-way-to-software-monetization) |
| **Stripe `trialing` subscription** (no payment method) | Customer + Subscription per demo user | Poor for anonymous; **good** for reverse-trial on a *real* signup | Pollutes billing with throwaway records; cancel/pause at trial end | [Stripe](https://docs.stripe.com/billing/subscriptions/trials/free-trials) |
| **Stripe Entitlements override** | Customer record | Poor for anonymous | Still ties demo to a billing identity | [overview](https://docs.stripe.com/billing/subscriptions/overview) |

The app-side synthetic entitlement wins for an anonymous demo: it needs no Stripe identity, leaves the `AccessEvaluator` gate unchanged, and is removed simply by dropping the demo tenant. Stripe `trialing` is the right tool only if "demo" actually means a **reverse-trial on a real, signed-up account** (a different product — see open questions).

## Implications for the design

- **Inject a synthetic demo entitlement at the `AccountAccess` resolution layer; do not create a Stripe object for anonymous demos.** When the tenant is `IsDemo`, return `AccountAccess` with `State = Active`, a product-chosen `PlanTier`, a curated `Features` set, and **small `Limits`** — bypassing Stripe entirely. The `AccessEvaluator` gate stays untouched. *(Anchor: entitlement-resolution change — the seam is `SubscriptionService` / `AccessRegistry` / `AccessCacheManager`; confirm the exact injection point during `/plan write`.)*
- **Tofu's existing entitlement/billing decoupling is the enabling property — lean on it.** `AccountAccess` is already independent of how Stripe state was read, so a demo entitlement is additive, not a billing change. *(Anchor: confirms no Stripe schema/contract work for the anonymous-demo path.)*
- **Demo must clear both gates: role and plan.** A demo user needs the auto-provisioned Admin role *in its demo tenant* (Section 1) **and** the synthetic active entitlement; missing either still yields `DeniedByRole` / `DeniedBySubscription`. *(Anchor: provisioning must set role AND entitlement together.)*
- **Demo `Limits` are the primary anti-abuse lever.** `IQuotaValidator` runs after the access check, and `GetLimit` returns `0` for a missing quota and `null` for unlimited — demo limits must be explicit small integers (never `null`), capping how much a demo can create. *(Anchor: quota config for demo tier — ties to Section 1's abuse concern.)*
- **Entitlement lifecycle is the third cleanup concern.** The synthetic demo entitlement must be TTL-bound and must yield to real Stripe resolution on conversion (stable UID, Section 1). On `linkWithCredential`, the `IsDemo` flag must clear so the account resolves its real (likely `Inactive`/free) entitlement. *(Anchor: conversion flow + demo-expiry, alongside Firebase 30-day cleanup and demo-data GC.)*

## Open questions / follow-ups

- [ ] **Demo product shape — the fork that decides everything:** is "demo" a *pre-signup anonymous showcase* (→ app-side synthetic entitlement, no Stripe) **or** a *reverse-trial on a real signed-up account* (→ Stripe `trialing` subscription)? These are different builds. (Product decision.)
- [ ] **Which `PlanTier` does the demo present** — top tier (`FsmBusiness`/`Premium`) to showcase everything, or a limited tier? Drives the synthetic `Features`/`Limits`. (Product decision.)
- [ ] **Demo quota limits** — concrete numbers per `Quota` (invoices, worker seats, etc.) so demo can't be used for real work. (Product + abuse review.)
- [ ] **`AccountAccess` resolution seam** — confirm where `AccountAccess` is built (`SubscriptionService` / `AccessRegistry`) and that there's a clean place to branch on `IsDemo` without touching the Stripe read path. (Local code review for `/plan write`.)

---

# WEB-1617 — Web Spike: client-facing plan info (mobile/web)

Sections 1–2 cover *entry* (anonymous auth) and the server-side *gate* (`AccountAccess`). But the clients also **render** the plan — current tier, active state, expiry, "upgrade" CTA — from a *separate* DTO the BFF returns. A demo user must look coherent there too, or the app shows "no plan / trial available" instead of "demo, N days left". This section grounds that surface in the current `PlansService` code and surveys the canonical client-side subscription model (RevenueCat) as a reference shape for the demo DTO.

## Questions

7. How does Tofu return plan info to clients today, and what must change so a demo user sees a coherent demo plan rather than "no subscription"? *(code-grounded)*
8. What client-side model do mobile/web subscription SDKs expose for trial/demo state — i.e., the reference shape Tofu's `Plan` DTO should mirror?

## Sources

- [RevenueCat — Getting Subscription Status (CustomerInfo / EntitlementInfo)](https://www.revenuecat.com/docs/customers/customer-info) — the client-side fields used to render access/trial state.
- [RevenueCat — EntitlementInfo (Android SDK reference)](https://sdk.revenuecat.com/android/9.18.0/purchases/com.revenuecat.purchases/-entitlement-info/index.html) — `periodType`, `expirationDate`, `willRenew`, `isActive`.
- [RevenueCat — How to add trial notifications](https://www.revenuecat.com/blog/engineering/how-to-add-trial-notifications-to-your-subscriptions/) — computing "days remaining" from `expirationDate`.
- [Stripe — The Subscription object](https://docs.stripe.com/api/subscriptions/object) — `trial_start` / `trial_end` as the trial-window fields.

## Findings

### Q7 — How Tofu returns plan info to clients today (current code)

The client-facing surface is `IPlansService.GetCurrent(...)` → `Invoices.Core.Models.Plans.Plan` — distinct from the `AccountAccess` gate. `Plan` carries `IsActive`, `ProductType`, `Duration`, `CurrentTime`, `ExpirationTime`, `IsAutoRenewalEnabled`, `IsTrialAvailable`, `AdapterType`, `Price`, `Product`, `ExternalSubscriptionId`, `HasDuplicateSubscriptions` (`PlansService.cs:188-205`).

It is built from real `AccountSubscription[]` via `ISubscriptionService.GetSubscriptions` (`PlansService.cs:60-66`). A demo user has none, so the no-subscription branch fires (`PlansService.cs:117-136`):

```csharp
IsActive = false, ProductType = ProductType.Unknown,
IsTrialAvailable = subscriptions.Count == 0,        // → true
AdapterType = AccountSubscriptionAdapterType.None
```

**Consequence:** a demo user's client renders "no plan, trial available" — *not* "demo, expires X, tier Y". The `Plan` DTO has **no demo/kind discriminator**, and `AdapterType` has only `None`/`Stripe`/`Paddle`/`Apple…` — nothing for a synthetic demo. So the demo must be represented explicitly here, consistently with the gate.

### Q8 — Canonical client-side model for trial/demo state (reference shape)

RevenueCat's `EntitlementInfo` is the de-facto client contract for rendering subscription state, and it separates *active* from *period type* — exactly the distinction the demo DTO needs:

> **isActive**: "Whether or not the user has access to this entitlement."
> **periodType**: "The period type this entitlement is in, can be one of: Trial: In a free trial period … Normal: In the default period."
> **expirationDate**: "The expiration date for the entitlement, can be null for lifetime access. If the period type is trial then this is the trial expiration date."
> — [RevenueCat, CustomerInfo](https://www.revenuecat.com/docs/customers/customer-info)

Clients determine access from `isActive` and detect a trial via `periodType == Trial`, then compute "days remaining" from `expirationDate` ([trial notifications](https://www.revenuecat.com/blog/engineering/how-to-add-trial-notifications-to-your-subscriptions/)). Stripe exposes the same window as `trial_start`/`trial_end` ([Subscription object](https://docs.stripe.com/api/subscriptions/object)).

**Takeaway:** access and *kind of access* are separate axes. A demo should be `IsActive = true` **with** a `periodType`-style discriminator (`Demo`) and an `ExpirationTime` — so clients reuse their existing trial-rendering logic ("active, special period, N days left, convert to keep"). Overloading `IsActive = false` to mean "demo" forces every client to special-case it and reads as a paywall.

## Implications for the design

- **Inject the synthetic demo at `ISubscriptionService.GetSubscriptions` — the lowest common source.** Both the gate (`AccountAccess`) and the display (`Plan`) derive from subscriptions; a single synthetic demo `AccountSubscription` keeps them consistent. Injecting separately at each surface risks drift (gate allows, UI says "no plan"). *(Anchor: injection seam — confirm `AccountAccess` also derives from this source in `/plan write`.)*
- **Extend the `Plan` DTO with a demo/period discriminator + expiry, mirroring `periodType`.** Add a kind (`Normal` / `Trial` / `Demo`) and reuse `ExpirationTime` as the demo end, so clients render "demo, N days left" with the same code path as a trial — `IsActive = true`, not `false`. *(Anchor: additive DTO/contract change — new field; verify mobile back-compat.)*
- **Decide `AdapterType.Demo` vs a separate `PlanKind`.** A demo isn't Stripe/Paddle/Apple. Adding an enum value is additive server-side, but **shipped mobile clients must tolerate an unknown enum value** or it's a breaking change — flag this for the breaking-change scan. *(Anchor: enum evolution / mobile compatibility — potential BREAKING.)*
- **Resolve `IsTrialAvailable` semantics for demo.** A demo user showing `IsActive = true (Demo)` should not simultaneously claim `IsTrialAvailable = true` inconsistently — define what the flag means once a demo is active. *(Anchor: flag contract.)*
- **The conversion CTA reuses the existing offers surface.** Clients render upsell from `GetAllOffersAsync` → `OfferInfo`; ensure the BFF returns offers for the anonymous demo user so "convert to keep your work" renders. *(Anchor: offers endpoint must serve demo users.)*
- **One DTO serves both mobile and web** — a single `Plan` change covers both clients; no per-platform divergence on the display surface. *(Anchor: parity — reduces scope.)*

## Open questions / follow-ups

- [ ] **`AdapterType.Demo` vs new `PlanKind` field — and mobile tolerance.** Do shipped iOS/Android clients tolerate an unknown `AdapterType` enum value, or must demo be a new additive field? (Mobile compat review — **breaking-risk**.)
- [ ] **`IsTrialAvailable` for a demo user** — what does it return while a demo is active, and after conversion? (Product + client contract.)
- [ ] **Days-remaining: server-computed or client-derived?** Return just `ExpirationTime` (client computes) or an explicit remaining-days field? (Client contract decision.)
- [ ] **Single-source confirmation** — verify both `AccountAccess` and `Plan` derive from `ISubscriptionService.GetSubscriptions`, so one synthetic demo subscription keeps gate and display in sync. (Local code review for `/plan write`.)
