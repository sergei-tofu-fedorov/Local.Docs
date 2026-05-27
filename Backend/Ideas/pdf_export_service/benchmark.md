# PDF Export Benchmarking

Test harness for measuring PDF generation performance, memory usage, and Chrome resource consumption.

---

## Architecture

```
┌─────────────────────┐         ┌─────────────────────────────────────┐
│ Load Test Client    │         │ Pdf.Benchmark.Api                   │
│ (k6 / .NET)         │         │ (ASP.NET Core Web API)              │
├─────────────────────┤   HTTP  ├─────────────────────────────────────┤
│ - Concurrent reqs   │────────►│ POST /benchmark/pdf                 │
│ - Metrics collection│◄────────│ - Generate PDF (configurable size)  │
│ - Report generation │         │ - Return timing + memory metrics    │
└─────────────────────┘         │ - Monitor Chrome process            │
                                └─────────────────────────────────────┘
```

---

## Benchmark API

### Project Structure

```
Pdf.Benchmark.Api/
├── Program.cs
├── Controllers/
│   └── BenchmarkController.cs
├── Services/
│   ├── PdfGeneratorService.cs
│   ├── ChromeMetricsService.cs
│   └── TemplateService.cs
├── Models/
│   ├── BenchmarkRequest.cs
│   └── BenchmarkResponse.cs
└── Templates/
    ├── small.html      (1 page)
    ├── medium.html     (10 pages)
    └── large.html      (50+ pages)
```

### Endpoints

#### POST /benchmark/pdf

Generate a PDF and return performance metrics.

**Request:**
```json
{
  "templateSize": "medium",
  "pageCount": 20,
  "includeImages": true,
  "includeCharts": false,
  "returnPdf": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| `templateSize` | string | `small`, `medium`, `large`, or `custom` |
| `pageCount` | int | Override page count (for `custom`) |
| `includeImages` | bool | Add base64 images to stress memory |
| `includeCharts` | bool | Add SVG charts |
| `returnPdf` | bool | Return PDF bytes (false = metrics only) |

**Response:**
```json
{
  "success": true,
  "metrics": {
    "totalMs": 1250,
    "htmlGenerationMs": 50,
    "pdfRenderMs": 1180,
    "pageAcquisitionMs": 20,
    "pdfSizeBytes": 524288,
    "pageCount": 20
  },
  "chrome": {
    "processId": 12345,
    "workingSetMb": 256,
    "privateMemoryMb": 180,
    "pagePoolSize": 4,
    "activePages": 1
  },
  "server": {
    "gcGen0Collections": 5,
    "gcGen1Collections": 1,
    "gcGen2Collections": 0,
    "managedMemoryMb": 85,
    "threadCount": 24
  }
}
```

#### GET /benchmark/chrome/stats

Get current Chrome process statistics.

**Response:**
```json
{
  "browserRunning": true,
  "processId": 12345,
  "uptimeSeconds": 3600,
  "workingSetMb": 256,
  "childProcesses": 3,
  "pagePool": {
    "total": 4,
    "available": 3,
    "locked": 1,
    "totalUsageCount": 47
  }
}
```

#### POST /benchmark/chrome/restart

Force restart Chrome browser (for memory leak testing).

#### GET /benchmark/templates

List available templates with metadata.

---

## Implementation

### BenchmarkController.cs

```csharp
[ApiController]
[Route("benchmark")]
public class BenchmarkController : ControllerBase
{
    private readonly IPdfGeneratorService _pdfGenerator;
    private readonly IChromeMetricsService _chromeMetrics;
    private readonly ILogger<BenchmarkController> _logger;

