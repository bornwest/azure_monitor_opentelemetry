module AzureMonitorOpenTelemetry
  # Posts envelopes to the Application Insights track endpoint, handling responses the way
  # Microsoft's exporters do:
  #   200          sent
  #   206          partly accepted: resend only the items marked retryable
  #   307 / 308    follow to the same ingestion domain, and keep using the new host
  #   401 403 408 429 500 502 503 504, network errors, token failures   retry
  #   402 439      daily quota exceeded: drop
  #   anything else (400 invalid key or data, 404 wrong endpoint, …)    drop
  class Transport
    RETRYABLE = [401, 403, 408, 429, 500, 502, 503, 504].freeze
    QUOTA = [402, 439].freeze
    REDIRECT = [307, 308].freeze
    INGESTION_HOST_SUFFIXES = %w[.monitor.azure.com .services.visualstudio.com
                                 .applicationinsights.azure.com .monitor.azure.us
                                 .applicationinsights.azure.us .monitor.azure.cn
                                 .applicationinsights.azure.cn].freeze
    # Failures where the request may not have reached ingestion, or no answer came back.
    TRANSIENT_ERRORS = [Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::OpenSSLError,
                        Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error].freeze
    SAMPLED_OUT = "telemetry sampled out.".freeze
    MAX_ATTEMPTS = 3
    MAX_REDIRECTS = 10
    DEFAULT_TIMEOUT = 30

    # credential: anything with #token returning an Entra bearer token, or nil for
    # instrumentation-key auth. request_timeout caps each HTTP call, in seconds.
    def initialize(uri:, credential: nil, request_timeout: 10)
      @uri = uri
      @credential = credential
      @request_timeout = request_timeout
      @mutex = Mutex.new
    end

    # => OpenTelemetry::SDK::Trace::Export::SUCCESS, FAILURE, or TIMEOUT
    def deliver(envelopes, timeout: nil)
      deadline = monotonic_now + (timeout || DEFAULT_TIMEOUT)
      attempts = 0
      redirects = 0

      loop do
        return give_up(envelopes, "the export timeout passed", export::TIMEOUT) if remaining(deadline) <= 0

        attempts += 1
        response = post(envelopes, deadline)
        delay = nil

        if response.is_a?(Exception)
          warn("send failed (#{response.class}: #{response.message}); retrying")
        elsif response.code == "200"
          return export::SUCCESS
        elsif response.code == "206"
          envelopes = retryable_items(envelopes, response)
          return export::SUCCESS if envelopes.empty?
        elsif REDIRECT.include?(response.code.to_i)
          return export::FAILURE unless follow_redirect(response, redirects += 1)

          attempts -= 1
          next
        elsif RETRYABLE.include?(response.code.to_i)
          warn(retry_reason(response.code.to_i))
          delay = retry_after(response)
        else
          return drop(envelopes, response)
        end

        return give_up(envelopes, "#{MAX_ATTEMPTS} attempts failed", export::FAILURE) if attempts >= MAX_ATTEMPTS

        wait = delay || (2**(attempts - 1))
        return give_up(envelopes, "retrying would pass the export timeout", export::TIMEOUT) if wait >= remaining(deadline)

        sleep(wait)
      end
    end

    private

    # Returns the Net::HTTPResponse, or the exception for a retryable failure (including failing
    # to get a token), so the caller can decide whether to try again.
    def post(envelopes, deadline)
      uri = @mutex.synchronize { @uri }
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@credential.token}" if @credential
      request.body = JSON.generate(envelopes)
      seconds = [remaining(deadline), @request_timeout].min
      # The upload must not be traced itself, or every export would produce more spans to export.
      OpenTelemetry::Common::Utilities.untraced do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: seconds, read_timeout: seconds, write_timeout: seconds) do |http|
          http.request(request)
        end
      end
    rescue *TRANSIENT_ERRORS, Error => e
      e
    end

    # 206 body: {"itemsReceived":3,"itemsAccepted":1,"errors":[{"index":2,"statusCode":429,"message":"…"}]}
    def retryable_items(envelopes, response)
      errors = JSON.parse(response.body.to_s).fetch("errors")
      errors.filter_map do |error|
        envelope = envelopes[error["index"].to_i] if error["index"].is_a?(Integer)
        if error["message"].to_s.downcase == SAMPLED_OUT
          nil
        elsif envelope && RETRYABLE.include?(error["statusCode"])
          envelope
        else
          warn("item dropped (#{error["statusCode"]}): #{error["message"]}")
          nil
        end
      end
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      warn("partial success with an unreadable response; #{envelopes.size} items may be lost")
      []
    end

    # Follows only within the current ingestion domain, so a forged Location header can't receive
    # telemetry or the bearer token. The new host is kept for later exports.
    def follow_redirect(response, redirects)
      return give_up(nil, "too many redirects; check the connection string", false) if redirects > MAX_REDIRECTS

      location = URI(response["location"].to_s)
      unless location.scheme == "https" && location.host && same_domain?(@uri.host, location.host)
        return give_up(nil, "refusing redirect to #{location.host.inspect}", false)
      end

      @mutex.synchronize { @uri = URI("https://#{location.host}#{":#{location.port}" unless location.port == 443}#{@uri.path}") }
      true
    rescue URI::InvalidURIError
      give_up(nil, "redirect had an invalid Location", false)
    end

    def same_domain?(current, target)
      current = current.to_s.downcase.chomp(".")
      target = target.to_s.downcase.chomp(".")
      current == target ||
        INGESTION_HOST_SUFFIXES.any? { |suffix| current.end_with?(suffix) && target.end_with?(suffix) }
    end

    def drop(envelopes, response)
      code = response.code.to_i
      reason = QUOTA.include?(code) ? "the Application Insights daily cap or quota is exhausted" : "ingestion rejected them"
      give_up(envelopes, "#{reason} (#{response.code}: #{response.body.to_s[0, 300]})", export::FAILURE)
    end

    def give_up(envelopes, reason, result)
      OpenTelemetry.logger.error("AzureMonitorOpenTelemetry: #{"dropped #{envelopes.size} items: " if envelopes}#{reason}")
      result
    end

    def retry_reason(code)
      case code
      when 401 then "ingestion returned 401: the Application Insights resource may require Entra ID auth; retrying"
      when 403 then "ingestion returned 403: the identity may lack Monitoring Metrics Publisher on the resource; retrying"
      else "ingestion returned #{code}; retrying"
      end
    end

    # Retry-After in seconds or as an HTTP date.
    def retry_after(response)
      value = response["retry-after"].to_s.strip
      return if value.empty?
      return value.to_i if value.match?(/\A\d+\z/) && value.to_i.positive?

      seconds = (Time.httpdate(value) - Time.now).ceil
      seconds if seconds.positive?
    rescue ArgumentError
      nil
    end

    def warn(message) = OpenTelemetry.logger.warn("AzureMonitorOpenTelemetry: #{message}")
    def remaining(deadline) = deadline - monotonic_now
    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def export = OpenTelemetry::SDK::Trace::Export
  end
end
