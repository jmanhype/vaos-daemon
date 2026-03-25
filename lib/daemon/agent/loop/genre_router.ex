defmodule Daemon.Agent.Loop.GenreRouter do
  @moduledoc """
  Signal genre routing for the agent loop.

  Routes message handling based on the signal genre from upstream classification.
  Returns {:respond, text} to short-circuit with a direct response,
  or :execute_tools to continue normal LLM + tool execution.

  Genres from Signal Theory 5-tuple Type field:
    :direct   — user wants something done -> execute tools (default)
    :inform   — user is sharing info -> suggest memory_save, no tools
    :express  — emotional content -> empathetic response, no tools
    :decide   — user needs help deciding -> ask clarifying question first
    :commit   — user is committing to an action -> confirm plan before executing
  """

  @doc """
  Route message handling based on the signal genre.

  Returns {:respond, text} to short-circuit, or :execute_tools for normal execution.
  """
  def route_by_genre(:inform, _message, _state) do
    {:respond,
     "Got it — I've noted that. Would you like me to save this to memory with `memory_save` so I can reference it later?"}
  end

  def route_by_genre(:express, message, _state) do
    # Acknowledge emotional content with empathy, skip tools
    lower = String.downcase(message)

    response =
      cond do
        Regex.match?(~r/\b(frustrated?|annoyed?|angry|upset|irritated?)\b/, lower) ->
          "I hear you — that sounds frustrating. I'm here to help. What would make things easier right now?"

        Regex.match?(~r/\b(worried|anxious|nervous|scared|overwhelmed)\b/, lower) ->
          "That sounds stressful. Let's take it one step at a time. What's the most pressing thing on your mind?"

        Regex.match?(~r/\b(happy|excited|great|awesome|amazing|love)\b/, lower) ->
          "That's great to hear! How can I help you build on that?"

        true ->
          "I appreciate you sharing that. How can I best support you right now?"
      end

    {:respond, response}
  end

  def route_by_genre(:decide, _message, _state) do
    # Ask a clarifying question before committing to any action
    {:respond,
     "Before I proceed — could you help me understand a bit more? Specifically: what outcome matters most to you here, and are there any constraints I should know about? Once I have that I can give you a more useful recommendation."}
  end

  def route_by_genre(:commit, message, _state) do
    # Surface the implied plan and ask for confirmation before executing
    {:respond,
     "Just to confirm before I proceed: based on what you've said, my plan would be to #{summarize_intent(message)}. Should I go ahead with that?"}
  end

  def route_by_genre(_genre, _message, _state) do
    # :direct or any unknown genre -> normal tool execution
    :execute_tools
  end

  @doc "Extract a short intent summary from the message for the :commit confirmation prompt."
  def summarize_intent(message) do
    words = message |> String.split(~r/\s+/, trim: true) |> Enum.take(12)
    summary = Enum.join(words, " ")
    if String.length(message) > String.length(summary), do: "#{summary}…", else: summary
  end
end
