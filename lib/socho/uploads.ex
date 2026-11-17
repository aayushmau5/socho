defmodule Socho.Uploads do
  @moduledoc """
  File upload abstraction with local and S3 backends.

  Files uploaded via the S3 backend are stored with the key `s3:<object-key>`
  in template vars. This key is resolved to a fresh presigned URL at both
  builder preview time and study serve time, so the stored vars never expire.
  """

  alias Socho.Studies.Templates

  @s3_region "ap-south-2"
  @presign_ttl 3600

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Upload a file. Returns `{:ok, ref}` where ref is `/uploads/name` or `s3:key`."
  def upload(tmp_path, client_name, _content_type \\ nil) do
    filename = "#{System.unique_integer([:positive])}_#{client_name}"

    case backend() do
      :local -> upload_local(tmp_path, filename)
      :s3 -> upload_s3(tmp_path, filename)
    end
  end

  @doc "Resolve a stored ref to a usable URL. Passes through plain URLs unchanged."
  def resolve_url("s3:" <> key), do: presign(key)
  def resolve_url(url), do: url

  @doc "Resolve all s3: refs in a template vars map."
  def resolve_vars(vars) when is_map(vars) do
    Map.new(vars, fn {k, v} -> {k, resolve_value(v)} end)
  end

  @doc """
  Walk a trial tree and rebuild any template_group children using fresh presigned
  URLs. Called by the study controller before generating JavaScript so participants
  always get valid image URLs.
  """
  def rebuild_template_groups(nodes) do
    Enum.map(nodes, fn
      %{node_type: "template_group"} = node ->
        case Templates.get(node.config["template_id"]) do
          nil ->
            node

          tpl ->
            vars = node.config["vars"] || %{}
            new_children =
              vars
              |> resolve_vars()
              |> tpl.build.()
              |> stamp_ids()

            %{node | children: new_children}
        end

      node ->
        %{node | children: rebuild_template_groups(node.children)}
    end)
  end

  # ── Local backend ────────────────────────────────────────────────────────────

  defp upload_local(tmp_path, filename) do
    dest = Path.join([:code.priv_dir(:socho), "static", "uploads", filename])
    File.cp!(tmp_path, dest)
    {:ok, "/uploads/#{filename}"}
  end

  # ── S3 backend ───────────────────────────────────────────────────────────────

  defp upload_s3(tmp_path, filename) do
    bucket = s3_bucket()
    key = "uploads/#{filename}"

    result =
      tmp_path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(bucket, key)
      |> ExAws.request()

    case result do
      {:ok, _} -> {:ok, "s3:#{key}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp presign(key) do
    config = ExAws.Config.new(:s3, region: @s3_region)
    {:ok, url} = ExAws.S3.presigned_url(config, :get, s3_bucket(), key, expires_in: @presign_ttl)
    url
  end

  defp s3_bucket, do: Application.fetch_env!(:socho, :s3_bucket)

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp resolve_value(list) when is_list(list), do: Enum.map(list, &resolve_url/1)
  defp resolve_value(str) when is_binary(str), do: resolve_url(str)
  defp resolve_value(other), do: other

  defp stamp_ids(nodes) do
    Enum.map(nodes, fn node ->
      node
      |> Map.put(:id, System.unique_integer([:positive]))
      |> Map.update(:children, [], &stamp_ids/1)
    end)
  end

  defp backend, do: Application.get_env(:socho, :uploads_backend, :local)
end
