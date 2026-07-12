defmodule CommsIntegrations.ObjectStorage.Memory do
  @behaviour CommsIntegrations.ObjectStorage

  @impl true
  def presign_upload(attachment) do
    {:ok,
     %{
       method: "PUT",
       url: url(attachment.object_key),
       headers: %{"content-type" => attachment.content_type},
       expires_in: 900
     }}
  end

  @impl true
  def presign_download(attachment) do
    {:ok, %{method: "GET", url: url(attachment.object_key), headers: %{}, expires_in: 900}}
  end

  @impl true
  def verify_upload(_attachment), do: :ok

  defp url(object_key) do
    encoded = object_key |> String.split("/") |> Enum.map_join("/", &URI.encode/1)
    "https://object-storage.test/#{encoded}"
  end
end
