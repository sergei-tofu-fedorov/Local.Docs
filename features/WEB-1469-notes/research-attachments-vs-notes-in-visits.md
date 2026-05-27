# Attachments vs notes — how FS vendors model the relationship at visit level

Companion to the [WEB-1469 plan README](README.md). The README's vendor table
already records *that* notes and attachments are kept separate everywhere; this
doc zooms in on **the relationship itself, at the visit (or visit-equivalent)
level**, across the same five field-service vendors.

Four dimensions, one section each — **Hierarchy**, **Structure**, **API**,
**UI**. Each section is a vendor-by-vendor table plus a short reading. Same
five vendors as the main plan: ServiceTitan, Jobber, Housecall Pro, Salesforce
Field Service, Dynamics 365 Field Service.

The question being answered: when a tech opens a visit and wants to *write a
note* or *attach a photo*, what entity does each thing become, where does it
sit in the tree, and how does the user see them side by side?

## Vendors and visit-equivalent entity

The "visit" concept has different names per vendor. Throughout this doc:

| Vendor | Visit-equivalent entity | Notes entity at this level | Attachments entity at this level |
|---|---|---|---|
| ServiceTitan | `Appointment` | ✗ no per-Appointment note (Job notes serve the appointment) | ✗ no per-Appointment attachment (Job attachments serve it) |
| Jobber | `Visit` | `Visit.notes` (auto-promoted up to Job notes on save) | `noteAttachments` (children of the note, never of the visit directly) |
| Housecall Pro | (no separate visit entity — visits are implicit under `Job`) | `Job.notes` | `Job.attachments` |
| Salesforce FS | `ServiceAppointment` | `ContentNote` linked via `ContentDocumentLink` (polymorphic) | `ContentDocument` / `ContentVersion` linked via `ContentDocumentLink` (same plumbing) |
| Dynamics 365 FS | `bookableresourcebooking` | `annotation` row with `notetext` set | `annotation` row with `documentbody` set (same table, different flag) |

Two of the five (ServiceTitan, HCP) don't actually have a *visit-distinct*
notes/attachments level at all — the Job is the unit. That's a meaningful
finding by itself: **half the industry treats the visit as a transient
scheduling slot, not a note-bearing entity.** Our `Visit` does the opposite, so
we land closer to Jobber / Salesforce / Dynamics.

## 1. Hierarchy — where do they sit relative to the visit?

How notes and attachments are positioned in the containment tree, and which
one (if either) owns the other.

| Vendor | Note's position relative to visit | Attachment's position relative to visit | Note ↔ Attachment edge |
|---|---|---|---|
| **ServiceTitan** | Sibling of the Appointment under Job — notes attach at Job level, surfaced on the Appointment via aggregation | Sibling of the Appointment under Job — `JobAttachment` attaches at Job level, surfaced on the Appointment via aggregation | **None.** They're parallel collections under the same parent. Neither references the other. |
| **Jobber** | Direct child of Visit (`Visit.notes : VisitNoteConnection`); auto-promotes to `Job.notes` on save | **Grandchild of Visit, child of the note.** `noteAttachments : NoteFileConnection` is exposed *on the note*, not on the visit. | **Note is parent of attachment.** Removing a note removes its attachments (cascade). 50 attachments per note, 500 MB each. |
| **Housecall Pro** | Direct child of Job (no separate visit) | Direct child of Job (no separate visit) | **None.** Sibling collections under the Job. |
| **Salesforce FS** | Linked to `ServiceAppointment` via `ContentDocumentLink` (polymorphic) | Linked to `ServiceAppointment` via `ContentDocumentLink` (same polymorphic edge) | **None at the link layer**, but they share the underlying `ContentVersion` storage row, so they're indistinguishable below the type label. |
| **Dynamics 365 FS** | `annotation.objectid` → `bookableresourcebooking` (polymorphic FK) | `annotation.objectid` → `bookableresourcebooking` (same FK) | **Same row.** One annotation = one note OR one attachment. `isdocument` flag selects which. |

