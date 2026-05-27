DDD Reference — Compact Skill Guide
====================================

Primary source: "Domain-Driven Design Quickly" (InfoQ/Abel Avram &
Floyd Marinescu), summarizing Eric Evans' "Domain-Driven Design:
Tackling Complexity in the Heart of Software" (2003).

Additional sources (marked with **[Vernon]** where used):
- Vernon, Vaughn. "Implementing Domain-Driven Design." (2013) Ch.10.
- Kulec, Szymon (Scooletz). "Relaxed Optimistic Concurrency." (2016).

This document is a compact, actionable reference for applying DDD patterns
during code review, design discussions, and implementation decisions.

---

Core Philosophy
---------------

Software must model the **domain** — the real-world subject area. The
domain model is not the code, the database, or the UI. It is the
organized, structured knowledge of the problem, expressed in a form
that both developers and domain experts understand.

**Key principle:** The model and the code must stay in sync. If the
model says one thing and the code does another, the model is useless.

---

Model-Driven Design
-------------------

The model and the implementation must be **one thing**, not separate
artifacts. Evans warns against the "analysis model" anti-pattern:
analysts create a model, hand it to developers, developers reinterpret
it into something different. The original model becomes irrelevant.

**Rules:**
- Developers must participate in modeling. Modelers must write code.
- If the design can't be mapped to the model literally, change the
  model — don't build a separate "implementation model"
- A change to the code is a change to the model. Its effect must
  ripple through conversations, docs, and the Ubiquitous Language.
- Use object-oriented programming — it provides direct mappings
  between model objects/relationships and code

**Anti-pattern:** Analyst creates a "correct" domain model in
diagrams, hands it to developers who build something different.
Knowledge is lost in translation. The model becomes shelfware.

---

Building Domain Knowledge
-------------------------

The model is built through **collaboration between developers and
domain experts**. Neither side can do it alone. Developers bring
software design skills; domain experts bring deep understanding of
the problem space.

**Process:**
1. Developers and domain experts talk — concepts emerge from dialog
2. Nouns become candidates for classes, verbs for methods (but this
   is only a starting point — shallow models come from mechanical
   noun/verb extraction)
3. The model evolves through many iterations, each adding depth
4. Contradictions between experts reveal hidden concepts
5. Domain literature (books, specs) provides deep background

**Evans' air traffic example:** Through dialog, "Aircraft" was
refined to "Flight" (we track flights, not planes), "Route" became
a series of "Fixes" (ground points, not 3D paths), and "Flight Plan"
emerged as a key concept that wasn't initially obvious.

**Key insight:** The most important domain concepts are often
**implicit** — used in conversation but not yet in the model. Making
them explicit (as classes, VOs, or named processes) is how
breakthroughs happen.

---

Ubiquitous Language
-------------------

A **shared vocabulary** between developers and domain experts. Every
class, method, and module name should come from this language. If
domain experts say "Visit" and developers say "Appointment," pick one
and use it everywhere — code, conversations, docs, tests.

**Rules:**
- Build the language collaboratively with domain experts
- Use it in code (class names, method names, variable names)
- If a term is ambiguous, refine it until it's precise
- Changes to the language = changes to the model = changes to the code
- If you can't explain a design decision using domain language,
  the model is wrong

**Anti-pattern:** Technical jargon in the domain layer. "EntityManager,"
"DataProcessor," "Handler" — these are infrastructure terms, not domain
terms. Domain classes should read like business descriptions.

---

Layered Architecture
--------------------

Separate concerns into layers. Each layer depends only on layers below.

```
┌─────────────────────────────────────────┐
│  UI / API  (Controllers, DTOs)          │  Drives the application
├─────────────────────────────────────────┤
│  Application  (Use cases, orchestration)│  Thin, no business logic
├─────────────────────────────────────────┤
│  Domain  (Entities, VOs, Services)      │  All business logic here
├─────────────────────────────────────────┤
│  Infrastructure  (DB, messaging, I/O)   │  Technical implementations
└─────────────────────────────────────────┘
```

**Application layer** is thin — coordinates domain objects, does not
contain business rules. A use case handler loads aggregates, calls
domain methods, saves. It does not compute, validate, or decide.

**Domain layer** has zero dependencies on infrastructure. No database
calls, no HTTP clients, no file I/O. Pure business logic.

---

Building Blocks
---------------

### Entities

Objects defined by **identity**, not attributes. Two entities with the
same data but different IDs are different. Two entities with the same
ID but different data are the same entity at different points in time.

```
Entity = identity + mutable state + behavior
```

**When to use:** When you need to track something across time and
state changes. Jobs, Visits, Users, Invoices — these are entities.

