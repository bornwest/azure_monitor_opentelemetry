require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::ConnectionString do
  let(:key) { "11111111-2222-3333-4444-555555555555" }

  it "reads the key and regional ingestion endpoint" do
    config = described_class.new(
      "InstrumentationKey=#{key};IngestionEndpoint=https://centralus-0.in.applicationinsights.azure.com/;" \
      "LiveEndpoint=https://centralus.livediagnostics.monitor.azure.com/",
    )

    expect(config.instrumentation_key).to eq(key)
    expect(config.track_uri.to_s).to eq("https://centralus-0.in.applicationinsights.azure.com/v2.1/track")
    expect(config.audience).to eq("https://monitor.azure.com")
  end

  it "matches keys case-insensitively and falls back to the global endpoint" do
    config = described_class.new("instrumentationkey=#{key}")

    expect(config.track_uri.to_s).to eq("https://dc.services.visualstudio.com/v2.1/track")
  end

  it "takes the token audience from AADAudience" do
    config = described_class.new("InstrumentationKey=#{key};AADAudience=https://monitor.azure.us/.default")

    expect(config.audience).to eq("https://monitor.azure.us")
  end

  it "builds the endpoint from EndpointSuffix and Location" do
    config = described_class.new("InstrumentationKey=#{key};EndpointSuffix=applicationinsights.us;Location=usgovvirginia")

    expect(config.track_uri.to_s).to eq("https://usgovvirginia.dc.applicationinsights.us/v2.1/track")
  end

  it "falls back to APPINSIGHTS_INSTRUMENTATIONKEY" do
    config = described_class.new(nil, instrumentation_key_fallback: key)

    expect(config.instrumentation_key).to eq(key)
  end

  it "rejects a missing or malformed key" do
    [nil, "", "IngestionEndpoint=https://x", "InstrumentationKey=not-a-key"].each do |value|
      expect { described_class.new(value, instrumentation_key_fallback: nil) }
        .to raise_error(AzureMonitorOpenTelemetry::Error, /InstrumentationKey/)
    end
  end

  it "rejects malformed segments and unsupported authorization" do
    expect { described_class.new("InstrumentationKey=#{key};garbage") }
      .to raise_error(AzureMonitorOpenTelemetry::Error, /segment/)
    expect { described_class.new("InstrumentationKey=#{key};Authorization=aad") }
      .to raise_error(AzureMonitorOpenTelemetry::Error, /Authorization/)
    expect(described_class.new("Authorization=ikey;InstrumentationKey=#{key};").instrumentation_key).to eq(key)
  end
end
