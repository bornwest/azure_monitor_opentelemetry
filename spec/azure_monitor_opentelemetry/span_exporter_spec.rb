require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::SpanExporter do
  let(:connection_string) do
    "InstrumentationKey=11111111-2222-3333-4444-555555555555;" \
      "IngestionEndpoint=https://centralus-0.in.applicationinsights.azure.com/"
  end
  let(:export) { OpenTelemetry::SDK::Trace::Export }
  let(:spans) do
    finished_spans do |tracer|
      tracer.in_span("GET /", kind: :server) { |span| span.record_exception(RuntimeError.new("boom")) }
    end
  end

  it "authenticates with the connection string when there is no managed identity" do
    sent = stub_http(http_response(200))
    exporter = described_class.new(connection_string:, managed_identity: false)

    expect(exporter.export(spans)).to eq(export::SUCCESS)
    post = sent.last[:request]
    expect(post["Authorization"]).to be_nil
    expect(JSON.parse(post.body).map { |e| e["name"] })
      .to eq(%w[Microsoft.ApplicationInsights.Request Microsoft.ApplicationInsights.Exception])
  end

  it "authenticates with a managed identity token for the resource's audience" do
    token = http_response(200, JSON.generate("access_token" => "mi-token",
                                             "expires_on" => (Time.now + 3600).to_i.to_s))
    sent = stub_http(token, http_response(200))
    stub_const("ENV", ENV.to_h.merge("IDENTITY_ENDPOINT" => "http://127.0.0.1:41000/msi/token",
                                      "IDENTITY_HEADER" => "secret-header"))
    exporter = described_class.new(connection_string:, managed_identity: true)

    expect(exporter.export(spans)).to eq(export::SUCCESS)
    expect(sent.first[:request].path).to include("resource=https%3A%2F%2Fmonitor.azure.com")
    expect(sent.last[:request]["Authorization"]).to eq("Bearer mi-token")
  end

  it "retries, then reports a failure instead of raising, when the token can't be fetched" do
    allow_any_instance_of(AzureMonitorOpenTelemetry::Transport).to receive(:sleep) # rubocop:disable RSpec/AnyInstance
    sent = stub_http(*Array.new(3) { http_response(500, "identity endpoint down") })
    stub_const("ENV", ENV.to_h.merge("IDENTITY_ENDPOINT" => "http://127.0.0.1:41000/msi/token",
                                      "IDENTITY_HEADER" => "secret-header"))
    exporter = described_class.new(connection_string:, managed_identity: true)

    expect(exporter.export(spans)).to eq(export::FAILURE)
    expect(sent.size).to eq(3)
  end

  it "drops a span it can't convert and still sends the rest" do
    sent = stub_http(http_response(200))
    exporter = described_class.new(connection_string:, managed_identity: false)
    broken = spans.first.dup
    broken.define_singleton_method(:status) { raise "corrupt span" }

    expect(exporter.export([broken, *spans])).to eq(export::SUCCESS)
    expect(JSON.parse(sent.last[:request].body).size).to eq(2)
  end

  it "lists every span in a trace under its request's name, across batches" do
    sent = stub_http(http_response(200), http_response(200))
    exporter = described_class.new(connection_string:, managed_identity: false)
    query = nil
    trace = finished_spans do |tracer|
      tracer.in_span("HTTP GET", kind: :server, attributes: { "http.method" => "GET", "http.route" => "/agent" }) do
        tracer.in_span("SELECT atlas", kind: :client, attributes: { "db.system" => "postgresql" }) { nil }
        query = tracer.in_span("late query", kind: :client) { |span| span }
      end
    end

    exporter.export(trace.reject { |span| span.name == "late query" })
    exporter.export([query.to_span_data])
    names = sent.flat_map { |s| JSON.parse(s[:request].body) }.to_h do |e|
      [e.dig("data", "baseData", "name"), e.dig("tags", "ai.operation.name")]
    end

    expect(names).to eq("SELECT atlas" => "GET /agent", "GET /agent" => "GET /agent", "late query" => "GET /agent")
  end

  it "refuses to export after shutdown" do
    exporter = described_class.new(connection_string:, managed_identity: false)
    exporter.shutdown

    expect(exporter.export(spans)).to eq(export::FAILURE)
  end

  it "requires a connection string" do
    expect { described_class.new(connection_string: nil, managed_identity: false) }
      .to raise_error(AzureMonitorOpenTelemetry::Error)
  end
end
