# WEB-1479 — Web Spike: handoff-token table naming + one-time token storage best practices

The plan (README, Option C) needs a decision on whether the one-time web-handoff token gets its own table — and if so, what to call it — plus industry-grounded answers on hashing, TTL, single-use semantics, indexes, and cleanup of expired rows. This spike surveys how widely-used identity systems name and store one-time auth tokens, and what the OAuth standards require of the analogous artifact (the authorization code).

## Questions

1. What do widely-used identity systems and frameworks name the table/entity holding one-time / short-lived auth tokens — and is the prevailing pattern a purpose-specific table or a generic token table with a `type` column?
2. What are established best practices for storing one-time tokens: hash algorithm (plain SHA-256 vs HMAC/pepper vs slow hashes), TTL, single-use semantics?
3. How is the single-use claim made race-safe (double-exchange prevention)?
4. What indexes does the table need, and how are expired rows cleaned up (Postgres has no native TTL)?
5. (Adjacent) Keep consumed rows for audit vs hard-delete; token format conventions (identifiable prefixes).
6. (Follow-up) Is "web handoff" an established pattern name, and does the industry call the artifact a *token* or a *code*? (Asked once the entity was re-scoped to serve multiple sign-in scenarios that all exchange into a Firebase custom token.)

## Sources

