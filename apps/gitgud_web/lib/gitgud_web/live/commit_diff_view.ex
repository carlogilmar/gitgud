defmodule GitGud.Web.CommitDiffView do
  use Phoenix.LiveView

  def render(assigns) do
    Phoenix.View.render(GitGud.Web.CodebaseView, "_commit_diff.html", assigns)
  end

  def mount(%{repo_id: repo_id, commit_oid: oid}, socket) do
    socket = assign_new(socket, :repo, fn ->
      repo = GitGud.RepoQuery.by_id(repo_id)
      if repo, do: GitGud.Repo.load_agent!(repo)
    end)

    socket = assign_new(socket, :current_user, fn ->
      GitGud.UserQuery.by_login("redrabbit")
    end)

    socket = assign_new(socket, :commit, fn ->
      {:ok, commit} = GitRekt.GitAgent.object(socket.assigns.repo, oid)
      commit
    end)

    socket = assign_new(socket, :diff, fn ->
      {:ok, diff}  = GitRekt.GitAgent.commit_diff(socket.assigns.repo, socket.assigns.commit)
      diff
    end)

    {:ok, deltas} = GitRekt.GitAgent.diff_deltas(socket.assigns.repo, socket.assigns.diff)
    socket = assign(socket, :deltas, deltas)

    line_reviews = GitGud.ReviewQuery.commit_line_reviews(socket.assigns.repo, socket.assigns.commit, preload: [comments: :author])
    socket = assign(socket, :line_reviews, line_reviews)

    GitGud.Web.Endpoint.subscribe("repo:#{repo_id}")
    {:ok, assign(socket, :line_review_form, nil)}
  end

  def handle_event("new-line-comment", pos, socket) do
    [blob_oid, hunk_index, line_index] = String.split(pos, ":", parts: 3, trim: true)
    {:noreply, assign(socket, :line_review_form, {GitRekt.Git.oid_parse(blob_oid), String.to_integer(hunk_index), String.to_integer(line_index)})}
  end

  def handle_event("cancel-line-comment", _val, socket) do
    {:noreply, assign(socket, :line_review_form, nil)}
  end

  def handle_event("create-line-comment", %{"comment" => comment_params}, socket) do
    {blob_oid, hunk_index, line_index} = socket.assigns.line_review_form
    case GitGud.CommitLineReview.add_comment(socket.assigns.repo.id, socket.assigns.commit.oid, blob_oid, hunk_index, line_index, 1, comment_params["body"]) do
      {:ok, comment} ->
        socket = assign_line_review_comment(socket, comment)
        {:noreply, assign(socket, :line_review_form, nil)}
    end
  end

  def handle_event("validate-comment", %{"comment" => _comment_params}, socket) do
    {:noreply, socket}
  end

  def handle_info(%{topic: "repo:" <> _repo_id , event: "delete-comment", payload: %{id: comment_id}}, socket) do
    {:noreply, assign_line_review_drop_comment(socket, comment_id)}
  end

  #
  # Helpers
  #

  defp assign_line_review_comment(socket, comment) do
    if idx = Enum.find_index(socket.assigns.line_reviews, &current_line_review?(&1, socket.assigns.line_review_form)) do
      assign(socket, :line_reviews, List.update_at(socket.assigns.line_reviews, idx, &%{&1|comments: &1.comments ++ [comment]}))
    else
      {blob_oid, hunk_index, line_index} = socket.assigns.line_review_form
      line_review = GitGud.ReviewQuery.commit_line_review(socket.assigns.repo, socket.assigns.commit, blob_oid, hunk_index, line_index, preload: [comments: :author])
      assign(socket, :line_reviews, List.insert_at(socket.assigns.line_reviews, -1, line_review))
    end
  end

  defp assign_line_review_drop_comment(socket, comment_id) do
    if idx = Enum.find_index(socket.assigns.line_reviews, &(comment_id in Enum.map(&1.comments, fn comment -> comment.id end))) do
      if Enum.count(Enum.at(socket.assigns.line_reviews, idx).comments) == 1,
        do: assign(socket, :line_reviews, List.delete_at(socket.assigns.line_reviews, idx)),
      else: assign(socket, :line_reviews, List.update_at(socket.assigns.line_reviews, idx, &%{&1|comments: Enum.reject(&1.comments, fn comment -> comment.id == comment_id end)}))
    end || socket
  end

  defp current_line_review?(%GitGud.CommitLineReview{blob_oid: blob_oid, hunk: hunk_index, line: line_index}, {blob_oid, hunk_index, line_index}), do: true
  defp current_line_review?(_line_review, _line_review_form), do: false
end
