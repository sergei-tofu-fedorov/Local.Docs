# WEB-1523 — Presidio redaction (implementation plan)

How the Presidio-based PII redaction step is wired into `Tofu.AI.Backend`. **What** gets redacted, **why**, and the per-analysis allow-list are owned by [`../investigation/privacy.md`](../investigation/privacy.md) — this doc is the engineering plan for the redaction component itself.

> **Scope.** Deployment shape, C# integration point, allow-list config, failure mode, test fixtures. Not in scope: which entity types each analysis allows on the wire (that's `privacy.md` § 3a), which model the redacted payload goes to (`provider.md`).

## Decision

- **Sidecar deployment.** Microsoft Presidio runs as two sidecar containers in the **`tofu-ai-api-deployment`** pod (analyzer + anonymizer — `mcr.microsoft.com/presidio-analyzer` + `mcr.microsoft.com/presidio-anonymizer`, or the combined image once one is published). Since the AI service is single-pod in v1 (Hangfire embedded in `Tofu.AI.Api` — see [`../implementation/service.md`](../implementation/service.md) § Decision), the same pod that hosts the Hangfire jobs also hosts Presidio; HTTP loopback is intra-pod regardless.
- **HTTP loopback** — the C# code talks to Presidio over `http://localhost:3000` (analyzer) + `http://localhost:5001` (anonymizer). No network egress; same pod, same network namespace, sub-ms latency.
- **In-process is rejected.** No `.NET` Presidio port exists; running Presidio via Python.NET / IronPython would graft a Python runtime into the .NET process for no infrastructure benefit. The sidecar adds ~150 MB memory and zero ops complexity beyond a pod-spec line.
- **Integration point — `IFsmFitPayloadBuilder.BuildAsync()`.** Redaction is the last transformation before the typed payload is serialised into the OpenAI request body. **Notes route through `IRedactor.RedactAsync(...)`; item names are passed through raw** — the field-level split is owned by [`../investigation/privacy.md`](../investigation/privacy.md) § 2a (the 2026-05 A/B: redacting item names is the dominant source of mis-scoring, and the dense direct PII lives in notes). The builder is the single enforcement point.
- **Fail-closed.** If the Presidio sidecar is unreachable, returns 5xx, or times out (>2s), `IRedactor` throws `RedactionUnavailableException`. `AnalyzeJob<T>` catches it, marks the row's refresh as failed (Hangfire retry), and **does not call the LLM**. No raw payload ever reaches OpenAI on a redactor failure.
- **Per-analysis allow-list driven by config**, not code. The list of entity types Presidio is asked to find lives in `appsettings.json` under `Analyses:<AnalysisType>:Redaction:EnabledEntities`. Changing the allow-list is a config push, not a code deploy.

## Deployment shape

**API pod sidecars.** `Deploy/Invoices.Kubernetes/overlays/prod/tofu-ai.yaml` gets two sidecar containers added to the existing `tofu-ai-api-deployment` spec (single-pod design — no separate Worker Deployment):

```yaml
- name: presidio-analyzer
  image: mcr.microsoft.com/presidio-analyzer:2.2.362
  ports: [{ containerPort: 3000 }]
  resources:
    requests: { memory: 200Mi, cpu: 100m }
    limits:   { memory: 400Mi, cpu: 500m }
  startupProbe: { httpGet: { path: /health, port: 3000 }, periodSeconds: 5, failureThreshold: 30 }

- name: presidio-anonymizer
  image: mcr.microsoft.com/presidio-anonymizer:2.2.362
  ports: [{ containerPort: 5001 }]
  resources:
    requests: { memory: 100Mi, cpu: 50m }
    limits:   { memory: 200Mi, cpu: 200m }
  startupProbe: { httpGet: { path: /health, port: 5001 } }
```

The API pod's memory budget (already bumped to ~1Gi per `../implementation/service.md` § Q1 to absorb the in-process Hangfire workload) needs another ~300Mi for the sidecars — bump `requests.memory` to 1.3Gi when these are added.

