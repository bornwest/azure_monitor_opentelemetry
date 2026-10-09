require "json"
require "net/http"
require "openssl"
require "socket"
require "time"
require "uri"
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/faraday"
require "opentelemetry/instrumentation/mysql2"
require "opentelemetry/instrumentation/net/http"
require "opentelemetry/instrumentation/pg"
require "opentelemetry/instrumentation/rack"
require "opentelemetry/instrumentation/rails"

require_relative "azure_monitor_opentelemetry/version"
require_relative "azure_monitor_opentelemetry/connection_string"
require_relative "azure_monitor_opentelemetry/managed_identity"
require_relative "azure_monitor_opentelemetry/converter"
require_relative "azure_monitor_opentelemetry/transport"
require_relative "azure_monitor_opentelemetry/span_exporter"
require_relative "azure_monitor_opentelemetry/entry_point_sampler"
require_relative "azure_monitor_opentelemetry/running_requests"

# Azure Monitor (Application Insights) APM on OpenTelemetry. In a Rails initializer:
#
#   AzureMonitorOpenTelemetry.configure(service_name: "my-app")
module AzureMonitorOpenTelemetry
  class Error < StandardError; end

  # Rails' health check.
  DEFAULT_UNTRACED_PATHS = %w[/up].freeze

  # Instruments every supported library the app loads and exports to Application Insights.
  # Returns false, configuring nothing, when there's no connection string or the SDK is disabled.
  #
  # untraced_paths: exact paths, or prefixes when they end in "/" ("/assets/").
  # untraced_jobs: job class names whose runs aren't traced, such as a chatty recurring job.
  # instrumentation: per-instrumentation options merged over the defaults, as use_all takes them.
  # The block receives the OpenTelemetry SDK configurator, for anything else.
  def self.configure(service_name:, connection_string: ENV.fetch("APPLICATIONINSIGHTS_CONNECTION_STRING", nil),
                     managed_identity: ManagedIdentity.enabled?, managed_identity_client_id: nil,
                     sampling_ratio: Float(ENV.fetch("OTEL_TRACES_SAMPLER_ARG", "1")),
                     untraced_paths: DEFAULT_UNTRACED_PATHS, untraced_jobs: [], instrumentation: {})
    return false if connection_string.to_s.empty?

    running_requests = RunningRequests.new
    exporter = SpanExporter.new(connection_string:, managed_identity:, managed_identity_client_id:, running_requests:)
    sampler = EntryPointSampler.new(sampling_ratio, untraced_jobs:)
    options = instrumentation_defaults(untraced_paths).merge(instrumentation) { |_, default, custom| default.merge(custom) }

    OpenTelemetry::SDK.configure do |c|
      c.service_name = service_name
      c.use_all(options)
      c.add_span_processor(running_requests)
      c.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))
      yield c if block_given?
    end
    provider = OpenTelemetry.tracer_provider
    # Still the API's no-op provider when OTEL_SDK_DISABLED is set or the SDK logged a config error.
    return false unless provider.is_a?(OpenTelemetry::SDK::Trace::TracerProvider)

    provider.sampler = sampler
    # The batch processor holds a few seconds of spans; flush them when the process stops.
    at_exit { provider.shutdown }
    true
  end

  def self.instrumentation_defaults(untraced_paths)
    {
      "OpenTelemetry::Instrumentation::Rack" => { untraced_requests: untraced_request(untraced_paths) },
      "OpenTelemetry::Instrumentation::ActiveJob" => { span_naming: :job_class },
      # SQL literals can hold personal or financial data; keep them out of telemetry.
      "OpenTelemetry::Instrumentation::PG" => { db_statement: :obfuscate },
      "OpenTelemetry::Instrumentation::Mysql2" => { db_statement: :obfuscate },
    }
  end

  # App Service's Always On pings, plus the given paths.
  def self.untraced_request(paths)
    exact, prefixes = paths.partition { |path| !path.end_with?("/") }
    lambda do |env|
      path = env["PATH_INFO"].to_s
      env["HTTP_USER_AGENT"].to_s.include?("AlwaysOn") || exact.include?(path) ||
        prefixes.any? { |prefix| path.start_with?(prefix) }
    end
  end
  private_class_method :instrumentation_defaults, :untraced_request
end
