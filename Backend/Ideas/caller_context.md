# Idea: CallerContext — Unified Request Identity

## Problem

The current auth flow stores caller identity across multiple scattered locations:

```
Middleware sets:
  HttpContext.Items["UserId"]              → MasterUserId (string)
  HttpContext.Items["AuthenticationInfo"]   → AuthenticationInfo record
    .MasterUserId                          → same string
    .MasterUser?.Id                        → same string (from DB entity)
  HttpContext.Items["AccountId"]           → AccountId (string)
```

Controllers read the same value through four different patterns:

```csharp
AuthenticationInfo?.MasterUser?.Id              // JobsController, TeamController
AuthenticationInfo?.MasterUserId                // WorkerController
httpContext.GetMasterUserIdFromAuthenticationApi() // ActiveSubscriptionAuthorizationHandler
httpContext.Items["UserId"]                     // AccountIdentifiersDto model binder
```

This makes the codebase harder to reason about, especially for signature-auth users where all of these are null/missing.

## Two Concerns Mixed Together

`AuthenticationInfo` bundles caller identity and user entity:

| Concern | Data | Who Needs It |
|---------|------|-------------|
| **Caller identity** | `AccountId`, `MasterUserId`, auth method | Every command, every service |
| **User entity** | `MasterUser` (OwnedAccounts, PlatformUserLinks) | Account management controllers only |

## Proposal: Separate Identity from Entity

### CallerContext (identity only)

```csharp
// Invoices.Common
public interface ICallerContext
{
    string AccountId { get; }
    string? MasterUserId { get; }
    bool HasAuthenticatedUser => MasterUserId != null;
}

public class CallerContext : ICallerContext
{
    public string AccountId { get; set; } = "";
    public string? MasterUserId { get; set; }
}
```

Registered as scoped, populated by middleware:

```csharp
services.AddScoped<CallerContext>();
services.AddScoped<ICallerContext>(sp => sp.GetRequiredService<CallerContext>());
```

### Middleware Populates Once

```csharp
// AuthenticationApi path
var caller = context.RequestServices.GetRequiredService<CallerContext>();
caller.AccountId = authenticationInfo.AccountId;
caller.MasterUserId = authenticationInfo.MasterUserId;

// Signature path
var caller = context.RequestServices.GetRequiredService<CallerContext>();
caller.AccountId = accountId;
// MasterUserId stays null
```

### Works in Any Host

No HTTP dependency — each host populates it at its boundary:

- **API**: middleware writes to it
- **Worker**: message handler writes to it before dispatching
- **Tests**: `new CallerContext { AccountId = "x", MasterUserId = "y" }`

### After

```
Middleware populates:
  CallerContext             → identity (AccountId, MasterUserId)
  AuthenticationInfo        → entity (MasterUser), only for AuthenticationApi path
  HttpContext.Items          → only non-auth stuff (ProductKey, ClientEventTime, RequestId)
```

BaseController:

```csharp
// 1 way for identity
protected ICallerContext Caller => HttpContext.RequestServices.GetRequiredService<ICallerContext>();

// entity only when needed (account management)
protected AuthenticationInfo? AuthenticationInfo => ...;
```

Controllers:

```csharp
// Before (inconsistent)
MasterUserId: AuthenticationInfo?.MasterUser?.Id
MasterUserId: AuthenticationInfo?.MasterUserId

// After (one pattern)
MasterUserId: Caller.MasterUserId
```

Application services that need auth awareness:

```csharp
public class JobWorkerService(ITofuAuthApiClient authClient, ICallerContext caller)
{
    public async Task<Team> GetTeam(string accountId, CancellationToken ct)
    {
        if (!caller.HasAuthenticatedUser)
            return Team.Empty;
        // ...
    }
}
```

## What This Enables

Convention established by [5.4 anon users fix](../../features/jobs/implementation/5_worker_users/5.4_anon_users.md): services that need Auth API access check `MasterUserId != null`. CallerContext makes this a first-class pattern instead of threading `string? masterUserId` through every method.

## Replaces AuthUserContextProvider

`AuthUserContextProvider` is a singleton that uses `AsyncLocal<AuthUserContext?>` to carry per-request platform context (`Platform`, `ProductKey`, `DeviceId`) to Auth service gRPC calls. This pattern exists because the singleton can't use scoped lifetime directly.

CallerContext is already scoped — it can absorb these fields and eliminate `AuthUserContextProvider` entirely:

```csharp
public interface ICallerContext
{
    string AccountId { get; }
    string? MasterUserId { get; }
    bool HasAuthenticatedUser => MasterUserId != null;

    // Replaces AuthUserContextProvider
    Platform? Platform { get; }
    string? ProductKey { get; }
    string? DeviceId { get; }
}
```

Middleware already sets all these values in the same place (`AccountAuthenticationMiddleware`), so populating a single scoped object is simpler than maintaining a separate singleton+AsyncLocal.

What gets removed:
- `AuthUserContextProvider` (singleton + AsyncLocal)
- `IAuthUserContextProvider` / `IAuthUserContextWriter` interfaces
- The `Tofu.Auth.Common.Models.AuthUserContext` dependency from the API project

Auth gRPC clients that currently inject `IAuthUserContextProvider` would inject `ICallerContext` instead.

## Scope

Moderate refactor: middleware + BaseController + controller call sites. Each change is mechanical — replace scattered reads with `Caller.MasterUserId`.

`AuthenticationInfo` stays for controllers that need the `MasterUser` entity (account management, invitations). Commands stay explicit — they keep carrying `AccountId`/`MasterUserId` as fields.
