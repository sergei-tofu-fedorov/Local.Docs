# FS-976 — QA test plan for the WASM bundle rollout

What QA needs to validate when a fresh `Invoices.Shared.HtmlPreview` bundle (from a backend commit newer than the one currently bundled in iOS) gets shipped via the manifest. Scoped to the **breaking-change risks** identified by the master-vs-deployed-WASM diff, not full regression of the preview pipeline.

**Reference:** the deployed bundle in `gs://wasm_shared/_latest` is from backend commit `b24f0962` (2025-08-07). Anything master-since carries the changes below. Source-of-truth diff is in this repo via `git log b24f09627d…master -- Src/Invoices.Shared.HtmlPreview Src/Tofu.HtmlTemplates Src/Invoices.Core/Models`.

## Targets

Each scenario must be verified on **both** consumers:

| Consumer | How |
|---|---|
| iOS (TestFlight build that loads the new bundle via the manifest) | Open invoice / estimate detail, generate preview |
| Web frontend (already auto-loads WASM from CDN) | Open the corresponding screen in the web app |

If a scenario produces different output between the two — that is itself a finding worth filing.

## 1. Visual rendering — paid-invoice footer (highest risk)

The footer rendering logic in `Tofu.HtmlTemplates/TemplateHelpers.cs` changed between Mar 5 and Mar 18, 2026. Three cases that produce **visibly different output** vs. the currently-bundled WASM:

| Invoice setup | Old bundle | New bundle | QA test |
|---|---|---|---|
| Status = `PaidByCard`, has `ReceivedPayments` | "Payments" line **hidden** | "Payments" line shows the sum | Open one. Confirm "Payments: $X.XX" line is now visible and equals sum of received payments. |
| Status = `Paid`, has `ReceivedPayments` | "Balance Due" shows `entity.TotalDue` (could be non-zero in stale data) | "Balance Due" shows `$0.00` | Open one. Confirm "Balance Due: 0.00". |
| Status = `Paid` or `PaidByCard`, no `ReceivedPayments` | Both lines hidden | Both lines hidden (unchanged) | Confirm nothing weird appears. |
| Status = `NotPaid` (or any other), regardless of payments | Unchanged | Unchanged | Confirm nothing changed visually for non-paid invoices. |

Find at least one invoice of each shape. The dev-2 account has plenty of paid invoices with received payments — pull from there.

## 2. Currencies — XCG and other newer codes

The trigger for FS-976 was missing `XCG` (Caribbean guilder, replaced `ANG` in 2025-03). New bundle adds `XCG` and `ZWG` (Zimbabwe Gold).

- Set the account currency to **`XCG`** → preview must render without crashing, with the correct symbol/name.
- Set the account currency to **`ZWG`** → same.
- Sanity sweep: `USD`, `EUR`, `GBP`, `JPY` continue to render exactly as before.
- An **invoice with no explicit currency** (the model field is null) — must still render using the account currency fallback.

## 3. Line items with units (`UnitType` field)

The `UnitType` field on `InvoiceItemDto` switched from int-encoded to string-encoded on the wire. iOS and web continue to work because `System.Text.Json` accepts both — but worth verifying.

- Invoice with line items that have `UnitType = Hours` → preview shows the unit ("hours") next to the item.
- Invoice with line items that have `UnitType = Days` → same with "days".
- Invoice with line items that have `UnitType = None` → no unit shown, no garbage text.
- iOS specifically: pin one device that's still running an **older build** with the previous bundle baked in, point it at the new manifest, confirm both the int (legacy) and string (new) wire formats work — i.e., loading the new bundle doesn't break older iOS builds. (Or the reverse: load the **old** bundle on the new manifest path; should still work because the manifest is purely additive.)

## 4. Additive `Invoice` fields — no rendering impact

The model added `JobId`, `EstimateId`, `Source` (all optional). These are **not** rendered anywhere by the preview. If you spot any of them leaking into the rendered HTML/PDF, that's a bug — file it.

## 5. Filename / disposition unchanged

For PDF downloads from the iOS app's "Share" / "Save PDF" path: the filename should still be `Invoice_<number>.pdf` (or whatever the account locale dictates). The bundle change does not touch filename logic; if QA sees a different name, that's an unexpected regression.

## 6. iOS snapshot test refresh (mobile team)

iOS has a `InvoicesSnapshotTests` target that pixel-compares previews against committed snapshots. The visual changes in section 1 **will fail those snapshots**. Mobile team needs to regenerate snapshots after pulling the new bundle. Not a QA action — a heads-up.

## 7. Manifest mechanics (after Phase 1 ships)

Once the manifest publishing is live (Phase 1 of FS-976):

- Verify `https://wasm-shared.tofu.example/manifest.json` (or whatever the agreed URL is) returns valid JSON with the expected schema.
- Verify the SHA in `current.sha256` matches the SHA256 of the tarball at `current.url` (download both, compare).
- Verify cache headers: manifest has `cache-control: max-age=300` (5 min), tarballs have `max-age=604800, immutable`.
- Verify the previous `current` was demoted to head of `history` after a publish.
- Set `rollbackTo` to the previous bundleId in staging → fetch manifest → confirm iOS picks up the rollback within the cache TTL (≤5 min).

## What QA does NOT need to test

- Internal calculation correctness — `InvoiceItem.GetItemTotalAmount` was refactored to call `MoneyHelper.CalculateItemTotal` but produces identical totals (same multiplication, same `RoundCurrency(MidpointRounding.ToEven)`). Covered by backend unit tests.
- DTO wire compatibility for hypothetical third-party clients — there are no external consumers of `Api.Contracts.cs` outside the iOS bundle.
- Performance — the changes do not add allocations or I/O in the rendering path.

## Sign-off criteria

- All scenarios in §1–§5 pass on iOS (TestFlight build with new bundle) AND on web.
- §6 confirmed by mobile team (snapshots refreshed and committed).
- §7 confirmed by backend (manifest deploys cleanly to staging at minimum, production after).

If any §1 case shows the *old* footer behaviour, the bundle didn't actually swap — investigate the iOS resolution algorithm before re-testing.
