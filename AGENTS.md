# AGENTS.md

このrepositoryは、変更、commit、push、PR、mergeの権限とhuman gateを解決する単一plugin marketplaceである。marketplaceへ公開するインストール対象は、利用者の変更作業を完了させる`agent-work-policy`だけにする。内部処理や管理者判定を別entryへ分解せず、他の作業pluginを追加しない。変更後は`bash scripts/validate.sh`を実行する。
