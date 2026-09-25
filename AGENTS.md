> 共通の規約は /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/AGENTS.md にある。ここには、この repository だけの規則を置く。

# agent-work-policy

この repository は、AI エージェントが `git` と `gh` で直接 commit、push、PR、base への追従、merge を行うときの規律を、skill `agent-work-policy` 一つとして配布する。skill が持つのは、エージェントが自分では外しやすい判断だけで、操作の手順、承認の object、設定ファイル、それを照合するスクリプトは持たない。merge の条件は GitHub の Ruleset に守らせ、skill の側で判定を組み立て直さない。