    [HttpPost("pdf")]
    public async Task<BenchmarkResponse> GeneratePdf(
        [FromBody] BenchmarkRequest request,
        CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();
        var response = new BenchmarkResponse();

        // Capture pre-generation state
        var preGcCollections = GC.CollectionCount(0);
        var preManagedMemory = GC.GetTotalMemory(false);

        // Generate HTML
        var htmlStart = stopwatch.ElapsedMilliseconds;
        var html = await _templateService.GenerateHtml(request);
        response.Metrics.HtmlGenerationMs = stopwatch.ElapsedMilliseconds - htmlStart;

        // Generate PDF
        var pdfStart = stopwatch.ElapsedMilliseconds;
        var (pdf, pageMetrics) = await _pdfGenerator.GenerateWithMetrics(html, ct);
        response.Metrics.PdfRenderMs = stopwatch.ElapsedMilliseconds - pdfStart;
        response.Metrics.PageAcquisitionMs = pageMetrics.AcquisitionMs;

        // Capture post-generation state
        response.Metrics.TotalMs = stopwatch.ElapsedMilliseconds;
        response.Metrics.PdfSizeBytes = pdf.Length;

        response.Chrome = await _chromeMetrics.GetCurrentStats();
        response.Server = new ServerMetrics
        {
            GcGen0Collections = GC.CollectionCount(0) - preGcCollections,
            ManagedMemoryMb = (GC.GetTotalMemory(false) - preManagedMemory) / 1024 / 1024
        };

        if (request.ReturnPdf)
            response.PdfBase64 = Convert.ToBase64String(pdf);

        return response;
    }
}
```

### ChromeMetricsService.cs (Accurate Windows Process Monitoring)

The .NET `Process` class is unreliable for Chrome metrics because:
- Chromium spawns multiple child processes (GPU, renderer, utility)
- `WorkingSet64` can be stale or cached
- Child processes aren't automatically included

**Solution:** Query all `chrome.exe` processes by parent PID or use WMI/PowerShell.

```csharp
public class ChromeMetricsService : IChromeMetricsService
{
    private readonly IPuppeteerPdfCreatorService _pdfCreator;

    public async Task<ChromeStats> GetCurrentStats()
    {
        var browser = _pdfCreator.GetBrowser();
        if (browser == null)
            return new ChromeStats { BrowserRunning = false };

        var parentPid = browser.Process.Id;

        // Get all Chrome processes (parent + children)
        var chromeProcesses = GetChromeProcessTree(parentPid);

        // Aggregate memory across all processes
        var totalWorkingSet = chromeProcesses.Sum(p => p.WorkingSet64);
        var totalPrivateMemory = chromeProcesses.Sum(p => p.PrivateMemorySize64);

        return new ChromeStats
        {
            BrowserRunning = true,
            ProcessId = parentPid,
            ProcessCount = chromeProcesses.Count,
            WorkingSetMb = totalWorkingSet / 1024 / 1024,
            PrivateMemoryMb = totalPrivateMemory / 1024 / 1024,
            PagePool = _pdfCreator.GetPoolStats(),
            ProcessDetails = chromeProcesses.Select(p => new ProcessDetail
            {
                Pid = p.Id,
                Name = GetProcessType(p),
                WorkingSetMb = p.WorkingSet64 / 1024 / 1024
            }).ToList()
        };
    }

    /// <summary> Gets Chrome parent process and all child processes. </summary>
    private List<Process> GetChromeProcessTree(int parentPid)
    {
        var result = new List<Process>();

        try
        {
            var parent = Process.GetProcessById(parentPid);
            parent.Refresh(); // Force refresh cached values
            result.Add(parent);
        }
        catch (ArgumentException)
        {
            return result; // Process exited
        }

        // Use WMI to find child processes (Windows-specific)
        if (OperatingSystem.IsWindows())
        {
            result.AddRange(GetChildProcessesWmi(parentPid));
        }

        return result;
    }

    /// <summary> Query child processes via WMI (accurate on Windows). </summary>
    private IEnumerable<Process> GetChildProcessesWmi(int parentPid)
    {
        var query = $"SELECT ProcessId FROM Win32_Process WHERE ParentProcessId = {parentPid}";

        using var searcher = new ManagementObjectSearcher(query);
        foreach (var obj in searcher.Get())
        {
            var childPid = Convert.ToInt32(obj["ProcessId"]);
            Process childProcess;
            try
            {
                childProcess = Process.GetProcessById(childPid);
                childProcess.Refresh();
            }
            catch (ArgumentException)
            {
                continue; // Process exited
            }

            yield return childProcess;

            // Recursively get grandchildren
            foreach (var grandchild in GetChildProcessesWmi(childPid))
                yield return grandchild;
        }
    }
}
```

**Required NuGet:** `System.Management` (for WMI queries on Windows)

### Template Generation

```csharp
public class TemplateService : ITemplateService
{
    public Task<string> GenerateHtml(BenchmarkRequest request)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<!DOCTYPE html><html><head>");
        sb.AppendLine("<style>@page { size: A4; margin: 1cm; }</style>");
        sb.AppendLine("</head><body>");

