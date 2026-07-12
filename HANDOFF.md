# qa-chat-poc 引き継ぎメモ（2026-07-12 時点）

## 0. 最優先の未解決問題（ここから読む）

**症状**: 社内（corp）環境で、チャットに質問を入力しても **broker が検知しない**（回答が返らない）。

**状態更新（2026-07-12）**: **local(n365) の pending モード E2E は現行 `broker.ps1` で実機確認済み**。起動→質問(実UI `send()`)→`[broker] detected new item 25`→接地回答(qwen2.5:7b「緊急(P1)…4時間以内」= manual §5)→`DisplayedAt` 反映 まで通った（送信→表示 約20秒）。**sessionId 修正(f7dc472)もライブ確認**（注入UIの `cfg.sessionId` == broker session == sessionStorage）。→ 詳細と再現手順は §11。**corp は開発機から到達不可のため未検証**（§11 のカットオーバ手順を corp 実機で実施すること）。

**その際見つけた地雷**: 検証テナントに **Power Automate フロー `QA_PoC-detect`（作成トリガ→Status=Detected）が生きている**。回答済みアイテムを ~37秒後に Answered→Detected へ戻す。回答表示自体は無事だが、**`Build-Messages` の履歴クエリ `Status eq 'Answered'` から漏れて会話履歴が壊れる（次ターンで文脈喪失）**ことを実測。pending モードでは **このフローを止める**のが正（§11）。

### 「検知されない」の切り分けチェックリスト
1. **起動ログ2行目 `pickup mode:` を確認**
   - `detected` → Power Automate が `Pending→Detected` にするのを待つ。PA未設定/遅いと検知しない/遅い。→ `config.json` を `"pickup":"pending"` にして broker 再起動で ≤2.5秒 直接拾い（PA不要）。
2. **質問時に broker コンソールへ `[broker] detected new item <id> ...` が出るか**
   - 出ない → SessionId ズレ か filter/権限。出るが遅い → poll間隔 or 単一スレッドで前の回答生成中。
3. **SessionId ズレ（本命バグ・修正＋自動化済み）**: `chat-ui.js` は以前 `sessionStorage` の旧SIDを優先し、broker再起動後に旧SIDで投稿→broker新SIDで探す→永久に不一致だった。commit `f7dc472` で `CFG.sessionId` 優先に修正。**さらに `Launch-Edge` に `Kill-ProfileEdge` を追加**（起動時に `.edgeprofile` の残骸msedgeだけkill→新規Edge起動）。これで**再起動のたびに専用Edgeが新規ロードされ新SIDでマウントされる＝手動リロード不要・通常Edgeは無傷**。2026-07-12実機確認: 通常Edge22プロセス残存のまま、旧PoC Edge13を掃除→新SID `fbaafd21` でマウント→item26検知・回答（§11）。※古い専用Edgeを**開いたまま**にしても自動掃除されるので、以前の「Ctrl+Shift+R必須」はもう不要。万一SIDがズレて見えたら旧UI残存なので `Ctrl+Shift+R`。
4. 単一スレッド制約: broker は poll→claim→（埋め込み＋総当りcosine＋LLM）→書き戻し を同期実行。回答生成中は次のpollが走らない＝busy中の新質問は遅延。

## 1. リポジトリ / 実行

- GitHub: https://github.com/trie0000/qa-chat-poc （**public**）。ローカル: `C:\Users\trie0\mytools\qa-chat-poc`
- 最新コミット: `f7dc472`（このHANDOFF.mdは未コミット。要らなければ消してよい）
- **Python は全廃。PowerShell 一本**（`broker.ps1` / `build_index.ps1`、Windows標準のみ・追加インストール不要）
- 起動: `start.bat`（`powershell -NoProfile -File broker.ps1` を叩くだけ）
  - `running scripts is disabled` が出たら一度: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
- 索引再生成（マニュアル変更時のみ）: `powershell -NoProfile -File build_index.ps1`

## 2. アーキテクチャ（要点）

