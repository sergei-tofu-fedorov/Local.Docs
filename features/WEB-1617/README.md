# WEB-1617 — <Title>

**Status:** planning
**Started:** 2026-06-08
**ClickUp:** https://app.clickup.com/t/WEB-1617
**Affected repos:** _<list once known>_

## Goal

Providing demo access to our application.

## Scope

- In scope:
- Out of scope:

## Affected repos

For each repo touched, list the area and (if multi-repo) its role.

- `Tofu.Invoices.Backend` (producer) — _e.g., new gRPC method, repository, domain change_
- `Invoices.Backend` (consumer / BFF) — _e.g., new controller endpoint that calls the new gRPC method_
- (others as needed)

**Cross-repo notes:**
- Producer / consumer order: _producer ships first; consumer references new contract after producer is deployed._
- Contract changes: _list any .proto or shared DTO changes; mark additive vs breaking._
- Mapper updates: _which `Mapping/Mapper.cs` arms need new entries._

## Plan

Numbered, repo-scoped steps that can be ticked off during implementation.

1. [ ] …
2. [ ] …

## API / DTO changes

<only if applicable — list new endpoints, request/response shapes, breaking changes>

## Breaking changes

<list anything that could break consumers (other repos, mobile clients, third-party API users) — proto field renumbering, removed/renamed REST endpoints, narrowed types, new required fields, dropped DB columns, changed event payloads, etc. If purely additive, write `None — additive only` so the explicit check is recorded. The `/feature review` op will re-audit this against the actual diff.>

## Data / migration

<only if applicable — new collections, indexes, migrations>

## Open questions

- [ ] …

## Test plan

- Unit tests:
- Integration tests:
- Manual verification:
