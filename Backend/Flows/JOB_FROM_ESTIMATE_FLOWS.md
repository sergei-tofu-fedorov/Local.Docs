# Step 6: Job From Estimate — Workflow Flows

Mermaid versions of the workflow diagrams from [overview.md](overview.md).

## Create Job From Estimate

```mermaid
sequenceDiagram
    participant Client
    participant Backend as Invoices.Backend (Jobs domain)
    participant Tofu as Tofu.Invoices (gRPC)

    Client->>Backend: POST /jobs/from-estimate
    Backend->>Tofu: GetEstimateWithItems
    Tofu-->>Backend: Estimate + items

    Note over Backend: Validate status = Approved
    Note over Backend: Create Job aggregate, job.TryAddEstimateLink()
    Note over Backend: Set currency from estimate
    Note over Backend: Save job + jobCreated event

    Backend->>Tofu: LinkJobToEstimate RPC (sets JobId + estimateJobCreated)
    Tofu-->>Backend: OK

    Backend-->>Client: JobDto response
```

## Save Invoice with JobId

```mermaid
sequenceDiagram
    participant Client
    participant Backend as Invoices.Backend
    participant Tofu as Tofu.Invoices (gRPC)

    Client->>Backend: PUT /invoices { jobId, estimateId, ... }

    Note over Backend: InvoicesController.Put
    Note over Backend: Map InvoiceDto to Invoice (JobId, EstimateId preserved)

    Backend->>Backend: Get Job by JobId

    alt Job found
        Note over Backend: Check job has no different invoice linked
        Note over Backend: Extract jobNumber
        Note over Backend: If job has estimate: set invoice.EstimateId
    else Job not found
        Note over Backend: OK (sync - job will come later)
    end

    Note over Backend: Sync attachments

    Backend->>Tofu: InvoicesApiClient.AddAsync (full invoice upsert + jobNumber)
    Note over Backend,Tofu: If new invoice has JobId = created from job
    Tofu-->>Backend: OK

    Note over Backend: TryUpdateJobSummary (if jobId non-empty)
    Note over Backend: UpdateJobFromInvoiceCmd
    Note over Backend: job.TryAddInvoiceLink (append-only, idempotent)
    Note over Backend: job.UpdateInvoiceInfo (Summary: amounts, status)

    Backend-->>Client: InvoiceDto response
```

## Save Estimate with JobId

```mermaid
sequenceDiagram
    participant Client
    participant Backend as Invoices.Backend
    participant Tofu as Tofu.Invoices (gRPC)

    Client->>Backend: PUT /estimates { jobId, ... }

    Note over Backend: EstimatesController.Put
    Note over Backend: Map EstimateDto to Estimate (JobId preserved)

    Backend->>Backend: Get Job by JobId

    alt Job found
        Note over Backend: Check job has same or no estimate linked
        Note over Backend: Extract jobNumber
        Note over Backend: If job has invoice: set estimate.InvoiceId
    else Job not found
        Note over Backend: OK (sync - job will come later)
    end

    Note over Backend: Sync attachments

    Backend->>Tofu: EstimatesApiClient.AddAsync (full estimate upsert + jobNumber)
    Note over Backend,Tofu: If JobId changed from null generates estimateJobCreated event
    Tofu-->>Backend: OK

    Note over Backend: TryUpdateJobLink (if jobId non-empty)
    Note over Backend: UpdateJobFromEstimateCmd
    Note over Backend: job.TryAddEstimateLink (append-only, idempotent)

    Backend-->>Client: EstimateDto response
```

## Remove Invoice (cleanup)

```mermaid
sequenceDiagram
    participant Client
    participant Backend as Invoices.Backend
    participant Tofu as Tofu.Invoices (gRPC)

    Client->>Backend: DELETE /invoices/{id}

    Note over Backend: InvoicesController.Delete, get invoice

    Backend->>Tofu: Delete invoice via gRPC
    Note over Backend,Tofu: If invoice has EstimateId, Tofu.Invoices clears InvoiceId on Estimate
    Tofu-->>Backend: OK

    alt Invoice had JobId
        Note over Backend: Remove invoice from Job.Relations.Invoices
        Note over Backend: Reset Job.Summary (clear invoice amounts, status)
    end

    Backend-->>Client: OK
```

## Delete Job (cleanup)

```mermaid
sequenceDiagram
    participant Client
    participant Backend as Invoices.Backend (Jobs domain)
    participant Tofu as Tofu.Invoices (gRPC)

    Client->>Backend: DELETE /jobs/{id}

    Backend->>Tofu: ClearInvoiceLinks (set invoice.JobId = null)
    Backend->>Tofu: ClearEstimateLinks (set estimate.JobId = null)

    Note over Backend: Soft-delete job, save + jobDeleted event

    Backend-->>Client: OK
```