**Standards:**
- [RFC 6749 — The OAuth 2.0 Authorization Framework](https://datatracker.ietf.org/doc/html/rfc6749) — single-use + ≤10 min lifetime + revoke-on-reuse rules for authorization codes.
- [RFC 8628 — OAuth 2.0 Device Authorization Grant](https://datatracker.ietf.org/doc/html/rfc8628) — names the other standard one-time exchanged artifact, the *device code*.
- [OWASP Forgot Password Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html) — generation, storage, single-use rules for reset tokens (the closest OWASP analogue to a handoff token).

**Vendor / framework docs:**
- [Duende IdentityServer — Persisted Grant Store](https://docs.duendesoftware.com/identityserver/reference/stores/persisted-grant-store/) — `PersistedGrant` schema: SHA-256-hashed `Key`, `ConsumedTime`, single-use handling.
- [Duende IdentityServer — Operational Options](https://docs.duendesoftware.com/identityserver/reference/efoptions/operational/) + [Operational Data](https://docs.duendesoftware.com/identityserver/data/operational/) — expired-grant cleanup job (`EnableTokenCleanup`, `TokenCleanupInterval`, batching, multi-node fuzzing).
- [Auth.js — Database Models](https://authjs.dev/concepts/database-models) — `VerificationToken` model for magic-link sign-in.
- [Laravel — Resetting Passwords](https://laravel.com/docs/12.x/passwords) — `password_reset_tokens` table.
- [Django REST Framework — Authentication](https://www.django-rest-framework.org/api-guide/authentication/) — `authtoken_token` table.
- [Identity model customization in ASP.NET Core (Microsoft Learn)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/customize-identity-model?view=aspnetcore-10.0) — `AspNetUserTokens` generic per-user token store.
- [SuperTokens — OTP and Magic Link expiration](https://supertokens.com/docs/passwordless/common-customizations/change-code-lifetime) + [SuperTokens — Magic Links guide](https://supertokens.com/blog/magiclinks) — default 15-min lifetime; reference `magic_link_tokens` schema.
- [Behind GitHub's new authentication token formats (GitHub Engineering Blog)](https://github.blog/engineering/platform-security/behind-githubs-new-authentication-token-formats/) — identifiable token prefixes + checksum rationale.

**Pattern-name follow-up (Q6):**
- [draft-moros-oauth-browser-session-handoff-00 (IETF Internet-Draft, Apr 2026)](https://www.ietf.org/archive/id/draft-moros-oauth-browser-session-handoff-00.html) — names the pattern "session handoff" and the artifact a *Handoff Code*; TTL/entropy/single-use requirements.
- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693) — the umbrella swap-one-credential-for-another primitive the draft composes with.
- [OpenID Connect Native SSO for Mobile Apps 1.0](https://openid.net/specs/openid-connect-native-sso-1_0.html) — the adjacent adopted spec (app→app on one device, `device_secret` + RFC 8693); does not cover app→browser.
- [Keycloak forum — "Mobile application authentication handoff to stateful webapp"](https://forum.keycloak.org/t/mobile-application-authentication-handoff-to-stateful-webapp/16927) — practitioner usage of "authentication handoff" for this exact flow.
- [Auth0 — Native to Web SSO](https://auth0.com/docs/authenticate/single-sign-on/native-to-web) — the major-vendor product for this exact flow; artifact named **Session Transfer Token** (`session_transfer_token`): 60 s default TTL, single-use, optional device/IP binding.
- [Keycloak issue #46660 — Native-to-Web SSO / Session Transfer](https://github.com/keycloak/keycloak/issues/46660) — feature request describing the same artifact as a short-lived, single-use transfer token.

**Secondary (named engineering blogs / community):**
- [Clerk — Email Magic Links explained](https://clerk.com/blog/magic-links) — one-time + short-expiry framing for sign-in links.
- [Why bcrypt Will Kill Your API Performance (CyberSierra)](https://cybersierra.co/blog/bcrypt-performance-issues-api/) — entropy-not-slowness argument for fast hashes on random tokens.
- [FusionAuth — The Math of Password Hashing Algorithms and Entropy](https://fusionauth.medium.com/the-math-of-password-hashing-algorithms-and-entropy-7640e27f150) — why slow KDFs exist for *low-entropy* secrets.
- [Race Conditions in Web Applications (Raijuna)](https://www.raijuna.com/knowledge/race-conditions) + [TOCTOU exploitation guide (F. Fernandez, Medium)](https://fdzdev.medium.com/guide-to-identifying-and-exploiting-toctou-race-conditions-in-web-applications-c5f233e32b7f) — atomic check-and-claim as the fix for redemption races.

## Findings

### Q1 — What do identity systems name the one-time token table, and generic vs purpose-specific?

Two patterns coexist; **purpose-specific tables dominate for short-lived, exchanged-once artifacts**, while generic tables with a `Type` column show up in full token-infrastructure products:

| System | Entity / table | Pattern | Notes | Source |
|---|---|---|---|---|
| Auth.js | `VerificationToken` | purpose-specific | "store tokens for email-based **magic-link** sign in"; "Auth.js makes sure that every token is usable only once" | [Auth.js models](https://authjs.dev/concepts/database-models) |
| Laravel | `password_reset_tokens` | purpose-specific | plural snake_case, named after the *purpose* not the mechanism | [Laravel docs](https://laravel.com/docs/12.x/passwords) |
| SuperTokens-style guides | `magic_link_tokens` | purpose-specific | reference schema: `token_hash`, `user_id`, `expires_at`, `used_at` — same column shape we already use | [SuperTokens](https://supertokens.com/blog/magiclinks) |
| Django DRF | `authtoken_token` | purpose-specific | long-lived API tokens, not one-time | [DRF docs](https://www.django-rest-framework.org/api-guide/authentication/) |
| Duende IdentityServer | `PersistedGrants` | **generic + `Type`** | one table for auth codes, refresh tokens, device codes, consents; `Type` discriminator | [Duende store](https://docs.duendesoftware.com/identityserver/reference/stores/persisted-grant-store/) |
| ASP.NET Core Identity | `AspNetUserTokens` | **generic + purpose key** | external auth tokens, TOTP keys, recovery codes — keyed by `(UserId, LoginProvider, Name)` | [MS Learn](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/customize-identity-model?view=aspnetcore-10.0) |
| OAuth vocabulary | *authorization code*, *device code* | n/a | the standards call an opaque, single-use, server-exchanged artifact a **code**, reserving *token* for the bearer credential it yields | [RFC 6749](https://datatracker.ietf.org/doc/html/rfc6749), [RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628) |

Naming observations:

- Frameworks name the table after the **purpose** (`password_reset_tokens`, `magic_link_tokens`, `VerificationToken`), not the mechanism. The generic-table pattern (Duende, ASP.NET Identity) appears only where the product manages *many* token kinds behind one abstraction — that is not our situation (we'd have exactly two kinds: invitation + handoff).
- OAuth's own vocabulary argues the artifact is a **code** ("authorization code", "device code"): an opaque single-use string exchanged server-side for the real credential. "Token" in the wild more often means the bearer credential itself. That said, the workspace precedent (`InvitationMagicToken`) already uses `*Token`, and Auth.js/SuperTokens show `*Token` is also common for exactly this artifact.
- Candidate names consistent with both industry and codebase convention: **`WebHandoffToken`** (purpose-named, parallels `InvitationMagicToken`), `SignInToken`, `WebLoginCode`. Avoid bare `OneTimeToken`/`Token` — every survey row names the purpose.

### Q2 — Hashing, at-rest storage

- OWASP requires reset-style tokens to be "Generated using a cryptographically secure random number generator", "Long enough to protect against brute-force attacks", stored "in a secure manner", and "Invalidated after they have been used" — [OWASP Forgot Password Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html).
- **Plain SHA-256 of the raw token is the industry-standard at-rest form for high-entropy tokens.** Duende stores the grant `Key` as a SHA-256 hash (hex-encoded since v6) — [Persisted Grant Store](https://docs.duendesoftware.com/identityserver/reference/stores/persisted-grant-store/). GitHub likewise treats token identifiability + hashing as the storage model in its [token-format post](https://github.blog/engineering/platform-security/behind-githubs-new-authentication-token-formats/).
- Why fast hash, no salt, no bcrypt/argon2: "The security comes from the high entropy of the source key, not the slowness of the hash. A properly generated API key with 256 bits of entropy is computationally impossible to brute-force, regardless of hash speed" — [CyberSierra](https://cybersierra.co/blog/bcrypt-performance-issues-api/) (named engineering blog; the same logic is laid out quantitatively by [FusionAuth](https://fusionauth.medium.com/the-math-of-password-hashing-algorithms-and-entropy-7640e27f150)). Slow KDFs and salts exist to protect *low-entropy, possibly-duplicated* secrets (passwords) against brute force and rainbow tables; a 256-bit CSPRNG token is globally unique and unguessable, so neither applies. Salting would also break the lookup-by-hash query pattern.
- Lookup is **by exact hash via a unique index** — the DB equality match on the SHA-256 digest is the comparison; no separate constant-time-compare code path is needed (timing leakage on a 256-bit-entropy digest lookup is not exploitable).
- Optional hardening, not required at this tier: HMAC with a server-side key (pepper) protects against an attacker who can both read the DB *and* knows the hashing scheme; none of the surveyed mainstream stores do this for one-time codes.

**Fit:** our existing `TokenGenerationUtils.GenerateSecureToken` (32 CSPRNG bytes, Base64Url) + `ComputeTokenHash` (SHA-256) already match all of the above exactly. Nothing to change in the primitive.

### Q3 — TTL and single-use semantics

- RFC 6749 on the closest standard analogue: "The client MUST NOT use the authorization code more than once. If an authorization code is used more than once, the authorization server MUST deny the request and SHOULD revoke (when possible) all tokens previously issued based on that authorization code. … A maximum authorization code lifetime of 10 minutes is RECOMMENDED." — [RFC 6749 §4.1.2 / §10.5](https://datatracker.ietf.org/doc/html/rfc6749).
- Magic-link industry practice converges on **10–15 minutes** ([SuperTokens default 15 min](https://supertokens.com/docs/passwordless/common-customizations/change-code-lifetime); [Clerk](https://clerk.com/blog/magic-links) and Auth0 community guidance in the same band). That band exists to absorb *email delivery latency* — which our flow doesn't have: the app opens Safari with the token immediately.
- Therefore the README's proposed **2–5 minutes** is well-supported and conservative: stricter than the email-bound 10–15 min norm, generous against the seconds-scale actual redemption window. RFC 6749's "expire shortly after issuance to mitigate the risk of leaks" is the governing principle.
- **Reuse handling:** at minimum reject (`MUST deny`); the RFC's `SHOULD revoke previously issued tokens` maps poorly to Firebase custom tokens (≤1 h, already consumed by `signInWithCustomToken`), so for stage 1 reject-and-log is sufficient; flag reuse attempts in logs as a potential-leak signal.

### Q4 — Race-safe single-use claim

- Naive `SELECT` → check → `UPDATE` is a TOCTOU race: parallel exchange requests can both pass the check and both mint custom tokens — exactly the coupon-redemption race documented in [Raijuna](https://www.raijuna.com/knowledge/race-conditions) and [Fernandez](https://fdzdev.medium.com/guide-to-identifying-and-exploiting-toctou-race-conditions-in-web-applications-c5f233e32b7f).
- The standard fix is an **atomic conditional claim**: a single statement of the form `UPDATE … SET UsedAt = now() WHERE TokenHash = @h AND UsedAt IS NULL AND ExpiresAt > now()` — exactly one request observes `rows affected = 1` and wins; everyone else gets 0 rows and a rejection. Alternatives: `SELECT … FOR UPDATE` row lock, or EF optimistic concurrency (the repo's existing `ConcurrentUpdateInterceptor` / a `rowversion`-style token) — any of these is acceptable; the conditional-update form is the simplest to test.
- The double-exchange race is a **mandatory functional-test case** (two concurrent exchanges → exactly one custom token).

### Q5 — Indexes and cleanup of expired rows

- **Indexes:** `UNIQUE` on `TokenHash` (serves both the exchange lookup and duplicate prevention; Duende's hashed `Key` is its store key), plus a plain index on `ExpiresAt` to make the cleanup delete cheap. FK index on `UserId` comes free with the constraint in Postgres conventions. Nothing else — keep it minimal (cf. the [Laravel discussion on questionable default indexes](https://github.com/laravel/framework/discussions/51001)).
- **Cleanup:** Postgres has no native TTL, so expired rows are reaped by a background job. Duende is the reference implementation of the pattern — [Operational Options](https://docs.duendesoftware.com/identityserver/reference/efoptions/operational/) / [Operational Data](https://docs.duendesoftware.com/identityserver/data/operational/):
  - `EnableTokenCleanup` (default `false`), `TokenCleanupInterval` default **3600 s**, `TokenCleanupBatchSize` default **100** (loops batches until done).
  - Multi-node: "If multiple nodes run the cleanup job at the same time, update conflicts might occur in the store. To reduce the probability of that happening, the startup time can be fuzzed" (first run scheduled at a random offset).
  - Notably: "The token cleanup feature does not remove persisted grants that are consumed. It only removes persisted grants that are beyond their Expiration." — i.e., delete on *expiry*, not on *consumption*; consumed rows survive until they expire.
- Volume for WEB-1479 is tiny (one row per app→web handoff, TTL minutes), so a simple periodic delete is ample; the batching/fuzzing knobs matter only at IdentityServer scale. **Check whether a cleanup job already exists for `InvitationMagicToken`** — if it does, extend it; if not, this feature is the moment both token kinds get one.

### Q5-adjacent — Retain consumed rows? Token format prefixes?

- **Retention:** Duende keeps consumed grants because they "are intended to be used once and … need to be retained after their use for some purpose (for example, replay detection or to allow certain kinds of limited reuse)". This matches the existing `InvitationMagicToken.UsedAt` mark-don't-delete approach. Recommendation: same model — set `UsedAt`, let the expiry-based cleanup remove the row later; a reuse attempt then remains distinguishable from an unknown token (useful log signal per Q3).
- **Column naming for the consumed mark:** Duende uses `ConsumedTime`; the workspace already uses `UsedAt`. Internal consistency wins — keep `UsedAt` (and `ExpiresAt`, `CreatedAt`) matching `InvitationMagicToken`.
- **Identifiable prefixes:** GitHub prefixes all tokens (`ghp_`, `gho_`, …) so that leaked tokens are machine-identifiable; "the false positive rate for secret scanning will be down to 0.5%", and a checksum lets validators reject fakes offline — [GitHub blog](https://github.blog/engineering/platform-security/behind-githubs-new-authentication-token-formats/). For an internal 2–5-minute token this is optional, but a short prefix (e.g., `twh_`) is nearly free and makes accidental log leakage greppable. Note `InvitationMagicToken` has no prefix — adopting one only for the new token is a deliberate, additive divergence.

### Q6 — Is "web handoff" a standard pattern name? Token or code?

**"Session handoff" is the emerging standards term for exactly this flow, and the artifact is a *code*.** An IETF Internet-Draft published April 2026 — [draft-moros-oauth-browser-session-handoff](https://www.ietf.org/archive/id/draft-moros-oauth-browser-session-handoff-00.html), *"Browser Session Establishment Using OAuth 2.0 Token Exchange and Short-Lived Authorization Codes"* — describes app/IdP→browser session establishment via a short-lived single-use code, motivated by the same front-channel leakage concerns as this plan ("browser history, HTTP Referer header, intermediary access logs"). Its term for the artifact:

> "A short-lived, single-use, opaque string generated by the RP that indirectly references a cached RP-issued access token."
> — *Handoff Code*, [draft-moros-oauth-browser-session-handoff-00](https://www.ietf.org/archive/id/draft-moros-oauth-browser-session-handoff-00.html)

Its normative properties for the code: "At least 128 bits of cryptographically random material, base64url-encoded. 256 bits RECOMMENDED"; "A Time-To-Live (TTL) of 60 seconds is RECOMMENDED. TTL MUST NOT exceed 120 seconds"; "The cached mapping MUST be deleted atomically on first successful redemption."

Corroborating signals:

- Practitioners already use the word — e.g., the [Keycloak thread](https://forum.keycloak.org/t/mobile-application-authentication-handoff-to-stateful-webapp/16927) "Mobile application **authentication handoff** to stateful webapp".
- The adjacent *adopted* standards stack leaves this gap: [RFC 8693 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693) is the generic credential-swap primitive; [OpenID Connect Native SSO 1.0](https://openid.net/specs/openid-connect-native-sso-1_0.html) covers app→app on one device. App→browser is precisely what the handoff draft adds.
- "Cross-Device Authentication (CDA)" is a different pattern (FIDO/passkeys across two devices) — not this.

Caveats, inline: the draft is an **individual `-00` Internet-Draft** (expires Oct 2026), not an RFC — converging vocabulary, not settled law. Its transport is a query `?code=` (server-rendered RP redirect); our fragment choice remains correct for a client-side Firebase SPA. And in iOS contexts, Apple's "Handoff" continuity feature is an unrelated namesake — acceptable collision, different domain.

Naming consequence: with the entity re-scoped to serve multiple sign-in scenarios that all exchange into a Firebase custom token, the name should encode the *role* (single-use artifact exchanged for the credential), not one scenario. The industry is split on token-vs-code: the IETF draft and OAuth RFCs say **code** (`HandoffCode` matches the draft verbatim), while [Auth0's Native to Web SSO](https://auth0.com/docs/authenticate/single-sign-on/native-to-web) — the closest commercial product — says **token** (*Session Transfer Token*, 60 s TTL, single-use, optionally device-bound; its TTL independently corroborates the 60–120 s band above).

**Final decision (2026-06-04): `HandoffToken`** — team preference, backed by the Auth0 precedent. The code-vs-token collision risk this spike flagged (the error catalog already uses `token_expired`/`token_revoked` for the *Firebase JWT*) is accepted and mitigated by a contract note in [client-flow.md](./client-flow.md) distinguishing JWT-layer `token_*` errors from `handoff_token_*` errors.

## Implications for the design

- **New table: `HandoffTokens`, entity `HandoffToken`, with a `Purpose` discriminator** (anchor: README open question "reuse `InvitationMagicToken` vs new table"; final naming per the Q6 decision — Auth0 "Session Transfer Token" precedent over the draft's "Handoff Code"): keeps the invitations domain clean (no nullable-`InvitationId` migration), names the *role* not one scenario, and — since multiple kinds are planned — adopts the generic-table-plus-`Type` pattern (Duende `PersistedGrants` precedent) via `Purpose` instead of one table per scenario. Endpoints: `/v1/handoff-tokens` + `/v1/handoff-tokens/exchange` (Tofu.Auth), `/api/authenticate/handoff-tokens[…]` (BFF).
- **Schema** (anchor: EF migration): `Id, TokenHash (unique index), UserId (FK), Purpose, ExpiresAt (indexed), UsedAt (nullable), CreatedAt` — same column vocabulary as `InvitationMagicToken` (`TokenHash`, `UsedAt` — not Duende's `ConsumedTime`).
- **Keep the existing crypto primitive unchanged** (anchor: token generation): 32-byte CSPRNG + Base64Url + plain SHA-256 at rest is exactly what Duende/GitHub/OWASP converge on and meets the handoff draft's "256 bits RECOMMENDED"; no salt, no bcrypt, no pepper needed at this tier.
- **TTL 60–120 s** (anchor: README open question on TTL; tightens this spike's earlier 2–5 min conclusion): the handoff draft — purpose-built for this exact flow — recommends 60 s and caps at 120 s; our redemption window is seconds (app opens Safari immediately, no email latency), so nothing argues for more. Config-bound (`Invitation`-style options section), so loosening later is trivial.
- **Exchange endpoint must claim atomically** (anchor: exchange implementation + test plan): single conditional `UPDATE … WHERE UsedAt IS NULL AND ExpiresAt > now()` (or the repo's optimistic-concurrency equivalent); add a concurrent-double-exchange functional test; log reuse attempts as a leak signal (RFC 6749 MUST-deny).
- **Mark-used, reap-on-expiry** (anchor: single-use semantics + ops): set `UsedAt` instead of deleting (Duende's retained-consumed-grant model — preserves replay-attempt detectability); a small background cleanup job deletes rows past `ExpiresAt`. This deliberately diverges from the handoff draft's "deleted atomically on first successful redemption" — the draft's mapping is a cache with nothing to audit; ours retains the row so a reuse attempt is distinguishable from an unknown code. The claim itself must still be atomic. Check whether `InvitationMagicToken` already has such a job — extend it or introduce one covering both tables; Duende's interval/batch/fuzz defaults are the reference if multi-node matters.
- **Adopted: `tht_` token prefix** (GitHub pattern; decided 2026-06-04, re-lettered from `thc_` after the HandoffToken rename): makes accidental leaks greppable (logs, screenshots, commits) and turns the client telemetry scrub into a precise regex (`tht_[A-Za-z0-9_-]+`) instead of positional URL surgery. Purely additive — constant prepended before the 32-byte Base64Url payload; entropy untouched; hash computed over the full prefixed string. Deliberate divergence from the prefix-less `InvitationMagicToken` (retrofit tracked below).

## Open questions / follow-ups

- [ ] Does a cleanup job for expired `InvitationMagicToken` rows already exist in Tofu.Auth (Worker/hosted service)? Determines whether WEB-1479 adds a new job or extends one. (Codebase question — answer during `/plan write`, not a web question.)
- [ ] See also the second spike section below: client-side (mobile/web) corner cases for the fragment transport.
- [ ] Exact TTL value within the 60–120 s band (handoff draft's recommendation) and its config key name — product/lead confirmation.
- [ ] Adopt a code prefix only for the new entity, or also retrofit invitation magic tokens later (consistency follow-up, out of WEB-1479 scope)?
- [x] ~~`HandoffCode` vs `AuthCode`~~ — resolved 2026-06-04: **`HandoffToken`** (team decision; Auth0 "Session Transfer Token" precedent). Still worth a sanity check before the migration that future exchange scenarios are all session handoffs.
- [ ] Atomic-claim mechanism choice (conditional UPDATE vs existing `ConcurrentUpdateInterceptor` pattern) — pick whichever matches Tofu.Auth repository conventions during `/plan write`.

---

# WEB-1479 — Web Spike: client-side handling of the fragment-borne handoff code (mobile/web corner cases)

The flow puts the handoff code in the URL fragment and relies on the web app reading it, scrubbing it, and exchanging it exactly once. This section collects the browser/iOS corner cases that break naive implementations — most are documented failures in shipped auth libraries.

## Questions

1. Does the fragment survive HTTP redirects, and what leak vector does that open?
2. What is the correct read-scrub-exchange order on the web side, and what breaks it (bfcache, duplicated tabs, SPA routers, double-mounted effects)?
3. Does client-side telemetry (Sentry & co.) leak the fragment?
4. On iOS, what can prevent the URL from actually landing in an external browser (universal-link interception, non-Safari default browser)?

## Sources

- [RFC-derived fragment-inheritance behavior + OAuth open-redirect labs (PortSwigger)](https://portswigger.net/web-security/oauth/lab-oauth-stealing-oauth-access-tokens-via-an-open-redirect) — fragment inherited across 3xx; token theft via open redirect.
- [OWASP — Open Redirect](https://owasp.org/www-community/attacks/open_redirect) — the underlying vulnerability class.
- [Curity — OAuth Implicit Flow](https://curity.io/resources/learn/oauth-implicit-flow/) and [Okta — Implicit Grant](https://developer.okta.com/blog/2018/05/24/what-is-the-oauth2-implicit-grant-type) — why tokens-in-fragment was deprecated (RFC 9700, Jan 2025); context for why an opaque code is OK there.
- [supabase/auth-js #302 — "Removing tokens from the URL's hash fragment should be done via History.replaceState()"](https://github.com/supabase/auth-js/issues/302) — shipped magic-link library bug: Back→Forward (bfcache) resurrects the token in the URL.
- [MDN — History.replaceState()](https://developer.mozilla.org/en-US/docs/Web/API/History/replaceState) — the scrub primitive.
- [Scrubbing URL fragments from Sentry crash reports (R. Clement)](https://romain-clement.net/articles/sentry-url-fragments/) + [Sentry — Scrubbing Sensitive Data (JS)](https://docs.sentry.io/platforms/javascript/data-management/sensitive-data/) — Sentry captures `location.href` incl. fragment; `beforeSend`/`beforeBreadcrumb` scrubbing.
- [OAuth double exchange-code request due to React StrictMode (answeroverflow)](https://www.answeroverflow.com/m/1458018843795390494) + [facebook/react #24455](https://github.com/facebook/react/issues/24455) — dev-mode double-mount consumes a single-use code twice ("code already used" on the 2nd call).
- [Apple TN3155 — Debugging universal links](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links) + [Bugfender — iOS Universal Links guide](https://bugfender.com/blog/ios-universal-links/) — AASA path matching decides app-vs-Safari; broad `*` paths capture the whole site.
- [Apple Developer Forums — canOpenURL/default browser](https://developer.apple.com/forums/thread/660241) + [Chromium — Opening links in Chrome for iOS](https://chromium.googlesource.com/chromium/src/+/master/docs/ios/opening_links.md) — `UIApplication.open(https)` opens the user's **default** browser, not necessarily Safari.

## Findings

### Q1 — Fragment survives redirects; open redirects are the leak vector

Per HTTP semantics, if a 3xx `Location` has no fragment of its own, "a user agent MUST process the redirection as if the value inherits the fragment component of the URI reference used to generate the request target". Consequences:

- If the landing URL (`/auth#t=...`) triggers **any server-side redirect** before the SPA reads the hash — http→https rewrite chains, `/auth` → `/auth/`, CDN country redirects, "not logged in → /login" — the code silently rides along to the new URL. If any hop is an **open redirect** to a foreign domain, the code is exfiltrated (the classic OAuth-implicit token-theft chain in the PortSwigger lab).
- Caveat for readers: RFC 9700 deprecated the *implicit flow* because it put the **access token** in the fragment. Our design ships only the opaque single-use code there — exactly the code-not-token mitigation — but the redirect-inheritance behavior applies to the code too; its protections are the 60–120 s TTL + single-use, not immunity to the vector.

### Q2 — Read-scrub-exchange order, and what breaks it

The naive `useEffect(() => exchange(location.hash))` breaks four ways, all documented:

1. **bfcache resurrection** ([supabase/auth-js #302](https://github.com/supabase/auth-js/issues/302)): after `replaceState` scrubs the URL, Back→Forward can restore the page from back/forward cache **with the original URL**, showing (and re-processing) the code. Handle "already used" gracefully on re-entry; treat it as "session already established → continue" when the user is in fact signed in.
2. **Double-mounted effects** (React 18 StrictMode, dev): mount→unmount→mount runs the exchange twice; the second call gets "code already used" — observed exactly as `POST /auth/exchange-code 200` then `400 The code has already been used`. Guard with a module/`useRef` once-flag; never key retries off the raw hash.
3. **SPA router interference**: hash-based routers (and some history libraries) read/rewrite `location.hash` on boot. The code must be read **synchronously, before router init**, captured into memory, then `history.replaceState` immediately — before any `await` and before the exchange request, so no async gap leaves the code in the URL.
4. **Tab duplication / "copy URL"**: duplicating the tab or sharing the URL before scrub copies the code. Single-use + short TTL bound the damage; immediate synchronous scrub minimizes the window.

Storage rule: the code lives in a JS variable only — never `localStorage`/`sessionStorage` (outlives the seconds-long need, readable by any same-origin script).

### Q3 — Client telemetry leaks the fragment

Sentry's JS SDK captures `window.location.href` **including the fragment** in events, and "most SDKs will add the HTTP query string and fragment as a data attribute to the breadcrumb". Server logs never see the fragment, but the error tracker does — re-creating the leak the fragment transport was chosen to avoid. Fix: scrub `#...` from `event.request.url` in `beforeSend` and from navigation breadcrumbs in `beforeBreadcrumb` (R. Clement has a drop-in example). The same applies to any client-side analytics capturing full URLs.

### Q4 — iOS: getting the URL to actually land in an external browser

- **Universal-link interception**: if the web app's domain serves an AASA file whose `paths` cover `/auth` (e.g., a broad `*`), iOS may hand the URL **back to the native app** instead of the browser — a handoff loop. Fix: exclude the landing path in AASA (`"NOT /auth/*"` style exclusion) or host the landing page on a path/subdomain outside `applinks` scope. (Opening one's own universal link via `UIApplication.open` has additional system heuristics — test on device, per TN3155.)
- **"Safari" actually means the default browser**: `UIApplication.open(https:)` launches the user's default browser — Chrome/Firefox/etc. if the user changed it. The flow works identically (fragment, exchange, Firebase IndexedDB persistence are per-browser), but the resulting long-lived web session lands in *that* browser, and Safari-specific assumptions (shared cookie SSO with `ASWebAuthenticationSession`) silently stop holding. Product wording "открыть в Safari" should be read as "открыть во внешнем браузере по умолчанию".
- **TTL vs. cold start** (derived from the TTL findings, no external source): the 60–120 s clock starts at issuance, and a cold browser start + SPA bundle download on a bad connection can eat it. Mitigate: issue the code immediately before `open(url)` (not at screen load), prefer 120 s over 60 s, and ship a friendly expired-state UX ("вернитесь в приложение и попробуйте снова").

## Implications for the design

- **Web landing page must be redirect-free** (anchor: web `/auth` page design): serve it directly over HTTPS with no server-side redirects on the path; audit CDN/host rewrite rules; `Referrer-Policy: no-referrer` on the page (already in README).
- **Prescribed client order** (anchor: web checklist in README): synchronously read hash → capture to variable → `history.replaceState` → *then* exchange; once-guard around the exchange; "already used" on re-entry = continue if signed-in, else show expired UX. No persistence of the code anywhere.
- **Add Sentry scrubbing to the web work** (anchor: web checklist): `beforeSend` + `beforeBreadcrumb` fragment scrub ships **with** the landing page, not later — otherwise the first production error uploads a live code.
- **iOS checklist gains two items** (anchor: iOS side): (1) verify/adjust AASA so the landing path is NOT claimed by universal links; (2) issue the code right before opening the browser, treat "Safari" as "default external browser" in copy and QA matrix (test with Chrome-as-default).
- **Backend stance unchanged** (anchor: exchange endpoint): single-use + atomic claim + 60–120 s TTL are exactly the compensating controls these client corner cases lean on; the "already used" error must be distinguishable (per the error-codes decision) so the web can implement the graceful re-entry path.

## Open questions / follow-ups

- [ ] Who owns the web app's AASA file / is `/auth` (or chosen landing path) currently covered by `applinks` paths? (Needs an answer before the iOS work starts.)
- [ ] Which error tracker/analytics run on the web landing page (Sentry? GA?) — each needs the fragment scrub.
- [ ] Confirm product copy: flow targets the default external browser, not literally Safari.
