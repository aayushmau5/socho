# File Uploads

## Overview

File uploads are handled by `Socho.Uploads` (`lib/socho/uploads.ex`), which abstracts over two storage backends: **local** (default) and **S3**.

The active backend is selected at runtime via application config:

```elixir
Application.get_env(:socho, :uploads_backend, :local)  # :local | :s3
```

**Local backend** copies the uploaded file into `priv/static/uploads/` and returns a path like `/uploads/<filename>`. This path is served directly by `Plug.Static` and requires no credentials.

**S3 backend** streams the file to an S3 bucket using multipart upload (`ExAws.S3.Upload.stream_file/1`) and returns a storage key in the form `s3:uploads/<filename>`. This key is **not** a usable URL — it must be resolved to a presigned URL before it reaches the browser (see [URL Resolution](#url-resolution) below).

Switching between backends requires only environment variables — no code changes.

---

## Technical Implementation

### Dependencies

| Package | Purpose |
|---|---|
| `ex_aws` | AWS SDK core, request signing |
| `ex_aws_s3` | S3-specific operations |
| `hackney` | HTTP adapter used by ex_aws |

Phoenix LiveView's built-in upload system (`allow_upload` / `consume_uploaded_entries`) handles chunked transfer and client-side validation. `Socho.Uploads.upload/3` is called inside `consume_uploaded_entries` and returns `{:ok, ref}` where `ref` is the stored reference string (path or `s3:` key).

### Stored Reference Format

The reference stored in template vars differs by backend:

| Backend | Stored ref | Example |
|---|---|---|
| Local | URL path | `/uploads/123456_photo.jpg` |
| S3 | Storage key | `s3:uploads/123456_photo.jpg` |

Filenames are prefixed with `System.unique_integer([:positive])` to avoid collisions.

### URL Resolution

S3 refs are not valid URLs. They are resolved to presigned GET URLs (1-hour TTL) by `Socho.Uploads.resolve_url/1`. Two helper functions build on this:

- `resolve_vars/1` — walks a template vars map and resolves any `s3:` refs found in string or list values.
- `rebuild_template_groups/1` — walks a trial tree, finds `template_group` nodes, and re-runs their template build function with freshly resolved vars. This regenerates the stimulus HTML with valid presigned URLs.

Resolution happens in two places:

1. **Builder** (`StudyLive.Builder`) — called before every `tpl.build.(vars)` invocation so the live preview always renders correctly.
2. **Study controller** (`StudyController.show`) — called after loading the study from the database and before `JsGenerator.generate_inline_js/1`. This ensures participants always receive non-expired URLs regardless of when the study was last saved.

The implication is that **presigned URL expiry is not a concern for saved studies** — the stored vars hold `s3:` keys indefinitely, and fresh presigned URLs are generated on every serve.

### Enabling S3

Set the following environment variables:

```
S3_BUCKET=your-bucket-name
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

The region is hardcoded to `ap-south-2` in `Socho.Uploads`. When `S3_BUCKET` is present, `config/runtime.exs` sets `:uploads_backend` to `:s3` and configures `ex_aws`. When it is absent, the local backend is used with no additional config required.

### Where Uploads Appear in the Codebase

- `lib/socho/uploads.ex` — the entire uploads abstraction
- `lib/socho_web/live/study_live/builder.ex` — `use_uploaded_file` event and the `↑ Upload` button in template variable list fields
- `lib/socho_web/controllers/study_controller.ex` — `rebuild_template_groups` call before JS generation
- `priv/static/uploads/` — local storage directory (served by `Plug.Static`)
- `lib/socho_web.ex` — `"uploads"` added to `static_paths/0`

The upload UI is currently wired into the template variable editor for `:list`-type variables (used by the IAT stimulus fields). The drag-and-drop modal, file chip display, and cancel flow all live in `builder.ex`.

---

## Caveats and Known Limitations

**Presigned URL TTL in the builder.** The builder resolves `s3:` refs to 1-hour presigned URLs when building the live preview. If a user keeps the builder open for more than an hour without triggering a rebuild (e.g., changing a var), images in the preview may stop loading. Triggering any var change re-resolves everything. This does not affect participants.

**Local files are not cleaned up.** Files uploaded to `priv/static/uploads/` are never deleted, even if the associated study is deleted or the stimulus entry is removed. For long-running deployments, manual pruning or a periodic cleanup job will be needed.

**S3 objects are also not deleted.** The same applies to S3 — removing a stimulus entry from the builder does not delete the object from the bucket. Add a lifecycle rule on the bucket prefix if storage growth is a concern.

**No content-type enforcement on S3.** The S3 upload does not currently set `Content-Type` metadata on the object. Browsers generally infer type correctly from the file extension, but if you need strict MIME types on responses (e.g., for CORS or CSP rules), pass `content_type: entry.content_type` to `ExAws.S3.upload/3`.

**Single-file uploads only.** `allow_upload` is configured with `max_entries: 1`. The UI opens a fresh modal per stimulus slot, so this is intentional, but the constraint is worth knowing if the upload flow is extended.