        var pageCount = request.PageCount ?? GetDefaultPageCount(request.TemplateSize);

        for (int i = 0; i < pageCount; i++)
        {
            sb.AppendLine($"<div style='page-break-after: always;'>");
            sb.AppendLine($"<h1>Page {i + 1}</h1>");
            sb.AppendLine(GenerateLoremIpsum(500)); // ~500 words per page

            if (request.IncludeImages)
                sb.AppendLine(GenerateBase64Image(800, 600));

            if (request.IncludeCharts)
                sb.AppendLine(GenerateSvgChart());

            sb.AppendLine("</div>");
        }

        sb.AppendLine("</body></html>");
        return Task.FromResult(sb.ToString());
    }

    private static int GetDefaultPageCount(string size) => size switch
    {
        "small" => 1,
        "medium" => 10,
        "large" => 50,
        _ => 10
    };
}
```

---

## External Windows Process Monitoring

For accurate memory measurement, monitor Chrome processes externally using PowerShell or a sidecar process.

### PowerShell Monitor Script

```powershell
# monitor-chrome.ps1
# Run alongside benchmark to capture accurate memory over time

param(
    [int]$IntervalSeconds = 2,
    [int]$DurationMinutes = 10,
    [string]$OutputCsv = "chrome-metrics.csv"
)

$endTime = (Get-Date).AddMinutes($DurationMinutes)
$results = @()

Write-Host "Monitoring Chrome processes for $DurationMinutes minutes..."
Write-Host "Output: $OutputCsv"
Write-Host ""

