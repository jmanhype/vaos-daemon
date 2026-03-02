defmodule OptimalSystemAgent.Tools.Builtins.AskUser do
  @moduledoc """
  Interactive prompting tool — lets the LLM ask the user questions mid-task.

  Emits an event on the Bus and waits for the user's response.
  The channel (SSE/TUI) renders the question and relays the answer back.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Events.Bus

  @timeout_ms 300_000

  @impl true
  def name, do: "ask_user"

  @impl true
  def description, do: "Ask the user a question to clarify requirements. Use when you need input before proceeding."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{"type" => "string", "description" => "The question to ask the user"},
        "options" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional multiple choice options"
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  def execute(%{"question" => question} = params) do
    options = params["options"] || []
    ref = make_ref()
    caller = self()

    # Emit ask_user event — the channel will render this and send back the answer
    Bus.emit(:system_event, %{
      event: :ask_user,
      question: question,
      options: options,
      ref: inspect(ref),
      reply_to: caller
    })

    # Wait for the response from the channel
    receive do
      {:ask_user_response, ^ref, answer} when is_binary(answer) ->
        {:ok, "User answered: #{answer}"}

      {:ask_user_response, _ref, answer} when is_binary(answer) ->
        # Accept even if ref doesn't match (single ask_user at a time)
        {:ok, "User answered: #{answer}"}
    after
      @timeout_ms ->
        {:error, "User did not respond within 5 minutes"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: question"}
end
