# qa-chat-poc — SPOリスト中継 + ローカルAI の QAチャット検証ツール

SharePoint Online (SPO) リストを**メッセージキュー**にした QA チャット構成の
**レイテンシと成立性を検証する PoC**。

```
利用者ブラウザ(SSO) ──> SPOリストに質問登録(Pending)
   Power Automate ──> 作成を検知して Status=Detected / DetectedAt を記録
   broker.py(ローカル) ──> Detected を拾い Ollama で回答生成 ──> Answer/Answered を書き戻し
利用者ブラウザ ──> 回答を検知して吹き出し表示 / DisplayedAt を記録
```

**設計の肝**: `broker.py` は SPO の認証情報を一切持たない。SPO REST はすべて
**ブラウザのセッションに相乗り**して実行する（CDP `Runtime.evaluate` → ページ内 `fetch`）。
UIコード(`chat-ui.js`)は SPO ライブラリ上の最新版が常に読まれる（ローカルに同梱しない）。

---

## 構成

| ファイル | 役割 |
|---|---|
| `start.bat` | `broker.py` を起動する薄いラッパー（venvがあれば使用 / `chcp 65001`） |
| `broker.py` | ブラウザ起動・CDP接続・認証待ち・UI注入・監視ループ・Ollama・書き戻し・計測 |
| `config.json` | 設定（`config.example.json` をコピーして作成。gitignore 済） |
| `sharepoint/chat-ui.js` | SPOライブラリへ手動アップロードするブラウザ側UI |
| `setup/create-list.ps1` | `QA_PoC` リスト作成（PnP.PowerShell）。無い環境向けに手動手順も |
| `setup/README-PA-flow.md` | Power Automate フロー作成手順（実装対象外・仕様のみ） |
| `logs/latency.csv` | 区間別レイテンシの出力先 |

## SPOリスト `QA_PoC` スキーマ（内部名＝表示名で作成）

| 列 | 型 | 用途 |
|---|---|---|
| Title | 1行テキスト | 質問先頭50字（SP必須列を流用） |
| Question | 複数行(プレーン) | 質問全文 |
| Answer | 複数行(プレーン) | 回答全文 |
| SessionId | 1行テキスト（インデックス） | 1起動=1セッション |
| Turn | 数値 | セッション内連番 |
| Status | 選択肢 | Pending / Detected / Answering / Answered / Error |
| DetectedAt | 日付と時刻 | PA が記録 |
| AnsweredAt | 日付と時刻 | broker が記録 |
| DisplayedAt | 日付と時刻 | UI が記録 |

---

## セットアップ

1. **リスト作成**: `setup/create-list.ps1`（PnP）か、上表どおり手動で `QA_PoC` を作成。
2. **UI配置**: `sharepoint/chat-ui.js` を SPO のドキュメントライブラリ（例 `Shared Documents/qa-chat-poc/`）にアップロード。
3. **PA作成**: `setup/README-PA-flow.md` に従い「作成トリガー → Detected 更新」フローを作成。
4. **設定**: `copy config.example.json config.json` して各値を設定
   （`site_url` / `list_title` / `ui_code_url` / `browser_path` / `ollama_endpoint` / `ollama_model` ...）。
5. **依存**: `python -m venv .venv` → `.venv\Scripts\pip install websocket-client requests`。
6. **Ollama**: 対象モデル（既定 `gemma3:4b`）を `ollama pull` 済みにし、サービスを起動。

## 実行

```
start.bat をダブルクリック
```

1. 専用プロファイルの Edge が開く → **SharePoint にサインイン**（人手はここだけ）
2. 認証を検知すると `chat-ui.js` が自動注入され、右下にチャットパネルが出る
3. 質問送信 → (PA が Detected) → broker が Ollama 回答を書き戻し → パネルに表示

> 2回目以降は専用プロファイルにサインインが残るので無操作で進む。
> broker を止めて再起動しても、ブラウザ／サインイン状態は再利用される。

## 計測の読み方（`logs/latency.csv`）

1行 = 1ターン。各時刻から区間を分解できる：

| 区間 | 意味 |
|---|---|
| `CreatedAt → PA_DetectedAt` | **PAトリガー発火遅延** |
| `PA_DetectedAt → Broker_PickedAt` | broker がポーリングで拾うまで |
| `Broker_PickedAt → AnsweredAt` | **Ollama 生成時間** |
| `AnsweredAt → DisplayedAt` | **UI 反映遅延**（ポーリング周期に依存） |

（`CreatedAt` は SP アイテムの `Created`、`DisplayedAt` は UI が書いた値を broker が回収）

> ⚠ **クロック差に注意**：`CreatedAt`（SPサーバ）と `PA_DetectedAt`（PA=クラウド）は**サーバ側時計**、
> `Broker_PickedAt`/`AnsweredAt` は**ローカル(broker)時計**が刻む。両者がずれていると
> `Created→Detected→Picked` の区間が歪む（検証機では broker 側が約80秒遅れていた）。
> **同一時計で取れる `Broker_PickedAt → AnsweredAt`（＝Ollama生成時間）が最も信頼できる**。
> 正確に測るなら実行前に `w32tm /resync` 等でローカル時計を合わせること。
> なお Ollama は**初回のみモデルロードのコールドスタート**（数十秒）が乗るので、2ターン目以降で評価する。

---

## 技術メモ / 制約

- **Python から SPO へ直接 HTTP しない**（認証を持たないため）。必ず CDP → ブラウザ `fetch` 経由。
- 依存は最小（`websocket-client`, `requests`）。Playwright 等の重い依存は使わない。
- 対象ブラウザは Edge 既定 / Chrome も `browser_path` で切替可。
- Windows ネイティブ実行（WSL2ではない）。Ollama は `ollama_endpoint` で別ホストにも向けられる。
- 秘密情報（APIキー等）は扱わない。`config.json` にも置かない。
- 例外時は `Status='Error'` + `Answer` にエラー概要を書き、ループは継続（1件失敗で全体を止めない）。
- 多重処理防止：`Status='Answering'` への MERGE を **ETag 楽観ロック**（`If-Match`）で行い、成功時のみ生成へ進む。

## マルチターン

- 会話履歴は**リストが正**。broker は回答生成時に同一 `SessionId` の `Answered` を `Turn` 順に読み、
  `user/assistant` ペアで Ollama に積む（既定10ターン・各2,000字で切り詰め、`config` で変更可）。
- UI は `SessionId` を `sessionStorage` に保持し、リロードでも同一セッションを継続（broker 再起動＝新規セッション）。
