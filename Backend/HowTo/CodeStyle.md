Backend Code Style
==================

This document summarizes backend‑specific coding conventions that complement
the main repository guidelines.

Language and Structure
----------------------

- C#, 4‑space indentation.
- Keep application logic in `*.Application`, domain logic in `*.Domain`,
  infrastructure in `*.Persistence`.
- Shared cross‑cutting code belongs in `*.Common` or `*.Common.AspNet`.

Constructors and Guards
-----------------------

- Do not use C# primary constructors in backend projects.
- Do not use `EnsureThat` / `EnsureArg`; use regular .NET guard clauses.
- Do not add null‑checks for constructor‑injected dependencies.

Controllers and APIs
--------------------

- Avoid `[ProducesResponseType]` attributes; keep contracts in XML docs.
- Keep controllers thin: delegate to Application or Domain services.

Enums and DTOs
--------------

- Keep enum-to-DTO mapping in a single place (helper/extension).
- Do not scatter `switch` statements on enums across the codebase.

### Domain Enums (internal)

Domain enums live in `*.Core`, `*.Domain`, or `*.Common` and represent internal
business state. They **must always** start with `Unknown = 0`:

```csharp
public enum JobStatus
{
    Unknown = 0,   // required — protects against uninitialized values and DB defaults
    Draft = 1,
    Scheduled = 2,
    InProgress = 3,
    Completed = 4
}
```

Why `Unknown = 0`:
- C# initializes enums to `0` by default — without `Unknown`, an uninitialized
  field silently becomes the first meaningful value.
- MongoDB and other stores may return `0` for missing or migrated fields.
- Makes it explicit that a value has not been set, enabling guard clauses
  like `if (status == JobStatus.Unknown) throw ...`.

### Non-domain Enums (BFF / DTO)

BFF / API layer must **never reference core enums directly** in DTOs, request
models, or response models. Always create a separate `*Dto` enum with JSON
serialization attributes:

```csharp
[JsonConverter(typeof(JsonStringEnumConverter)),
 Newtonsoft.Json.JsonConverter(typeof(StringOnlyEnumConverter))]
public enum ModalTypeDto
{
    EstimateToJob = 1
}
```

Rules for DTO enums:
- Do **not** include `Unknown` — never expose it to API consumers.
- Start values at `1`, aligned with the domain enum.
- Add `[JsonConverter]` attributes for both `System.Text.Json` and
  `Newtonsoft.Json` so values serialize as strings (not integers).
- Use `StringOnlyEnumConverter` (Newtonsoft) to reject integer input.
- The mapping layer must handle the `Unknown` case from domain enums — either
  throw or map to a sensible default.

Logging
-------

- Wrap interpolated parameters in single quotes in structured log templates:
  ```csharp
  _logger.LogWarning(ex, "Failed to upload content '{ContentId}'", contentId);
  _logger.LogInformation("Notification transition '{ProcessType}'/'{AccountId}': '{OldState}' → '{NewState}'",
      processType, accountId, state, result.NewState);
  ```
- This improves readability in log viewers — quoted values are visually distinct
  from surrounding text, especially when values are empty strings or contain spaces.

Mapping Methods
---------------

- Prefer single-instance mapping methods; let callers use `.Select(...)` for collections.

FluentResults — Result Pattern
------------------------------

Use `FluentResults` for domain methods that need to return **warnings** (soft
rules) alongside their normal return value. Hard invariants still throw
exceptions.

### When to use Result vs exceptions

| Scenario | Pattern |
|----------|---------|
| Hard invariant (must never be violated) | Throw exception |
| Entity/aggregate lookup in handler | Throw `EntityNotFoundException` |
| Soft rule (advisory, operation still succeeds) | Return `Result` with warning |
| Worker-initiated actions with expected failures | Return `Result` with error |

### Domain warnings

Warnings extend `Success` and implement `IDomainWarning`. The operation
succeeds; the warning is advisory info that propagates through the call stack.

```csharp
// 1. Define the warning (Domain layer)
public class AttachmentLimitWarning : Success, IDomainWarning
{
    public Guid VisitId { get; }
    public int Count { get; }
    public AttachmentLimitWarning(Guid visitId, int count, int limit)
        : base($"Visit '{visitId}' has {count} attachments, exceeding limit of {limit}")
    {
        VisitId = visitId;
        Count = count;
    }
}

// 2. Attach in the domain method (returns Result<T> or Result)
var result = Result.Ok(events);
if (Attachments.Count > Job.MaxAttachmentsPerVisit)
    result.WithSuccess(new AttachmentLimitWarning(Id, Attachments.Count, Job.MaxAttachmentsPerVisit));
return result;

// 3. Propagate in the aggregate (parent absorbs child reasons)
return visitResult.ToResult();               // Result<T> → Result, keeps all reasons
result.WithReasons(childResult.Reasons);     // accumulate in a loop

// 4. Log in the handler (one-liner via extension)
job.UpdateVisits(visits, team, occurredAt, createdBy)
    .LogWarnings(_logger);
```

### Rules

- **Use `WithSuccess()`** (not `WithReason()`) for warnings — semantically
  clearer that the operation succeeded with advisory info.
- **Use `ToResult()`** to convert `Result<T>` → `Result` while preserving
  all reasons. Do not manually rebuild with `Result.Ok().WithReasons(...)`.
- **Use `WithReasons(child.Reasons)`** when accumulating warnings from
  multiple child results in a loop.
- **Use typed warning classes**, not strings. Consumers filter with
  `.Successes.OfType<AttachmentLimitWarning>()`.
- **All warning classes implement `IDomainWarning`** so the shared
  `LogWarnings()` extension can find them.
- **Log at the handler level** using `result.LogWarnings(_logger)`. Domain
  entities never reference `ILogger`.
- **Do not use `Result` when there is no failure or warning scenario** — plain
  return types are clearer.

### Namespace conflict with CSharpFunctionalExtensions

`Jobs.Domain` has a global using for `FluentResults`, so `Result` resolves to
`FluentResults.Result` by default. The one method that uses
`CSharpFunctionalExtensions.Result` (`TryUpdateVisitStatusByWorker`) must
fully qualify it:

```csharp
public CSharpFunctionalExtensions.Result<bool, VisitUpdateError> TryUpdateVisitStatusByWorker(...)
```

Testing
-------

- Unit tests in `*.UnitTests` projects; API tests in `*.Api.Tests.Functional`.

### Unit Test Patterns

**Factory Methods**: Place at the **end of the test class** with default parameters.
- Call domain factory methods (e.g., `Job.Create`) not object initializers
- Clear domain events for cleaner assertions: `job.ClearDomainEvents()`

**Consolidate Tests**: Merge related assertions into single tests.

**Use Theory**: For parameterized input/output combinations.

**Combine Edge Cases**: Test related guard conditions together.

### Integration Test Patterns

**Request Builders**: Use helper methods with defaults to highlight test-relevant params.
- `CreateXxxRequest(...)` for new entities
- `UpdateXxxRequest(id, ...)` for updates

**Assertion Helpers**: Extract repeated assertion patterns (3+) into shared
`Setup/<Entity>Assertions.cs` with optional parameters.
