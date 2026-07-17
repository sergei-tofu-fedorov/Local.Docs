# FS-1443 — Проброс product key инвойса в платёж

**Status:** in-progress
**Started:** 2026-07-16
**ClickUp:** https://app.clickup.com/t/FS-1443
**Affected repos:** `Invoices.Backend` (BFF — единственная правка кода) · `Tofu.AI.Backend` (экспорт в warehouse — сделано) · `Playfair.DWH.BigQuery` (PF — правка маппинга до раскатки BFF)

## Где план

> **[`Invoices.Backend/Docs/features/FS-1443/README.md`](../../../Invoices.Backend/Docs/features/FS-1443/README.md)** — канонический документ (полный разбор, код, валидация, порядок раскатки).

## Суть

Платёж должен нести **ключ продукта инвойса / пеймент-реквеста, по которому он прошёл**, чтобы на уровне PF платежи разносились по продуктам. Провод уже пишет ключ в jsonb `PspAdditionalInfos["product-key"]`, и все приёмники (PF, Tofu.AI) читают именно jsonb — поэтому типизированную колонку в `Tofu.Payments` **не добавляем**.

Осталась одна правка кода — **`Invoices.Backend` (BFF)**: источник ключа меняем с request-scoped `XA-App-Type` (клиент-апп) на `Invoice.ProductKey` / `PaymentRequest.ProductKey` (что заодно снимает зависимость от заголовка, которого на redirect-хуках нет). `Tofu.AI.Backend` уже экспортирует сырой jsonb `psp_additional_infos` и `src_invoices.product_key` (раскатано на проде).

**PF — обязательная координация:** модель `stripe_connect_like_subz_events.sql` уже читает product-key из jsonb и маппит его в app по жёстко зашитому списку (`invoices`, `payments`), отсекая незнакомые ключи (`WHERE app_name is not null`). BFF-правка переразнесёт часть платежей на `tofu`/`tofu-fieldservice` → без правки маппинга они **выпадут** из PF-выручки. Правка PF должна выехать **раньше** BFF.
