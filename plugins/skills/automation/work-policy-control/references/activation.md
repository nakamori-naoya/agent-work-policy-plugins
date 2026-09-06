# 常時適用する

**pluginのインストールだけでは、すべてのGit操作へ自動適用されない。** skillが呼ばれた作業だけが設定を読む。hooksや利用者のsettingsを配布して、黙って強制することはしない。

repositoryのすべての変更作業で使う場合は、正式な `AGENTS.md` と `CLAUDE.md` に次の趣旨を置く。

```markdown
このrepositoryで変更、commit、push、PR作成、mergeを行う前に、
agent-work-policyの work-with-policy skillを呼び、解決された設定とgateに従う。
```

特定の段取りだけへ適用する場合は、その段取りの先頭と公開操作の直前に公開入口を明示的に組み込む。別pluginの段取りからは、公開playbook `agent-work-policy` を `playbook:` 工程として組み込む（このpackageのscriptを直接実行しない）。どちらにも書かれていない作業へ適用されたとはみなさない。
