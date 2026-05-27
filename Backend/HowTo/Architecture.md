Backend Architecture Overview
=============================

This document explains the high‑level backend architecture used in Tofu.Auth
and related services.

Layers
------

- **Domain**  
  Core business concepts, invariants, and domain services.

- **Application**  
  Use‑cases, orchestration, and application‑level services. Depends on Domain.

- **API**  
  HTTP endpoints, request/response contracts, authentication and authorization.

- **Persistence**  
  Database models, repositories, migrations, and infrastructure concerns.

DTOs and Domain Models
----------------------

- Domain types represent core business meaning.
- DTOs (request/response contracts) are used for external APIs.
- When mapping between domain and DTO:
  - keep mapping in a single place (helpers or extension methods);
  - avoid spreading `switch` statements across the codebase.

Validation
----------

- Prefer built‑in .NET validation attributes (`[EmailAddress]`, `[Phone]`, `[Range]`, etc.).
- Use `[Required]` on DTOs where a value must be provided.
- For more complex rules (email format, password strength, business constraints),
  use dedicated validators or domain services, not ad‑hoc checks in controllers.

Enums and API Contracts
-----------------------

- Expose enums through DTO‑specific enum types if API representation differs
  from internal domain enums.
- Keep API enums alongside their DTO contracts.

Where to go next
----------------

- For authorization details, see: `Backend/HowTo/Authorization.md`
- For backend coding conventions, see: `Backend/HowTo/CodeStyle.md`
