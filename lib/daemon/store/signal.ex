defmodule Daemon.Store.Signal do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :session_id,
             :channel,
             :mode,
             :genre,
             :type,
             :format,
             :weight,
             :tier,
             :input_preview,
             :agent_name,
             :confidence,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "signals" do
    field(:session_id, :string)
    field(:channel, :string)
    field(:mode, :string)
    field(:genre, :string)
    field(:type, :string, default: "general")
    field(:format, :string)
    field(:weight, :float, default: 0.5)
    field(:tier, :string)
    field(:input_preview, :string)
    field(:agent_name, :string)
    field(:confidence, :string, default: "high")
    field(:metadata, :map, default: %{})
    timestamps()
  end

  @required_fields [:channel, :mode, :genre, :format, :weight]
  @optional_fields [
    :session_id,
    :type,
    :tier,
    :input_preview,
    :agent_name,
    :confidence,
    :metadata
  ]

  @valid_modes ~w(build execute analyze maintain assist)
  @valid_genres ~w(direct inform commit decide express)
  @valid_formats ~w(command message notification document text)
  @valid_tiers ~w(haiku sonnet opus)
  @valid_confidence ~w(high low)

  def changeset(signal \\ %__MODULE__{}, attrs) do
    signal
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:mode, @valid_modes)
    |> validate_inclusion(:genre, @valid_genres)
    |> validate_inclusion(:format, @valid_formats)
    |> validate_inclusion(:tier, @valid_tiers)
    |> validate_inclusion(:confidence, @valid_confidence)
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> derive_tier()
  end

  defp derive_tier(changeset) do
    case get_field(changeset, :weight) do
      w when is_float(w) and w < 0.35 -> put_change(changeset, :tier, "haiku")
      w when is_float(w) and w < 0.65 -> put_change(changeset, :tier, "sonnet")
      w when is_float(w) -> put_change(changeset, :tier, "opus")
      _ -> changeset
    end
  end
end
