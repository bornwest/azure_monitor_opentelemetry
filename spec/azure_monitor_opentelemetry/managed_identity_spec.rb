require "spec_helper"

RSpec.describe AzureMonitorOpenTelemetry::ManagedIdentity do
  subject(:identity) do
    described_class.new(resource: "https://monitor.azure.com", endpoint: "http://127.0.0.1:41000/msi/token",
                        header: "secret-header")
  end

  def token_response(token, expires_on)
    http_response(200, JSON.generate("access_token" => token, "expires_on" => expires_on.to_i.to_s))
  end

  it "is available only when both App Service identity variables are set" do
    stub_const("ENV", { "IDENTITY_ENDPOINT" => "http://127.0.0.1:41000/msi/token" })
    expect(described_class.available?).to be(false)
    expect { described_class.new(resource: "https://monitor.azure.com") }
      .to raise_error(AzureMonitorOpenTelemetry::Error, /IDENTITY_HEADER/)

    stub_const("ENV", { "IDENTITY_ENDPOINT" => "http://127.0.0.1:41000/msi/token", "IDENTITY_HEADER" => "h" })
    expect(described_class.available?).to be(true)
  end

  it "requests a token for the resource, outside any trace" do
    sent = stub_http(token_response("tok-1", Time.now + 3600))

    expect(identity.token).to eq("tok-1")
    request = sent.first[:request]
    expect(request.path).to include("resource=https%3A%2F%2Fmonitor.azure.com", "api-version=2019-08-01")
    expect(request["X-IDENTITY-HEADER"]).to eq("secret-header")
    expect(sent.first[:untraced]).to be(true)
  end

  it "selects a user-assigned identity by client id" do
    sent = stub_http(token_response("tok-1", Time.now + 3600))
    described_class.new(resource: "https://monitor.azure.com", client_id: "abc", endpoint: "http://127.0.0.1/t",
                        header: "h").token

    expect(sent.first[:request].path).to include("client_id=abc")
  end

  it "reuses a token until five minutes before it expires" do
    sent = stub_http(token_response("tok-1", Time.now + 3600), token_response("tok-2", Time.now + 3600))

    expect([identity.token, identity.token]).to eq(%w[tok-1 tok-1])
    expect(sent.size).to eq(1)
  end

  it "refreshes a token that is about to expire" do
    sent = stub_http(token_response("tok-1", Time.now + 60), token_response("tok-2", Time.now + 3600))

    expect([identity.token, identity.token]).to eq(%w[tok-1 tok-2])
    expect(sent.size).to eq(2)
  end

  it "raises when the endpoint refuses" do
    stub_http(http_response(400, "bad resource"))

    expect { identity.token }.to raise_error(AzureMonitorOpenTelemetry::Error, /400/)
  end

  it "raises on a response without a usable token" do
    stub_http(http_response(200, "<html>proxy</html>"), http_response(200, '{"token_type":"Bearer"}'))

    expect { identity.token }.to raise_error(AzureMonitorOpenTelemetry::Error, /not JSON/)
    expect { identity.token }.to raise_error(AzureMonitorOpenTelemetry::Error, /access_token/)
  end

  it "falls back to expires_in when expires_on is missing" do
    sent = stub_http(http_response(200, JSON.generate("access_token" => "tok-1", "expires_in" => "3600")))

    expect([identity.token, identity.token]).to eq(%w[tok-1 tok-1])
    expect(sent.size).to eq(1)
  end
end