**Rules:**
- Every entity must have a unique, stable identity
- Identity can be assigned (GUID) or natural (invoice number)
- Equality is by ID, not by attribute comparison
- Focus entity design on identity and lifecycle, not data

### Value Objects

Objects defined by **attributes**, not identity. Two VOs with the same
attributes are interchangeable. Immutable — if you need a different
value, create a new instance.

```
Value Object = attributes + immutability + no identity
```

**When to use:** Quantities, measurements, descriptors, ranges,
composed attributes. Money, Address, DateRange, Tag, Coordinates.

**Rules:**
- No identity field (no ID, no primary key of its own)
- Immutable — no setters, no mutation methods
- Equality is by value (all attributes match)
- Can contain other value objects
- Can contain behavior (validation, computation)
- **Prefer value objects over primitives.** Don't use `string` for
  an email address — create an `Email` value object that validates

**Why immutability matters:** VOs can be freely shared and passed
around without defensive copying. If a VO is mutable, two aggregates
holding the same VO instance can corrupt each other.

### Services

Operations that **don't naturally belong to any entity or VO**. A
service is a stateless operation expressed in domain terms.

**Three tests for a domain service:**
1. The operation relates to a domain concept that isn't a natural
   part of an Entity or Value Object
2. The interface is defined in terms of domain model elements
3. The operation is stateless

```
Entity behavior:  visit.UpdateStatus(newStatus)
Service behavior: transferFunds(sourceAccount, targetAccount, amount)
```

**Layered services:**
- **Domain service:** Business logic spanning multiple aggregates.
  E.g., `InvoiceCreationService` that orchestrates Job → Invoice.
- **Application service:** Use case orchestration. Loads aggregates,
  calls domain methods, saves. No business logic.
- **Infrastructure service:** Technical concerns. Email sending,
  file storage, external API calls.

**Anti-pattern:** Anemic domain model — entities are pure data bags,
all logic lives in services. If your entities have only getters/setters
and services do all the work, you've lost the model.

### Modules (Namespaces)

Group related concepts. A module should tell a story about the domain,
not about technical layers.

**Good:** `Tofu.Invoices`, `Tofu.Payments`, `Tofu.Auth`
**Bad:** `Models`, `Services`, `Repositories`, `Helpers`

**Rules:**
- Low coupling between modules, high cohesion within
- Module names come from the Ubiquitous Language
- If two concepts are always discussed together, they belong in
  the same module

---

Aggregates
----------

A cluster of entities and value objects treated as a **single unit**
for data changes. One entity is the **aggregate root** — the only
entry point for external access.

```
Job (aggregate root)
├── Visits[]        (child entities)
│   └── Items[]     (child entities or VOs)
└── Relations       (value object)
```

### Rules

1. **The root has global identity.** Child entities have local
   identity (unique within the aggregate, not globally).

2. **External objects can only reference the root.** Never hold a
   direct reference to a child entity. Access children through
   the root: `job.Visits`, not a standalone `visit` reference.

3. **Only the root enforces invariants.** The root is responsible
   for all business rules that span multiple children. Children
   can enforce their own local invariants.

4. **Delete the root = delete everything inside.** Cascade. An
   aggregate is a consistency boundary — if the root goes, the
   children have no meaning.

5. **One transaction = one aggregate.** Don't modify multiple
   aggregates in the same transaction. If you need cross-aggregate
   consistency, use eventual consistency (domain events).

### Aggregate sizing **[Vernon]**

Vernon emphasizes: **keep aggregates small.** Evans discusses
aggregate boundaries but the explicit sizing guidance is Vernon's.

- Only include entities that MUST be consistent with each other
  in the same transaction
- If a child entity has no invariant relationship with the root,
  it might be its own aggregate
- Large aggregates cause concurrency contention (every change
  locks the whole cluster) and performance problems (loading the
  full graph)

**The test:** "If I change child X, does any invariant on root or
sibling Y need to be checked?" If no → X might not belong in this
aggregate.

### Concurrency and versioning **[Vernon]**

Evans establishes that the aggregate is a consistency boundary. Vernon
extends this with concrete versioning guidance:

The aggregate root carries the **version / concurrency token**. All
changes to any entity within the aggregate bump the root's version.
This guarantees consistency: if two transactions modify different
children of the same aggregate, one will fail with a concurrency
conflict.

**Relaxed optimistic concurrency (Vernon, IDDD Ch.10 + Scooletz):**

When child entity changes have **no cross-entity invariants**, the
child can carry its own version. The root version does NOT bump for
child-only changes. This reduces false conflicts.

Example: adding a BacklogItem to a Product. No invariant on the
collection size → Product.Version should not bump. BacklogItem
gets its own version.

