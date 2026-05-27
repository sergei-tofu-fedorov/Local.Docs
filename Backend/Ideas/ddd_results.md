# Idea: Unify Result Types and Drop Exceptions in Job/Visit Domain

## Problem

`Src/Jobs/Jobs.Domain/Jobs.Domain.csproj` references **two** result libraries:

```xml
<PackageReference Include="CSharpFunctionalExtensions" Version="3.6.0" />
<PackageReference Include="FluentResults" Version="4.0.0" />
```

In practice only `FluentResults` is currently used in domain code (`Job.cs`, `Visit.cs`, `Job.Attachments.cs`, `Warnings/DomainWarning.cs`, plus `Jobs.Application/Extensions/ResultLoggingExtensions.cs`). `CSharpFunctionalExtensions` is referenced but barely used. Two libraries solving the same problem in the same project is dead weight — different APIs, different `Result`/`Success`/`Failure` semantics, two sets of conventions to know.

At the same time, the Job/Visit code still throws domain exceptions in many places: ~48 `throw new *Exception` calls across 25 files in `Src/Jobs/`, including command handlers (`UpsertJobCommandHandler`, `UpdateVisitStatusCommandHandler`, `DeleteJobCommandHandler`, etc.), domain models (`Job.cs`, `Visit.cs`, `Team.cs`), and services (`JobWorkerService`, `JobClientsService`, `JobEstimateService`). So the domain is split between two error styles: half "return a `Result`", half "throw and let middleware translate".

## Idea

Pick **one** result library and one error style for the Job/Visit module:

1. **Drop `FluentResults`. Standardise on `CSharpFunctionalExtensions`.** It's the more idiomatic .NET option (`Result<T, E>` with strongly‑typed errors, `Maybe<T>`, `Result.Combine`, railway‑oriented `Bind`/`Map` extensions), it's already on the dependency list, and it composes better with the rest of the code that already uses functional extensions. The migration is mechanical: `Result.Ok()` → `Result.Success()`, `Result.Fail("...")` → `Result.Failure(error)`, `IResult` → `Result`/`Result<T>`.
2. **Replace domain `throw` with `Result<T, DomainError>` returns** in Job/Visit code paths. Validation, "entity not found", "operation not allowed in current state", "concurrency conflict" — all of these are expected outcomes, not exceptional ones, and should travel back to the caller as typed errors.
3. **Translate at the boundary.** Command/query handlers return `Result<T, DomainError>`; controllers map `DomainError` → HTTP status (404 / 409 / 422 / 400) in one place, instead of relying on exception‑filter middleware to do it via runtime type checks.
4. **Keep exceptions for what they're for** — bugs, infrastructure failures (DB unreachable, gRPC timeout), and assertions. These should still bubble up and become `500`s.

## Handling Warnings Without FluentResults

`Result<T, E>` from CSharpFunctionalExtensions is intentionally two‑state — there's no "metadata bag on success". The replacement: **warnings live on the `Job` aggregate, alongside the domain events it already accumulates.** The application layer drains both after a successful save.

This matches the existing pattern in the codebase. `Visit.cs:139–148` already returns a `List<JobDomainEvent>` (`PhotoAdded(...)`) on the same code path that today returns a `Result.WithSuccess(new AttachmentLimitWarning(...))`. We just add a parallel channel for warnings:

```csharp
public class Job
{
    private readonly List<JobDomainEvent> _events = new();
    private readonly List<DomainWarning> _warnings = new();

    public IReadOnlyList<JobDomainEvent> PendingEvents => _events;
    public IReadOnlyList<DomainWarning> PendingWarnings => _warnings;
    public void ClearPending() { _events.Clear(); _warnings.Clear(); }

    public Result<Unit, DomainError> AddVisitAttachment(...)
    {
        ...                                       // invariant checks → Result.Failure(...)
        _events.Add(JobDomainEvent.PhotoAdded(...));
        if (visit.Attachments.Count > MaxAttachmentsPerVisit)
            _warnings.Add(new AttachmentLimitWarning(visit.Id, visit.Attachments.Count, MaxAttachmentsPerVisit));
        return Unit.Value;
    }
}
```