**Reading.**
- **Three positions** for the attachment: sibling of the note (ServiceTitan,
  HCP, Salesforce), child of the note (Jobber), same-row-as-the-note
  (Dynamics).
- **Sibling is the dominant pattern** (3 of 5). Jobber is the only one where
  the attachment can't exist without a note. Dynamics is the only one where
  *neither* can exist without the other (they're literally the same row with
  a flag).
- **No vendor inverts the relation** — none make the note a child of the
  attachment. "Caption on a photo" is not how any of them models it; if
  a photo needs a caption, that goes in the photo's own description field
  (e.g. ServiceTitan attachment `description`, Salesforce `ContentDocument.Description`),
  not as a note attached to the photo.

## 2. Structure — what does the storage shape look like?

What table(s) the bytes actually land in, and how the note row physically
relates to the attachment row.

| Vendor | Notes table | Attachments table | Shared columns / shared storage? | Discriminator |
|---|---|---|---|---|
| **ServiceTitan** | `Notes` per parent type (`JobNote`, `CustomerNote`, `LocationNote`) — schema not public; API shape implies dedicated tables | `Attachments` (separate, schema not public; community threads suggest `JobAttachments` per parent) | None known. Different concepts, different endpoints. | n/a — different tables |
| **Jobber** | Per-entity `*Note` (`ClientNote`, `JobNote`, `VisitNote`, etc.) | `noteAttachments` join table (one note → many attachments) | None — note row and attachment row are connected only by FK | n/a — different tables |
| **Housecall Pro** | Per-entity (Customer/Address/Job/Estimate notes) — schema not public | Per-entity attachments — schema not public | None known | n/a — different tables |
| **Salesforce FS** | `ContentNote` — built **on top of** `ContentVersion` (notes are stored as a special `ContentVersion` payload) | `ContentDocument` (logical) / `ContentVersion` (binary versions) | **Yes — same `ContentVersion` table.** A note is a `ContentVersion` with `FileType = 'snote'`; a file is a `ContentVersion` with `FileType = '<mime>'`. | `ContentVersion.FileType` |
| **Dynamics 365 FS** | `annotation` row with `notetext`, `subject` set | `annotation` row with `documentbody`, `filename`, `mimetype`, `filesize` set | **Yes — same row.** One row carries note OR attachment fields, never both. | `annotation.isdocument : bool` |

### The two real industry storage models

Two genuinely distinct shapes show up across the five:

1. **Per-entity tables, no shared storage** — ServiceTitan, Jobber, HCP. Each
   parent type has its own `Notes` table; attachments are their own thing. The
   note row's columns and the attachment row's columns share nothing
   meaningful. This is the dominant choice.
2. **Single-table polymorphic with a discriminator** — Dynamics' `annotation`
   table; Salesforce's `ContentVersion` is a softer version of the same idea
   (different physical rows but one storage layer). Compact and generic, but
   dependent on platform features (Dataverse polymorphic FKs, Salesforce
   content infrastructure) that PostgreSQL/EF Core doesn't have.

### Relevant column shape — leaf-level fields

Stripped to what each "note" and each "attachment" record actually carries.

**Note row (typical):**
- `Id`, parent FK (entity-specific or polymorphic), `Message` / `NoteText`
- Author (`OwnerId` / `AuthorUserId` / `CreatedBy`)
- Audit: `CreatedAt`. Most vendors also carry `UpdatedAt` / `ModifiedOn`,
  but several treat edits as a separate event-log concern instead — our
  design takes that route (edits flow through the existing `JobEvents`
  audit log via `JobDomainEvent.NoteUpdated`).
- Optional: `IsPinned` (ServiceTitan, HCP), `Subject` (Dynamics)
- *Not in this list:* Dynamics' `isprivate` — it's system-managed and not
  exposed for create/update via the standard Web API surface (see
  "Verified field-level reference" below). Listed in the README's design
  discussion as a *precedent* for our `IsPrivate` flag, not as something a
  Dynamics integrator can actually toggle from outside the platform.

