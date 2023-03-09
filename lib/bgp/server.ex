defmodule BGP.Server do
  @moduledoc "BGP Server"

  use Supervisor

  alias BGP.FSM

  @type t :: module()

  @server_schema asn: [
                   doc: "Server Autonomous System Number.",
                   type: :pos_integer,
                   required: true
                 ],
                 bgp_id: [
                   doc: "Server BGP ID, IP address as string.",
                   type: {:custom, IP.Address, :from_string, []},
                   required: true
                 ],
                 networks: [
                   doc: "Server AS Networks to announce to peers",
                   type: {:list, {:custom, IP.Prefix, :from_string, []}},
                   default: []
                 ],
                 port: [
                   doc: "Port the server listens on.",
                   type: :integer,
                   default: 179
                 ],
                 peers: [
                   doc: "List of peer configurations (`t:peer_options/0`).",
                   type: {:list, :keyword_list},
                   default: []
                 ]

  @peer_schema as_origination: [
                 type: :keyword_list,
                 keys: [seconds: [doc: "AS Origination timer seconds.", type: :non_neg_integer]],
                 default: [seconds: 15]
               ],
               automatic: [
                 doc: "Automatically start the peering session.",
                 type: :boolean,
                 default: true
               ],
               asn: [
                 doc: "Peer Autonomous System Number.",
                 type: :pos_integer,
                 default: 23_456
               ],
               bgp_id: [
                 doc: "Peer BGP ID, IP address.",
                 type: :string,
                 required: true
               ],
               connect_retry: [
                 type: :keyword_list,
                 keys: [
                   seconds: [doc: "Connect Retry timer seconds.", type: :non_neg_integer]
                 ],
                 default: [seconds: 120]
               ],
               delay_open: [
                 type: :keyword_list,
                 keys: [
                   enabled: [doc: "Enable Delay OPEN.", type: :boolean],
                   seconds: [doc: "Delay OPEN timer seconds.", type: :non_neg_integer]
                 ],
                 default: [enabled: true, seconds: 5]
               ],
               hold_time: [
                 type: :keyword_list,
                 keys: [seconds: [doc: "Hold Time timer seconds.", type: :non_neg_integer]],
                 default: [seconds: 90]
               ],
               host: [
                 doc: "Peer IP address as string.",
                 type: {:custom, IP.Address, :from_string, []},
                 required: true
               ],
               keep_alive: [
                 type: :keyword_list,
                 keys: [seconds: [doc: "Keep Alive timer seconds.", type: :non_neg_integer]],
                 default: [seconds: 30]
               ],
               notification_without_open: [
                 doc: "Allows NOTIFICATIONS to be received without OPEN first.",
                 type: :boolean,
                 default: true
               ],
               mode: [
                 doc: "Actively connects to the peer or just waits for a connection.",
                 type: {:in, [:active, :passive]},
                 default: :active
               ],
               port: [
                 doc: "Peer TCP port.",
                 type: :integer,
                 default: 179
               ],
               route_advertisement: [
                 type: :keyword_list,
                 keys: [
                   seconds: [doc: "Route Advertisement timer seconds.", type: :non_neg_integer]
                 ],
                 default: [seconds: 30]
               ]

  @typedoc """
  Server options

  #{NimbleOptions.docs(@server_schema)}
  """
  @type options :: keyword()

  @typedoc """
  Peer options

  #{NimbleOptions.docs(@peer_schema)}
  """
  @type peer_options :: keyword()
  defmacro __using__(otp_app: otp_app) when is_atom(otp_app) do
    quote do
      @__otp_app__ unquote(otp_app)
      def __otp_app__, do: @__otp_app__
    end
  end

  defmacro __using__(_args) do
    raise "You must pass a module name to #{__MODULE__} :otp_app option"
  end

  def child_spec([server: server] = opts) do
    %{id: server, type: :supervisor, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(server: server) do
    Supervisor.start_link(__MODULE__, get_config(server), name: server)
  end

  @spec get_config(t()) :: keyword()
  def get_config(server) do
    server.__otp_app__()
    |> Application.get_env(server, [])
    |> NimbleOptions.validate!(@server_schema)
    |> Keyword.put(:server, server)
  end

  @spec get_peer(t(), IP.Address.t()) :: {:ok, keyword()} | {:error, :not_found}
  def get_peer(server, host) do
    server
    |> get_config()
    |> Keyword.get(:peers, [])
    |> Enum.find_value({:error, :not_found}, fn peer ->
      options =
        peer
        |> NimbleOptions.validate!(@peer_schema)
        |> Keyword.put(:server, server)

      if host == options[:host] do
        {:ok, options}
      else
        nil
      end
    end)
  end

  @impl Supervisor
  def init(args) do
    server = args[:server]

    peers =
      Enum.map(
        args[:peers],
        &{BGP.Server.Session,
         &1
         |> NimbleOptions.validate!(@peer_schema)
         |> Keyword.put(:server, server)}
      )

    Supervisor.init(
      [
        {Registry, keys: :unique, name: Module.concat(server, Listener.Registry)},
        {Registry, keys: :unique, name: Module.concat(server, Session.Registry)},
        {BGP.Server.RDE, server: server},
        {
          ThousandIsland,
          port: args[:port], handler_module: BGP.Server.Listener, handler_options: server
        }
        | peers
      ],
      strategy: :one_for_all
    )
  end

  @spec check_collision(FSM.t(), BGP.bgp_id()) ::
          :ok | {:error, :collision | :close}
  def check_open_collision_dump(%FSM{state: :established}, _peer_bgp_id),
    do: {:error, :collision}

  def check_collision(%FSM{state: state} = fsm, peer_bgp_id)
      when state in [:open_confirm, :open_sent] and fsm.bgp_id > peer_bgp_id do
    {:error, :collision}
  end

  def check_collision(%FSM{state: state}, _peer_bgp_id)
      when state in [:open_confirm, :open_sent],
      do: {:error, :close}

  def check_collision(_fsm, _peer_bgp_id), do: :ok
end
