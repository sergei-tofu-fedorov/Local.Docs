# WEB-1414: Content Linked Per Attachment

## Overview

Content (photos, files) is now linked per attachment instead of per job. Each `ContentEntry` carries an `AttachmentId` alongside `ContentId`, so the content service links/unlinks against individual attachments rather than the job entity.

## What changed

### ContentEntry

`ContentEntry` now includes `AttachmentId`:

```
ContentEntry(Guid AttachmentId, string ContentId, ContentAdditionalProperties? Properties)
```

### ContentEntities enum

Renamed `Job = 3` to `JobAttachment = 3` to reflect that content is owned by an attachment, not by the job as a whole.

### IJobContentService

- `LinkContentAsync` no longer takes `jobId` -- it uses `AttachmentId` from each `ContentEntry` as the entity ID.
- `UnlinkContentAsync` now accepts `IReadOnlyList<ContentEntry>` instead of `IReadOnlyList<string>` content IDs, so it can unlink per attachment.

### DeleteJobCommandHandler

Now unlinks all attachment content when a job is deleted, using `Job.GetContentEntries()` to collect entries before soft-deleting.

## Bug fix: sync job content enrichment

The sync jobs endpoint (`SyncJobsQueryHandler`) was returning jobs without resolved content URLs. Now content is correctly enriched for all non-deleted jobs in the sync response.
