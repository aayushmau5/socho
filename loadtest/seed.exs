defmodule Socho.Load.Seed do
  @moduledoc """
  Seeds a load test database for loadtest/participant.exs.

  It refuses to run unless the connected database's name contains "loadtest".
  Each run first deletes what the previous run seeded, then creates:

    * a "Load Test" client
    * two published IAT studies: one public, one for the client
    * SEED_ACCOUNTS participant accounts for the client (default 5000)

  It writes two files to loadtest/fixtures/: iat_submission.json, the
  submission every participant posts, and accounts.csv. Randomness is seeded,
  so the submission is the same on every run.

  It ends by printing the env vars loadtest/participant.exs needs.
  """

  import Ecto.Query

  alias Socho.{Clients, Repo, Studies}
  alias Socho.Accounts.User
  alias Socho.Clients.Client
  alias Socho.Studies.{Study, Templates}

  @fixtures_dir Path.join(__DIR__, "fixtures")
  @fixture_path Path.join(@fixtures_dir, "iat_submission.json")
  @accounts_path Path.join(@fixtures_dir, "accounts.csv")
  @password "loadtest-password"
  @email_domain "loadtest.socho.local"
  @client_name "Load Test"
  @title_prefix "Load Test: "
  @random_seed {31, 31, 31}
  @insert_batch_size 1_000
  @error_rate 0.07
  @reaction_time_sd_ms 180
  @min_reaction_time_ms 300
  @max_reaction_time_ms 3_000
  @gap_between_trials_ms 250
  @plugin_version "2.0.0"

  defstruct [:database, :accounts_count, :seeded_at]

  def run do
    :rand.seed(:exsss, @random_seed)
    nodes = iat_nodes()

    with {:ok, config} <- load_config(),
         :ok <- delete_previous_seed(),
         {:ok, client} <- find_or_create_client(),
         {:ok, public_study} <-
           create_published_study("IAT (public)", nil, nodes, %{
             allow_multiple_public_submissions: true
           }),
         {:ok, client_study} <- create_published_study("IAT (client)", client.id, nodes, %{}) do
      submission = build_submission(nodes)
      File.mkdir_p!(@fixtures_dir)
      File.write!(@fixture_path, Jason.encode!(submission, pretty: true))

      emails = Enum.map(1..config.accounts_count, &account_email/1)
      insert_accounts!(config, emails, client)
      write_accounts_csv!(emails)

      print_summary(config, submission, public_study, client_study)
    else
      {:error, reason} -> raise failure_message(reason)
    end
  end

  defp load_config do
    database = current_database()

    if String.contains?(database, "loadtest") do
      {:ok,
       %__MODULE__{
         database: database,
         accounts_count: System.get_env("SEED_ACCOUNTS", "5000") |> String.to_integer(),
         seeded_at: DateTime.utc_now(:second)
       }}
    else
      {:error, {:not_loadtest_database, database}}
    end
  end

  defp current_database do
    %{rows: [[database]]} = Repo.query!("select current_database()")
    database
  end

  defp delete_previous_seed do
    Repo.delete_all(from u in User, where: like(u.email, ^"%@#{@email_domain}"))
    Repo.delete_all(from s in Study, where: like(s.title, ^"#{@title_prefix}%"))
    :ok
  end

  defp find_or_create_client do
    case Repo.get_by(Client, name: @client_name) do
      nil -> Clients.create_client(%{name: @client_name})
      %Client{} = client -> {:ok, client}
    end
  end

  defp create_published_study(title, client_id, nodes, attrs) do
    with {:ok, study} <-
           Studies.create_study_with_trials(@title_prefix <> title, client_id, nodes) do
      Studies.update_study(study.id, Map.put(attrs, :status, :published))
    end
  end

  defp iat_nodes do
    iat = Templates.get("iat")
    defaults = Map.new(iat.variables, &{&1.key, &1.default})

    iat.build.(
      Map.merge(defaults, %{
        "cat1_label" => "Flowers",
        "cat1_images" => image_urls("flower"),
        "cat2_label" => "Insects",
        "cat2_images" => image_urls("insect"),
        "att1_images" => "Joy\nLove\nPeace\nHappy\nLaughter",
        "att2_images" => "Agony\nTerrible\nHorrible\nNasty\nEvil"
      })
    )
  end

  defp image_urls(name) do
    Enum.map_join(1..5, "\n", &"https://picsum.photos/seed/#{name}#{&1}/300")
  end

  defp build_submission(nodes) do
    [_preload, _instructions, versions, _results] = nodes
    iat_trials = Enum.flat_map(version_aa(versions), &trials_for/1)

    ([preload_trial(), instructions_trial()] ++ iat_trials ++ [results_trial()])
    |> add_timing()
    |> Kernel.++([iat_summary()])
  end

  defp version_aa(versions) do
    Enum.take(versions.children, hd(versions.config["group_sizes"]))
  end

  defp trials_for(%{node_type: "timeline", config: config}) do
    iat_type = config["data"]["iat_type"]

    for _ <- 1..config["repetitions"], variable <- Enum.shuffle(config["timeline_variables"]) do
      iat_trial(variable, iat_type)
    end
  end

  defp trials_for(%{plugin: "html-button-response", config: config}) do
    [
      %{
        "trial_type" => "html-button-response",
        "stimulus" => config["stimulus"],
        "response" => 0,
        "rt" => Enum.random(1_500..6_000)
      }
    ]
  end

  defp iat_trial(variable, iat_type) do
    expected = expected_key(variable["stim_key_association"])
    correct? = :rand.uniform() > @error_rate

    %{
      "trial_type" => "iat-html",
      "stimulus" => variable["stimulus"],
      "response" => if(correct?, do: expected, else: other_key(expected)),
      "correct" => correct?,
      "rt" => reaction_time(iat_type),
      "iat_type" => iat_type
    }
  end

  defp expected_key("left"), do: "e"
  defp expected_key(_right), do: "i"

  defp other_key("e"), do: "i"
  defp other_key("i"), do: "e"

  defp reaction_time(iat_type) do
    (mean_reaction_time(iat_type) + :rand.normal() * @reaction_time_sd_ms)
    |> round()
    |> max(@min_reaction_time_ms)
    |> min(@max_reaction_time_ms)
  end

  defp mean_reaction_time("combined1" <> _block), do: 750
  defp mean_reaction_time("combined2" <> _block), do: 900
  defp mean_reaction_time(_iat_type), do: 700

  defp preload_trial do
    %{
      "trial_type" => "preload",
      "success" => true,
      "timeout" => false,
      "failed_images" => [],
      "failed_audio" => [],
      "failed_video" => [],
      "rt" => 412
    }
  end

  defp instructions_trial do
    %{
      "trial_type" => "instructions",
      "view_history" => [%{"page_index" => 0, "viewing_time" => 8213}],
      "rt" => 8213
    }
  end

  defp results_trial do
    %{
      "trial_type" => "html-button-response",
      "stimulus" => "<h2>Your results</h2><p>D-score: 0.42</p>",
      "response" => 0,
      "rt" => 3120
    }
  end

  defp iat_summary do
    %{"iat_type" => "iat_summary", "d_score" => 0.42, "mean_c1" => 771.98, "mean_c2" => 932.94}
  end

  defp add_timing(trials) do
    {timed_trials, _elapsed_ms} =
      trials
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {trial, index}, elapsed_ms ->
        elapsed_ms = elapsed_ms + trial["rt"] + @gap_between_trials_ms

        timing = %{
          "trial_index" => index,
          "time_elapsed" => elapsed_ms,
          "plugin_version" => @plugin_version
        }

        {Map.merge(trial, timing), elapsed_ms}
      end)

    timed_trials
  end

  defp account_email(number) do
    "lt-#{String.pad_leading(Integer.to_string(number), 6, "0")}@#{@email_domain}"
  end

  defp insert_accounts!(%__MODULE__{seeded_at: seeded_at}, emails, %Client{} = client) do
    hashed_password = Bcrypt.hash_pwd_salt(@password)

    emails
    |> Enum.map(fn email ->
      %{
        email: email,
        hashed_password: hashed_password,
        confirmed_at: seeded_at,
        role: :participant,
        client_id: client.id,
        verification_method: :email,
        inserted_at: seeded_at,
        updated_at: seeded_at
      }
    end)
    |> Enum.chunk_every(@insert_batch_size)
    |> Enum.each(&Repo.insert_all(User, &1))
  end

  defp write_accounts_csv!(emails) do
    rows = Enum.map(emails, &"#{&1},#{@password}\n")
    File.write!(@accounts_path, ["email,password\n" | rows])
  end

  defp print_summary(%__MODULE__{} = config, submission, public_study, client_study) do
    IO.puts("""
    Seeded #{config.database}: #{config.accounts_count} accounts, \
    #{length(submission)} trial rows per submission.

    export SOCHO_PUBLIC_STUDY_ID=#{public_study.id}
    export SOCHO_CLIENT_STUDY_ID=#{client_study.id}
    export SOCHO_ACCOUNTS=loadtest/fixtures/accounts.csv
    """)
  end

  defp failure_message({:not_loadtest_database, database}),
    do: "refusing to seed #{inspect(database)}: the database name must contain \"loadtest\""

  defp failure_message(%Ecto.Changeset{} = changeset),
    do: "could not save #{inspect(changeset.data.__struct__)}: #{inspect(changeset.errors)}"

  defp failure_message(reason), do: "seeding failed: #{inspect(reason)}"
end

Socho.Load.Seed.run()
