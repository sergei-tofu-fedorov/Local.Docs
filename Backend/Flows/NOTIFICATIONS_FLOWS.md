Notifications: Command and Query Processing Flows
=================================================

## Commands

### 1. CreateNotificationCommand (Internal)

**Triggered by:** domain events (e.g., Stripe connected, payment received, email opened).

**Flow:**

```mermaid
flowchart TD
    A[Domain service emits NotificationEvent] --> B[Dispatcher validates event<br/>and resolves channel routing]
    B --> C[Create Notification record in PostgreSQL<br/>NotificationId, AccountId, Type, Payload<br/>ReadAt = null]
    C --> D[Store notification in DB]
    D --> E[Create delivery tasks per channel<br/>status = Pending, next_attempt_at]
    E --> F[Delivery workers pick up tasks]
    F --> G{Delivery success?}
    G -->|Yes| H[Mark task as Sent]
    G -->|No| I{Max attempts?}
    I -->|No| J[Retry with backoff]
    J --> F
    I -->|Yes| K[Mark as DeadLetter]
```

---

### Example: First Payment Notification (In-App + Push + Email)

**Trigger:** payment processing detects the first successful payment.

**Flow:**

```mermaid
sequenceDiagram
    participant Payments as Payments Module
    participant Dispatcher
    participant DB as PostgreSQL
    participant Push as Push (OnePush)
    participant Email as Email Channel
    participant Client as Client (SPA / App)

    Payments->>Dispatcher: NotificationEvent<br/>type=firstPaymentReceived<br/>accountId=A123, payload={...}
    Dispatcher->>DB: Create Notification (id=1001)<br/>+ outbox tasks: InApp, Push, Email

    par Push delivery
        DB->>Push: Pick up Push task
        Push-->>DB: Sent / Failed (retry with backoff)
    and Email delivery
        DB->>Email: Pick up Email task
        Email-->>DB: Sent / Failed (retry with backoff)
    end

    Client->>DB: Poll GET /api/v3/notifications
    DB-->>Client: Notification (unread)
    Note over Client: User reads notification
    Client->>DB: POST /api/v3/notifications/1001/read
    Note over DB: Set read_at = UtcNow
```

---

### 2. MarkNotificationReadCommand

**Endpoint:** `POST /api/v3/notifications/{id}/read`

**Flow:**

```mermaid
flowchart TD
    A[Client: POST /notifications/id/read] --> B{Load notification<br/>by AccountId + NotificationId}
    B -->|Not found| C[404 Not Found]
    B -->|Found| D{MasterUserId scope<br/>matches current user?}
    D -->|No| E[403 Forbidden]
    D -->|Yes| F{Already read?}
    F -->|Yes| G[204 No Content<br/>idempotent]
    F -->|No| H[Set ReadAt = UtcNow<br/>Save and return 204]
```

---

### 3. MarkNotificationsReadBatchCommand

**Endpoint:** `POST /api/v3/notifications/read`

**Flow:**

```mermaid
flowchart TD
    A[Client: POST /notifications/read<br/>body: list of ids] --> B[Filter by AccountId +<br/>MasterUserId scope]
    B --> C[Update all matching<br/>unread records: set ReadAt = UtcNow]
    C --> D[Return count of<br/>updated notifications]
```

---

## Queries

### 1. GetNotificationsQuery (Polling)

**Endpoint:** `GET /api/v3/notifications`

**Flow:**

```mermaid
flowchart TD
    A[Client: GET /notifications<br/>params: unread, type, limit, cursor] --> B[Filter by AccountId]
    B --> C[Include MasterUserId IS NULL<br/>+ MasterUserId = current user]
    C --> D{unread filter?}
    D -->|Yes| E[ReadAt == null]
    D -->|No| F[All notifications]
    E --> G{type filter?}
    F --> G
    G -->|Yes| H[Filter by Type]
    G -->|No| I[No type filter]
    H --> J[Keyset pagination<br/>CreatedAt DESC, NotificationId DESC]
    I --> J
    J --> K[Return PageDto with nextCursor]
```

---

### 2. StreamNotificationsQuery (SSE, Future)

**Endpoint:** `GET /api/v3/notifications/stream`

**Flow:**

```mermaid
sequenceDiagram
    participant Client
    participant Server as Notifications API

    Client->>Server: GET /notifications/stream (SSE)
    Note over Server: Subscribe to account +<br/>user scope stream

    loop On new notification
        Server-->>Client: SSE event: NotificationDto
    end

    Note over Client: Uses polling for<br/>historical data and read state
```