```
利用者ブラウザ(chat-ui.js) --SPO REST--> QA_PoC リストに質問追加(Status=Pending, SessionId, Turn)
  [detectedモード] Power Automate: 作成トリガ -> Status=Detected, DetectedAt=utcNow()
  broker.ps1(ローカル/常駐): 自SessionIdの Detected(or Pending) を poll -> claim(ETag) -> RAG検索 -> LLM回答 -> Answer/Answered 書き戻し
利用者ブラウザ: 自SessionIdの Answered を poll -> 吹き出し表示 -> DisplayedAt 書き戻し
```

- **設計の肝**: broker は SPO 認証を持たない。全 SPO REST は **CDP `Runtime.evaluate` → 認証済みブラウザ内 `fetch`(credentials:'include')** で実行。CDP は `System.Net.WebSockets.ClientWebSocket`（`Add-Type` 同梱csc）。
- **retrieval backend は2つ、`Rag-Retrieve` に統一**:
  - local: Ollama（`bge-m3` 埋め込み / `qwen2.5:7b` 回答）＋ `knowledge/index.json`
  - corp: 社内API（Azure OpenAI互換）＋ Tadori セグメント（SPO上）。`config.json.corp` が埋まっていれば corp、空なら local。
- **ハイブリッドRAG（Tadori `src/search` 準拠）**: `score=(1-w)*max(0,cosine)+w*文字bigram一致率`、w=`rag_keyword_weight`(既定0.4)。glossary.json でクエリ展開、`「」`/`""` でmustContain、OneNoteはconversationId重複除去。

## 3. config.json 主要キー（`config.example.json` 参照。config.json は gitignore）

- `site_url` / `list_title`(QA_PoC) / `ui_code_url` / `browser_path` / `cdp_port`(9222)
- `poll_interval_ms`(2500) / `history_max_turns`(10) / `top_k`(4) / `rag_keyword_weight`(0.4)
- `pickup`: `"detected"`(PA必須) | `"pending"`(PA不要・直接・速い)
- `corp`: `base_url` `deploy_prefix` `chat_model` `embed_model` `embed_api_version` `dimensions` `seg_url` `api_key` `proxy_url`
  - `base_url` = **tadori の `TADORI_AI_TARGET` と同値**（ゲートウェイ直・末尾/やパス接頭辞不問）。broker はサーバサイドPSなので **tadoriリレー不要**。社内proxyがシステム既定と別なら `proxy_url` 指定。
  - `seg_url` = **Tadori セグメントフォルダ**（既定 `<site>/Shared Documents/Tadori`。`manifest.json`+`seg-NNNNN.json`）。**共有リンク(`/:f:/r/...`)/`AllItems.aspx?id=`/フォルダURL/サーバ相対 いずれも自動正規化**。site_urlと別サイトでも可（同一テナント＝同Cookie）。
  - デプロイ名 = `deploy_prefix + model名(ドット除去)`（例 `dev-gpt-41-mini`）。

## 4. corp セグメント形式（tadori実物・`trie0000/tadori` で確認済み）

- 配置: `<site>/<library>/Tadori/` に `manifest.json` + `seg-NNNNN.json`
- manifest: `{version,generation,maxSeq, sealed:[seg id], open:{id,hash,count}|null, updatedAt}`（一覧は `sealed[]`＋`open`）
- seg: `{id,generation,records[]}`、record: `{seq,op:'upsert'|'delete',messageId,conversationId?,kind?,subject?,body?, emb?}`。**埋め込み欄は `emb`**（base64 Float16, LE）。
- 読取: `{web}/_api/web/GetFileByServerRelativeUrl('<encodeURIComponent(path)>')/$value`（ファイル直URLのGETはビューア/リダイレクトで不可）。
- 解決: 追記式 upsert/delete を **messageId単位 last-writer-wins**、OneNoteはconversationId重複除去。

## 5. 検証済み / 未検証（正直に）

