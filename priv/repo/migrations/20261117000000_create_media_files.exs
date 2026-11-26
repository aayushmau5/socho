defmodule Socho.Repo.Migrations.CreateMediaFiles do
  use Ecto.Migration

  def change do
    create table(:media_files) do
      add :ref, :string, null: false
      add :original_name, :string, null: false
      add :file_size, :integer
      add :content_type, :string

      timestamps(updated_at: false)
    end

    create index(:media_files, [:inserted_at])
    create index(:media_files, [:original_name])
  end
end