while ((Get-Date) -lt $endTime) {
    $chromeProcesses = Get-Process -Name "chrome" -ErrorAction SilentlyContinue

    if ($chromeProcesses) {
        $totalWorkingSetMB = [math]::Round(($chromeProcesses | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 2)
        $totalPrivateMB = [math]::Round(($chromeProcesses | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB, 2)
        $processCount = $chromeProcesses.Count

        $entry = [PSCustomObject]@{
            Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            ProcessCount    = $processCount
            WorkingSetMB    = $totalWorkingSetMB
            PrivateMemoryMB = $totalPrivateMB
        }

        $results += $entry

        Write-Host "$($entry.Timestamp) | Processes: $processCount | WorkingSet: $totalWorkingSetMB MB | Private: $totalPrivateMB MB"
    }
    else {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | No Chrome processes found"
    }

    Start-Sleep -Seconds $IntervalSeconds
}

# Export results
$results | Export-Csv -Path $OutputCsv -NoTypeInformation
Write-Host "`nResults saved to $OutputCsv"

# Summary
if ($results.Count -gt 0) {
    Write-Host "`n=== Summary ==="
    Write-Host "Samples: $($results.Count)"
    Write-Host "WorkingSet - Min: $($results.WorkingSetMB | Measure-Object -Minimum | Select-Object -Expand Minimum) MB"
    Write-Host "WorkingSet - Max: $($results.WorkingSetMB | Measure-Object -Maximum | Select-Object -Expand Maximum) MB"
    Write-Host "WorkingSet - Avg: $([math]::Round(($results.WorkingSetMB | Measure-Object -Average).Average, 2)) MB"
}
```

**Usage:**
```powershell
# Run in separate terminal during benchmark
pwsh monitor-chrome.ps1 -IntervalSeconds 2 -DurationMinutes 30 -OutputCsv results.csv
```

### Real-Time Memory Watcher (Per-Process Breakdown)

```powershell
# watch-chrome-detail.ps1
# Shows memory breakdown by Chrome process type

while ($true) {
    Clear-Host
    Write-Host "=== Chrome Process Memory ===" -ForegroundColor Cyan
    Write-Host "Time: $(Get-Date -Format 'HH:mm:ss')`n"

    $processes = Get-Process -Name "chrome" -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object Id,
            @{N='WorkingSet (MB)';E={[math]::Round($_.WorkingSet64/1MB,1)}},
            @{N='Private (MB)';E={[math]::Round($_.PrivateMemorySize64/1MB,1)}},
            @{N='CPU (s)';E={[math]::Round($_.CPU,1)}}

    if ($processes) {
        $processes | Format-Table -AutoSize

        $total = $processes | Measure-Object 'WorkingSet (MB)' -Sum
        Write-Host "TOTAL: $([math]::Round($total.Sum, 1)) MB across $($processes.Count) processes" -ForegroundColor Yellow
    }
    else {
        Write-Host "No Chrome processes running" -ForegroundColor Red
    }

    Start-Sleep -Seconds 2
}
```

### Performance Counter Approach (Most Accurate)

```csharp
/// <summary> Uses Windows Performance Counters for accurate memory metrics. </summary>
public class PerformanceCounterChromeMetrics : IChromeMetricsService
{
    public ChromeStats GetCurrentStats()
    {
        var stats = new ChromeStats();

        // Get all chrome process instances
        var category = new PerformanceCounterCategory("Process");
        var instances = category.GetInstanceNames()
            .Where(name => name.StartsWith("chrome"))
            .ToList();

        stats.ProcessCount = instances.Count;

        foreach (var instance in instances)
        {
            using var workingSetCounter = new PerformanceCounter(
                "Process", "Working Set", instance, true);
            using var privateCounter = new PerformanceCounter(
                "Process", "Private Bytes", instance, true);

            stats.WorkingSetMb += workingSetCounter.NextValue() / 1024 / 1024;
            stats.PrivateMemoryMb += privateCounter.NextValue() / 1024 / 1024;
        }

        return stats;
    }
}
```

### Integrated Background Monitor Service

```csharp
/// <summary> Background service that samples Chrome memory at fixed intervals. </summary>
public class ChromeMemoryMonitor : BackgroundService
{
    private readonly ILogger<ChromeMemoryMonitor> _logger;
    private readonly ConcurrentQueue<MemorySample> _samples = new();
    private const int MaxSamples = 1000;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var sample = CaptureMemorySample();
            _samples.Enqueue(sample);

            // Keep only last N samples
            while (_samples.Count > MaxSamples)
                _samples.TryDequeue(out _);

            await Task.Delay(TimeSpan.FromSeconds(2), ct);
        }
    }

    private MemorySample CaptureMemorySample()
    {
        var chromeProcesses = Process.GetProcessesByName("chrome");

        foreach (var p in chromeProcesses)
            p.Refresh(); // Force refresh!

        return new MemorySample
        {
            Timestamp = DateTime.UtcNow,
            ProcessCount = chromeProcesses.Length,
            TotalWorkingSetMb = chromeProcesses.Sum(p => p.WorkingSet64) / 1024 / 1024,
            TotalPrivateMb = chromeProcesses.Sum(p => p.PrivateMemorySize64) / 1024 / 1024
        };
    }

    public IReadOnlyList<MemorySample> GetSamples() => _samples.ToList();

    public MemoryStats GetStats()
    {
        var samples = _samples.ToList();
        if (!samples.Any())
            return new MemoryStats();

        var workingSets = samples.Select(s => s.TotalWorkingSetMb).ToList();

        return new MemoryStats
        {
            SampleCount = samples.Count,
            MinWorkingSetMb = workingSets.Min(),
            MaxWorkingSetMb = workingSets.Max(),
            AvgWorkingSetMb = workingSets.Average(),
            CurrentWorkingSetMb = workingSets.Last()
        };
    }
}

public record MemorySample(DateTime Timestamp, int ProcessCount, long TotalWorkingSetMb, long TotalPrivateMb);
public record MemoryStats(int SampleCount, long MinWorkingSetMb, long MaxWorkingSetMb, double AvgWorkingSetMb, long CurrentWorkingSetMb);
```

### Updated API Response with Accurate Metrics

```json
{
  "chrome": {
    "processId": 12345,
    "processCount": 5,
    "workingSetMb": 412,
    "privateMemoryMb": 380,
    "processDetails": [
      { "pid": 12345, "type": "browser", "workingSetMb": 120 },
      { "pid": 12350, "type": "gpu", "workingSetMb": 85 },
      { "pid": 12355, "type": "renderer", "workingSetMb": 95 },
      { "pid": 12360, "type": "renderer", "workingSetMb": 72 },
      { "pid": 12365, "type": "utility", "workingSetMb": 40 }
    ],
    "memoryTrend": {
      "sampleCount": 150,
      "minMb": 280,
      "maxMb": 450,
      "avgMb": 365
    }
  }
}
```

---

## Load Test Clients

### Option 1: k6 (Recommended for Load Testing)

```javascript
// benchmark.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const pdfDuration = new Trend('pdf_generation_ms');
const pdfSize = new Trend('pdf_size_bytes');
const chromeMemory = new Trend('chrome_memory_mb');
const errors = new Counter('errors');

