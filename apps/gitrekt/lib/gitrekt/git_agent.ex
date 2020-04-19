defmodule GitRekt.GitAgent do
  @moduledoc ~S"""
  High-level API for running Git commands on a repository.

  This module provides an API to manipulate Git repositories. In contrast to `GitRekt.Git`, it offers
  an abstraction for serializing Git commands via message passing. By doing so it allows multiple processes
  to manipulate a single repository simultaneously.

  At it core `GitRekt.GitAgent` implements `GenServer`. Therefore it makes it easy to fit into a supervision
  tree and furthermore, in a distributed environment.

  An other major benefit is support for caching command results. In their nature Git objects are immutable;
  that is, once they have been created and stored in the data store, they cannot be modified. This allows for
  very naive caching strategy implementations without having to deal with cache invalidation.

  ## Example

  Let's start by rewriting the example exposed in the `GitRekt.Git` module:

  ```elixir
  alias GitRekt.GitAgent

  # load repository
  {:ok, agent} = GitAgent.start_link("tmp/my-repo.git")

  # fetch master branch
  {:ok, branch} = GitAgent.branch(agent, "master")

  # fetch commit pointed by master
  {:ok, commit} = GitAgent.peel(agent, branch)

  # fetch commit author & message
  {:ok, author} = GitAgent.commit_author(agent, commit)
  {:ok, message} = GitAgent.commit_message(agent, commit)

  IO.puts "Last commit by #{author.name} <#{author.email}>:"
  IO.puts message
  ```

  This look very similar to the original example altought the API is slightly different.

  By swapping `GitRekt.Git.repository_open/1` with `start_link/1`, we are not working with the underlying
  `t:GitRekt.Git.repo/0` anymore. Instead we use a dedicated process and serialize Git commands via message
  passing; allowing multiple processes to access the repository simultaneously.
  """
  use GenServer

  alias GitRekt.{
    Git,
    GitRepo,
    GitOdb,
    GitCommit,
    GitRef,
    GitTag,
    GitBlob,
    GitTree,
    GitTreeEntry,
    GitIndex,
    GitIndexEntry,
    GitDiff
  }

  @behaviour GitRekt.GitAgent.Cache

  @type agent :: Git.repo | GitRepo.t | pid

  @type git_odb :: GitOdb.t
  @type git_object :: GitCommit.t | GitBlob.t | GitTree.t | GitTag.t
  @type git_reference :: GitRef.t
  @type git_revision :: GitRef.t | GitTag.t | GitCommit.t

  @default_config %{
      cache: __MODULE__,
      idle_timeout: :infinity
  }

  @doc """
  Starts a Git agent linked to the current process for the repository at the given `path`.
  """
  @spec start_link(Path.t, keyword) :: GenServer.on_start
  def start_link(path, opts \\ []) do
    {agent_opts, server_opts} = Keyword.split(opts, Map.keys(@default_config))
    GenServer.start_link(__MODULE__, {path, agent_opts}, server_opts)
  end

  @doc """
  Returns `true` if the repository is empty; otherwise returns `false`.
  """
  @spec empty?(agent) :: {:ok, boolean} | {:error, term}
  def empty?(agent), do: exec(agent, :empty?)

  @doc """
  Returns the ODB.
  """
  @spec odb(agent) :: {:ok, git_odb}
  def odb(agent), do: exec(agent, :odb)

  @doc """
  Return the raw data of the `odb` object with the given `oid`.
  """
  @spec odb_read(agent, git_odb, Git.oid) :: {:ok, map} | {:error, term}
  def odb_read(agent, odb, oid), do: exec(agent, {:odb_read, odb, oid})

  @doc """
  Writes the given `data` into the `odb`.
  """
  @spec odb_write(agent, git_odb, binary, atom) :: {:ok, Git.oid} | {:error, term}
  def odb_write(agent, odb, data, type), do: exec(agent, {:odb_write, odb, data, type})

  @doc """
  Returns `true` if the given `oid` exists in `odb`; elsewhise returns `false`.
  """
  @spec odb_object_exists?(agent, git_odb, Git.oid) :: boolean
  def odb_object_exists?(agent, odb, oid), do: exec(agent, {:odb_object_exists?, odb, oid})

  @doc """
  Returns the Git reference for `HEAD`.
  """
  @spec head(agent) :: {:ok, git_reference} | {:error, term}
  def head(agent), do: exec(agent, :head)

  @doc """
  Returns all Git branches.
  """
  @spec branches(agent) :: {:ok, [git_reference]} | {:error, term}
  def branches(agent), do: exec(agent, {:references, "refs/heads/*"})

  @doc """
  Returns the Git branch with the given `name`.
  """
  @spec branch(agent, binary) :: {:ok, git_reference} | {:error, term}
  def branch(agent, name), do: exec(agent, {:reference, "refs/heads/" <> name})

  @doc """
  Returns all Git tags.
  """
  @spec tags(agent) :: {:ok, [GitTag.t]} | {:error, term}
  def tags(agent), do: exec(agent, {:references, "refs/tags/*"})

  @doc """
  Returns the Git tag with the given `name`.
  """
  @spec tag(agent, binary) :: {:ok, GitTag.t} | {:error, term}
  def tag(agent, name), do: exec(agent, {:reference, "refs/tags/" <> name})

  @doc """
  Returns the Git tag author of the given `tag`.
  """
  @spec tag_author(agent, GitTag.t) :: {:ok, map} | {:error, term}
  def tag_author(agent, tag), do: exec(agent, {:author, tag})

  @doc """
  Returns the Git tag message of the given `tag`.
  """
  @spec tag_message(agent, GitTag.t) :: {:ok, binary} | {:error, term}
  def tag_message(agent, tag), do: exec(agent, {:message, tag})

  @doc """
  Returns all Git references matching the given `glob`.
  """
  @spec references(agent, binary | :undefined) :: {:ok, [git_reference]} | {:error, term}
  def references(agent, glob \\ :undefined), do: exec(agent, {:references, glob})

  @doc """
  Returns the Git reference with the given `name`.
  """
  @spec reference(agent, binary) :: {:ok, git_reference} | {:error, term}
  def reference(agent, name), do: exec(agent, {:reference, name})

  @doc """
  Creates a reference with the given `name` and `target`.
  """
  @spec reference_create(agent, binary, :atom, Git.oid | binary, boolean) :: :ok | {:error, term}
  def reference_create(agent, name, type, target, force \\ false), do: exec(agent, {:reference_create, name, type, target, force})

  @doc """
  Deletes a reference with the given `name`.
  """
  @spec reference_delete(agent, binary) :: :ok | {:error, term}
  def reference_delete(agent, name), do: exec(agent, {:reference_delete, name})

  @doc """
  Returns the Git object with the given `oid`.
  """
  @spec object(agent, Git.oid) :: {:ok, git_object} | {:error, term}
  def object(agent, oid), do: exec(agent, {:object, oid})

  @doc """
  Returns the Git object matching the given `spec`.
  """
  @spec revision(agent, binary) :: {:ok, GitCommit.t | GitTag.t, git_reference | nil} | {:error, term}
  def revision(agent, spec), do: exec(agent, {:revision, spec})

  @doc """
  Returns the parent of the given `commit`.
  """
  @spec commit_parents(agent, GitCommit.t) :: {:ok, [GitCommit.t]} | {:error, term}
  def commit_parents(agent, commit), do: exec(agent, {:commit_parents, commit})

  @doc """
  Returns the author of the given `commit`.
  """
  @spec commit_author(agent, GitCommit.t) :: {:ok, map} | {:error, term}
  def commit_author(agent, commit), do: exec(agent, {:author, commit})

  @doc """
  Returns the committer of the given `commit`.
  """
  @spec commit_committer(agent, GitCommit.t) :: {:ok, map} | {:error, term}
  def commit_committer(agent, commit), do: exec(agent, {:committer, commit})

  @doc """
  Returns the message of the given `commit`.
  """
  @spec commit_message(agent, GitCommit.t) :: {:ok, binary} | {:error, term}
  def commit_message(agent, commit), do: exec(agent, {:message, commit})

  @doc """
  Returns the timestamp of the given `commit`.
  """
  @spec commit_timestamp(agent, GitCommit.t) :: {:ok, DateTime.t} | {:error, term}
  def commit_timestamp(agent, commit), do: exec(agent, {:commit_timestamp, commit})

  @doc """
  Returns the GPG signature of the given `commit`.
  """
  @spec commit_gpg_signature(agent, GitCommit.t) :: {:ok, binary} | {:error, term}
  def commit_gpg_signature(agent, commit), do: exec(agent, {:commit_gpg_signature, commit})

  @doc """
  Creates a commit with the given `tree_oid` and `parents_oid`.
  """
  @spec commit_create(agent, binary, map, map, binary, Git.oid, [Git.oid]) :: {:ok, Git.oid} | {:error, term}
  def commit_create(agent, update_ref \\ :undefined, author, committer, message, tree_oid, parents_oids), do: exec(agent, {:commit_create, update_ref, author, committer, message, tree_oid, parents_oids})

  @doc """
  Returns the content of the given `blob`.
  """
  @spec blob_content(agent, GitBlob.t) :: {:ok, binary} | {:error, term}
  def blob_content(agent, blob), do: exec(agent, {:blob_content, blob})

  @doc """
  Returns the size in byte of the given `blob`.
  """
  @spec blob_size(agent, GitBlob.t) :: {:ok, non_neg_integer} | {:error, term}
  def blob_size(agent, blob), do: exec(agent, {:blob_size, blob})

  @doc """
  Returns the Git tree of the given `revision`.
  """
  @spec tree(agent, git_revision) :: {:ok, GitTree.t} | {:error, term}
  def tree(agent, revision), do: exec(agent, {:tree, revision})

  @doc """
  Returns the Git tree entries of the given `tree`.
  """
  @spec tree_entries(agent, GitTree.t) :: {:ok, [GitTreeEntry.t]} | {:error, term}
  def tree_entries(agent, tree), do: exec(agent, {:tree_entries, tree})

  @doc """
  Returns the Git tree entry for the given `revision` and `oid`.
  """
  @spec tree_entry_by_id(agent, git_revision | GitTree.t, Git.oid) :: {:ok, GitTreeEntry.t} | {:error, term}
  def tree_entry_by_id(agent, revision, oid), do: exec(agent, {:tree_entry, revision, {:oid, oid}})

  @doc """
  Returns the Git tree entry for the given `revision` and `path`.
  """
  @spec tree_entry_by_path(agent, git_revision | GitTree.t, Path.t, keyword) :: {:ok, GitTreeEntry.t | {GitTreeEntry.t, GitCommit.t}} | {:error, term}
  def tree_entry_by_path(agent, revision, path, opts \\ [])
  def tree_entry_by_path(agent, revision, path, [with_commit: true] = _opts), do: exec(agent, {:tree_entry_with_commit, revision, path})
  def tree_entry_by_path(agent, revision, path, _opts), do: exec(agent, {:tree_entry, revision, {:path, path}})

  @doc """
  Returns the Git tree entries for the given `revision` and `path`.
  """
  @spec tree_entries_by_path(agent, git_revision | GitTree.t, Path.t, keyword) :: {:ok, [GitTreeEntry.t | {GitTreeEntry.t, GitCommit.t}]} | {:error, term}
  def tree_entries_by_path(agent, revision, path \\ :root, opts \\ [])
  def tree_entries_by_path(agent, revision, path, [with_commit: true] = _opts), do: exec(agent, {:tree_entries_with_commit, revision, path})
  def tree_entries_by_path(agent, revision, path, _opts), do: exec(agent, {:tree_entries, revision, path})

  @doc """
  Returns the Git tree target of the given `tree_entry`.
  """
  @spec tree_entry_target(agent, GitTreeEntry.t) :: {:ok, GitBlob.t | GitTree.t} | {:error, term}
  def tree_entry_target(agent, tree_entry), do: exec(agent, {:tree_entry_target, tree_entry})

  @doc """
  Returns the Git index of the repository.
  """
  @spec index(agent) :: {:ok, GitIndex.t} | {:error, term}
  def index(agent), do: exec(agent, :index)

  @doc """
  Adds `index_entry` to the gieven `index`.
  """
  @spec index_add(agent, GitIndex.t, GitIndexEntry.t) :: :ok | {:error, term}
  def index_add(agent, index, index_entry), do: exec(agent, {:index_add, index, index_entry})

  @doc """
  Adds an index entry to the given `index`.
  """
  @spec index_add(agent, GitIndex.t, Git.oid, Path.t, non_neg_integer, pos_integer, keyword) :: :ok | {:error, term}
  def index_add(agent, index, oid, path, file_size, mode, opts \\ []), do: exec(agent, {:index_add, index, oid, path, file_size, mode, opts})

  @doc """
  Removes an index entry from the given `index`.
  """
  @spec index_remove(agent, GitIndex.t, Path.t) :: :ok | {:error, term}
  def index_remove(agent, index, path), do: exec(agent, {:index_remove, index, path})

  @doc """
  Remove all entries from the given `index` under a given directory `path`.
  """
  @spec index_remove_dir(agent, GitIndex.t, Path.t) :: :ok | {:error, term}
  def index_remove_dir(agent, index, path), do: exec(agent, {:index_remove_dir, index, path})

  @doc """
  Reads the given `tree` into the given `index`.
  """
  @spec index_read_tree(agent, GitIndex.t, GitTree.t) :: :ok | {:error, term}
  def index_read_tree(agent, index, tree), do: exec(agent, {:index_read_tree, index, tree})

  @doc """
  Writes the given `index` as a tree.
  """
  @spec index_write_tree(agent, GitIndex.t) :: {:ok, Git.oid} | {:error, term}
  def index_write_tree(agent, index), do: exec(agent, {:index_write_tree, index})

  @doc """
  Returns the Git diff of `obj1` and `obj2`.
  """
  @spec diff(agent, git_object, git_object, keyword) :: {:ok, GitDiff.t} | {:error, term}
  def diff(agent, obj1, obj2, opts \\ []), do: exec(agent, {:diff, obj1, obj2, opts})

  @doc """
  Returns the deltas of the given `diff`.
  """
  @spec diff_deltas(agent, GitDiff.t) :: {:ok, map} | {:error, term}
  def diff_deltas(agent, diff), do: exec(agent, {:diff_deltas, diff})

  @doc """
  Returns a binary formated representation of the given `diff`.
  """
  @spec diff_format(agent, GitDiff.t, Git.diff_format) :: {:ok, binary} | {:error, term}
  def diff_format(agent, diff, format \\ :patch), do: exec(agent, {:diff_format, diff, format})

  @doc """
  Returns the stats of the given `diff`.
  """
  @spec diff_stats(agent, GitDiff.t) :: {:ok, map} | {:error, term}
  def diff_stats(agent, diff), do: exec(agent, {:diff_stats, diff})

  @doc """
  Returns the Git commit history of the given `revision`.
  """
  @spec history(agent, git_revision, keyword) :: {:ok, [GitCommit.t]} | {:error, term}
  def history(agent, revision, opts \\ []), do: exec(agent, {:history, revision, opts})

  @doc """
  Returns the number of commit ancestors for the given `revision`.
  """
  @spec history_count(agent, git_revision) :: {:ok, non_neg_integer} | {:error, term}
  def history_count(agent, revision), do: exec(agent, {:history_count, revision})

  @doc """
  Peels the given `obj` until a Git object of the specified type is met.
  """
  @spec peel(agent, git_reference | git_object, Git.obj_type | :undefined) :: {:ok, git_object} | {:error, term}
  def peel(agent, obj, target \\ :undefined), do: exec(agent, {:peel, obj, target})

  @doc """
  Returns a Git PACK representation of the given `oids`.
  """
  @spec pack_create(agent, [Git.oid]) :: {:ok, binary} | {:error, term}
  def pack_create(agent, oids), do: exec(agent, {:pack, oids})

  #
  # Callbacks
  #

  @impl true
  def init({path, opts}) do
    case Git.repository_open(path) do
      {:ok, handle} ->
        config = Map.merge(@default_config, Map.new(opts))
        cache = if cache_mod = config.cache, do: cache_mod.init_cache(path)
        {:ok, {handle, config, cache}, config.idle_timeout}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def init_cache(_path), do: :ets.new(:cache, [:protected, :bag])

  @impl true
  def fetch_cache(cache, op) when not is_nil(op) do
    case :ets.lookup(cache, op) do
      [{^op, cache_entry}] ->
        cache_entry
      [] ->
        nil
    end
  end

  @impl true
  def put_cache(cache, op, resp) when not is_nil(op) do
    :ets.insert(cache, {op, resp})
    :ok
  end

  @impl true
  def handle_call({:references, _glob} = op, _from, {handle, config, _cache} = state) do
    {:reply, call_stream(op, handle), state, config.idle_timeout}
  end

  @impl true
  def handle_call({:commit_parents, _commit} = op, _from, {handle, config, _cache} = state) do
    {:reply, call_stream(op, handle), state, config.idle_timeout}
  end

  @impl true
  def handle_call({:tree_entries, _tree} = op, _from, {handle, config, _cache} = state) do
    {:reply, call_stream(op, handle), state, config.idle_timeout}
  end

  @impl true
  def handle_call({:history, obj, opts}, _from, {handle, config, _cache} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, 100)
    case call_stream({:history, obj, opts}, handle) do
      {:ok, stream} ->
        {:reply, {:ok, async_stream(:history_next, stream, chunk_size)}, state, config.idle_timeout}
      {:error, reason} ->
        {:reply, {:error, reason}, state, config.idle_timeout}
    end
  end

  def handle_call({:history_next, stream, chunk_size}, _from, {_handle, config, _cache} = state) do
    chunk_stream = struct(stream, enum: Enum.take(stream.enum, chunk_size))
    slice_stream = struct(stream, enum: Enum.drop(stream.enum, chunk_size))
    acc = if Enum.empty?(slice_stream.enum), do: :halt, else: slice_stream
    {:reply, {Enum.to_list(chunk_stream), acc}, state, config.idle_timeout}
  end

  @impl true
  def handle_call(op, _from, {handle, %{cache: cache_mod} = config, cache} = state) when is_atom(cache_mod) do
    cache_op = cache_mod.make_cache_key(op)
    cond do
      is_nil(cache_op) ->
        {:reply, call(op, handle), state, config.idle_timeout}
      cache_entry = cache_mod.fetch_cache(cache, cache_op) ->
        {:reply, cache_entry, state, config.idle_timeout}
      true ->
        cache_entry = call(op, handle)
        cache_mod.put_cache(cache, cache_op, cache_entry)
        {:reply, cache_entry, state, config.idle_timeout}
    end
  end

  @impl true
  def handle_call(op, _from, {handle, %{cache: nil} = config, nil} = state) do
    {:reply, call(op, handle), state, config.idle_timeout}
  end

  @impl true
  def handle_info(:timeout, {_handle, %{idle_timeout: :infinity}} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def make_cache_key(:empty?), do: nil
  def make_cache_key(:odb), do: nil
  def make_cache_key({:odb_read, _odb, _oid}), do: nil
  def make_cache_key({:odb_write, _odb, _data, _type}), do: nil
  def make_cache_key({:odb_object_exists?, _odb, _oid}), do: nil
  def make_cache_key(:head), do: nil
  def make_cache_key({:references, _glob}), do: nil
  def make_cache_key({:reference, _name}), do: nil
  def make_cache_key({:reference_create, _name, _type, _target, _force}), do: nil
  def make_cache_key({:reference_delete, _name}), do: nil
# def make_cache_key({:author, %GitTag{}}), do: nil
# def make_cache_key({:message, %GitTag{}}), do: nil
  def make_cache_key({:revision, _spec}), do: nil
  def make_cache_key({:commit_create, _update_ref, _author, _committer, _message, _tree_oid, _parents_oids}), do: nil
# def make_cache_key({:tree, %GitRef{}}), do: nil
# def make_cache_key({:tree, %GitTag{}}), do: nil
# def make_cache_key({:tree_entry, %GitRef{}, _entry}), do: nil
# def make_cache_key({:tree_entry, %GitTag{}, _entry}), do: nil
  def make_cache_key({:tree_entry, revision, {:path, path}}), do: {:tree_entry, map_operation_item(revision), path}
  def make_cache_key({:tree_entry, revision, {:oid, oid}}), do: {:tree_entry, map_operation_item(revision), oid}
  def make_cache_key({:tree_entries_with_commit, %GitRef{}, _path}), do: nil
  def make_cache_key({:tree_entries_with_commit, %GitTag{}, _path}), do: nil
# def make_cache_key({:tree_entries, %GitRef{}, _path}), do: nil
# def make_cache_key({:tree_entries, %GitTag{}, _path}), do: nil
  def make_cache_key(:index), do: nil
  def make_cache_key({:index_add, _index, _entry}), do: nil
  def make_cache_key({:index_add, _index, _oid, _path, _file_size, _mode, _opts}), do: nil
  def make_cache_key({:index_remove, _index, _path}), do: nil
  def make_cache_key({:index_remove_dir, _index, _path}), do: nil
  def make_cache_key({:index_read_tree, _index, _tree}), do: nil
  def make_cache_key({:index_write_tree, _index}), do: nil
  def make_cache_key({:diff, _obj1, _obj2, _opts}), do: nil
  def make_cache_key({:diff_deltas, _diff}), do: nil
  def make_cache_key({:diff_format, _diff, _format}), do: nil
  def make_cache_key({:diff_stats, _diff}), do: nil
  def make_cache_key({:history, _revision, _opts}), do: nil
# def make_cache_key({:peel, %GitRef{}, _target}), do: nil
# def make_cache_key({:peel, %GitTag{}, _target}), do: nil
  def make_cache_key({:pack, _oids}), do: nil
  def make_cache_key(op) do
      op
      |> Tuple.to_list()
      |> Enum.map(&map_operation_item/1)
      |> List.to_tuple()
  end

  #
  # Helpers
  #

  defp exec(agent, op) when is_reference(agent), do: telemery_exec(op, fn -> call(op, agent) end)
  defp exec(agent, op) when is_pid(agent), do: telemery_exec(op, fn -> GenServer.call(agent, op) end)
  defp exec(repo, op) do
    case GitRepo.get_agent(repo) do
      {:ok, agent} ->
        exec(agent, op)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp telemery_exec(op, callback) do
    {name, args} =
      if is_atom(op) do
        {op, []}
      else
        [name|args] = Tuple.to_list(op)
        {name, args}
      end
    event_time = System.monotonic_time(1_000_000)
    result = callback.()
    latency = System.monotonic_time(1_000_000) - event_time
    :telemetry.execute([:gitrekt, :git_agent, :call], %{latency: latency}, %{op: name, args: args})
    result
  end

  defp call(:empty?, handle) do
    {:ok, Git.repository_empty?(handle)}
  end

  defp call(:odb, handle) do
    case Git.repository_get_odb(handle) do
      {:ok, odb} ->
        {:ok, resolve_odb(odb)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:odb_read, %GitOdb{__ref__: odb}, oid}, _handle), do: Git.odb_read(odb, oid)
  defp call({:odb_write, %GitOdb{__ref__: odb}, data, type}, _handle), do: Git.odb_write(odb, data, type)
  defp call({:odb_object_exists?, %GitOdb{__ref__: odb}, oid}, _handle), do: Git.odb_object_exists?(odb, oid)

  defp call(:head, handle) do
    case Git.reference_resolve(handle, "HEAD") do
      {:ok, name, shorthand, oid} ->
        {:ok, resolve_reference({name, shorthand, :oid, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:references, glob}, handle) do
    case Git.reference_stream(handle, glob) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &resolve_reference/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:reference, "/refs/" <> _suffix = name}, handle) do
    case Git.reference_lookup(handle, name) do
      {:ok, shorthand, :oid, oid} ->
        {:ok, resolve_reference({name, shorthand, :oid, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:reference, shorthand}, handle) do
    case Git.reference_dwim(handle, shorthand) do
      {:ok, name, :oid, oid} ->
        {:ok, resolve_reference({name, shorthand, :oid, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:reference_create, name, type, target, force}, handle), do: Git.reference_create(handle, name, type, target, force)
  defp call({:reference_delete, name}, handle), do: Git.reference_delete(handle, name)

  defp call({:revision, spec}, handle) do
    case Git.revparse_ext(handle, spec) do
      {:ok, obj, obj_type, oid, name} ->
        {:ok, resolve_object({obj, obj_type, oid}), resolve_reference({name, nil, :oid, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:object, oid}, handle) do
    case Git.object_lookup(handle, oid) do
      {:ok, obj_type, obj} ->
        {:ok, resolve_object({obj, obj_type, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:tree, obj}, handle), do: fetch_tree(obj, handle)
  defp call({:diff, obj1, obj2, opts}, handle), do: fetch_diff(obj1, obj2, handle, opts)
  defp call({:diff_format, %GitDiff{__ref__: diff}, format}, _handle), do: Git.diff_format(diff, format)
  defp call({:diff_deltas, %GitDiff{__ref__: diff}}, _handle) do
    case Git.diff_deltas(diff) do
      {:ok, deltas} ->
        {:ok, Enum.map(deltas, &resolve_diff_delta/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:diff_stats, %GitDiff{__ref__: diff}}, _handle) do
    case Git.diff_stats(diff) do
      {:ok, files_changed, insertions, deletions} ->
        {:ok, resolve_diff_stats({files_changed, insertions, deletions})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:tree_entry, obj, spec}, handle), do: fetch_tree_entry(obj, spec, handle)
  defp call({:tree_entry_with_commit, obj, path}, handle) do
    with {:ok, tree_entry} <- fetch_tree_entry(obj, {:path, path}, handle),
         {:ok, commit} <- fetch_tree_entry_commit(obj, path, handle), do:
      {:ok, tree_entry, commit}
  end

  defp call({:tree_entry_target, %GitTreeEntry{} = tree_entry}, handle), do: fetch_target(tree_entry, :undefined, handle)
  defp call({:tree_entries, tree}, handle), do: fetch_tree_entries(tree, handle)
  defp call({:tree_entries, rev, :root}, handle), do: fetch_tree_entries(rev, handle)
  defp call({:tree_entries, rev, path}, handle), do: fetch_tree_entries(rev, path, handle)
  defp call({:tree_entries_with_commit, rev, :root}, handle) do
    with {:ok, tree_entries} <- fetch_tree_entries(rev, handle),
         {:ok, commits} <- fetch_tree_entries_commits(rev, handle), do:
      zip_tree_entries_commits(tree_entries, commits, "", handle)
  end

  defp call({:tree_entries_with_commit, rev, path}, handle) do
    with {:ok, tree_entries} <- fetch_tree_entries(rev, path, handle),
         {:ok, commits} <- fetch_tree_entries_commits(rev, path, handle), do:
      zip_tree_entries_commits(tree_entries, commits, path, handle)
  end

  defp call(:index, handle) do
    case Git.repository_get_index(handle) do
      {:ok, index} -> {:ok, resolve_index(index)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call({:index_add, %GitIndex{__ref__: index}, %GitIndexEntry{} = entry}, _handle) do
    Git.index_add(index, {entry.ctime, entry.mtime, entry.dev, entry.ino, entry.mode, entry.uid, entry.gid, entry.file_size, entry.oid, entry.flags, entry.flags_extended, entry.path})
  end

  defp call({:index_add, %GitIndex{__ref__: index}, oid, path, file_size, mode, opts}, _handle) do
    tree_entry = {
      Keyword.get(opts, :ctime, :undefined),
      Keyword.get(opts, :mtime, :undefined),
      Keyword.get(opts, :dev, :undefined),
      Keyword.get(opts, :ino, :undefined),
      mode,
      Keyword.get(opts, :uid, :undefined),
      Keyword.get(opts, :gid, :undefined),
      file_size,
      oid,
      Keyword.get(opts, :flags, :undefined),
      Keyword.get(opts, :flags_extended, :undefined),
      path
    }
    Git.index_add(index, tree_entry)
  end

  defp call({:index_remove, %GitIndex{__ref__: index}, path}, _handle), do: Git.index_remove(index, path)
  defp call({:index_remove_dir, %GitIndex{__ref__: index}, path}, _handle), do: Git.index_remove_dir(index, path)
  defp call({:index_read_tree, %GitIndex{__ref__: index}, %GitTree{__ref__: tree}}, _handle), do: Git.index_read_tree(index, tree)
  defp call({:index_write_tree, %GitIndex{__ref__: index}}, handle), do: Git.index_write_tree(index, handle)
  defp call({:author, obj}, _handle), do: fetch_author(obj)
  defp call({:committer, obj}, _handle), do: fetch_committer(obj)
  defp call({:message, obj}, _handle), do: fetch_message(obj)
  defp call({:commit_parents, %GitCommit{__ref__: commit}}, _handle) do
    case Git.commit_parents(commit) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &resolve_commit_parent/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:commit_timestamp, %GitCommit{__ref__: commit}}, _handle) do
    case Git.commit_time(commit) do
      {:ok, time, _offset} ->
        DateTime.from_unix(time)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:commit_gpg_signature, %GitCommit{__ref__: commit}}, _handle), do: Git.commit_header(commit, "gpgsig")
  defp call({:commit_create, update_ref, author, committer, message, tree_oid, parents_oids}, handle) do
    Git.commit_create(handle, update_ref, signature_tuple(author), signature_tuple(committer), :undefined, message, tree_oid, List.wrap(parents_oids))
  end

  defp call({:blob_content, %GitBlob{__ref__: blob}}, _handle), do: Git.blob_content(blob)
  defp call({:blob_size, %GitBlob{__ref__: blob}}, _handle), do: Git.blob_size(blob)
  defp call({:history, obj, opts}, handle), do: walk_history(obj, handle, opts)
  defp call({:history_count, obj}, handle) do
    case walk_history(obj, handle) do
      {:ok, stream} ->
        {:ok, Enum.count(stream.enum)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call({:peel, obj, target}, handle), do: fetch_target(obj, target, handle)
  defp call({:pack, oids}, agent) do
    with {:ok, walk} <- Git.revwalk_new(agent),
          :ok <- walk_insert(walk, oid_mask(oids)),
      do: Git.revwalk_pack(walk)
  end

  defp call_stream(op, handle) do
    case call(op, handle) do
      {:ok, stream} ->
        {:ok, enumerate_stream(stream)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_odb(odb), do: %GitOdb{__ref__: odb}

  defp resolve_reference({nil, nil, :oid, _oid}), do: nil
  defp resolve_reference({name, nil, :oid, oid}) do
    prefix = Path.dirname(name) <> "/"
    shorthand = Path.basename(name)
    %GitRef{oid: oid, name: shorthand, prefix: prefix, type: resolve_reference_type(prefix)}
  end

  defp resolve_reference({name, shorthand, :oid, oid}) do
    prefix = String.slice(name, 0, String.length(name) - String.length(shorthand))
    %GitRef{oid: oid, name: shorthand, prefix: prefix, type: resolve_reference_type(prefix)}
  end

  defp resolve_reference_type("refs/heads/"), do: :branch
  defp resolve_reference_type("refs/tags/"), do: :tag

  defp resolve_object({blob, :blob, oid}), do: %GitBlob{oid: oid, __ref__: blob}
  defp resolve_object({commit, :commit, oid}), do: %GitCommit{oid: oid, __ref__: commit}
  defp resolve_object({tree, :tree, oid}), do: %GitTree{oid: oid, __ref__: tree}
  defp resolve_object({tag, :tag, oid}) do
    case Git.tag_name(tag) do
      {:ok, name} ->
        %GitTag{oid: oid, name: name, __ref__: tag}
      {:error, _reason} ->
        %GitTag{oid: oid, __ref__: tag}
    end
  end

  defp resolve_commit_parent({oid, commit}), do: %GitCommit{oid: oid, __ref__: commit}

  defp resolve_tree_entry({mode, type, oid, name}), do: %GitTreeEntry{oid: oid, name: name, mode: mode, type: type}

  defp resolve_index(index), do: %GitIndex{__ref__: index}

  defp resolve_diff_delta({{old_file, new_file, count, similarity}, hunks}) do
    %{old_file: resolve_diff_file(old_file), new_file: resolve_diff_file(new_file), count: count, similarity: similarity, hunks: Enum.map(hunks, &resolve_diff_hunk/1)}
  end

  defp resolve_diff_file({oid, path, size, mode}) do
    %{oid: oid, path: path, size: size, mode: mode}
  end

  defp resolve_diff_hunk({{header, old_start, old_lines, new_start, new_lines}, lines}) do
    %{header: header, old_start: old_start, old_lines: old_lines, new_start: new_start, new_lines: new_lines, lines: Enum.map(lines, &resolve_diff_line/1)}
  end

  defp resolve_diff_line({origin, old_line_no, new_line_no, num_lines, content_offset, content}) do
    %{origin: <<origin>>, old_line_no: old_line_no, new_line_no: new_line_no, num_lines: num_lines, content_offset: content_offset, content: content}
  end

  defp resolve_diff_stats({files_changed, insertions, deletions}) do
    %{files_changed: files_changed, insertions: insertions, deletions: deletions}
  end

  defp lookup_object!(oid, handle) do
    case Git.object_lookup(handle, oid) do
      {:ok, obj_type, obj} ->
        resolve_object({obj, obj_type, oid})
      {:error, reason} ->
        raise reason
    end
  end

  defp fetch_tree(%GitCommit{__ref__: commit}, _handle) do
    case Git.commit_tree(commit) do
      {:ok, oid, tree} ->
        {:ok, %GitTree{oid: oid, __ref__: tree}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree(%GitRef{name: name, prefix: prefix}, handle) do
    case Git.reference_peel(handle, prefix <> name, :commit) do
      {:ok, obj_type, oid, obj} ->
        fetch_tree(resolve_object({obj, obj_type, oid}), handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree(%GitTag{__ref__: tag}, handle) do
    case Git.tag_peel(tag) do
      {:ok, obj_type, oid, obj} ->
        fetch_tree(resolve_object({obj, obj_type, oid}), handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry(%GitTree{__ref__: tree}, {:oid, oid}, _handle) do
    case Git.tree_byid(tree, oid) do
      {:ok, mode, type, oid, name} ->
        {:ok, resolve_tree_entry({mode, type, oid, name})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry(%GitTree{__ref__: tree}, {:path, path}, _handle) do
    case Git.tree_bypath(tree, path) do
      {:ok, mode, type, oid, name} ->
        {:ok, resolve_tree_entry({mode, type, oid, name})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry(rev, spec, handle) do
    case fetch_tree(rev, handle) do
      {:ok, tree} ->
        fetch_tree_entry(tree, spec, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry_commit(rev, path, handle) do
    case walk_history(rev, handle, pathspec: path) do
      {:ok, stream} ->
        stream = Stream.take(stream, 1)
        {:ok, List.first(Enum.to_list(stream))}
      {:error, reason} ->
        {:error, reason}
    end
  end


  defp fetch_tree_entries(%GitTree{__ref__: tree}, _handle) do
    case Git.tree_entries(tree) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &resolve_tree_entry/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entries(rev, handle) do
    case fetch_tree(rev, handle) do
      {:ok, tree} ->
        fetch_tree_entries(tree, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entries(%GitTree{} = tree, path, handle) do
    with {:ok, tree_entry} <- fetch_tree_entry(tree, {:path, path}, handle),
         {:ok, tree} <- fetch_target(tree_entry, :tree, handle), do:
     fetch_tree_entries(tree, handle)
  end

  defp fetch_tree_entries(rev, path, handle) do
    case fetch_tree(rev, handle) do
      {:ok, tree} ->
        fetch_tree_entries(tree, path, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entries_commits(rev, handle), do: walk_history(rev, handle)
  defp fetch_tree_entries_commits(rev, path, handle), do: walk_history(rev, handle, pathspec: path)

  defp fetch_diff(%GitTree{__ref__: tree1}, %GitTree{__ref__: tree2}, handle, opts) do
    case Git.diff_tree(handle, tree1, tree2, opts) do
      {:ok, diff} ->
        {:ok, %GitDiff{__ref__: diff}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_diff(obj1, obj2, handle, opts) do
    with {:ok, tree1} <- fetch_tree(obj1, handle),
         {:ok, tree2} <- fetch_tree(obj2, handle), do:
      fetch_diff(tree1, tree2, handle, opts)
  end

  defp fetch_target(%GitRef{name: name, prefix: prefix}, target, handle) do
    case Git.reference_peel(handle, prefix <> name, target) do
      {:ok, obj_type, oid, obj} ->
        {:ok, resolve_object({obj, obj_type, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(%GitTag{} = tag, :tag, _handle), do: {:ok, tag}
  defp fetch_target(%GitTag{__ref__: tag}, target, handle) do
    case Git.tag_peel(tag) do
      {:ok, obj_type, oid, obj} ->
        if target == :undefined,
          do: {:ok, resolve_object({obj, obj_type, oid})},
        else: fetch_target(resolve_object({obj, obj_type, oid}), target, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(%GitCommit{} = commit, :commit, _handle), do: {:ok, commit}
  defp fetch_target(%GitCommit{} = commit, target, handle) do
    fetch_target(fetch_tree(commit, handle), target, handle)
  end

  defp fetch_target(%GitBlob{} = blob, :blob, _handle), do: {:ok, blob}
  defp fetch_target(%GitTree{} = tree, :tree, _handle), do: {:ok, tree}

  defp fetch_target(%GitTreeEntry{oid: oid, type: type}, target, handle) do
    case Git.object_lookup(handle, oid) do
      {:ok, ^type, obj} ->
        if target == :undefined,
          do: {:ok, resolve_object({obj, type, oid})},
        else: fetch_target(resolve_object({obj, type, oid}), target, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(obj, target, _handle) do
    {:error, "cannot peel #{inspect obj} to #{target}"}
  end

  defp fetch_author(%GitCommit{__ref__: commit}) do
    with {:ok, name, email, time, _offset} <- Git.commit_author(commit),
         {:ok, datetime} <- DateTime.from_unix(time), do:
      {:ok, %{name: name, email: email, timestamp: datetime}}
  end

  defp fetch_author(%GitTag{__ref__: tag}) do
    with {:ok, name, email, time, _offset} <- Git.tag_author(tag),
         {:ok, datetime} <- DateTime.from_unix(time), do:
      {:ok, %{name: name, email: email, timestamp: datetime}}
  end

  defp fetch_committer(%GitCommit{__ref__: commit}) do
    with {:ok, name, email, time, _offset} <- Git.commit_committer(commit),
         {:ok, datetime} <- DateTime.from_unix(time), do:
      {:ok, %{name: name, email: email, timestamp: datetime}}
  end

  defp fetch_message(%GitCommit{__ref__: commit}), do: Git.commit_message(commit)
  defp fetch_message(%GitTag{__ref__: tag}), do: Git.tag_message(tag)

  defp walk_history(obj, handle, opts \\ []) do
    {sorting, opts} = Enum.split_with(opts, &(is_atom(&1) && String.starts_with?(to_string(&1), "sort")))
    with {:ok, walk} <- Git.revwalk_new(handle),
          :ok <- Git.revwalk_sorting(walk, sorting),
          :ok <- Git.revwalk_push(walk, obj.oid),
         {:ok, stream} <- Git.revwalk_stream(walk) do
      stream = Stream.map(stream, &lookup_object!(&1, handle))
      if pathspec = Keyword.get(opts, :pathspec),
        do: {:ok, Stream.filter(stream, &pathspec_match_commit(&1, List.wrap(pathspec), handle))},
      else: {:ok, stream}
    end
  end

  defp pathspec_match_commit(%GitCommit{__ref__: commit}, pathspec, handle) do
    case Git.commit_tree(commit) do
      {:ok, _oid, tree} ->
        pathspec_match_commit_tree(commit, tree, pathspec, handle)
      {:error, _reason} ->
        false
    end
  end

  defp pathspec_match_commit_tree(commit, tree, pathspec, handle) do
    with {:ok, stream} <- Git.commit_parents(commit),
         {_oid, parent} <- Enum.at(stream, 0, :match_tree),
         {:ok, _oid, parent_tree} <- Git.commit_tree(parent),
         {:ok, delta_count} <- pathspec_match_commit_diff(parent_tree, tree, pathspec, handle) do
      delta_count > 0
    else
      :match_tree ->
        case Git.pathspec_match_tree(tree, pathspec) do
          {:ok, match?} -> match?
          {:error, _reason} -> false
        end
      {:error, _reason} ->
        false
    end
  end

  defp pathspec_match_commit_diff(old_tree, new_tree, pathspec, handle) do
    case Git.diff_tree(handle, old_tree, new_tree, pathspec: pathspec) do
      {:ok, diff} -> Git.diff_delta_count(diff)
      {:error, reason} -> {:error, reason}
    end
  end

  defp oid_mask(oids) do
    Enum.map(oids, fn
      {oid, hidden} when is_binary(oid) -> {oid, hidden}
      oid when is_binary(oid) -> {oid, false}
    end)
  end

  defp signature_tuple(%{name: name, email: email, timestamp: datetime}) do
    {name, email, DateTime.to_unix(datetime), datetime.utc_offset}
  end

  defp walk_insert(_walk, []), do: :ok
  defp walk_insert(walk, [{oid, hide}|oids]) do
    case Git.revwalk_push(walk, oid, hide) do
      :ok -> walk_insert(walk, oids)
      {:error, reason} -> {:error, reason}
    end
  end

  defp async_stream(request, stream, chunk_size) do
    agent = self()
    Stream.resource(
      fn -> stream end,
      fn :halt -> {:halt, agent}
         stream -> GenServer.call(agent, {request, stream, chunk_size})
      end,
      &(&1)
    )
  end

  defp enumerate_stream(stream) when is_function(stream), do: %Stream{enum: Enum.to_list(stream)}
  defp enumerate_stream(%Stream{} = stream), do: Map.update!(stream, :enum, &Enum.to_list/1)

  defp zip_tree_entries_commits(tree_entries, commits, path, handle) do
    path_map = Map.new(tree_entries, &{Path.join(path, &1.name), &1})
    {missing_entries, tree_entries_commits} = Enum.reduce_while(commits, {path_map, []}, &zip_tree_entries_commit(&1, &2, handle))
    if Enum.empty?(missing_entries),
      do: {:ok, tree_entries_commits},
    else: {:ok, tree_entries_commits ++ Enum.map(missing_entries, fn {_path, tree_entry} -> {tree_entry, nil} end)}
  end

  defp zip_tree_entries_commit(_commit, {map, acc}, _handle) when map == %{} do
    {:halt, {%{}, acc}}
  end

  defp zip_tree_entries_commit(commit, {path_map, acc}, handle) do
    entries = Enum.filter(path_map, fn {path, _entry} -> pathspec_match_commit(commit, [path], handle) end)
    {:cont, Enum.reduce(entries, {path_map, acc}, fn {path, entry}, {path_map, acc} -> {Map.delete(path_map, path), [{entry, commit}|acc]} end)}
  end

  defp map_operation_item(item) when is_atom(item) or is_binary(item) or is_number(item), do: item
  defp map_operation_item(%GitRef{oid: oid}), do: {:reference, oid}
  defp map_operation_item(%GitTag{oid: oid}), do: {:tag, oid}
  defp map_operation_item(%GitCommit{oid: oid}), do: {:commit, oid}
  defp map_operation_item(%GitTree{oid: oid}), do: {:tree, oid}
  defp map_operation_item(%GitTreeEntry{oid: oid}), do: {:tree_entry, oid}
  defp map_operation_item(%GitBlob{oid: oid}), do: {:blob, oid}
end
