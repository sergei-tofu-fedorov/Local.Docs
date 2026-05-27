Invoices.Backend Service
========================

This folder contains backend documentation for the Invoices.Backend service.

Contents
--------

- Local rules for DTOs and enums:
  - `Backend/Services/Invoices.Backend/CodeStyle.md`
- User model and authentication:
  - `Backend/Services/Invoices.Backend/Users.md`
- Accounts and ownership:
  - `Backend/Services/Invoices.Backend/Accounts.md`
 - Persistence and data ownership:
  - `Backend/Services/Invoices.Backend/Persistence.md`
- Jobs application services (command handler orchestration):
  - `Backend/Services/Invoices.Backend/Jobs-Application-Services.md`
- PDF ZIP streaming flow (how streaming PDF export works end-to-end):
  - `Backend/Services/Invoices.Backend/PDF_ZIP_FLOW.md`

Persistence
-----------

- Invoices.Backend does not own core invoices/estimates persistence. The main
  persistence model is documented under:
  - `Backend/Services/Tofu.Invoices/Persistence.md`

Local rules
-----------

When you add documentation for Invoices.Backend (API, validation, integration details,
error handling, etc.), put it in this folder and update this `AGENTS.md` with links.

