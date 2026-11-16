# Koe Mac：右シフトで話して、文字にする

右シフトを押して話すと、Macの中だけで文字にする道具です。声を外へ送りません。
文字にしたものは、既定ではクリップボードに入ります。設定で、好きなコマンドへ渡すこともできます。

## 使い方

- 右シフトを**長押し**している間だけ録ります。離すと文字にします。
- 右シフトを**短く1回**押すと「話し続けモード」になります。
  - 話して黙ると（既定1.0秒）、そこまでを1件にして文字にし、すぐ次を待ちます。
  - もう1回押すとやめます。スリープや画面ロックでも止まります。
- 画面の右側に黒いピルが出て、いまの状態を点の色で示します。
  - 青の点がゆっくり明滅：聞いています
  - 赤の点：話しています
  - 青のくるくる：文字にしています
  - 緑の点：届けました
  - グレーの点：届けなかった（短すぎる・声がない など）
- 話し続けモードで言葉を届けると、ピルが広がって、届けた言葉の一覧のカードになります。
  - ドラッグで動かせます。場所は覚えます。ダブルクリックで右の既定に戻ります。
  - 入りきらないときは、カードの上で2本指スクロールできます。
  - 画面共有中は広げません（ピルだけ）。

## 入っているもの

| ファイル | 役目 |
|---|---|
| `koe.lua` | Hammerspoon の本体。キーの合図・録音・届け方 |
| `pill.lua` | 画面の右側のピル（ばねの動き） |
| `card.lua` | ピルが広がってできる、届けた言葉の一覧 |
| `listen.mjs` | 話し続けモードの耳。録り続けて、黙ったところで区切る |
| `transcribe.mjs` | 声を文字にする（transcribe-cpp と SenseVoiceSmall） |
| `config.example.lua` | 設定の見本 |
| `karabiner/right-shift-koe.json` | 右シフトを合図のキー（F17・F18・F19）に変える Karabiner の決まり |
| `examples/` | 送り先のコマンドの見本 |

## 入れ方

### 1. 道具をそろえる

```sh
brew install --cask hammerspoon karabiner-elements
brew install node sox
```

- Hammerspoon：キーの合図を受けて、録音と画面のピルを動かします。
- Karabiner-Elements：右シフトを合図のキーに変えます。
- Node.js（18 以上）：文字にする処理を動かします。
- SoX（`rec` コマンド）：マイクから録ります。

### 2. このフォルダを置いて、部品を入れる

```sh
git clone https://github.com/soichiro-nitta/gentle-ui-and-koe.git
cd gentle-ui-and-koe/koe-mac
npm install
```

`npm install` で transcribe-cpp（[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) の Node 版）が入ります。

### 3. モデルを置く

このリポジトリにはモデルを入れていません。次の2つを用意して、`~/.local/share/koe-mac/models/` に置きます。

- `SenseVoiceSmall-Q8_0.gguf`：文字にするモデル（SenseVoiceSmall を transcribe.cpp 用の GGUF にしたもの）
- `silero-vad-v6.2-F32.gguf`：声の区間を見つけるモデル（Silero VAD）

入手先と変換の方法は [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) の案内を見てください。
別のファイル名・場所にしたときは、設定の `asrModel`・`vadModel` を直します。

### 4. Karabiner の決まりを入れる

```sh
mkdir -p ~/.config/karabiner/assets/complex_modifications
cp karabiner/right-shift-koe.json ~/.config/karabiner/assets/complex_modifications/
```

Karabiner-Elements の「Complex Modifications」→「Add predefined rule」で「Koe Mac（右シフトで話す）」を有効にします。

- 単独で短く押して離す → F17（話し続けモードの切り替え）
- 単独で 0.3 秒押し続ける → F18（録音の開始）、離す → F19（終わり）
- ほかのキーと一緒に押したときは、ふつうの右シフトのまま

右シフトをほかの用途に置きかえている場合は、`from` のキーを合わせて直してください。

### 5. Hammerspoon で読み込む

`~/.hammerspoon/init.lua` に1行足して、Hammerspoon の設定を読み直します。

```lua
koe = dofile(os.getenv("HOME") .. "/path/to/gentle-ui-and-koe/koe-mac/koe.lua")
```

Hammerspoon には、マイク（録音）とアクセシビリティ（キーの合図を受ける・貼り付ける）の許可が要ります。初めて使うときに許可を求められます。

### 6. 設定する（任意）

```sh
mkdir -p ~/.config/koe-mac
cp config.example.lua ~/.config/koe-mac/config.lua
```

主な項目です。書かなかったものは既定のままです。

| 項目 | 既定 | 意味 |
|---|---|---|
| `clipboard` | `true` | 文字にしたものをクリップボードに入れる |
| `paste` | `false` | 前面のアプリへそのまま貼り付ける |
| `send` | なし | 送り先のコマンド。文字を標準入力で渡す |
| `pauseFile` | なし | このファイルが新しく現れたら話し続けモードを止める |
| `icon` | なし | カードの一覧に出す小さな丸いアイコン |
| `silence` | `1.0` | 何秒黙ったら区切るか |
| `idle` | `0` | 黙ってこの秒数たったらモードを止める（0 は止めない） |
| `minRatio` | 0.15〜0.18 | 離れた声（隣の人の声など）を捨てる割合 |
| `asrModel`・`vadModel` | 上の置き場所 | モデルの場所 |

## 送り先を差し替える

`send` にコマンドを書くと、文字にしたものを**標準入力**で渡して呼びます。終了コードが 0 なら「送りました」と出ます。

```lua
send = { os.getenv("HOME") .. "/path/to/koe-mac/examples/append-to-file.sh" },
```

- `examples/append-to-file.sh`：時刻つきでメモのファイルに足す見本
- `examples/print.sh`：そのまま標準出力へ出す見本

チャットへ送る、タスク管理に足す、エージェントへ指示として渡す、などは、このコマンドを差し替えて作ります。
文をコマンドの引数にせず標準入力で渡すのは、日本語の濁点が分かれた形（NFD）に変わるのを避けるためです。

## マイクを使わずに試す

- 文字にするところだけ：16kHz・モノラル・float32 の raw ファイルを用意して `node transcribe.mjs <ファイル>`。
  終了コードは 0（文字にできた）・3（1秒未満）・4（聞き取れない）・5（声がない）です。
- 話し続けモードの耳だけ：16kHz・モノラル・int16 の raw で `node listen.mjs <書き出すフォルダ> --input <ファイル>`。
  1行1つの JSON（`speech-start`・`cut`・`segment`・`discard`）が出ます。
- Hammerspoon の中で：`koe.testInput = "<int16 の raw>"` を入れてから右シフトを短く押すと、マイクの代わりにそのファイルを流します。

## 動かないとき

- ログは `~/Library/Logs/koe-mac.log` です。届けなかったときは `skipped: <理由>` が1行出ます。
  - `too-short`：押した時間が1秒未満
  - `silent`：声が入っていない
  - `unheard`：声はあったが文字にならない
  - `transcribe-failed`：文字にする処理が失敗（モデルや transcribe-cpp の場所を確かめる）
  - `rec-failed`：録音を始められない（SoX の場所とマイクの許可を確かめる）
  - `send-failed`：送り先のコマンドが 0 以外で終わった
- 押しても何も出ない：Karabiner-EventViewer で、右シフトの長押しが f18 になっているかを確かめます。
- 文字にする速さの目安：5秒の声で0.2秒ほど、40秒の声で0.5秒ほど（Apple シリコンの Mac）。