**Attachment row (typical):**
- `Id`, parent FK
- Binary pointer (`ContentId` / `documentbody` / `ContentVersion.VersionData`)
- File metadata (`fileName`, `mimeType`, `size`)
- Author + audit (same shape as notes)
- Optional: `Tags` / `Description` / `Order`

**Overlap.** Author + audit columns are identical across both. Body / binary
columns are mutually exclusive (Dynamics literally puts both on the same row
and uses `isdocument` to flip). This is the column-level evidence behind
"sibling concepts": author + audit overlap, payload doesn't.

### Verified field-level reference (Salesforce + Dynamics)

Two of the five vendors publish full field-level schemas that are reachable
from static documentation. The other three (ServiceTitan, Jobber, HCP) ship
JS-rendered developer portals (Readme.io / Stoplight / custom SPAs) where
endpoint paths are reachable but row-shape detail isn't — for those, you
need the Postman collection (ServiceTitan), authenticated GraphiQL (Jobber),
or the Stoplight runtime (HCP).

#### Salesforce — `ContentVersion` (the row that is both "note" and "file")

| Field | Type | Purpose |
|---|---|---|
| `Id` | ID | Record id. |
| `Title` | String | Display name. |
| `Description` | String | Optional caption. |
| `ContentDocumentId` | Reference | Parent `ContentDocument` (the logical document). |
| `VersionData` | Blob | Binary payload. |
| `PathOnClient` | String | Original filename + path. |
| `ContentLocation` | String | `S` (Salesforce-stored), `E` (external), `L` (link). |
| `FileType` | String | `PDF`, `PNG`, … or `SNOTE` for the note variant — **this is the discriminator**. |
| `FileExtension` | String | e.g. `pdf`. |
| `ContentSize` | Int | Bytes. |
| `OwnerId` | Reference | Owner. |
| `CreatedById`, `CreatedDate` | Reference, DateTime | Audit. |
| `LastModifiedById`, `LastModifiedDate` | Reference, DateTime | Audit. |
| `IsLatest` | Boolean | Latest-version flag. |
| `ContentBodyId` | Reference | Body row. |
| `ReasonForChange` | String | Revision note. |

The link row that ties a `ContentVersion` (or its parent `ContentDocument`)
to e.g. a `ServiceAppointment`:

| `ContentDocumentLink` field | Type | Purpose |
|---|---|---|
| `Id` | ID | Link id. |
| `ContentDocumentId` | Reference | The document being linked. |
| `LinkedEntityId` | Reference (polymorphic) | Parent record (`ServiceAppointment`, `Account`, anything). |
| `ShareType` | Picklist | `V` Viewer / `C` Collaborator / `I` Inferred. |
| `Visibility` | Picklist | `AllUsers` / `InternalUsers` / `SharedUsers`. |

Sources: [`ContentVersion`](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentversion.htm),
[`ContentDocumentLink`](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentdocumentlink.htm).

#### Dynamics 365 — `annotation` (the single-row note-or-attachment table)

| Schema name | Type | Purpose |
|---|---|---|
| `annotationid` | Uniqueidentifier | PK. |
| `objectid` | Lookup (polymorphic) | Parent record FK. Targets include `account`, `contact`, `appointment`, `task`, plus FS entities (`bookableresourcebooking`, `msdyn_workorder`) attached via custom 1:N relationships. |
| `objecttypecode` | EntityName | Parent entity's logical name. |
| `subject` | String(500) | Title — required at app level. |
| `notetext` | Memo (100 000 chars) | Note body. |
| `isdocument` | Boolean | **Discriminator.** True ⇒ attachment, False ⇒ note. |
| `documentbody` | String (≈1 GB) | Base64 file payload. |
| `filename` | String(255) | Filename. |
| `mimetype` | String(256) | MIME. |
| `filesize` | Integer (read-only) | Bytes. |
| `filepointer`, `storagepointer`, `prefix` | String (read-only / internal) | Blob storage references. |
| `langid` | String(2) | Language. |
| `ownerid` / `owneridtype` / `owningbusinessunit` / `owningteam` / `owninguser` | Owner / Lookup | Owner + derived owner refs. |
| `createdby`, `createdon`, `createdonbehalfby` | Lookup, DateTime, Lookup | Audit (with delegate). |
| `modifiedby`, `modifiedon`, `modifiedonbehalfby` | Lookup, DateTime, Lookup | Audit (with delegate). |
| `overriddencreatedon` | DateTime | Migration-only. |
| `isprivate` | Boolean (read-only / internal) | Privacy flag. **Not writable** through the standard Web API (`IsValidForCreate=false`, `IsValidForUpdate=false`); some teams expose it via custom forms / privileged plugins. |
| `versionnumber` | BigInt | Concurrency token. |
| `importsequencenumber` | Integer | Import tracking. |
| `stepid` | String(32) | Workflow step. |

