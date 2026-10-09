module AzureMonitorOpenTelemetry
  # Span processor that holds each request span (server or consumer, without a local parent)
  # while it runs. A long request's children can be exported before it finishes, as with a job
  # making hundreds of queries; the exporter reads the request's name from here for them.
  class RunningRequests
    KINDS = %i[server consumer].freeze
    MAX_REQUESTS = 10_000

    def initialize
      @spans = {}
      @mutex = Mutex.new
    end

    def on_start(span, parent_context)
      return unless KINDS.include?(span.kind) && local_root?(parent_context)

      @mutex.synchronize do
        @spans[span.context.hex_trace_id] ||= span
        @spans.shift while @spans.size > MAX_REQUESTS
      end
    end

    def on_finish(span)
      trace_id = span.context.hex_trace_id
      @mutex.synchronize { @spans.delete(trace_id) if @spans[trace_id].equal?(span) }
    end

    # => a SpanData snapshot of the trace's running request, or nil
    def [](hex_trace_id) = @mutex.synchronize { @spans[hex_trace_id] }&.to_span_data

    def force_flush(timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS
    def shutdown(timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS

    private

    def local_root?(parent_context)
      parent = OpenTelemetry::Trace.current_span(parent_context).context
      !parent.valid? || parent.remote?
    end
  end
end
