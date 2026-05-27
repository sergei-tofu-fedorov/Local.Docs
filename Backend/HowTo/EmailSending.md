Email Sending in Backend
========================

This document describes how email sending is organized in backend services, including provider fallback and template configuration.

Responsibilities
----------------

- Backend uses dedicated email adapters (for example, SendGrid, Sendinblue) instead of sending email directly from controllers.
- Application or domain services decide *what* to send; infrastructure decides *how* to send it (provider, template, attachments).

Providers and Fallback
----------------------

- Email providers are modeled as an enum (for example, `SendGrid`, `Sendinblue`).
- The main email service accepts an optional provider parameter:
  - When a specific provider is passed, only that provider is used.
  - When provider is `Unknown`, the service tries providers in a configured order.
- For document and online-email flows, the typical order is:
  - first: SendGrid;
  - second (fallback): Sendinblue.
- For some notification flows (for example, “email opened” notifications), only one provider may be used.
- The send operation loops over providers and stops on the first successful send; if all providers fail, a domain-level `EmailNotSent` error is raised.

Templates and Configuration
---------------------------

- Template IDs and base sender addresses are driven by configuration, not hard-coded:
  - Each provider has its own configuration section under `Services:<Provider>` (for example, `Services:SendGrid`, `Services:Sendinblue`).
  - Common options include:
    - `InvoiceTemplateId`
    - `EstimateTemplateId`
    - `RequestTemplateId`
    - `InvoicesReportTemplateId`
    - `OnlineInvoicesTemplateId`
    - `OnlineTemplateId`
    - `EmailOpenedTemplateId`
    - `BaseEmailAddress`
    - `BaseEmailAddressForPayments`
- Configuration is bound to strongly typed options and validated on startup.
- Each provider has a dedicated template service instance built from its own options:
  - the template service chooses the correct template id based on the business object type and scenario;
  - it constructs the `TemplateData` object (for example, invoice number, amounts, links, flags) that is passed to the gateway;
  - all template data keys should match the variables in the provider’s template system.

Sendinblue-Specific Settings
----------------------------

- Sendinblue configuration usually includes:
  - `ApiKey` – API key for transactional emails;
  - `Sandbox` – when enabled, requests are not actually sent;
  - `ReplyToEnabled` – whether to include a reply-to address.
- The Sendinblue client:
  - uses `TemplateId` and `Params` from the template service;
  - optionally sets `ReplyTo` when enabled and a valid reply-to email is available;
  - can attach files (for example, PDFs and previews) when needed;
  - retries one more time without `ReplyTo` if the first send fails.

Patterns
--------

- Use strongly typed models for email templates and message payloads (no scattered magic strings).
- Keep all email text and URLs in a small number of template services and localization helpers.
- Ensure template data remains backward compatible when templates evolve (avoid removing or renaming keys used by existing templates).

Error Handling
--------------

- Log failures with enough context to debug (recipient, template id, provider, correlation identifiers) but avoid logging sensitive content.
- When multiple providers are configured:
  - treat the first provider failure as a reason to try the next provider;
  - only surface a fatal error when all configured providers fail.
- At the use-case level (for example, sending an invoice vs. sending a notification):
  - decide whether a failed email should block the main flow or be treated as best-effort.

Where to Extend
---------------

- When adding new email flows, document:
  - which service owns the flow;
  - which provider(s) are used and in what order;
  - template names, ids, and data keys expected by the templates;
  - retry, fallback, and notification behaviour (including callbacks for status updates).