Source: [Note (Annotation) entity reference — Microsoft Learn](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/reference/entities/annotation).

**Refinement vs the Section-2 table above.** Dynamics' `annotation` table is
even more "everything-fused" than the table summary suggests — owner, audit,
and language fields are uniform, and the only thing that meaningfully changes
between a "note row" and an "attachment row" is which of `notetext` vs
`documentbody`+`filename`+`mimetype` is populated. `isprivate` is on every
row but realistically immovable from the API surface.

#### Why ServiceTitan / Jobber / HCP aren't field-table'd here

These three publish API references via Readme.io / GraphiQL / Stoplight —
endpoint paths are scrapeable, the row schema isn't. What's verifiable
without authenticated access:

- **ServiceTitan** — endpoint paths split across two domains:
  - `POST /jpm/v2/tenant/{tenantId}/jobs/{id}/attachments` (create)
  - `GET  /jpm/v2/tenant/{tenantId}/jobs/{id}/attachments` (list)
  - `GET  /forms/v2/tenant/{tenantId}/jobs/attachment/{attachmentId}` (single-fetch goes through Forms domain)
  - No documented PATCH/DELETE — community thread (linked in Sources)
    confirms the gap.
- **Jobber** — confirmed connection types are **per-parent**, not a single
  shared `NoteFileConnection`: `JobNoteFileConnection`,
  `ClientNoteFileConnection`, `RequestNoteFileConnection`,
  `QuoteNoteFileConnection` (plus `InvoiceNoteUnionConnection` for invoices).
  File uploads go through `noteCreate` / `noteUpdate` mutations with file
  inputs; there is no standalone `attachmentCreate` mutation.
- **Housecall Pro** — has a public `POST /jobs/{id}/attachments`
  endpoint documented on Stoplight (MAX plan only); field schema only via
  the Stoplight runtime renderer.

To close these three at field level for any future design doc, grab their
Postman / GraphQL-introspection / Stoplight YAML artifacts directly.

## 3. API — what does the wire shape look like?

| Vendor | Notes endpoint shape | Attachments endpoint shape | Single combined endpoint? |
|---|---|---|---|
| **ServiceTitan** (REST V2) | `GET/POST /jpm/v2/tenant/{tenantId}/jobs/{id}/notes` and per-parent equivalents (`/customers/{id}/notes`, `/locations/{id}/notes`) | `POST /jpm/v2/tenant/{tenantId}/jobs/{id}/attachments` (create), `GET` on the same path (list); single-fetch via `/forms/v2/tenant/{tenantId}/jobs/attachment/{attachmentId}`. **No PATCH/DELETE published.** | No. Notes and attachments are two different REST resources, and attachments are split across the JPM and Forms domains. |
| **Jobber** (GraphQL) | `client.notes : ClientNoteConnection`, `job.notes : JobNoteConnection`, `visit.notes`, etc. — per-parent connection types | Connection on the note: `JobNoteFileConnection` / `ClientNoteFileConnection` / `RequestNoteFileConnection` / `QuoteNoteFileConnection` (plus `InvoiceNoteUnionConnection`). File uploads go via `noteCreate` / `noteUpdate` mutations with file inputs; no standalone `attachmentCreate`. | No. To list "all attachments on a job," the caller queries `job.notes { noteAttachments { … } }` and walks the note layer. Attachments don't exist outside a note. |
| **Housecall Pro** | Per-entity notes endpoints (Stoplight, MAX plan only) | `POST /jobs/{id}/attachments` documented on Stoplight (MAX plan only); field schema only renders via the Stoplight client | No — separate. |
| **Salesforce FS** | `ContentNote` SObject CRUD via REST/SOAP; linked via `ContentDocumentLink` insert | `ContentVersion` SObject CRUD; linked via `ContentDocumentLink` insert | **Partially.** Both are queried via SOQL on `ContentDocumentLink WHERE LinkedEntityId = :appointmentId`; the *type* (note vs file) is a column on the joined `ContentVersion`. So one query returns both, but the developer still distinguishes via `FileType`. |
| **Dynamics 365 FS** | `GET /api/data/v9.x/annotations?$filter=isdocument eq false and _objectid_value eq <bookingId>` | `GET /api/data/v9.x/annotations?$filter=isdocument eq true and _objectid_value eq <bookingId>` | **Yes by default.** The annotation collection returns both kinds of rows — clients filter on `isdocument` if they want one kind only. |

