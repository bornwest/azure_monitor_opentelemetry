# azure_monitor_opentelemetry

Application performance monitoring for Ruby apps on **Azure Monitor / Application Insights**, built
on [OpenTelemetry](https://opentelemetry.io/docs/languages/ruby/). One call traces web requests,
background jobs, SQL, and outbound HTTP and sends them straight to Application Insights. There's
no collector, sidecar, or agent to run.

Microsoft ships Azure Monitor OpenTelemetry distros for .NET, Java, Node.js, and Python, but not
Ruby. This gem fills that gap. It applies the same span-to-telemetry mapping as Microsoft's
exporters, so traces show up in the normal Application Insights views: performance (slowest
operations, percentiles), failures, transaction search, end-to-end transaction details, and the
application map.

Unofficial; not affiliated with Microsoft.

## Install

```ruby
gem "azure_monitor_opentelemetry", github: "bornwest/azure_monitor_opentelemetry"
```

Requires Ruby 3.3 or later. The OpenTelemetry SDK and instrumentation for Rack, Rails (Action
Pack, Action View, Active Record, Active Job, …), PostgreSQL, MySQL, Net::HTTP, and Faraday come
with it. Each instrumentation turns on only when the app loads its library.

## Use

In a Rails initializer, such as `config/initializers/opentelemetry.rb`:

```ruby
AzureMonitorOpenTelemetry.configure(service_name: "my-app")
```

That's it. Set `APPLICATIONINSIGHTS_CONNECTION_STRING`, the same variable Microsoft's SDKs use,
to the connection string on the Application Insights resource's Overview page. Without it,
`configure` does nothing and returns `false`, so the same code runs in environments without
telemetry.

| Option | Default | |
|---|---|---|
| `service_name:` | | Required. Becomes the cloud role, which the application map and role filters use. |
| `connection_string:` | `ENV["APPLICATIONINSIGHTS_CONNECTION_STRING"]` | Supplies the instrumentation key and regional ingestion endpoint (`IngestionEndpoint`, or `EndpointSuffix` and `Location` for sovereign clouds). The key falls back to `APPINSIGHTS_INSTRUMENTATIONKEY`. |
| `managed_identity:` | From `APPLICATIONINSIGHTS_AUTH`, else `true` when `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are set | Authenticate with the host's managed identity. |
| `managed_identity_client_id:` | `nil` | Client ID of a user-assigned identity; omit for system-assigned. |
| `sampling_ratio:` | `ENV["OTEL_TRACES_SAMPLER_ARG"]`, else `1.0` | Fraction of traces to keep. |
| `untraced_paths:` | `["/up"]` | Paths not to trace: exact, or prefixes when they end in `/` (`"/assets/"`). |
| `untraced_jobs:` | `[]` | Job class names whose runs aren't traced, such as a recurring maintenance job that would otherwise dominate telemetry. The jobs still run. |
| `instrumentation:` | `{}` | Per-instrumentation options merged over the defaults, keyed by class name as OpenTelemetry's `use_all` takes them. |

A block receives the OpenTelemetry SDK configurator, for anything else, such as extra span
processors or resource attributes.

### Defaults

- **Traces start only at a web request or a job run.** Spans without a parent of any other kind
  are dropped. Otherwise a job queue's polling queries would each become a trace. Child spans
  follow their parent's sampling decision.
- **App Service's Always On pings and `/up` aren't traced.**
- **SQL literals are obfuscated** for PostgreSQL and MySQL (`WHERE email = ?`), since they can
  hold personal or financial data.
- **Jobs are named by class** (`InvoiceJob process`), so each job gets its own row in Performance.
- **Every dependency and exception is listed under its request's name**, including those exported
  while a long request or job is still running.
- **Spans are flushed at exit**, so a deploy or restart doesn't lose the last few seconds.
- When `sampling_ratio` is below 1, sampled telemetry carries the rate, so Application Insights
  scales its request and dependency counts back up.

### Spans for anything else

Libraries without an instrumentation can be traced with the OpenTelemetry API, and the spans
export like any other:

```ruby
tracer = OpenTelemetry.tracer_provider.tracer("my-app")
tracer.in_span("report.render", kind: :internal) { render_report }
```

### Exporter only

To wire the SDK yourself, register the exporter behind a batch span processor:

```ruby
OpenTelemetry::SDK.configure do |c|
  c.service_name = "my-app"
  c.use_all
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(AzureMonitorOpenTelemetry::SpanExporter.new),
  )
