require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::EntryPointSampler do
  def spans_with(sampler, &)
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(sampler:)
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    yield provider.tracer("spec")
    exporter.finished_spans
  end

  it "starts traces only at requests and job runs, keeping their children" do
    spans = spans_with(described_class.new(1.0)) do |tracer|
      tracer.in_span("poll", kind: :client) { nil }
      tracer.in_span("GET /", kind: :server) { tracer.in_span("SELECT", kind: :client) { nil } }
      tracer.in_span("MyJob process", kind: :consumer) { nil }
    end

    expect(spans.map(&:name)).to eq(["SELECT", "GET /", "MyJob process"])
    expect(spans.first.attributes).not_to have_key("_MS.sampleRate")
  end

  it "drops a request's children along with it" do
    spans = spans_with(described_class.new(0.0)) do |tracer|
      tracer.in_span("GET /", kind: :server) { tracer.in_span("SELECT", kind: :client) { nil } }
    end

    expect(spans).to be_empty
  end

  it "marks sampled spans with the rate Application Insights scales counts by" do
    spans = spans_with(described_class.new(0.5)) do |tracer|
      40.times { tracer.in_span("GET /", kind: :server) { tracer.in_span("SELECT", kind: :client) { nil } } }
    end

    expect(spans.size).to be_between(2, 78)
    expect(spans.map { |span| span.attributes["_MS.sampleRate"] }.uniq).to eq([50.0])
  end

  it "doesn't trace runs of untraced jobs, by job class" do
    sampler = described_class.new(1.0, untraced_jobs: ["SweepJob"])
    spans = spans_with(sampler) do |tracer|
      [%w[SweepJob sweep], %w[InvoiceJob invoice]].each do |job, query|
        tracer.in_span("#{job} process", kind: :consumer, attributes: { "code.namespace" => job }) do
          tracer.in_span(query, kind: :client) { nil }
        end
      end
    end

    expect(spans.map(&:name)).to eq(["invoice", "InvoiceJob process"])
  end

  it "rejects a ratio outside 0..1" do
    expect { described_class.new(5) }.to raise_error(ArgumentError, /between 0 and 1/)
  end
end
