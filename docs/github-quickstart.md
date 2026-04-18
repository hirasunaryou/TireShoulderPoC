# GitHubアップロード最短手順

## いちばん簡単な流れ

### 1. まずXcodeで動かす
先に GitHub は気にしなくて大丈夫です。  
まずは実機で1回動かしてください。

### 2. GitHubで空リポジトリを作る
ブラウザで GitHub にログインして、

- New repository
- Repository name: `TireShoulderPoC`
- Public or Private を選ぶ
- README は追加しなくてOK

で作成します。

### 3. Xcodeプロジェクトのフォルダを開く
ターミナルでそのフォルダへ移動して、下を順番に実行します。

```bash
git init
git add .
git commit -m "Initial PoC"
git branch -M main
git remote add origin <ここにGitHubのURL>
git push -u origin main
```

---

## URL の例

```bash
git remote add origin https://github.com/<your-name>/TireShoulderPoC.git
```

---

## うまくいかない時

### `Author identity unknown`
最初だけ名前とメールを入れます。

```bash
git config --global user.name "Your Name"
git config --global user.email "your-email@example.com"
```

### `Permission denied`
GitHubログインやトークン設定が未完了のことが多いです。  
この場合はブラウザから ZIP アップロードでも進められます。

---

## ブラウザだけでやる逃げ道

どうしてもGitが難しければ、

1. GitHubで空リポジトリ作成
2. `Upload files`
3. Xcodeプロジェクト一式をドラッグ&ドロップ
4. Commit

でも開始できます。

---

## 最初のコミットに入れるとよいもの

- Swiftソース一式
- README.md
- docs/algorithm-spec.md
- docs/architecture.md
- `.gitignore`

---

## 以後の運用

変更したら毎回これだけです。

```bash
git add .
git commit -m "Describe what changed"
git push
```
