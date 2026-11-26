defmodule Socho.Load.Participant do
  @moduledoc """
  Simulates participants taking an IAT study, the way a browser would.

  Every iteration is a new visitor who does one of two things:

    * Anonymous (1 - LOGGED_IN_SHARE): opens the public study, loads its
      assets, takes the study, and submits the results.
    * Signed in (LOGGED_IN_SHARE): opens /dashboard, gets redirected to log
      in, signs in with a seeded account, views the dashboard, then takes the
      client study the same way.

  A failed step stops the iteration and raises, so Stampede counts it under
  "iteration.errors" and prints the reason.

  Run loadtest/seed.exs first, then set:

    * SOCHO_PUBLIC_STUDY_ID, SOCHO_CLIENT_STUDY_ID, SOCHO_ACCOUNTS (printed by the seed)
    * SOCHO_BASE_URL (default http://localhost:4000)
    * LOGGED_IN_SHARE (default 0.5)
    * SOCHO_THINK_SECONDS, how long taking a study takes (default 30-90)
  """

  use Stampede.Scenario

  alias Stampede.{HTTP, LiveView, VU}

  @fixture_path Path.join(__DIR__, "fixtures/iat_submission.json")
  @gzip {"accept-encoding", "gzip"}
  @typing_ms 3_000..8_000
  @dashboard_view_ms 1_000..3_000

  defstruct [
    :base_url,
    :public_study_id,
    :client_study_id,
    :logged_in_share,
    :study_duration_ms,
    :submission,
    :accounts,
    :accounts_used
  ]

  @impl true
  def options do
    [
      # Stages:
      # 1. from 0 to 60 seconds, we grow from 0 to 500 users (about 8 new users per second)
      # 2. for the next 2 minutes, stay at 500 users
      # 3. over the last 10 seconds, drop from 500 to 0 users
      stages: [{[second: 60], 500}, {[minute: 2], 500}, {[second: 10], 0}],
      # Pass and fail rules
      thresholds: [
        # Speed rules
        # opening a study page: 95% of requests must finish within 500ms
        {"study.page", p95: 500},
        # posting the result: 95% of requests must finish within 300ms
        {"study.submit", p95: 300},
        # login request
        {"login.post", p95: 1_000},
        # Correctness rules
        # the study page loaded
        {"study page is 200", failed_rate: 0},
        # every JS and CSS file loaded
        {"asset is 200", failed_rate: 0},
        # login redirects to /dashboard
        {"logged in", failed_rate: 0},
        # the submission is successful
        {"submit saved", failed_rate: 0},
        # Crash rules
        # No user's session may crash
        {"iteration.errors", count: 0}
      ]
    ]
  end

  @impl true
  def setup(_opts) do
    # This struct is passed verbatim to run/1 below
    %__MODULE__{
      base_url: System.get_env("SOCHO_BASE_URL", "http://localhost:4000"),
      public_study_id: System.fetch_env!("SOCHO_PUBLIC_STUDY_ID"),
      client_study_id: System.fetch_env!("SOCHO_CLIENT_STUDY_ID"),
      logged_in_share: parse_share(System.get_env("LOGGED_IN_SHARE", "0.5")),
      study_duration_ms: parse_seconds_range(System.get_env("SOCHO_THINK_SECONDS", "30-90")),
      submission: @fixture_path |> File.read!() |> Jason.decode!(),
      accounts: System.fetch_env!("SOCHO_ACCOUNTS") |> load_accounts() |> List.to_tuple(),
      accounts_used: :atomics.new(1, [])
    }
  end

  @impl true
  # Every virtual users run this function over and over
  #
  # There are two types of VUs: anonymous & users with account.
  #
  # The follow roughly looks like:
  #  1. (If user has account) Get a seeded account
  #  2. (If user has account) Visit /dashboard, user not logged in, redirected to /login
  #  3. (If user has account) Using a seeded account credentials, log in(POST login)
  #  4. Open a study URL, parse body
  #  5. Load CSS/JS assets
  #  6. Pause x seconds (configured) to simulate a study. Study happens in-browser without any server involvement.
  #  7. Submit study result
  def run(%VU{data: %__MODULE__{} = config}) do
    HTTP.clear_cookies()

    result =
      if sign_in?(config) do
        sign_in_and_take_study(config)
      else
        take_study(config, config.public_study_id)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> raise failure_message(reason)
    end
  end

  defp sign_in?(%__MODULE__{logged_in_share: share}) do
    :rand.uniform() < share
  end

  defp sign_in_and_take_study(%__MODULE__{} = config) do
    with {:ok, account} <- get_account(config),
         :ok <- sign_in(config, account),
         :ok <- view_dashboard(config) do
      take_study(config, config.client_study_id)
    end
  end

  defp sign_in(%__MODULE__{} = config, account) do
    credentials = %{"email" => account.email, "password" => account.password}

    with {:ok, login} <- LiveView.connect(config.base_url <> "/dashboard", cookies: true),
         :ok <- pause(@typing_ms),
         {:ok, _reply} <- LiveView.submit(login, "submit_password", %{"user" => credentials}),
         :ok <- LiveView.close(login),
         {:ok, response} <- post_login_form(config, login.params["_csrf_token"], credentials) do
      expect("logged in", response, redirected_to?(response, "/dashboard"))
    end
  end

  defp post_login_form(%__MODULE__{} = config, csrf_token, credentials) do
    post(config.base_url <> "/users/log-in",
      cookies: true,
      headers: [@gzip],
      metric: "login.post",
      form: %{
        "_csrf_token" => csrf_token,
        "user" => Map.put(credentials, "remember_me", "true")
      }
    )
  end

  defp view_dashboard(%__MODULE__{} = config) do
    with {:ok, dashboard} <- LiveView.connect(config.base_url <> "/dashboard", cookies: true),
         :ok <- pause(@dashboard_view_ms) do
      LiveView.close(dashboard)
    end
  end

  defp take_study(%__MODULE__{} = config, study_id) do
    study_url = "#{config.base_url}/study/#{study_id}"

    with {:ok, html} <- open_study(study_url),
         :ok <- load_assets(config, html),
         :ok <- pause(config.study_duration_ms) do
      submit_results(config, study_url, HTTP.csrf_token(html))
    end
  end

  defp open_study(study_url) do
    with {:ok, page} <- HTTP.get(study_url, cookies: true, headers: [@gzip], metric: "study.page"),
         :ok <- expect("study page is 200", page, page.status == 200) do
      {:ok, body(page)}
    end
  end

  defp load_assets(%__MODULE__{} = config, html) do
    html
    |> asset_paths()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case load_asset(config.base_url <> path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp load_asset(url) do
    with {:ok, asset} <- HTTP.get(url, cookies: true, headers: [@gzip], metric: "study.asset") do
      expect("asset is 200", asset, asset.status == 200)
    end
  end

  defp submit_results(%__MODULE__{} = config, study_url, csrf_token) do
    with {:ok, response} <-
           post(study_url <> "/user-data",
             cookies: true,
             headers: [{"x-csrf-token", csrf_token}, {"accept", "*/*"}, @gzip],
             metric: "study.submit",
             json: %{data: config.submission}
           ) do
      saved? = response.status == 200 and submit_status(response) == "ok"
      expect("submit saved", response, saved?)
    end
  end

  # Stampede 1.4.0 returns :closed when it reuses a keep-alive connection the
  # server closed while idle, where a browser opens a new one. Fixed upstream
  # in mandar1045/stampede#7, unreleased as of 1.4.0.
  defp post(url, opts) do
    case HTTP.post(url, opts) do
      {:error, %Mint.TransportError{reason: :closed}} -> HTTP.post(url, opts)
      result -> result
    end
  end

  defp expect(check_name, response, passed?) do
    if Stampede.check(check_name, passed?) do
      :ok
    else
      {:error, {:check_failed, check_name, response.status}}
    end
  end

  defp pause(range_ms), do: Process.sleep(Enum.random(range_ms))

  defp get_account(%__MODULE__{accounts: accounts, accounts_used: accounts_used}) do
    index = :atomics.add_get(accounts_used, 1, 1)

    if index <= tuple_size(accounts) do
      {:ok, elem(accounts, index - 1)}
    else
      {:error, :out_of_accounts}
    end
  end

  defp failure_message(:out_of_accounts),
    do: "used every seeded account: reseed with a higher SEED_ACCOUNTS"

  defp failure_message({:check_failed, check_name, status}),
    do: "check #{inspect(check_name)} failed with status #{status}"

  defp failure_message(reason), do: "participant failed: #{inspect(reason)}"

  defp asset_paths(html) do
    ~r/(?:src|href)="(\/[^"]+\.(?:js|css))"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp body(response) do
    case header(response, "content-encoding") do
      "gzip" -> :zlib.gunzip(response.body)
      _ -> response.body
    end
  end

  defp submit_status(response) do
    case Jason.decode(body(response)) do
      {:ok, %{"status" => status}} -> status
      _ -> nil
    end
  end

  defp redirected_to?(response, path) do
    response.status == 302 and header(response, "location") == path
  end

  defp header(response, name) do
    case List.keyfind(response.headers, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp load_accounts(path) do
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&parse_account/1)
  end

  defp parse_account(line) do
    [email, password] = String.split(line, ",", parts: 2)
    %{email: email, password: password}
  end

  defp parse_share(value) do
    {share, ""} = Float.parse(value)
    share
  end

  defp parse_seconds_range(value) do
    [low, high] = value |> String.split("-") |> Enum.map(&String.to_integer/1)
    (low * 1_000)..(high * 1_000)
  end
end
