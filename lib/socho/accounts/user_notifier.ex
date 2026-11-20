defmodule Socho.Accounts.UserNotifier do
  import Swoosh.Email

  alias Socho.Mailer
  alias Socho.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({Application.get_env(:socho, :app_label, "Socho"), "admin@tattle.co.in"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver an invitation email with a magic link to get started.
  """
  def deliver_invitation(user, url) do
    role_label = user.role |> to_string() |> String.capitalize()

    app_label = Application.get_env(:socho, :app_label, "Socho")
    deliver(user.email, "You've been invited to #{app_label}", """

    ==============================

    Hi #{user.email},

    You've been invited to join #{app_label} as a #{role_label}.

    Click the link below to confirm your account and log in:

    #{url}

    This link will expire after a short time. If you weren't expecting this invitation,
    you can safely ignore this email.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
