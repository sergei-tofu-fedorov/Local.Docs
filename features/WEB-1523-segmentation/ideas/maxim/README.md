# Резюме архитектуры рекомендательной системы для invoice SaaS

## Главная идея

Ты строишь не просто "AI рекомендации", а платформу данных о финансовом поведении компаний.

Система должна понимать:

* кто оказывает услуги
* какие услуги
* кому
* как платят
* как меняется поведение
* какие компании похожи друг на друга
* что обычно приводит к оплате / churn / upsell

---

# Общая схема

```text id="gx5s6m"
                ┌─────────────────┐
                │     Frontend    │
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │   App / API     │
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │ Operational DB  │
                │  PostgreSQL     │
                └────────┬────────┘
                         │
            ┌────────────┴────────────┐
            ▼                         ▼
  ┌─────────────────┐      ┌─────────────────┐
  │ Event Collection│      │ Semantic Layer  │
  │ invoice.paid    │      │ embeddings      │
  │ payment.failed  │      │ contracts       │
  └────────┬────────┘      └────────┬────────┘
           │                        │
           ▼                        ▼
   ┌────────────────────────────────────┐
   │         Analytics Layer            │
   │      aggregations / metrics        │
   └────────────────┬───────────────────┘
                    │
                    ▼
        ┌────────────────────────┐
        │   Feature Generation   │
        │ payment_score          │
        │ churn_risk             │
        │ service_similarity     │
        └───────────┬────────────┘
                    │
                    ▼
        ┌────────────────────────┐
        │ Recommendation Engine  │
        │ rules                  │
        │ similarity             │
        │ ML ranking             │
        └───────────┬────────────┘
                    │
                    ▼
        ┌────────────────────────┐
        │ Recommendations API    │
        │ AI assistant / RAG     │
        └────────────────────────┘
```

---

# Шаги построения системы

# ШАГ 1. Operational database

## Что делаем

Создаем основные сущности:

```text id="rn96zs"
Tenant
Customer
Service
Invoice
InvoiceLine
Payment
Subscription
Contract
```

---

## Зачем

Это ядро системы:

* UI
* API
* CRUD
* billing logic

---

## Технологии

* PostgreSQL
* JSONB для гибких полей

---

# ШАГ 2. Event collection

## Что делаем

Начинаем сохранять все важные действия как события.

---

## Примеры событий

```text id="k47vpm"
invoice.created
invoice.sent
invoice.paid
invoice.overdue

payment.failed
subscription.started
customer.created
service.purchased
```

---

## Зачем

Events дают:

* историю
* behavioral context
* аналитику
* future ML

---

## Хранение

Сначала:

* PostgreSQL event table

Потом:

* Kafka
* ClickHouse

---

# ШАГ 3. Analytics layer

## Что делаем

Считаем агрегаты и метрики.

---

## Примеры

```text id="z5jzxu"
avg_payment_delay
LTV
MRR
invoice_growth
payment_success_rate
```

---

## Зачем

Raw events неудобны для рекомендаций.

Нужны готовые агрегаты.

---

# ШАГ 4. Feature generation

## Что делаем

Строим features из аналитики.

---

## Примеры features

```text id="5t64xa"
payment_score
customer_risk
preferred_payment_day
service_popularity
upsell_probability
```

---

## Зачем

Features — главный "контекст" системы.

Именно их читает recommendation engine.

---

# ШАГ 5. Semantic layer

## Что делаем

Храним неструктурированные данные.

---

## Что хранить

```text id="c2o3l6"
service descriptions
contracts
emails
invoice notes
support chats
```

---

## Что происходит

Тексты превращаются в embeddings.

---

## Зачем

Это дает:

* semantic search
* похожие услуги
* похожих клиентов
* RAG
* AI assistant

---

## Технологии

Старт:

* pgvector

---

# ШАГ 6. Recommendation engine

# ЭТАП 1 — Rules

## Пример

```text id="d1vb4d"
IF payment_delay > 14 days
THEN recommend upfront payment
```

---

# ЭТАП 2 — Similarity

## Пример

```text id="z3gdx7"
Companies similar to yours also use:
- annual billing
- premium support
```

---

# ЭТАП 3 — ML ranking

Когда данных становится много:

* churn prediction
* upsell prediction
* payment probability

---

# ШАГ 7. Recommendation API

## Что делаем

Делаем сервис:

```text id="42f93n"
GET /recommendations/customer/123
```

---

## Что он делает

1. берет features
2. берет embeddings
3. запускает rules/model
4. возвращает рекомендации

---

# ШАГ 8. Feedback loop

## Что делаем

Сохраняем реакцию на рекомендации.

---

## События

```text id="s4v12w"
recommendation_shown
recommendation_clicked
recommendation_accepted
recommendation_ignored
```

---

## Зачем

Без feedback loop система не обучается.

---

# ШАГ 9. AI assistant / RAG

## Что делаем

LLM получает unified context:

```text id="6k3gqg"
facts
+
events
+
features
+
semantic search
+
recommendations
```

---

## Пример

Пользователь спрашивает:

> "Почему клиент risky?"

AI объясняет:

* были late payments
* invoice volume падает
* похожие компании churned

---

# Recommended MVP stack

## Минимальный practical stack

```text id="ebjlwm"
PostgreSQL
+
event table
+
aggregations
+
rules
+
pgvector
```

---

# Что НЕ нужно на старте

Не нужно сразу:

* microservices
* separate vector DB
* complex ML
* graph DB
* realtime streaming

---

# Когда масштабироваться

## Добавлять позже

### Analytics scale

* ClickHouse

### Streaming

* Kafka

### Graph recommendations

* Neo4j

### Feature store

* Feast

---

# Финальная оценка подхода

| Критерий              | Оценка |
| --------------------- | ------ |
| Масштабируемость      | 9/10   |
| AI readiness          | 9/10   |
| Простота MVP          | 7/10   |
| Скорость разработки   | 8/10   |
| Качество рекомендаций | 8/10   |
| Сложность поддержки   | 6/10   |

---

# Главный вывод

Самый ценный asset такой системы — не ML.

А:

* event history
* behavioral data
* financial relationships
* generated features
* semantic context

Именно это потом позволяет:

* делать AI
* строить RAG
* запускать recommendations
* делать intelligent billing automation
