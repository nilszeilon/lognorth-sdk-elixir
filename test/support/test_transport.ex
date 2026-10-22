defmodule Lognorth.TestTransport do
  @moduledoc false

  def post(endpoint, key, body, timeout) do
    send(:lognorth_test, {:posted, %{endpoint: endpoint, key: key, body: body, timeout: timeout}})
    Application.get_env(:lognorth, :test_response, {:ok, 200, nil})
  end
end
