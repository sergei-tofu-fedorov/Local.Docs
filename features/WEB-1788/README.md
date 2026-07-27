# WEB-1788 — Launch-price offer на финале онбординга (Web)

**Status:** planning
**Started:** 2026-07-20
**ClickUp:** https://app.clickup.com/t/24553599/WEB-1788
**Affected repos:** _<list once known>_

## Goal

Launch-price offer на финале онбординга (Web): заменить статичный финальный экран онбординга на пропускаемый оффер с launch-ценой. Реюз 3 существующих месячных прайсов (Solo fsmProMonth / Team fsmTeamMonth / Business fsmBusinessMonth), маппинг по crew_size из онбординга. Промо «3 месяца» = Stripe-купон duration_in_months=3, повешенный через WebCheckout:PriceConfigs.CouponId (Вариант B), НЕ новые прайсы и НЕ URL-купон. Триал/без-триала выбирается по состоянию подписки (3 прекондишена: активный триал/подписка → оффер не показываем; триала не было → 7-дн бесплатный триал, $0 сегодня; триал был, подписки нет → без триала, списание сегодня). Оффер идёт через авторизованный POST api/web-checkout/subscriptions (сейчас не принимает флаг триала и режет купоны кроме ios_migration_*). Убрать countdown-таймер на checkout.tofu.com. Аналитика Amplitude: Page Shown (page_name=launch_offer, plan_name), Click Start Subscription, Click Skip Offer. Скоуп только веб (desktop+mobile web). Источник — PRD Ekaterina Lazukina, Figma node 3304-27327.

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
