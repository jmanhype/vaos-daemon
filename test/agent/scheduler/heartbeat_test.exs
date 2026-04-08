defmodule Daemon.Agent.Scheduler.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Daemon.Agent.Scheduler.Heartbeat

  setup do
    original_config_dir = Application.get_env(:daemon, :config_dir)
    original_eval_mode = Application.get_env(:daemon, :eval_mode, :__missing__)

    tmp_dir =
      Path.join(System.tmp_dir!(), "daemon-heartbeat-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    Application.put_env(:daemon, :config_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      case original_config_dir do
        nil -> Application.delete_env(:daemon, :config_dir)
        value -> Application.put_env(:daemon, :config_dir, value)
      end

      case original_eval_mode do
        :__missing__ -> Application.delete_env(:daemon, :eval_mode)
        value -> Application.put_env(:daemon, :eval_mode, value)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "run/1 suppresses heartbeat task execution in eval mode", %{tmp_dir: tmp_dir} do
    Application.put_env(:daemon, :eval_mode, true)

    heartbeat_path = Path.join(tmp_dir, "HEARTBEAT.md")

    File.write!(
      heartbeat_path,
      "# Heartbeat Tasks\n\n- [ ] Investigate a fresh evaluation topic\n"
    )

    state = %{last_run: nil, failures: %{}}
    updated_state = Heartbeat.run(state)

    assert %DateTime{} = updated_state.last_run
    assert File.read!(heartbeat_path) =~ "- [ ] Investigate a fresh evaluation topic"
  end
end
