defmodule LivebookWeb.SettingsLive do
  use LivebookWeb, :live_view

  import LivebookWeb.UserHelpers

  alias LivebookWeb.{SidebarHelpers, PageHelpers}

  @impl true
  def mount(_params, _session, socket) do
    file_systems = Livebook.Settings.file_systems()

    {:ok,
     socket
     |> SidebarHelpers.shared_home_handlers()
     |> assign(
       file_systems: file_systems,
       autosave_path_state: %{
         file: autosave_dir(),
         dialog_opened?: false
       },
       page_title: "Livebook - Settings"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex grow h-full">
      <SidebarHelpers.sidebar>
        <SidebarHelpers.logo_item socket={@socket} />
        <SidebarHelpers.shared_home_footer socket={@socket} current_user={@current_user} />
      </SidebarHelpers.sidebar>
      <div class="grow px-6 py-8 overflow-y-auto">
        <div class="max-w-screen-md w-full mx-auto px-4 pb-8 space-y-16">
          <!-- System settings section -->
          <div class="flex flex-col space-y-8">
            <div>
              <PageHelpers.title text="System settings" socket={@socket} />
              <p class="mt-4 text-gray-700">
                Here you can change global Livebook configuration. Keep in mind
                that this configuration gets persisted and will be restored on application
                launch.
              </p>
            </div>

          <!-- System details -->
          <div class="flex flex-col space-y-4">
            <h1 class="text-xl text-gray-800 font-semibold">
              About
            </h1>
            <div class="flex items-center justify-between border border-gray-200 rounded-lg p-4">
              <div class="flex items-center space-x-12">
                <.labeled_text label="Livebook" text={"v#{Application.spec(:livebook, :vsn)}"} />
                <.labeled_text label="Elixir" text={"v#{System.version()}"} />
              </div>

              <%= live_redirect to: Routes.live_dashboard_path(@socket, :home),
                                class: "button-base button-outlined-gray" do %>
                <.remix_icon icon="dashboard-2-line" class="align-middle mr-1" />
                <span>Open dashboard</span>
              <% end %>
            </div>
          </div>
          <!-- Autosave path configuration -->
          <div class="flex flex-col space-y-4">
            <div>
              <h2 class="text-xl text-gray-800 font-semibold">
                Autosave location
              </h2>
              <p class="mt-4 text-gray-700">
                A directory to temporarily keep notebooks until they are persisted.
              </p>
            </div>
            <.autosave_path_select state={@autosave_path_state} />
          </div>
          <!-- File systems configuration -->
          <div class="flex flex-col space-y-4">
            <div class="flex justify-between items-center">
              <h2 class="text-xl text-gray-800 font-semibold">
                File systems
              </h2>
            </div>
              <LivebookWeb.SettingsLive.FileSystemsComponent.render
                file_systems={@file_systems}
                socket={@socket} />
            </div>
          </div>
          <!-- User settings section -->
          <div class="flex flex-col space-y-8">
            <div>
              <h1 class="text-3xl text-gray-800 font-semibold">
                User settings
              </h1>
              <p class="mt-4 text-gray-700">
                The configuration in this section changes only your Livebook
                experience and is saved in your browser.
              </p>
            </div>
            <!-- Editor configuration -->
            <div class="flex flex-col space-y-4">
              <h2 class="text-xl text-gray-800 font-semibold">
                Code editor
              </h2>
              <div class="flex flex-col space-y-3"
                id="editor-settings"
                phx-hook="EditorSettings"
                phx-update="ignore">
                <.switch_checkbox
                  name="editor_auto_completion"
                  label="Show completion list while typing"
                  checked={false} />
                <.switch_checkbox
                  name="editor_auto_signature"
                  label="Show function signature while typing"
                  checked={false} />
                <.switch_checkbox
                  name="editor_font_size"
                  label="Increase font size"
                  checked={false} />
                <.switch_checkbox
                  name="editor_high_contrast"
                  label="Use high contrast theme"
                  checked={false} />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <.current_user_modal current_user={@current_user} />

    <%= if @live_action == :add_file_system do %>
      <.modal id="add-file-system-modal" show class="w-full max-w-3xl" patch={Routes.settings_path(@socket, :page)}>
        <.live_component module={LivebookWeb.SettingsLive.AddFileSystemComponent}
          id="add-file-system"
          return_to={Routes.settings_path(@socket, :page)} />
      </.modal>
    <% end %>
    """
  end

  defp autosave_path_select(%{state: %{dialog_opened?: true}} = assigns) do
    ~H"""
    <div class="w-full h-52">
      <.live_component module={LivebookWeb.FileSelectComponent}
        id="autosave-path-component"
        file={@state.file}
        extnames={[]}
        running_files={[]}
        submit_event={:set_autosave_path}
        file_system_select_disabled={true}
      >
        <button class="button-base button-gray"
          phx-click="cancel_autosave_path"
          tabindex="-1">
            Cancel
        </button>
        <button class="button-base button-gray"
          phx-click="reset_autosave_path"
          tabindex="-1">
            Reset
        </button>
        <button class="button-base button-blue"
          phx-click="set_autosave_path"
          disabled={not Livebook.FileSystem.File.dir?(@state.file)}
          tabindex="-1">
          Save
        </button>
      </.live_component>
    </div>
    """
  end

  defp autosave_path_select(assigns) do
    ~H"""
    <div class="flex">
      <input class="input mr-2" readonly value={@state.file.path}/>
      <button class="button-base button-gray button-small"
        phx-click="open_autosave_path_select">
        Change
      </button>
    </div>
    """
  end

  @impl true
  def handle_params(%{"file_system_id" => file_system_id}, _url, socket) do
    {:noreply, assign(socket, file_system_id: file_system_id)}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_autosave_path", %{}, socket) do
    {:noreply,
     update(
       socket,
       :autosave_path_state,
       &%{&1 | dialog_opened?: false, file: autosave_dir()}
     )}
  end

  def handle_event("set_autosave_path", %{}, socket) do
    path = socket.assigns.autosave_path_state.file.path

    Livebook.Settings.set_autosave_path(path)

    {:noreply,
     update(
       socket,
       :autosave_path_state,
       &%{&1 | dialog_opened?: false, file: autosave_dir()}
     )}
  end

  @impl true
  def handle_event("reset_autosave_path", %{}, socket) do
    {:noreply,
     update(
       socket,
       :autosave_path_state,
       &%{&1 | file: default_autosave_dir()}
     )}
  end

  def handle_event("open_autosave_path_select", %{}, socket) do
    {:noreply, update(socket, :autosave_path_state, &%{&1 | dialog_opened?: true})}
  end

  def handle_event("detach_file_system", %{"id" => file_system_id}, socket) do
    Livebook.Settings.remove_file_system(file_system_id)
    file_systems = Livebook.Settings.file_systems()
    {:noreply, assign(socket, file_systems: file_systems)}
  end

  @impl true
  def handle_info({:file_systems_updated, file_systems}, socket) do
    {:noreply, assign(socket, file_systems: file_systems)}
  end

  def handle_info({:set_file, file, _info}, socket) do
    {:noreply, update(socket, :autosave_path_state, &%{&1 | file: file})}
  end

  def handle_info(:set_autosave_path, socket) do
    handle_event("set_autosave_path", %{}, socket)
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp autosave_dir() do
    Livebook.Settings.autosave_path()
    |> Livebook.FileSystem.Utils.ensure_dir_path()
    |> Livebook.FileSystem.File.local()
  end

  defp default_autosave_dir() do
    Livebook.Settings.default_autosave_path()
    |> Livebook.FileSystem.Utils.ensure_dir_path()
    |> Livebook.FileSystem.File.local()
  end
end
