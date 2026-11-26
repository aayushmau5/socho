defmodule Socho.Media do
  import Ecto.Query

  alias Socho.Repo
  alias Socho.Media.MediaFile

  @list_limit 60

  def list_files(search \\ "") do
    from(f in MediaFile, order_by: [desc: f.inserted_at], limit: @list_limit)
    |> filter_by_name(search)
    |> Repo.all()
  end

  def record_upload(attrs) do
    %MediaFile{}
    |> MediaFile.changeset(attrs)
    |> Repo.insert()
  end

  defp filter_by_name(query, ""), do: query

  defp filter_by_name(query, search) do
    term = "%#{search}%"
    where(query, [f], ilike(f.original_name, ^term))
  end
end
