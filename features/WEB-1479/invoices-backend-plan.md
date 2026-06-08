# WEB-1479 — Auth handoff implementation plan

Developer plan for the auth handoff (mobile → web session transfer): Tofu.Auth issues a single-use opaque handoff token for the authenticated user; the web app exchanges it for a Firebase custom token and signs in. Decisions and rationale live in the sibling docs repo — `Local.Docs/features/WEB-1479/` (`README.md` — plan and decisions; `client-flow.md` — wire contracts and client edge cases; `web-spike.md` — naming/storage research). This doc only says **what to code and where**.

Roles: **Tofu.Auth.Backend (producer)** owns the token lifecycle — generation, SHA-256-at-rest, TTL, atomic single-use claim, custom-token mint. **Invoices.Backend (BFF, consumer)** is a thin proxy via the `Tofu.Auth.Api.Client` NuGet, shaping responses into the standard BFF envelope (`{ "result": … }` / `{ "error": { code, … } }`).

> Build order: producer merges first; `publish-client.yaml` publishes the client NuGet; the BFF does not compile before the package version with the two new client methods exists.

## Endpoints (short)

| Endpoint | Auth | In → Out |
|---|---|---|
| `POST /v1/handoff-tokens` (Tofu.Auth) | JWT | — → `{ token, expiresInSeconds }` |
| `POST /v1/handoff-tokens/exchange` (Tofu.Auth) | anonymous | `{ token }` → `{ customToken }` |
| `POST /api/authenticate/handoff-tokens` (BFF) | JWT | proxy of issue |
| `POST /api/authenticate/handoff-tokens/exchange` (BFF) | anonymous | proxy of exchange |

- Token travels in the **body** on exchange (never path/query — access logs).
- Exchange errors, keyed by `error.code` (the web contract; HTTP status is secondary): `handoff_token_used` · `handoff_token_expired` · `invalid_handoff_token`.
- Issue path has no handoff-specific errors — standard authorization errors only.

## New domain entities (Tofu.Auth.Domain)

One new aggregate — `HandoffToken` (`Models/HandoffToken.cs`), FK to `User`:

```csharp
public class HandoffToken : IEntity<Guid>
{
    public const string TokenPrefix = "tht_";   // part of RAW token and of the hashed string; makes leaks greppable

    public required Guid Id { get; init; }
    public required string TokenHash { get; init; }       // SHA-256 of the full prefixed RAW token; unique index
    public required Guid UserId { get; init; }
    public required DateTimeOffset ExpiresAt { get; init; } // CreatedAt + TTL (config, default 120 s)
    public required DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? UpdatedAt { get; private set; }
    public DateTimeOffset? UsedAt { get; private set; }    // mark-used, reap-on-expiry; never deleted on consumption

    public bool IsExpired();
    public bool IsUsed { get; }

    public static HandoffToken Create(Guid userId, string tokenHash, TimeSpan ttl);
}
```

Design notes:

- **No `MarkAsUsed()` on the entity** — claiming must be race-safe, so consumption is an atomic conditional UPDATE in `IHandoffTokenRepository.TryClaimAsync(tokenHash)`; the entity is only re-read for diagnostics (distinguishing used vs expired vs unknown).
- RAW token = `tht_` + Base64Url(32 CSPRNG bytes) via the existing `TokenGenerationUtils`; only the hash is stored.
- TTL bound from config `HandoffToken:HandoffTokenTtl` (`HandoffTokenConfig`, default 120 s).

## Code layout — Tofu.Auth.Backend (producer)

```
src/Tofu.Auth.Domain/
  Models/HandoffToken.cs                                  # the aggregate (structure above)
  Repositories/IHandoffTokenRepository.cs                 # InsertAsync · FindByTokenHashAsync · TryClaimAsync (atomic claim)
  Configuration/HandoffTokenConfig.cs                     # HandoffToken:HandoffTokenTtl (default 120 s)
  Exceptions/HandoffTokenException.cs                     # used / expired / invalid distinctions

src/Tofu.Auth.Application/
  Services/IHandoffTokenService.cs                        # Issue (uid from authenticated context) + Exchange
  Services/HandoffTokenService.cs                         # exchange: TryClaim → mint Firebase custom token (existing port)
  Dto/Responses/IssueHandoffTokenResponse.cs

src/Tofu.Auth.Contracts/
  HandoffTokens/IssueHandoffTokenResponse.cs              # wire contracts shared with Api.Client
  HandoffTokens/ExchangeHandoffTokenRequest.cs
  HandoffTokens/ExchangeHandoffTokenResponse.cs           # { customToken }

src/Tofu.Auth.Persistence/
  Database/EntityConfigurations/HandoffTokenConfiguration.cs  # HandoffTokens table; UNIQUE(TokenHash); index(ExpiresAt)
  Repositories/HandoffTokenRepository.cs                  # incl. TryClaimAsync as conditional UPDATE (UsedAt IS NULL AND not expired)
  Migrations/20260604165607_WEB-1479_HandoffTokens.cs

src/Tofu.Auth.Api/
  Controllers/HandoffTokensController.cs                  # POST v1/handoff-tokens [Authorize]
                                                          # POST v1/handoff-tokens/exchange [AllowAnonymous]

src/Tofu.Auth.Api.Client/
  ITofuAuthApiClient.cs / TofuAuthApiClient.cs            # IssueHandoffTokenAsync · ExchangeHandoffTokenAsync
```

## Code layout — Invoices.Backend (BFF)

```
Src/Invoices.Api/
  Controllers/AuthenticateController.cs                   # touch: two new actions in the existing controller
                                                          #   (Route("api/authenticate"), ITofuAuthApiClient already injected)
                                                          # POST handoff-tokens           [authorized]     → WebHandoffResponseDto
                                                          # POST handoff-tokens/exchange  [AllowAnonymous] → ExchangeWebHandoffResponseDto
  Models/Authenticate/WebHandoffResponseDto.cs            # { token, expiresInSeconds } — DTOs of this controller live in
  Models/Authenticate/ExchangeWebHandoffRequestDto.cs     #   Models/Authenticate/ (controller convention), not Dto/
  Models/Authenticate/ExchangeWebHandoffResponseDto.cs    # { customToken }

Src/Tofu.Auth/                                            # BFF Auth module — wrapper over the Tofu.Auth.Api.Client NuGet
  TofuAuthApiClientDecorator.cs                           # touch: pass-through for IssueHandoffTokenAsync / ExchangeHandoffTokenAsync
  AuthApiExceptionConverter.cs                            # touch: producer handoff errors → handoff_token_used /
                                                          #   handoff_token_expired / invalid_handoff_token
  Tofu.Auth.csproj                                        # touch: bump Tofu.Auth.Api.Client to the version with the new methods
```

Pattern precedent for the BFF slice: the existing `magic-login` proxy in `InvitationsController` — same producer, same client NuGet, same anonymous-exchange shape.
