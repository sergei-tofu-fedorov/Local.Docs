# PDF Export Service Overview

## Purpose

Extract and optimize invoice PDF generation into a dedicated service.

**Goals:**
1. Move PDF generation logic out of Invoices.Backend into standalone service
2. Optimize memory usage using streams instead of buffering entire PDFs
3. Improve scalability and performance for high-volume PDF generation

---

## Current Implementation

### Technology Stack

| Component | Technology |
|-----------|------------|
| PDF Library | PuppeteerSharp v20.0.0 |
| Rendering | Headless Chromium |
| Platform | Linux (Chromium 128.0.6613.119) / macOS (Chrome) |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Invoices.Backend                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────┐ │
│  │ InvoicesController│   │ EstimatesController│   │ ReportsController  │ │
│  │ GET /invoices/   │   │ GET /estimates/  │   │ GET /reports/      │ │
│  │     {id}/pdf     │   │     {id}/pdf     │   │  stream/pdf_zip    │ │
│  └────────┬─────────┘   └────────┬─────────┘   └─────────┬───────────┘ │
│           │                      │                       │             │
│           └──────────────────────┼───────────────────────┘             │
│                                  ▼                                     │
│                    ┌──────────────────────────────┐                    │
│                    │ PdfService (Scoped)          │                    │
│                    │ - FormPdfStreamForInvoice()  │                    │
│                    │ - FormPdfStreamForEstimate() │                    │
│                    └───────────┬──────────────────┘                    │
│                                │                                       │
│           ┌────────────────────┼────────────────────┐                  │
│           ▼                    ▼                    ▼                  │
│  ┌─────────────────┐  ┌─────────────────────┐  ┌──────────────────┐   │
│  │ IHtmlBuilder    │  │ PuppeteerPdfCreator │  │ BlobPersistence  │   │
│  │ - Build HTML    │  │ Service (Singleton) │  │ Service          │   │
│  │ - Body/Header/  │  │ - Page pooling      │  │ - GCS storage    │   │
│  │   Footer        │  │ - Browser mgmt      │  │                  │   │
│  └─────────────────┘  └──────────┬──────────┘  └──────────────────┘   │
│                                  │                                     │
│                                  ▼                                     │
│                    ┌─────────────────────────┐                         │
│                    │ Headless Chromium       │                         │
│                    │ - Renders HTML          │                         │
│                    │ - Outputs PDF bytes     │                         │
│                    └─────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `Invoices.Implementation.Pdf/PuppeteerPdfCreatorService.cs` | Core PDF generation (Singleton) |
| `Invoices.Common/Services/Templates/PdfService.cs` | Orchestration layer (Scoped) |
| `Invoices.Core/Templates/IPdfCreatorService.cs` | Creator interface |
| `Invoices.Core/Templates/IPdfService.cs` | Service interface |
| `Invoices.Implementation.Services/Infrastructure/PdfBlobPersistenceService.cs` | GCS storage |

### API Entry Points

| Controller | Endpoint | Description |
|------------|----------|-------------|
| `V3/InvoicesController` | `GET /api/v3/invoices/pdf?invoiceJson=` | PDF from JSON payload |
| `V3/InvoicesController` | `POST /api/v3/invoices/pdf` | PDF from InvoiceDto body |
| `V1/InvoicesController` | `GET /api/invoices/{id}/pdf` | PDF by invoice ID |
| `EstimatesController` | `GET /api/estimates/{id}/pdf` | Estimate PDF by ID |
| `InvoiceGeneratorController` | `POST /api/invoice-generator/generate-pdf` | Anonymous PDF + GCS storage |
| `V3/EmailController` | `POST /api/v3/email/send` | PDF as email attachment |

### PDF Generation Flow

```
1. Controller receives request
        │
        ▼
2. PdfService.FormPdfStreamForInvoice(invoice, accountId, useLogo, ct)
        │
        ▼
3. IHtmlBuilder.BuildHtmlForInvoice()
   └── Fetches account data, logos, localization
   └── Returns (Body, Footer, Header, Params, TemplateSize)
        │
        ▼
4. PuppeteerPdfCreatorService.HtmlToPdfStream(body, footer, header, size, ct)
   └── Acquires page from pool (with retry/backoff)
   └── SetContentAsync() - renders HTML
   └── PdfStreamAsync() - generates PDF as stream
   └── Returns Stream
        │
        ▼
5. Controller returns File(stream, "application/pdf")
```

