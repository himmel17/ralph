# Ralph

[English](README.md)

![Ralph](ralph.webp)

Ralph は、AI コーディングツール（[Amp](https://ampcode.com) または [Claude Code](https://docs.anthropic.com/en/docs/claude-code)）を、PRD の全項目が完了するまで繰り返し実行する自律型 AI エージェントループです。各イテレーションは、コンテキストを持たない新しいインスタンスとして起動します。記憶は git の履歴、`progress.txt`、`prd.json` を通じて引き継がれます。

[Geoffrey Huntley の Ralph パターン](https://ghuntley.com/ralph/)に基づいています。

[私が Ralph をどう使っているかの詳しい記事はこちら](https://x.com/ryancarson/status/2008548371712135632)

## 前提条件

- 次のいずれかの AI コーディングツールがインストール済みで、認証も済んでいること
  - [Amp CLI](https://ampcode.com)（既定）
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（`npm install -g @anthropic-ai/claude-code`）
- `jq` がインストールされていること（macOS では `brew install jq`）
- プロジェクトが git リポジトリであること
- 任意: [GitHub Issue ワークフロー](#github-issue-ワークフロー任意)を使う場合は、[GitHub CLI](https://cli.github.com)（`gh`）がインストール済みで、認証も済んでいること

## セットアップ

### Option 1: プロジェクトにコピーする

Ralph のファイルをプロジェクトにコピーします。

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/

# Copy the prompt template for your AI tool of choice:
cp /path/to/ralph/prompt.md scripts/ralph/prompt.md    # For Amp
# OR
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md    # For Claude Code

chmod +x scripts/ralph/ralph.sh

# Optional: GitHub Issue workflow (all three files are needed)
cp /path/to/ralph/ralph-safe.sh /path/to/ralph/ralph-pr.sh /path/to/ralph/ralph-lib.sh scripts/ralph/
chmod +x scripts/ralph/ralph-safe.sh scripts/ralph/ralph-pr.sh
```

### Option 2: skill をグローバルにインストールする (Amp)

skill を Amp または Claude の設定ディレクトリにコピーすると、全てのプロジェクトで使えるようになります。

Amp の場合
```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
cp -r skills/ralph-issue ~/.config/amp/skills/
```

Claude Code の場合（手動）
```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
cp -r skills/ralph-issue ~/.claude/skills/
```

### Option 3: Claude Code Marketplace として使う

Ralph の marketplace を Claude Code に追加します。

```bash
/plugin marketplace add snarktank/ralph
```

続いて skill をインストールします。

```bash
/plugin install ralph-skills@ralph-marketplace
```

インストール後に使える skill は次のとおりです。
- `/prd` - Product Requirements Document（PRD）を生成します
- `/ralph` - PRD を prd.json 形式に変換します
- `/ralph-issue` - GitHub Issue を prd.json 形式に変換します

Claude に次のように頼むと、skill が自動的に呼び出されます。
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"
- "convert issue to prd.json", "run ralph on issue #12"

### Amp の auto-handoff を設定する（推奨）

`~/.config/amp/settings.json` に次を追加します。

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

これにより、コンテキストが埋まったときに自動で引き継ぎが行われ、1 つのコンテキストウィンドウに収まらない大きな story も Ralph が扱えるようになります。

## ワークフロー

### 1. PRD を作成する

PRD skill を使って、詳細な要件定義書を生成します。

```
Load the prd skill and create a PRD for [your feature description]
```

確認の質問に答えてください。skill は出力を `tasks/prd-[feature-name].md` に保存します。

### 2. PRD を Ralph 形式に変換する

Ralph skill を使って、Markdown の PRD を JSON に変換します。

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

これにより、自律実行に向けて構造化された user story を持つ `prd.json` が作られます。

### 3. Ralph を実行する

```bash
# Using Amp (default)
./scripts/ralph/ralph.sh [max_iterations]

# Using Claude Code
./scripts/ralph/ralph.sh --tool claude [max_iterations]
```

既定のイテレーション数は 10 です。AI コーディングツールは `--tool amp` または `--tool claude` で選びます。

Ralph は次のことを行います。
1. feature branch を作成します（PRD の `branchName` から）
2. `passes: false` の story のうち、優先度が最も高いものを選びます
3. その story を 1 つだけ実装します
4. 品質チェック（typecheck、テスト）を実行します
5. チェックが通れば commit します
6. `prd.json` を更新し、その story を `passes: true` にします
7. 学んだことを `progress.txt` に追記します
8. 全ての story が pass するか、最大イテレーション数に達するまで繰り返します

## GitHub Issue ワークフロー（任意）

要件を GitHub Issue で管理している場合に使います。ループ自体は GitHub と一切通信しません。Issue の読み取りはループの前に、pull request の作成はループの後に、あなた自身が行います。

**1 Issue = 1 `prd.json` = 1 branch = 1 PR です。** Issue は 1 つの機能を記述します。そこから分割された user story は `prd.json` の中にだけ存在します。story ごとに Issue を作らないでください。

### 1. Issue を書く

Issue の本文が要件定義書になります。PRD skill で書いたものを、そのまま投稿できます。

```bash
gh issue create --title "Task Priority System" --body-file tasks/prd-task-priority.md
```

### 2. Issue を prd.json に変換する

```
Load the ralph-issue skill and convert issue #12 to prd.json
```

この skill は Issue を読み、`ralph` skill と同じ規則を適用し、story の分割結果をあなたに見せて承認を求めたうえで、`prd.json` に出どころを記録します。

```json
"source": {
  "type": "github-issue",
  "issue": 12,
  "url": "https://github.com/OWNER/REPO/issues/12",
  "issueUpdatedAt": "2026-09-01T12:34:56Z"
}
```

`prd.json` はスナップショットです。Issue の要件が変わった場合は、`prd.json` を手で直さずに、変換をやり直してください。`ralph-safe.sh` と `ralph-pr.sh` は、変換後に Issue が変更されていると警告を出します（コメントの追加やラベルの変更でも警告が出ます）。

### 3. GitHub へのアクセスを無効にしてループを実行する

```bash
./scripts/ralph/ralph-safe.sh --tool claude [max_iterations]
```

`ralph-safe.sh` は引数をそのまま `ralph.sh` に渡します。ループの実行中は、`gh` がログアウト状態になり（空の `GH_CONFIG_DIR` を使います）、`origin` の push URL が `DISABLED` に設定されます。どちらもループの終了時に元に戻ります。スクリプトが強制終了された場合は、次回の実行時に最初に push URL を復元します。`origin` 以外の remote を保護するには、`RALPH_REMOTE` を設定してください。

これは事故を防ぐためのものであり、サンドボックスではありません。権限チェックなしで動くエージェントは、この設定を元に戻すことができます。

### 4. ローカルで確認してから PR を作成する

push するまでは、失敗した実行に代償はありません。branch を reset して、やり直せます。結果に問題がなければ、次を実行します。

```bash
./scripts/ralph/ralph-pr.sh --dry-run   # Print the PR body and the commands, change nothing
./scripts/ralph/ralph-pr.sh             # Commit leftover Ralph state, push, open the PR
```

- 全ての story が pass している場合: `Closes #12` を付けた通常の PR を作成します。
- 未完了の story が残っている場合: `Refs #12` を付けた **draft** PR を作成します。そのため、merge しても Issue は閉じません。
- その branch の PR が既に開いている場合: 本文だけを更新します。
- `prd.json` に `source` が無い場合: `--issue 12` を渡してください。省略すると、どの Issue も参照しない PR を作成します。

PR の本文には、全ての story とその状態、notes が並びます。`ralph-pr.sh` は、branch が違う場合と、`prd.json` と `progress.txt` 以外に未コミットの変更がある場合には、実行を拒否します。

### 5. merge は自分で行う

Ralph には merge を行う仕組みがありません。story の状態はエージェント自身の申告なので、他の PR と同じようにレビューしてください。GitHub が Issue を閉じるのは、`Closes #12` を含む PR が **default branch** に merge された時です。PR を開いただけの時や、別の branch に merge した時には閉じません。

Issue は小さく保ってください。全ての story が 1 つの PR に入りますし、ループは実行中に default branch に入った変更を取り込みません。

### Windows

スクリプトは Git Bash 経由で実行します: `bash scripts/ralph/ralph-safe.sh --tool claude 10`。Windows ネイティブ版の `jq` は改行を CRLF で出力しますが、スクリプト側で取り除いています。

### テスト

```bash
bash tests/test-ralph-pr.sh
```

このテストは、一時的なリポジトリで `ralph-pr.sh --dry-run` を実行し、`gh` をスタブに差し替えるので、ネットワーク接続を必要としません。

## 主なファイル

| ファイル | 用途 |
|------|---------|
| `ralph.sh` | 新しい AI インスタンスを起動する bash のループ（`--tool amp` と `--tool claude` に対応） |
| `prompt.md` | Amp 用のプロンプトテンプレート |
| `CLAUDE.md` | Claude Code 用のプロンプトテンプレート |
| `prd.json` | `passes` の状態を持つ user story（タスクリスト） |
| `prd.json.example` | 参考用の PRD 形式の例 |
| `progress.txt` | 以降のイテレーションに向けた、追記専用の学習記録 |
| `skills/prd/` | PRD を生成する skill（Amp と Claude Code の両方で動作） |
| `skills/ralph/` | PRD を JSON に変換する skill（Amp と Claude Code の両方で動作） |
| `skills/ralph-issue/` | GitHub Issue を JSON に変換する skill |
| `ralph-safe.sh` | `gh` をログアウト状態にし、push を無効にして `ralph.sh` を実行する |
| `ralph-pr.sh` | ループの後に branch を push し、`prd.json` から PR を作成する |
| `ralph-lib.sh` | `ralph-safe.sh` と `ralph-pr.sh` が共有するヘルパー |
| `tests/` | `ralph-pr.sh` のオフラインテスト |
| `.claude-plugin/` | Claude Code marketplace から発見されるための plugin マニフェスト |
| `flowchart/` | Ralph の仕組みを示すインタラクティブな可視化 |

## フローチャート

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[インタラクティブなフローチャートを見る](https://snarktank.github.io/ralph/)** - クリックして進めると、各ステップがアニメーション付きで表示されます。

`flowchart/` ディレクトリにソースコードがあります。ローカルで動かすには次を実行します。

```bash
cd flowchart
npm install
npm run dev
```

## 重要な考え方

### 各イテレーション = 新しいコンテキスト

各イテレーションは、コンテキストを持たない**新しい AI インスタンス**（Amp または Claude Code）を起動します。イテレーション間で引き継がれる記憶は、次のものだけです。
- git の履歴（以前のイテレーションの commit）
- `progress.txt`（学んだことと文脈）
- `prd.json`（どの story が完了したか）

### 小さなタスク

PRD の各項目は、1 つのコンテキストウィンドウで完了できる大きさにしてください。タスクが大きすぎると、LLM は完了する前にコンテキストを使い切り、質の低いコードを生成します。

適切な大きさの story の例:
- データベースのカラムと migration を追加する
- 既存のページに UI コンポーネントを追加する
- server action に新しいロジックを加える
- 一覧にフィルタのドロップダウンを追加する

大きすぎる例（分割してください）:
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md の更新が重要

各イテレーションの後、Ralph は関連する `AGENTS.md` に学んだことを書き込みます。AI コーディングツールはこのファイルを自動的に読むので、発見されたパターン、落とし穴、規約が、以降のイテレーション（と将来の人間の開発者）に活かされます。これが重要な理由です。

AGENTS.md に書く内容の例:
- 発見したパターン（「このコードベースでは Y に X を使う」）
- 落とし穴（「W を変更するときは Z の更新を忘れないこと」）
- 役に立つ文脈（「設定パネルはコンポーネント X にある」）

### フィードバックループ

Ralph は、フィードバックループがある場合にだけ機能します。
- typecheck が型エラーを検出する
- テストが振る舞いを検証する
- CI は常に green に保つ（壊れたコードはイテレーションを重ねるごとに悪化します）

### UI の story はブラウザで検証する

フロントエンドの story では、受け入れ基準に "Verify in browser using dev-browser skill" を含める必要があります。Ralph は dev-browser skill を使ってページに移動し、UI を操作して、変更が動作することを確認します。

### 終了条件

全ての story が `passes: true` になると、Ralph は `<promise>COMPLETE</promise>` を出力し、ループが終了します。

## デバッグ

現在の状態を確認します。

```bash
# See which stories are done
cat prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10
```

## プロンプトのカスタマイズ

`prompt.md`（Amp 用）または `CLAUDE.md`（Claude Code 用）をプロジェクトにコピーしたら、プロジェクトに合わせて調整してください。
- プロジェクト固有の品質チェックコマンドを追加する
- コードベースの規約を書き加える
- 使っている技術スタックでよくある落とし穴を追加する

## アーカイブ

新しい機能（異なる `branchName`）を始めると、Ralph は以前の実行を自動的にアーカイブします。アーカイブは `archive/YYYY-MM-DD-feature-name/` に保存されます。

## 参考資料

- [Geoffrey Huntley の Ralph の記事](https://ghuntley.com/ralph/)
- [Amp のドキュメント](https://ampcode.com/manual)
- [Claude Code のドキュメント](https://docs.anthropic.com/en/docs/claude-code)