**When to relax:**
- Append-only / additive operations (add photo, add comment)
- No aggregate-level invariant governs the child collection
- Operations are commutative (order doesn't matter)
- Operations are idempotent (safe to retry)

**When NOT to relax:**
- Status transitions that affect the root (visit status → job status)
- Operations with cross-child invariants (max N items total)
- Read-modify-write on shared root state

---

Factories
---------

Encapsulate complex object/aggregate creation. When constructing an
aggregate requires creating multiple entities, enforcing invariants,
and wiring references, put it in a Factory.

**When to use a Factory:**
- Construction is complex (multiple child entities, computed defaults)
- The caller shouldn't know the internal structure
- Creation involves invariant enforcement

**When a constructor is enough:**
- Simple construction, no complex assembly
- No invariants beyond what the constructor validates
- The class itself is the natural place for creation logic

**Factory method on aggregate root:** When creating a child entity
that belongs to the aggregate, put the factory method on the root.

```csharp
// Good: root controls creation, enforces invariants
var visit = job.CreateVisit(dateTime, workerId);

// Bad: client creates child directly, bypasses root
var visit = new Visit(job.Id, dateTime, workerId);
job.Visits.Add(visit);
```

---

Repositories
------------

Provide the illusion of an **in-memory collection** of aggregates.
The client asks for an aggregate root by identity or criteria; the
repository handles persistence details.

**Rules:**
- One repository per aggregate root (not per entity/table)
- Interface in the domain layer, implementation in infrastructure
- Returns fully reconstituted aggregates (not partial objects)
- Encapsulates query logic — clients don't write SQL/LINQ

**Repository vs Factory:**
- Factory creates **new** objects
- Repository reconstitutes **existing** objects from storage
- A repository may use a factory internally to rebuild objects

**Anti-pattern:** Repositories that return DTOs, projections, or
partial objects. A repository returns domain objects. If you need
a read-optimized projection, use a separate read model / query service.

---

Bounded Contexts
----------------

A model has boundaries. The same word means different things in
different parts of a large system. "Account" in billing ≠ "Account"
in authentication.

A **Bounded Context** is the boundary within which a model is
consistent and a term has exactly one meaning.

```
┌─────────────────┐  ┌─────────────────┐
│ Invoicing BC     │  │ Jobs BC          │
│                  │  │                  │
│ Invoice          │  │ Job              │
│ LineItem         │  │ Visit            │
│ Payment          │  │ Worker           │
│ Client(billing)  │  │ Client(contact)  │
└─────────────────┘  └─────────────────┘
```

"Client" in Invoicing has billing info. "Client" in Jobs has contact
info and job history. Same word, different models. Each BC owns its
definition.

### Continuous Integration (within a BC)

Within a single BC, the model must stay unified. Multiple developers
working on the same BC risk fragmenting it — duplicating code,
contradicting the model, breaking existing behavior.

**Rules:**
- Merge code frequently (daily within a team)
- Automated build + test suite to catch breakage early
- Team members must communicate about model changes
- CI applies within a BC — it does not handle cross-BC relationships

### Context Map

A document (diagram or text) showing all BCs and their relationships.
Everyone on the project should understand the big picture. Each BC
should have a **name** that's part of the Ubiquitous Language.

**Integration patterns between BCs:**

- **Shared Kernel:** Two BCs share a subset of the model (risky,
  tight coupling — changes affect both). Must run both teams' tests
  on changes. Use only when teams are closely collaborating.
- **Customer-Supplier:** One BC (supplier) provides data/services
  to another (customer). Customer can request changes. Works when
  both teams are under the same management. Joint acceptance tests
  validate the interface.
- **Conformist:** Like customer-supplier but the customer has no
  influence — the supplier won't adapt. Customer must accept the
  supplier's model as-is, or use an ACL to translate.
- **Anti-Corruption Layer (ACL):** A translation layer between BCs.
  Protects your model from being polluted by external models.
  Essential when integrating with legacy systems or third-party APIs.
- **Separate Ways:** BCs have no relationship. Integration isn't
  worth the cost. Models developed independently are very difficult
  to integrate later — make sure you won't need to.
- **Open Host Service:** A BC provides a well-defined protocol
  (API) for others to integrate with. Combined with **Published
  Language** (a shared schema/format). When many consumers need
  the same service, one protocol beats N translation layers.

### Anti-Corruption Layer (ACL)

The most practically important integration pattern. When consuming
an external system:

```
Your Domain ←→ ACL (translates) ←→ External System
```

The ACL contains:
- **Facade:** Simplified interface to the external system
- **Adapter:** Converts external protocols to your internal interfaces
- **Translator:** Maps external concepts to your domain model

**Never let external models leak into your domain.** If a gRPC service
returns `ExternalInvoiceProto`, the ACL translates it to your
`Invoice` domain entity. Your domain code never sees the proto.

---

Distillation — Core Domain vs Generic Subdomains
--------------------------------------------------

A large system has a **Core Domain** (the essence of the business,
what makes this system unique) and **Generic Subdomains** (things
every system needs but that aren't your competitive advantage).

**Core Domain:**
- The part that justifies building custom software
- Assign your best developers here
- Invest in deep modeling, refactoring, supple design
- Example: trajectory computation in air traffic control

**Generic Subdomains:**
- Concepts used across many domains: money/currency, routing,
  scheduling, notifications, authentication
- Options: off-the-shelf solutions, outsource, published models,
  or in-house with lower priority
- Don't assign core developers here — they'll gain little domain
  knowledge from generic work

**The test:** If you replaced this module with a third-party
library, would you lose your competitive advantage? If no → generic.

**Evans:** "Boil the model down. Find the Core Domain and provide
a means of easily distinguishing it from the mass of supporting
model and code. Make the Core small."

---

Refactoring Toward Deeper Insight
----------------------------------

The model is never done. As understanding grows, refactor to express
new insights.

**Patterns:**

- **Constraint:** Make implicit rules explicit. Instead of validation
  scattered across services, create a value object that enforces the
  constraint. `BookshelfCapacity` that checks max books.

- **Process:** When a complex procedure spans multiple objects and
  isn't a simple service call, model it explicitly. A `Shipment`
  process that moves through states: ordered → packed → shipped.

- **Specification:** Encapsulate a business rule as an object that
  can be combined, reused, and tested independently.

  ```csharp
  var spec = new OverdueInvoiceSpec().And(new HighValueSpec());
  var matches = invoices.Where(spec.IsSatisfiedBy);
  ```

**Making implicit concepts explicit:**

Evans emphasizes that many important domain concepts start as
**implicit** — used in conversation but missing from the model.
Signs of hidden concepts:
- A section of code is awkward or hard to follow
- A set of relationships makes the computation path unclear
- Domain experts use a term that has no corresponding class
- Contradictions between experts may reveal a missing concept

When you find one, make it a class, a VO, or a named process.
This is how **breakthroughs** happen — a single refactoring that
unlocks a much cleaner, deeper model.

**Continuous refactoring mindset:**
- When the code is hard to explain in domain terms, the model is wrong
- Breakthroughs happen when you discover a concept hiding in the code
  that should be explicit (a class, a VO, a named process)
- Don't refactor just for code quality — refactor when the model
  doesn't match the domain understanding
- Models start shallow (nouns→classes, verbs→methods). Depth comes
  through iterative refinement, not upfront design
- Breakthroughs can require large refactorings — budget for them

---

Decision Checklist
------------------

Use this when making design decisions:

**Is this an Entity or Value Object?**
- Does it need a unique identity tracked over time? → Entity
- Is it defined entirely by its attributes? → Value Object
- When in doubt, prefer Value Object (simpler, safer)

**Does this belong in the aggregate?**
- Must it be transactionally consistent with the root? → Yes
- Can it change independently without breaking invariants? → Probably its own aggregate
- Is the aggregate getting too large? → Split

**Should I check the root's version for this operation?**
- Does it affect root-level or cross-child invariants? → Yes, check version
- Is it append-only with no aggregate invariant? → Can skip (relaxed concurrency)
- Does ordering matter? → Check version

**Is this a domain service or should it be on an entity?**
- Does the operation naturally belong to one entity? → Put it there
- Does it span multiple aggregates? → Domain service
- Is it orchestration without business logic? → Application service

**Do I need a Factory?**
- Is construction complex (multiple children, computed defaults)? → Factory
- Is it a simple creation with validation? → Constructor is fine
- Should the root control child creation? → Factory method on root

**Do I need an ACL?**
- Am I consuming an external system's model? → Yes, always
- Would external concepts leak into my domain? → ACL prevents this

**Is this Core Domain or Generic Subdomain?**
- Would replacing it with a library lose our competitive edge? → Core
- Is it used across many domains (auth, scheduling, email)? → Generic
- Am I assigning best developers to the most important part? → Core

---

Evans' Practical Advice
-----------------------

From the interview in "DDD Quickly":

1. **Stay hands-on.** Modelers need to code.
2. **Focus on concrete scenarios.** Abstract thinking must be
   anchored in concrete cases.
3. **Don't try to apply DDD to everything.** Draw a context map
   and decide where you will push for DDD and where you won't.
   Then don't worry about it outside those boundaries.
4. **Experiment a lot and expect to make lots of mistakes.**
   Modeling is a creative process.
