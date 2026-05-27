# PDF ZIP Report - Streaming Memory Optimization

## Problem Statement

The PDF ZIP report generation originally accumulated all PDFs in memory before creating the ZIP archive. For accounts with many invoices, this caused excessive memory usage.

## Evolution of Solutions

### Level 1: Original (High Memory)
```
PDF 1 byte[] ─┐
PDF 2 byte[] ─┼─→ List<byte[]> ─→ MemoryStream ─→ ToArray() ─→ Upload
PDF N byte[] ─┘
              All held in memory
```
**Memory**: N × PDF + 2 × ZIP

### Level 2: Stream to MemoryStream (Medium Memory)
```
PDF 1 Stream ─→ ZIP entry ─→ (disposed)
PDF 2 Stream ─→ ZIP entry ─→ (disposed)
PDF N Stream ─→ ZIP entry ─→ MemoryStream ─→ Upload
                                  ZIP buffer
```
**Memory**: ZIP size only (no PDF accumulation)

### Level 3: True Streaming (Minimal Memory) ✓ Current

Two streaming paths depending on the consumer:

**API path — direct to HTTP response (no pipe needed):**
```
PDF 1 Stream ──┐
PDF 2 Stream ──┼─→ ZipArchive ─→ Response.Body (direct write)
PDF N Stream ──┘
```
**Memory**: ~1 PDF stream at a time

**Worker path — pipe to GCS upload (concurrent producer-consumer):**
```
PDF 1 Stream ──┐
PDF 2 Stream ──┼─→ ZipArchive ─→ Pipe ─→ GCS Upload (concurrent)
PDF N Stream ──┘         │                         │
                    Producer              Consumer (concurrent)
```
**Memory**: ~1MB pipe buffer only

---

## Current Implementation: True Streaming

Uses built-in `System.IO.Compression.ZipArchive` (Create mode supports non-seekable streams since .NET Core 2.0) and `System.IO.Pipelines` for the worker/GCS path.

### Architecture

**API streaming path** — writes ZIP directly to `Response.Body`, no intermediate buffering:
```
┌─────────────────────────────────────────────────────────────────────────┐
│                     API STREAMING PIPELINE                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ReportsService                    StreamingZipService                  │
│  ┌────────────────┐               ┌─────────────────────┐               │
│  │ StreamInvoice  │               │                     │               │
│  │ Pdfs()         │──────────────→│ WriteZipToStream    │               │
│  │                │  IAsyncEnum   │ Async() (static)    │               │
│  │ yields PDF     │  <PdfEntry>   │                     │               │
│  │ streams        │               │ ZipArchive (Create) │               │
│  └────────────────┘               └──────────┬──────────┘               │
│                                              │                          │
│                                              ▼                          │
│                                   ┌─────────────────────┐               │
│                                   │   Response.Body     │               │
│                                   │   (direct write)    │               │
│                                   └─────────────────────┘               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Worker streaming path** — uses Pipe for concurrent ZIP creation + GCS upload:
```
┌─────────────────────────────────────────────────────────────────────────┐
│                    WORKER STREAMING PIPELINE                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ReportsService                    StreamingZipService                  │
│  ┌────────────────┐               ┌─────────────────────┐               │
│  │ StreamInvoice  │               │                     │               │
│  │ Pdfs()         │──────────────→│  CreateZipStream()  │               │
│  │                │  IAsyncEnum   │                     │               │
│  │ yields PDF     │  <PdfEntry>   │  ZipArchive (Create)│               │
│  │ streams        │               │  → PipeWriter       │               │
│  └────────────────┘               └──────────┬──────────┘               │
│                                              │                          │
│                                              ▼                          │
│                                   ┌─────────────────────┐               │
│                                   │   System.IO.Pipe    │               │
│                                   │   ┌───────────────┐ │               │
│                                   │   │ ~1MB Buffer   │ │               │
│                                   │   │ ░░░░░░░░░░░░░ │ │               │
│                                   │   └───────────────┘ │               │
│                                   │   Writer ←── Reader │               │
│                                   └─────────┬───────────┘               │
│                                             │                           │
│                                             ▼                           │
│                                   ┌─────────────────────┐               │
│                                   │  GoogleBlobStorage  │               │
│                                   │  StoreStreamingPipe │               │
│                                   │                     │               │
│                                   │  Uploads to GCS     │               │
│                                   │  while ZIP creates  │               │
│                                   └─────────────────────┘               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `IReportsService.StreamInvoicePdfs()` | Yields PDF streams as `IAsyncEnumerable` |
| `StreamingZipService.WriteZipToStreamAsync()` | Writes ZIP directly to any writable stream (API path) |
| `StreamingZipService.CreateZipStream()` | Creates ZIP via Pipe for readable stream consumers (worker path) |
| `IBlobStorage.StoreStreamingPipe()` | Uploads from pipe while producer writes |

### Code Flow

**API path** — controller writes ZIP directly to response:
```csharp
// In ReportsController
var metadata = await _reportsService.GetZipReportMetadata(AccountId, ct);
SetZipResponseHeaders(metadata);
await _reportsService.StreamInvoicesZipTo(AccountId, Response.Body, ct);

// StreamInvoicesZipTo calls StreamingZipService.WriteZipToStreamAsync() internally
// ZipArchive writes directly to Response.Body — no pipe, no buffering
```

**Worker path** — pipe-based for GCS upload:
```csharp
// 1. Get PDF stream enumerable (lazy - generates on demand)
var pdfEntries = _reportsService.StreamInvoicePdfs(accountId, ct);

// 2. Create streaming ZIP - returns pipe reader and producer task
var (zipReadStream, producerTask) = _streamingZipService.CreateZipStream(
    zipEntries, ct);

// 3. Upload concurrently while ZIP is being created
var contentUri = await _blobStorage.StoreStreamingPipe(
    bucket, name, contentType,
    zipReadStream,    // Consumer reads from pipe
    producerTask,     // Producer writes to pipe
    control, cache, ct);
```

---

## Memory Comparison

| Invoices | Level 1 (Original) | Level 2 (MemoryStream) | Level 3 (Pipes) |
|----------|-------------------|------------------------|-----------------|
| 20 × 2MB | ~80MB + ZIP | ~8MB ZIP | **~1MB** |
| 100 × 2MB | ~400MB + ZIP | ~40MB ZIP | **~1MB** |
| 500 × 2MB | ~2GB + ZIP | ~200MB ZIP | **~1MB** |

---

## Files

| File | Purpose |
|------|---------|
| `Invoices.Common/Services/Streaming/StreamingZipService.cs` | Pipe-based ZIP creation |
| `Invoices.Core/Reports/IReportsService.cs` | `StreamInvoicePdfs()` interface |
| `Invoices.Common/Services/Reports/ReportsService.cs` | PDF streaming implementation |
| `Invoices.Common/BlobStorage/IBlobStorage.cs` | `StoreStreamingPipe()` interface |
| `Invoices.Implementation.Services/BlobStorage/GoogleBlobStorage.cs` | GCS pipe upload |
| `Invoices.Worker/OperationHandlers/*` | Use streaming pipeline |

---

## Dependencies

```xml
<PackageReference Include="System.IO.Pipelines" Version="8.0.0" />
```

Uses built-in `System.IO.Compression.ZipArchive` with `ZipArchiveMode.Create` — supports non-seekable streams since .NET Core 2.0. No third-party ZIP library needed.

---

## Related

- [Overview](overview.md) - PDF service architecture
- [Benchmark](benchmark.md) - Performance testing
