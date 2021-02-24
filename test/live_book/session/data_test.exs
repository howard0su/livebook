defmodule LiveBook.Session.DataTest do
  use ExUnit.Case, async: true

  alias LiveBook.Session.Data
  alias LiveBook.{Delta, Notebook}

  describe "new/1" do
    test "called with no arguments defaults to a blank notebook" do
      empty_map = %{}

      assert %{notebook: %{sections: []}, cell_infos: ^empty_map, section_infos: ^empty_map} =
               Data.new()
    end

    test "called with a notebook, sets default cell and section infos" do
      cell = Notebook.Cell.new(:elixir)
      section = %{Notebook.Section.new() | cells: [cell]}
      notebook = %{Notebook.new() | sections: [section]}

      cell_id = cell.id
      section_id = section.id

      assert %{cell_infos: %{^cell_id => %{}}, section_infos: %{^section_id => %{}}} =
               Data.new(notebook)
    end
  end

  describe "apply_operation/2 given :insert_section" do
    test "adds new section to notebook and session info" do
      data = Data.new()

      operation = {:insert_section, 0, "s1"}

      assert {:ok,
              %{
                notebook: %{
                  sections: [%{id: "s1"}]
                },
                section_infos: %{"s1" => _}
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :insert_cell" do
    test "returns an error given invalid section id" do
      data = Data.new()
      operation = {:insert_cell, "nonexistent", 0, :elixir, "c1"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "insert_cell adds new cell to notebook and cell info" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"}
        ])

      operation = {:insert_cell, "s1", 0, :elixir, "c1"}

      assert {:ok,
              %{
                notebook: %{
                  sections: [
                    %{cells: [%{id: "c1"}]}
                  ]
                },
                cell_infos: %{"c1" => _}
              }, []} = Data.apply_operation(data, operation)
    end

    test "initializes client-revision map" do
      client_pid = self()

      data =
        data_after_operations!([
          {:client_join, client_pid},
          {:insert_section, 0, "s1"}
        ])

      operation = {:insert_cell, "s1", 0, :elixir, "c1"}

      assert {:ok,
              %{
                cell_infos: %{"c1" => %{revision_by_client_pid: %{^client_pid => 0}}}
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :delete_section" do
    test "returns an error given invalid section id" do
      data = Data.new()
      operation = {:delete_section, "nonexistent"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "removes the section from notebook and session info, adds to deleted sections" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"}
        ])

      operation = {:delete_section, "s1"}
      empty_map = %{}

      assert {:ok,
              %{
                notebook: %{
                  sections: []
                },
                section_infos: ^empty_map,
                deleted_sections: [%{id: "s1"}]
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :delete_cell" do
    test "returns an error given invalid cell id" do
      data = Data.new()
      operation = {:delete_cell, "nonexistent"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "if the cell is evaluating, cencels section evaluation" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"}
        ])

      operation = {:delete_cell, "c1"}

      assert {:ok,
              %{
                cell_infos: %{"c2" => %{evaluation_status: :ready}},
                section_infos: %{"s1" => %{evaluating_cell_id: nil, evaluation_queue: []}}
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "removes the cell from notebook and session info, adds to deleted cells" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      operation = {:delete_cell, "c1"}
      empty_map = %{}

      assert {:ok,
              %{
                notebook: %{
                  sections: [%{cells: []}]
                },
                cell_infos: ^empty_map,
                deleted_cells: [%{id: "c1"}]
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "unqueues the cell if it's queued for evaluation" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"}
        ])

      operation = {:delete_cell, "c2"}

      assert {:ok,
              %{
                section_infos: %{"s1" => %{evaluation_queue: []}}
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "marks evaluated child cells as stale" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          # Evaluate both cells
          {:queue_cell_evaluation, "c1"},
          {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}},
          {:queue_cell_evaluation, "c2"},
          {:add_cell_evaluation_response, "c2", {:ok, [1, 2, 3]}}
        ])

      operation = {:delete_cell, "c1"}

      assert {:ok,
              %{
                cell_infos: %{"c2" => %{validity_status: :stale}}
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "returns forget evaluation action" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      operation = {:delete_cell, "c1"}

      assert {:ok, _data, [{:forget_evaluation, %{id: "c1"}, %{id: "s1"}}]} =
               Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :queue_cell_evaluation" do
    test "returns an error given invalid cell id" do
      data = Data.new()
      operation = {:queue_cell_evaluation, "nonexistent"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error given non-elixir cell" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :markdown, "c1"}
        ])

      operation = {:queue_cell_evaluation, "c1"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error for an evaluating cell" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:queue_cell_evaluation, "c1"}
        ])

      operation = {:queue_cell_evaluation, "c1"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "marks the cell as evaluating if the corresponding section is idle" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      operation = {:queue_cell_evaluation, "c1"}

      assert {:ok,
              %{
                cell_infos: %{"c1" => %{evaluation_status: :evaluating}},
                section_infos: %{"s1" => %{evaluating_cell_id: "c1", evaluation_queue: []}}
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "returns start evaluation action if the corresponding section is idle" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      operation = {:queue_cell_evaluation, "c1"}

      assert {:ok, _data, [{:start_evaluation, %{id: "c1"}, %{id: "s1"}}]} =
               Data.apply_operation(data, operation)
    end

    test "marks the cell as queued if the corresponding section is already evaluating" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"}
        ])

      operation = {:queue_cell_evaluation, "c2"}

      assert {:ok,
              %{
                cell_infos: %{"c2" => %{evaluation_status: :queued}},
                section_infos: %{"s1" => %{evaluating_cell_id: "c1", evaluation_queue: ["c2"]}}
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :add_cell_evaluation_stdout" do
    test "updates the cell outputs" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:queue_cell_evaluation, "c1"}
        ])

      operation = {:add_cell_evaluation_stdout, "c1", "Hello!"}

      assert {:ok,
              %{
                notebook: %{
                  sections: [
                    %{
                      cells: [%{outputs: ["Hello!"]}]
                    }
                  ]
                }
              }, []} = Data.apply_operation(data, operation)
    end

    test "merges consecutive stdout results" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:queue_cell_evaluation, "c1"},
          {:add_cell_evaluation_stdout, "c1", "Hello"}
        ])

      operation = {:add_cell_evaluation_stdout, "c1", " amigo!"}

      assert {:ok,
              %{
                notebook: %{
                  sections: [
                    %{
                      cells: [%{outputs: ["Hello amigo!"]}]
                    }
                  ]
                }
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :add_cell_evaluation_response" do
    test "updates the cell outputs" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:queue_cell_evaluation, "c1"}
        ])

      operation = {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}}

      assert {:ok,
              %{
                notebook: %{
                  sections: [
                    %{
                      cells: [%{outputs: [{:ok, [1, 2, 3]}]}]
                    }
                  ]
                }
              }, []} = Data.apply_operation(data, operation)
    end

    test "marks the cell as evaluated" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"}
        ])

      operation = {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}}

      assert {:ok,
              %{
                cell_infos: %{"c1" => %{validity_status: :evaluated, evaluation_status: :ready}},
                section_infos: %{"s1" => %{evaluating_cell_id: nil, evaluation_queue: []}}
              }, []} = Data.apply_operation(data, operation)
    end

    test "marks next queued cell in this section as evaluating if there is one" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"}
        ])

      operation = {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}}

      assert {:ok,
              %{
                cell_infos: %{"c2" => %{evaluation_status: :evaluating}},
                section_infos: %{"s1" => %{evaluating_cell_id: "c2", evaluation_queue: []}}
              },
              [{:start_evaluation, %{id: "c2"}, %{id: "s1"}}]} =
               Data.apply_operation(data, operation)
    end

    test "if parent cells are not executed, marks them for evaluation first" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"}
        ])

      operation = {:queue_cell_evaluation, "c2"}

      assert {:ok,
              %{
                cell_infos: %{
                  "c1" => %{evaluation_status: :evaluating},
                  "c2" => %{evaluation_status: :queued}
                },
                section_infos: %{"s1" => %{evaluating_cell_id: "c1", evaluation_queue: ["c2"]}}
              },
              [{:start_evaluation, %{id: "c1"}, %{id: "s1"}}]} =
               Data.apply_operation(data, operation)
    end

    test "marks evaluated child cells as stale" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          # Evaluate both cells
          {:queue_cell_evaluation, "c1"},
          {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}},
          {:queue_cell_evaluation, "c2"},
          {:add_cell_evaluation_response, "c2", {:ok, [1, 2, 3]}},
          # Queue the first cell again
          {:queue_cell_evaluation, "c1"}
        ])

      operation = {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}}

      assert {:ok,
              %{
                cell_infos: %{"c2" => %{validity_status: :stale}}
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :cancel_cell_evaluation" do
    test "returns an error given invalid cell id" do
      data = Data.new()
      operation = {:cancel_cell_evaluation, "nonexistent"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error for an evaluated cell" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:queue_cell_evaluation, "c1"},
          {:add_cell_evaluation_response, "c1", {:ok, [1, 2, 3]}}
        ])

      operation = {:cancel_cell_evaluation, "c1"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "if the cell is evaluating, clears the corresponding section evaluation and the queue" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"}
        ])

      operation = {:cancel_cell_evaluation, "c1"}

      assert {:ok,
              %{
                cell_infos: %{
                  "c1" => %{validity_status: :fresh},
                  "c2" => %{validity_status: :fresh}
                },
                section_infos: %{
                  "s1" => %{evaluating_cell_id: nil, evaluation_queue: []}
                }
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "if the cell is evaluating, returns stop evaluation action" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"}
        ])

      operation = {:cancel_cell_evaluation, "c1"}

      assert {:ok, _data, [{:stop_evaluation, %{id: "s1"}}]} =
               Data.apply_operation(data, operation)
    end

    test "if the cell is queued, unqueues it" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"}
        ])

      operation = {:cancel_cell_evaluation, "c2"}

      assert {:ok,
              %{
                cell_infos: %{"c2" => %{validity_status: :fresh, evaluation_status: :ready}},
                section_infos: %{"s1" => %{evaluating_cell_id: "c1", evaluation_queue: []}}
              }, []} = Data.apply_operation(data, operation)
    end

    test "if the cell is queued, unqueues dependent cells that are also queued" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:insert_cell, "s1", 2, :elixir, "c3"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"},
          {:queue_cell_evaluation, "c3"}
        ])

      operation = {:cancel_cell_evaluation, "c2"}

      assert {:ok,
              %{
                cell_infos: %{"c3" => %{evaluation_status: :ready}},
                section_infos: %{"s1" => %{evaluating_cell_id: "c1", evaluation_queue: []}}
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :set_notebook_name" do
    test "updates notebook name with the given string" do
      data = Data.new()

      operation = {:set_notebook_name, "Cat's guide to life"}

      assert {:ok, %{notebook: %{name: "Cat's guide to life"}}, []} =
               Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :set_section_name" do
    test "returns an error given invalid cell id" do
      data = Data.new()
      operation = {:set_section_name, "nonexistent", "Chapter 1"}
      assert :error = Data.apply_operation(data, operation)
    end

    test "updates section name with the given string" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"}
        ])

      operation = {:set_section_name, "s1", "Cat's guide to life"}

      assert {:ok, %{notebook: %{sections: [%{name: "Cat's guide to life"}]}}, []} =
               Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :client_join" do
    test "returns an error if the given process is already a client" do
      data =
        data_after_operations!([
          {:client_join, self()}
        ])

      operation = {:client_join, self()}
      assert :error = Data.apply_operation(data, operation)
    end

    test "adds the given process to the client list" do
      client_pid = self()
      data = Data.new()

      operation = {:client_join, client_pid}
      assert {:ok, %{client_pids: [^client_pid]}, []} = Data.apply_operation(data, operation)
    end

    test "adds new entry to the cell revisions map for the client with the latest revision" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      delta1 = Delta.new() |> Delta.insert("cats")

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:apply_cell_delta, client1_pid, "c1", delta1, 1}
        ])

      client2_pid = IEx.Helpers.pid(0, 0, 1)
      operation = {:client_join, client2_pid}

      assert {:ok,
              %{
                cell_infos: %{"c1" => %{revision_by_client_pid: %{^client2_pid => 1}}}
              }, _} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :client_leave" do
    test "returns an error if the given process is not a client" do
      data = Data.new()

      operation = {:client_leave, self()}
      assert :error = Data.apply_operation(data, operation)
    end

    test "removes the given process from the client list" do
      data =
        data_after_operations!([
          {:client_join, self()}
        ])

      operation = {:client_leave, self()}
      assert {:ok, %{client_pids: []}, []} = Data.apply_operation(data, operation)
    end

    test "removes an entry in the the cell revisions map for the client and purges deltas" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      client2_pid = IEx.Helpers.pid(0, 0, 1)

      delta1 = Delta.new() |> Delta.insert("cats")

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:client_join, client2_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:apply_cell_delta, client1_pid, "c1", delta1, 1}
        ])

      operation = {:client_leave, client2_pid}

      assert {:ok,
              %{
                cell_infos: %{
                  "c1" => %{deltas: [], revision_by_client_pid: revision_by_client_pid}
                }
              }, _} = Data.apply_operation(data, operation)

      assert revision_by_client_pid == %{client1_pid => 1}
    end
  end

  describe "apply_operation/2 given :apply_cell_delta" do
    test "returns an error given invalid cell id" do
      data =
        data_after_operations!([
          {:client_join, self()}
        ])

      operation = {:apply_cell_delta, self(), "nonexistent", Delta.new(), 1}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error given non-joined client pid" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      delta = Delta.new() |> Delta.insert("cats")
      operation = {:apply_cell_delta, self(), "c1", delta, 1}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error given invalid revision" do
      data =
        data_after_operations!([
          {:client_join, self()},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      delta = Delta.new() |> Delta.insert("cats")
      operation = {:apply_cell_delta, self(), "c1", delta, 5}

      assert :error = Data.apply_operation(data, operation)
    end

    test "updates cell source according to the given delta" do
      data =
        data_after_operations!([
          {:client_join, self()},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      delta = Delta.new() |> Delta.insert("cats")
      operation = {:apply_cell_delta, self(), "c1", delta, 1}

      assert {:ok,
              %{
                notebook: %{
                  sections: [
                    %{cells: [%{source: "cats"}]}
                  ]
                },
                cell_infos: %{"c1" => %{revision: 1}}
              }, _actions} = Data.apply_operation(data, operation)
    end

    test "transforms the delta if the revision is not the most recent" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      client2_pid = IEx.Helpers.pid(0, 0, 1)

      delta1 = Delta.new() |> Delta.insert("cats")

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:client_join, client2_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:apply_cell_delta, client1_pid, "c1", delta1, 1}
        ])

      delta2 = Delta.new() |> Delta.insert("tea")
      operation = {:apply_cell_delta, client2_pid, "c1", delta2, 1}

      assert {:ok,
              %{
                notebook: %{
                  sections: [
                    %{cells: [%{source: "catstea"}]}
                  ]
                },
                cell_infos: %{"c1" => %{revision: 2}}
              }, _} = Data.apply_operation(data, operation)
    end

    test "returns broadcast delta action with the transformed delta" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      client2_pid = IEx.Helpers.pid(0, 0, 1)

      delta1 = Delta.new() |> Delta.insert("cats")

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:client_join, client2_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:apply_cell_delta, client1_pid, "c1", delta1, 1}
        ])

      delta2 = Delta.new() |> Delta.insert("tea")
      operation = {:apply_cell_delta, client2_pid, "c1", delta2, 1}

      transformed_delta2 = Delta.new() |> Delta.retain(4) |> Delta.insert("tea")

      assert {:ok, _data, [{:broadcast_delta, ^client2_pid, _cell, ^transformed_delta2}]} =
               Data.apply_operation(data, operation)
    end

    test "given single client, does not keep deltas" do
      client_pid = self()

      data =
        data_after_operations!([
          {:client_join, client_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      delta = Delta.new() |> Delta.insert("cats")
      operation = {:apply_cell_delta, client_pid, "c1", delta, 1}

      assert {:ok,
              %{
                cell_infos: %{"c1" => %{deltas: []}}
              }, _} = Data.apply_operation(data, operation)
    end

    test "given multiple client, keeps the delta" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      client2_pid = IEx.Helpers.pid(0, 0, 1)

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:client_join, client2_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      delta = Delta.new() |> Delta.insert("cats")
      operation = {:apply_cell_delta, client1_pid, "c1", delta, 1}

      assert {:ok,
              %{
                cell_infos: %{"c1" => %{deltas: [^delta]}}
              }, _} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :report_cell_revision" do
    test "returns an error given invalid cell id" do
      data =
        data_after_operations!([
          {:client_join, self()}
        ])

      operation = {:report_cell_revision, self(), "nonexistent", 1}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error given non-joined client pid" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      client2_pid = IEx.Helpers.pid(0, 0, 1)

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:apply_cell_delta, client1_pid, "c1", Delta.new(insert: "cats"), 1}
        ])

      operation = {:report_cell_revision, client2_pid, "c1", 1}
      assert :error = Data.apply_operation(data, operation)
    end

    test "returns an error given invalid revision" do
      data =
        data_after_operations!([
          {:client_join, self()},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"}
        ])

      operation = {:report_cell_revision, self(), "c1", 1}
      assert :error = Data.apply_operation(data, operation)
    end

    test "updates client entry in the revisions map and purges unnecessary deltas" do
      client1_pid = IEx.Helpers.pid(0, 0, 0)
      client2_pid = IEx.Helpers.pid(0, 0, 1)

      delta1 = Delta.new() |> Delta.insert("cats")

      data =
        data_after_operations!([
          {:client_join, client1_pid},
          {:client_join, client2_pid},
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:apply_cell_delta, client1_pid, "c1", delta1, 1}
        ])

      operation = {:report_cell_revision, client2_pid, "c1", 1}

      assert {:ok,
              %{
                cell_infos: %{
                  "c1" => %{
                    deltas: [],
                    revision_by_client_pid: %{^client1_pid => 1, ^client2_pid => 1}
                  }
                }
              }, _} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :set_runtime" do
    test "updates data with the given runtime" do
      data = Data.new()

      {:ok, runtime} = LiveBookTest.Runtime.SingleEvaluator.init()

      operation = {:set_runtime, runtime}

      assert {:ok, %{runtime: ^runtime}, []} = Data.apply_operation(data, operation)
    end

    test "clears all statuses and the per-section queues" do
      data =
        data_after_operations!([
          # First section with evaluating and queued cells
          {:insert_section, 0, "s1"},
          {:insert_cell, "s1", 0, :elixir, "c1"},
          {:insert_cell, "s1", 1, :elixir, "c2"},
          {:queue_cell_evaluation, "c1"},
          {:queue_cell_evaluation, "c2"},
          # Second section with evaluating and queued cells
          {:insert_section, 1, "s2"},
          {:insert_cell, "s2", 0, :elixir, "c3"},
          {:insert_cell, "s2", 1, :elixir, "c4"},
          {:queue_cell_evaluation, "c3"},
          {:queue_cell_evaluation, "c4"}
        ])

      {:ok, runtime} = LiveBookTest.Runtime.SingleEvaluator.init()

      operation = {:set_runtime, runtime}

      assert {:ok,
              %{
                cell_infos: %{
                  "c1" => %{validity_status: :fresh, evaluation_status: :ready},
                  "c2" => %{validity_status: :fresh, evaluation_status: :ready},
                  "c3" => %{validity_status: :fresh, evaluation_status: :ready},
                  "c4" => %{validity_status: :fresh, evaluation_status: :ready}
                },
                section_infos: %{
                  "s2" => %{evaluating_cell_id: nil, evaluation_queue: []},
                  "s1" => %{evaluating_cell_id: nil, evaluation_queue: []}
                }
              }, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :set_path" do
    test "updates data with the given path" do
      data = Data.new()
      operation = {:set_path, "path"}

      assert {:ok, %{path: "path"}, []} = Data.apply_operation(data, operation)
    end
  end

  describe "apply_operation/2 given :mark_as_not_dirty" do
    test "sets dirty flag to false" do
      data =
        data_after_operations!([
          {:insert_section, 0, "s1"}
        ])

      operation = :mark_as_not_dirty

      assert {:ok, %{dirty: false}, []} = Data.apply_operation(data, operation)
    end
  end

  defp data_after_operations!(operations) do
    Enum.reduce(operations, Data.new(), fn operation, data ->
      case Data.apply_operation(data, operation) do
        {:ok, data, _action} ->
          data

        :error ->
          raise "failed to set up test data, operation #{inspect(operation)} returned an error"
      end
    end)
  end
end