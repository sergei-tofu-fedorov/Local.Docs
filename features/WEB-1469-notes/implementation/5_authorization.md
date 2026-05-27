# Step 5: Authorization

> Reference: [`../overview.md` → Authorization](../overview.md#authorization),
> [`3_application_layer.md`](3_application_layer.md), [`4_api_layer.md`](4_api_layer.md).

Authorization splits across two layers:

1. **Permission system** — gate at the endpoint level: who is allowed to call this route at all
   (`note.view` / `note.manage`).
2. **Handler logic** — content-level rules the permission system cannot express
   (Private hidden from Worker, own-vs-others edit, visit-completion lock).

This step covers the permission-system half. The handler-side rules live in step 3 — the
permission attributes here only decide whether the call reaches a handler in the first place.

---

## 5.1 Permission keys

**File:** `Src/Tofu.Permissions.Shared/Domain/PermissionKeys.cs`.

```csharp
public static class Note
{
    public const string View   = "note.view";    // GET /api/notes/{sync,/all,/{id}}
    public const string Manage = "note.manage";  // PUT /api/notes, DELETE /api/notes/{id}
}
```

Naming mirrors `PermissionKeys.Client` (`client.view` / `client.manage`). The string literals
are part of the public contract — they appear in `AuthorizeAction` attributes, the access
registry, denial responses, and any future external policy override.

---

## 5.2 `AccessRegistry` entries

**File:** `Src/Tofu.Permissions.Shared/Domain/AccessRegistry.cs`.

Both keys open to Admin and Worker on every plan — no paywall:

```csharp
// Notes — open to all plans, no paywall. Worker-vs-Admin distinctions
// (Private hidden from Worker, own-vs-others edit, visit-completion lock)
// live in the application layer (step 3), not in the permission system.
yield return new AccessPolicy(PermissionKeys.Note.View,   AdminAndWorker, AllPlans);
yield return new AccessPolicy(PermissionKeys.Note.Manage, AdminAndWorker, AllPlans);
```

Both policies use the existing `AdminAndWorker` / `AllPlans` constants — no new constant
needed.

Result: `[AuthorizeAction(...)]` succeeds for any authenticated tenant user on any plan; the
deeper checks happen inside the handlers via the `CallerRole` parameter the controller
forwards.

---

## 5.3 Decorator usage

Covered by step 4 — the controller carries:

- `[AuthorizeAction(PermissionKeys.Note.View)]` on `GET /sync`, `GET /{id}`, `GET /all`.
- `[AuthorizeAction(PermissionKeys.Note.Manage)]` on `PUT`, `DELETE /{id}`.

`AccessMiddleware` matches the attribute against `AccessRegistry` at runtime — no per-action
registration on the route itself.

---

## Execution Checklist

| # | Task | Files |
|---|------|-------|
| 5.1 | `PermissionKeys.Note.View` / `Note.Manage` constants | `Src/Tofu.Permissions.Shared/Domain/PermissionKeys.cs` |
| 5.2 | `AccessRegistry` entries (`AdminAndWorker`, `AllPlans`) for both keys | `Src/Tofu.Permissions.Shared/Domain/AccessRegistry.cs` |
| 5.3 | `[AuthorizeAction(...)]` decorators on `NotesController` (already listed in step 4) | `Src/Invoices.Api/Controllers/NotesController.cs` |

| 5.x | Tofu.Auth role-permission seed grants `note.view` / `note.manage` to Admin and Worker | separate `Tofu.Auth.Backend` deploy — out of scope for this PR |
