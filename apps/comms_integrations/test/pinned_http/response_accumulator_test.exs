defmodule CommsIntegrations.PinnedHttp.ResponseAccumulatorTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.PinnedHttp.ResponseAccumulator

  @moduletag :unit
  @moduletag :external_delivery

  @limits %{body_bytes: 8, header_bytes: 32, header_count: 2}

  test "accumulates matching response entries" do
    request_ref = make_ref()

    assert {:done, accumulator} =
             ResponseAccumulator.consume(
               [
                 {:status, request_ref, 200},
                 {:headers, request_ref, [{"x-id", "1"}]},
                 {:data, request_ref, "ok"},
                 {:done, request_ref}
               ],
               request_ref,
               ResponseAccumulator.new(),
               @limits
             )

    assert ResponseAccumulator.response(accumulator) == %{
             status: 200,
             headers: [{"x-id", "1"}],
             body: "ok"
           }
  end

  test "rejects a body that exceeds the configured byte limit" do
    request_ref = make_ref()

    assert {:error, :outbound_response_too_large} =
             ResponseAccumulator.consume(
               [{:data, request_ref, "123456789"}],
               request_ref,
               ResponseAccumulator.new(),
               @limits
             )
  end

  test "rejects completion without a status" do
    request_ref = make_ref()

    assert {:error, :outbound_invalid_response} =
             ResponseAccumulator.consume(
               [{:done, request_ref}],
               request_ref,
               ResponseAccumulator.new(),
               @limits
             )
  end

  test "rejects malformed headers" do
    request_ref = make_ref()

    assert {:error, :outbound_invalid_response} =
             ResponseAccumulator.consume(
               [{:headers, request_ref, [{"x-id", :invalid}]}],
               request_ref,
               ResponseAccumulator.new(),
               @limits
             )
  end

  test "ignores entries for another request" do
    request_ref = make_ref()
    other_ref = make_ref()

    assert {:cont, accumulator} =
             ResponseAccumulator.consume(
               [{:status, other_ref, 204}, {:data, other_ref, "ignored"}],
               request_ref,
               ResponseAccumulator.new(),
               @limits
             )

    assert accumulator == ResponseAccumulator.new()
  end

  test "preserves the raw transport error for the transport adapter" do
    request_ref = make_ref()
    reason = %Mint.TransportError{reason: :timeout}

    assert {:transport_error, ^reason} =
             ResponseAccumulator.consume(
               [{:error, request_ref, reason}],
               request_ref,
               ResponseAccumulator.new(),
               @limits
             )
  end
end
