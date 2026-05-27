# Streaming Optimization Backlog

## Overview

This document tracks opportunities for streaming optimization across the codebase to reduce memory allocations. The PDF ZIP report streaming has already been implemented (see `streaming_memory_optimization.md`). The items below are candidates for future optimization.

---

## Priority Legend

| Priority | Description |
|----------|-------------|
| HIGH | Large memory impact, frequently used code paths |
| MEDIUM | Moderate impact or less frequent usage |
| LOW | Minor optimization, low priority |

---

## HIGH PRIORITY

### 1. CSV Report Generation

**Location:** `Invoices.Common/Services/Reports/ReportsService.cs:159-167, 298-304`

**Current Pattern:**
```csharp
using var ms = new MemoryStream();
await GenerateCsv(ms, headerNames, invoices, ct);
return new Report
{
    Payload = ms.ToArray(),  // Full allocation
    ResponseContentType = "text/csv"
};
```

**Issue:** CSV reports are fully buffered to memory via `ToArray()` before being returned. For large reports with thousands of invoices, this creates significant memory pressure.

**Proposed Solution:**
- Modify `Report` class to support `Stream` payload
- Stream CSV directly to HTTP response without `ToArray()` conversion
- Consider chunked transfer encoding for large exports

**Estimated Impact:** High for accounts with many invoices (1000+ rows)

---

### 2. File Upload Processing

**Locations:**
- `Invoices.Api/Extensions/HttpRequestExtensions.cs:34-44`
- `Invoices.Api/Controllers/V1/EmailController.cs:61-66`

**Current Pattern:**
```csharp
await using var memoryStream = new MemoryStream();
await formFile.OpenReadStream().CopyToAsync(memoryStream, ct);
return memoryStream.ToArray();  // Full file buffered
```

**Issue:** Uploaded files are fully buffered to memory instead of streaming directly to the email service or storage.

**Proposed Solution:**
- Modify email attachment API to accept `Stream` instead of `byte[]`
- Pass `formFile.OpenReadStream()` directly without buffering
- Update `IEmailService` interface to support stream-based attachments

**Estimated Impact:** High for large file attachments (>1MB)

---

### 3. GCS Blob Download

**Location:** `Invoices.Implementation.Services/BlobStorage/GoogleBlobStorage.cs:98-102`

**Current Pattern:**
```csharp
await using var stream = new MemoryStream();
var downloadedObject = await _storageClient.DownloadObjectAsync(
    bucketName, name, stream, cancellationToken: ct);
return (stream.ToArray(), downloadedObject.ContentType);  // Full buffering
```

**Issue:** All downloads are fully buffered to memory before being returned to callers.

**Proposed Solution:**
- Add new method `DownloadStream()` returning `Stream` instead of `byte[]`
- Let callers decide whether to buffer based on their needs
- Keep existing method for backwards compatibility but mark as legacy

**Interface Change:**
```csharp
// New method
Task<(Stream Content, string ContentType)> DownloadStream(
    string bucketName, string name, CancellationToken ct);
```

**Estimated Impact:** High for large blob downloads

---

## MEDIUM PRIORITY

### 4. Report Payload Property ✅ DONE

**Location:** `Invoices.Core/Reports/Report.cs`

**Resolution:** `Report` now supports both `byte[] Payload` (init-only) and `MemoryStream? PayloadStream` (init-only). Accessing `Payload` when `PayloadStream` was set throws `InvalidOperationException` — prevents silent OOM from accidental materialization. Callers use `HasStreamPayload` to check which form is available.

---

### 5. Logo Base64 Encoding

**Location:** `Invoices.Common/Services/InvoiceGenerator/InvoiceGeneratorService.cs:84`

**Current Pattern:**
```csharp
request.Logo = Convert.ToBase64String(resizedStream.ToArray());
```

**Issue:** Stream converted to `byte[]` for Base64 encoding, causing unnecessary allocation.

**Proposed Solution:**
- Use `resizedStream.GetBuffer()` if stream length matches buffer size
- Or implement stream-to-Base64 without full materialization
- Consider `Microsoft.Toolkit.HighPerformance` for `ReadOnlySequence<byte>` support

**Estimated Impact:** Low-Medium - logos are typically small (<500KB)

---

### 6. Logo Image Processing

**Location:** `Invoices.Common/Services/Images/LogoService.cs:41-47`

**Current Pattern:**
```csharp
using var destination = new MemoryStream();
_imageService.ConvertToWebPAndResize(fileData.Span, destination);
var externalUrl = await _blobStorage.Store(LogoBucketName, logoName,
    "image/webp", destination, ...);
```

