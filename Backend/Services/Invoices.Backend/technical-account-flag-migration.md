# INVC-3562: Switch to Technical Account Flag

Replace runtime technical-account detection (gRPC calls, BusinessName checks) with reads from the persisted `IsTechnical` flag on `Account`.

## Goal

Eliminate expensive runtime computations in `AuthService` and inconsistent BusinessName-based checks across controllers. All code should use `Account.IsTechnical` instead.

## Null Handling

`IsTechnical` stays `bool?`. Treat `null` as regular (non-technical): use `IsTechnical == true` to detect technical accounts, `IsTechnical != true` for regular.

---

## Changes

### 1. AuthService — eliminate gRPC calls and refactor activity loading

**File:** `Invoices.Implementation.Services/Authentication/AuthService.cs`

#### 1a. Remove `IsRealAccount`, batch-fetch non-technical accounts, then load activity

Remove the `IsRealAccount` static method entirely.

Add `FindManyAsync(IReadOnlyCollection<string> accountIds, bool excludeTechnical, CancellationToken ct)` to `IAccountsRepository` — batch reads accounts in a single MongoDB query with `$in` filter. When `excludeTechnical: true`, filters `IsTechnical != true` at the database level.

Refactor `GetOwnedAccountInfos`:
1. Batch-fetch non-technical accounts via `FindManyAsync`
2. Batch-fetch logos via `ILogoService.FindLogoUrls` (single `$in` query on `Logo._id`)
3. Use `RunInParallelAsync` only for gRPC activity calls (when `includeActivity: true`)

This avoids N individual `Find` calls, N individual logo queries, and wasted gRPC calls for technical accounts.

#### 1b. Batch logo fetching

Add `FindManyAsync(IReadOnlyCollection<string> accountIds, CancellationToken ct)` to `ILogosRepository` — batch reads logos with `$in` on `_id` (since `Logo.AccountId` is `[BsonId]`).

Add `FindLogoUrls(IReadOnlyCollection<string> accountIds, CancellationToken ct)` to `ILogoService` — returns `Dictionary<string, string>` mapping accountId → logo URL. Single DB query, URL formatting in-memory.

Logos are fetched upfront before the parallel activity fan-out, so the `RunInParallelAsync` only handles gRPC calls.

#### 1c. Keep `includeActivity` as single flag

`GetOwnedAccountInfos` keeps the original `includeActivity` boolean. When `true` — make gRPC calls and populate all 4 activity fields (totals + last dates). When `false` — skip gRPC calls entirely, no parallel calls at all (just two batch DB queries + LINQ projection).

The `Last*Activity` fields cost nothing extra since the gRPC data is already fetched for totals, so a dedicated flag is unnecessary.

#### 1d. Update callers in AccountController V3

**File:** `Invoices.Api/Controllers/V3/AccountController.cs`

| Endpoint | `includeActivity` | Effect |
|----------|-------------------|--------|
| `GET /all-by-account-id` | `false` | No gRPC calls — main perf win |
| `GET /all` | `includeActivity ?? false` | Same as original — gRPC only when requested |
| `GET /all-by-platform-user` | `true` | Full activity loaded |

### 2. InvitationsController — use flag instead of BusinessName

**File:** `Invoices.Api/Controllers/InvitationsController.cs` (lines 43-47)

Current:
```csharp
var businessName = await _accountsRepository.GetBusinessName(AccountId) ?? string.Empty;
if (string.IsNullOrWhiteSpace(businessName))
{
    throw new TechnicalAccountNotAllowedException(AccountId, "create_invitation");
}
```

New — fetch account, check flag, still need businessName for the invitation request:
```csharp
var account = await _accountsRepository.Find(AccountId, ct);
if (account is null || account.IsTechnical == true)
{
    throw new TechnicalAccountNotAllowedException(AccountId, "create_invitation");
}
var businessName = account.BusinessName ?? string.Empty;
```

### 3. WorkerController — use flag instead of BusinessName

**File:** `Invoices.Api/Controllers/WorkerController.cs` (lines 161-181)

Current `CreateWorkerBusinessDto` skips accounts with empty BusinessName.

New:
```csharp
private async Task<WorkerBusinessDto?> CreateWorkerBusinessDto(
    string accountId,
    Tofu.Auth.Contracts.Invitations.RoleLevelDto roleLevel,
    CancellationToken ct)
{
    var account = await _accountsRepository.Find(accountId, ct);

    if (account is null || account.IsTechnical == true)
    {
        _logger.LogWarning("Skipping worker business for account '{AccountId}' — technical or not found", accountId);
        return null;
    }

    return new WorkerBusinessDto
    {
        AccountId = accountId,
        Name = account.BusinessName ?? string.Empty,
        Role = roleLevel.ToRoleLevelDto()
    };
}
```

Note: already fetches the full account — no extra DB call.

---

## Execution Order

1. `IAccountsRepository.cs` / `AccountsRepository.cs` — add `FindManyAsync` with `excludeTechnical`
2. `ILogosRepository.cs` / `LogosRepository.cs` — add `FindManyAsync` for batch logo fetch
3. `ILogoService.cs` / `LogoService.cs` — add `FindLogoUrls` batch method
4. `IAuthService.cs` — update interface signature (`includeActivity`)
5. `AuthService.cs` — remove `IsRealAccount`, batch accounts + logos, parallel only for gRPC
6. `AccountController.cs` V3 — update three callers with `includeActivity`
7. `InvitationsController.cs` — switch to flag check
8. `WorkerController.cs` — switch to flag check
9. Update tests (`AuthServiceTest.cs`, `AccountsRepositoryMock.cs`)

## Files Affected

| File | Change |
|------|--------|
| `Invoices.Core/Repositories/IAccountsRepository.cs` | Add `FindManyAsync` with `excludeTechnical` filter |
| `Invoices.Implementation.MongoDb/Repositories/AccountsRepository.cs` | Implement `FindManyAsync` with `$in` + `IsTechnical` filter |
| `Invoices.Core/Repositories/ILogosRepository.cs` | Add `FindManyAsync` for batch logo fetch |
| `Invoices.Implementation.MongoDb/Repositories/LogosRepository.cs` | Implement `FindManyAsync` with `$in` on `_id` |
| `Invoices.Common/Services/Images/ILogoService.cs` | Add `FindLogoUrls` batch method |
| `Invoices.Common/Services/Images/LogoService.cs` | Implement `FindLogoUrls` |
| `Invoices.Implementation.Services/Authentication/AuthService.cs` | Remove `IsRealAccount`, batch accounts + logos, parallel only for gRPC |
| `Invoices.Api/Controllers/V3/AccountController.cs` | Update three callers with `includeActivity` |
| `Invoices.Api/Controllers/InvitationsController.cs` | Use IsTechnical flag |
| `Invoices.Api/Controllers/WorkerController.cs` | Use IsTechnical flag |
| `Invoices.Tests/Services/AuthServiceTest.cs` | Update for new signature, batch mocks |
| `Invoices.Tests/Controllers/AccountsRepositoryMock.cs` | Add `FindManyAsync` to mock |
