defmodule CommsCore.CompileCycleContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Accounts.{PlatformRoleGrant, User}

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookEndpoint,
    WebhookSubscription
  }

  test "authorization adapters implement the independent policy contract" do
    assert CommsCore.Authorization.Policy in CommsCore.Authorization.DenyAll.module_info(
             :attributes
           )[:behaviour]

    assert CommsCore.Authorization.Policy in CommsCore.Authorization.Database.module_info(
             :attributes
           )[:behaviour]

    refute CommsCore.Authorization in CommsCore.Authorization.DenyAll.module_info(:attributes)[
             :behaviour
           ]
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
