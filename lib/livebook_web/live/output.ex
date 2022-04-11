defmodule LivebookWeb.Output do
  use Phoenix.Component

  import LivebookWeb.Helpers

  alias LivebookWeb.Output

  @doc """
  Renders a list of cell outputs.
  """
  def outputs(assigns) do
    ~H"""
    <%= for {idx, output} <- Enum.reverse(@outputs) do %>
      <div class="max-w-full" id={"output-wrapper-#{@dom_id_map[idx] || idx}"}
        data-el-output
        data-border={border?(output)}
        data-wrapper={wrapper?(output)}>
        <%= render_output(output, %{
              id: "output-#{idx}",
              socket: @socket,
              session_id: @session_id,
              input_values: @input_values
            }) %>
      </div>
    <% end %>
    """
  end

  defp border?({:stdout, _text}), do: true
  defp border?({:text, _text}), do: true
  defp border?({:error, _message}), do: true
  defp border?(_output), do: false

  defp wrapper?({:frame, _outputs, _info}), do: true
  defp wrapper?(_output), do: false

  defp render_output({:stdout, text}, %{id: id}) do
    text = if(text == :__pruned__, do: nil, else: text)
    live_component(Output.StdoutComponent, id: id, text: text)
  end

  defp render_output({:text, text}, %{id: id}) do
    assigns = %{id: id, text: text}

    ~H"""
    <Output.TextComponent.render id={@id} content={@text} />
    """
  end

  defp render_output({:markdown, markdown}, %{id: id}) do
    live_component(Output.MarkdownComponent, id: id, content: markdown)
  end

  defp render_output({:image, content, mime_type}, %{id: id}) do
    assigns = %{id: id, content: content, mime_type: mime_type}

    ~H"""
    <Output.ImageComponent.render content={@content} mime_type={@mime_type} />
    """
  end

  defp render_output({:js, js_info}, %{id: id, session_id: session_id}) do
    live_component(LivebookWeb.JSViewComponent,
      id: id,
      js_view: js_info.js_view,
      session_id: session_id,
      timeout_message: "Output data no longer available, please reevaluate this cell"
    )
  end

  defp render_output({:frame, outputs, _info}, %{
         id: id,
         input_values: input_values,
         session_id: session_id
       }) do
    live_component(Output.FrameComponent,
      id: id,
      outputs: outputs,
      session_id: session_id,
      input_values: input_values
    )
  end

  defp render_output({:input, attrs}, %{id: id, input_values: input_values}) do
    live_component(Output.InputComponent, id: id, attrs: attrs, input_values: input_values)
  end

  defp render_output({:control, attrs}, %{id: id, input_values: input_values}) do
    live_component(Output.ControlComponent, id: id, attrs: attrs, input_values: input_values)
  end

  defp render_output({:error, formatted}, %{}) do
    assigns = %{message: formatted}

    ~H"""
    <div class="whitespace-pre-wrap font-editor text-gray-500" role="complementary" aria-label="error"><%= ansi_string_to_html(@message) %></div>
    """
  end

  # TODO: remove on Livebook v0.7
  defp render_output(output, %{})
       when elem(output, 0) in [
              :vega_lite_static,
              :vega_lite_dynamic,
              :table_dynamic,
              :frame_dynamic
            ] do
    render_error_message("""
    Legacy output format: #{inspect(output)}. Please update Kino to
    the latest version.
    """)
  end

  defp render_output(output, %{}) do
    render_error_message("""
    Unknown output format: #{inspect(output)}. If you're using Kino,
    you may want to update Kino and Livebook to the latest version.
    """)
  end

  defp render_error_message(message) do
    assigns = %{message: message}

    ~H"""
    <div class="whitespace-pre-wrap font-editor text-red-600" role="complementary" aria-label="error message"><%= @message %></div>
    """
  end
end
