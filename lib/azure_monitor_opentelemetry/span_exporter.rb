module AzureMonitorOpenTelemetry
  # OpenTelemetry span exporter for Application Insights. Register it behind a batch processor:
  #
  #   OpenTelemetry::SDK.configure do |c|
  #     c.add_span_processor(
  #       OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(AzureMonitorOpenTelemetry::SpanExporter.new),
  #     )
  #   end
  #
  # Authenticates with the host's managed identity when one is available (an Entra token for the
  # connection string's audience), otherwise with the connection string's instrumentation key.
  class SpanExporter
    def initialize(connection_string: ENV.fetch("APPLICATIONINSIGHTS_CONNECTION_STRING", nil),
                   managed_identity: ManagedIdentity.available?, managed_identity_client_id: nil)
      config = ConnectionString.new(connection_string)
      credential = (ManagedIdentity.new(resource: config.audience, client_id: managed_identity_client_id) if managed_identity)
      @converter = Converter.new(config.instrumentation_key)
      @transport = Transport.new(uri: config.track_uri, credential:)
      @stopped = false
    end

    def export(span_data, timeout: nil)
      return result::FAILURE if @stopped

      envelopes = span_data.flat_map { |span| convert(span) }
      return result::SUCCESS if envelopes.empty?

      @transport.deliver(envelopes, timeout:)
    rescue StandardError => e
      OpenTelemetry.handle_error(exception: e, message: "AzureMonitorOpenTelemetry: export failed")
      result::FAILURE
    end

    # Nothing is buffered here; the span processor owns batching.
    def force_flush(timeout: nil) = result::SUCCESS

    def shutdown(timeout: nil)
      @stopped = true
      result::SUCCESS
    end

    private

    # A span that can't be converted is dropped on its own rather than failing the batch.
    def convert(span)
      @converter.convert(span)
    rescue StandardError => e
      OpenTelemetry.handle_error(exception: e, message: "AzureMonitorOpenTelemetry: dropped span #{span.name.inspect}")
      []
    end

    def result = OpenTelemetry::SDK::Trace::Export
  end
end
