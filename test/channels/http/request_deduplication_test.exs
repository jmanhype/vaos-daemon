defmodule Daemon.Channels.HTTP.RequestDeduplicationTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Daemon.Channels.HTTP.RequestDeduplication

  @opts RequestDeduplication.init([])

  setup do
    try do
      :ets.delete_all_objects(:daemon_request_dedup)
    rescue
      _ -> :ok
    end
    :ok
  end

  describe "compute_fingerprint/2" do
    test "generates consistent fingerprint for identical requests" do
      conn = conn(:post, "/api/v1/orchestrate", %{"input" => "deploy to production", "session_id" => "test-123"})
        |> assign(:user_id, "user-1")

      fingerprint1 = RequestDeduplication.compute_fingerprint(conn, "user-1")
      fingerprint2 = RequestDeduplication.compute_fingerprint(conn, "user-1")
      assert fingerprint1 == fingerprint2
    end

    test "generates different fingerprints for different inputs" do
      conn1 = conn(:post, "/api/v1/orchestrate", %{"input" => "deploy to production"})
        |> assign(:user_id, "user-1")
      conn2 = conn(:post, "/api/v1/orchestrate", %{"input" => "deploy to staging"})
        |> assign(:user_id, "user-1")

      fingerprint1 = RequestDeduplication.compute_fingerprint(conn1, "user-1")
      fingerprint2 = RequestDeduplication.compute_fingerprint(conn2, "user-1")
      assert fingerprint1 != fingerprint2
    end
  end

  describe "check_and_record/1" do
    test "allows first request" do
      conn = conn(:post, "/api/v1/orchestrate", %{"input" => "test"})
        |> assign(:user_id, "user-1")
      assert {:ok, _fingerprint} = RequestDeduplication.check_and_record(conn)
    end

    test "rejects duplicate request within window" do
      conn = conn(:post, "/api/v1/orchestrate", %{"input" => "test"})
        |> assign(:user_id, "user-1")
      assert {:ok, _fingerprint} = RequestDeduplication.check_and_record(conn)
      assert {:error, :duplicate} = RequestDeduplication.check_and_record(conn)
    end

    test "allows different requests for same user" do
      conn1 = conn(:post, "/api/v1/orchestrate", %{"input" => "test1"})
        |> assign(:user_id, "user-1")
      conn2 = conn(:post, "/api/v1/orchestrate", %{"input" => "test2"})
        |> assign(:user_id, "user-1")

      assert {:ok, _fingerprint1} = RequestDeduplication.check_and_record(conn1)
      assert {:ok, _fingerprint2} = RequestDeduplication.check_and_record(conn2)
    end

    test "allows same request from different users" do
      conn1 = conn(:post, "/api/v1/orchestrate", %{"input" => "test"})
        |> assign(:user_id, "user-1")
      conn2 = conn(:post, "/api/v1/orchestrate", %{"input" => "test"})
        |> assign(:user_id, "user-2")

      assert {:ok, _fingerprint1} = RequestDeduplication.check_and_record(conn1)
      assert {:ok, _fingerprint2} = RequestDeduplication.check_and_record(conn2)
    end
  end

  describe "Plug.call/2" do
    test "passes through non-orchestrate requests" do
      conn = conn(:post, "/api/v1/sessions", %{"input" => "test"})
        |> assign(:user_id, "user-1")
        |> RequestDeduplication.call(@opts)

      refute conn.halted
      assert conn.status != 409
    end

    test "allows first orchestrate request" do
      conn = conn(:post, "/api/v1/orchestrate", %{"input" => "test"})
        |> assign(:user_id, "user-1")
        |> RequestDeduplication.call(@opts)

      refute conn.halted
      assert conn.status != 409
    end

    test "rejects duplicate orchestrate request" do
      body = %{"input" => "test"}

      conn1 = conn(:post, "/api/v1/orchestrate", body)
        |> assign(:user_id, "user-1")
        |> RequestDeduplication.call(@opts)

      refute conn1.halted

      conn2 = conn(:post, "/api/v1/orchestrate", body)
        |> assign(:user_id, "user-1")
        |> RequestDeduplication.call(@opts)

      assert conn2.halted
      assert conn2.status == 409
    end
  end
end