- **済（ユニット/静的）**: PS ParseFile、ASCII-only(0)、float16デコード一致、デプロイ名導出、チャンク分割がPython版と18/18一致＋埋め込みcosine=1.0、seg_url正規化(4形式)、ハイブリッドscore/glossary展開/mustContain+fallback/onenote dedup（合成データ）、IRMのUTF-8化けをlatin1で再現し修正確認。
- **未（実機E2E）**: 現行broker.ps1で起動→質問→検知→回答→表示の通し。**corpの実接続（社内API/実glossary/実segments）はこの開発機から到達不可で恒久的に未検証**。localE2Eは旧版では通っていたが現行版では未再走。

## 6. PowerShell 固有の地雷（何度も踏んだ。必読）

- **broker.ps1 は ASCII-only 厳守**。`.ps1` に日本語リテラルを書くと BOM無しUTF-8を `powershell -File` が CP932解釈して parse崩壊（`&不許可`/`文字列終端なし`が日本語行周辺から連鎖）。診断: `[Parser]::ParseFile`(壊れる) と `ParseInput`(通る) の食い違い＝日本語混入のサイン。日本語必要ならコード点 `[char]0x300C` 等で組む。日本語データは config/SPO から読む。**コンソール出力もASCII**（日本語データはログに出さない＝化ける。qlen等で代替）。
- **`Invoke-RestMethod`(5.1) は Content-Typeにcharset無いと本文をISO-8859-1復号**→UTF-8日本語化け。corp応答で発生。対策済: `Invoke-WebRequest -UseBasicParsing` + `[Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())|ConvertFrom-Json`。
- **単一要素配列の戻り値がスカラーに開封される**→`$x.Count`が`$null`で「0件」誤判定（mustContainフォールバック誤発火の原因だった）。呼出境界を `@(func ...)` で包む。
- `sp` は `Set-ItemProperty` の組込AllScopeエイリアス→関数名は `SpReq`。
- SPリスト項目は `Id` と `ID` 両方返す→`ConvertFrom-Json` が大小無視で重複キー失敗→fetch側で`ID`削除。

## 7. CDP/Edge 地雷

- WS403: `--remote-allow-origins=*` ＋ ClientWebSocketはOrigin送らないのでOK。
- loopbackはproxy迂回（.NET DefaultWebProxyが自動bypass）。CDPは127.0.0.1直。
- 専用プロファイル `.edgeprofile` の SingletonLock: 既存msedgeを cmdline一致でkillしてから再起動。
- 認証はユーザが手でサインイン（broker は資格情報を持たない）。`Wait-Auth` が `/_api/web?$select=Title` 成功までpoll。専用プロファイルにセッション残れば2回目以降サイレント。
- モダンSPは `_spPageContextInfo` 未定義→`webServerRelativeUrl` を注入。CSPはinline script不可だがCDP evalは迂回。UIはSPOライブラリの最新を毎回fetch（ローカル同梱しない）。

## 8. 主なコミット履歴（新しい順・抜粋）

- `f7dc472` UI: sessionId は broker注入を優先（再起動後の検知不能を修正）
- `359334b` broker: pickup mode を起動最初に出力
- `018557d` broker: pickup modeログ明確化＋アイテム検知ログ
- `ab8d19f` rag: ハイブリッド(ベクトル+キーワード)検索・glossary展開・mustContain・dedup
- `4fef514` broker: pickup を config化（pending=PA不要）
- `d5a4b7a` corp: 応答をUTF-8復号（PS5.1化け修正）
- `9a51411` corp: seg_url正規化（共有リンク/AllItems/別サイト）
- `522a4e6` corp: tadori実セグメント形式に整合＋ASCII-only維持
- `88a1e4a` docs: base_url == TADORI_AI_TARGET
- （さらに前）corpモードをbroker.ps1へ移植・Python全廃、UIから設定排除、等

## 9. 記憶（`C:\Users\trie0\.claude\projects\C--Users-trie0-mytools-sp-test\memory\`）

- `tadori-corp-search-contract.md` — 社内API契約・セグメント形式・ハイブリッド検索
- `cdp-edge-automation-gotchas.md` — 上記PS/CDP地雷（ASCII-only, IRM utf8, 単一要素開封, WS403 等）
- `spo-modern-page-injection.md` / `ollama-japanese-rag.md` / ほか