export const options = {
  scenarios: {
    // Ramp up test
    ramp_up: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 5 },
        { duration: '1m', target: 10 },
        { duration: '30s', target: 0 },
      ],
    },
    // Constant load test
    constant: {
      executor: 'constant-vus',
      vus: 5,
      duration: '5m',
      startTime: '2m30s',
    },
    // Spike test
    spike: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '10s', target: 20 },
        { duration: '1m', target: 20 },
        { duration: '10s', target: 1 },
      ],
      startTime: '8m',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<5000'],
    pdf_generation_ms: ['p(95)<3000'],
    errors: ['count<10'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:5000';

export default function () {
  const payload = JSON.stringify({
    templateSize: 'medium',
    pageCount: 10,
    includeImages: true,
    returnPdf: false,
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
    timeout: '30s',
  };

  const res = http.post(`${BASE_URL}/benchmark/pdf`, payload, params);

  const success = check(res, {
    'status is 200': (r) => r.status === 200,
    'has metrics': (r) => r.json('metrics') !== null,
  });

  if (success) {
    const body = res.json();
    pdfDuration.add(body.metrics.totalMs);
    pdfSize.add(body.metrics.pdfSizeBytes);
    chromeMemory.add(body.chrome.workingSetMb);
  } else {
    errors.add(1);
  }

  sleep(1);
}

export function handleSummary(data) {
  return {
    'summary.json': JSON.stringify(data, null, 2),
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
  };
}
```

**Run:**
```bash
# Install k6
# Windows: choco install k6
# macOS: brew install k6

# Run test
k6 run benchmark.js

# Run with custom URL
k6 run -e BASE_URL=http://localhost:5000 benchmark.js

# Run with HTML report
k6 run --out json=results.json benchmark.js
```

### Option 2: .NET Client (For Detailed Analysis)

```csharp
// Pdf.Benchmark.Client/Program.cs
public class BenchmarkClient
{
    private readonly HttpClient _http;
    private readonly BenchmarkOptions _options;

    public async Task RunBenchmark()
    {
        var results = new List<BenchmarkResult>();

        Console.WriteLine($"Running benchmark: {_options.Iterations} iterations, {_options.Concurrency} concurrent");

        // Warmup
        Console.WriteLine("Warming up...");
        await RunIteration(new BenchmarkRequest { TemplateSize = "small" });

        // Run test
        var semaphore = new SemaphoreSlim(_options.Concurrency);
        var tasks = new List<Task<BenchmarkResult>>();

        for (int i = 0; i < _options.Iterations; i++)
        {
            await semaphore.WaitAsync();
            tasks.Add(Task.Run(async () =>
            {
                try
                {
                    return await RunIteration(_options.Request);
                }
                finally
                {
                    semaphore.Release();
                }
            }));
        }

        results = (await Task.WhenAll(tasks)).ToList();

        // Report
        PrintReport(results);
        await SaveReport(results);
    }

    private async Task<BenchmarkResult> RunIteration(BenchmarkRequest request)
    {
        var sw = Stopwatch.StartNew();
        var response = await _http.PostAsJsonAsync("/benchmark/pdf", request);
        var clientMs = sw.ElapsedMilliseconds;

        var body = await response.Content.ReadFromJsonAsync<BenchmarkResponse>();

        return new BenchmarkResult
        {
            ClientTotalMs = clientMs,
            ServerMetrics = body.Metrics,
            ChromeStats = body.Chrome,
            Timestamp = DateTime.UtcNow
        };
    }

    private void PrintReport(List<BenchmarkResult> results)
    {
        var successful = results.Where(r => r.ServerMetrics != null).ToList();

        Console.WriteLine("\n=== Benchmark Results ===\n");
        Console.WriteLine($"Total requests:    {results.Count}");
        Console.WriteLine($"Successful:        {successful.Count}");
        Console.WriteLine($"Failed:            {results.Count - successful.Count}");
        Console.WriteLine();

        if (!successful.Any()) return;

        var times = successful.Select(r => r.ServerMetrics.TotalMs).OrderBy(x => x).ToList();
        Console.WriteLine($"PDF Generation Time:");
        Console.WriteLine($"  Min:    {times.First()} ms");
        Console.WriteLine($"  Max:    {times.Last()} ms");
        Console.WriteLine($"  Avg:    {times.Average():F0} ms");
        Console.WriteLine($"  p50:    {Percentile(times, 50)} ms");
        Console.WriteLine($"  p95:    {Percentile(times, 95)} ms");
        Console.WriteLine($"  p99:    {Percentile(times, 99)} ms");
        Console.WriteLine();

        var memory = successful.Select(r => r.ChromeStats.WorkingSetMb).ToList();
        Console.WriteLine($"Chrome Memory:");
        Console.WriteLine($"  Min:    {memory.Min()} MB");
        Console.WriteLine($"  Max:    {memory.Max()} MB");
        Console.WriteLine($"  Avg:    {memory.Average():F0} MB");
    }

    private static double Percentile(List<long> values, int p)
    {
        var index = (int)Math.Ceiling(p / 100.0 * values.Count) - 1;
        return values[Math.Max(0, index)];
    }
}
```

**Client CLI:**
```bash
dotnet run -- --url http://localhost:5000 \
              --iterations 100 \
              --concurrency 5 \
              --template medium \
              --pages 20 \
              --output results.csv
```

---

## Test Scenarios

### 1. Baseline Performance

```bash
# Single request, various sizes
k6 run -e TEMPLATE=small -i 1 benchmark.js
k6 run -e TEMPLATE=medium -i 1 benchmark.js
k6 run -e TEMPLATE=large -i 1 benchmark.js
```

### 2. Concurrency Limits

```bash
# Find breaking point
for vus in 2 4 8 16 32; do
  k6 run --vus $vus --duration 1m benchmark.js
done
```

### 3. Memory Leak Detection

```bash
# Long-running test monitoring Chrome memory
k6 run --vus 2 --duration 30m benchmark.js

# Monitor Chrome memory separately
watch -n 5 'curl -s http://localhost:5000/benchmark/chrome/stats | jq .workingSetMb'
```

### 4. Large Document Stress

```json
{
  "templateSize": "custom",
  "pageCount": 100,
  "includeImages": true,
  "includeCharts": true
}
```

---

## Metrics to Collect

| Metric | Source | Target |
|--------|--------|--------|
| PDF generation time | API response | p95 < 3s |
| Time to first byte | k6 http_req_waiting | p95 < 500ms |
| Chrome working set | Process.WorkingSet64 | < 500 MB |
| Chrome private memory | Process.PrivateMemorySize64 | Stable over time |
| Page pool utilization | PdfCreator stats | < 80% |
| GC collections | GC.CollectionCount | Low Gen2 |
| Request throughput | k6 http_reqs | > 10 req/s |
| Error rate | k6 http_req_failed | < 1% |

---

## Running the Benchmark

### 1. Start the Benchmark API

```bash
cd Pdf.Benchmark.Api
dotnet run
```

### 2. Run Load Test

```bash
# Quick test
k6 run --vus 5 --duration 1m benchmark.js

# Full test suite
k6 run benchmark.js
```

### 3. Analyze Results

```bash
# View summary
cat summary.json | jq '.metrics.pdf_generation_ms'

# Generate HTML report (with k6 extension)
k6 run --out json=results.json benchmark.js
# Then use k6-reporter or similar tool
```

---

## Expected Results

| Template | Pages | Avg Time | Memory |
|----------|-------|----------|--------|
| small | 1 | 200-400 ms | +10 MB |
| medium | 10 | 500-1000 ms | +30 MB |
| large | 50 | 2-4 s | +100 MB |
| custom | 100 | 5-10 s | +200 MB |

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Timeouts at high concurrency | Page pool exhausted | Increase pool size or reduce concurrency |
| Memory grows continuously | Page not disposed | Check MaxPageUsageCount, force restart |
| First request slow | Cold start | Add warmup endpoint, pre-initialize browser |
| Inconsistent times | GC pressure | Monitor GC, consider server GC mode |

---

## Related Documentation

- [Overview](overview.md) - Service architecture
- [Appendix: Optimization Techniques](overview.md#appendix-web-sourced-optimization-techniques) - Performance tuning
