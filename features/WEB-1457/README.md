# WEB-1457: Puppeteer PDF Page Pool — Locking and Concurrency Issues

## Problem

The `PuppeteerPdfCreatorService` manages a pool of Chromium pages for PDF generation.
Two issues were identified:

1. **Excess requests fail instead of waiting.** `AllocatePage` uses a retry/back-off
   loop (`MaxRetries` × `BackOffDelay`) to find a free page. When all pages are
   busy the caller polls the pool, and if no page becomes available within the
   retry budget the call throws `InvalidOperationException`.
   Example: with `MaxLocked = 2`, if 3 requests arrive simultaneously, 2 acquire
   pages and the 3rd enters the retry loop. If the first 2 renders take longer
   than `MaxRetries × BackOffDelay` (default 50 × 500 ms = 25 s), the 3rd request
   fails — even though a page would have been available moments later.
   The request should wait until a page is actually released, not poll and give up.

2. **No global concurrency limit on PDF generation.** `ReportsService` applied its
   own `SemaphoreSlim(ProcessorCount)` per-call, but other callers of
   `IPdfCreatorService` (single-invoice export, preview, etc.) had no throttle.
   Under load, many concurrent `HtmlToPdf` calls competed for the same page pool,
   amplifying the retry/back-off pressure and increasing memory usage from
   parallel Chromium rendering.

## Root Causes for Pages Stuck in Locked State

Investigation of `AllocatePage`/`ReleasePage` revealed several scenarios where a
page can remain in the `Locked` dictionary permanently:

1. **`TryAdd` race in `AllocatePage` (fixed).** Previously
   `if (Locked.TryAdd(pageId, 1) && PageCache.TryAdd(pageId, page))` — if
   `Locked.TryAdd` succeeded but `PageCache.TryAdd` failed (duplicate key from a
   concurrent call), the code fell through without cleaning up `Locked`. The page
   ID stayed locked but was never returned to the caller, so `ReleasePage` was
   never called. The two `TryAdd` calls are now checked independently: on a
   `Locked` collision the new page is closed and the loop retries; on a
   `PageCache` collision `Locked` is unwound via `TryRemove` and the page is
   closed before retrying.

2. **`AllocatePage` returns but assignment to `page` is interrupted.** `AllocatePage`
   adds the page to `Locked` internally before returning. If an exception occurs
   after the method returns but before `page` is assigned (e.g.
   `ThreadAbortException` on older runtimes), the `finally` block sees `page` as
   `null` and skips `ReleasePage`. The entry remains in `Locked`.

3. **Chromium page crash during release.** If the underlying renderer crashes,
   accessing `page.MainFrame.Id` inside `ReleasePage` can throw. The exception
   bubbles out of the `finally` block, preventing `Locked.TryRemove` from executing.

The new `_concurrencyGate` semaphore mitigates Scenarios 2 and 3 by ensuring only
`MaxLocked` callers enter the allocate → render → release block at a time, so pool
contention drops dramatically.

## Changes

### PuppeteerPdfCreatorService

Added a `_concurrencyGate` semaphore (`SemaphoreSlim`) initialized from
`Config.MaxLocked` (defaults to `Environment.ProcessorCount`).

The gate wraps the entire page-allocate → render → release block inside `HtmlToPdf`:

```
await _concurrencyGate.WaitAsync(ct);   // ← wait before allocating a page
try
{
    page = await AllocatePage(…);
    // … render PDF …
}
finally
{
    ReleasePage(page, …);
    _concurrencyGate.Release();          // ← always released
}
```

This guarantees that at most `MaxLocked` PDF renders execute concurrently across
all callers, and the semaphore is always released even if rendering throws.

### IPdfCreatorService / IPdfService

Both interfaces now expose `int MaxConcurrentRenders { get; }`. `PdfService`
forwards the value from the underlying creator. This lets callers that produce
batches (e.g. `ReportsService`) size their work to match the central gate instead
of hard-coding `Environment.ProcessorCount` or piling up tasks that all block on
the semaphore.

### ReportsService

Bulk invoice PDF generation no longer materializes one `Task` per invoice up front
behind a local `SemaphoreSlim(ProcessorCount)`. Instead it streams through the
input enumerator with a sliding window of size `_pdfService.MaxConcurrentRenders`:

- Seed `MaxConcurrentRenders` tasks.
- On each `Task.WhenAny` completion, yield the result and start the next invoice.

The local semaphore is gone — concurrency is bounded by the central
`_concurrencyGate` plus the explicit window of in-flight tasks, which also avoids
allocating a `Task` for every invoice in large batches.
