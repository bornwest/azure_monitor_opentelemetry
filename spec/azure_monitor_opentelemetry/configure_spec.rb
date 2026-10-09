require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry do
  let(:connection_string) do
    "InstrumentationKey=11111111-2222-3333-4444-555555555555;" \
      "IngestionEndpoint=https://centralus-0.in.applicationinsights.azure.com/"
  end

  before { allow(described_class).to receive(:at_exit) }
  after { OpenTelemetry.tracer_provider = OpenTelemetry::Internal::ProxyTracerProvider.new }

  it "does nothing without a connection string" do
    expect(described_class.configure(service_name: "app", connection_string: nil)).to be(false)
    expect(OpenTelemetry.tracer_provider).not_to be_a(OpenTelemetry::SDK::Trace::TracerProvider)
  end

  it "does nothing when the SDK is disabled" do
    stub_const("ENV", ENV.to_h.merge("OTEL_SDK_DISABLED" => "true"))

    expect(described_class.configure(service_name: "app", connection_string:, managed_identity: false)).to be(false)
  end

  it "exports traces to Application Insights under the service name, flushing at exit" do
    sent = stub_http(http_response(200))

    expect(described_class.configure(service_name: "my-app", connection_string:, managed_identity: false)).to be(true)
    provider = OpenTelemetry.tracer_provider
    provider.tracer("spec").in_span("GET /", kind: :server) { nil }
    provider.force_flush

    expect(provider.sampler).to be_a(AzureMonitorOpenTelemetry::EntryPointSampler)
    envelope = JSON.parse(sent.last[:request].body).first
    expect(envelope).to include("name" => "Microsoft.ApplicationInsights.Request")
    expect(envelope["tags"]).to include("ai.cloud.role" => "my-app")
    expect(described_class).to have_received(:at_exit)
  end

  it "skips untraced jobs" do
    sent = stub_http(http_response(200))
    described_class.configure(service_name: "app", connection_string:, managed_identity: false,
                              untraced_jobs: ["SweepJob"])
    tracer = OpenTelemetry.tracer_provider.tracer("spec")
    tracer.in_span("SweepJob process", kind: :consumer, attributes: { "code.namespace" => "SweepJob" }) { nil }
    tracer.in_span("InvoiceJob process", kind: :consumer, attributes: { "code.namespace" => "InvoiceJob" }) { nil }
    OpenTelemetry.tracer_provider.force_flush

    expect(JSON.parse(sent.last[:request].body).map { |e| e.dig("data", "baseData", "name") })
      .to eq(["InvoiceJob process"])
  end

  it "doesn't trace Always On pings or the given paths" do
    untraced = described_class.send(:untraced_request, %w[/up /assets/])

    expect(untraced.call("PATH_INFO" => "/", "HTTP_USER_AGENT" => "AlwaysOn")).to be(true)
    expect(untraced.call("PATH_INFO" => "/up")).to be(true)
    expect(untraced.call("PATH_INFO" => "/assets/app-1.css")).to be(true)
    expect(untraced.call("PATH_INFO" => "/upload")).to be(false)
    expect(untraced.call("PATH_INFO" => "/orders", "HTTP_USER_AGENT" => "Mozilla/5.0")).to be(false)
  end

  it "merges instrumentation options over the defaults" do
    configurator = nil
    stub_http
    described_class.configure(service_name: "app", connection_string:, managed_identity: false,
                              instrumentation: { "OpenTelemetry::Instrumentation::PG" => { peer_service: "db" } }) do |c|
      configurator = c
    end

    expect(configurator.instance_variable_get(:@instrumentation_config_map))
      .to include("OpenTelemetry::Instrumentation::PG" => { db_statement: :obfuscate, peer_service: "db" })
  end
end
