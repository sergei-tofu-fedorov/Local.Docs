# FS-976 — WASM bundle versioning and iOS sync (triggered by missing XCG currency)

**Status:** planning
**Started:** 2026-05-01
**ClickUp:** https://app.clickup.com/t/FS-976
**Affected repos:** `Invoices.Backend` (WASM project + manifest publishing) — iOS app repo (separate, owned by mobile team) consumes the manifest

## Trigger

Invoice preview crashes on iOS for users whose currency is `XCG` (the new Caribbean guilder, replaced `ANG` on 2025-03-31; users in the field switched in December 2025). Root cause analysis revealed two separable problems:

1. **Surface bug:** the WASM bundle bundled into iOS builds is older than commit `39954293` (2025-10-09, "feat: add Caribbean guilder (XCG) and Zimbabwe Gold (ZWG)"). The .NET source already has `XCG` in `Src/Invoices.Core/Models/Currencies/CurrencyCodeType.cs:164` and `CurrencyHelper.cs:182`.
2. **Underlying problem:** there is **no versioning contract** between the iOS app and the WASM bundle. iOS ships a WASM bundle baked into the app at build time (or pinned to an arbitrary SHA), and there is no mechanism to:
   - detect that a newer bundle is available,
   - confirm a newer bundle is compatible with the installed app,
   - safely roll back if a bundle is broken,
   - tell which bundle a given app version is currently using.

This feature is the **underlying-problem fix**. The XCG crash is verified once the new versioning rolls out; we do not ship a one-off XCG patch.

## Goal

Define and implement a versioning + sync contract for the `Invoices.Shared.HtmlPreview` WASM bundle so that:

- The iOS app always loads the most recent WASM bundle that is **compatible** with its installed native version.
- New WASM-only fixes (e.g., adding a currency) reach iOS users without a mobile App Store release.
- Bundles whose changes require native cooperation are gated by a minimum native version and **not** delivered to older clients.
- We can roll back to a known-good bundle in minutes.
- The current "stale bundle is opaque" failure mode is replaced by a deterministic "iOS shows version X, manifest serves version Y, here is why" diagnosis path.

## Scope

- **In scope:**
  - Bundle manifest format and publication (backend, this repo).
  - GitHub Actions workflow changes: auto-publish on `main` merges, manifest generation, manifest cache-control rules.
  - Documenting the iOS-side contract: what the iOS app must read from the manifest, how it decides which bundle to fetch, where it caches, when it falls back.
  - Adding `runtimeVersion` to the WASM bundle (a string embedded in the bundle and exposed in the manifest) so app and bundle compatibility is explicit.
  - One-off: confirm the XCG crash is gone once a fresh bundle is published and iOS picks it up.
  - Regression test that asserts every `CurrencyCodeType` enum value resolves through `CurrencyHelper` (catches future enum/dictionary drift).
- **Out of scope:**
  - Implementing the iOS-side fetch/cache/swap logic — that is mobile-team work in their repo. This feature defines the contract they will implement against.
  - Android client (separate ticket if needed; the same manifest can serve both).
  - Frontend / web-app consumption (already loads the WASM bundle via standard browser caching; no change needed).
  - Replacing the WASM bundle with a native iOS implementation.

## Affected repos

- **`Invoices.Backend`** — WASM project (`Src/Invoices.Shared.HtmlPreview`) and CI workflow (`.github/workflows/publish-wasm.yaml`).
- **iOS app repo** (mobile team — separate from this workspace) — implements the manifest-based fetch/cache/swap contract documented here.

This is effectively a **producer/consumer** feature: backend produces the manifest + bundles; iOS consumes them. They land independently, with the backend producer landing first so the iOS team can target a working endpoint.

## Versioning contract

### Manifest

Publish a single, stable JSON manifest at a well-known URL per channel:

- Production: `https://wasm-shared.tofu.example/manifest.json`
- Staging: `https://wasm-shared-staging.tofu.example/manifest.json`

(Exact host TBD — currently the buckets are `gs://wasm_shared` and `gs://wasm_shared_staging`. Decide whether to expose them via a CDN/custom domain or use the GCS public URL.)

Manifest shape:

