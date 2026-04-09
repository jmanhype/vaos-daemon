defmodule Daemon.Tools.Builtins.AlphaXivClientTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Builtins.AlphaXivClient

  test "auth_available? is false when no token is present" do
    tmp = temp_dir!()
    token_path = Path.join(tmp, "alphaxiv_token.txt")
    oauth_path = Path.join(tmp, "alphaxiv_oauth.json")

    refute AlphaXivClient.auth_available?(token_path: token_path, oauth_path: oauth_path)
  end

  test "auth_available? is true when a token is present" do
    tmp = temp_dir!()
    token_path = Path.join(tmp, "alphaxiv_token.txt")
    oauth_path = Path.join(tmp, "alphaxiv_oauth.json")

    File.write!(token_path, "header.payload.signature")

    assert AlphaXivClient.auth_available?(token_path: token_path, oauth_path: oauth_path)
  end

  defp temp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "alphaxiv-client-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end
end
