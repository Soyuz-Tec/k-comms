defmodule CommsWeb.FallbackControllerTest do
  use CommsWeb.ConnCase, async: true

  alias CommsWeb.FallbackController

  test "filters conversion verification secrets from request logging" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "verification_code" => "guest-conversion-code",
        "conversion_verification_code" => "creator-only-code",
        "password" => "guest-password",
        "token" => "guest-link-token",
        "display_name" => "Visible Guest"
      })

    assert filtered["verification_code"] == "[FILTERED]"
    assert filtered["conversion_verification_code"] == "[FILTERED]"
    assert filtered["password"] == "[FILTERED]"
    assert filtered["token"] == "[FILTERED]"
    assert filtered["display_name"] == "Visible Guest"
  end

  test "maps expired call authority to a non-sensitive forbidden response" do
    response =
      build_conn()
      |> FallbackController.call({:error, :call_authorization_expired})
      |> json_response(403)

    assert response == %{
             "error" => %{
               "code" => "call_authorization_expired",
               "detail" => "Call access is no longer authorized"
             }
           }
  end

  test "maps guest account conversion policy failures without disclosing the authorized email" do
    disabled =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_not_enabled})
      |> json_response(403)

    forbidden =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_forbidden})
      |> json_response(403)

    mismatch =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_email_mismatch})
      |> json_response(403)

    verification_failed =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_verification_failed})
      |> json_response(403)

    invalid_email =
      build_conn()
      |> FallbackController.call({:error, :invalid_guest_conversion_email})
      |> json_response(422)

    invalid_use_count =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_requires_single_use})
      |> json_response(422)

    assert disabled["error"]["code"] == "guest_account_conversion_not_enabled"

    assert forbidden == %{
             "error" => %{
               "code" => "guest_account_conversion_forbidden",
               "detail" => "Account creation is not permitted for this guest link"
             }
           }

    assert mismatch["error"]["code"] == "guest_account_conversion_email_mismatch"

    assert verification_failed == %{
             "error" => %{
               "code" => "guest_account_conversion_verification_failed",
               "detail" => "Account conversion verification failed"
             }
           }

    assert invalid_email == %{
             "error" => %{
               "code" => "invalid_guest_conversion_email",
               "detail" => "The account conversion email is invalid"
             }
           }

    assert invalid_use_count["error"]["code"] == "guest_account_conversion_requires_single_use"

    refute inspect([
             disabled,
             forbidden,
             mismatch,
             verification_failed,
             invalid_email,
             invalid_use_count
           ]) =~ "@"
  end
end
