defmodule Phoenix.LiveView.UploadChannel do
  @moduledoc false
  use Phoenix.Channel, log_handle_in: false

  require Logger

  alias Phoenix.LiveView.{Static, Channel}

  def cancel(pid) do
    Logger.warn("[LiveView - Channel] cancel")
    GenServer.call(pid, :cancel)
  end

  def consume(pid, entry, func) when is_function(func, 1) or is_function(func, 2) do
    Logger.warn("[LiveView - Channel] consume #{inspect(entry)}")

    case GenServer.call(pid, {:consume, entry, func}) do
      {:ok, result} ->
        result

      {:error, :in_progress} ->
        raise RuntimeError, "cannot consume uploaded file that is still in progress"
    end
  end

  @impl true
  def join(_topic, auth_payload, socket) do
    Logger.warn("[LiveView - Channel] join")
    %{"token" => token} = auth_payload

    with {:ok, %{pid: pid, ref: ref}} <- Static.verify_token(socket.endpoint, token),
         {:ok, config} <- Channel.register_upload(pid, ref),
         %{max_file_size: max_file_size, chunk_timeout: chunk_timeout} = config,
         {:ok, path} <- Plug.Upload.random_file("live_view_upload"),
         {:ok, handle} <- File.open(path, [:binary, :write]) do
      Process.monitor(pid)

      socket =
        assign(socket, %{
          path: path,
          handle: handle,
          live_view_pid: pid,
          max_file_size: max_file_size,
          chunk_timeout: chunk_timeout,
          chunk_timer: nil,
          done?: false,
          uploaded_size: 0
        })

      {:ok, socket}
    else
      {:error, :limit_exceeded} -> {:error, %{reason: :limit_exceeded}}
      _ -> {:error, %{reason: :invalid_token}}
    end
  end

  @impl true
  def handle_in("chunk", {:binary, payload}, socket) do
    Logger.warn("[LiveView - Channel] handle_in #{inspect(payload)}")
    %{uploaded_size: uploaded_size, max_file_size: max_file_size} = socket.assigns
    socket = reschedule_chunk_timer(socket)

    if byte_size(payload) + uploaded_size <= max_file_size do
      {:reply, :ok, write_bytes(socket, payload)}
    else
      reply = %{reason: :file_size_limit_exceeded, limit: max_file_size}
      {:stop, {:shutdown, :closed}, {:error, reply}, socket}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, _, _, live_view_pid, reason},
        %{assigns: %{live_view_pid: live_view_pid}} = socket
      ) do
    Logger.warn("[LiveView - Channel] handle_info DOWN")
    reason = if reason == :normal, do: {:shutdown, :closed}, else: reason
    {:stop, reason, socket}
  end

  def handle_info(:chunk_timeout, socket) do
    Logger.warn("[LiveView - Channel] handle_info :chunk_timeout")
    {:stop, {:shutdown, :closed}, socket}
  end

  @impl true
  def handle_call({:consume, entry, func}, from, socket) do
    Logger.warn("[LiveView - Channel] handle_call :consume")

    if socket.assigns.done? do
      result =
        cond do
          is_function(func, 1) -> func.(file_meta(socket))
          is_function(func, 2) -> func.(file_meta(socket), entry)
        end

      GenServer.reply(from, {:ok, result})
    else
      GenServer.reply(from, {:error, :in_progress})
    end

    {:stop, {:shutdown, :closed}, socket}
  end

  def handle_call(:cancel, from, socket) do
    Logger.warn("[LiveView - Channel] handle_call :cancel")
    new_socket = close_file(socket)
    GenServer.reply(from, :ok)
    {:stop, {:shutdown, :closed}, new_socket}
  end

  defp reschedule_chunk_timer(socket) do
    timer = socket.assigns.chunk_timer
    if timer, do: Process.cancel_timer(timer)
    new_timer = Process.send_after(self(), :chunk_timeout, socket.assigns.chunk_timeout)
    assign(socket, :chunk_timer, new_timer)
  end

  defp write_bytes(socket, payload) do
    IO.binwrite(socket.assigns.handle, payload)
    socket = assign(socket, :uploaded_size, socket.assigns.uploaded_size + byte_size(payload))

    if socket.assigns.uploaded_size == socket.assigns.max_file_size do
      socket
      |> close_file()
      |> assign(:done?, true)
    else
      socket
    end
  end

  defp close_file(socket) do
    File.close(socket.assigns.handle)
    if socket.assigns.chunk_timer, do: Process.cancel_timer(socket.assigns.chunk_timer)

    socket
    |> assign(:chunk_timer, nil)
    |> garbage_collect()
  end

  defp garbage_collect(socket) do
    send(socket.transport_pid, :garbage_collect)
    :erlang.garbage_collect(self())

    socket
  end

  defp file_meta(socket), do: %{path: socket.assigns.path}
end
