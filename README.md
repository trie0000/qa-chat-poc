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
| `knowledge/manual.md` | 検証用の仮想マニュアル（RAG の知識ソース） |
| `build_index.py` | manual.md をチャンク化し Ollama で事前ベクトル化 → `knowledge/index.json` |
| `knowledge/index.json` | 事前計算した埋め込みインデックス（broker が読み込む） |
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

## セットアップ（別環境・ゼロから）

> **上表の QA_PoC リスト・列と chat-ui.js の SPO 配置は、broker が初回起動時に自動作成**します。
> 手動のリスト作成/アップロードは不要です（`setup/create-list.ps1` は参考用に残置）。

1. **前提**: Python 3.10+ / git（ローカルAIで動かすなら Ollama も）。
2. **clone + 依存**:
   ```
   git clone https://github.com/trie0000/qa-chat-poc
   cd qa-chat-poc
   python -m venv .venv
   .venv\Scripts\pip install websocket-client requests
   ```
3. **設定**: `copy config.example.json config.json` → `site_url` を実 SharePoint サイトに、
   `ui_code_url` を「そのサイト/Shared%20Documents/qa-chat-poc/chat-ui.js」に書き換え
   （`browser_path` は Edge のパス。既定のままで大抵OK）。
4. **（ローカルAIモードなら）モデル＋索引**:
   ```
   ollama pull qwen2.5:7b
   ollama pull bge-m3
   python build_index.py
   ```
   ※社内API検索モードで使うなら Ollama/索引は不要（起動後に ⚙ で社内API設定）。
5. **PAフロー作成**: `setup/README-PA-flow.md`（作成トリガー → `Status=Detected` / `DetectedAt=utcNow()`）。
6. **起動**: `start.bat`。**初回起動でリスト・列・chat-ui.js を自動生成**し、サインイン後にチャットが立ち上がる。

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

## ナレッジ（RAG：マニュアルに基づく回答）

`knowledge/manual.md`（架空の問い合わせ管理システムのマニュアル）を知識ソースとして、
**質問に関連する箇所だけを検索して回答**します。

- **事前処理**: `build_index.py` が manual.md を `## ` セクション単位でチャンク化し、
  **Ollama の埋め込みモデル `bge-m3`（多言語・日本語に強い）** でベクトル化 → `knowledge/index.json` に保存。
- **回答時**: broker が質問を埋め込み → cos 類似で上位 `top_k`(既定4) チャンクを取得 →
  **回答モデル `qwen2.5:7b`** に「資料をよく読んで答える／無ければ『資料に記載がありません』／出典見出しを示す」指示付きで渡す。
- **効果（実測）**: 「再オープンは何日以内？→クローズ後7日以内（章10）」等、**根拠つきで正答**。
  マニュアルに無い質問（例: 経費精算）は **「資料に記載がありません」** と正しく拒否。

**マニュアルを差し替える／増やすとき**: `knowledge/manual.md` を編集 → `python build_index.py` で索引を作り直す → broker 再起動。
埋め込みモデル/回答モデルは `config.json` の `embed_model` / `ollama_model` で変更可（モデルを変えたら索引の再構築が必要）。

> 補足: pptx 等の別形式を知識にしたい場合も、抽出（例: `python-pptx`）でテキスト化し
> 同じ `build_index.py` の流れ（チャンク→埋め込み→index.json）に載せれば同様に使えます。
> 画像内の文字は OCR しない限り取り込めない点に注意。

## 社内API検索モード（Tadori セグメント / Azure OpenAI 互換）

ローカル Ollama RAG の代わりに、**社内API（Azure OpenAI互換）で検索・回答**し、
**Tadori が事前ベクトル化して SPO に置いた文書（セグメント）**を知識源にできます。

- **設定画面**（チャットパネル右上の ⚙）で以下を指定 → localStorage に保存：
  - **SPO セグメントURL**（ベクトル化済み文書の場所）／社内API ベースURL（ゲートウェイ or リレー loopback）／
    埋め込みデプロイ名／dimensions／api-version／回答デプロイ名／api-key
- **broker** はこの設定を **CDP 経由で読み**、設定が揃っていれば **社内API検索モード**に切り替わる（未設定ならローカル Ollama にフォールバック）：
  1. SPO セグメントをブラウザセッション（CDP）で読み込み、`embedding`（base64-float16）をデコード
  2. 質問を **社内API `…/openai/deployments/<embed>/embeddings`** で埋め込み
  3. L2 正規化 cosine で Top-K
  4. **社内API `…/openai/deployments/<chat>/chat/completions`** で回答生成
- **経路**：質問者は直接 APIを叩かず、**API実行権限を持つ運用者が動かす broker が社内API（リレー経由可）を呼ぶ**。
  SPO 認証は既存の bat/CDP で統一。

> ⚠ **未接続検証**：社内API・api-key・実 Tadori セグメントは開発環境から到達できないため、実接続の E2E はここでは未検証。
> 実装は Tadori の契約（`src/embeddings/client.ts` 等）に厳密準拠し、**リクエスト形式・float16デコード・cosine・設定読込はモックで確認済み**。
> セグメントのファイル構成（manifest + seg ファイル）は Tadori の想定形式を仮定しているので、実出力が異なる場合は `corp.load_segments()` を調整する。

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
