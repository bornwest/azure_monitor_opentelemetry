require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::Converter do
  subject(:converter) { described_class.new("11111111-2222-3333-4444-555555555555") }

  def convert(span) = converter.convert(span)
  def data(envelope) = envelope.dig("data", "baseData")

  describe "a server span" do
    let(:attributes) do
      { "http.method" => "GET", "http.scheme" => "https", "http.host" => "atlas.example.com",
        "http.target" => "/agent/sessions/7?tab=1", "http.route" => "/agent/sessions/:id",
        "http.status_code" => 200, "http.user_agent" => "Mozilla/5.0", "tenant" => "acme" }
    end
    let(:span) { finished_span("GET /agent/sessions/:id", kind: :server, attributes:) }
    let(:envelope) { convert(span).first }

    it "becomes a request named by route, with the full URL and status" do
      expect(envelope).to include("name" => "Microsoft.ApplicationInsights.Request",
                                  "iKey" => "11111111-2222-3333-4444-555555555555")
      expect(envelope.dig("data", "baseType")).to eq("RequestData")
      expect(data(envelope)).to include(
        "ver" => 2, "id" => span.hex_span_id, "name" => "GET /agent/sessions/:id",
        "url" => "https://atlas.example.com/agent/sessions/7?tab=1", "responseCode" => "200", "success" => true,
      )
      expect(data(envelope)["duration"]).to match(/\A\d+\.\d{2}:\d{2}:\d{2}\.\d{3}\z/)
      expect(envelope["time"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)
    end

    it "carries trace, role, and user agent context tags, with no parent at the root" do
      expect(envelope["tags"]).to include(
        "ai.operation.id" => span.hex_trace_id, "ai.operation.name" => "GET /agent/sessions/:id",
        "ai.cloud.role" => "atlas-web", "ai.cloud.roleInstance" => "instance-1",
        "ai.application.ver" => "1.2.3", "ai.user.userAgent" => "Mozilla/5.0",
      )
      expect(envelope["tags"]).not_to have_key("ai.operation.parentId")
    end

    it "keeps only non-standard attributes as custom properties" do
      expect(data(envelope)["properties"]).to eq("tenant" => "acme")
    end

    it "fails on a 4xx and on an error status" do
      not_found = finished_span("GET /x", kind: :server, attributes: attributes.merge("http.status_code" => 404))
      errored = finished_span("GET /x", kind: :server, attributes: attributes.merge("http.status_code" => 500)) do |s|
        s.status = OpenTelemetry::Trace::Status.error("boom")
      end

      expect(data(convert(not_found).first)["success"]).to be(false)
      expect(data(convert(errored).first)["success"]).to be(false)
    end

    it "marks App Service keep-alive pings as synthetic" do
      ping = finished_span("GET /", kind: :server, attributes: attributes.merge("http.user_agent" => "AlwaysOn"))

      expect(convert(ping).first["tags"]).to include("ai.operation.syntheticSource" => "True")
    end
  end

  describe "client spans under a request" do
    def child(name, attributes, &block)
      spans = finished_spans do |tracer|
        tracer.in_span("GET /", kind: :server) do
          tracer.in_span(name, kind: :client, attributes:) { |span| block&.call(span) }
        end
      end
      [spans.first, spans.last]
    end

    it "maps a Postgres query to a database dependency" do
      query, request = child("SELECT atlas", "db.system" => "postgresql", "db.name" => "atlas_production",
                                             "db.statement" => "SELECT ? FROM users", "net.peer.name" => "pg.internal",
                                             "net.peer.port" => 5432)
      envelope = convert(query).first

      expect(envelope["name"]).to eq("Microsoft.ApplicationInsights.RemoteDependency")
      expect(data(envelope)).to include("type" => "postgresql", "target" => "pg.internal|atlas_production",
                                        "data" => "SELECT ? FROM users", "name" => "SELECT atlas", "success" => true)
      expect(envelope["tags"]).to include("ai.operation.id" => request.hex_trace_id,
                                          "ai.operation.parentId" => request.hex_span_id)
    end

    it "maps SQL Server queries to the SQL type, targeted by system when there is no server" do
      query, = child("lake.query", "db.system" => "mssql", "db.statement" => "SELECT TOP ? x FROM t")

      expect(data(convert(query).first)).to include("type" => "SQL", "target" => "mssql")
    end

    it "maps a Faraday call to an HTTP dependency named by path" do
      call, = child("POST", "http.method" => "POST", "http.url" => "https://models.example.com/v1/chat",
                            "net.peer.name" => "models.example.com", "http.status_code" => 429) do |span|
        span.status = OpenTelemetry::Trace::Status.error("rate limited")
      end

      expect(data(convert(call).first)).to include(
        "type" => "HTTP", "name" => "POST /v1/chat", "target" => "models.example.com",
        "data" => "https://models.example.com/v1/chat", "resultCode" => "429", "success" => false,
      )
    end

    it "rebuilds the URL of a Net::HTTP call and drops the default port from the target" do
      call, = child("HTTP GET", "http.method" => "GET", "http.scheme" => "https",
                                "net.peer.name" => "onelake.example.com", "net.peer.port" => 443,
                                "http.target" => "/ws/files/a.pdf", "http.status_code" => 200)

      expect(data(convert(call).first)).to include(
        "data" => "https://onelake.example.com:443/ws/files/a.pdf", "target" => "onelake.example.com",
        "name" => "GET /ws/files/a.pdf", "resultCode" => "200",
      )
    end
  end

  describe "job spans" do
    it "maps a job run to a request from its queue, linked to the enqueue" do
      spans = finished_spans do |tracer|
        enqueue = tracer.start_span("AdvanceSessionJob publish", kind: :producer,
                                                                 attributes: { "messaging.system" => "active_job",
                                                                               "messaging.destination" => "agent" })
        enqueue.finish
        link = OpenTelemetry::Trace::Link.new(enqueue.context)
        tracer.start_root_span("AdvanceSessionJob process", kind: :consumer, links: [link],
                                                            attributes: { "messaging.system" => "active_job",
                                                                          "messaging.destination" => "agent" }).finish
      end
      enqueue, run = spans
      request = convert(run).first
      producer = convert(enqueue).first

      expect(request["name"]).to eq("Microsoft.ApplicationInsights.Request")
      expect(data(request)).to include("name" => "AdvanceSessionJob process", "source" => "agent",
                                       "responseCode" => "0", "success" => true)
      expect(JSON.parse(data(request)["properties"]["_MS.links"]))
        .to eq([{ "operation_Id" => enqueue.hex_trace_id, "id" => enqueue.hex_span_id }])
      expect(data(producer)).to include("type" => "Queue Message | active_job", "target" => "agent")
    end
  end

  it "maps an internal span to an in-process dependency" do
    span = finished_span("render_template.action_view", kind: :internal)

    expect(data(convert(span).first)).to include("type" => "InProc", "name" => "render_template.action_view")
  end

  it "emits a recorded exception as its own envelope under the span" do
    span = finished_span("GET /", kind: :server) do |s|
      s.record_exception(ArgumentError.new("bad input"))
    end
    request, exception = convert(span)

    expect(request["name"]).to eq("Microsoft.ApplicationInsights.Request")
    expect(exception["name"]).to eq("Microsoft.ApplicationInsights.Exception")
    expect(exception["tags"]).to include("ai.operation.id" => span.hex_trace_id,
                                         "ai.operation.parentId" => span.hex_span_id)
    details = data(exception)["exceptions"].first
    expect(details).to include("typeName" => "ArgumentError", "message" => "bad input", "hasFullStack" => true)
  end

  it "formats duration as d.hh:mm:ss.fff" do
    span = finished_spans do |tracer|
      start = Time.at(1_700_000_000)
      tracer.start_span("slow", kind: :internal, start_timestamp: start)
            .finish(end_timestamp: start + 90_061.5)
    end.first

    expect(data(convert(span).first)["duration"]).to eq("1.01:01:01.500")
  end

  it "makes every string valid UTF-8 so the batch always serializes" do
    span = finished_span("GET /", kind: :server,
                                  attributes: { "raw" => "caf\xE9".b, "latin" => "café".encode("ISO-8859-1") })
    envelope = convert(span).first

    expect(data(envelope)["properties"]).to eq("raw" => "caf\uFFFD", "latin" => "café")
    expect { JSON.generate(envelope) }.not_to raise_error
  end

  it "survives missing or reversed timestamps" do
    span = finished_span("odd", kind: :internal).dup
    span.end_timestamp = span.start_timestamp - 1_000_000
    expect(data(convert(span).first)["duration"]).to eq("0.00:00:00.000")

    span.start_timestamp = nil
    span.end_timestamp = nil
    expect(convert(span).first["time"]).to match(/\A\d{4}-.*Z\z/)
  end

  it "passes Application Insights' sample rate through" do
    span = finished_span("GET /", kind: :server, attributes: { "_MS.sampleRate" => 25.0 })

    expect(convert(span).first["sampleRate"]).to eq(25.0)
    expect(convert(finished_span("GET /", kind: :server)).first).not_to have_key("sampleRate")
  end
end
