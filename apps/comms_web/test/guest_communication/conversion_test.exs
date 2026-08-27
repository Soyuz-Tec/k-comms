defmodule CommsWeb.GuestCommunication.ConversionTest do
  use CommsWeb.ConnCase, async: false

  import CommsWeb.GuestCommunicationTestSupport

  alias CommsCore.Conversations.GuestLink
  alias CommsCore.Repo

  @moduletag :integration
  @moduletag :guest

  setup :setup_account

  test "optional conversion returns normal account access and preserves room membership", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id
    conversion_email = "converted-#{System.unique_integer([:positive])}@example.test"

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversion_email
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Convertible Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    refute inspect(guest) =~ link["conversion_verification_code"]

    converted =
      guest_conn(guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: conversion_email,
        verification_code: link["conversion_verification_code"],
        password: "correct-converted-guest-password-123",
        display_name: "Converted Member",
        device: %{name: "Converted browser", platform: "test"}
      })
      |> json_response(200)

    assert converted["authentication"]["user"]["id"] == guest["user"]["id"]
    assert converted["authentication"]["user"]["account_type"] == "human"
    refute Map.has_key?(converted["authentication"], "capabilities")
    assert converted["conversation"]["id"] == conversation_id

    normal_token = converted["authentication"]["access_token"]

    identity =
      member_conn(normal_token)
      |> get("/api/v1/me")
      |> json_response(200)

    assert identity["user"]["id"] == guest["user"]["id"]
    assert identity["user"]["account_type"] == "human"

    # Exact match on purpose: a converted guest must receive the full member
    # capability set and nothing extra, so a new capability has to be added
    # here deliberately rather than pass unnoticed.
    assert identity["capabilities"] == %{
             "allow_audio_calls" => true,
             "allow_immersive_mode" => true,
             "allow_public_channels" => true,
             "allow_video_calls" => true,
             "max_attachment_bytes" => 26_214_400,
             "message_edit_window_seconds" => 86_400
           }

    preserved =
      member_conn(normal_token)
      |> get("/api/v1/conversations/#{conversation_id}")
      |> json_response(200)

    assert preserved["data"]["id"] == conversation_id

    assert guest_conn(guest["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(401)

    member_conn(member_token)
    |> delete("/api/v1/conversations/#{conversation_id}/guest-links/#{link["data"]["id"]}")
    |> json_response(200)

    assert member_conn(normal_token)
           |> get("/api/v1/conversations/#{conversation_id}")
           |> response(200)
  end

  test "host link creation forwards the optional conversion email into domain policy", %{
    account: account,
    member_token: member_token
  } do
    conversion_email = "Invited.Guest+#{System.unique_integer([:positive])}@Example.Test"

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{account.conversation.id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversion_email
      })
      |> json_response(201)

    persisted = Repo.get!(GuestLink, link["data"]["id"])
    assert persisted.conversion_email == String.downcase(conversion_email)
    assert byte_size(link["conversion_verification_code"]) == 43

    assert {:ok, verification_secret} =
             Base.url_decode64(link["conversion_verification_code"], padding: false)

    assert persisted.conversion_verification_digest ==
             conversion_verification_digest(verification_secret, persisted)

    refute inspect(persisted) =~ link["conversion_verification_code"]
    refute link["data"]["share_url"] =~ link["conversion_verification_code"]

    listed =
      member_conn(member_token)
      |> get("/api/v1/conversations/#{account.conversation.id}/guest-links")
      |> json_response(200)

    refute inspect(listed) =~ link["conversion_verification_code"]

    preview =
      build_conn()
      |> post("/api/v1/guest-links/preview", %{token: link["token"]})
      |> json_response(200)

    refute inspect(preview) =~ link["conversion_verification_code"]

    invalid_use_count =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{account.conversation.id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 2,
        conversion_email: "single-use-only@example.test"
      })
      |> json_response(422)

    assert invalid_use_count["error"]["code"] ==
             "guest_account_conversion_requires_single_use"
  end

  test "account conversion requires the link's preauthorized email", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    communication_only =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    communication_guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: communication_only["token"],
        display_name: "Communication Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    disabled =
      guest_conn(communication_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: "not-authorized@example.test",
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    assert disabled["error"]["code"] == "guest_account_conversion_not_enabled"

    authorized_email = "authorized-#{System.unique_integer([:positive])}@example.test"

    account_link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: authorized_email
      })
      |> json_response(201)

    account_guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: account_link["token"],
        display_name: "Account Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    mismatch =
      guest_conn(account_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: "different@example.test",
        verification_code: account_link["conversion_verification_code"],
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    assert mismatch["error"]["code"] == "guest_account_conversion_email_mismatch"
    refute inspect(mismatch) =~ authorized_email

    missing_code =
      guest_conn(account_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: authorized_email,
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    wrong_code =
      guest_conn(account_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: authorized_email,
        verification_code: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    assert missing_code == wrong_code

    assert missing_code["error"]["code"] ==
             "guest_account_conversion_verification_failed"

    refute inspect([missing_code, wrong_code]) =~ authorized_email
  end

  @tag :slow
  test "guest account conversion is capped at five expensive attempts per minute", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id
    conversion_email = "rate-limited-#{System.unique_integer([:positive])}@example.test"

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversion_email
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Rate Limited Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    for _attempt <- 1..5 do
      response =
        guest_conn(guest["access_token"])
        |> post("/api/v1/guest/account", %{
          email: conversion_email,
          verification_code: link["conversion_verification_code"],
          password: "correct-converted-guest-password-123",
          display_name: "",
          device: %{name: "Converted browser", platform: "test"}
        })
        |> json_response(422)

      assert response["error"]["code"] == "invalid_guest_account"
    end

    response =
      guest_conn(guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: conversion_email,
        verification_code: link["conversion_verification_code"],
        password: "correct-converted-guest-password-123",
        display_name: "",
        device: %{name: "Converted browser", platform: "test"}
      })
      |> json_response(429)

    assert response["error"]["code"] == "rate_limited"
  end
end
