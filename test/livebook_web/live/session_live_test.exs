defmodule LivebookWeb.SessionLiveTest do
  use LivebookWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Livebook.{Sessions, Session, Runtime, Users, FileSystem}
  alias Livebook.Notebook.Cell
  alias Livebook.Users.User

  setup do
    {:ok, session} = Sessions.create_session(notebook: Livebook.Notebook.new())

    on_exit(fn ->
      Session.close(session.pid)
    end)

    %{session: session}
  end

  test "disconnected and connected render", %{conn: conn, session: session} do
    {:ok, view, disconnected_html} = live(conn, "/sessions/#{session.id}")
    assert disconnected_html =~ "Untitled notebook"
    assert render(view) =~ "Untitled notebook"
  end

  describe "asynchronous updates" do
    test "renders an updated notebook name", %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      Session.set_notebook_name(session.pid, "My notebook")
      wait_for_session_update(session.pid)

      assert render(view) =~ "My notebook"
    end

    test "renders an updated notebook name in title", %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      assert page_title(view) =~ "Untitled notebook"

      Session.set_notebook_name(session.pid, "My notebook")
      wait_for_session_update(session.pid)

      # Wait for LV to update
      _ = render(view)

      assert page_title(view) =~ "My notebook"
    end

    test "renders a newly inserted section", %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      section_id = insert_section(session.pid)

      assert render(view) =~ section_id
    end

    test "renders an updated section name", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      Session.set_section_name(session.pid, section_id, "My section")
      wait_for_session_update(session.pid)

      assert render(view) =~ "My section"
    end

    test "renders a newly inserted cell", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      cell_id = insert_text_cell(session.pid, section_id, :markdown)

      assert render(view) =~ "cell-" <> cell_id
    end

    test "un-renders a deleted cell", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :markdown)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      Session.delete_cell(session.pid, cell_id)
      wait_for_session_update(session.pid)

      refute render(view) =~ "cell-" <> cell_id
    end
  end

  describe "UI events update the shared state" do
    test "adding a new section", %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element("button", "New section")
      |> render_click()

      assert %{notebook: %{sections: [_section]}} = Session.get_data(session.pid)
    end

    test "adding a new cell", %{conn: conn, session: session} do
      Session.insert_section(session.pid, 0)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element("button", "Markdown")
      |> render_click()

      assert %{notebook: %{sections: [%{cells: [%Cell.Markdown{}]}]}} =
               Session.get_data(session.pid)
    end

    test "queueing cell evaluation", %{conn: conn, session: session} do
      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")
      evaluate_setup(session.pid)

      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code, "Process.sleep(50)")

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("queue_cell_evaluation", %{"cell_id" => cell_id})

      assert %{cell_infos: %{^cell_id => %{eval: %{status: :evaluating}}}} =
               Session.get_data(session.pid)
    end

    test "reevaluting the setup cell", %{conn: conn, session: session} do
      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")
      evaluate_setup(session.pid)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("queue_cell_evaluation", %{"cell_id" => "setup"})

      assert_receive {:operation, {:set_runtime, _pid, %{} = _runtime}}
    end

    test "cancelling cell evaluation", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code, "Process.sleep(2000)")

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("queue_cell_evaluation", %{"cell_id" => cell_id})

      view
      |> element(~s{[data-el-session]})
      |> render_hook("cancel_cell_evaluation", %{"cell_id" => cell_id})

      assert %{cell_infos: %{^cell_id => %{eval: %{status: :ready}}}} =
               Session.get_data(session.pid)
    end

    test "inserting a cell below the given cell", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("insert_cell_below", %{"cell_id" => cell_id, "type" => "markdown"})

      assert %{notebook: %{sections: [%{cells: [_first_cell, %Cell.Markdown{}]}]}} =
               Session.get_data(session.pid)
    end

    test "inserting a cell at section start", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      _cell_id = insert_text_cell(session.pid, section_id, :code)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("insert_cell_below", %{"section_id" => section_id, "type" => "markdown"})

      assert %{notebook: %{sections: [%{cells: [%Cell.Markdown{}, _first_cell]}]}} =
               Session.get_data(session.pid)
    end

    test "deleting the given cell", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("delete_cell", %{"cell_id" => cell_id})

      assert %{notebook: %{sections: [%{cells: []}]}} = Session.get_data(session.pid)
    end

    test "restoring a deleted cell", %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code)

      Session.delete_cell(session.pid, cell_id)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      refute render(view) =~ "cell-" <> cell_id

      view
      |> element(~s{a[aria-label="Bin (sb)"]})
      |> render_click()

      view
      |> element("button", "Restore")
      |> render_click()

      assert %{notebook: %{sections: [%{cells: [%{id: ^cell_id}]}]}} =
               Session.get_data(session.pid)
    end

    test "editing input field in cell output", %{conn: conn, session: session, test: test} do
      section_id = insert_section(session.pid)

      Process.register(self(), test)

      input = %{
        ref: :input_ref,
        id: "input1",
        type: :number,
        label: "Name",
        default: "hey",
        destination: test
      }

      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")

      insert_cell_with_output(session.pid, section_id, {:input, input})

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s/[data-el-outputs-container] form/)
      |> render_change(%{"value" => "10"})

      assert %{input_values: %{"input1" => 10}} = Session.get_data(session.pid)

      assert_receive {:event, :input_ref, %{value: 10, type: :change}}
    end

    test "newlines in text input are normalized", %{conn: conn, session: session, test: test} do
      section_id = insert_section(session.pid)

      Process.register(self(), test)

      input = %{
        ref: :input_ref,
        id: "input1",
        type: :textarea,
        label: "Name",
        default: "hey",
        destination: test
      }

      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")

      insert_cell_with_output(session.pid, section_id, {:input, input})

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s/[data-el-outputs-container] form/)
      |> render_change(%{"value" => "line\r\nline"})

      assert %{input_values: %{"input1" => "line\nline"}} = Session.get_data(session.pid)
    end

    test "form input changes are reflected only in local LV data",
         %{conn: conn, session: session, test: test} do
      section_id = insert_section(session.pid)

      Process.register(self(), test)

      form_control = %{
        type: :form,
        ref: :form_ref,
        destination: test,
        fields: [
          name: %{
            ref: :input_ref,
            id: "input1",
            type: :text,
            label: "Name",
            default: "initial",
            destination: test
          }
        ],
        submit: "Send",
        report_changes: %{},
        reset_on_submit: []
      }

      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")

      insert_cell_with_output(session.pid, section_id, {:control, form_control})

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s/[data-el-outputs-container] form/)
      |> render_change(%{"value" => "sherlock"})

      # The new value is on the page
      assert render(view) =~ "sherlock"
      # but it's not reflected in the synchronized session data
      assert %{input_values: %{"input1" => "initial"}} = Session.get_data(session.pid)

      view
      |> element(~s/[data-el-outputs-container] button/, "Send")
      |> render_click()

      assert_receive {:event, :form_ref, %{data: %{name: "sherlock"}, type: :submit}}
    end
  end

  describe "outputs" do
    test "stdout output update", %{conn: conn, session: session} do
      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")
      evaluate_setup(session.pid)

      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code)

      Session.queue_cell_evaluation(session.pid, cell_id)

      send(session.pid, {:runtime_evaluation_output, cell_id, {:stdout, "line 1\n"}})

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")
      assert render(view) =~ "line 1"

      send(session.pid, {:runtime_evaluation_output, cell_id, {:stdout, "line 2\n"}})
      wait_for_session_update(session.pid)
      # Render once, so that stdout send_update is processed
      _ = render(view)
      assert render(view) =~ "line 2"
    end

    test "frame output update", %{conn: conn, session: session} do
      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")
      evaluate_setup(session.pid)

      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code)

      Session.queue_cell_evaluation(session.pid, cell_id)

      send(
        session.pid,
        {:runtime_evaluation_output, cell_id,
         {:frame, [{:text, "In frame"}], %{ref: "1", type: :default}}}
      )

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")
      assert render(view) =~ "In frame"

      send(
        session.pid,
        {:runtime_evaluation_output, cell_id,
         {:frame, [{:text, "Updated frame"}], %{ref: "1", type: :replace}}}
      )

      wait_for_session_update(session.pid)

      # Render once, so that frame send_update is processed
      _ = render(view)

      content = render(view)
      assert content =~ "Updated frame"
      refute content =~ "In frame"
    end
  end

  describe "smart cells" do
    test "shows a new cell insert button when a new smart cell kind becomes available",
         %{conn: conn, session: session} do
      insert_section(session.pid)

      {:ok, runtime} = Runtime.Embedded.new() |> Runtime.connect()
      Session.set_runtime(session.pid, runtime)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      refute render(view) =~ "Database connection"

      send(
        session.pid,
        {:runtime_smart_cell_definitions,
         [%{kind: "dbconn", name: "Database connection", requirement: nil}]}
      )

      wait_for_session_update(session.pid)

      assert render(view) =~ "Database connection"
    end
  end

  describe "runtime settings" do
    test "connecting to elixir standalone updates connect button to reconnect",
         %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}/settings/runtime")

      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")

      view
      |> element("button", "Elixir standalone")
      |> render_click()

      [elixir_standalone_view] = live_children(view)

      elixir_standalone_view
      |> element("button", "Connect")
      |> render_click()

      assert_receive {:operation, {:set_runtime, _pid, %Runtime.ElixirStandalone{} = runtime}}

      page = render(view)
      assert page =~ Atom.to_string(runtime.node)
      assert page =~ "Reconnect"
      assert page =~ "Disconnect"
    end
  end

  describe "persistence settings" do
    @tag :tmp_dir
    test "saving to file shows the newly created file in file selector",
         %{conn: conn, session: session, tmp_dir: tmp_dir} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}/settings/file")

      assert view = find_live_child(view, "persistence")

      path = Path.join(tmp_dir, "notebook.livemd")

      view
      |> element("button", "Choose a file")
      |> render_click()

      view
      |> element(~s{form[phx-change="set_path"]})
      |> render_change(%{path: path})

      view
      |> element(~s{button[phx-click="confirm_file"]}, "Choose")
      |> render_click()

      view
      |> element(~s{button}, "Save now")
      |> render_click()

      view
      |> element("button", "Change file")
      |> render_click()

      assert view
             |> element("button", "notebook.livemd")
             |> has_element?()
    end

    @tag :tmp_dir
    test "changing output persistence updates data",
         %{conn: conn, session: session, tmp_dir: tmp_dir} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}/settings/file")

      assert view = find_live_child(view, "persistence")

      path = Path.join(tmp_dir, "notebook.livemd")

      view
      |> element("button", "Choose a file")
      |> render_click()

      view
      |> element(~s{form[phx-change="set_path"]})
      |> render_change(%{path: path})

      view
      |> element(~s{button[phx-click="confirm_file"]}, "Choose")
      |> render_click()

      view
      |> element(~s{form[phx-change="set_options"]})
      |> render_change(%{persist_outputs: "true"})

      view
      |> element(~s{button}, "Save now")
      |> render_click()

      assert %{notebook: %{persist_outputs: true}} = Session.get_data(session.pid)
    end
  end

  describe "completion" do
    test "replies with nil completion reference when no runtime is started",
         %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code, "Process.sleep(10)")

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("intellisense_request", %{
        "cell_id" => cell_id,
        "type" => "completion",
        "hint" => "System.ver",
        "editor_auto_completion" => false
      })

      assert_reply view, %{"ref" => nil}
    end

    test "replies with completion reference and then sends asynchronous response",
         %{conn: conn, session: session} do
      section_id = insert_section(session.pid)
      cell_id = insert_text_cell(session.pid, section_id, :code, "Process.sleep(10)")

      {:ok, runtime} = Runtime.Embedded.new() |> Runtime.connect()
      Session.set_runtime(session.pid, runtime)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      view
      |> element(~s{[data-el-session]})
      |> render_hook("intellisense_request", %{
        "cell_id" => cell_id,
        "type" => "completion",
        "hint" => "System.ver",
        "editor_auto_completion" => false
      })

      assert_reply view, %{"ref" => ref}
      assert ref != nil

      assert_push_event(
        view,
        "intellisense_response",
        %{
          "ref" => ^ref,
          "response" => %{items: [%{label: "version/0"}]}
        },
        1000
      )
    end
  end

  test "forking the session", %{conn: conn, session: session} do
    Session.set_notebook_name(session.pid, "My notebook")
    wait_for_session_update(session.pid)

    {:ok, view, _} = live(conn, "/sessions/#{session.id}")

    assert {:error, {:live_redirect, %{to: "/sessions/" <> session_id}}} =
             result =
             view
             |> element("button", "Fork")
             |> render_click()

    {:ok, view, _} = follow_redirect(result, conn)
    assert render(view) =~ "My notebook - fork"

    close_session_by_id(session_id)
  end

  describe "connected users" do
    test "lists connected users", %{conn: conn, session: session} do
      user1 = create_user_with_name("Jake Peralta")

      client_pid =
        spawn_link(fn ->
          Session.register_client(session.pid, self(), user1)

          receive do
            :stop -> :ok
          end
        end)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      assert render(view) =~ "Jake Peralta"

      send(client_pid, :stop)
    end

    test "updates users list whenever a user joins or leaves",
         %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")

      user1 = create_user_with_name("Jake Peralta")

      client_pid =
        spawn_link(fn ->
          Session.register_client(session.pid, self(), user1)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:operation, {:client_join, ^client_pid, _user}}
      assert render(view) =~ "Jake Peralta"

      send(client_pid, :stop)
      assert_receive {:operation, {:client_leave, ^client_pid}}
      refute render(view) =~ "Jake Peralta"
    end

    test "updates users list whenever a user changes his data",
         %{conn: conn, session: session} do
      user1 = create_user_with_name("Jake Peralta")

      client_pid =
        spawn_link(fn ->
          Session.register_client(session.pid, self(), user1)

          receive do
            :stop -> :ok
          end
        end)

      {:ok, view, _} = live(conn, "/sessions/#{session.id}")

      Phoenix.PubSub.subscribe(Livebook.PubSub, "sessions:#{session.id}")

      assert render(view) =~ "Jake Peralta"

      Users.broadcast_change(%{user1 | name: "Raymond Holt"})
      assert_receive {:operation, {:update_user, _pid, _user}}

      refute render(view) =~ "Jake Peralta"
      assert render(view) =~ "Raymond Holt"

      send(client_pid, :stop)
    end
  end

  describe "relative paths" do
    test "renders an info message when the path doesn't have notebook extension",
         %{conn: conn, session: session} do
      session_path = "/sessions/#{session.id}"

      assert {:error, {:live_redirect, %{to: ^session_path}}} =
               result = live(conn, "/sessions/#{session.id}/document.pdf")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "Got unrecognised session path: document.pdf"
    end

    test "renders an info message when the session has neither original url nor path",
         %{conn: conn, session: session} do
      session_path = "/sessions/#{session.id}"

      assert {:error, {:live_redirect, %{to: ^session_path}}} =
               result = live(conn, "/sessions/#{session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)

      assert render(view) =~
               "Cannot resolve notebook path notebook.livemd, because the current notebook has no location"
    end

    @tag :tmp_dir
    test "renders an error message when the relative notebook does not exist",
         %{conn: conn, session: session, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      index_file = FileSystem.File.resolve(tmp_dir, "index.livemd")
      notebook_file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      Session.set_file(session.pid, index_file)
      wait_for_session_update(session.pid)

      session_path = "/sessions/#{session.id}"

      assert {:error, {:live_redirect, %{to: ^session_path}}} =
               result = live(conn, "/sessions/#{session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)

      assert render(view) =~
               "Cannot navigate, failed to read #{notebook_file.path}, reason: no such file or directory"
    end

    @tag :tmp_dir
    test "opens a relative notebook if it exists",
         %{conn: conn, session: session, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      index_file = FileSystem.File.resolve(tmp_dir, "index.livemd")
      notebook_file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      Session.set_file(session.pid, index_file)
      wait_for_session_update(session.pid)

      :ok = FileSystem.File.write(notebook_file, "# Sibling notebook")

      assert {:error, {:live_redirect, %{to: new_session_path}}} =
               result = live(conn, "/sessions/#{session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "Sibling notebook"

      "/sessions/" <> session_id = new_session_path
      {:ok, session} = Sessions.fetch_session(session_id)
      data = Session.get_data(session.pid)
      assert data.file == notebook_file

      Session.close(session.pid)
    end

    @tag :tmp_dir
    test "if the current session has no path, forks the relative notebook",
         %{conn: conn, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      index_file = FileSystem.File.resolve(tmp_dir, "index.livemd")
      notebook_file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      {:ok, session} = Sessions.create_session(origin: {:file, index_file})

      :ok = FileSystem.File.write(notebook_file, "# Sibling notebook")

      assert {:error, {:live_redirect, %{to: new_session_path}}} =
               result = live(conn, "/sessions/#{session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "Sibling notebook - fork"

      "/sessions/" <> session_id = new_session_path
      {:ok, new_session} = Sessions.fetch_session(session_id)
      data = Session.get_data(new_session.pid)
      assert data.file == nil
      assert data.origin == {:file, notebook_file}

      Session.close([session.pid, new_session.pid])
    end

    @tag :tmp_dir
    test "if the notebook is already open, redirects to the session",
         %{conn: conn, session: session, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      index_file = FileSystem.File.resolve(tmp_dir, "index.livemd")
      notebook_file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      Session.set_file(session.pid, index_file)
      wait_for_session_update(session.pid)

      :ok = FileSystem.File.write(notebook_file, "# Sibling notebook")

      assert {:error, {:live_redirect, %{to: session_path}}} =
               live(conn, "/sessions/#{session.id}/notebook.livemd")

      assert {:error, {:live_redirect, %{to: ^session_path}}} =
               live(conn, "/sessions/#{session.id}/notebook.livemd")

      "/sessions/" <> session_id = session_path
      close_session_by_id(session_id)
    end

    @tag :tmp_dir
    test "handles nested paths", %{conn: conn, session: session, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      parent_file = FileSystem.File.resolve(tmp_dir, "parent.livemd")
      child_dir = FileSystem.File.resolve(tmp_dir, "dir/")
      child_file = FileSystem.File.resolve(child_dir, "child.livemd")

      Session.set_file(session.pid, parent_file)
      wait_for_session_update(session.pid)

      :ok = FileSystem.File.write(child_file, "# Child notebook")

      assert {:error, {:live_redirect, %{to: "/sessions/" <> session_id}}} =
               result = live(conn, "/sessions/#{session.id}/dir/child.livemd")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "Child notebook"

      close_session_by_id(session_id)
    end

    @tag :tmp_dir
    test "handles parent paths", %{conn: conn, session: session, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      parent_file = FileSystem.File.resolve(tmp_dir, "parent.livemd")
      child_dir = FileSystem.File.resolve(tmp_dir, "dir/")
      child_file = FileSystem.File.resolve(child_dir, "child.livemd")

      Session.set_file(session.pid, child_file)
      wait_for_session_update(session.pid)

      :ok = FileSystem.File.write(parent_file, "# Parent notebook")

      assert {:error, {:live_redirect, %{to: "/sessions/" <> session_id}}} =
               result = live(conn, "/sessions/#{session.id}/__parent__/parent.livemd")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "Parent notebook"

      close_session_by_id(session_id)
    end

    test "resolves remote URLs", %{conn: conn} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/notebook.livemd", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "# My notebook")
      end)

      index_url = url(bypass.port) <> "/index.livemd"
      {:ok, session} = Sessions.create_session(origin: {:url, index_url})

      assert {:error, {:live_redirect, %{to: "/sessions/" <> session_id}}} =
               result = live(conn, "/sessions/#{session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "My notebook"

      Session.close(session.pid)
      close_session_by_id(session_id)
    end

    test "renders an error message if relative remote notebook cannot be loaded", %{conn: conn} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/notebook.livemd", fn conn ->
        Plug.Conn.resp(conn, 500, "Error")
      end)

      index_url = url(bypass.port) <> "/index.livemd"

      {:ok, session} = Sessions.create_session(origin: {:url, index_url})

      session_path = "/sessions/#{session.id}"

      assert {:error, {:live_redirect, %{to: ^session_path}}} =
               result = live(conn, "/sessions/#{session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)
      assert render(view) =~ "Cannot navigate, failed to download notebook from the given URL"

      Session.close(session.pid)
    end

    test "if the remote notebook is already imported, redirects to the session",
         %{conn: conn, test: test} do
      test_path = test |> to_string() |> URI.encode_www_form()
      index_url = "http://example.com/#{test_path}/index.livemd"
      notebook_url = "http://example.com/#{test_path}/notebook.livemd"

      {:ok, index_session} = Sessions.create_session(origin: {:url, index_url})
      {:ok, notebook_session} = Sessions.create_session(origin: {:url, notebook_url})

      notebook_session_path = "/sessions/#{notebook_session.id}"

      assert {:error, {:live_redirect, %{to: ^notebook_session_path}}} =
               live(conn, "/sessions/#{index_session.id}/notebook.livemd")

      Session.close([index_session.pid, notebook_session.pid])
    end

    test "renders an error message if there are already multiple session imported from the relative URL",
         %{conn: conn, test: test} do
      test_path = test |> to_string() |> URI.encode_www_form()
      index_url = "http://example.com/#{test_path}/index.livemd"
      notebook_url = "http://example.com/#{test_path}/notebook.livemd"

      {:ok, index_session} = Sessions.create_session(origin: {:url, index_url})
      {:ok, notebook_session1} = Sessions.create_session(origin: {:url, notebook_url})
      {:ok, notebook_session2} = Sessions.create_session(origin: {:url, notebook_url})

      index_session_path = "/sessions/#{index_session.id}"

      assert {:error, {:live_redirect, %{to: ^index_session_path}}} =
               result = live(conn, "/sessions/#{index_session.id}/notebook.livemd")

      {:ok, view, _} = follow_redirect(result, conn)

      assert render(view) =~
               "Cannot navigate, because multiple sessions were found for #{notebook_url}"

      Session.close([index_session.pid, notebook_session1.pid, notebook_session2.pid])
    end
  end

  describe "dependency search" do
    test "lists search entries", %{conn: conn, session: session} do
      {:ok, view, _} = live(conn, "/sessions/#{session.id}/dependency-search")

      [search_view] = live_children(view)

      # Search the predefined dependencies in the embedded runtime
      search_view
      |> element(~s{form[phx-change="search"]})
      |> render_change(%{"search" => "ki"})

      page = render(view)
      assert page =~ "kino"
      assert page =~ "Interactive widgets for Livebook"
      assert page =~ "0.5.2"
    end
  end

  # Helpers

  defp wait_for_session_update(session_pid) do
    # This call is synchronous, so it gives the session time
    # for handling the previously sent change messages.
    Session.get_data(session_pid)
    :ok
  end

  # Utils for sending session requests, waiting for the change to be applied
  # and retrieving new ids if applicable.

  defp insert_section(session_pid) do
    Session.insert_section(session_pid, 0)
    %{notebook: %{sections: [section]}} = Session.get_data(session_pid)
    section.id
  end

  defp insert_text_cell(session_pid, section_id, type, content \\ "") do
    Session.insert_cell(session_pid, section_id, 0, type, %{source: content})
    %{notebook: %{sections: [%{cells: [cell]}]}} = Session.get_data(session_pid)
    cell.id
  end

  defp evaluate_setup(session_pid) do
    Session.queue_cell_evaluation(session_pid, "setup")
    assert_receive {:operation, {:add_cell_evaluation_response, _, "setup", _, _}}
  end

  defp insert_cell_with_output(session_pid, section_id, output) do
    code =
      quote do
        send(
          Process.group_leader(),
          {:io_request, self(), make_ref(), {:livebook_put_output, unquote(Macro.escape(output))}}
        )
      end
      |> Macro.to_string()

    cell_id = insert_text_cell(session_pid, section_id, :code, code)
    Session.queue_cell_evaluation(session_pid, cell_id)
    assert_receive {:operation, {:add_cell_evaluation_response, _, ^cell_id, _, _}}
    cell_id
  end

  defp create_user_with_name(name) do
    {:ok, user} = User.new() |> User.change(%{"name" => name})
    user
  end

  defp url(port), do: "http://localhost:#{port}"

  defp close_session_by_id(session_id) do
    {:ok, session} = Sessions.fetch_session(session_id)
    Session.close(session.pid)
  end
end
