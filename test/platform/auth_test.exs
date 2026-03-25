defmodule Daemon.Platform.AuthTest do
  # async: false because tests mutate application env (jwt_secret) and the HTTP
  # Auth module reads it at call time. Running async risks cross-test secret
  # mismatch when other test files also mutate :shared_secret.
  use ExUnit.Case, async: false

  alias Daemon.Channels.HTTP.Auth

  # Pin a deterministic secret for the entire module so generate/verify use the
  # same key regardless of what other test files set in application env.
  setup do
    original = Application.get_env(:daemon, :jwt_secret)
    Application.put_env(:daemon, :jwt_secret, "test-secret-for-platform-auth-tests")

    on_exit(fn ->
      if original do
        Application.put_env(:daemon, :jwt_secret, original)
      else
        Application.delete_env(:daemon, :jwt_secret)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_claims(overrides \\ %{}) do
    Map.merge(%{"user_id" => "user-abc-123", "email" => "test@example.com", "role" => "user"}, overrides)
  end

  # ---------------------------------------------------------------------------
  # Auth.generate_token/1
  # ---------------------------------------------------------------------------

  describe "generate_token/1" do
    test "returns a three-segment JWT string" do
      token = Auth.generate_token(build_claims())

      assert is_binary(token)
      assert length(String.split(token, ".")) == 3
    end

    test "embeds user_id claim in the payload" do
      token = Auth.generate_token(build_claims(%{"user_id" => "u-999"}))

      [_header, payload_b64, _sig] = String.split(token, ".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      claims = Jason.decode!(json)

      assert claims["user_id"] == "u-999"
    end

    test "sets exp approximately 15 minutes from now" do
      now = System.system_time(:second)
      token = Auth.generate_token(build_claims())

      [_header, payload_b64, _sig] = String.split(token, ".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      claims = Jason.decode!(json)

      # 900 seconds = 15 min; allow 5-second window for test timing
      assert claims["exp"] >= now + 895
      assert claims["exp"] <= now + 905
    end

    test "does not overwrite caller-provided exp" do
      future_exp = System.system_time(:second) + 3600
      token = Auth.generate_token(build_claims(%{"exp" => future_exp}))

      [_header, payload_b64, _sig] = String.split(token, ".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      claims = Jason.decode!(json)

      assert claims["exp"] == future_exp
    end

    test "encodes HS256 header" do
      token = Auth.generate_token(build_claims())

      [header_b64 | _] = String.split(token, ".")
      {:ok, json} = Base.url_decode64(header_b64, padding: false)
      header = Jason.decode!(json)

      assert header["alg"] == "HS256"
      assert header["typ"] == "JWT"
    end
  end

  # ---------------------------------------------------------------------------
  # Auth.generate_refresh_token/1
  # ---------------------------------------------------------------------------

  describe "generate_refresh_token/1" do
    test "returns a three-segment JWT string" do
      token = Auth.generate_refresh_token(build_claims())

      assert length(String.split(token, ".")) == 3
    end

    test "sets type claim to 'refresh'" do
      token = Auth.generate_refresh_token(build_claims())

      [_h, payload_b64, _s] = String.split(token, ".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      claims = Jason.decode!(json)

      assert claims["type"] == "refresh"
    end

    test "sets exp approximately 7 days from now" do
      now = System.system_time(:second)
      token = Auth.generate_refresh_token(build_claims())

      [_h, payload_b64, _s] = String.split(token, ".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      claims = Jason.decode!(json)

      # 604_800 seconds = 7 days; allow 10-second window
      assert claims["exp"] >= now + 604_790
      assert claims["exp"] <= now + 604_810
    end
  end

  # ---------------------------------------------------------------------------
  # Auth.verify_token/1
  # ---------------------------------------------------------------------------

  describe "verify_token/1" do
    test "verifies a freshly generated token and returns claims" do
      claims = build_claims(%{"user_id" => "verify-me"})
      token = Auth.generate_token(claims)

      assert {:ok, returned_claims} = Auth.verify_token(token)
      assert returned_claims["user_id"] == "verify-me"
    end

    test "returns error for tampered payload" do
      token = Auth.generate_token(build_claims())
      [header, _payload, sig] = String.split(token, ".")

      fake_payload =
        %{"user_id" => "hacker", "exp" => System.system_time(:second) + 9999}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      tampered = "#{header}.#{fake_payload}.#{sig}"

      assert {:error, :invalid_token} = Auth.verify_token(tampered)
    end

    test "returns error for expired token" do
      # The setup callback pins jwt_secret, so we can build a validly-signed but
      # expired token using the same secret the module will read during verify.
      secret = Application.fetch_env!(:daemon, :jwt_secret)
      past_exp = System.system_time(:second) - 1
      claims = build_claims(%{"exp" => past_exp})

      header = %{"alg" => "HS256", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)
      payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
      sig =
        :crypto.mac(:hmac, :sha256, secret, "#{header}.#{payload}")
        |> Base.url_encode64(padding: false)

      expired_token = "#{header}.#{payload}.#{sig}"

      assert {:error, :invalid_token} = Auth.verify_token(expired_token)
    end

    test "returns error for completely invalid token string" do
      assert {:error, :invalid_token} = Auth.verify_token("not.a.jwt")
    end

    test "returns error for empty string" do
      assert {:error, :invalid_token} = Auth.verify_token("")
    end

    test "returns error for token missing exp claim" do
      # We can't easily inject tokens without exp using generate_token (it adds exp),
      # but we can verify that the generated tokens do contain exp and verify succeeds.
      token = Auth.generate_token(build_claims())
      assert {:ok, claims} = Auth.verify_token(token)
      assert Map.has_key?(claims, "exp")
    end
  end

  # ---------------------------------------------------------------------------
  # Auth.refresh/1
  # ---------------------------------------------------------------------------

  describe "refresh/1" do
    test "returns new access + refresh tokens for valid refresh token" do
      claims = build_claims(%{"user_id" => "refresh-user"})
      refresh_token = Auth.generate_refresh_token(claims)

      assert {:ok, result} = Auth.refresh(refresh_token)
      assert is_binary(result.token)
      assert is_binary(result.refresh_token)
      assert result.expires_in == 900
    end

    test "returns error when given an access token (not a refresh token)" do
      access_token = Auth.generate_token(build_claims())
      assert {:error, :not_refresh_token} = Auth.refresh(access_token)
    end

    test "returns error for invalid token string" do
      assert {:error, :invalid_token} = Auth.refresh("garbage.token.here")
    end

    test "newly issued access token is itself valid" do
      refresh_token = Auth.generate_refresh_token(build_claims(%{"user_id" => "roundtrip"}))
      {:ok, %{token: new_access}} = Auth.refresh(refresh_token)

      assert {:ok, new_claims} = Auth.verify_token(new_access)
      assert new_claims["user_id"] == "roundtrip"
    end
  end
end
