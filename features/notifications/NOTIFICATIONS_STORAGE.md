Notifications - Storage Notes
=============================

Tables (PostgreSQL)
-------------------

1. notifications
- Partition key: `target_account_id`
- Sort order: `created_at DESC, notification_id DESC`
- Target scope fields (recipient scope):
  - `target_account_id` - always set for account-wide and user-scoped notifications.
  - `target_master_user_id` - optional; when set, notification is visible only to that user.
  - `target_product_key` - optional; when set, notification is scoped to a product/app.
- Columns: `notification_id` (bigint), `target_account_id`, `target_master_user_id`,
  `target_product_key`, `type`, `payload`, `created_at`, `read_at`, `schema_version`, `source`
- Indexes:
  - `target_account_id, read_at` (for unread queries)
  - `target_account_id, created_at` (for paging)
  - `target_account_id, target_master_user_id, created_at` (for user-scoped paging)
  - `target_account_id, target_product_key, created_at` (for product scoping)
  - `target_account_id, type, created_at` (for type filtering)

2. notification_outbox
- Stores delivery tasks generated right after a notification is created.
- Each row is a pending delivery task: `notification_id`, `channel`, `status`,
  `next_attempt_at`, `attempts`, `created_at`, `updated_at`, `last_error`, `idempotency_key`.
- Workers claim rows by channel, update `status`, and reschedule on failure.
- `last_error` stores the error message from the last failed delivery attempt.
- `idempotency_key` prevents duplicate deliveries during retries.
- Partial index on `(status, next_attempt_at) WHERE status = 'Pending'` for efficient worker polling.

Optional Tables
---------------

3. notification_delivery_status (phase 2+)
- Track delivery per channel (`Push`, `Email`, `InApp`).
- Fields: `notification_id`, `channel`, `status`, `attempts`, `next_attempt_at`,
  `last_attempt_at`, `error`, `idempotency_key`.
- Used when channel delivery needs retries or detailed audit beyond the
  outbox table.

Retention
---------
- Keep at least N days or N items per account (define later).
- Purge old read notifications in a background job.

Schema (PostgreSQL DDL, Example)
--------------------------------

```sql
create table notifications (
    notification_id bigint generated always as identity primary key,
    target_account_id text not null,
    target_master_user_id text null,
    target_product_key text null,
    type text not null,
    payload jsonb not null,
    created_at timestamptz not null,
    read_at timestamptz null,
    schema_version int not null,
    source text null  -- originating module (e.g., "Payments", "Stripe")
);

create index ix_notifications_account_read_at
    on notifications (target_account_id, read_at);

create index ix_notifications_account_created_at
    on notifications (target_account_id, created_at desc, notification_id desc);

create index ix_notifications_account_user_created_at
    on notifications (target_account_id, target_master_user_id, created_at desc, notification_id desc);

create index ix_notifications_account_product_created_at
    on notifications (target_account_id, target_product_key, created_at desc, notification_id desc);

create index ix_notifications_account_type_created_at
    on notifications (target_account_id, type, created_at desc, notification_id desc);

create table notification_outbox (
    notification_id bigint not null,
    channel text not null,
    status text not null,
    attempts int not null default 0,
    next_attempt_at timestamptz not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    last_error text null,        -- error message from last failed attempt
    idempotency_key text null,   -- prevents duplicate deliveries on retry
    primary key (notification_id, channel),
    foreign key (notification_id) references notifications (notification_id) on delete cascade
);

create index ix_notification_outbox_pending
    on notification_outbox (status, next_attempt_at)
    where status = 'Pending';

create unique index ix_notification_outbox_idempotency
    on notification_outbox (idempotency_key)
    where idempotency_key is not null;

-- Optional phase 2+ table for detailed delivery audit.
create table notification_delivery_status (
    notification_id bigint not null,
    channel text not null,
    status text not null,
    attempts int not null default 0,
    next_attempt_at timestamptz null,
    last_attempt_at timestamptz null,
    error text null,
    idempotency_key text null,
    primary key (notification_id, channel),
    foreign key (notification_id) references notifications (notification_id)
);
```
