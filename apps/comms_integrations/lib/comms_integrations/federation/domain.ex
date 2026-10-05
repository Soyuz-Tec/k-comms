defmodule CommsIntegrations.Federation.Domain do
  @moduledoc "Canonical Matrix server names: approved DNS names, never URL/IP/email aliases."
  @spec validate(term()) :: {:ok, binary()} | {:error, :invalid_federation_domain}
  def validate(value) when is_binary(value) and byte_size(value) in 4..253 do
    labels = String.split(value, ".")

    valid =
      value == String.downcase(value) and String.trim(value) == value and
        length(labels) >= 2 and not String.ends_with?(value, ".") and
        Enum.all?(
          labels,
          &(byte_size(&1) in 1..63 and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, &1))
        ) and
        not Regex.match?(~r/\A\d+(?:\.\d+){3}\z/, value) and
        not Enum.any?(
          ["localhost", "local", "internal", "invalid", "test"],
          &String.ends_with?(value, "." <> &1)
        )

    if valid, do: {:ok, value}, else: {:error, :invalid_federation_domain}
  end

  def validate(_), do: {:error, :invalid_federation_domain}
  @spec matrix_user(term(), binary()) :: {:ok, binary()} | {:error, :untrusted_matrix_principal}
  def matrix_user(value, domain) when is_binary(value) and byte_size(value) <= 255 do
    with {:ok, ^domain} <- validate(domain),
         [_, local, ^domain] <- Regex.run(~r/\A@([a-z0-9._=\/-]+):([^:]+)\z/, value),
         true <- byte_size(local) in 1..128 do
      {:ok, value}
    else
      _ -> {:error, :untrusted_matrix_principal}
    end
  end

  def matrix_user(_, _), do: {:error, :untrusted_matrix_principal}
end