### Patterns

- **Two-resource shape (3 of 5):** notes and attachments are independently
  addressable resources, with their own CRUD verbs under the same parent.
  This is what most developers expect and what most front-ends find easiest
  to render.
- **Note-as-parent-of-attachment (1 of 5):** Jobber's GraphQL only exposes
  attachments through a containing note. There's no `Job.attachments` field
  at all — every file lives under a note, even if the note's body is empty.
- **Single-resource discriminated (1 of 5):** Dynamics' `annotation` REST
  collection mixes both kinds. Convenient for one-shot reads of "everything
  on this booking" but pushes the discriminator into every consumer's filter
  predicate.

### Identity / referencing

- **All five give the note its own stable ID.** No vendor uses a positional
  reference into a parent's array.
- **Polymorphic parent IDs in two of five.** Dynamics' `objectid` and
  Salesforce's `LinkedEntityId` accept any object type; the consumer keeps
  the type out-of-band. The other three (ServiceTitan, Jobber, HCP) bake the
  parent type into the URL path.

### Author / actor

Across all five APIs, the note carries an author user ID; on read, vendors
expand this to `{ id, name, ... }`. Attachments carry the same. **There is
no `system`-authored note** in the public APIs — even imports or sync flows
attribute to a service-account user.

## 4. UI — how does the visit screen present them side by side?

How a tech (or office user) actually sees the two on a visit-equivalent
screen.

