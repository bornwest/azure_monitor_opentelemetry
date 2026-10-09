require "logger"
require "azure_monitor_opentelemetry"

OpenTelemetry.logger = Logger.new(File::NULL)

module SpanHelpers
  RESOURCE = OpenTelemetry::SDK::Resources::Resource.create(
    "service.name" => "my-app", "service.instance.id" => "instance-1", "service.version" => "1.2.3",
  )

  # Runs the block with a tracer and returns the spans it finished, as exporters receive them.
  def finished_spans
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: RESOURCE)
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    yield provider.tracer("spec")
    exporter.finished_spans
  end

  def finished_span(name, **options, &block)
    finished_spans { |tracer| tracer.in_span(name, **options) { |span| block&.call(span) } }.last
  end
end

module HttpHelpers
  def http_response(code, body = "", headers = {})
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s) { Net::HTTPResponse::CODE_CLASS_TO_OBJ[code.to_s[0]] }
    response = klass.new("1.1", code.to_s, "")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    headers.each { |key, value| response[key] = value }
    response
  end

  # Stubs Net::HTTP so each request returns (or raises) the next item; records what was sent.
  def stub_http(*replies)
    sent = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      sent << { request: request, untraced: OpenTelemetry::Common::Utilities.untraced? }
      reply = replies.shift
      reply.is_a?(Exception) ? raise(reply) : reply
    end
    allow(Net::HTTP).to receive(:start) { |*_args, **_opts, &block| block.call(http) }
    sent
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.include SpanHelpers
  config.include HttpHelpers
end
