FS-768: ZIP Streaming Optimization — Implementation Plan
=========================================================

## Goal

Optimize invoice ZIP report generation to reduce memory usage and improve throughput. Currently the API and Worker paths buffer all PDFs in memory before creating a ZIP. This plan replaces that with true streaming, adds parallel PDF rendering, and pushes status filtering to the database.

## Background

Sergey's [PDF Export Service overview](overview.md) documents the current architecture and identifies streaming as the primary optimization direction. His [streaming memory optimization](streaming_memory_optimization.md) describes the three-level evolution from full buffering to true streaming with `System.IO.Pipelines`. The [PDF ZIP flow](PDF_ZIP_FLOW.md) specifies the streaming endpoint contracts, sequence diagrams, and design decisions (AllowSynchronousIO, non-seekable streams, chunked transfer).

This plan takes that design, scopes it to ZIP generation only (no Puppeteer pool changes), and adds two optimizations not covered in the original plan: parallel PDF rendering and server-side status filtering.

## What Changes and Why

### Problem 1: All PDFs buffered before zipping
Currently `GetInvoicesReportZip` loads every invoice, renders each PDF into `byte[]`, accumulates them in `List<(string, byte[])>`, builds a ZIP in `MemoryStream`, calls `.ToArray()`, and uploads. For 100 invoices at ~200KB each, peak memory is ~55MB.

**Solution:** Stream PDFs through `IAsyncEnumerable<PdfReportEntry>` into a `ZipArchive` opened in Create mode (supports non-seekable streams). Each PDF is rendered, written into a ZIP entry, and disposed before the next one starts.

- **API path:** write ZIP directly to `Response.Body` — zero buffering
- **Worker path:** write ZIP into a `System.IO.Pipe` (1MB backpressure) while GCS upload reads from the other end concurrently

### Problem 2: Sequential PDF rendering
Even with streaming, rendering PDFs one-at-a-time underutilizes the Puppeteer page pool (which supports `ProcessorCount` concurrent pages).

**Solution:** Fire all PDF rendering tasks concurrently, await results in order. The page pool's semaphore provides natural backpressure — no explicit batching needed.

### Problem 3: All invoices loaded, then filtered in memory
`GetAll` returns every invoice for the account, then the caller filters by `Paid`/`PaidByCard` status. For accounts with thousands of invoices, this transfers unnecessary data from Tofu.Invoices.

**Solution:** Add `repeated InvoiceStatus statuses` field to the `GetAllRequest` proto. MongoDB filters with `$in` at the query level. Backward compatible — empty list returns all.

### Problem 4: Redundant localization calls
Each flow fetches `GetLocalizationContext` twice — once for ZIP filename, once for PDF filename prefix.

**Solution:** `ZipReportMetadata` includes `PdfFileNamePrefix`. Fetched once, passed through.

## Execution Order

Changes span two repos with a dependency: Invoices.Backend consumes a NuGet package from Tofu.Invoices.Backend.

### Phase 1: Tofu.Invoices.Backend
1. Add `repeated InvoiceStatus statuses = 4` to `GetAllRequest` in proto
2. Thread `statuses` through: `SearchInvoicesQuery` → handler → `IInvoicesRepository.GetAll()` / `GetByClientId()`
3. Implement MongoDB `$in` filter in repository (no-op when empty)
4. Add mapping helper `MapToStatuses()` in gRPC service layer
5. Write functional tests: filter by single status, multiple statuses, no filter (backward compat)
6. Publish prerelease NuGet package

### Phase 2: Invoices.Backend — interfaces and plumbing
1. Add `HtmlToPdfStream()` to `IPdfCreatorService`, `FormPdfStreamForInvoice/Estimate()` to `IPdfService`
2. Create `IStreamingZipService` interface and `ZipEntry`/`PdfReportEntry`/`ZipReportMetadata` records
3. Extend `IReportsService` with streaming methods
4. Add `Statuses` to `GetAllInvoicesRequestModel`, update mapper

### Phase 3: Invoices.Backend — implementation
1. `PuppeteerPdfCreatorService` — extract `GeneratePdf<T>` generic, add `HtmlToPdfStream` (minimal — no pool/config changes)
2. `PdfService` — stream-returning overloads
3. `StreamingZipService` — `WriteZipToStreamAsync` (API path) + `CreateZipStream` via Pipe (Worker path)
4. `GoogleBlobStorage.StoreStreamingPipe` — concurrent pipe upload with `Task.WhenAll` + producer fault check
5. `ReportsService` — streaming methods with parallel rendering, single localization fetch, server-side status filter
6. Refactor buffer methods to delegate to streaming internally

### Phase 4: Invoices.Backend — API and Worker
1. Two new streaming endpoints in `ReportsController` with error handling (`HttpContext.Abort()`)
2. `ResultWrapperFilter` — `Response.HasStarted` guard
3. Worker handlers — replace buffer flow with streaming pipe flow
4. DI registration for `StreamingZipService`
5. Integration tests for streaming endpoints

## Scope Boundaries

**In scope:**
- Streaming ZIP generation (API + Worker)
- Parallel PDF rendering
- Server-side invoice status filtering
- Stream-returning PDF methods
- New streaming HTTP endpoints
- Streaming GCS upload

**Out of scope (separate work, per reviewer feedback on PR #1030):**
- Puppeteer page pool improvements (stale lock cleanup, page reset config, Chrome memory flags)
- Puppeteer benchmarks infrastructure
- Non-ZIP streaming optimizations (CSV reports, individual PDF endpoints, logo processing)
- See [streaming optimization backlog](streaming_optimization_backlog.md) for the full list

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| No explicit batch size for parallel rendering | Puppeteer page pool (capped at `ProcessorCount`) provides natural backpressure |
| `AllowSynchronousIO` per-request opt-in | `ZipArchive.Dispose()` writes central directory synchronously; no `IAsyncDisposable` before .NET 10 |
| No retry on `StoreStreamingPipe` | Pipe stream is non-seekable, cannot be replayed |
| `HttpContext.Abort()` on streaming failure | Headers already sent — cannot return error status code |
| `ZipReportMetadata` includes `PdfFileNamePrefix` | Avoids double `GetLocalizationContext` call per flow |
| Status filter is optional in proto | Backward compatible — existing callers get all invoices |

## Expected Memory Impact

| Path | Before | After |
|------|--------|-------|
| API streaming endpoint | N/A (new) | ~1 PDF stream at a time |
| Worker email report | Full ZIP in memory (~55MB for 100 invoices) | ~1MB pipe buffer |
| Buffer endpoint (`GET /reports/{type}`) | All PDFs + ZIP (~55MB) | One PDF at a time → MemoryStream (~30MB) |

See [streaming memory optimization](streaming_memory_optimization.md) for detailed comparisons.

## Related

- [PDF Export Service Overview](overview.md) — architecture, entry points, current state
- [PDF ZIP Streaming Flow](PDF_ZIP_FLOW.md) — endpoint contracts, sequence diagrams, design decisions
- [Streaming Memory Optimization](streaming_memory_optimization.md) — evolution from buffered to streaming
- [Streaming Optimization Backlog](streaming_optimization_backlog.md) — remaining optimization opportunities
