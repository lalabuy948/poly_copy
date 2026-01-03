defmodule PolyxWeb.Plugs.OptionalBasicAuth do
  @moduledoc """
  Optional basic authentication plug that checks config at runtime.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:polyx, :basic_auth)

    case config do
      nil ->
        conn

      config when is_list(config) ->
        username = Keyword.get(config, :username)
        password = Keyword.get(config, :password)

        if username && password do
          Plug.BasicAuth.basic_auth(conn, username: username, password: password)
        else
          conn
        end

      _ ->
        conn
    end
  end
end
