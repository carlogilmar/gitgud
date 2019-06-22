defmodule GitGud.Web.CommentThreadView do
  use Phoenix.LiveView

  def render(assigns) do
    Phoenix.View.render(GitGud.Web.CommentView, "comment_thread.html", assigns)
  end

  def mount(%{line_review_id: line_review_id}, socket) do
    socket = assign_new(socket, :current_user, fn -> GitGud.UserQuery.by_login("redrabbit") end) # TODO
    socket = assign_line_review_comments(socket, line_review_id)
    {:ok, assign(socket, comment_edit: nil)}
  end

  def handle_event("edit-comment", id, socket) do
    if user = socket.assigns.current_user do
      if comment = Enum.find(socket.assigns.comments, &(&1.author_id == user.id && &1.id == String.to_integer(id))) do
        {:noreply, assign(socket, comment_edit: comment.id)}
      end
    end
  end

  def handle_event("cancel-comment-edit", _, socket) do
    {:noreply, assign(socket, comment_edit: nil)}
  end

  def handle_event("update-comment", %{"comment" => comment_params}, socket) do
    if user = socket.assigns.current_user do
      if idx = Enum.find_index(socket.assigns.comments, &(&1.author_id == user.id && &1.id == socket.assigns.comment_edit)) do
        comments = List.update_at(socket.assigns.comments, idx, &GitGud.Comment.update!(&1, comment_params))
        {:noreply, assign(socket, comment_edit: nil, comments: comments)}
      end
    end
  end

  def handle_event("delete-comment", id, socket) do
    if user = socket.assigns.current_user do
      if idx = Enum.find_index(socket.assigns.comments, &(&1.author_id == user.id && &1.id == String.to_integer(id))) do
        {comment, comments} = List.pop_at(socket.assigns.comments, idx)
        GitGud.Comment.delete!(comment)
        GitGud.Web.Endpoint.broadcast_from!(self(), "repo:#{comment.repo_id}", "delete-comment", %{id: comment.id})
        {:noreply, assign(socket, comments: comments)}
      end
    end
  end

  def handle_event("validate-comment", %{"comment" => _comment_params}, socket) do
    {:noreply, socket}
  end

  #
  # Helpers
  #

  defp assign_line_review_comments(socket, line_review_id) do
    cond do
      line_review = Enum.find(Map.get(elem(socket.private.assigned_new, 0), :line_reviews, []), &(&1.id == line_review_id)) ->
        assign(socket, comments: line_review.comments)
      line_review = GitGud.ReviewQuery.commit_line_review_by_id(line_review_id, preload: [comments: :author]) ->
        assign(socket, comments: line_review.comments)
      true ->
        socket
    end
  end
end
