defmodule PhoenixClient.Transports.LongPoll do
  @behaviour PhoenixClient.Transport

  use GenServer

  require Logger

  @poll_timeout 25_000

  def open(url, transport_opts) do
    GenServer.start_link(__MODULE__, [url, transport_opts])
  end

  def close(pid) do
    :ok = GenServer.cast(pid, :close)

    {:ok, :closed}
  end

  def init([url, opts]) do
    # Convert ws:// or wss:// to http:// or https:// and change path from /websocket to /longpoll
    poll_url =
      url
      |> String.replace("ws://", "http://")
      |> String.replace("wss://", "https://")
      |> String.replace(~r/(.*?)\/websocket/, "\\1/longpoll")

    sender = opts[:sender]

    # Parse URL to get base URL for Tesla client
    uri = URI.parse(poll_url)
    auth_token = URI.decode_query(uri.query || "") |> Map.fetch!("auth_token")

    uri = uri |> delete_query_param("auth_token")
    base_url = "#{uri.scheme}://#{uri.authority}"

    # Create Tesla client with Finch adapter for keep-alive connections
    client =
      Tesla.client([
        {Tesla.Middleware.BaseUrl, base_url},
        {Tesla.Middleware.Headers, [
          {"x-phoenix-authtoken", auth_token},
          {"content-type", "application/x-ndjson"},
          {"accept", "application/json"}
        ]},
        {Tesla.Middleware.Timeout, timeout: @poll_timeout}
      ],
        {Tesla.Adapter.Finch, name: Stressgrid.Generator.Finch} # requires running Finch registry
      )

    state = %{
      poll_uri: uri,
      sender: sender,
      token: nil,
      status: :connecting,
      pending_messages: [],
      batch_task_ref: nil,
      awaiting_batch_ack: false,
      opts: opts,
      client: client
    }

    # schedule first poll
    GenServer.cast(self(), :poll)

    {:ok, state}
  end

  def handle_info({:send, msg}, state) do
    {:noreply, queue_message(msg, state)}
  end

  def handle_info({_ref, {:polling_response, response}}, state) do
    state = case response do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded_body} ->
            handle_poll_response(decoded_body, state)

          {:error, reason} ->
            Logger.error("Failed to decode poll response: #{body} - #{reason}")

            %{state | status: :disconnected}
        end

      {:ok, %Tesla.Env{status: status_code, body: _body}} ->
        notify_disconnected(state, {:unhandled_status, status_code})

        %{state | status: :disconnected}

      {:error, reason} ->
        if state.status == :connecting do
          notify_disconnected(state, reason)
        end

        %{state | status: :disconnected}
    end

    {:noreply, state}
  end

  def handle_info({_ref, {:send_batch_response, response}}, state) do
    updated_state = case response do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"status" => status}} when status in [200, 410] ->
            %{
              state
            | pending_messages: [],
              batch_task_ref: nil,
              awaiting_batch_ack: false
            }

          result ->
            %{
              state
            | batch_task_ref: nil,
              awaiting_batch_ack: false
            }
        end

      {:error, reason} ->
        Logger.error("Batch send failed: #{inspect(reason)}")

        notify_disconnected(state, reason)

        %{
          state
        | status: :disconnected,
          batch_task_ref: nil,
          awaiting_batch_ack: false
        }
    end

    {:noreply, updated_state}
  end

  # handler for Task DOWN messages
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_cast(:poll, state) do
    {:noreply, poll(state)}
  end

  def handle_cast({:poll, state_patch}, state) do
    {:noreply, poll(Map.merge(state, state_patch))}
  end

  def handle_cast(:close, state) do
    notify_closed(state, :normal)

    {:noreply, state}
  end

  defp poll(%{status: :closed} = state), do: state

  defp poll(state) do
    Task.async(fn ->
      {:polling_response, Tesla.get(state.client, resolve_path_and_query(state))}
    end)

    state
  end

  defp handle_poll_response(%{"status" => 200, "token" => token, "messages" => messages}, state) do
    # Deliver messages to sender
    Enum.each(messages, fn msg ->
      send(state.sender, {:receive, msg})
    end)

    GenServer.cast(self(), :poll)

    %{state | token: token}
  end

  defp handle_poll_response(%{"status" => 204} = body, state) do
    # the response may or may not contain messages
    if body["messages"] do
      # Deliver messages to sender
      Enum.each(body["messages"], fn msg ->
        send(state.sender, {:receive, msg})
      end)
    end

    GenServer.cast(self(), :poll)

    case body do
      %{"token" => token} ->
        %{state | token: token}
      _ ->
        state
    end
  end

  defp handle_poll_response(%{"status" => 410, "token" => token} = body, state) do
    if state.status == :connecting do
      notify_connected(state)
    end

    # the response may or may not contain messages
    if body["messages"] do
      # Deliver messages to sender
      Enum.each(body["messages"], fn msg ->
        send(state.sender, {:receive, msg})
      end)
    end

    GenServer.cast(self(), :poll)

    %{state | token: token, status: :connected}
  end

  defp handle_poll_response(%{"status" => 403}, state) do
    Logger.error("Forbidden (403)")

    notify_closed(state, :forbidden)

    %{state | status: :closed}
  end

  defp handle_poll_response(%{"status" => 500}, state) do
    Logger.error("Internal server error (500)")

    notify_disconnected(state, :internal_server_error)

    %{state | status: :disconnected}
  end

  defp queue_message(msg, state) do
    cond do
      state.batch_task_ref != nil ->
        # Timer already running, add to pending messages
        %{state | pending_messages: [msg | state.pending_messages]}

      state.awaiting_batch_ack ->
        # Waiting for previous batch to complete
        %{state | pending_messages: [msg | state.pending_messages]}

      true ->
        send_batch(%{state | pending_messages: [msg | state.pending_messages]})
    end
  end

  defp send_batch(%{pending_messages: []} = state), do: state

  defp send_batch(state) do
    # Join messages with newlines for x-ndjson format
    body = Enum.reverse(state.pending_messages) |> Enum.join("\n")

    task_ref = Task.async(fn ->
      {:send_batch_response, Tesla.post(state.client, resolve_path_and_query(state), body)}
    end)

    %{state | batch_task_ref: task_ref, awaiting_batch_ack: true}
  end

  defp notify_connected(state) do
    send(state.sender, {:connected, self()})
  end

  defp notify_disconnected(state, reason) do
    send(state.sender, {:disconnected, reason, self()})
  end

  defp notify_closed(state, reason) do
    send(state.sender, {:closed, reason, self()})
  end

  defp resolve_path_and_query(state) do
    poll_uri =
      if state.token do
        replace_query_param(state.poll_uri, "token", state.token)
      else
        state.poll_uri
      end

    "#{poll_uri.path}?#{poll_uri.query}"
  end

  defp replace_query_param(uri, key, value) do
    new_query_string = URI.decode_query(uri.query || "")
                       |> Map.put(key, value)
                       |> URI.encode_query()

    %URI{uri | query: new_query_string}
  end

  defp delete_query_param(uri, key) do
    new_query_string = URI.decode_query(uri.query || "")
                       |> Map.delete(key)
                       |> URI.encode_query()

    %URI{uri | query: new_query_string}
  end
end
