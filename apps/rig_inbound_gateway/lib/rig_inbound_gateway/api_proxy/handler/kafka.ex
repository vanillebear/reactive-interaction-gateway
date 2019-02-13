defmodule RigInboundGateway.ApiProxy.Handler.Kafka do
  @moduledoc """
  Handles requests for Kafka targets.

  """
  use Rig.KafkaConsumerSetup, [:cors, :request_topic, :request_schema, :response_timeout]

  alias Plug.Conn

  alias RigInboundGateway.ApiProxy.Handler
  @behaviour Handler

  alias Rig.Connection.Codec

  @help_text """
  Produce the request to a Kafka topic and optionally wait for the (correlated) response.

  Expects a JSON encoded HTTP body with the following fields:

  - `event`: The published CloudEvent >= v0.2. The event is extended by metadata
  written to the "rig" extension field (following the CloudEvents v0.2 spec).
  - `partition`: The targetted Kafka partition.

  """

  # ---

  def validate(conf), do: {:ok, conf}

  # ---

  def kafka_handler(message) do
    with {:ok, body} <- Jason.decode(message),
         {:ok, rig_metadata} <- Map.fetch(body, "rig"),
         {:ok, correlation_id} <- Map.fetch(rig_metadata, "correlation"),
         {:ok, deserialized_pid} <- Codec.deserialize(correlation_id) do
      Logger.debug(fn ->
        "HTTP response via Kafka to #{inspect(deserialized_pid)}: #{inspect(message)}"
      end)

      send(deserialized_pid, {:response_received, message})
    else
      err ->
        Logger.warn(fn -> "Parse error #{inspect(err)} for #{inspect(message)}" end)
        :ignore
    end

    :ok
  rescue
    err -> {:error, err, message}
  end

  # ---

  @impl Handler
  def handle_http_request(conn, api, endpoint, request_path)

  @doc "CORS response for preflight request."
  def handle_http_request(%{method: "OPTIONS"} = conn, _, %{"target" => "kafka"}, _) do
    conn
    |> with_cors()
    |> Conn.send_resp(:no_content, "")
  end

  @doc @help_text
  def handle_http_request(
        %{params: %{"partition" => partition, "event" => event}} = conn,
        _,
        %{"target" => "kafka"} = endpoint,
        request_path
      ) do
    kafka_message =
      event
      |> Map.put("rig", %{
        correlation: Codec.serialize(self()),
        remoteip: to_string(:inet_parse.ntoa(conn.remote_ip)),
        host: conn.host,
        port: conn.port,
        scheme: conn.scheme,
        headers: Enum.map(conn.req_headers, &Tuple.to_list(&1)),
        method: conn.method,
        path: request_path,
        query: conn.query_string
      })
      |> Poison.encode!()

    produce(partition, kafka_message)

    wait_for_response? =
      case Map.get(endpoint, "response_from") do
        "kafka" -> true
        _ -> false
      end

    if wait_for_response? do
      wait_for_response(conn)
    else
      Conn.send_resp(conn, :accepted, "Accepted.")
    end
  end

  def handle_http_request(conn, _, %{"target" => "kafka"}, _) do
    response = """
    Bad request: missing expected body parameters.

    # Usage

    #{@help_text}
    """

    Conn.send_resp(conn, :bad_request, response)
  end

  # ---

  defp wait_for_response(conn) do
    conf = config()

    receive do
      {:response_received, response} ->
        conn
        |> with_cors()
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(:ok, response)
    after
      conf.response_timeout ->
        conn
        |> with_cors()
        |> Conn.send_resp(:gateway_timeout, "")
    end
  end

  # ---

  defp produce(server \\ __MODULE__, key, plaintext) do
    GenServer.call(server, {:produce, key, plaintext})
  end

  # ---

  @impl GenServer
  def handle_call({:produce, key, plaintext}, _from, %{kafka_config: kafka_config} = state) do
    %{request_topic: topic, request_schema: schema} = config()
    res = RigKafka.produce(kafka_config, topic, schema, key, plaintext)
    {:reply, res, state}
  end

  # ---

  defp with_cors(conn) do
    conn
    |> Conn.put_resp_header("access-control-allow-origin", config().cors)
    |> Conn.put_resp_header("access-control-allow-methods", "*")
    |> Conn.put_resp_header("access-control-allow-headers", "content-type,authorization")
  end
end