Note: `byte[]` variants (`FormPdfForInvoice`, `HtmlToPdf`) still exist for callers that need bytes (e.g., email attachments).

### Detailed Flow: Direct PDF Download

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  GET /api/invoices/{id}/pdf                                                     │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  InvoicesController.GetPdf()                                                    │
│  └── IInvoicesService.Get(id) → Fetch invoice from MongoDB                      │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  PdfService.FormPdfStreamForInvoice()                                            │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  HtmlBuilder.BuildHtmlForInvoice()                                              │
│  ├── IAccountsRepository.GetById() → Account data                               │
│  ├── ILogoService.Get() → Base64-encoded logo                                   │
│  ├── IPaymentsService.GetAuthenticatedTypes() → Payment methods                 │
│  ├── IWebLinkService.GetShortUrl() → QR code URL for footer                     │
│  ├── IEntityTemplateService.GetParams() → Template customization                │
│  ├── IRegionalLocalizationFactory.Get() → Currency/number formatting            │
│  ├── IContentsService.GetUrls() → Attachment URLs (strips GCS signed params)    │
│  └── IHtmlTemplateService.FillForInvoiceWithParam() → Final HTML                │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  PuppeteerPdfCreatorService.HtmlToPdfStream()                                    │
│  ├── Allocate page from pool (or create new, up to ProcessorCount)              │
│  ├── page.SetContentAsync(html) → Render HTML in Chromium                       │
│  ├── page.PdfStreamAsync(options) → Generate PDF as Stream                      │
│  │   └── Options: PrintBackground=true, DisplayHeaderFooter=true, Size=A4       │
│  └── Return page to pool (or dispose if usage >= 10)                            │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Results.File(stream, "application/pdf")                                        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Detailed Flow: Invoice Generator (Anonymous + GCS Storage)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  POST /api/invoice-generator/generate-pdf                                       │
│  └── Anonymous endpoint, no auth required                                       │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  InvoiceGeneratorService.Generate()                                             │
│  ├── IHtmlTemplateService.FillForInvoiceWithParam() → Generate HTML             │
│  ├── IPdfCreatorService.HtmlToPdf() → Create PDF bytes                          │
│  ├── IImageService.ConvertPdfToPngImage() → Create preview image                │
│  │                                                                              │
│  │  ┌─────────────────── GCS Upload ───────────────────┐                        │
│  │  │                                                  │                        │
│  ├──┼── IBlobStorage.Store(pdf, bucket, key)           │                        │
│  │  │   └── Bucket: invoice_generator (prod)           │                        │
│  │  │   └── ACL: PublicRead                            │                        │
│  │  │   └── Returns: MediaLink URL                     │                        │
│  │  │                                                  │                        │
│  └──┼── IBlobStorage.Store(image, bucket, key)         │                        │
│     │   └── Returns: MediaLink URL                     │                        │
│     └──────────────────────────────────────────────────┘                        │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Response: { PdfLink: "https://storage.googleapis.com/...",                     │
│              ImageLink: "https://storage.googleapis.com/..." }                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Detailed Flow: Email with PDF Attachment

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  POST /api/v3/email/send                                                        │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  EmailController.Send()                                                         │
│  ├── IInvoicesService.Get() → Fetch invoice                                     │
│  ├── IPdfService.FormPdfForInvoice() → Generate PDF bytes                       │
│  │                                                                              │
│  │  ┌─────────────── Async GCS Persistence ────────────┐                        │
│  │  │                                                  │                        │
│  ├──┼── IPdfBlobPersistenceService.Store()             │                        │
│  │  │   └── Queues to IOffloadQueue (background)       │                        │
│  │  │   └── Bucket: prod_invoices_stored_pdfs          │                        │
│  │  │   └── Key: {AccountId}/{EntityId}_{Guid}.pdf     │                        │
│  │  │   └── ACL: ProjectPrivate                        │                        │
│  │  └──────────────────────────────────────────────────┘                        │
│  │                                                                              │
│  └── IEmailService.Send(emailDto, pdfAttachment)                                │
│      └── Provider: SendGrid / Sendinblue                                        │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Email sent with PDF attachment + PDF stored in GCS (async)                     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Google Cloud Storage Integration