**Issue:** Intermediate `MemoryStream` used for image conversion before storage.

**Proposed Solution:**
- Use `StoreStream()` with pipe-based approach if image conversion can write to non-seekable stream
- Otherwise, this may be acceptable given logo size limits

**Estimated Impact:** Low-Medium - bounded by logo size limits

---

### 7. Response Logging Middleware

**Location:** `Invoices.Api/Middleware/RequestLoggingMiddleware.cs:152-162`

**Current Pattern:**
```csharp
await using var responseBodyStream = new MemoryStream();
context.Response.Body = responseBodyStream;
await _next(context);

responseBodyStream.Seek(0, SeekOrigin.Begin);
var responseBodyText = await reader.ReadToEndAsync();
```

**Issue:** ALL response bodies are buffered to memory for logging, defeating streaming benefits.

**Current Mitigations:**
- PDF paths are already skipped (lines 143-145)

**Proposed Solution:**
- Add content length threshold (e.g., skip logging for responses >1MB)
- Add content type filtering (skip binary content types)
- Consider sampling in non-production environments

```csharp
// Skip large responses
if (context.Response.ContentLength > 1_000_000)
{
    await _next(context);
    return;
}
```

**Estimated Impact:** Medium - affects all API responses

---

## LOW PRIORITY

### 8. ToolsController PDF Generation

**Location:** `Invoices.Api/Controllers/ToolsController.cs:108`

**Current Pattern:**
```csharp
var pdf = await _pdfCreatorService.HtmlToPdf(...);  // Returns byte[]
```

**Issue:** Uses `byte[]` variant instead of stream.

**Proposed Solution:** Use `HtmlToPdfStream()` if endpoint is frequently called.

**Estimated Impact:** Low - tool endpoint, infrequent usage

---

## ALREADY OPTIMIZED

These areas have been optimized with true streaming:

| Component | File | Status |
|-----------|------|--------|
| ZIP Creation (API) | `StreamingZipService.WriteZipToStreamAsync()` | Direct write to Response.Body |
| ZIP Creation (Worker) | `StreamingZipService.CreateZipStream()` | Pipe with 1MB buffer |
| PDF ZIP Reports | `InvoicesPdfZipReportOperationHandler.cs` | Full streaming pipeline |
| Client PDF ZIP | `ClientInvoicesPdfZipReportOperationHandler.cs` | Full streaming pipeline |
| PDF Service | `PdfService.cs` | Has `FormPdfStreamForInvoice/Estimate()` |
| PDF Creator | `PuppeteerPdfCreatorService.cs` | Has `HtmlToPdfStream()` via `PdfStreamAsync` |
| GCS Upload | `GoogleBlobStorage.StoreStreamingPipe()` | Concurrent pipe upload |
| Report Payload | `Report.cs` | Separate `Payload` / `PayloadStream` with safety guard |
| Buffered ZIP methods | `ReportsService.cs` | Delegate to streaming path (no duplicate logic) |

---

## Implementation Notes

### Dependencies for Streaming

```xml
<PackageReference Include="System.IO.Pipelines" Version="8.0.0" />
```

ZIP streaming uses built-in `System.IO.Compression.ZipArchive` (Create mode, non-seekable stream support since .NET Core 2.0). No third-party ZIP library needed.

### Pattern for Streaming Responses

```csharp
// In controller
[HttpGet("export")]
public async Task<IActionResult> ExportCsv(CancellationToken ct)
{
    var stream = await _reportsService.GenerateCsvStream(accountId, ct);
    return File(stream, "text/csv", "export.csv");
}
```

### Pattern for Stream-Based Storage

```csharp
// Producer-consumer with Pipes
var (readStream, producerTask) = CreateStreamingContent(data, ct);
await _blobStorage.StoreStreamingPipe(bucket, name, contentType,
    readStream, producerTask, control, cache, ct);
```

---

## Future: PDF Service Extraction

When moving PDF generation to a separate service, streaming remains possible with no breaking changes to BFF endpoints.

### Target Architecture

