# TireShoulderPoC

iPhoneローカルで **新品 / 走行品のUSDZ** を読み込み、  
**青テープで位置合わせ**、**赤テープ帯だけを断面プロファイル比較** するためのSwiftUI PoCです。

## いま入っているもの

- SwiftUI UI
- Filesアプリから `.usdz` を2本読み込み
- USDZのテクスチャから青 / 赤を自動抽出
- 青点群で PCA 初期合わせ + ICP 微調整
- 赤点群を2Dプロファイル化して比較
- 3D重ね合わせ表示
- CSV 出力
- GitHub向けの仕様メモとアーキテクチャ図

## 想定ユースケース

- 新品タイヤと走行後タイヤのショルダ部を比較したい
- サイド部を基準に位置合わせしたい
- 現場では iPhone だけで確認したい
- まず PoC を回し、成立性を見たい

## Xcodeで最短起動する手順

1. Xcodeで **iOS App** を新規作成
2. Product Name を `TireShoulderPoC` にする
3. Interface は `SwiftUI`
4. Language は `Swift`
5. Deployment Target は **iOS 17.0 以上**
6. このフォルダの `XcodeDropIn/` 配下のファイルを、作成したプロジェクトへ全部ドラッグ&ドロップ
7. 既存の `ContentView.swift` と `TireShoulderPoCApp.swift` は置き換える
8. 実機 iPhone Pro を接続して Run

## 使い方

1. 新品USDZを読み込む
2. 走行品USDZを読み込む
3. 「比較を実行」を押す
4. 3D重ね合わせとプロファイル差分を確認
5. CSVを書き出す

## 最初に見るべき項目

- 青RMS が安定して小さいか
- 同じ新品 vs 同じ新品 で差分が小さいか
- 赤帯の線形が大きく破綻していないか
- CSVの差分が再現しているか

## 重要な前提

- 青テープは **非対称形状** にしてください
- 赤テープは **ショルダ断面を横切る細長い帯** にしてください
- できるだけ **マットで高彩度** のテープを使ってください
- 新品 / 走行品で **内圧・姿勢・照明** をそろえてください

## 既知の制約

- この版は **色抽出ベースのPoC** です
- 3D上の差分ヒートマップは未実装です
- kd-tree ではなく総当たり近傍探索なので、将来高速化余地があります
- SceneKitのマテリアル展開結果によっては、一部USDZで色抽出精度が落ちる可能性があります

## 次にやると強い改善

- 青 / 赤の色しきい値をUIで調整可能にする
- 自動抽出後の手修正モードを入れる
- 赤帯の中心線抽出を geodesic ベースに置き換える
- 3Dヒートマップ表示を追加する
- モデル取得まで `ObjectCaptureSession` と一体化する

## ドキュメント

- `docs/algorithm-spec.md`
- `docs/architecture.md`
- `docs/github-quickstart.md`
- `docs/codex-next-prompt.md`