```json
{
  "schemaVersion": 1,
  "channel": "production",
  "generatedAt": "2026-05-01T12:00:00Z",
  "current": {
    "bundleId": "39954293",
    "runtimeVersion": "1",
    "minSupportedAppBuild": 4200,
    "url": "https://wasm-shared.tofu.example/wasm_shared_html_preview_39954293.tar.gz",
    "sha256": "<hex>",
    "sizeBytes": 2345678,
    "publishedAt": "2026-05-01T12:00:00Z",
    "releaseNotes": "Adds XCG (Caribbean guilder) and ZWG (Zimbabwe Gold) currencies."
  },
  "history": [
    {
      "bundleId": "1ff176c2",
      "runtimeVersion": "1",
      "minSupportedAppBuild": 4100,
      "url": "...",
      "sha256": "...",
      "publishedAt": "2025-09-15T10:00:00Z"
    }
  ],
  "rollbackTo": null
}
```

Field semantics:

- **`schemaVersion`** — manifest format version. Increment on incompatible changes; iOS can refuse to load unknown schema versions.
- **`bundleId`** — short SHA of the source commit that produced the bundle (already the convention in `publish-wasm.yaml`).
- **`runtimeVersion`** — string declaring the bundle's contract with the native app. Bumped only when the bundle requires native-side changes (new function the host must provide, removed entry point, breaking IPC change, etc.). iOS only loads bundles whose `runtimeVersion` it knows. This is the same idea as Expo EAS's `runtimeVersion`.
- **`minSupportedAppBuild`** — minimum iOS app build number that may load this bundle. Lets us ship a bundle that *uses* a feature added in app build 4200 without breaking apps still on 4100. iOS skips any entry where `minSupportedAppBuild > installedBuild` and falls through to the next history entry.
- **`url` / `sha256` / `sizeBytes`** — content-addressed download. iOS verifies SHA before swapping in.
- **`publishedAt` / `releaseNotes`** — diagnostics.
- **`history`** — recent prior bundles, newest-first, capped (e.g., last 10). Enables fallback when `current` is incompatible with the installed app build.
- **`rollbackTo`** — when non-null, iOS prefers this bundleId over `current`. Lets us pin the manifest to a known-good bundle without rebuilding.

### iOS resolution algorithm (documented for the mobile team)

```
on app start (and every N hours / on foreground):
  fetch manifest.json (timeout, retry; honor cache-control)
  if rollbackTo is set:
    candidate = history.find(b => b.bundleId == rollbackTo)
  else:
    candidate = current
  if candidate.runtimeVersion not in supported_runtime_versions: candidate = walk history for first supported
  if candidate.minSupportedAppBuild > installed_app_build:    candidate = walk history for first compatible
  if candidate.bundleId != currently_loaded_bundle.bundleId:
    download(candidate.url) -> verify sha256 -> stage on disk
    on next preview render: swap to staged bundle
  on download/verify failure: keep currently_loaded_bundle, log
fallback chain: cached bundle -> bundle baked into app at build time
```

Key invariants:

- The bundle baked into the IPA at build time is the **floor** — the app must always be able to render a preview without network.
- The cached bundle replaces the baked one only after a SHA match.
- Rolling back is a manifest edit (set `rollbackTo`) — no rebuild, no app release.

### Backwards compatibility

- Old iOS app builds that do not implement this manifest will continue to use whatever bundle they were shipped with. No regression — they were already in that state.
- Once an iOS build that implements the manifest ships, it picks up the latest compatible bundle automatically. The XCG crash resolves the first time such an iOS build runs.

## Plan

### Phase 1 — Backend (this repo)

1. [ ] **Embed `runtimeVersion` in the WASM bundle.** Add `appsettings.json` or compile-time constant `WASM_RUNTIME_VERSION = "1"` exposed in `Invoices.Shared.HtmlPreview`. Initial value `"1"`.
2. [ ] **Write a manifest generator step in CI.** New script (`Src/Invoices.Shared.HtmlPreview/scripts/build-manifest.ps1` or inline in the workflow) that:
   - Reads existing `manifest.json` from the target GCS bucket (if present).
   - Computes SHA256 of the freshly built tarball.
   - Builds the new `current` entry with `bundleId = $GITHUB_SHA`, `runtimeVersion`, `minSupportedAppBuild` (input parameter, default = previous), `url`, `sha256`, `sizeBytes`, `publishedAt = now`, `releaseNotes` (input parameter or commit subject).
   - Demotes the previous `current` to the head of `history`, capping at 10 entries.
   - Writes the merged manifest back to the bucket.
