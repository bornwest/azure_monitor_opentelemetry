module AzureMonitorOpenTelemetry
  # Starts a trace only at an inbound request (server span) or a job run (consumer span), keeping
  # `ratio` of them; spans with a parent follow the parent's decision. Any other span without a
  # parent is dropped, otherwise a job queue's polling queries would each become a trace.
  #
  # Sampled spans carry _MS.sampleRate when ratio < 1, so Application Insights scales its counts.
  class EntryPointSampler
    KINDS = %i[server consumer].freeze

    def initialize(ratio)
      raise ArgumentError, "sampling ratio must be between 0 and 1, got #{ratio}" unless (0.0..1.0).cover?(ratio)

      @ratio = ratio.to_f
      @root = OpenTelemetry::SDK::Trace::Samplers.trace_id_ratio_based(@ratio)
      @attributes = @ratio < 1 ? { "_MS.sampleRate" => @ratio * 100 }.freeze : {}
    end

    def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
      parent = OpenTelemetry::Trace.current_span(parent_context).context
      sampled = if parent.valid?
                  parent.trace_flags.sampled?
                elsif KINDS.include?(kind)
                  @root.should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:).sampled?
                end
      result(sampled, parent.tracestate)
    end

    def description = "EntryPointSampler{#{@ratio}}"

    private

    def result(sampled, tracestate)
      samplers = OpenTelemetry::SDK::Trace::Samplers
      return samplers::Result.new(decision: samplers::Decision::DROP, tracestate:) unless sampled

      samplers::Result.new(decision: samplers::Decision::RECORD_AND_SAMPLE, attributes: @attributes, tracestate:)
    end
  end
end