| Bucket | Environment | Purpose | ACL |
|--------|-------------|---------|-----|
| `prod_invoices_stored_pdfs` | Production | Email PDF archives | ProjectPrivate |
| `invoices_stored_pdfs` | Staging | Email PDF archives | ProjectPrivate |
| `invoice_generator` | Production | Anonymous generator PDFs | PublicRead |
| `invoice_generator_staging` | Staging | Anonymous generator PDFs | PublicRead |

**GCS Operations:**

```csharp
// GoogleBlobStorage with Polly resilience
var retryPolicy = Policy
    .Handle<GoogleApiException>(e =>
        e.HttpStatusCode is 429 or 503 or 502 or 504)
    .WaitAndRetryAsync(3, attempt => TimeSpan.FromSeconds(Math.Pow(2, attempt)));

// Store with public access
await _storage.UploadObjectAsync(bucket, key, contentType, stream,
    new UploadObjectOptions { PredefinedAcl = PredefinedObjectAcl.PublicRead });

// Generate signed URL (7-day expiry)
var signedUrl = _urlSigner.Sign(bucket, key, TimeSpan.FromDays(7));
```

**GCS URL Handling in HtmlBuilder:**

```csharp
// Strip signed URL parameters from GCS URLs for cleaner attachment display
private string StripGcsSignedParams(string url)
{
    if (url.Contains("storage.googleapis.com") && url.Contains("?"))
        return url.Split('?')[0];
    return url;
}
```

### Page Pooling Mechanism

`PuppeteerPdfCreatorService` implements sophisticated resource management:

```csharp
// Configuration
MaxLocked: Environment.ProcessorCount    // Max concurrent pages
MaxPageUsageCount: 10                    // Reuse count before disposal
BackOffDelay: 500ms                      // Retry delay
MaxRetries: 50                           // Max allocation attempts

// Data structures
ConcurrentDictionary<string, IPage> _pages      // Page pool
ConcurrentDictionary<string, int> _pageUsages   // Usage counters
ConcurrentDictionary<string, int> Locked        // Concurrency locks
```

**Page Lifecycle:**
1. Request arrives → Try to acquire unlocked page
2. If no page available → Create new (up to MaxLocked)
3. If at capacity → Retry with backoff
4. After use → Increment usage counter
5. If usage >= MaxPageUsageCount → Dispose page async

### Current Performance Characteristics

| Aspect | Current Behavior |
|--------|------------------|
| Memory (single PDF) | Stream-based via `PdfStreamAsync` — no full byte[] buffer |
| Memory (ZIP export) | True streaming to Response.Body (API) or Pipe (worker) — ~1MB buffer |
| Concurrency | Limited by `MaxLocked` (CPU count) |
| Browser | Single shared instance (Singleton) |
| Page reuse | Up to 10 times before disposal |
| Response (single PDF) | Streamed directly via `File(stream, "application/pdf")` |
| Response (ZIP export) | Streamed directly to Response.Body — no buffering |

### Batch Operations (Worker) — Streaming

| Handler | Purpose |
|---------|---------|
| `InvoicesPdfZipReportOperationHandler` | ZIP all account invoices (streaming) |
| `ClientInvoicesPdfZipReportOperationHandler` | ZIP client-specific invoices (streaming) |

Flow: Queue message → Stream PDFs via `IAsyncEnumerable` → ZIP via Pipe → GCS upload (concurrent) → Email link

Workers use `StreamingZipService.CreateZipStream()` + `IBlobStorage.StoreStreamingPipe()` for true streaming — ZIP creation and GCS upload happen concurrently with ~1MB pipe buffer.

### Storage

- **Bucket (prod)**: `prod_invoices_stored_pdfs`
- **Bucket (dev)**: `invoices_stored_pdfs`
- **Path format**: `{AccountPublicId}/{EntityId}_{Guid}.pdf`

---

## Target State

