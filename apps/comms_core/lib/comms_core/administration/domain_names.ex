defmodule CommsCore.Administration.DomainNames do
  @moduledoc false

  @spec canonical(term()) :: {:ok, binary()} | {:error, :invalid_workspace_domain}
  def canonical(input) when is_binary(input) and byte_size(input) <= 254 do
    domain = input |> String.downcase() |> String.replace_suffix(".", "")
    labels = String.split(domain, ".")

    if byte_size(domain) in 4..253 and length(labels) >= 2 and
         Enum.all?(
           labels,
           &(byte_size(&1) in 1..63 and Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, &1))
         ) and
         Regex.match?(~r/^[a-z]{2,63}$|^xn--[a-z0-9-]{2,59}$/, List.last(labels)) and
         List.last(labels) not in ~w(local localhost invalid test example internal onion) do
      {:ok, domain}
    else
      {:error, :invalid_workspace_domain}
    end
  end

  def canonical(_input), do: {:error, :invalid_workspace_domain}

  @spec exact_challenge_name?(term()) :: boolean()
  def exact_challenge_name?("_k-comms." <> suffix) do
    if String.ends_with?(suffix, ".") do
      domain = String.replace_suffix(suffix, ".", "")
      match?({:ok, ^domain}, canonical(domain))
    else
      false
    end
  end

  def exact_challenge_name?(_name), do: false
end
