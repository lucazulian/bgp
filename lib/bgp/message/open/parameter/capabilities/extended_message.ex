defmodule BGP.Message.OPEN.Parameter.Capabilities.ExtendedMessage do
  @moduledoc false

  @type t :: %__MODULE__{}
  defstruct []

  alias BGP.Message.Encoder

  @behaviour Encoder

  @impl Encoder
  def decode(<<>>, _fsm), do: %__MODULE__{}

  @impl Encoder
  def encode(_multi_protocol, _fsm), do: []
end