```
┌─────────────────────┐         ┌─────────────────────────┐
│ Invoices.Backend    │         │ PDF Export Service      │
├─────────────────────┤         ├─────────────────────────┤
│ Invoice API         │────────►│ Stream-based generation │
│ - Request PDF       │         │ - No full buffering     │
│ - Get stream back   │◄────────│ - Template rendering    │
└─────────────────────┘         │ - Direct stream output  │
                                └─────────────────────────┘
```

## Implemented Optimizations

### Stream-Based Generation ✅

**Before:**
```
1. Generate HTML
2. Render to PDF (buffer entire file as byte[])
3. Return byte[] to caller
4. Caller writes to response
```

**Current (implemented):**
```
1. Generate HTML
2. PdfStreamAsync() → returns Stream from Chromium
3. Controller returns File(stream, "application/pdf")
4. No byte[] buffering for download endpoints
```

### Streaming ZIP Export ✅

**Before:**
```
Generate all PDFs → accumulate in List<byte[]> → build ZIP in MemoryStream → upload/respond
```

**Current (implemented):**
```
API:    IAsyncEnumerable<PDF streams> → ZipArchive → Response.Body (direct)
Worker: IAsyncEnumerable<PDF streams> → ZipArchive → Pipe → GCS upload (concurrent)
```

See [Streaming Memory Optimization](streaming_memory_optimization.md) for details.

### Benefits (Measured)

| Aspect | Before | Current |
|--------|--------|---------|
| Memory (single PDF) | O(file size) as byte[] | Stream — no full buffer |
| Memory (ZIP export) | N × PDF + ZIP size | ~1MB pipe buffer (worker) or ~1 PDF (API) |
| Time to first byte | After full generation | Immediate (stream) |
| Concurrent PDFs | Limited by memory | Higher throughput |
| Large ZIP exports | Risk of OOM | Stable |

## Supported Export Types

| Type | Priority | Notes |
|------|----------|-------|
| Invoice PDF | High | Primary use case |
| Estimate PDF | Medium | Similar template |
| Receipt PDF | Medium | Payment confirmation |
| Report PDF | Low | Future consideration |

## Integration

### API Contract

```
POST /api/pdf/invoice/{invoiceId}
Accept: application/pdf

Response: Stream (application/pdf)
```

### Internal Communication

Options:
- **gRPC streaming** - Efficient binary streaming
- **HTTP chunked response** - Simpler, standard HTTP

---

## Optimization Options

### Option 1: Stream Response ✅ IMPLEMENTED

**Implemented** in `PuppeteerPdfCreatorService.HtmlToPdfStream()` and `PdfService.FormPdfStreamForInvoice/Estimate()`.

Both `byte[]` and `Stream` variants coexist via `GeneratePdf<T>` generic method:
- Stream variant: used by download endpoints and ZIP export
- byte[] variant: used by email attachment (needs full content for `Attachment`)

---

### Option 2: Background Generation with Polling/Webhook

**Goal**: Async PDF generation for large/batch operations.

**Flow:**
```
1. POST /pdf/invoice/{id}
   └── Returns: { "jobId": "abc-123", "status": "pending" }

2. Background worker generates PDF
   └── Stores in GCS

3. GET /pdf/jobs/{jobId}
   └── Returns: { "status": "completed", "url": "https://..." }

   OR webhook callback to client
```

**Pros:**
- API responds immediately
- No timeout issues for large PDFs
- Better for batch operations

**Cons:**
- More complex client integration
- Requires job tracking infrastructure
- Not suitable for immediate download UX

---

### Option 3: Dedicated PDF Microservice

**Goal**: Extract PDF generation to separate deployable service.

```
┌─────────────────────┐         ┌─────────────────────────┐
│ Invoices.Backend    │         │ Tofu.Pdf (New Service)  │
├─────────────────────┤   gRPC  ├─────────────────────────┤
│ - Invoice API       │────────►│ - PuppeteerPdfCreator   │
│ - Estimate API      │◄────────│ - Page pooling          │
│ - No Chromium dep   │  Stream │ - Chromium instance     │
└─────────────────────┘         │ - Independent scaling   │
                                └─────────────────────────┘
```

