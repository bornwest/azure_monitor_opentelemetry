module AzureMonitorOpenTelemetry
  # Turns finished spans into Application Insights telemetry envelopes, following the mapping in
  # Microsoft's Azure Monitor exporters: server and consumer spans become requests, every other
  # span becomes a dependency, and span events become exceptions or trace messages.
  class Converter
    SCHEMA_VERSION = 2
    # Attributes the envelope already carries in typed fields; the rest become custom properties.
    STANDARD_PREFIXES = %w[http. db. message. messaging. rpc. enduser. net. peer. exception. thread.
                           fass. code.].freeze
    STANDARD_KEYS = %w[client.address client.port server.address server.port url.full url.path
                       url.query url.scheme url.template error.type network.local.address
                       network.local.port network.protocol.name network.peer.address
                       network.peer.port network.protocol.version network.transport
                       user_agent.original user_agent.synthetic.type session.id _MS.sampleRate
                       microsoft.custom_measurements].freeze
    SQL_SYSTEMS = %w[db2 ibm.db2 derby mariadb mssql microsoft.sql_server oracle oracle.db sqlite
                     other_sql hsqldb h2 h2database].freeze
    DB_DEFAULT_PORTS = { "postgresql" => 5432, "mysql" => 3306, "mariadb" => 3306, "mssql" => 1433,
                         "microsoft.sql_server" => 1433, "redis" => 6379, "cassandra" => 9042,
                         "oracle" => 1521, "db2" => 50_000 }.freeze
    MAX_LINKS = 100

    def initialize(instrumentation_key)
      @instrumentation_key = instrumentation_key
      @context_tags = {
        "ai.device.id" => Socket.gethostname,
        "ai.device.type" => "Other",
        "ai.internal.sdkVersion" => "rb#{RUBY_VERSION}:otel#{OpenTelemetry::SDK::VERSION}:ext#{VERSION}",
      }.freeze
    end

    # Every string is made valid UTF-8, so one span with binary or mis-encoded data (a raw SQL
    # literal, a header) can't make the whole batch fail to serialize.
    #
    # operation_name is the name of the request the span belongs to; Application Insights lists
    # dependencies and exceptions under it. A request span names its own operation.
    def convert(span, operation_name: nil)
      operation_name = request_name(span) if request?(span)
      utf8([span_envelope(span, operation_name), *event_envelopes(span, operation_name)])
    end

    def request?(span) = %i[server consumer].include?(span.kind)

    # "GET /agent/sessions/:id" for HTTP, otherwise the span name ("InvoiceJob process").
    def request_name(span)
      attrs = span.attributes || {}
      method = http_method(attrs)
      path = attrs["http.route"] || url_path(request_url(attrs)) if method
      (path ? "#{method} #{path}" : span.name).to_s[0, 1024]
    end

    private

    def span_envelope(span, operation_name)
      attrs = span.attributes || {}
      tags = operation_tags(span, attrs, operation_name)
      tags["ai.operation.parentId"] = span.hex_parent_span_id if parent?(span)
      request = request?(span)
      data = request ? request_data(span, attrs, tags) : dependency_data(span, attrs, tags)
      data["properties"] = custom_properties(attrs)
      data["properties"]["_MS.links"] = links_json(span.links) if span.links&.any?
      type = request ? "Request" : "RemoteDependency"
      envelope(type, "#{type}Data", span.start_timestamp, tags, data).merge(sample_rate(attrs))
    end

    # Set by samplers that follow Application Insights' convention, so it can scale counts.
    def sample_rate(attrs)
      rate = attrs["_MS.sampleRate"]
      rate.is_a?(Numeric) && rate.positive? && rate <= 100 ? { "sampleRate" => rate.to_f } : {}
    end

    def request_data(span, attrs, tags)
      data = { "ver" => SCHEMA_VERSION, "id" => span.hex_span_id, "name" => tags["ai.operation.name"],
               "duration" => duration(span), "responseCode" => "0", "success" => span.status.ok? }
      location_ip = attrs["client.address"] || attrs["http.client_ip"] || attrs["net.peer.ip"]
      tags["ai.location.ip"] = location_ip.to_s if location_ip

      if http_method(attrs)
        user_agent!(tags, attrs)
        url = request_url(attrs)
        data["url"] = url[0, 2048] unless url.empty?
        code = status_code(attrs)
        data["responseCode"] = code.to_s
        data["success"] = span.status.ok? && code != 0 && !(400..499).cover?(code)
      elsif attrs["messaging.system"] && (destination = attrs["messaging.destination"])
        peer = attrs["client.address"] || attrs["net.peer.name"] || attrs["net.peer.ip"]
        data["source"] = (peer ? "#{peer}/#{destination}" : destination.to_s)[0, 1024]
      end

      data["responseCode"] = data["responseCode"][0, 1024]
      data
    end

    def dependency_data(span, attrs, tags)
      data = { "ver" => SCHEMA_VERSION, "id" => span.hex_span_id, "name" => span.name,
               "resultCode" => "0", "duration" => duration(span), "success" => span.status.ok? }
      target = peer_target(attrs)

      case span.kind
      when :client
        target = client_dependency!(data, tags, attrs, target)
      when :producer
        data["type"] = ["Queue Message", attrs["messaging.system"]].compact.join(" | ")
        target = messaging_target(target, attrs)
      else
        data["type"] = "InProc"
      end

      data["name"] = data["name"].to_s[0, 1024]
      data["resultCode"] = data["resultCode"].to_s[0, 1024]
      data["data"] = data["data"].to_s[0, 8192] if data["data"]
      data["type"] = data["type"].to_s[0, 1024]
      data["target"] = target.to_s[0, 1024] unless target.to_s.empty?
      data
    end

    # Sets type/data/result code for a CLIENT span and returns its target.
    def client_dependency!(data, tags, attrs, target)
      if (method = http_method(attrs))
        data["type"] = "HTTP"
        user_agent!(tags, attrs)
        url = dependency_url(attrs)
        data["data"] = url unless url.empty?
        target, path = http_target_and_path(attrs, url)
        data["name"] = "#{method} #{path}"
        data["resultCode"] = status_code(attrs).to_s
      elsif (system = attrs["db.system.name"] || attrs["db.system"])
        data["type"] = db_type(system.to_s)
        statement = attrs["db.query.text"] || attrs["db.statement"] || attrs["db.operation.name"] ||
                    attrs["db.operation"]
        data["data"] = statement if statement
        target = db_target(target, system.to_s, attrs)
      elsif (system = attrs["messaging.system"])
        data["type"] = system.to_s
        target = messaging_target(target, attrs)
      elsif (system = attrs["rpc.system"])
        data["type"] = system.to_s
        target = system.to_s if target.empty?
      else
        data["type"] = "N/A"
      end
      target
    end

    def event_envelopes(span, operation_name)
      Array(span.events).map do |event|
        attrs = event.attributes || {}
        tags = operation_tags(span, attrs, operation_name)
        tags["ai.operation.parentId"] = span.hex_span_id
        properties = custom_properties(attrs)
        if event.name == "exception"
          envelope("Exception", "ExceptionData", event.timestamp, tags, exception_data(attrs, properties))
        else
          data = { "ver" => SCHEMA_VERSION, "message" => event.name.to_s[0, 32_768], "properties" => properties }
          envelope("Message", "MessageData", event.timestamp, tags, data)
        end
      end
    end

    def exception_data(attrs, properties)
      stack = attrs["exception.stacktrace"]
      details = { "typeName" => (attrs["exception.type"] || "Exception").to_s[0, 1024],
                  "message" => (attrs["exception.message"] || "Exception").to_s[0, 32_768],
                  "hasFullStack" => !stack.nil? }
      details["stack"] = stack.to_s[0, 32_768] if stack
      { "ver" => SCHEMA_VERSION, "exceptions" => [details], "properties" => properties }
    end

    def envelope(type, base_type, timestamp, tags, data)
      { "name" => "Microsoft.ApplicationInsights.#{type}", "time" => iso8601(timestamp),
        "iKey" => @instrumentation_key, "tags" => tags,
        "data" => { "baseType" => base_type, "baseData" => data } }
    end

    # Context tags shared by every envelope a span produces.
    def operation_tags(span, attrs, operation_name)
      tags = @context_tags.merge(resource_tags(span.resource))
      tags["ai.operation.id"] = span.hex_trace_id
      tags["ai.operation.name"] = operation_name if operation_name
      span_attrs = span.attributes || {}
      tags["ai.user.authUserId"] = span_attrs["enduser.id"].to_s if span_attrs["enduser.id"]
      tags["ai.user.id"] = span_attrs["enduser.pseudo.id"].to_s if span_attrs["enduser.pseudo.id"]
      session = attrs["session.id"] || span_attrs["session.id"]
      tags["ai.session.id"] = session if session.is_a?(String)
      tags["ai.operation.syntheticSource"] = "True" if synthetic?(span_attrs)
      tags
    end

    # ai.cloud.role is what Application Map and role filters key on.
    def resource_tags(resource)
      attrs = resource ? resource.attribute_enumerator.to_h : {}
      role = attrs["service.name"].to_s
      role = "#{attrs["service.namespace"]}.#{role}" if attrs["service.namespace"] && !role.empty?
      instance = (attrs["service.instance.id"] || Socket.gethostname).to_s
      tags = { "ai.cloud.role" => role, "ai.cloud.roleInstance" => instance, "ai.internal.nodeName" => instance }
      tags["ai.application.ver"] = attrs["service.version"].to_s if attrs["service.version"]
      tags
    end

    def custom_properties(attrs)
      attrs.each_with_object({}) do |(key, value), properties|
        next if value.nil? || key.empty? || key.length > 150 || standard?(key)

        properties[key] = (value.is_a?(Array) ? value.join(",") : value.to_s)[0, 8192]
      end
    end

    def standard?(key) = STANDARD_KEYS.include?(key) || STANDARD_PREFIXES.any? { |prefix| key.start_with?(prefix) }

    def links_json(links)
      JSON.generate(links.first(MAX_LINKS).map do |link|
        { "operation_Id" => link.span_context.hex_trace_id, "id" => link.span_context.hex_span_id }
      end)
    end

    def synthetic?(attrs)
      %w[bot test].include?(attrs["user_agent.synthetic.type"]) || user_agent(attrs).to_s.include?("AlwaysOn")
    end

    def user_agent!(tags, attrs)
      agent = user_agent(attrs)
      tags["ai.user.userAgent"] = agent.to_s if agent
    end

    def user_agent(attrs) = attrs["user_agent.original"] || attrs["http.user_agent"]
    def http_method(attrs) = attrs["http.request.method"] || attrs["http.method"]
    def status_code(attrs) = Integer(attrs["http.response.status_code"] || attrs["http.status_code"] || 0, exception: false) || 0
    def http_scheme(attrs) = attrs["url.scheme"] || attrs["http.scheme"]
    def parent?(span) = span.parent_span_id && span.parent_span_id != OpenTelemetry::Trace::INVALID_SPAN_ID

    def request_url(attrs)
      return (attrs["url.full"] || attrs["http.url"]).to_s if attrs["url.full"] || attrs["http.url"]

      scheme = http_scheme(attrs)
      target = if attrs["url.path"]
                 [attrs["url.path"], attrs["url.query"]].compact.join("?")
               else
                 attrs["http.target"].to_s
               end
      return "" unless scheme && !target.empty?

      host = if attrs["server.address"]
               [attrs["server.address"], attrs["server.port"]].compact.join(":")
             elsif attrs["http.host"]
               attrs["http.host"]
             elsif attrs["net.host.name"]
               [attrs["net.host.name"], attrs["net.host.port"]].compact.join(":")
             end
      host ? "#{scheme}://#{host}#{target}" : ""
    end

    def dependency_url(attrs)
      return (attrs["url.full"] || attrs["http.url"]).to_s if attrs["url.full"] || attrs["http.url"]

      scheme = http_scheme(attrs)
      target = attrs["http.target"]
      return "" unless scheme && target

      if attrs["http.host"]
        "#{scheme}://#{attrs["http.host"]}#{target}"
      elsif attrs["net.peer.port"] && (peer = attrs["net.peer.name"] || attrs["net.peer.ip"])
        "#{scheme}://#{peer}:#{attrs["net.peer.port"]}#{target}"
      else
        ""
      end
    end

    def http_target_and_path(attrs, url)
      parsed = parse_uri(url)
      path = parsed&.path.to_s.empty? ? "/" : parsed.path
      default_port = http_default_port(attrs)
      target = if attrs["server.address"]
                 with_port(attrs["server.address"], attrs["server.port"], default_port)
               elsif attrs["peer.service"]
                 attrs["peer.service"].to_s
               elsif attrs["http.host"]
                 host = parse_uri("//#{attrs["http.host"]}")
                 host && host.port == default_port ? host.host : attrs["http.host"].to_s
               elsif parsed&.host
                 # URI reports the scheme's port even when the URL omits it.
                 with_port(parsed.host, parsed.port, parsed.default_port)
               end
      target = peer_target(attrs) if target.to_s.empty?
      [target, path]
    end

    def peer_target(attrs)
      return attrs["peer.service"].to_s if attrs["peer.service"]

      host = attrs["net.peer.name"] || attrs["net.peer.ip"]
      return host.to_s unless host && attrs["net.peer.port"]

      port = attrs["net.peer.port"]
      system = (attrs["db.system.name"] || attrs["db.system"]).to_s
      [http_default_port(attrs), DB_DEFAULT_PORTS[system]].include?(port) ? host.to_s : "#{host}:#{port}"
    end

    # "server:port|database"; the port is dropped when it is the system's default.
    def db_target(target, system, attrs)
      if target.empty? && attrs["server.address"]
        target = with_port(attrs["server.address"], attrs["server.port"], DB_DEFAULT_PORTS[system])
      end
      name = attrs["db.namespace"] || attrs["db.name"]
      return target.empty? ? name.to_s : "#{target}|#{name}" if name

      target.empty? ? system : target
    end

    def messaging_target(target, attrs)
      return target unless target.to_s.empty?

      (attrs["messaging.destination"] || attrs["messaging.system"]).to_s
    end

    def db_type(system)
      return system if %w[postgresql mysql mongodb redis].include?(system)

      SQL_SYSTEMS.include?(system) ? "SQL" : system
    end

    def http_default_port(attrs)
      { "http" => 80, "https" => 443 }[http_scheme(attrs).to_s]
    end

    def with_port(host, port, default_port)
      port.nil? || port == default_port ? host.to_s : "#{host}:#{port}"
    end

    def url_path(url)
      parsed = parse_uri(url)
      return unless parsed

      parsed.path.to_s.empty? ? "/" : parsed.path
    end

    def parse_uri(url)
      return if url.to_s.empty?

      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    # "d.hh:mm:ss.fff", rounded to the millisecond.
    def duration(span)
      nanos = (span.end_timestamp || span.start_timestamp).to_i - span.start_timestamp.to_i
      millis = ([nanos, 0].max + 500_000) / 1_000_000
      seconds, millis = millis.divmod(1000)
      minutes, seconds = seconds.divmod(60)
      hours, minutes = minutes.divmod(60)
      days, hours = hours.divmod(24)
      format("%<d>d.%<h>02d:%<m>02d:%<s>02d.%<ms>03d", d: days, h: hours, m: minutes, s: seconds, ms: millis)
    end

    def iso8601(nanoseconds)
      nanoseconds ||= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      Time.at(nanoseconds / 1_000_000_000, nanoseconds % 1_000_000_000, :nsec).utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
    end

    def utf8(value)
      case value
      when Hash then value.to_h { |key, val| [utf8(key), utf8(val)] }
      when Array then value.map { |item| utf8(item) }
      when String then utf8_string(value)
      else value
      end
    end

    # Binary and invalid bytes become U+FFFD; other encodings are transcoded.
    def utf8_string(string)
      return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?
      if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(string.encoding)
        return string.dup.force_encoding(Encoding::UTF_8).scrub
      end

      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
  end
end
