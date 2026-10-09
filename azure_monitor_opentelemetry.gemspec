require_relative "lib/azure_monitor_opentelemetry/version"

Gem::Specification.new do |spec|
  spec.name        = "azure_monitor_opentelemetry"
  spec.version     = AzureMonitorOpenTelemetry::VERSION
  spec.authors     = ["Rishabh Gupta"]
  spec.email       = ["rishabh@bornwest.com"]

  spec.summary     = "Azure Monitor (Application Insights) APM for Ruby, built on OpenTelemetry."
  spec.description = "One call traces Rails requests, jobs, SQL, and outbound HTTP and sends them to " \
                     "Application Insights as requests, dependencies, and exceptions, authenticating " \
                     "with a managed identity or a connection string. No collector or sidecar needed."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "opentelemetry-sdk", "~> 1.13"
  # Each instrumentation installs only when its library is loaded.
  spec.add_dependency "opentelemetry-instrumentation-faraday", "~> 0.33"
  spec.add_dependency "opentelemetry-instrumentation-mysql2", "~> 0.34"
  spec.add_dependency "opentelemetry-instrumentation-net_http", "~> 0.29"
  spec.add_dependency "opentelemetry-instrumentation-pg", "~> 0.37"
  spec.add_dependency "opentelemetry-instrumentation-rack", "~> 0.31"
  spec.add_dependency "opentelemetry-instrumentation-rails", "~> 0.42"

  spec.add_development_dependency "rspec", "~> 3.13"
end
