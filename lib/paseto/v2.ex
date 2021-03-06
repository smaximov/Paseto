defmodule Paseto.V2 do
  @moduledoc """
  The Version2 implementation of the Paseto protocol.

  More information about the implementation can be found here:
  1.) https://github.com/paragonie/paseto/blob/master/docs/01-Protocol-Versions/Version2.md

  In short, asymmetric encryption is handled by Ed25519, whereas symmetric encryption is handled by xchachapoly1305
  Libsodium bindings are used for these crypto functions.
  """

  @behaviour Paseto.VersionBehaviour

  alias Paseto.Token
  alias Paseto.Utils.Utils
  alias Paseto.Utils.Crypto
  alias Salty.Sign.Ed25519

  require Logger

  @required_keys [:version, :purpose, :payload]
  @all_keys @required_keys ++ [:footer]

  @enforce_keys @all_keys
  defstruct @all_keys

  @spec from_token(%Token{}) :: %__MODULE__{}
  def from_token(token) do
    %__MODULE__{
      version: token.version,
      purpose: token.purpose,
      payload: token.payload,
      footer: token.footer
    }
  end

  @key_len 32
  @nonce_len_bits 192
  @nonce_len round(@nonce_len_bits / 8)
  @header "v2"

  @doc """
  Handles encrypting the payload and returning a valid token

  # Examples:
      iex> key = <<56, 165, 237, 250, 173, 90, 82, 73, 227, 45, 166, 36, 121, 213, 122, 227, 188, 168, 248, 190, 39, 11, 243, 40, 236, 206, 123, 237, 189, 43, 220, 66>>
      iex> Paseto.V2.encrypt("This is a test message", key)
      "v2.local.voHwaLKK64eSfnCGoJuxJvoyncIpDrg2AkFbRTBeOOBdytn8XoRtl_sRORjlGdTvPageE38TR7dVlv5wxw0"
  """
  @spec encrypt(String.t(), String.t(), String.t()) :: String.t() | {:error, String.t()}
  def encrypt(data, key, footer \\ "") do
    aead_encrypt(data, key, footer)
  end

  @doc """
  Handles decrypting a token payload given the correct key.

  # Examples:
      iex> key = <<56, 165, 237, 250, 173, 90, 82, 73, 227, 45, 166, 36, 121, 213, 122, 227, 188, 168, 248, 190, 39, 11, 243, 40, 236, 206, 123, 237, 189, 43, 220, 66>>
      iex> Paseto.V2.decrypt("AUfxx2uuiOXEXnYlMCzesBUohpewQTQQURBonherEWHcRgnaJfMfZXCt96hciML5PN9ozels1bnPidmFvVc", key)
      {:ok, "This is a test message"}
  """
  @spec decrypt(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def decrypt(data, key, footer \\ "") do
    aead_decrypt(data, key, footer)
  end

  @doc """
  Handles signing the token for public use.

  # Examples:
      iex> {:ok, pk, sk} = Salty.Sign.Ed25519.keypair()
      iex> Paseto.V2.sign("Test Message", sk)
      "v2.public.VGVzdAJxQsXSrgYBkcwiOnWamiattqhhhNN_1jsY-LR_YbsoYpZ18-ogVSxWv7d8DlqzLSz9csqNtSzDk4y0JV5xaAE"
  """
  @spec sign(String.t(), String.t(), String.t()) :: String.t()
  def sign(data, secret_key, footer \\ "") when byte_size(secret_key) == 64 do
    h = "v2.public."
    pre_auth_encode = Utils.pre_auth_encode([h, data, footer])

    {:ok, sig} = Ed25519.sign_detached(pre_auth_encode, secret_key)

    case footer do
      "" -> h <> b64_encode(data <> sig)
      _ -> h <> b64_encode(data <> sig) <> "." <> b64_encode(footer)
    end
  end

  @doc """
  Handles verifying the signature belongs to the provided key.

  # Examples:
      iex> {:ok, pk, sk} = Salty.Sign.Ed25519.keypair()
      iex> Paseto.V2.sign("Test Message", sk)
      "v2.public.VGVzdAJxQsXSrgYBkcwiOnWamiattqhhhNN_1jsY-LR_YbsoYpZ18-ogVSxWv7d8DlqzLSz9csqNtSzDk4y0JV5xaAE"
      iex> Paseto.V2.verify("VGVzdAJxQsXSrgYBkcwiOnWamiattqhhhNN_1jsY-LR_YbsoYpZ18-ogVSxWv7d8DlqzLSz9csqNtSzDk4y0JV5xaAE", pk)
      "{:ok, "Test"}"
  """
  @spec verify(String.t(), String.t(), String.t() | nil) :: {:ok, binary} | {:error, String.t()}
  def verify(signed_message, public_key, footer \\ "") do
    decoded_footer =
      case footer do
        "" -> ""
        _ -> b64_decode!(footer)
      end

    h = "v2.public."
    decoded_message = b64_decode!(signed_message)
    data_size = round(byte_size(decoded_message) * 8 - 512)
    <<data::size(data_size), sig::size(512)>> = decoded_message
    pre_auth_encode = Utils.pre_auth_encode([h, <<data::size(data_size)>>, decoded_footer])

    case Ed25519.verify_detached(<<sig::size(512)>>, pre_auth_encode, public_key) do
      :ok -> {:ok, <<data::size(data_size)>>}
      {:error, _reason} -> {:error, "Failed to verify signature."}
    end
  end

  @doc """
  Allows looking at the claims without having verified them.
  """
  @spec peek(token :: String.t()) :: String.t()
  def peek(token) do
    case String.split(token, ".") do
      [_version, _purpose, payload] ->
        get_claims_from_signed_message(payload)

      [_version, _purpose, payload, _footer] ->
        get_claims_from_signed_message(payload)
    end
  end

  ##############################
  # Internal Private Functions #
  ##############################

  @spec get_claims_from_signed_message(signed_message :: String.t()) :: String.t()
  def get_claims_from_signed_message(signed_message) do
    decoded_message = b64_decode!(signed_message)
    data_size = round(byte_size(decoded_message) * 8 - 512)
    <<data::size(data_size), _sig::size(512)>> = decoded_message

    <<data::size(data_size)>>
  end

  @spec aead_encrypt(String.t(), String.t(), String.t()) :: String.t() | {:error, String.t()}
  defp aead_encrypt(_data, key, _footer) when byte_size(key) != @key_len do
    {:error, "Invalid key length. Expected #{@key_len}, but got #{byte_size(key)}"}
  end

  defp aead_encrypt(data, key, footer) when byte_size(key) == @key_len do
    h = "#{@header}.local."
    n = :crypto.strong_rand_bytes(@nonce_len)
    nonce = Blake2.hash2b(data, @nonce_len, n)
    pre_auth_encode = Utils.pre_auth_encode([h, nonce, footer])

    {:ok, ciphertext} = Crypto.xchacha20_poly1305_encrypt(data, pre_auth_encode, nonce, key)

    case footer do
      "" -> h <> b64_encode(nonce <> ciphertext)
      _ -> h <> b64_encode(nonce <> ciphertext) <> "." <> b64_encode(footer)
    end
  end

  @spec aead_decrypt(String.t(), binary, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp aead_decrypt(_data, key, _footer) when byte_size(key) != @key_len do
    {:error, "Invalid key length. Expected #{@key_len}, but got #{byte_size(key)}"}
  end

  defp aead_decrypt(data, key, footer) when byte_size(key) == @key_len do
    h = "#{@header}.local."
    decoded_payload = b64_decode!(data)

    decoded_footer =
      case footer do
        "" -> ""
        _ -> b64_decode!(footer)
      end

    <<nonce::size(@nonce_len_bits), ciphertext::binary>> = decoded_payload
    pre_auth_encode = Utils.pre_auth_encode([h, <<nonce::size(@nonce_len_bits)>>, decoded_footer])

    case Crypto.xchacha20_poly1305_decrypt(
           ciphertext,
           pre_auth_encode,
           <<nonce::size(@nonce_len_bits)>>,
           key
         ) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, reason} -> {:error, "Failed to decrypt payload due to: #{reason}"}
    end
  end

  @spec b64_encode(binary) :: binary
  defp b64_encode(input) when is_binary(input), do: Base.url_encode64(input, padding: false)

  @spec b64_decode!(binary) :: binary
  defp b64_decode!(input) when is_binary(input), do: Base.url_decode64!(input, padding: false)
end
