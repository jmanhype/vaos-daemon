defmodule Daemon.Sandbox.Behaviour do
  @moduledoc "Common behaviour for sandbox backends (Docker, Wasm, Sprites)."

  @type exec_result ::
          {:ok, output :: String.t(), exit_code :: non_neg_integer()}
          | {:error, reason :: String.t()}

  @callback available?() :: boolean()
  @callback execute(command :: String.t(), opts :: keyword()) :: exec_result()
end
