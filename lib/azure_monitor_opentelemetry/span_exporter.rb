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
    MAX_OPERATIONS = 10_000

    def initialize(connection_string: ENV.fetch("APPLICATIONINSIGHTS_CONNECTION_STRING", nil),
                   managed_identity: ManagedIdentity.available?, managed_identity_client_id: nil)
      config = ConnectionString.new(connection_string)
      credential = (ManagedIdentity.new(resource: config.audience, client_id: managed_identity_client_id) if managed_identity)
      @converter = Converter.new(config.instrumentation_key)
      @transport = Transport.new(uri: config.track_uri, credential:)
      @operations = {}
      @mutex = Mutex.new
      @stopped = false
    end

    def export(span_data, timeout: nil)
      return result::FAILURE if @stopped

      remember_operations(span_data)
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

    # Children finish before their request, so they're usually in the same batch; names are kept
    # per trace (the outermost request wins) for spans that finish after it.
    def remember_operations(span_data)
      requests = span_data.select { |span| @converter.request?(span) }.sort_by { |span| -span.start_timestamp.to_i }
      names = requests.to_h { |span| [span.hex_trace_id, @converter.request_name(span)] }
      @mutex.synchronize do
        @operations.update(names)
        @operations.shift while @operations.size > MAX_OPERATIONS
      end
    end

    # A span that can't be converted is dropped on its own rather than failing the batch.
    def convert(span)
      @converter.convert(span, operation_name: @mutex.synchronize { @operations[span.hex_trace_id] })
    rescue StandardError => e
      OpenTelemetry.handle_error(exception: e, message: "AzureMonitorOpenTelemetry: dropped span #{span.name.inspect}")
      []
    end

    def result = OpenTelemetry::SDK::Trace::Export
  end
end
