# Frontend Backend Error Handling

How the frontend (Tofu.Web.Frontend) handles errors from the backend, focusing on `errorCode` and `message` fields.

---

## Error Response Formats

The backend sends errors in two formats, defined in `src/shared/lib/http/types.ts`:

**Format 1 — `APIBodyError`:**
```typescript
{ error: { traceId, code: APIErrorType, message?: string, info?: Record<string, unknown> } }
```

**Format 2 — `APIResultError`:**
```typescript
{ result: { traceId, status, title: string, type: APIErrorType } }
```

**Special case — `APIVersionMismatchError`:**
```typescript
{ error: { traceId, code: 'version_mismatch', message?, info: { actualVersion, submittedVersion } } }
```

---

## Known Error Codes (`APIErrorType`)

Defined in `src/shared/lib/http/types.ts`:

| Error Code                   | Description                      |
|------------------------------|----------------------------------|
| `not_found`                  | Resource not found               |
| `not_delete`                 | Cannot delete                    |
| `forbidden`                  | Access denied                    |
| `version_mismatch`           | Optimistic concurrency conflict  |
| `bad_request`                | Bad request                      |
| `invalid_one_time_password`  | OTP validation failure           |
| `unauthorized`               | Not authenticated                |
| `master_deleted`             | User account deleted             |
| `master_migration_conflict`  | Account migration needed         |
| `platform_already_taken`     | Platform already linked          |
| `internal_server_error`      | Server error                     |
| `token_revoked`              | Token revoked                    |
| `unknown`                    | Fallback                         |

---

## All Specific Error Code Handling Cases

### 1. `master_deleted`
**File:** `src/features/auth/model/platform-auth.ts`
- **Action:** Redirects user to a "deleted account" page

### 2. `master_migration_conflict`
**File:** `src/features/auth/model/platform-auth.ts`
- **Action:** Triggers a migration modal/flow for the user

### 3. `platform_already_taken`
**File:** `src/features/auth/model/platform-auth.ts`
- **Action:** Shows error notification: *"This platform account is already associated with another user..."*

### 4. `magic_link_expired` / `invitation_token_revoked`
**File:** `src/features/auth/model/invitation-auth.ts`
- **Action:** Redirects to invitation expired page
- **Note:** These codes are beyond the `APIErrorType` enum — checked directly on `error.type`

### 5. `magic_link_used`
**File:** `src/features/auth/model/invitation-auth.ts`
- **Action:** Redirects to "already accepted" page

### 6. `token_revoked`
**File:** `src/shared/lib/http/errors.ts` (in `checkErrorByContent`)
- **Action:** Triggers logout globally (handled at HTTP layer)

### 7. `version_mismatch`
**Files:**
- `src/shared/lib/version-mismatch/resolver.ts`
- `src/shared/lib/version-mismatch/save-with-version-conflict-resolution/create-save-with-resolution-effect.ts`
- **Action:** Extracts `actualVersion` and `submittedVersion` from `error.body.error.info`, then retries the operation with the correct version (up to `maxRetries`)

### 8. `not_found`
**Files:**
- `src/shared/clients/model/form.ts` — Falls back to creating a client instead of updating
- `src/features/invoices/model/client.ts` — Sets `$isClientNotFound` state
- `src/features/estimates/model/client.ts` — Sets `$isClientNotFound` state
- `src/features/invoice/model/view.ts` — Sets not-found UI state
- `src/features/job/model/view.ts` — Sets not-found UI state

### 9. `client_has_jobs`
**File:** `src/features/client/model/delete.ts`
- **Action:** Checks `error.body.error.code === 'client_has_jobs'` and shows a modal about related jobs
- **Note:** This code is checked on the raw body, not on `error.type`

### 10. `invalid_one_time_password`
**File:** `src/features/auth/model/otp.ts`
- **Action:** Error type is extracted and tracked as an analytics event

---

## How `message` Is Used

| Where | What happens |
|---|---|
| `src/shared/lib/notifications/notifications.tsx` | Primary display channel — shows `error.message` in a red toast notification. Falls back to *"Something went wrong. Please try again later."* |
| `src/shared/lib/http/parsers.ts` | Sends `error.message` to **Amplitude** analytics as `error_message` field |
| `src/shared/lib/http/parsers.ts` | Sends full error context to **Sentry** with `traceId` as a tag |
| `src/features/stripe-onboarding/model/error-handling.ts` | Stores `error.message` in a store, falls back to *"Failed to enable payments"* |
| Various feature files | Many features pipe `effectFx.failData` directly into `showErrorNotificationFx`, which displays the backend's `message` as-is |

---

## Error Parsing Flow

1. Backend response comes through `ky`
2. `checkErrorByContent()` in `src/shared/lib/http/errors.ts` tries to parse the body as `APIBodyError` or `APIResultError`
3. If matched, it creates an `APIError` with `type` (from `code` or `type` field) and `message` (from `message` or `title` field)
4. If no body match, `checkErrorByStatus()` maps HTTP status to an error type
5. The resulting `APIError` flows through Effector effects (`.failData`) where features handle specific codes or pass through to the generic notification system
