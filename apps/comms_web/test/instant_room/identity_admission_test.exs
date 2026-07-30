defmodule CommsWeb.InstantRoom.IdentityAdmissionTest do
  use CommsWeb.InstantRoomCase

  import Ecto.Query

  alias CommsCore.Conversations.{EphemeralRoom, GuestAdmission, Membership}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "a fresh human join for an already-active membership emits no added event", %{
    account: account
  } do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    created =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{title: "Existing member room"})
      )
      |> json_response(201)

    conversation_topic = "conversation:#{created["conversation"]["id"]}"
    assert :ok = CommsWeb.Endpoint.subscribe(conversation_topic)

    joined =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{token: created["token"]})
      )
      |> json_response(201)

    assert joined["replayed"] == false

    refute_receive %Phoenix.Socket.Broadcast{
                     topic: ^conversation_topic,
                     event: "membership.changed.v1"
                   },
                   50
  end

  test "a cross-tenant human falls back to a public-workspace guest without selecting a tenant",
       %{
         account: public_account
       } do
    other_tenant_account = Fixtures.account_fixture()

    token =
      other_tenant_account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    response =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/instant-rooms", Jason.encode!(%{title: "Cross-tenant room"}))
      |> json_response(201)

    assert response["room"]["owner_kind"] == "guest"
    assert response["tenant"]["id"] == public_account.tenant.id
    assert response["user"]["id"] != other_tenant_account.user.id
    assert response["user"]["display_name"] == other_tenant_account.user.display_name
    assert is_binary(response["access_token"])
  end

  test "a same-tenant conversation-only human reuses its registered identity for creation and join",
       %{
         account: public_account
       } do
    original_guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Original guest",
          device: %{name: "Verified browser", platform: "web"}
        })
      )
      |> json_response(201)

    converted =
      build_conn()
      |> put_req_header("authorization", "Bearer #{original_guest["access_token"]}")
      |> post("/api/v1/guest/account", %{
        email: "scoped-#{System.unique_integer([:positive])}@example.test",
        password: "correct-conversation-scoped-password-123",
        display_name: "Verified converted user",
        device: %{name: "Verified browser", platform: "web"}
      })
      |> json_response(200)

    converted_token = converted["authentication"]["access_token"]
    converted_user_id = converted["authentication"]["user"]["id"]

    created =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{converted_token}")
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Untrusted override",
          title: "Scoped-user room",
          device: %{name: "Untrusted device", platform: "unknown"}
        })
      )
      |> json_response(201)

    assert created["room"]["owner_kind"] == "registered"
    assert created["room"]["owner_user_id"] == converted_user_id
    refute Map.has_key?(created, "tenant")
    refute Map.has_key?(created, "user")
    refute Map.has_key?(created, "device")
    refute Map.has_key?(created, "access_token")
    refute Map.has_key?(created, "refresh_token")
    refute Map.has_key?(created, "admission")

    target =
      %{build_conn() | remote_ip: {198, 51, 100, 177}}
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Other guest host",
          device: %{name: "Other browser", platform: "web"}
        })
      )
      |> json_response(201)

    target_conversation_id = target["conversation"]["id"]
    join_key = idempotency_key()

    joined =
      build_conn()
      |> public_json_headers(join_key)
      |> put_req_header("authorization", "Bearer #{converted_token}")
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: target["token"],
          display_name: "Untrusted join override",
          device: %{name: "Untrusted join device", platform: "unknown"}
        })
      )
      |> json_response(201)

    assert joined["room"]["id"] == target["room"]["id"]
    refute Map.has_key?(joined, "user")
    refute Map.has_key?(joined, "device")
    refute Map.has_key?(joined, "access_token")
    refute Map.has_key?(joined, "refresh_token")
    refute Map.has_key?(joined, "admission")

    assert %Membership{role: :member, left_at: nil} =
             Repo.get_by!(Membership,
               conversation_id: target_conversation_id,
               user_id: converted_user_id
             )

    refute Repo.exists?(
             from(admission in GuestAdmission,
               where:
                 admission.conversation_id == ^target_conversation_id and
                   admission.guest_user_id == ^converted_user_id
             )
           )

    replayed =
      build_conn()
      |> public_json_headers(join_key)
      |> put_req_header("authorization", "Bearer #{converted_token}")
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{token: target["token"]})
      )
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["room"]["id"] == target["room"]["id"]

    assert Repo.aggregate(
             from(membership in Membership,
               where:
                 membership.conversation_id == ^target_conversation_id and
                   membership.user_id == ^converted_user_id
             ),
             :count
           ) == 1

    assert Repo.get!(EphemeralRoom, created["room"]["id"]).tenant_id == public_account.tenant.id
  end
end