**Image pinning.** Pin to a specific Presidio version (latest stable at implementation time — check [github.com/microsoft/presidio/releases](https://github.com/microsoft/presidio/releases)). Auto-update via `:latest` is rejected — model-rules drift would silently change what's redacted.

## C# integration

```csharp
// Analyses.Domain/Redaction/IRedactor.cs
public interface IRedactor
{
    Task<string> RedactAsync(string text, IReadOnlyCollection<string> enabledEntities, CancellationToken ct);
    Task<RedactedBatch> RedactAsync(IReadOnlyCollection<string> texts, IReadOnlyCollection<string> enabledEntities, CancellationToken ct);
}

// Analyses.Infrastructure/Redaction/PresidioRedactor.cs
public sealed class PresidioRedactor(HttpClient analyzer, HttpClient anonymizer, ILogger<PresidioRedactor> log)
    : IRedactor
{
    // POST /analyze   → list of {entity_type, start, end, score}
    // POST /anonymize → replaced string
    // 2s per call, Polly retry x2 with exponential backoff, then throw RedactionUnavailableException.
}
```

DI registration in `Analyses.Infrastructure/ServiceCollectionExtensions.cs`:
- `services.AddHttpClient<IRedactor, PresidioRedactor>()` with named clients for the two Presidio endpoints.
- Base URLs from `appsettings.json` (`Analyses:Redaction:AnalyzerUrl`, `Analyses:Redaction:AnonymizerUrl`); defaulted to `http://localhost:3000` / `http://localhost:5001` so local dev without a sidecar can stub via a fake `IRedactor`.

**Where it's called.** Inside `FsmFitPayloadBuilder.BuildAsync()`, for **notes only** — item names are forwarded unchanged:

```csharp
// FsmFitPayloadBuilder.BuildAsync(...)
// Item names pass through raw (the classifier's primary signal — see privacy.md § 2a).
// Only notes are redacted; a redactor outage propagates (fail-closed, no LLM call).
var redactedNotes = await RedactNotesAsync(signals.TopNotes, ct);
return AnalysesMappings.ToPayload(metrics, new InvoiceSignals(signals.TopItemNames, redactedNotes));
```

The redactor's batch API is used — `top_notes` is a list of ~5–20 strings per account; one round-trip beats N. (Entities default to `PresidioSettings.DefaultEntities`; the per-analysis allow-list is passed as `[]` to fall back to it.)

## Per-analysis allow-list (config shape)

```jsonc
// appsettings.json
"Analyses": {
  "FsmFit": {
    "Redaction": {
      "EnabledEntities": [
        "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "LOCATION",
        "US_BANK_NUMBER", "IBAN_CODE", "CREDIT_CARD"
      ],
      "ConfidenceThreshold": 0.55
    }
  }
}
```

`EnabledEntities` is the **request** to Presidio's `/analyze` endpoint — Presidio only runs detectors for the listed entity types, so unlisted ones are not even scanned for. This is the operational expression of `privacy.md` § 3a's per-analysis PII allow-list: a field allowed on the wire (e.g. `business_name`) simply doesn't have its detector enabled here.

`ConfidenceThreshold` lives in config because per-`privacy.md` § "Tuning levers" it's the primary knob for false-positive control. Default 0.55 (Presidio's recommended baseline); raise for an analysis that's seeing legitimate vocabulary stripped, lower if PII is leaking through.

## Failure handling

Three failure modes, all close the gate:

| Failure | Behaviour |
|---|---|
| Sidecar unreachable (connection refused, DNS failure) | `RedactionUnavailableException` → `AnalyzeJob<T>` marks failed → Hangfire retry x3 → DLQ |
| Sidecar returns 5xx | Same path — retry, then DLQ |
| Sidecar exceeds 2s timeout | Same path |
| Sidecar returns 200 with redacted text | Continue to LLM call |

The point: **no raw payload reaches OpenAI when redaction is degraded.** The cost of a missed analysis cycle (24h re-refresh anyway) is dramatically lower than the cost of leaking PII to an external provider.

Monitoring: emit a counter `analyses.redaction.failures{analysis_type, reason}` on every exception path; alert if `>1% / hr`.

## Testing

Three layers:

1. **Unit tests** against a faked `IRedactor` — verify `FsmFitPayloadBuilder` calls the redactor for **notes** (occurrence counts preserved, order-pairing intact) and forwards **item names unchanged** (redactor never invoked for them). Cover the fail-closed path: a redactor that throws `RedactionUnavailableException` propagates and no payload is assembled.
2. **Integration tests** against the real Presidio sidecar — `Tofu.AI.FunctionalTests` uses Testcontainers to spin up the Presidio analyzer + anonymizer images; fixture set is the 2026-05-13 sample under `Investigation/main-1361-collect/` (per `privacy.md` § 1) — verify that the redacted output contains no PII strings from a known-PII set (regex-based assertion list: emails, US phone numbers, bank-account patterns, the seed accounts' real business names where they're sole-proprietor PII).
3. **Smoke check on every deploy** — pre-deploy migration Job pings both Presidio endpoints with a fixed PII probe (`"Contact John Smith at john@example.com or 555-0100"`) and asserts the output contains no surface form of `John Smith`, `john@example.com`, or `555-0100`. Failed probe aborts the deploy — same gate pattern as the BigQuery migration.

## Open questions

- [x] ~~**Sidecar version pin** — pick the exact Presidio version + language model bundle at implementation time; document in this section.~~ — **Resolved (2026-05-21):** pinned to `2.2.362` (latest stable, GitHub release 2026-03-18) for both analyzer + anonymizer in `Deploy/Invoices.Kubernetes/overlays/dev/tofu-ai.yaml`. Language-model bundle = the default English shipped in the official image. Bump both images in lockstep when revisiting.
- [ ] **Multi-language handling** — Presidio's analyzer is language-aware (English model by default). Spanish / French / German invoices in the sample? If yes, load the multi-language NER model — adds memory but fixes recall on non-EN payloads. Confirm with PM whether non-EN accounts are in the v1 cohort.
- [ ] **Custom recognisers** — `privacy.md` § "Tuning levers" implies we may add custom detectors (e.g., a recogniser for our own account-id format if it ever leaks into item text). Tracked, not committed for v1.
- [ ] **Fixture set for the integration test** — `Investigation/main-1361-collect/` is the obvious source, but PII-containing fixtures should not land in `Tofu.Docs` or the source repo. Park them in a separate private bucket or generate synthetic PII in-test.
- [ ] **Cold-start latency** — Presidio analyzer's first request after pod start can take ~5–10s to warm the NER model. The API pod's `startupProbe` waits for the sidecar's own `startupProbe` to pass, but consider preloading via a one-shot warmup call from the API host's `IHostedService` so the first real Hangfire tick doesn't pay the cold-start penalty.
