App Links with OneLink (App Store and Google Play)
==================================================

This document describes how backend services use OneLink URLs to generate
application links for the App Store and Google Play. It is intended to be
used as a generic guideline across services.

Overview
--------

- Backend services do not construct OneLink URLs manually in controllers.
- Each service exposes configuration values for base OneLink URLs, for
  example:
  - `AppLinkAppStore` - base OneLink URL for iOS / App Store.
  - `AppLinkGooglePlay` - base OneLink URL for Android / Google Play.
- Application code treats these values as *base URLs* and adds query
  parameters at runtime in code.
- OneLink accepts configuration only via query parameters; backend code
  must not modify path segments of the base URL.
- Predefined AppsFlyer query parameters such as `af_xp`, `pid`, and
  `af_dp` are treated as part of the base URL and should be configured
  in `appsettings.json` (see example below). Backend code should only
  append additional feature-specific query parameters.
- OneLink is responsible for redirecting the user either to the store page
  or directly into the installed app via deep links, based on the URL
  parameters and the device.

Configuration
-------------

- Base OneLink URLs (for example, `AppLinkAppStore`, `AppLinkGooglePlay`)
  must be stored in configuration, not hard-coded in code.
- These values should be bound to a strongly typed options class and
  validated on startup (for example, using `[Required]` attributes).
- Prefer environment-specific configuration (Development, Staging,
  Production) instead of per-tenant settings.

Example `appsettings.json` section (stores)
-------------------------------------------

The exact section name and keys may vary by service, but a typical
configuration for store-related OneLink URLs looks like:

```json
"OneLink": {
  "AppLinkAppStore": "https://invoice-maker.onelink.me/Z7EF?af_xp=custom&pid=Tofu.com&af_dp=com.getpaidapp.invoices%3A%2F%2F&deep_link_value=claim_email",
  "AppLinkGooglePlay": "https://invoice-maker.onelink.me/WgXa?af_xp=custom&pid=Tofu.com&af_dp=com.getpaidapp.invoices%3A%2F%2F&deep_link_value=claim_email"
}
```

In this example, the AppsFlyer query parameters `af_xp`, `pid`, and
`af_dp` are preconfigured in `appsettings.json` as part of the base
URL and are not set dynamically per request.

Here:

- `af_xp` controls the experience type (for example, `custom`);
- `pid` is the OneLink campaign or partner identifier;
- `af_dp` is the encoded app deep-link URI;
- `deep_link_value` is the value consumed by the app when opened from
  the OneLink.

Query Parameters and Deep Links
-------------------------------

When building a OneLink URL in backend code:

- take the base `AppLinkAppStore` / `AppLinkGooglePlay` values from config;
- append only additional business-specific query parameters in code;
- do not override the preconfigured AppsFlyer parameters (`af_xp`,
  `pid`, `af_dp`) from code.

For example:

```csharp
var baseUrl = config.AppLinkAppStore;

var query = new Dictionary<string, string?>
{
    ["email"] = email,
    ["customer_id"] = customerId,
};

var uriBuilder = new UriBuilder(baseUrl);
var queryString = string.Join(
    "&",
    query
        .Where(kv => kv.Value is not null)
        .Select(kv => $"{WebUtility.UrlEncode(kv.Key)}={WebUtility.UrlEncode(kv.Value)}"));
uriBuilder.Query = string.IsNullOrEmpty(uriBuilder.Query)
    ? queryString
    : $"{uriBuilder.Query.TrimStart('?')}&{queryString}";

var finalUrl = uriBuilder.Uri.ToString();
```

When to Update This Document
----------------------------

Update this document when:

- OneLink parameters or base URLs change for all products.
- New backend services start using OneLink and introduce new required
  parameters.
- The deep-link value (`deep_link_value`) or app routing rules change in a
  way that affects how backend should construct URLs.

