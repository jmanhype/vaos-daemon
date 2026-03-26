defmodule Daemon.Receipt.VerifierTest do
  use ExUnit.Case, async: true

  alias Daemon.Receipt.Verifier

  # Generate a test Ed25519 keypair using :crypto
  setup_all do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{pub: pub, priv: priv, pub_hex: Base.encode16(pub, case: :lower), priv_raw: priv}
  end

  describe "verify/3" do
    test "accepts valid signature", %{pub: _pub, priv: priv, pub_hex: pub_hex} do
      message = "abc123def456"
      message_bytes = Base.decode16!(message, case: :mixed)
      sig = :crypto.sign(:eddsa, :none, message_bytes, [priv, :ed25519])

      sig_hex = Base.encode16(sig, case: :lower)

      assert Verifier.verify(message, sig_hex, pub_hex)
    end

    test "rejects tampered data", %{pub: _pub, priv: priv, pub_hex: pub_hex} do
      message = "abc123def456"
      message_bytes = Base.decode16!(message, case: :mixed)
      sig = :crypto.sign(:eddsa, :none, message_bytes, [priv, :ed25519])
      sig_hex = Base.encode16(sig, case: :lower)

      # Tamper with the attestation
      tampered = "000000000000"
      refute Verifier.verify(tampered, sig_hex, pub_hex)
    end

    test "rejects wrong key", %{priv: priv} do
      message = "abc123def456"
      message_bytes = Base.decode16!(message, case: :mixed)
      sig = :crypto.sign(:eddsa, :none, message_bytes, [priv, :ed25519])
      sig_hex = Base.encode16(sig, case: :lower)

      # Generate a different keypair
      {wrong_pub, _wrong_priv} = :crypto.generate_key(:eddsa, :ed25519)
      wrong_pub_hex = Base.encode16(wrong_pub, case: :lower)

      refute Verifier.verify(message, sig_hex, wrong_pub_hex)
    end

    test "returns false for invalid hex" do
      refute Verifier.verify("not-hex!", "not-hex!", "not-hex!")
    end
  end
end