Command handler:

```csharp
var result = job.AddVisitAttachment(...);
if (result.IsFailure) return result.MapError(MapToHttpError);

await _repo.Save(job, ct);

foreach (var w in job.PendingWarnings)
    _logger.LogWarning("{WarningType}: {Message}", w.GetType().Name, w.Message);

job.ClearPending();
return Result.Success();
```

`DomainWarning` stays as a base type, but loses its `: Success` (FluentResults) inheritance — it becomes a plain abstract record. Existing warning types (`AttachmentLimitWarning`, …) are unchanged from the consumer's POV.

### Why this and not the alternatives

- **Wrap the value (`record VisitOutcome(events, warnings)`)** — works but pollutes every signature; the warnings list is empty for ~99% of calls.
- **Custom `ResultWithWarnings<T, E>` type** — reinvents what we just removed. If we end up here, keep FluentResults instead.
- **Treat warnings as just another `JobDomainEvent` variant** — the most DDD‑pure option, but couples logging behaviour to the event‑dispatch pipeline. `PendingWarnings` keeps the two cleanly separated: events are about *what happened*, warnings are about *what the operator should know*.

The chosen pattern is a small in‑house composition of two well‑documented patterns: the **collect‑on‑aggregate domain events pattern** (Bogard / Microsoft Learn / Vernon) and the **Notification pattern** (Fowler / Grzybek). It's not a textbook DDD pattern in its own right but it composes from two that are. See references at the bottom.

## Why now

- Job/Visit is the most actively developed area of the backend. Every new command handler currently has to make the same "throw or return Result" decision and pick one of two libraries. That choice should be made once.
- The split forces controllers and middleware to handle both paths (typed errors *and* exception filters), which makes error responses inconsistent and harder to test.
- Removing one of the two NuGet packages is a measurable cleanup with no behaviour change.

## Open Questions

- **Scope:** start with new code only (any new handler returns `Result<T, DomainError>`, no new exceptions), then migrate the existing 25 files incrementally? Or do a single sweep on Job/Visit before touching anything else?
- **`DomainError` shape:** flat enum + message, hierarchical record types (`NotFound`, `Conflict`, `Validation`), or a small union via abstract base + sealed records? The boundary mapper is what cares — pick whatever makes that one switch easiest.
- **Cross‑module impact:** Job/Visit calls into other services that still throw. The boundary at the call site needs to translate their exceptions into `DomainError`, or those services follow suit. Where do we draw the line for this first pass?
- **Test fallout:** 48 exception throws probably correspond to a comparable number of `Assert.Throws<...>` tests. Migration cost is mostly here, not in the production code.

## References

- [Designing validations in the domain model layer — Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/domain-model-layer-validations) — official MS DDD guide; recommends the Notification pattern for accumulating multiple validation messages.
- [Domain Model Validation — Kamil Grzybek](http://www.kamilgrzybek.com/design/domain-model-validation/) — explicitly distinguishes errors / warnings / info as severity levels in a validation result.
- [A Better Domain Events Pattern — Jimmy Bogard](https://lostechies.com/jimmybogard/2014/05/13/a-better-domain-events-pattern/) — the canonical .NET reference for collecting events on aggregates and dispatching them in the unit‑of‑work. Same shape we use for warnings.
- [Domain events: Design and implementation — Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/domain-events-design-implementation) — production scaffolding for the collect‑and‑drain pattern.
- [Advanced error handling techniques — Vladimir Khorikov](https://enterprisecraftsmanship.com/posts/advanced-error-handling-techniques/) — counter‑position: warnings shouldn't ride on `Result<T, E>`. Worth reading to understand why we keep them on the aggregate instead of bolting them onto the result type.
