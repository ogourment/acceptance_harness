defmodule AcceptanceHarness.PlaywrightTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.Playwright

  test "resets browser identity and current-origin persisted state" do
    parent = self()

    cookie_clearer = fn conn ->
      send(parent, {:cleared_cookies, conn})
      Map.put(conn, :cookies, :cleared)
    end

    evaluator = fn conn, script, opts, callback ->
      send(parent, {:evaluated, conn, script, opts})
      assert :ok = callback.(%{"ok" => true})
      Map.put(conn, :storage, :cleared)
    end

    assert %{cookies: :cleared, storage: :cleared} =
             Playwright.reset_browser_state(%{browser: :fake},
               cookie_clearer: cookie_clearer,
               evaluator: evaluator
             )

    assert_receive {:cleared_cookies, %{browser: :fake}}

    assert_receive {:evaluated, %{cookies: :cleared}, script, [is_function: true]}
    assert script =~ "window.localStorage.clear()"
    assert script =~ "window.sessionStorage.clear()"
    assert script =~ "window.caches.keys()"
    assert script =~ "navigator.serviceWorker.getRegistrations()"
    assert script =~ "window.indexedDB.databases()"
    assert script =~ "error?.name === 'InvalidStateError'"
    assert script =~ "error?.name === 'SecurityError'"
    assert script =~ "throw error"
  end

  test "raises when persisted browser state cannot be reset" do
    evaluator = fn _conn, _script, _opts, callback ->
      callback.(%{"ok" => false, "reason" => "reset_failed"})
    end

    assert_raise RuntimeError, ~r/reset_failed/, fn ->
      Playwright.reset_browser_state(%{},
        cookie_clearer: & &1,
        evaluator: evaluator
      )
    end
  end

  test "shared case wraps the per-test Playwright context" do
    ast =
      quote do
        use AcceptanceHarness.Playwright.Case, async: false
      end

    rendered = Macro.to_string(ast)
    assert rendered =~ "use AcceptanceHarness.Playwright.Case"
    assert rendered =~ "async: false"
  end

  test "drags a source to a logical SVG grid cell through pointer events" do
    evaluator = fn conn, script, opts, callback ->
      send(self(), {:evaluate, script, opts})
      assert :ok = callback.(%{"ok" => true})
      conn
    end

    conn = %{browser: :fake}

    assert ^conn =
             Playwright.drag_to_grid_cell(conn, "#piece-7", 2, 3,
               board: "#board",
               pointer_id: 9,
               evaluator: evaluator
             )

    assert_receive {:evaluate, script, [is_function: true, arg: args]}
    assert script =~ "new PointerEvent('pointerdown'"
    assert script =~ "new PointerEvent('pointermove'"
    assert script =~ "new PointerEvent('pointerup'"
    assert script =~ "window.setTimeout(resolve, 75)"
    assert script =~ "board.viewBox?.baseVal?.width"
    assert args.sourceSelector == "#piece-7"
    assert args.boardSelector == "#board"
    assert args.row == 2
    assert args.col == 3
    assert args.pointerId == 9
  end

  test "raises when the browser cannot perform the drag" do
    evaluator = fn _conn, _script, _opts, callback ->
      callback.(%{"ok" => false, "reason" => "missing_source"})
    end

    assert_raise RuntimeError, ~r/missing_source/, fn ->
      Playwright.drag_to_grid_cell(%{}, "#missing", 0, 0, evaluator: evaluator)
    end
  end
end
