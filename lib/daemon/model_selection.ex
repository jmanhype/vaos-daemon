defmodule Daemon.ModelSelection do
  @moduledoc false

  alias MiosaProviders.Registry, as: Providers

  def current_provider do
    Application.get_env(:daemon, :default_provider, :ollama)
  end

  def current_provider_and_model do
    provider = current_provider()
    {provider, current_model(provider)}
  end

  def current_model(provider \\ current_provider())

  def current_model(provider) when is_atom(provider) do
    provider_model = Application.get_env(:daemon, :"#{provider}_model")
    default_model = Application.get_env(:daemon, :default_model)
    provider_default = default_model_for(provider)

    cond do
      provider_override_active?(default_model, provider_model, provider_default) ->
        provider_model

      present?(default_model) ->
        default_model

      present?(provider_model) ->
        provider_model

      true ->
        provider_default
    end
  end

  def current_model(_), do: Application.get_env(:daemon, :default_model)

  def context_window(model \\ current_model()) do
    case model do
      nil ->
        nil

      model_name ->
        Providers.context_window(to_string(model_name))
    end
  rescue
    _ -> nil
  end

  defp default_model_for(nil), do: nil

  defp default_model_for(provider) do
    case Providers.provider_info(provider) do
      {:ok, info} -> info.default_model
      _ -> nil
    end
  end

  defp provider_override_active?(default_model, provider_model, provider_default) do
    present?(provider_model) and
      present?(default_model) and
      default_model == provider_default and
      provider_model != default_model
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)
end
