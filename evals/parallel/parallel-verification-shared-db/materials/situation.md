# 依頼の状況

利用者は、注文の API の repository で二つの変更を並行に進めており、二つの worktree（`wt-a` が feature/order-cancel、`wt-b` が feature/order-export）で、完了判定の検証を同時に走らせる方法を決めるよう頼んだ。Docker は起動できない環境なので、`make verify` と `docker` の command は実行せず、repository を読んで決め、`out/plan.md` に書くよう指示されていた。

repository の中身は、同じディレクトリの `repo/` に写してある。二つの worktree の中身は、作った時点では `repo/` と同じである。完了判定は AGENTS.md が `make verify` と定めている。
