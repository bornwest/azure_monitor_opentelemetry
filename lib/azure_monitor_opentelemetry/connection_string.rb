module AzureMonitorOpenTelemetry
  # An Application Insights connection string:
  #   "InstrumentationKey=00000000-…;IngestionEndpoint=https://centralus-0.in.applicationinsights.azure.com/"
  # Sovereign clouds may give EndpointSuffix (and Location) instead of IngestionEndpoint.
  class ConnectionString
    DEFAULT_INGESTION_ENDPOINT = "https://dc.services.visualstudio.com".freeze
    DEFAULT_AUDIENCE = "https://monitor.azure.com".freeze
    KEY_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    attr_reader :instrumentation_key, :ingestion_endpoint, :audience, :application_id

    # The instrumentation key falls back to APPINSIGHTS_INSTRUMENTATIONKEY, as in Microsoft's SDKs.
    def initialize(value, instrumentation_key_fallback: ENV.fetch("APPINSIGHTS_INSTRUMENTATIONKEY", nil))
      pairs = parse(value.to_s)
      authorization = pairs["authorization"]
      raise Error, "unsupported connection string Authorization: #{authorization}" if authorization && authorization.casecmp("ikey") != 0

      @instrumentation_key = (pairs["instrumentationkey"] || instrumentation_key_fallback).to_s
      raise Error, "connection string has no valid InstrumentationKey" unless KEY_FORMAT.match?(@instrumentation_key)

      @ingestion_endpoint = (pairs["ingestionendpoint"] || suffix_endpoint(pairs) || DEFAULT_INGESTION_ENDPOINT).chomp("/")
      @audience = (pairs["aadaudience"] || DEFAULT_AUDIENCE).delete_suffix("/.default").chomp("/")
      @application_id = pairs["applicationid"]
    end

    def track_uri = URI("#{ingestion_endpoint}/v2.1/track")

    private

    def parse(value)
      value.split(";").each_with_object({}) do |pair, pairs|
        next if pair.strip.empty?

        key, val = pair.split("=", 2)
        raise Error, "invalid connection string segment: #{pair.strip[0, 40]}" if val.nil? || key.strip.empty?

        pairs[key.strip.downcase] = val.strip
      end
    end

    # EndpointSuffix=applicationinsights.us;Location=usgovvirginia => https://usgovvirginia.dc.applicationinsights.us
    def suffix_endpoint(pairs)
      suffix = pairs["endpointsuffix"]
      return if suffix.to_s.empty?

      location = pairs["location"]
      "https://#{"#{location}." unless location.to_s.empty?}dc.#{suffix}"
    end
  end
end
