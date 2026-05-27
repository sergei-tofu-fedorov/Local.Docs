Tofu.Invoices API – Proto Contracts
===================================

This document embeds the exact protobuf definitions used by
`https://github.com/m-unicorn/Tofu.Invoices.Backend` for invoices and estimates.

InvoicesApi.V1.InvoicesApi
--------------------------

```proto
syntax = "proto3";

package InvoicesApi.V1;
option csharp_namespace = "Tofu.Invoices.V1";

import "google/api/annotations.proto";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";

import "CustomTypes.proto";
import "V1/CommonTypes.proto";

service InvoicesApi {
    rpc GetAllPaidInvoicesByYear (GetInvoicesByYearRequest) returns (GetInvoicesByYearResponse){
        option (google.api.http) = {
            post: "/v1/invoices/search-paid-by-year"
            body: "*"
        };
    }

    rpc GetAll (GetAllRequest) returns (GetAllResponse){
        option (google.api.http) = {
            post: "/v1/invoices/search"
            body: "*"
        };
    }

    rpc GetInvoiceBalances(GetInvoiceBalancesRequest) returns (GetInvoiceBalancesResponse) {
        option (google.api.http) = {
            post: "/v1/invoices/balances"
            body: "*"
        };
    }

    rpc GetInvoicePaged(GetInvoicesPagedRequest) returns (GetInvoicesPagedResponse) {
        option (google.api.http) = {
            post: "/v1/invoices/paged",
            body: "*"
        };
    }

    rpc Get (GetRequest) returns (GetResponse){
        option (google.api.http) = {
            get: "/v1/invoices/{invoice_id}"
        };
    }

    rpc Add (AddRequest) returns (AddResponse){
        option (google.api.http) = {
            post: "/v1/invoices"
            body: "*"
        };
    }
//todo(zudwa): use Add for set is_deleted
    rpc Delete (DeleteRequest) returns (DeleteResponse){
        option (google.api.http) = {
            post: "/v1/invoices/delete"
            body: "*"
        };
    }

    rpc CalculateReport(CalculateReportRequest) returns (CalculateReportResponse) {
        option (google.api.http) = {
            post: "/v1/invoices/report"
            body: "*"
        };
    }

    rpc GetTimelineByCursor(GetTimelineByCursorRequest) returns (GetTimelineByCursorResponse){
        option (google.api.http) = {
            get: "/v1/invoices/timeline"
        };
    }

    rpc GetTimelineByEntityId(GetTimelineByEntityIdRequest) returns (GetTimelineByEntityIdResponse){
        option (google.api.http) = {
            get: "/v1/invoices/timeline-by-entity-id"
        };
    }

    rpc SetEmailStatus (SetEmailStatusRequest) returns (SetEmailStatusResponse) {
        option (google.api.http) = {
            post: "/v1/invoices/set-email-status"
            body: "*"
        };
    }
}

message CalculateReportRequest {
    string account_id = 1;
    google.protobuf.Timestamp period_start = 2;
    google.protobuf.Timestamp period_end = 3;
}

message CalculateReportResponse {
    string account_id = 1;
    google.protobuf.Timestamp period_start = 2;
    google.protobuf.Timestamp period_end = 3;
    int64 total_count = 4;
    Info paid_info = 5;
    Info unpaid_overdue_info = 6;
    Info unpaid_not_overdue_info = 7;
    repeated ReportItem items = 8;
}

message GetInvoicesPagedRequest {
    string account_id = 1;
    int32 limit = 2;
    google.protobuf.StringValue client_id = 3;
    InvoiceStatus invoice_status_type = 4;
    google.protobuf.StringValue token = 5;
}

message GetInvoicesPagedResponse {
    repeated InvoiceObj invoices = 1;
    google.protobuf.StringValue next_token = 2;
    int64 total_count = 3;
}

message GetInvoiceBalancesRequest {
    string account_id = 1;
    google.protobuf.StringValue client_id = 2;
}

message GetInvoiceBalancesResponse {
    InvoicesBalances Balances = 1;
}

message ReportItem {
    google.protobuf.Timestamp period_start = 1;
    google.protobuf.Timestamp period_end = 2;
    int64 count = 3;
    Info paid_info = 4;
    Info unpaid_overdue_info = 5;
    Info unpaid_not_overdue_info = 6;
}

message Info {
    DecimalValue amount = 1;
    int64 count = 2;
}

message GetInvoicesByYearRequest {
    string account_id = 1;
    int32 year = 2;
}

message GetInvoicesByYearResponse {
    string account_id = 1;
    repeated InvoiceObj invoices = 2;
}

message GetAllRequest {
    string account_id = 1;
    bool include_extended_info = 2;
    google.protobuf.StringValue client_id = 3;
}

message GetAllResponse {
    string account_id = 1;
    repeated InvoiceObj invoices = 2;
}

message GetRequest {
    string account_id = 1;
    string invoice_id = 2;
    bool include_extended_info = 3;
}

message GetResponse {
    InvoiceObj invoice = 1;
}

message AddRequest {
    InvoiceObj invoice = 1;
    optional google.protobuf.StringValue master_user_id = 2;
    optional int64 occurred_at_ms = 3; //unix time ms
}

message AddResponse {
    InvoiceObj invoice = 1;
}

message DeleteRequest {
    string account_id = 1;
    string invoice_id = 2;
    int32 version = 3;
}

message DeleteResponse {
}

message InvoiceObj {
    google.protobuf.StringValue account_id = 1;
    google.protobuf.StringValue product_key = 2;
    Client client = 3;
    google.protobuf.Timestamp date = 4;
    google.protobuf.Int32Value due_days = 5;
    google.protobuf.StringValue number = 6;
    InvoiceStatus status = 7;
    EmailStatus mail_status = 8;
    google.protobuf.StringValue mail_status_error_message = 9;
    DueDateNotificationStatus due_date_status = 10;
    repeated InvoiceItem items = 11;
    google.protobuf.StringValue payment_details = 12;
    google.protobuf.StringValue notes = 13;
    DiscountDescriptor discount = 14;
    TaxDescriptor tax = 15;
    DecimalValue subtotal_amount = 16;
    DecimalValue discount_amount = 17;
    DecimalValue tax_amount = 18;
    DecimalValue total_amount = 19;
    repeated DecimalValue received_payments = 20;
    DecimalValue total_due = 21;
    bool is_deleted = 22;
    google.protobuf.Timestamp created_on = 23;
    google.protobuf.Timestamp mark_as_paid_date = 24;
    ReceiptInfo receipt_info = 25;
    google.protobuf.StringValue id = 26;
    int32 version = 27;
    PaymentInfo payment_info = 28;
    InvoiceInfo info = 29;
    google.protobuf.StringValue currency_code = 30;
    google.protobuf.Timestamp paid_date = 31;
    RefundInformation refund_information = 32;
    repeated Attachment attachments = 33;
    google.protobuf.StringValue job_id = 34;
}
message Attachment {
    string id = 1;
    int32 order = 2;
}
enum RefundStatus {
    RS_UNKNOWN = 0;
    RS_COMPLETED = 1;
    RS_CANCELED = 2;
}

message Refund {
    google.protobuf.StringValue id = 1;
    google.protobuf.Timestamp date = 2;
    DecimalValue amount = 3;
    google.protobuf.StringValue reason = 4;
    google.protobuf.StringValue account_id = 5;
    google.protobuf.StringValue external_payment_id = 6;
    google.protobuf.StringValue external_refund_id = 7;
    google.protobuf.StringValue invoice_id = 8;
    RefundStatus status = 9;
}
message RefundInformation {
    repeated Refund refunds = 1;
}

message InvoiceInfo {
    google.protobuf.Timestamp created_at = 1;
    DecimalValue calculated_total_amount = 2;
    DecimalValue calculated_total_due = 3;
}

message PaymentInfo {
    repeated string accepted_payment_providers = 1;
    google.protobuf.StringValue paid_by_provider = 2;
}

message Client {
    google.protobuf.StringValue name = 1;
    google.protobuf.StringValue phone = 2;
    google.protobuf.StringValue email = 3;
    google.protobuf.StringValue address = 4;
    google.protobuf.StringValue catalog_id = 5;
}


message InvoiceBalance {
    string currency_code = 1;
    DecimalValue total_paid = 2;
    DecimalValue total_due = 3;
    DecimalValue total_amount = 4;
}

message InvoicesBalances {
    map<string, InvoiceBalance> balancesByCurrencyCode = 1;
    int32 paid_invoices_count = 2;
    int32 unpaid_invoices_count = 3;
}

message ReceiptInfo {
    google.protobuf.StringValue receipt_id = 1;
    google.protobuf.StringValue receipt_url = 2;
    google.protobuf.StringValue provider = 3;
    optional google.protobuf.StringValue psp_account_id = 4;
}

message DiscountDescriptor {
    DecimalValue value = 1;
    DiscountType type = 2;
}

message TaxDescriptor {
    DecimalValue percent_value = 1;
    TaxType type = 2;
    google.protobuf.StringValue name = 3;
}

message InvoiceItem {
    google.protobuf.StringValue name = 1;
    google.protobuf.StringValue details = 2;
    google.protobuf.StringValue description = 3;
    DecimalValue unit_price = 4;
    UnitType unit_type = 5;
    DecimalValue quantity = 6;
    DiscountDescriptor discount = 7;
    bool is_tax_applied = 8;
    google.protobuf.StringValue catalog_id = 9;
    ItemType item_type = 10;
}

enum InvoiceStatus {
    IS_UNKNOWN = 0;
    IS_NOT_PAID = 1;
    IS_PAID = 2;
    IS_PAID_BY_CARD = 3;
    IS_REFUNDED = 4;
    IS_PARTIAL_REFUNDED = 5;
}

enum EmailStatus {
    ES_UNKNOWN = 0;
    ES_SENT = 1;
    ES_IN_PROGRESS = 2;
    ES_OPENED = 3;
    ES_MARKED_AS_SENT = 4;
    ES_ERROR = 5;
}

enum DueDateNotificationStatus {
    DD_UNKNOWN = 0;
    DD_SENT = 1;
    DD_ERROR = 2;
}

enum UnitType {
    UT_NONE = 0;
    UT_HOURS = 1;
    UT_DAYS = 2;
}

enum TaxType {
    TT_UNKNOWN = 0;
    TT_INCLUSIVE = 1;
    TT_EXCLUSIVE = 2;
}

enum DiscountType {
    DT_UNKNOWN = 0;
    DT_PERCENT = 1;
    DT_ABSOLUTE = 2;
}

enum ItemType {
    IT_UNKNOWN = 0;
    IT_SERVICE = 1;
    IT_MATERIAL = 2;
}

message GetTimelineByCursorRequest {
    string account_id = 1;
    google.protobuf.StringValue cursor = 2;
    optional int32 page_size = 3;
}

message GetTimelineByCursorResponse {
    string accountId = 1;
    repeated InvoiceTimelineItem items = 2;
    string cursor = 3;
    bool has_more = 4;
}

message GetTimelineByEntityIdRequest {
    string account_id = 1;
    string entity_id = 2;
    google.protobuf.Int32Value limit = 3;
}

message GetTimelineByEntityIdResponse {
    string accountId = 1;
    repeated InvoiceTimelineItem items = 2;
}

message InvoiceTimelineItem {
    int64 id = 1;
    string account_id = 2;
    string entity_id = 3;
    google.protobuf.StringValue master_user_id = 4;
    google.protobuf.Timestamp created_at = 5;
    google.protobuf.Timestamp occurred_at = 6;
    InvoiceEventType event_type = 7;
    ActorType actor_type = 8;
    string payload = 9;
    int32 entity_version = 10;
}

enum InvoiceEventType {
    IET_UNKNOWN = 0;
    IET_STATUS_CHANGED = 1;
    IET_EMAIL_STATUS_CHANGED = 2;
    IET_PAYMENT_RECEIVED = 3;
}


message SetEmailStatusRequest {
    string account_id = 1;
    string entity_id = 2;
    EmailStatus status = 3;
    google.protobuf.Timestamp occurred_at = 4;
    ActorType actor_type = 5;
    google.protobuf.StringValue master_user_id = 6;
    EmailProviderType provider = 7;
    google.protobuf.StringValue recipient = 8;
    google.protobuf.StringValue error_message = 9;
}

message SetEmailStatusResponse {
    InvoiceObj invoice = 1;
    bool status_is_changed = 2;
}
```

