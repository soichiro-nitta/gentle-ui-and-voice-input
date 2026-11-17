# やさしいUI と 声入力（Mac）

読みやすく、やさしい見た目の「読み物」の作り方と、右シフトで話して文字にする Mac の道具をまとめたリポジトリです。
ほかのマシンでも同じように使えるように、考え方と材料を置いています。

## 中身

- [`reading/`](reading/)：やさしいUIの読み物の作り方
  - `reading.css`（共通の見た目）、使える部品の一覧（`COMPONENTS.md`）、今日のまとめの手本（`examples/today.html`）、書き方の決まり、見た目をそろえて確かめるスクリプト `reading-style`
- [`design/`](design/)：デザインの考え方
  - やさしい日本語、文字と余白が主役、線を引かない、控えめな色、文字の太さ、短く意味のある動き
- [`voice-input-mac/`](voice-input-mac/)：声入力（Mac）（右シフトで話して、Macの中だけで文字にする道具）
  - Hammerspoon・Karabiner-Elements・Node.js・SoX で動きます。文字にしたものは既定でクリップボードへ。送り先は設定で差し替えられます

## すぐ試す

読み物の手本を開く：

```sh
open reading/examples/today.html    # 今日のまとめ（1日のまとめ）
open reading/examples/sample.html   # ふつうの読み物
```

作り方と、AI に作らせるときの頼み方は [`reading/README.md`](reading/README.md)、使える部品は [`reading/COMPONENTS.md`](reading/COMPONENTS.md) を見てください。

自分の HTML を同じ見た目にそろえて、確かめる：

```sh
reading/reading-style apply my-page.html
reading/reading-style check my-page.html
```

声入力（Mac） の入れ方は [`voice-input-mac/README.md`](voice-input-mac/README.md) を見てください。

## 同梱していないもの

- 文字にするモデル（SenseVoiceSmall、Silero VAD）と、ほかの人のライブラリ（transcribe-cpp など）は入れていません。入手先だけを案内しています。

## ライセンス

[MIT](LICENSE)

## 元との同期

この中身は、作者の個人用の設定から個人の運用の部分を外して、手で写したものです。元を直したときは、同じ部分を手で写して更新します（自動の同期はしていません）。
