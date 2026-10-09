module AzureMonitorOpenTelemetry
  # Entra bearer tokens from the managed identity endpoint that App Service, Container Apps, and
  # Functions inject as IDENTITY_ENDPOINT / IDENTITY_HEADER. Tokens are cached until five minutes
  # before they expire.
  class ManagedIdentity
    API_VERSION = "2019-08-01".freeze
    REFRESH_MARGIN = 300
    DEFAULT_LIFETIME = 3600
    TIMEOUT = 10

    AUTH_MODES = { "managed_identity" => true, "connection_string" => false }.freeze

    def self.available? = !ENV["IDENTITY_ENDPOINT"].to_s.empty? && !ENV["IDENTITY_HEADER"].to_s.empty?

    # APPLICATIONINSIGHTS_AUTH forces managed_identity or connection_string; unset, the host's
    # identity is used when it has one.
    def self.enabled?(mode = ENV.fetch("APPLICATIONINSIGHTS_AUTH", nil))
      return available? if mode.to_s.strip.empty?

      AUTH_MODES.fetch(mode.strip.downcase) do
        raise Error, "APPLICATIONINSIGHTS_AUTH must be managed_identity or connection_string, got #{mode.inspect}"
      end
    end

    # client_id selects a user-assigned identity; omit it for the system-assigned one.
    def initialize(resource:, client_id: nil, endpoint: ENV.fetch("IDENTITY_ENDPOINT", nil),
                   header: ENV.fetch("IDENTITY_HEADER", nil))
      if endpoint.to_s.empty? || header.to_s.empty?
        raise Error, "managed identity unavailable: IDENTITY_ENDPOINT and IDENTITY_HEADER are not set"
      end

      @resource = resource
      @client_id = client_id
      @endpoint = endpoint
      @header = header
      @mutex = Mutex.new
    end

    # Raises AzureMonitorOpenTelemetry::Error, or a network error, when no token can be obtained.
    def token
      @mutex.synchronize do
        return @token if @token && Time.now < @expires_at - REFRESH_MARGIN

        fetch
      end
    end

    private

    def fetch
      uri = URI(@endpoint)
      uri.query = URI.encode_www_form({ "resource" => @resource, "api-version" => API_VERSION,
                                        "client_id" => @client_id }.compact)
      request = Net::HTTP::Get.new(uri)
      request["X-IDENTITY-HEADER"] = @header
      response = OpenTelemetry::Common::Utilities.untraced do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.request(request) }
      end
      raise Error, "managed identity token request failed (#{response.code}): #{response.body.to_s[0, 300]}" unless response.code == "200"

      store(response.body)
    end

    def store(body)
      json = JSON.parse(body.to_s)
      token = json["access_token"].to_s
      raise Error, "managed identity response had no access_token" if token.empty?

      @expires_at = expiry(json)
      @token = token
    rescue JSON::ParserError
      raise Error, "managed identity response was not JSON"
    end

    # App Service returns expires_on (epoch seconds); other hosts may return only expires_in.
    def expiry(json)
      expires_on = Integer(json["expires_on"].to_s, exception: false)
      return Time.at(expires_on) if expires_on && Time.at(expires_on) > Time.now

      expires_in = Integer(json["expires_in"].to_s, exception: false)
      Time.now + (expires_in&.positive? ? expires_in : DEFAULT_LIFETIME)
    end
  end
end
