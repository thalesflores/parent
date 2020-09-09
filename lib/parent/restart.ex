defmodule Parent.Restart do
  alias Parent.State

  # core logic of all restarts, both automatic and manual
  def perform(state, children, opts \\ []) do
    to_start =
      children
      # reject already started children (idempotence)
      |> Stream.reject(&State.child?(state, id: &1.spec.id))
      |> Enum.sort_by(& &1.startup_index)

    {to_start, state} = record_restart(state, to_start)
    {to_start, ignored} = exclude_ignored(to_start, opts)
    {not_started, state, start_error} = return_children(state, to_start)
    {all_ignored, state} = finalize_restart(state, not_started, ignored, start_error)
    {Parent.stopped_children(all_ignored), state}
  end

  defp record_restart(state, children) do
    Enum.flat_map_reduce(
      children,
      state,
      fn
        %{record_restart?: true} = child, state ->
          {child, state} = record_restart!(state, child)
          {[child], state}

        child, state ->
          {[child], state}
      end
    )
  end

  defp record_restart!(state, child) do
    with {:ok, state} <- State.record_restart(state),
         {:ok, restart_counter} <- Parent.RestartCounter.record_restart(child.restart_counter) do
      {%{child | restart_counter: restart_counter}, state}
    else
      _ ->
        Parent.give_up!(state, :too_many_restarts, "Too many restarts in parent process.")
    end
  end

  defp exclude_ignored(to_start, opts) do
    Enum.split_with(
      to_start,
      &(&1[:force_restart?] == true or &1.spec.restart != :temporary or
          Keyword.get(opts, :include_temporary?, false))
    )
  end

  defp return_children(state, []), do: {[], state, nil}

  defp return_children(state, [child | children]) do
    case return_child(state, child) do
      {:ok, state} -> return_children(state, children)
      {:error, start_error} -> {[child | children], state, start_error}
    end
  end

  defp return_child(state, child) do
    case Parent.start_child_process(state, child.spec) do
      {:ok, new_pid, timer_ref} ->
        {:ok, State.reregister_child(state, child, new_pid, timer_ref)}

      :ignore ->
        {:ok, state}

      error ->
        error
    end
  end

  defp shutdown_groups(children) do
    children
    |> Stream.map(& &1.spec.shutdown_group)
    |> Stream.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp stop_children_in_shutdown_groups(state, shutdown_groups) do
    {children_to_stop, state} =
      Enum.reduce(
        shutdown_groups,
        {[], state},
        fn group, {stopped, state} ->
          state
          |> State.children()
          |> Enum.find(&(&1.spec.shutdown_group == group))
          |> case do
            nil ->
              {stopped, state}

            child ->
              {:ok, children, state} =
                State.pop_child_with_bound_siblings(state, id: child.spec.id)

              {[children | stopped], state}
          end
        end
      )

    children_to_stop =
      children_to_stop |> List.flatten() |> Enum.sort_by(& &1.startup_index, :desc)

    Parent.stop_children(children_to_stop, :shutdown)
    {children_to_stop, state}
  end

  defp finalize_restart(state, [], ignored, _start_error),
    do: {ignored, state}

  defp finalize_restart(state, not_started, ignored, start_error) do
    # stop successfully started children which are bound to non-started ones
    {extra_stopped_children, state} =
      stop_children_in_shutdown_groups(state, shutdown_groups(not_started))

    [failed_child | other_children] = not_started

    {ignored, children_to_restart} =
      other_children
      |> Stream.concat(extra_stopped_children)
      |> Stream.concat(ignored)
      |> Stream.map(&Map.put(&1, :exit_reason, :shutdown))
      |> Stream.concat([
        Map.merge(failed_child, %{exit_reason: start_error, record_restart?: true})
      ])
      |> Enum.split_with(&(&1.spec.restart == :temporary))

    unless Enum.empty?(children_to_restart) do
      # some non-temporary children have not been started -> defer auto-restart to later moment
      send(
        self(),
        {Parent, :resume_restart, Parent.stopped_children(children_to_restart)}
      )
    end

    {ignored, state}
  end
end