3. [ ] **Update `.github/workflows/publish-wasm.yaml`** to:
   - Run the manifest generator after the existing tarball upload step.
   - Accept `min_supported_app_build` and `release_notes` workflow inputs.
   - Set `cache-control: public, max-age=300` on `manifest.json` (5 min — clients must see new releases promptly without hammering GCS).
   - Keep existing `cache-control: public, max-age=604800, immutable` on SHA-pinned tarballs.
4. [ ] **Add auto-publish to staging on every `main` merge.** New workflow (or trigger added to existing one) that runs `publish-wasm.yaml` with `target = staging` on `push` to `main`. Production stays manual.
5. [ ] **Add regression test** in `Invoices.Tests` that iterates `Enum.GetValues<CurrencyCodeType>()` and asserts each value resolves through `CurrencyHelper` without throwing — guards against future enum/dictionary drift.
6. [ ] **Document the manifest contract** in `Tofu.Docs/Backend/Invoices/wasm-manifest.md` (new file) and link it from this plan. Mobile team will implement against that doc.
7. [ ] **Open PR.** Single PR covering the workflow + test + docs. Producer-side only.

### Phase 2 — iOS (mobile team, separate repo and PR)

Out of scope to implement here; included for completeness and because the docs need to land.

8. [ ] iOS: implement the resolution algorithm above. Cache bundle on disk, verify SHA, swap on next render.
9. [ ] iOS: bake a fallback bundle into the IPA at build time so first-launch / offline still works.
10. [ ] iOS: add a debug screen showing currently-loaded `bundleId`, `runtimeVersion`, manifest URL, last-fetched timestamp.

### Phase 3 — Verification

11. [ ] Backend: trigger production publish from `main`. Verify manifest at the production URL has the new `current` and the previous bundle moved to `history`.
12. [ ] iOS: ship the manifest-aware build to TestFlight; verify on a device with an `XCG` invoice that the preview now renders.
13. [ ] iOS: ship to App Store. After release, monitor for `XCG` crash reports — should drop to zero as users update.

## API / DTO changes

No breaking API changes. New file at a stable URL: `manifest.json`.

## Data / migration

None.

## Open questions

- [ ] Where does the manifest live publicly — direct GCS public URL, or fronted by a CDN / custom domain? Affects cache-control behavior and TLS posture.
- [ ] Initial `minSupportedAppBuild` value: what is the lowest iOS build number we still support, and is that the same as the current "minimum supported app version" gate enforced elsewhere in the BFF?
- [ ] Do we want a separate `canary` channel between `staging` and `production`, or is two channels enough? (Two is enough until we have a reason to add a third.)
- [ ] Should the iOS app refuse to load bundles older than its baked-in bundle (i.e., never downgrade except via explicit `rollbackTo`)? Recommended yes — prevents an attacker who can serve a stale manifest from forcing a known-vulnerable bundle.
- [ ] App Store policy: shipping a manifest-driven WASM bundle update is the same pattern as React Native CodePush / Expo EAS / Capacitor Live Updates and is widely accepted. Confirm the mobile team is comfortable with the precedent.
- [ ] How does the iOS app currently load the WASM bundle today? (Need this answer to know how invasive the Phase 2 change is — this question is for the mobile team.)

## Test plan

- **Unit tests (backend):**
  - `CurrencyHelperTests.AllCurrencyCodes_HaveSymbolAndName` — iterate enum, assert non-empty symbol/name for each. Catches the class of bug that produced this ticket.
  - `ManifestBuilderTests` — given an existing manifest and a new bundle, the builder produces a manifest where the new bundle is `current`, the old one is the head of `history`, history is capped at 10, and SHA/size are correct.
- **Integration tests (backend):**
  - Run the manifest-generator script end-to-end against a fake bucket (test fixture); diff the output against a golden file.
- **Manual verification (backend):**
  - Trigger `publish-wasm.yaml` against staging from a feature branch with `runtimeVersion = "1"` and `min_supported_app_build = 4200`. Inspect the resulting `manifest.json` in the staging bucket.
  - Trigger again from a later commit; confirm the previous `current` was demoted into `history`.
  - Edit the staging manifest manually to set `rollbackTo = <previous SHA>`; confirm it round-trips.
- **Manual verification (iOS, after Phase 2):**
  - Install a TestFlight build, render an `XCG` invoice → success, debug screen shows the new `bundleId`.
  - Install an older build whose `installed_app_build < minSupportedAppBuild` of `current` → app uses a `history` entry instead, no crash.
  - Set `rollbackTo` on the production manifest pointing at the previous SHA → next foreground fetch on iOS reverts the loaded bundle within the cache TTL.