**Benefits:**
- Independent scaling (PDF-heavy load doesn't affect API)
- Chromium isolation (crashes don't affect main API)
- Specialized resource allocation (more memory for PDF service)
- Reusable by other services

**Implementation:**
- gRPC service with streaming response
- Kubernetes deployment with resource limits
- Health checks for Chromium status

---

### Option 4: Alternative PDF Library

**Goal**: Replace PuppeteerSharp with lighter alternative.

| Library | Pros | Cons |
|---------|------|------|
| **QuestPDF** | Native .NET, fast, no browser | No HTML rendering, code-based layout |
| **iTextSharp** | Mature, feature-rich | License cost, no HTML |
| **wkhtmltopdf** | HTML support, lighter than Chrome | Deprecated, security concerns |
| **Gotenberg** | Docker-based, API-first | External dependency, network latency |
| **WeasyPrint** | Python, good CSS support | Different runtime, integration overhead |

**Recommendation**: Keep PuppeteerSharp for HTML fidelity, but consider QuestPDF for simple templates.

---

### Option 5: Hybrid Caching Strategy

**Goal**: Cache generated PDFs to avoid regeneration.

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Request PDF  │────►│ Check Cache  │────►│ Cache Hit?   │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                 │
                     ┌───────────────────────────┼───────────────────┐
                     │ Yes                       │ No                │
                     ▼                           ▼                   │
              ┌──────────────┐           ┌──────────────┐           │
              │ Return from  │           │ Generate PDF │           │
              │ GCS/Redis    │           │ Store in cache│          │
              └──────────────┘           └──────────────┘           │
```

**Cache Key**: `pdf:{type}:{entityId}:{version}:{hash(template+data)}`

**Invalidation**:
- Invoice updated → Invalidate cache entry
- Template changed → Invalidate all for template
- TTL-based expiry as fallback

**Storage Options:**
- **GCS**: Already used, good for large files
- **Redis**: Fast, good for frequently accessed
- **CDN**: For public/shared PDFs

---

### Option 6: Page Pool Optimization

**Goal**: Improve current implementation without architectural changes.

**Improvements:**

1. **Warm page pool on startup**
   ```csharp
   // Pre-create pages during app initialization
   await pdfService.WarmPool(count: Environment.ProcessorCount);
   ```

2. **Dynamic pool sizing**
   ```csharp
   // Scale pool based on load
   if (queueDepth > threshold)
       await ExpandPool(additionalPages: 2);
   ```

3. **Page health checks**
   ```csharp
   // Proactively replace unhealthy pages
   if (!await page.IsHealthy())
       await ReplacePage(pageId);
   ```

4. **Metrics & alerts**
   - Track page acquisition time
   - Alert on high retry counts
   - Monitor memory per page

---

## Recommendation

**Completed:**
1. ~~Option 1: Stream responses~~ ✅ Implemented (`PdfStreamAsync`, `FormPdfStreamFor*`)

**Short-term (Quick wins):**
1. Option 5: Add caching for repeated PDF requests
2. Option 6: Optimize page pool settings

**Medium-term:**
1. Option 2: Background generation for batch/large PDFs

**Long-term:**
1. Option 3: Dedicated microservice when scale requires

---

## Open Questions

- What is typical PDF size? (affects streaming benefit)
- How often are same PDFs requested? (affects caching ROI)
- What's the peak concurrent PDF requests? (affects pool sizing)
- Are there PDF generation failures in production? (affects error handling priority)
- Is there budget for separate service deployment? (affects Option 3 timeline)

---

## Appendix: Web-Sourced Optimization Techniques

*External research on PuppeteerSharp PDF generation optimizations.*

### Benchmark Data

| Tool | Avg Time (10 PDFs) | Notes |
|------|-------------------|-------|
| PuppeteerSharp | 7.6s | Fastest, best CSS compliance |
| Puppeteer (Node.js) | 7.8s | Similar performance |
| wkhtmltopdf | 19.2s | ~3x slower, deprecated |

*Source: [PDF Generators Benchmark](https://www.hardkoded.com/blogs/pdf-generators-benchmark)*

### Concurrency Management

- **CPU-bound**: `page.pdf()` uses 100% of one CPU core during generation
- **Recommended limit**: `Environment.ProcessorCount - 1` concurrent PDFs
- **Page reuse**: Creating new pages costs 20-30ms; reuse pages when possible
- **Queue depth**: Use in-memory or Redis queue to track in-flight requests

### Static Asset Optimization

```csharp
// Use network interception instead of HTTP server
await page.SetRequestInterceptionAsync(true);
page.Request += async (sender, e) =>
{
    if (e.Request.ResourceType == ResourceType.StyleSheet)
    {
        var css = await File.ReadAllBytesAsync(localCssPath);
        await e.Request.RespondAsync(new ResponseData
        {
            Body = css,
            Headers = new Dictionary<string, object>
            {
                ["Cache-Control"] = "max-age=600"
            }
        });
    }
    else
    {
        await e.Request.ContinueAsync();
    }
};
```

**Benefits:**
- Eliminates HTTP server dependency
- Prevents CORS issues
- Enables aggressive caching

### Timeout and Error Handling

```csharp
// Add explicit timeouts to all operations
var pdfTask = page.PdfDataAsync(options);
var timeoutTask = Task.Delay(TimeSpan.FromSeconds(30));

var completed = await Task.WhenAny(pdfTask, timeoutTask);
if (completed == timeoutTask)
{
    // Force cleanup and retry
    await ForceClosePage(page);
    throw new TimeoutException("PDF generation timed out");
}
```

**Key practices:**
- Wrap `page.close()` with timeout (no native timeout support)
- Use `Promise.race()` pattern for forced timeouts
- Implement retry logic that accounts for in-flight requests

### Browser Version Considerations

| Chrome Version | PDF Time | Notes |
|----------------|----------|-------|
| Chrome 76 | <1s | Optimal performance |
| Chrome 77 | ~7s | Significant regression |
| Chrome 128+ | Varies | Test before upgrading |

**Recommendation:** Pin Chromium version in production; test performance before upgrades.

### Rendering Wait Strategies

```csharp
// Allow fonts/icons to load before PDF generation
await page.SetContentAsync(html);
await page.WaitForNetworkIdleAsync(new WaitForNetworkIdleOptions
{
    IdleTime = 500,
    Timeout = 5000
});
// OR explicit delay for complex content
await Task.Delay(1000);
var pdf = await page.PdfDataAsync(options);
```

**When needed:**
- Font Awesome or icon fonts
- Web fonts loading via @font-face
- JavaScript-rendered content

### Large Document Strategy

For documents >50 pages:

1. **Split and merge**: Generate smaller PDFs, combine with PDF library
2. **Incremental streaming**: Use `page.createPDFStream()` (Node.js) / investigate `PdfStreamAsync`
3. **Background processing**: Queue large jobs, notify on completion

### Hardware Scaling

| Scenario | Server Spec | Result |
|----------|-------------|--------|
| 20-page PDF | High-CPU VM | 250-500ms |
| Same PDF | Low-spec VM | 2-5s |

**Key insight:** PDF generation is CPU-bound; vertical scaling (faster CPU) helps more than horizontal scaling for individual requests.

### Production Results

Organizations report achieving:
- **10,000 PDFs/day** with p95 latency of **365ms** using AWS Lambda
- Browser warm-up reduces first-request latency from 14s to 8s

### Quick Wins Checklist

- [ ] Pin Chromium version, benchmark before upgrades
- [ ] Limit concurrency to `CPU cores - 1`
- [ ] Warm browser pool on startup
- [ ] Add request interception for static assets
- [ ] Set explicit timeouts on all operations
- [ ] Add 500ms-1s wait for font-heavy templates
- [ ] Monitor page acquisition time and retry counts

### External Resources

- [Optimizing Puppeteer PDF generation](https://www.codepasta.com/2024/04/19/optimizing-puppeteer-pdf-generation)
- [PDF Generators Benchmark](https://www.hardkoded.com/blogs/pdf-generators-benchmark)
- [Puppeteer slow PDF issue #3847](https://github.com/puppeteer/puppeteer/issues/3847)

---

## Related Documentation

- [Invoices.Backend Service](../../Backend/Services/Invoices.Backend/) - Main API
- [Worker Operations](../../Backend/Services/Invoices.Backend/Worker.md) - Background jobs
