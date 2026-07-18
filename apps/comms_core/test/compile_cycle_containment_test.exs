defmodule CommsCore.CompileCycleContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Accounts.{PlatformRoleGrant, User}
  alias CommsCore.Administration.CallPolicy
  alias CommsCore.AudioCalls.{Access, AuthorizationPolicy}
  alias CommsCore.Conversations.{CallConversation, CallMembership}

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookEndpoint,
    WebhookSubscription
  }

  test "Calls authorization composes Ecto-free owner projections without a generic adapter" do
    assert Code.ensure_loaded?(AuthorizationPolicy)
    assert function_exported?(AuthorizationPolicy, :authorize, 3)
    assert function_exported?(AuthorizationPolicy, :lock_access, 3)
    assert function_exported?(AuthorizationPolicy, :authorize_access, 3)

    for projection <- [Access, CallPolicy, CallConversation, CallMembership] do
      assert Code.ensure_loaded?(projection)
      refute function_exported?(projection, :__schema__, 1)
    end
  end

  test "webhook associations retain only the query directions used by the owner" do
    assert WebhookSubscription.__schema__(:type, :endpoint_id) == :binary_id
    refute :endpoint in WebhookSubscription.__schema__(:associations)

    assert :subscriptions in WebhookEndpoint.__schema__(:associations)
    refute :deliveries in WebhookEndpoint.__schema__(:associations)

    assert :endpoint in WebhookDelivery.__schema__(:associations)
  end

  test "platform grants retain scalar ownership while user-side preload remains available" do
    assert PlatformRoleGrant.__schema__(:type, :user_id) == :binary_id
    refute :user in PlatformRoleGrant.__schema__(:associations)
    assert :platform_role_grant in User.__schema__(:associations)
  end
end