```
┌──────────┐      ┌─────────────────────┐      ┌─────────────────┐
│  Client  │      │   BFF (existing)    │      │   PDF Service   │
│          │      │                     │      │                 │
│  GET ────┼─────►│  Same endpoints     │      │                 │
│  /pdf    │      │         │           │      │                 │
│          │      │         ▼           │      │                 │
│          │      │  HttpClient.Get ────┼─────►│  Generate PDF   │
│          │      │  (ResponseHeaders   │      │       │         │
│          │      │   Read)             │      │       ▼         │
│          │◄─────┼─────────────────────┼──────┼─ Stream bytes   │
│  Stream  │      │  CopyToAsync        │      │                 │
│  bytes   │      │  (pass-through)     │      │                 │
└──────────┘      └─────────────────────┘      └─────────────────┘
                        No buffering!
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Protocol | HTTP (not gRPC) | Simpler, native streaming support |
| BFF role | Pass-through proxy | No breaking changes to client API |
| ZIP creation | Worker (not PDF Service) | Worker controls storage, PDF Service stays stateless |

### BFF Endpoint Pattern (No Breaking Change)

```csharp
[HttpGet("invoices/{id}/pdf")]  // Same endpoint
public async Task GetInvoicePdf(string id, CancellationToken ct)
{
    // Stream from PDF Service directly to client
    using var response = await _pdfServiceClient.GetAsync(
        $"internal/invoices/{id}/pdf",
        HttpCompletionOption.ResponseHeadersRead,  // Key: Don't buffer!
        ct);

    Response.ContentType = "application/pdf";
    Response.StatusCode = (int)response.StatusCode;

    // Pass-through stream - no buffering in BFF
    await using var stream = await response.Content.ReadAsStreamAsync(ct);
    await stream.CopyToAsync(Response.Body, ct);
}
```

### Worker ZIP Report Pattern

```csharp
public async Task Handle(Operation operation, CancellationToken ct)
{
    // Stream PDFs from PDF Service via HTTP
    var pdfEntries = StreamPdfsFromService(operation.AccountId, ct);

    // Existing streaming ZIP code - no changes
    var zipEntries = ConvertToZipEntries(pdfEntries);
    var (zipStream, producerTask) = _streamingZipService.CreateZipStream(zipEntries, ct);

    // Existing GCS upload - no changes
    var url = await _blobStorage.StoreStreamingPipe(...);
}

private async IAsyncEnumerable<PdfReportEntry> StreamPdfsFromService(
    string accountId, [EnumeratorCancellation] CancellationToken ct)
{
    var invoices = await _invoicesClient.GetPaidInvoices(accountId, ct);

    foreach (var invoice in invoices)
    {
        // Stream each PDF from PDF Service
        var response = await _pdfServiceClient.GetAsync(
            $"internal/invoices/{invoice.Id}/pdf",
            HttpCompletionOption.ResponseHeadersRead,
            ct);

        var pdfStream = await response.Content.ReadAsStreamAsync(ct);
        yield return new PdfReportEntry($"{invoice.Number}.pdf", pdfStream);
    }
}
```

### PDF Service Internal Endpoint

```csharp
[ApiController]
[Route("internal")]
public class InternalPdfController : ControllerBase
{
    [HttpGet("invoices/{id}/pdf")]
    public async Task GetInvoicePdf(string id, CancellationToken ct)
    {
        var invoice = await _invoicesRepository.GetById(id, ct);
        var html = await _templateService.RenderInvoice(invoice, ct);

        Response.ContentType = "application/pdf";

        // Stream PDF directly to response
        await using var pdfStream = await _pdfCreator.HtmlToPdfStream(html, ct);
        await pdfStream.CopyToAsync(Response.Body, ct);
    }
}
```

### Memory Comparison

| Architecture | Memory per ZIP Report |
|--------------|----------------------|
| Current (monolith) | ~1MB pipe buffer |
| Separate PDF Service | ~1 PDF + ~1MB pipe ≈ 2-3MB |

### Migration Checklist

- [ ] Create PDF Service with internal endpoints
- [ ] Add `HttpClient` for PDF Service in Worker
- [ ] Update Worker handlers to use `StreamPdfsFromService()`
- [ ] Update BFF controllers to proxy requests
- [ ] Keep `StreamingZipService` and `StoreStreamingPipe` unchanged
- [ ] No changes to client-facing API contracts

### Components That Stay Unchanged

| Component | Location | Reason |
|-----------|----------|--------|
| `StreamingZipService` | Invoices.Common | Works with any `IAsyncEnumerable<ZipEntry>` |
| `StoreStreamingPipe` | GoogleBlobStorage | Works with any pipe stream |
| Client API contracts | BFF | BFF proxies transparently |
| Email notifications | Worker | Just sends URL, no change |

---

## Related Documentation

- [Streaming Memory Optimization](streaming_memory_optimization.md) - Current implementation
- [PDF Export Service Overview](overview.md) - Architecture overview

---

## Change Log

| Date | Change |
|------|--------|
| 2024-01 | Initial backlog created from codebase analysis |
