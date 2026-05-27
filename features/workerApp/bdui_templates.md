
BDUI Template Endpoint
======================

**Task**: [FS-924](https://app.clickup.com/t/FS-924)

Goal
----

Serve BDUI (Backend-Driven UI) JSON templates from a GCS bucket via a public endpoint. Mobile clients fetch templates by slug to render onboarding and other dynamic UI screens without app updates.

Endpoint: `GET /bdui/templates/{slug}`
- No authentication required
- Returns **plain JSON** (no result wrapper)
- JSON payloads can exceed 100KB

Slug examples: `onboarding_1`, `onboarding_2`, `onboarding_other_industries`.

Approach
--------

Store pre-configured JSON files in a dedicated GCS bucket. The endpoint builds a file path from the slug, fetches the object from GCS, and streams the raw JSON to the client.

```
Client                    Invoices.Backend                   GCS
  │                             │                              │
  │  GET /bdui/templates/        │                              │
  │       onboarding_1          │                              │
  │ ──────────────────────────► │                              │
  │                             │  GET {bucket}/onboarding_1.json
  │                             │ ───────────────────────────► │
  │                             │ ◄─────── object stream ───── │
  │ ◄──── application/json ──── │                              │
  │   (raw JSON, no wrapper)    │                              │
```

**Why GCS bucket (not DB or embedded files)**:
- Templates are static assets managed outside the deployment cycle — content team can update them without redeploying
- GCS handles storage, versioning, and redundancy out of the box
- Consistent with existing file storage patterns in the platform (logos, PDFs, AI chat history all use GCS)

**Why streaming**: The `GoogleBlobStorage.Get()` method loads the full object into memory. For 100KB files this works fine, but streaming from GCS directly to the HTTP response avoids buffering and scales to larger templates if needed later. The GCS `StorageClient` supports `DownloadObjectAsync` with a destination stream — pipe it straight into `Response.Body`.

Storage Layout
--------------

Bucket: `tofu-bdui` (dev/staging) / `tofu-bdui-production` (prod)

```
tofu-bdui-production/
  onboarding_1.json
  onboarding_2.json
  onboarding_3.json
  onboarding_other_industries.json
```

Files are stored flat at bucket root. The slug maps directly to `{slug}.json`.

Bucket setup:
- Uniform bucket-level access (no per-object ACLs)
- No public access — only the service account reads from it
- Managed via GCP console or Terraform (same as other Tofu buckets)

Template files are uploaded manually (GCP console, `gsutil cp`, or a future admin tool).

API Contract
------------

### `GET /bdui/templates/{slug}`

Request:

| Parameter | Location | Type   | Required | Description |
|-----------|----------|--------|----------|-------------|
| `slug`    | path     | string | yes      | Template identifier (e.g. `onboarding_1`) |

Response (200):

Raw JSON body. Content-Type: `application/json`. No envelope, no wrapper — the response IS the template.

Response (400):

Empty body when slug contains invalid characters (fails `^[a-z0-9_]+$` validation).

Response (404):

Empty body when the slug is valid but no matching template exists in the bucket.

### Slug Validation

Only alphanumeric characters and underscores allowed: `^[a-z0-9_]+$`. This prevents path traversal, injection, and unexpected GCS object paths.

### Caching

Response includes `Cache-Control: public, max-age=300` (5 min). Clients and CDN can cache aggressively — template updates are infrequent and a few minutes of staleness is acceptable.

The `ETag` header from GCS is forwarded as-is, enabling conditional requests (`If-None-Match` → 304).

Implementation — Invoices.Backend
----------------------------------

### New Files

1. **Controller**: `Controllers/BduiController.cs`
   - `[AllowAnonymous]` on the controller (same pattern as `SharedBundlesController`, `OneTimePasswordsController`)
   - Single action: `GetTemplate(string slug)`
   - Delegates to `IBduiTemplateService`

2. **Service**: `BduiTemplates/BduiTemplateService.cs` (in Implementation.Services)
   - Injected: `StorageClient` (already registered in DI)
   - Validates slug format (regex `^[a-z0-9_]+$`)
   - Builds object name: `{slug}.json`
   - Calls `storageClient.GetObjectAsync()` to check existence + get metadata
   - Streams via `storageClient.DownloadObjectAsync(bucket, objectName, Response.Body)`
   - Returns null/false when the object doesn't exist (triggers 404)

3. **Configuration**: `appsettings.json` — add `BduiTemplates` section:
   ```json
   "BduiTemplates": {
     "BucketName": "tofu-bdui"
   }
   ```
   Production override sets `tofu-bdui-production`.

### Controller Sketch

```csharp
[AllowAnonymous]
[Route("bdui")]
[ApiController]
public class BduiController : ControllerBase
{
    private readonly IBduiTemplateService _templateService;

    [HttpGet("templates/{slug}")]
    public async Task<IActionResult> GetTemplate(
        string slug,
        CancellationToken ct)
    {
        if (!_templateService.IsValidSlug(slug))
            return BadRequest();

        var result = await _templateService.GetTemplateAsync(slug, ct);
        if (result is null)
            return NotFound();

        Response.Headers.CacheControl = "public, max-age=300";
        if (result.ETag is not null)
            Response.Headers.ETag = result.ETag;

        return File(result.Stream, "application/json");
    }
}
```

### Service Sketch

```csharp
public interface IBduiTemplateService
{
    bool IsValidSlug(string slug);
    Task<BduiTemplateResult?> GetTemplateAsync(string slug, CancellationToken ct);
}

public record BduiTemplateResult(Stream Stream, string? ETag);

public class BduiTemplateService : IBduiTemplateService
{
    private readonly StorageClient _storageClient;
    private readonly string _bucketName;

    [GeneratedRegex("^[a-z0-9_]+$")]
    private static partial Regex SlugRegex();

    public bool IsValidSlug(string slug)
        => !string.IsNullOrEmpty(slug) && SlugRegex().IsMatch(slug);

    public async Task<BduiTemplateResult?> GetTemplateAsync(string slug, CancellationToken ct)
    {
        var objectName = $"{slug}.json";

        try
        {
            var obj = await _storageClient.GetObjectAsync(_bucketName, objectName, cancellationToken: ct);
            var stream = new MemoryStream();
            await _storageClient.DownloadObjectAsync(_bucketName, objectName, stream, cancellationToken: ct);
            stream.Position = 0;
            return new BduiTemplateResult(stream, obj.ETag);
        }
        catch (Google.GoogleApiException ex) when (ex.HttpStatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
    }
}
```

Note: This uses `MemoryStream` for simplicity (consistent with existing `GoogleBlobStorage.Get()`). Current files are around 100KB but may grow larger. If payloads grow significantly, replace with a pipe stream or `PushStreamContent` to avoid buffering.

### DI Registration

In `ExternalServicesConfiguration.cs` (or a new extension method):

```csharp
builder.Services.AddSingleton<IBduiTemplateService>(sp =>
    new BduiTemplateService(
        sp.GetRequiredService<StorageClient>(),  // already registered
        builder.Configuration["BduiTemplates:BucketName"]!));
```

`StorageClient` is already registered as a singleton in `ExternalServicesConfiguration.cs:44-53`.

Execution Order
---------------

1. **Create GCS bucket** — `tofu-bdui` (dev) and `tofu-bdui-production` (prod). Grant read access to the existing service account used by Invoices.Backend.
2. **Upload template files** — place the JSON files into the bucket.
3. **Implement endpoint** — controller + service + config in Invoices.Backend.
4. **Deploy to dev** — verify in test environment.
5. **Wire up mobile clients** — FS worker app calls the endpoint during onboarding.

Testing
-------

- **Happy path**: known slug returns 200 + valid JSON + correct Content-Type
- **Unknown slug**: returns 404
- **Invalid slug**: returns 400 (special characters, path traversal attempts like `../secrets`)
- **Valid slug, no template**: returns 404
- **Cache headers**: response has `Cache-Control` and `ETag`
- **No auth required**: request without Authorization header succeeds

Key Decisions
-------------

| Decision | Rationale |
|----------|-----------|
| GCS bucket, not DB | Static assets don't belong in a database. GCS is the existing pattern. Content can be updated without deployments. |
| Flat bucket layout | Only a handful of templates. No need for folders or prefixes yet. |
| Slug validation regex | Security: prevents path traversal and unexpected GCS paths. |
| MemoryStream (not true streaming) | Current files are around 100KB which fits in memory. Matches existing `GoogleBlobStorage.Get()` pattern. If files grow significantly larger, switch to pipe streaming. |
| Separate bucket (not reusing `contents`) | BDUI templates are a distinct concern from user-uploaded content. Separate bucket = separate access control, easier to audit. |
| 5-min cache | Templates change rarely. Short enough to pick up updates same day, long enough to reduce GCS reads. |
| Plain JSON response (no wrapper) | Explicit requirement from mobile team. Keeps the contract simple — response body IS the template. |