end
```

`SpanExporter.new` takes the `connection_string:`, `managed_identity:`, and
`managed_identity_client_id:` options above.

## Authentication

The exporter chooses automatically:

- **Managed identity**, when the host exposes one. App Service, Container Apps, and Functions
  inject `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`. The exporter fetches an Entra token for
  `https://monitor.azure.com` (or the connection string's `AADAudience`), caches it until five
  minutes before expiry, and sends it as a bearer token. Grant the identity the **Monitoring
  Metrics Publisher** role on the Application Insights resource.
- **Connection string only**, everywhere else, such as a laptop. The instrumentation key in the
  connection string authenticates on its own. This requires local authentication to be enabled on
  the Application Insights resource (it is by default).

To choose without a code change, set `APPLICATIONINSIGHTS_AUTH`:

| Value | Auth |
|---|---|
| unset | Managed identity when the host has one, otherwise the connection string |
| `connection_string` | The connection string's instrumentation key, even on a host with an identity. Useful until the identity is granted Monitoring Metrics Publisher. |
| `managed_identity` | The host's managed identity; fails at boot when the host has none |

Any other value raises `AzureMonitorOpenTelemetry::Error` at boot. The `managed_identity:` option
overrides the variable.

## How spans map

| Span | Application Insights | Notes |
|---|---|---|
| `server`, `consumer` (web requests, job runs) | **Request** | Named by `http.route` when present. A 4xx or an error status counts as failed. |
| `client` with HTTP attributes | **Dependency**, type `HTTP` | Named `METHOD /path`, targeted by host. |
| `client` with `db.system` | **Dependency**, type `postgresql` / `mysql` / `redis` / `SQL` / … | `db.statement` becomes the dependency data. |
| `producer` (enqueues) | **Dependency**, type `Queue Message \| system` | |
| `internal` | **Dependency**, type `InProc` | |
| span event `exception` | **Exception** | Type, message, and stack trace, under the span. |
| other span events | **Trace** message | |

The trace ID becomes the operation ID and parent span IDs become parent IDs, so a request and
everything under it render as one transaction. The `service.name` resource attribute becomes the
cloud role. Links (for example a job run linked to the request that enqueued it) are kept in the
`_MS.links` property. Attributes outside the standard semantic-convention namespaces become
custom properties.

The exporter's own requests, the upload and the token fetch, run untraced, so exporting never
creates spans of its own.

## Delivery

Each batch is posted to `<IngestionEndpoint>/v2.1/track`. Failures are retried the way Microsoft's
exporters retry them:

- Status codes 401, 403, 408, 429, 500, 502, 503, and 504, network errors (timeouts, DNS, TLS,
  connection resets), and failures to get a managed identity token retry the batch, up to three
  attempts. `Retry-After` (seconds or an HTTP date) is honored; otherwise backoff is 1s, then 2s.
  Retries never run past the span processor's export timeout.
- A partial success (206) resends only the items marked retryable. Items ingestion sampled out
  aren't resent.
- 402 and 439 mean the resource's daily cap or quota is exhausted; the batch is dropped.
- Redirects (307, 308) are followed only over HTTPS and within the Azure Monitor ingestion domains,
  so a forged `Location` can't receive telemetry or the bearer token. The new host is kept for later
  exports.
- Anything else, such as 400 for an invalid key, is dropped.

Every failure is logged through `OpenTelemetry.logger`, with a hint for 401 and 403 auth problems.

The exporter never raises into your app. A span that can't be converted is dropped on its own and
the rest of the batch is still sent. Strings are coerced to valid UTF-8, so binary or mis-encoded
attribute values can't make a batch fail to serialize.

There's no on-disk buffering: spans that can't be delivered are dropped.

Constructing the exporter does raise `AzureMonitorOpenTelemetry::Error` for a missing or malformed
connection string, so a misconfiguration shows up at boot instead of as silently missing telemetry.

## Scope

Traces: requests, dependencies, exceptions, and span events. Exporting logs and OpenTelemetry
metrics, and Live Metrics, aren't implemented.

## Data you send

Spans carry whatever instrumentation records: URLs with query strings, SQL, and any headers you opt
into. `configure` obfuscates PostgreSQL and MySQL literals; obfuscate SQL you trace yourself
(`OpenTelemetry::Helpers::SqlProcessor.obfuscate_sql`), and keep sensitive values out of span
attributes.

## Development

```sh
bundle install
bundle exec rspec
```

## Credits

The span-to-telemetry mapping follows Microsoft's MIT-licensed
[azure-monitor-opentelemetry-exporter](https://github.com/Azure/azure-sdk-for-python/tree/main/sdk/monitor/azure-monitor-opentelemetry-exporter)
for Python.

## License

MIT
