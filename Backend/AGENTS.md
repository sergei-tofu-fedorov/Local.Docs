Backend Documentation
=====================

Use this folder for backend‑specific documentation that applies across services.

Where to start
--------------

- Overall backend architecture: `Backend/HowTo/Architecture.md`
- Authentication scenarios (Bearer JWT, Signature): `Backend/HowTo/Authentication.md`
- Authorization flow and rules: `Backend/HowTo/Authorization.md`
- Persistence and data stores overview: `Backend/Persistence.md`
- Database transactions: `Backend/HowTo/Transactions.md`
- Email sending patterns and templates: `Backend/HowTo/EmailSending.md`
- General backend code style: `Backend/HowTo/CodeStyle.md`

API References
--------------

All API reference docs live in `Backend/Api/`:
- `ACCOUNT_API_REFERENCE.md` — Account management, subscriptions, currencies
- `CLIENTS_API_REFERENCE.md` — Client records
- `ESTIMATES_API_REFERENCE.md` — Estimates with PDF/timeline
- `EXPENSES_API_REFERENCE.md` — Expenses, incomes, Plaid/Sensibill
- `INVITATIONS_API_REFERENCE.md` — Tenant invitations
- `INVOICES_API_REFERENCE.md` — Invoices with PDF/timeline
- `ITEMS_API_REFERENCE.md` — Line items catalog
- `JOBS_API_REFERENCE.md` — Jobs with visits/timeline
- `NOTIFICATIONS_API_REFERENCE.md` — Notifications
- `PAYMENTS_API_REFERENCE.md` — Payment providers and connections
- `REPORTS_API_REFERENCE.md` — Financial reports
- `TEAMS_API_REFERENCE.md` — Team members
- `TIMELINE_API_REFERENCE.md` — Aggregated timeline
- `WORKER_API_REFERENCE.md` — Worker visits

Flows
-----

All flow/workflow docs live in `Backend/Flows/`:
- `AUTHENTICATION_FLOW.md` — Complete authentication flow (JWT, Signature, OTP, sessions)
- `OTP_FLOW.md` — One-time password authentication flow
- `NOTIFICATIONS_FLOWS.md` — Notification delivery flows
- `JOB_FROM_ESTIMATE_FLOWS.md` — Job creation from estimate flow
- `WORKER_WORKFLOW_DIAGRAMS.md` — Worker/visit workflow diagrams

Services
--------

- Tofu.Auth service  
  - Docs entry: `Backend/Services/Tofu.Auth/AGENTS.md`  
  - Repository: `https://github.com/m-unicorn/Tofu.Auth.Backend`  
  - Description: authentication and authorization service (sessions, OTP, permissions)
    used by other backend services and clients.

- Invoices.Backend service  
  - Docs entry: `Backend/Services/Invoices.Backend/AGENTS.md`  
  - Repository: `https://github.com/m-unicorn/Tofu.Invoices.Backend`  
  - Description: invoices and estimates gateway for web and mobile clients; the only
    backend service exposed directly to external clients.

- Tofu.Invoices service  
  - Docs entry: `Backend/Services/Tofu.Invoices/AGENTS.md`  
  - Repository: `https://github.com/m-unicorn/Tofu.Invoices.Backend`  
  - Description: core invoices and estimates service used by other backend components.

If you are unsure where to put a new backend document, prefer:
- `Backend/HowTo` for task‑oriented guides,
- `Backend/Services/<ServiceName>` for service‑specific rules and APIs.