## 10. 次セッションの推奨着手順
1. ~~local Ollama E2E~~ **→ 完了（2026-07-12, §11）**。
2. corp 環境へ: **§11 のカットオーバ手順**を corp 実機で実施。
3. 検知しないなら §0チェックリスト順に（pickup / detected new item の有無 / SID反映手順 / 権限）。

## 11. local E2E 実機確認記録（2026-07-12）と corp カットオーバ手順

### 確認済みの通し（n365, pickup=pending, corp空, local Ollama）
- 起動ログ健全: `session <guid>` / `pickup mode: pending` / `CDP connected` / `authenticated`(専用プロファイルにセッション残存でサイレント) / `chat-ui.js uploaded (ok)` / `UI injected` / `local Ollama RAG: 18 chunks` / `monitoring ... filter: (Status eq 'Pending' or Status eq 'Detected')`。
- 質問→検知→回答: 実UIの `send()` で item 25 を Pending 投稿(sid=broker session) → `[broker] detected new item 25` → `picked` → `retrieved`(SLA/FAQ等) → `answered item 25 (130 chars)`。回答は接地・正答（「緊急(P1)…4時間以内」= manual §5）。UI に吹き出し表示＋`DisplayedAt` 反映、`⏱ 応答 20.0秒`。`latency.csv` に行も記録。
- **診断ツール**: `scratchpad/cdp-eval.ps1`（最小 `ClientWebSocket` CDP クライアント）。稼働中の broker の Edge(:9222) に**別CDPクライアントで相乗り**して `Runtime.evaluate`→認証済みブラウザfetchでリスト照会/UIのSID確認ができる（複数CDPクライアント可）。corp の SID不一致/リスト状態/権限の切り分けにそのまま使える。

### 見つけた地雷: PA フロー `QA_PoC-detect` が生きている
- 症状: 回答済み item を **~37秒後に Answered→Detected へ戻す**（作成トリガの遅延発火）。
- 影響: (1) リスト上の Status が Detected のまま残る。(2) broker が PA より遅いと Status/latency が乱れる（今回は pending が速く無害）。(3) **会話履歴が壊れる** — `Build-Messages` は `Status eq 'Answered'` で履歴を組むので、戻された item が抜けて次ターンが文脈を失う（実測: 履歴クエリ 0 件）。
- 対処: **pending モードでは `QA_PoC-detect` を make.powerautomate.com で無効化**（PoC の設計意図＝pending は PA 不要）。corp 側でフローを止められない場合の代替ハードニング: 履歴クエリと `Reap-Latency` の判定を `Status eq 'Answered'` → `AnsweredAt ne null` に変える（回答後の Status 上書きに耐える）。※未実装・要判断。

### corp カットオーバ手順（corp 実機で・順番厳守）
1. `config.json` に corp を設定（`base_url`=TADORI_AI_TARGET、`api_key`、`seg_url`、`deploy_prefix`、`dimensions` 等）。**`pickup:"pending"` を強く推奨**（今回 pending は PA非依存で ≤2.5秒 検知を実証。`detected` は corp-PA の故障/遅延で「検知されない」に化ける）。
2. **broker 再起動するだけ**（`Kill-ProfileEdge` が `.edgeprofile` の残骸Edgeを自動掃除→新規Edgeが新SIDでマウント。通常Edgeは無傷、手動でEdgeを閉じる/リロードする必要なし）。旧手順の Ctrl+Shift+R は不要になった。
3. 起動ログ確認: `pickup mode: pending` と `corp seg location:` / `corp manifest: sealed=..` / `corp search ON: N records dim=D`。0件や dim 不一致は `WARNING` 行が出る。
4. 質問して `[broker] detected new item` を待つ:
   - **出る** → 検知はOK。以降の失敗は corp.*（seg_url/api_key/dim）で、回答が Error になるだけ＝非検知ではない。
   - **出ない** → SID不一致 or リスト読取権限。SPページのコンソールで `window.__QA_CONFIG__.sessionId` と `sessionStorage.qa_sid` が broker の `session <guid>` と一致するか確認。ズレていれば旧UIが残存 → 再度ハードリロード。`scratchpad/cdp-eval.ps1` でも確認可。
