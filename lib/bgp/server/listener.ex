defmodule BGP.Server.Listener do
  @moduledoc false

  alias ThousandIsland.{Handler, Socket}

  use Handler

  alias BGP.{Message, Prefix, Server}
  alias BGP.Message.{Encoder, OPEN}
  alias BGP.Server.{FSM, Session}

  require Logger

  @type t :: GenServer.server()

  @spec connection_for(Server.t(), Prefix.t()) :: {:ok, GenServer.server()} | {:error, :not_found}
  def connection_for(server, host) do
    case Registry.lookup(BGP.Server.Listener.Registry, {server, host}) do
      [] -> {:error, :not_found}
      [{pid, _value}] -> {:ok, pid}
    end
  end

  @spec outbound_connection(t(), Prefix.t()) :: :ok | {:error, :collision}
  def outbound_connection(handler, peer_bgp_id),
    do: GenServer.call(handler, {:outbound_connection, peer_bgp_id})

  @impl Handler
  def handle_connection(socket, server: server) do
    state = %{buffer: <<>>, fsm: FSM.new(Server.get_config(server)), server: server}
    %{address: address} = Socket.peer_info(socket)

    with {:ok, peer} <- get_configured_peer(state, server, address),
         {:ok, state} <- trigger_event(state, socket, {:start, :automatic, :passive}),
         {:ok, state} <- trigger_event(state, socket, {:tcp_connection, :confirmed}),
         :ok <- register_handler(state, server, peer),
         do: {:continue, state}
  end

  @impl Handler
  def handle_data(data, socket, %{buffer: buffer} = state) do
    (buffer <> data)
    |> Message.stream!()
    |> Enum.reduce({:continue, state}, fn {rest, msg}, {:continue, state} ->
      with {:ok, state} <- trigger_event(state, socket, {:msg, msg, :recv}),
           do: {:continue, %{state | buffer: rest}}
    end)
  catch
    %Encoder.Error{} = error ->
      data = Message.encode(Encoder.Error.to_notification(error), [])
      process_effect(state, socket, {:msg, data, :send})
      {:close, state}
  end

  @impl GenServer
  def handle_info({:timer, _timer, :expires} = event, {socket, state}) do
    with {:ok, state} <- trigger_event(state, socket, event),
         do: {:noreply, {socket, state}}
  end

  @impl GenServer
  def handle_call(
        {:incoming_connection, peer_bgp_id},
        _from,
        {socket, %{options: options} = state}
      ) do
    server_bgp_id =
      options
      |> Keyword.get(:server)
      |> Server.get_config(:bgp_id)

    if server_bgp_id > peer_bgp_id do
      {:reply, {:error, :collision}, state}
    else
      Logger.warn("LISTENER: closing conenction to peer due to collision")

      with {:ok, state} <- trigger_event(state, socket, {:open, :collision_dump}),
           do: {:reply, :ok, state}
    end
  end

  defp get_configured_peer(state, server, address) do
    case Server.get_peer(server, address) do
      {:ok, peer} ->
        {:ok, peer}

      {:error, :not_found} ->
        Logger.warn("LISTENER: dropping connection, no configured peer for #{inspect(address)}")
        {:close, state}
    end
  end

  defp register_handler(state, server, peer) do
    host = Keyword.get(peer, :host)

    case Registry.register(BGP.Server.Listener.Registry, {server, host}, nil) do
      {:ok, _pid} ->
        :ok

      {:error, _reason} ->
        Logger.warn("LISTENER: dropping connection, connection already exists for #{host}")
        {:close, state}
    end
  end

  defp trigger_event(%{fsm: fsm} = state, socket, event) do
    Logger.debug("LISTENER: Triggering FSM event: #{inspect(event)}")

    with {:ok, fsm, effects} <- FSM.event(fsm, event),
         do: process_effects(%{state | fsm: fsm}, socket, effects)
  end

  defp process_effects(state, socket, effects) do
    Logger.debug("LISTENER: Processing FSM effects: #{inspect(effects)}")

    Enum.reduce(effects, {:ok, state}, fn effect, return ->
      case process_effect(state, socket, effect) do
        :ok ->
          return

        {action, _reason} ->
          {action, state}
      end
    end)
  end

  defp process_effect(%{server: server} = state, socket, {:msg, %OPEN{bgp_id: bgp_id}, :recv}) do
    %{address: address} = Socket.peer_info(socket)

    case Session.session_for(server, address) do
      {:ok, session} ->
        case Session.incoming_connection(session, bgp_id) do
          :ok ->
            :ok

          {:error, :collision} ->
            Logger.warn("Connection from peer #{address} collides, closing")

            with {:ok, _state} <- trigger_event(state, socket, {:open, :collision_dump}),
                 do: {:close, :collision}
        end

      {:error, :not_found} ->
        Logger.warn("No configured session for peer #{address}, closing")
        {:close, :no_session}
    end
  end

  defp process_effect(_state, _socket, {:msg, _msg, :recv}), do: :ok

  defp process_effect(_state, socket, {:msg, data, :send}) do
    case Socket.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:close, reason}
    end
  end

  defp process_effect(_state, _socket, {:tcp_connection, :disconnect}), do: {:close, :disconnect}
end