| Vendor | Layout pattern | Notes section | Attachments section | Cross-surface from parent levels |
|---|---|---|---|---|
| **ServiceTitan** | **Job Details flyout / mobile job screen, aggregated** | One stream — pinned Customer + Location + Job notes float, each labeled with source | Photos in their own grid section on the same screen | Customer + Location + Job notes all aggregated; attachments NOT aggregated across levels |
| **Jobber** | **Tabbed (Visit / Details / Notes)** | Notes tab: list of notes with author + relative timestamp ("3 days ago") + edited indicator | Attachments thumbnails inline *on each note* (since they're children of the note) | None — Job/Client/Property notes only visible from their own pages; visit notes promote up to Job, but parent notes don't flow down |
| **Housecall Pro** | **Single Job page, sectioned (Notes / Photos / Attachments)** | Notes section: Customer notes (cascaded) + Address notes (cascaded) + Job notes, all in one list with type badges; pinning floats to top | Photos / Attachments grid below the Notes section | **Strongest cascade.** Address notes literally appear inline on the Job page (data-level inheritance at conversion time, not aggregation) |
| **Salesforce FS** | **"Notes & Attachments" related list, one combined component** | Same related list as attachments (notes show with a 📝 icon, files with a file icon) | Files in the same related list (different icon) | None automatic — admins customize page layouts for cross-record surfacing |
| **Dynamics 365 FS** | **Timeline component on the Booking form** | Timeline shows annotations + activities chronologically; notes inline; on mobile, "Quick Notes" picklist (text/photo/video/audio/file) | Same Timeline; attachments shown as cards with file icon | None automatic — admins customize forms for parent-level surfacing |

### UI patterns reduced to four shapes

1. **Mixed-stream chronological** (Salesforce, Dynamics). Notes and
   attachments interleave by time. Visually one feed, distinguished by icon.
   Closest to a chat-app timeline.
2. **Sectioned within the same screen** (HCP, ServiceTitan). "Notes"
   section above, "Photos / Attachments" section below. Clear separation;
   user scrolls between them.
3. **Tabbed** (Jobber). Notes live behind their own tab. Attachments live
   *inside* notes — there's no top-level attachments tab on the visit.
4. **Aggregated stream with source labels** (ServiceTitan's Job Details).
   Notes from multiple parent levels (Customer / Location / Job) collapsed
   into one list, each labeled with where it came from. Pinned notes float.

### Cross-level surfacing — five vendors, three answers

- **HCP**: write-time copy. Address notes are physically duplicated onto the
  Job. Stale-data risk; HCP accepts it.
- **ServiceTitan**: read-time aggregation. The Job Details panel pulls
  Customer + Location + Job notes at render time, source-labeled.
- **Jobber, Salesforce, Dynamics**: no cross-level surfacing by default. The
  user navigates to the parent record to see parent notes, or an admin
  customizes the page.

For attachments specifically, **none of the five auto-cascade attachments
across levels** — only notes do. Photos belong to the entity they were
captured on; nobody surfaces "this customer's old photos" on a new job.

## Cross-pattern reading

Three top-line takeaways, each anchored in the tables above:

1. **Three of five keep notes and attachments structurally separate** at
   every layer (hierarchy, storage, API). Jobber inverts only the note-↔-
   attachment edge (attachment is a child of note); Dynamics fuses them at
   storage but exposes the discriminator everywhere. **No vendor merges
   them at the API surface without a discriminator.**

2. **Author + audit columns overlap; payload columns don't.** Across all
   five, the *only* fields shared by note and attachment rows are `OwnerId`
   / `CreatedBy`, `CreatedAt`, `ModifiedAt`, and (where present) `IsPrivate`.
   The body field of one is meaningless for the other. This is the
   structural reason "use one row with a `Type` enum" feels wrong: the
   columns barely overlap.

3. **Visit-level note surface is rare.** Only Jobber, Salesforce, and
   Dynamics have a notes entity at the visit level; ServiceTitan and HCP
   collapse it up to the Job. Our `Visit` has its own Attachment table
   already, so adding a visit-level Note table follows the more granular
   industry pattern.

## Mapping to our domain

Today (after `WEB-1469` Option E ships):

```
Account (tenant)
└── Job
    └── Visit
        ├── Attachment (Photo only, table = jobs.Attachments)  ── existing
        └── VisitNote   (table = jobs.VisitNotes)              ── this feature
```

How that lines up with the four dimensions:

- **Hierarchy.** `Attachment` and `VisitNote` are both direct children of
  `Visit`, with no edge between them. **Sibling pattern** — matches
  ServiceTitan, HCP, Salesforce. Different from Jobber (no
  attachment-as-child-of-note) and Dynamics (no fused row).
- **Structure.** Two separate Postgres tables in `jobs.*`. `Attachment`
  keeps its existing schema (binary pointer + photo metadata + Tags
  enum). `VisitNote` adds Message + Author + audit + `IsPrivate`. **No
  shared columns beyond author + audit.** Closest to ServiceTitan / Jobber
  / HCP storage; explicitly *not* Dynamics' single-table approach (rejected
  in the README's design discussion because polymorphic FKs aren't
  first-class in EF Core).
- **API.** Two-resource shape. `POST/GET/PATCH/DELETE /visits/{id}/notes`
  for the new resource; existing `/visits/{id}/photos` (or whatever the
  current attachment endpoint is — verify in `Invoices.Backend` controllers)
  unchanged. Plus the aggregator `GET /visits/{id}/notes/aggregated` for the
  worker visit screen, which only joins **notes** across levels (Visit +
  Client). **Attachments are not part of the aggregator** — same
  industry rule: notes cascade across levels, attachments don't.
- **UI.** TBD on the front-end side; the two natural patterns to pick
  from given Option E:
  - **Sectioned** (HCP / ServiceTitan style): Notes block above
    Attachments block on the Visit screen. Most intuitive for office staff
    looking at a job summary.
  - **Mixed chronological timeline** (Salesforce / Dynamics style): single
    "Activity" feed mixing notes and attachments by `CreatedAt`. Best for
    techs reconstructing what happened on a visit.
  - Recommendation: **sectioned for v1.** Mixed timelines are nice but
    require pagination + filtering UX we don't have, and the aggregator
    response is already shaped as separate arrays (`{ visitNotes,
    clientNotes }`).

### What this rules out for v1

Three temptations the survey suggests skipping:

1. **Caption-style notes attached to a photo.** No vendor does this. If a
   photo needs a description, it goes in the photo's own metadata
   (`Attachment.Description`) — out of scope for WEB-1469 but a smaller,
   cleaner change than adding a `Note → Attachment` edge.
2. **Single polymorphic Notes table** (Dynamics shape). Already rejected in
   the README. The structural argument here re-confirms it: polymorphic FKs
   would force `VisitNotes` and `ClientNotes` into one store and lose the
   per-entity FK + cascade-delete that EF gives us for free.
3. **Cross-level aggregation of attachments.** No vendor does this either,
   and our aggregator endpoint should not start. Photos stay scoped to the
   entity they were captured on.

## Sources

ServiceTitan
- [Job Planning API resources](https://developer.servicetitan.io/docs/api-resources-job-planning/)
- [Add notes / pictures to a job](https://help.servicetitan.com/how-to/add-notes-pictures-to-job)
- [Field Mobile App — Job Details overview](https://help.servicetitan.com/how-to/overview-of-the-servicetitan-field-mobile-app-job-details-screen)
- [Jobs API missing endpoints for querying attachments (community)](https://community.servicetitan.com/t5/Integrations/Jobs-API-missing-endpoints-for-querying-attachments/m-p/39772)

Jobber
- [Notes and Attachments](https://help.getjobber.com/hc/en-us/articles/360000110368-Notes-and-Attachments)
- [Notes and Attachments in the Jobber App](https://help.getjobber.com/hc/en-us/articles/7447835963159-Notes-and-Attachments-in-the-Jobber-App)
- [Jobber API docs](https://developer.getjobber.com/docs/)

Housecall Pro
- [Using Notes: Customers, Jobs, and Addresses](https://help.housecallpro.com/en/articles/1083638-using-notes-customers-jobs-and-addresses)
- [Private Notes on Jobs and Estimates](https://help.housecallpro.com/en/articles/2883273-private-notes-on-jobs-and-estimates)
- [Add an Attachment to a Job (public API, Stoplight)](https://docs.housecallpro.com/docs/housecall-public-api/c4ea6b1217b22-add-an-attachment-to-a-job)
- [API Overview](https://help.housecallpro.com/en/articles/8505035-api-overview)

Salesforce Field Service
- [Field Service Developer Guide — Core Data Model](https://developer.salesforce.com/docs/atlas.en-us.field_service_dev.meta/field_service_dev/fsl_dev_soap_core.htm)
- [ContentNote object reference](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentnote.htm)
- [ContentVersion object reference](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentversion.htm)
- [ContentVersion field reference](https://developer.salesforce.com/docs/atlas.en-us.sfFieldRef.meta/sfFieldRef/salesforce_field_reference_ContentVersion.htm)
- [ContentDocument object reference](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentdocument.htm)
- [ContentDocumentLink object reference](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentdocumentlink.htm)

Dynamics 365 Field Service
- [Annotation entity reference (Dataverse)](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/reference/entities/annotation)
- [bookableresourcebooking entity reference](https://learn.microsoft.com/en-us/dynamics365/field-service/developer/reference/entities/bookableresourcebooking)
- [Field Service work order architecture](https://learn.microsoft.com/en-us/dynamics365/field-service/field-service-architecture)
