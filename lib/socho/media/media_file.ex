defmodule Socho.Media.MediaFile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "media_files" do
    field :ref, :string
    field :original_name, :string
    field :file_size, :integer
    field :content_type, :string

    timestamps(updated_at: false)
  end

  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [:ref, :original_name, :file_size, :content_type])
    |> validate_required([:ref, :original_name])
  end
end
