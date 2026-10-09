require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::RunningRequests do
  subject(:running) { described_class.new }

  let(:tracer) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap { |provider| provider.add_span_processor(running) }.tracer("spec")
  end

  it "holds a request only while it runs, and not its children" do
    tracer.in_span("GET /orders/:id", kind: :server) do |request|
      trace_id = request.context.hex_trace_id
      tracer.in_span("nested", kind: :server) do
        expect(running[trace_id].name).to eq("GET /orders/:id")
      end
      expect(running[trace_id].name).to eq("GET /orders/:id")
    end

    span = tracer.start_span("GET /", kind: :server)
    span.finish
    expect(running[span.context.hex_trace_id]).to be_nil
  end

  it "ignores spans that aren't requests" do
    span = tracer.start_span("SELECT", kind: :client)

    expect(running[span.context.hex_trace_id]).to be_nil
  end
end
