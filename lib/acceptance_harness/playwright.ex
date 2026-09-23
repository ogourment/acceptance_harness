defmodule AcceptanceHarness.Playwright do
  @moduledoc """
  Helpers for acceptance-mode Playwright startup.
  """

  @grid_drag_script """
  async ({sourceSelector, boardSelector, row, col, pointerId}) => {
    const source = document.querySelector(sourceSelector);
    const board = document.querySelector(boardSelector);
    if (!source || !board) {
      return {ok: false, reason: source ? 'missing_board' : 'missing_source'};
    }

    source.scrollIntoView({block: 'center', inline: 'center'});
    await new Promise((resolve) => requestAnimationFrame(resolve));

    const sourceRect = source.getBoundingClientRect();
    const boardRect = board.getBoundingClientRect();
    const cellSize = Number.parseInt(board.dataset.cellSize || '0', 10);
    const columns = Number.parseInt(board.dataset.columns || '0', 10);
    const intrinsicWidth =
      Number.parseFloat(board.getAttribute('width')) ||
      board.viewBox?.baseVal?.width ||
      (columns > 0 ? columns * cellSize : 0) ||
      boardRect.width;
    const scale = intrinsicWidth > 0 ? boardRect.width / intrinsicWidth : 1;

    if (!(cellSize > 0) || !(scale > 0)) {
      return {ok: false, reason: 'invalid_board_geometry'};
    }

    const startX = sourceRect.left + sourceRect.width / 2;
    const startY = sourceRect.top + sourceRect.height / 2;
    const targetX = boardRect.left + (col + 0.5) * cellSize * scale;
    const targetY = boardRect.top + (row + 0.5) * cellSize * scale;
    const eventOptions = {
      bubbles: true,
      button: 0,
      buttons: 1,
      isPrimary: true,
      pointerId,
      pointerType: 'mouse'
    };

    source.dispatchEvent(new PointerEvent('pointerdown', {
      ...eventOptions,
      clientX: startX,
      clientY: startY
    }));
    await new Promise((resolve) => window.setTimeout(resolve, 75));
    document.dispatchEvent(new PointerEvent('pointermove', {
      ...eventOptions,
      clientX: targetX,
      clientY: targetY
    }));
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    document.dispatchEvent(new PointerEvent('pointerup', {
      ...eventOptions,
      buttons: 0,
      clientX: targetX,
      clientY: targetY
    }));

    return {ok: true};
  }
  """

  @reset_browser_state_script """
  async () => {
    const skipped = [];
    const reset = async (surface, operation) => {
      try {
        await operation();
      } catch (error) {
        if (error?.name === 'InvalidStateError' || error?.name === 'SecurityError') {
          skipped.push({surface, reason: error.name});
          return;
        }

        throw error;
      }
    };

    await reset('localStorage', async () => window.localStorage.clear());
    await reset('sessionStorage', async () => window.sessionStorage.clear());

    if ('caches' in window) {
      await reset('caches', async () => {
        const cacheNames = await window.caches.keys();
        await Promise.all(cacheNames.map((name) => window.caches.delete(name)));
      });
    }

    if ('serviceWorker' in navigator) {
      await reset('serviceWorker', async () => {
        const registrations = await navigator.serviceWorker.getRegistrations();
        await Promise.all(registrations.map((registration) => registration.unregister()));
      });
    }

    if ('indexedDB' in window && typeof window.indexedDB.databases === 'function') {
      await reset('indexedDB', async () => {
        const databases = await window.indexedDB.databases();

        await Promise.all(
          databases
            .filter((database) => database.name)
            .map((database) => new Promise((resolve) => {
              const request = window.indexedDB.deleteDatabase(database.name);
              request.onsuccess = () => resolve();
              request.onerror = () => resolve();
              request.onblocked = () => resolve();
            }))
        );
      });
    }

    return {ok: true, skipped};
  }
  """

  def acceptance? do
    System.get_env("ATDD") == "true" or System.get_env("ACCEPTANCE") == "true"
  end

  def start_if_acceptance! do
    if acceptance?() do
      {:ok, _pid} = apply(Module.concat([PhoenixTest, Playwright, Supervisor]), :start_link, [])
    end

    :ok
  end

  @doc """
  Clears browser identity and current-origin persisted state.

  A Playwright case already receives a fresh browser context per test. Use this
  helper only when one scenario intentionally switches actors. It clears all
  context cookies plus the current origin's local storage, session storage,
  Cache Storage, service workers, and IndexedDB databases.
  """
  def reset_browser_state(conn, opts \\ []) do
    cookie_clearer = Keyword.get(opts, :cookie_clearer, &clear_cookies/1)
    evaluator = Keyword.get(opts, :evaluator, &evaluate/4)

    conn = cookie_clearer.(conn)

    evaluator.(conn, @reset_browser_state_script, [is_function: true], fn
      %{"ok" => true} -> :ok
      %{ok: true} -> :ok
      result -> raise "Playwright browser-state reset failed: #{inspect(result)}"
    end)
  end

  @doc """
  Resets browser state and then authenticates the next actor.

  The login function receives and returns the browser connection.
  """
  def switch_browser_identity(conn, login_fun) when is_function(login_fun, 1) do
    conn
    |> reset_browser_state()
    |> login_fun.()
  end

  @doc """
  Drags a browser element to a row/column cell on an SVG grid.

  The grid must expose its cell size through `data-cell-size` and an intrinsic
  `width` or rendered width. The interaction dispatches primary pointer events,
  so it exercises pointer-driven hooks rather than mutating DOM or server state
  directly.

  Options:

    * `:board` - grid selector, defaults to `.puzzle-board`
    * `:pointer_id` - pointer identifier, defaults to `41`

  """
  def drag_to_grid_cell(conn, source_selector, row, col, opts \\ [])
      when is_binary(source_selector) and is_integer(row) and row >= 0 and is_integer(col) and
             col >= 0 do
    board_selector = Keyword.get(opts, :board, ".puzzle-board")
    pointer_id = Keyword.get(opts, :pointer_id, 41)
    evaluator = Keyword.get(opts, :evaluator, &evaluate/4)

    args = %{
      boardSelector: board_selector,
      col: col,
      pointerId: pointer_id,
      row: row,
      sourceSelector: source_selector
    }

    evaluator.(conn, @grid_drag_script, [is_function: true, arg: args], fn
      %{"ok" => true} -> :ok
      %{ok: true} -> :ok
      result -> raise "Playwright grid drag failed: #{inspect(result)}"
    end)
  end

  defp evaluate(conn, expression, opts, callback) do
    apply(
      Module.concat([PhoenixTest, Playwright]),
      :evaluate,
      [conn, expression, opts, callback]
    )
  end

  defp clear_cookies(conn) do
    apply(Module.concat([PhoenixTest, Playwright]), :clear_cookies, [conn])
  end
end
