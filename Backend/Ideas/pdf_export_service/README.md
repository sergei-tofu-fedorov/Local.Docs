# PDF Export Service

Cross-platform PDF generation and export functionality.

## Overview

The PDF Export Service handles invoice, estimate, and receipt PDF generation using PuppeteerSharp with headless Chromium. Current implementation lives in Invoices.Backend with plans to extract into a dedicated microservice.

## Documents

| Document | Description |
|----------|-------------|
| [Overview](overview.md) | Service architecture, optimization options, and target state |
| [Benchmark](benchmark.md) | Performance testing harness and load test clients |
| [Streaming Memory Optimization](streaming_memory_optimization.md) | Stream-based ZIP generation to reduce memory usage |
| [Streaming Optimization Backlog](streaming_optimization_backlog.md) | Remaining optimization opportunities and completed items |
| [FS-768: ZIP Streaming Optimization](FS-768_zip_streaming_optimization.md) | Implementation plan: parallel rendering, status filtering, streaming |

## Related Documentation

- [Invoices.Backend](../../Backend/Services/Invoices.Backend/) - Main API service
