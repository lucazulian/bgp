defmodule BGP.Message.OPEN.Parameter.Capabilities do
  @moduledoc false

  alias BGP.Message.{Encoder, NOTIFICATION}

  alias BGP.Message.OPEN.Parameter.Capabilities.{
    FourOctetsASN,
    GracefulRestart,
    MultiProtocol,
    RouteRefresh
  }

  @type t :: %__MODULE__{capabilities: [struct()]}

  @enforce_keys [:capabilities]
  defstruct capabilities: []

  @behaviour Encoder

  @impl Encoder
  def decode(data, fsm),
    do: %__MODULE__{capabilities: decode_capabilities(data, [], fsm)}

  defp decode_capabilities(<<>>, capabilities, _fsm), do: Enum.reverse(capabilities)

  defp decode_capabilities(
         <<code::8, length::8, value::binary-size(length), rest::binary>>,
         capabilities,
         fsm
       ) do
    capability = module_for_type(code).decode(value, fsm)
    decode_capabilities(rest, [capability | capabilities], fsm)
  end

  @impl Encoder
  def encode(%__MODULE__{capabilities: capabilities}, fsm) do
    Enum.map(capabilities, fn %module{} = capability ->
      data = module.encode(capability, fsm)

      [<<type_for_module(module)::8>>, <<IO.iodata_length(data)::8>>, data]
    end)
  end

  attributes = [
    {MultiProtocol, 1},
    {RouteRefresh, 2},
    {ExtendedMessage, 6},
    {GracefulRestart, 64},
    {FourOctetsASN, 65},
    {EnanchedRouteRefresh, 70}
  ]

  for {module, code} <- attributes do
    defp type_for_module(unquote(module)), do: unquote(code)
  end

  defp type_for_module(_module) do
    raise NOTIFICATION, code: :open_message
  end

  for {module, code} <- attributes do
    defp module_for_type(unquote(code)), do: unquote(module)
  end

  defp module_for_type(_code) do
    raise NOTIFICATION, code: :open_message
  end
end
