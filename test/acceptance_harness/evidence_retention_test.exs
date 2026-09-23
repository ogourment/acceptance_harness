defmodule AcceptanceHarness.EvidenceRetentionTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.EvidenceRetention

  @now ~U[2026-07-22 12:00:00Z]

  test "keeps every recent run and tier representatives, archiving other runs" do
    runs = [
      run("recent-a", 1),
      run("recent-b", 2),
      run("daily-new", 5),
      run("daily-old", 5, -1),
      run("weekly-new", 29),
      run("weekly-old", 30),
      run("monthly-new", 120),
      run("monthly-old", 121),
      run("expired", 1_096)
    ]

    decisions = EvidenceRetention.plan(runs, now: @now)
    actions = Map.new(decisions, &{&1.run.id, &1.action})

    assert actions == %{
             "recent-a" => :keep_full,
             "recent-b" => :keep_full,
             "daily-new" => :keep_full,
             "daily-old" => :archive,
             "weekly-new" => :keep_full,
             "weekly-old" => :archive,
             "monthly-new" => :keep_full,
             "monthly-old" => :archive,
             "expired" => :archive
           }
  end

  test "tiers and current time are configurable" do
    decisions =
      EvidenceRetention.plan([run("newest", 2), run("older", 3)],
        now: @now,
        full_days: 1,
        daily_days: 2,
        weekly_days: 2,
        monthly_days: 2
      )

    assert Enum.map(decisions, &{&1.run.id, &1.action}) == [
             {"newest", :keep_full},
             {"older", :archive}
           ]
  end

  test "archives non-representative screenshots once and deletes oldest archives to fit cap" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    runs =
      for {id, days, bytes} <- [
            {"current", 1, 30},
            {"daily", 5, 30},
            {"daily-duplicate", 5, 30},
            {"expired", 1_200, 30}
          ] do
        source_dir = Path.join(root, id)
        File.mkdir_p!(Path.join(source_dir, "screenshots"))
        File.write!(Path.join([source_dir, "screenshots", "one.png"]), :binary.copy("x", bytes))
        create_thumbnail(source_dir)
        run(id, days) |> Map.put(:source_dir, source_dir)
      end

    thumbnailer = fn _source, temporary, _geometry -> File.write(temporary, "thumb") end

    assert {:ok, summary} =
             EvidenceRetention.apply(runs,
               root: root,
               now: @now,
               max_bytes: 75,
               thumbnailer: thumbnailer
             )

    assert summary.archived == ["daily-duplicate", "expired"]
    assert summary.forced_archived == ["daily"]
    assert summary.deleted == []
    assert summary.bytes == 50
    assert summary.over_limit_bytes == 0
    refute File.exists?(Path.join([root, "daily-duplicate", "screenshots", "one.png"]))
    assert File.read!(Path.join([root, "daily-duplicate", "thumbnails", "one.webp"])) == "thumb"
    refute File.exists?(Path.join([root, "expired", "screenshots", "one.png"]))
    assert File.dir?(Path.join(root, "expired"))

    fail_if_called = fn _source, _temporary, _geometry -> flunk("archive was applied twice") end

    assert {:ok, second} =
             EvidenceRetention.apply(runs,
               root: root,
               now: @now,
               max_bytes: 75,
               thumbnailer: fail_if_called
             )

    assert second.archived == []
  end

  test "deletes the oldest retained representative when thumbnails cannot satisfy the cap" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    current_dir = create_run_dir(root, "current", 20)
    older_dir = create_run_dir(root, "older", 20)
    create_thumbnail(current_dir)
    create_thumbnail(older_dir)

    assert {:ok, summary} =
             EvidenceRetention.apply(
               [
                 run("current", 1) |> Map.put(:source_dir, current_dir),
                 run("older", 2) |> Map.put(:source_dir, older_dir)
               ],
               root: root,
               now: @now,
               max_bytes: 30
             )

    assert summary.forced_archived == ["older"]
    assert summary.deleted == []
    assert summary.bytes == 30
    assert summary.over_limit_bytes == 0
    assert File.exists?(Path.join([current_dir, "screenshots", "one.png"]))
    refute File.exists?(Path.join([older_dir, "screenshots", "one.png"]))
  end

  test "protects the newest run and reports when it alone exceeds the cap" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    source_dir = create_run_dir(root, "current", 20)

    assert {:ok, summary} =
             EvidenceRetention.apply([run("current", 1) |> Map.put(:source_dir, source_dir)],
               root: root,
               now: @now,
               max_bytes: 10
             )

    assert summary.deleted == []
    assert summary.bytes == 20
    assert summary.over_limit_bytes == 10
    assert File.exists?(Path.join([source_dir, "screenshots", "one.png"]))
  end

  test "optionally removes allowlisted imported payloads while preserving run directories" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    source_dir = create_run_dir(root, "current", 20)
    File.write!(Path.join(source_dir, "evidence.json"), :binary.copy("e", 50_000))
    File.write!(Path.join(source_dir, "keep.txt"), "keep")

    assert {:ok, summary} =
             EvidenceRetention.apply([run("current", 1) |> Map.put(:source_dir, source_dir)],
               root: root,
               now: @now,
               prune_payload_names: ["evidence.json"]
             )

    assert summary.pruned_payloads == [%{run_id: "current", name: "evidence.json"}]
    refute File.exists?(Path.join(source_dir, "evidence.json"))
    assert File.read!(Path.join(source_dir, "keep.txt")) == "keep"
    assert File.dir?(source_dir)
  end

  test "reports imported runs whose local screenshot directory is already gone" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    missing = Path.join(root, "missing")

    assert {:ok, summary} =
             EvidenceRetention.apply([run("missing", 1_200) |> Map.put(:source_dir, missing)],
               root: root,
               now: @now,
               max_bytes: 10
             )

    assert [%{run_id: "missing", reason: {:missing_directory, "missing", ^missing}}] =
             summary.skipped

    assert summary.bytes == 0
  end

  test "counts hardlinked screenshots once and never deletes retained links" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    current_dir = create_run_dir(root, "current", 20)
    archived_dir = Path.join(root, "expired")
    File.mkdir_p!(Path.join(archived_dir, "screenshots"))

    current_file = Path.join([current_dir, "screenshots", "one.png"])
    archived_file = Path.join([archived_dir, "screenshots", "one.png"])
    File.ln!(current_file, archived_file)
    create_thumbnail(archived_dir)

    runs = [
      run("current", 1) |> Map.put(:source_dir, current_dir),
      run("expired", 1_200) |> Map.put(:source_dir, archived_dir)
    ]

    assert {:ok, summary} =
             EvidenceRetention.apply(runs, root: root, now: @now, max_bytes: 10)

    assert summary.deleted == ["expired"]
    assert summary.bytes == 20
    assert summary.over_limit_bytes == 10
    assert File.read!(current_file) == :binary.copy("x", 20)
    refute File.exists?(archived_file)
  end

  test "refuses run paths outside the root and screenshot directory symlinks" do
    root = temp_root()
    outside = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, {:outside_root, "outside", ^outside}} =
             EvidenceRetention.apply([run("outside", 1_200) |> Map.put(:source_dir, outside)],
               root: root,
               now: @now,
               skip_unmanaged: false
             )

    source_dir = Path.join(root, "linked")
    File.mkdir_p!(source_dir)
    File.ln_s!(outside, Path.join(source_dir, "screenshots"))

    assert {:error, {:unsafe_symlink, "linked", _path}} =
             EvidenceRetention.apply([run("linked", 1_200) |> Map.put(:source_dir, source_dir)],
               root: root,
               now: @now
             )

    actual_parent = Path.join(outside, "parent")
    linked_parent = Path.join(root, "linked-parent")
    create_run_dir(outside, "parent/run", 20)
    File.ln_s!(actual_parent, linked_parent)

    assert {:error, {:unsafe_symlink, "linked-parent", ^linked_parent}} =
             EvidenceRetention.apply(
               [
                 run("linked-parent", 1_200)
                 |> Map.put(:source_dir, Path.join(linked_parent, "run"))
               ],
               root: root,
               now: @now
             )
  end

  test "skips legacy imported paths outside the managed root by default" do
    root = temp_root()
    outside = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.mkdir_p!(Path.join(outside, "screenshots"))

    assert {:ok, summary} =
             EvidenceRetention.apply([run("legacy", 1_200) |> Map.put(:source_dir, outside)],
               root: root,
               now: @now
             )

    assert [%{run_id: "legacy", reason: {:outside_root, "legacy", ^outside}}] = summary.skipped
    assert summary.decisions == []
  end

  test "does not replace originals when thumbnail generation fails" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    source_dir = create_run_dir(root, "expired", 20)

    thumbnailer = fn source, temporary, _geometry ->
      if String.ends_with?(source, "one.png") do
        File.write(temporary, "thumbnail")
      else
        {:error, :broken_image}
      end
    end

    File.write!(Path.join([source_dir, "screenshots", "two.png"]), "original-two")

    assert {:error, {:archive_failed, "expired", {:thumbnail_failed, _path, :broken_image}}} =
             EvidenceRetention.apply([run("expired", 1_200) |> Map.put(:source_dir, source_dir)],
               root: root,
               now: @now,
               thumbnailer: thumbnailer
             )

    assert File.read!(Path.join([source_dir, "screenshots", "one.png"])) ==
             :binary.copy("x", 20)

    assert File.read!(Path.join([source_dir, "screenshots", "two.png"])) == "original-two"
  end

  test "keeps legacy originals and reports archive skipped when no thumbnail exists" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    source_dir = create_run_dir(root, "expired", 20)

    assert {:ok, summary} =
             EvidenceRetention.apply([run("expired", 1_200) |> Map.put(:source_dir, source_dir)],
               root: root,
               now: @now
             )

    assert [%{run_id: "expired", reason: {:missing_thumbnail, _source, _thumbnail}}] =
             summary.archive_skipped

    assert File.exists?(Path.join([source_dir, "screenshots", "one.png"]))
  end

  test "counts and deletes the oldest unreferenced snapshot under cap pressure" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    current_dir = create_run_dir(root, "snapshot-current", 20)
    orphan_dir = create_run_dir(root, "snapshot-orphan", 30)
    create_thumbnail(orphan_dir)
    File.write!(Path.join(orphan_dir, "evidence.json"), "already imported")
    File.touch!(orphan_dir, DateTime.to_unix(@now) - 3_600)

    assert {:ok, summary} =
             EvidenceRetention.apply(
               [run("current", 1) |> Map.put(:source_dir, current_dir)],
               root: root,
               now: @now,
               max_bytes: 25,
               snapshot_prefix: "snapshot-",
               orphan_grace_seconds: 60
             )

    assert summary.deleted_orphans == ["snapshot-orphan"]
    assert summary.orphan_snapshots == ["snapshot-orphan"]
    refute File.exists?(orphan_dir)
    assert File.dir?(current_dir)
    assert summary.bytes == 20
  end

  test "counts but protects current, in-progress, and grace-period orphan snapshots" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    current_dir = create_run_dir(root, "snapshot-current", 10)
    in_progress_dir = create_run_dir(root, "snapshot-uploading", 10)
    recent_dir = create_run_dir(root, "snapshot-recent", 10)
    File.write!(Path.join(in_progress_dir, ".in-progress"), "uploading")
    File.ln_s!(Path.basename(current_dir), Path.join(root, "current"))
    File.touch!(current_dir, DateTime.to_unix(@now) - 3_600)
    File.touch!(in_progress_dir, DateTime.to_unix(@now) - 3_600)
    File.touch!(recent_dir, DateTime.to_unix(@now) - 30)

    assert {:ok, summary} =
             EvidenceRetention.apply([],
               root: root,
               now: @now,
               max_bytes: 1,
               snapshot_prefix: "snapshot-",
               orphan_grace_seconds: 60
             )

    assert summary.deleted_orphans == []
    assert summary.bytes == 30
    assert summary.over_limit_bytes == 29
    assert %{name: "snapshot-current", reason: :current} in summary.orphan_skipped
    assert %{name: "snapshot-uploading", reason: :in_progress} in summary.orphan_skipped
    assert %{name: "snapshot-recent", reason: :grace_period} in summary.orphan_skipped
    assert File.dir?(current_dir)
    assert File.dir?(in_progress_dir)
    assert File.dir?(recent_dir)
  end

  test "keeps protected orphan bytes in the cap while cleaning referenced evidence" do
    root = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    current_dir = create_run_dir(root, "run-current", 20)
    older_dir = create_run_dir(root, "run-older", 20)
    protected_dir = create_run_dir(root, "snapshot-uploading", 20)
    create_thumbnail(current_dir)
    create_thumbnail(older_dir)
    File.write!(Path.join(protected_dir, ".in-progress"), "uploading")
    File.touch!(protected_dir, DateTime.to_unix(@now) - 3_600)

    runs = [
      run("current", 1) |> Map.put(:source_dir, current_dir),
      run("older", 2) |> Map.put(:source_dir, older_dir)
    ]

    assert {:ok, summary} =
             EvidenceRetention.apply(runs,
               root: root,
               now: @now,
               max_bytes: 35,
               snapshot_prefix: "snapshot-",
               orphan_grace_seconds: 60
             )

    assert summary.forced_archived == ["older"]
    assert summary.deleted == ["older"]
    assert summary.deleted_orphans == []
    assert summary.bytes == 45
    assert summary.over_limit_bytes == 10
    assert File.dir?(protected_dir)
    assert File.exists?(Path.join([current_dir, "screenshots", "one.png"]))
    refute File.exists?(Path.join([older_dir, "screenshots", "one.png"]))
    refute File.exists?(Path.join([older_dir, "thumbnails", "one.webp"]))
  end

  test "never follows or deletes a symlink matching the snapshot prefix" do
    root = temp_root()
    outside = temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "keep.txt"), "keep")
    link = Path.join(root, "snapshot-linked")
    File.ln_s!(outside, link)

    assert {:ok, summary} =
             EvidenceRetention.apply([],
               root: root,
               now: @now,
               max_bytes: 0,
               snapshot_prefix: "snapshot-",
               orphan_grace_seconds: 0
             )

    assert summary.deleted_orphans == []
    assert %{name: "snapshot-linked", reason: :symlink} in summary.orphan_skipped
    assert File.read!(Path.join(outside, "keep.txt")) == "keep"
    assert match?({:ok, %File.Stat{type: :symlink}}, File.lstat(link))
  end

  defp run(id, days_ago, second_offset \\ 0) do
    %{id: id, generated_at: DateTime.add(@now, -days_ago * 86_400 + second_offset, :second)}
  end

  defp temp_root do
    root =
      Path.join(System.tmp_dir!(), "acceptance-retention-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root
  end

  defp create_run_dir(root, id, bytes) do
    source_dir = Path.join(root, id)
    File.mkdir_p!(Path.join(source_dir, "screenshots"))
    File.write!(Path.join([source_dir, "screenshots", "one.png"]), :binary.copy("x", bytes))
    source_dir
  end

  defp create_thumbnail(source_dir) do
    File.mkdir_p!(Path.join(source_dir, "thumbnails"))
    File.write!(Path.join([source_dir, "thumbnails", "one.webp"]), "thumb")
  end
end
