require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::Transport do
  subject(:transport) { described_class.new(uri: uri) }

  let(:uri) { URI("https://centralus-0.in.applicationinsights.azure.com/v2.1/track") }
  let(:envelopes) { [{ "n" => 0 }, { "n" => 1 }, { "n" => 2 }] }
  let(:export) { OpenTelemetry::SDK::Trace::Export }

  before { allow(transport).to receive(:sleep) }

  def bodies(sent) = sent.map { |s| JSON.parse(s[:request].body) }

  it "posts the batch as JSON, outside any trace" do
    sent = stub_http(http_response(200, '{"itemsReceived":3,"itemsAccepted":3,"errors":[]}'))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    request = sent.first[:request]
    expect(request.path).to eq("/v2.1/track")
    expect(request["Content-Type"]).to eq("application/json")
    expect(request["Authorization"]).to be_nil
    expect(bodies(sent)).to eq([envelopes])
    expect(sent.first[:untraced]).to be(true)
  end

  it "sends a bearer token when it has a credential" do
    credential = Struct.new(:token).new("tok")
    sent = stub_http(http_response(200))

    described_class.new(uri:, credential:).deliver(envelopes)
    expect(sent.first[:request]["Authorization"]).to eq("Bearer tok")
  end

  it "resends only the items a partial success marks retryable" do
    partial = { "itemsReceived" => 3, "itemsAccepted" => 1,
                "errors" => [{ "index" => 1, "statusCode" => 429, "message" => "throttled" },
                             { "index" => 2, "statusCode" => 400, "message" => "invalid" }] }
    sent = stub_http(http_response(206, JSON.generate(partial)), http_response(200))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(bodies(sent).last).to eq([{ "n" => 1 }])
  end

  it "retries a retryable status, honoring Retry-After" do
    sent = stub_http(http_response(429, "", "Retry-After" => "2"), http_response(200))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(sent.size).to eq(2)
    expect(transport).to have_received(:sleep).with(2)
  end

  it "retries network failures with backoff" do
    sent = stub_http(Net::OpenTimeout.new, http_response(503), http_response(200))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(sent.size).to eq(3)
    expect(transport).to have_received(:sleep).with(1).ordered
    expect(transport).to have_received(:sleep).with(2).ordered
  end

  it "gives up after three attempts" do
    sent = stub_http(http_response(500), http_response(500), http_response(500), http_response(200))

    expect(transport.deliver(envelopes)).to eq(export::FAILURE)
    expect(sent.size).to eq(3)
  end

  it "drops a batch the service rejects outright" do
    sent = stub_http(http_response(400, "Invalid instrumentation key"))

    expect(transport.deliver(envelopes)).to eq(export::FAILURE)
    expect(sent.size).to eq(1)
  end

  it "follows a redirect to another Azure Monitor host" do
    sent = stub_http(
      http_response(308, "", "Location" => "https://eastus-1.in.applicationinsights.azure.com/v2.1/track"),
      http_response(200),
    )

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(sent.last[:request].uri.host).to eq("eastus-1.in.applicationinsights.azure.com")
  end

  it "refuses a redirect off Azure Monitor" do
    sent = stub_http(http_response(308, "", "Location" => "https://evil.example.com/track"))

    expect(transport.deliver(envelopes)).to eq(export::FAILURE)
    expect(sent.size).to eq(1)
  end

  it "times out instead of retrying past the deadline" do
    stub_http(http_response(429, "", "Retry-After" => "60"))

    expect(transport.deliver(envelopes, timeout: 5)).to eq(export::TIMEOUT)
  end

  it "drops quietly when the daily cap or quota is exhausted" do
    sent = stub_http(http_response(439, "Daily quota exceeded"), http_response(200))

    expect(transport.deliver(envelopes)).to eq(export::FAILURE)
    expect(sent.size).to eq(1)
  end

  it "doesn't resend items ingestion sampled out" do
    partial = { "itemsReceived" => 3, "itemsAccepted" => 2,
                "errors" => [{ "index" => 0, "statusCode" => 500, "message" => "Telemetry sampled out." }] }
    sent = stub_http(http_response(206, JSON.generate(partial)))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(sent.size).to eq(1)
  end

  it "treats an unreadable partial success as done" do
    sent = stub_http(http_response(206, "not json"))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(sent.size).to eq(1)
  end

  it "retries when the credential can't produce a token" do
    credential = Object.new
    calls = 0
    credential.define_singleton_method(:token) do
      calls += 1
      calls == 1 ? raise(AzureMonitorOpenTelemetry::Error, "identity endpoint down") : "tok"
    end
    sent = stub_http(http_response(200))
    transport = described_class.new(uri:, credential:)
    allow(transport).to receive(:sleep)

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(sent.first[:request]["Authorization"]).to eq("Bearer tok")
  end

  it "honors Retry-After given as an HTTP date" do
    stub_http(http_response(503, "", "Retry-After" => (Time.now + 3).httpdate), http_response(200))

    expect(transport.deliver(envelopes)).to eq(export::SUCCESS)
    expect(transport).to have_received(:sleep).with(be_between(2, 4))
  end

  it "keeps using the host it was redirected to" do
    sent = stub_http(
      http_response(307, "", "Location" => "https://eastus-1.in.applicationinsights.azure.com/v2.1/track"),
      http_response(200), http_response(200),
    )

    transport.deliver(envelopes)
    transport.deliver(envelopes)
    expect(sent.map { |s| s[:request].uri.host }).to eq(%w[centralus-0.in.applicationinsights.azure.com
                                                            eastus-1.in.applicationinsights.azure.com
                                                            eastus-1.in.applicationinsights.azure.com])
  end

  it "refuses insecure, relative, or endless redirects" do
    ["http://eastus-1.in.applicationinsights.azure.com/v2.1/track", "/v2.1/track", "https://[bad"].each do |location|
      stub_http(http_response(308, "", "Location" => location))
      expect(transport.deliver(envelopes)).to eq(export::FAILURE)
    end

    loop_redirect = http_response(308, "", "Location" => uri.to_s)
    sent = stub_http(*Array.new(20) { loop_redirect })
    expect(transport.deliver(envelopes)).to eq(export::FAILURE)
    expect(sent.size).to eq(described_class::MAX_REDIRECTS + 1)
  end
end