EstimatesApi.V1.EstimatesApi
----------------------------

```proto
syntax = "proto3";

package EstimatesApi.V1;
option csharp_namespace = "Tofu.Estimates.V1";

import "google/api/annotations.proto";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";

import "CustomTypes.proto";
import "V1/InvoicesApi.proto";
import "V1/CommonTypes.proto";

service EstimatesApi {
    rpc GetAll (GetAllRequest) returns (GetAllResponse){
        option (google.api.http) = {
            post: "/v1/estimates/search"
            body: "*"
        };
    }

    rpc Get (GetRequest) returns (GetResponse){
        option (google.api.http) = {
            get: "/v1/estimates/{estimate_id}"
        };
    }

    rpc Add (AddRequest) returns (AddResponse){
        option (google.api.http) = {
            post: "/v1/estimates"
            body: "*"
        };
    }
//todo(zudwa): use Add for set is_deleted
    rpc Delete (DeleteRequest) returns (DeleteResponse){
        option (google.api.http) = {
            post: "/v1/estimates/delete"
            body: "*"
        };
    }

    rpc GetEstimatesPaged(GetEstimatesPagedRequest) returns (GetEstimatesPagedResponse) {
        option (google.api.http) = {
            post: "/v1/estimates/paged",
            body: "*"
        };
    }

    rpc GetEstimatesBalances(GetEstimatesBalancesRequest) returns (GetEstimatesBalancesResponse) {
        option (google.api.http) = {
            post: "/v1/estimates/balances"
            body: "*"
        };
    }

    rpc GetEstimatesBalancesByStatus(GetEstimatesBalancesByStatusRequest) returns (GetEstimatesBalancesByStatusResponse) {
        option (google.api.http) = {
            post: "/v1/estimates/balances-by-status"
            body: "*"
        };
    }

    rpc GetTimelineByCursor(GetTimelineByCursorRequest) returns (GetTimelineByCursorResponse){
        option (google.api.http) = {
            get: "/v1/estimates/timeline"
        };
    }

    rpc GetTimelineByEntityId(GetTimelineByEntityIdRequest) returns (GetTimelineByEntityIdResponse){
      option (google.api.http) = {
          get: "/v1/estimates/timeline-by-entity-id"
      };
    }

    rpc SetEmailStatus (SetEmailStatusRequest) returns (SetEmailStatusResponse) {
      option (google.api.http) = {
          post: "/v1/estimates/set-email-status"
          body: "*"
      };
    }
}

message SetEmailStatusRequest {
  string account_id = 1;
  string entity_id = 2;
  InvoicesApi.V1.EmailStatus status = 3;
  google.protobuf.Timestamp occurred_at = 4;
  InvoicesApi.V1.ActorType actor_type = 5;
  google.protobuf.StringValue master_user_id = 6;
  InvoicesApi.V1.EmailProviderType provider = 7;
  google.protobuf.StringValue recipient = 8;
  google.protobuf.StringValue error_message = 9;
}

message SetEmailStatusResponse {
  EstimateObj estimate = 1;
  bool status_is_changed = 2;
}

message GetAllRequest {
    string account_id = 1;
    google.protobuf.StringValue client_id = 2;
    optional google.protobuf.Timestamp created_date_from = 3; // null
    optional google.protobuf.Timestamp created_date_to = 4; // null
    optional google.protobuf.Int32Value limit = 5;
    optional bool include_deleted_entities = 6; // false
}

message GetAllResponse {
    string account_id = 1;
    repeated EstimateObj estimates = 2;
}

message GetRequest {
    string account_id = 1;
    string estimate_id = 2;
    bool include_extended_info = 3;
}

message GetResponse {
    EstimateObj estimate = 1;
}

message AddRequest {
    EstimateObj estimate = 1;
    optional google.protobuf.StringValue master_user_id = 2;
    optional int64 occurred_at_ms = 3; //unix time ms
}

message AddResponse {
    EstimateObj estimate = 1;
}

message DeleteRequest {
    string account_id = 1;
    string estimate_id = 2;
    int32 version = 3;
}

message DeleteResponse {
}

message EstimateObj {
    google.protobuf.StringValue account_id = 1;
    google.protobuf.StringValue product_key = 2;
    google.protobuf.StringValue id = 3;
    int32 version = 4;
    google.protobuf.Timestamp created_on = 5;
    InvoicesApi.V1.Client client = 6;
    google.protobuf.Timestamp date = 7;
    google.protobuf.StringValue number = 8;
    InvoicesApi.V1.EmailStatus mail_status = 9;
    google.protobuf.StringValue mail_status_error_message = 10;
    repeated InvoicesApi.V1.InvoiceItem items = 11;
    google.protobuf.StringValue payment_details = 12;
    google.protobuf.StringValue notes = 13;
    InvoicesApi.V1.DiscountDescriptor discount = 14;
    InvoicesApi.V1.TaxDescriptor tax = 15;
    InvoicesApi.DecimalValue subtotal_amount = 16;
    InvoicesApi.DecimalValue discount_amount = 17;
    InvoicesApi.DecimalValue tax_amount = 18;
    InvoicesApi.DecimalValue total_amount = 19;
    bool is_deleted = 20;
    google.protobuf.Int32Value due_days = 21;
    EstimateInfo info = 22;
    google.protobuf.StringValue currency_code = 23;
    repeated Attachment attachments = 24;
    EstimateStatus status = 25;
    EstimateSentMethod sent_method = 26;
    google.protobuf.StringValue job_id = 27;
}
message Attachment {
    string id = 1;
    int32 order = 2;
}

message EstimateInfo {
    InvoicesApi.DecimalValue calculated_total_due = 1;
}

message GetEstimatesPagedRequest {
    string account_id = 1;
    int32 limit = 2;
    google.protobuf.StringValue client_id = 3;
    google.protobuf.StringValue token = 4;
    repeated EstimateStatus status_types = 5;
}

message GetEstimatesPagedResponse {
    repeated EstimateObj estimates = 1;
    google.protobuf.StringValue next_token = 2;
    int64 total_count = 3;
}

message GetEstimatesBalancesRequest {
    string account_id = 1;
    google.protobuf.StringValue client_id = 2;
}

message GetEstimatesBalancesResponse {
    EstimatesBalances balances = 1;
}

message GetTimelineByCursorResponse {
    string accountId = 1;
    repeated EstimateTimelineItem items = 2;
    string cursor = 3;
    bool has_more = 4;
}

message GetTimelineByCursorRequest {
    string account_id = 1;
    google.protobuf.StringValue cursor = 2;
    optional int32 page_size = 3;
}

message GetTimelineByEntityIdRequest {
  string account_id = 1;
  string entity_id = 2;
  google.protobuf.Int32Value limit = 3;
}

message GetTimelineByEntityIdResponse {
  string accountId = 1;
  repeated EstimateTimelineItem items = 2;
}

message EstimatesBalance {
    string currency_code = 1;
    InvoicesApi.DecimalValue total_amount = 2;
}

message EstimatesBalances {
    map<string, EstimatesBalance> balances_by_currency_code = 1;
}

message GetEstimatesBalancesByStatusRequest {
    string account_id = 1;
    google.protobuf.StringValue client_id = 2;
}

message GetEstimatesBalancesByStatusResponse {
    repeated EstimatesStatusBalance balances_by_status = 1;
}

message EstimatesStatusBalance {
    EstimateStatus status = 1;
    int32 count = 2;
    map<string, EstimatesBalance> balances_by_currency_code = 3;
}

message EstimateTimelineItem {
    int64 id = 1;
    string account_id = 2;
    string entity_id = 3;
    google.protobuf.StringValue master_user_id = 4;
    google.protobuf.Timestamp created_at = 5;
    google.protobuf.Timestamp occurred_at = 6;
    EstimateEventType event_type = 7;
    InvoicesApi.V1.ActorType actor_type = 8;
    string payload = 9;
    int32 entity_version = 10;
}

enum EstimateStatus {
    ES_UNKNOWN = 0;
    ES_DRAFT = 1;
    ES_SENT = 2;
    ES_APPROVED = 3;
    ES_CANCELED= 4;
    ES_DONE = 5;
}

enum EstimateSentMethod {
  ESM_UNKNOWN = 0;
  ESM_EMAIL = 1;
  ESM_MANUAL = 2;
}

enum EstimateEventType {
    EET_UNKNOWN = 0;
    EET_STATUS_CHANGED = 1;
    EET_EMAIL_STATUS_CHANGED = 2;
}
```
