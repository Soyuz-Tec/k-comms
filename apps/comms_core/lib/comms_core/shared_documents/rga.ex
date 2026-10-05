defmodule CommsCore.SharedDocuments.Rga do
  @moduledoc false
  # Server-owned bounded RGA. Parents never change; only admitted existing atoms
  # can be referenced. Sibling order is descending committed insertion order.
  @maximum_atoms 32_000
  @maximum_visible_atoms 16_000
  @maximum_content_bytes 65_536
  @maximum_insert_atoms 2_048
  @maximum_deleted_atoms 4_096

  def maximum_atoms, do: @maximum_atoms

  def apply(atoms, changes, operation_id, version)
      when is_list(atoms) and is_list(changes) and is_binary(operation_id) and is_integer(version) do
    with true <- length(changes) in 1..32,
         true <- length(atoms) <= @maximum_atoms,
         true <- Enum.all?(changes, &valid_change?/1),
         true <-
           Enum.sum(Enum.map(changes, &length(String.codepoints(&1["insert"])))) <=
             @maximum_insert_atoms,
         true <- Enum.sum(Enum.map(changes, &length(&1["delete_ids"]))) <= @maximum_deleted_atoms do
      index = Map.new(atoms, &{&1["id"], &1})

      result =
        Enum.reduce_while(changes, {:ok, index, [], [], 0}, fn change,
                                                               {:ok, current, inserted, deleted,
                                                                offset} ->
          after_id = change["after_id"]
          deletes = change["delete_ids"]

          if (is_nil(after_id) or Map.has_key?(current, after_id)) and
               Enum.all?(deletes, &Map.has_key?(current, &1)) do
            current =
              Enum.reduce(
                deletes,
                current,
                &Map.update!(&2, &1, fn atom -> Map.put(atom, "deleted", true) end)
              )

            {current, added, _anchor, next_offset} =
              Enum.reduce(
                String.codepoints(change["insert"]),
                {current, [], after_id, offset},
                fn text, {nodes, added, anchor, cursor} ->
                  id = operation_id <> ":" <> Integer.to_string(cursor)

                  atom = %{
                    "id" => id,
                    "after_id" => anchor,
                    "text" => text,
                    "deleted" => false,
                    "order" => version * @maximum_atoms + cursor
                  }

                  {Map.put(nodes, id, atom), [atom | added], id, cursor + 1}
                end
              )

            {:cont,
             {:ok, current, inserted ++ Enum.reverse(added), deleted ++ deletes, next_offset}}
          else
            {:halt, {:error, :unknown_document_atom}}
          end
        end)

      case result do
        {:ok, nodes, inserted, deleted, _} ->
          if map_size(nodes) > @maximum_atoms or
               map_size(nodes) != length(atoms) + length(inserted) do
            {:error, :document_capacity_exceeded}
          else
            ordered = order(Map.values(nodes))
            visible = Enum.reject(ordered, & &1["deleted"])
            content = Enum.map_join(visible, & &1["text"])

            if length(visible) <= @maximum_visible_atoms and
                 byte_size(content) <= @maximum_content_bytes do
              {:ok, ordered, content, inserted, Enum.uniq(deleted)}
            else
              {:error, :document_capacity_exceeded}
            end
          end

        error ->
          error
      end
    else
      _ -> {:error, :invalid_document_operation}
    end
  end

  def apply(_, _, _, _), do: {:error, :invalid_document_operation}

  def order(atoms) do
    children =
      Enum.group_by(atoms, & &1["after_id"])
      |> Map.new(fn {parent, siblings} ->
        {parent, Enum.sort_by(siblings, & &1["order"], :desc)}
      end)

    traverse(Map.get(children, nil, []), children, []) |> Enum.reverse()
  end

  defp traverse([], _children, result), do: result

  defp traverse([atom | rest], children, result) do
    traverse(Map.get(children, atom["id"], []) ++ rest, children, [atom | result])
  end

  defp valid_change?(%{"after_id" => after_id, "delete_ids" => ids, "insert" => text} = change) do
    Map.keys(change) |> Enum.sort() == ["after_id", "delete_ids", "insert"] and
      (is_nil(after_id) or valid_atom_id?(after_id)) and is_list(ids) and
      length(ids) <= @maximum_deleted_atoms and length(Enum.uniq(ids)) == length(ids) and
      Enum.all?(ids, &valid_atom_id?/1) and is_binary(text) and String.valid?(text) and
      byte_size(text) <= 8_192 and not String.contains?(text, "\0") and
      (text != "" or ids != [])
  end

  defp valid_change?(_), do: false

  defp valid_atom_id?(value) when is_binary(value),
    do: byte_size(value) in 38..45 and Regex.match?(~r/^[0-9a-f-]{36}:[0-9]{1,8}$/, value)

  defp valid_atom_id?(_), do: false
end
