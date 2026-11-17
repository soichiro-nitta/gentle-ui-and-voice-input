-- 声入力（Mac） の設定の見本。~/.config/voice-input-mac/config.lua に写して、要るところだけ直す。
-- 書かなかった項目は voice-input.lua の既定のまま。
local HOME = os.getenv("HOME")

return {
  -- node と rec（SoX）の場所。Homebrew の既定の場所なら書かなくてよい。
  -- node = "/opt/homebrew/bin/node",
  -- rec = "/opt/homebrew/bin/rec",

  -- モデルの場所（README の「モデルを置く」を参照）。
  asrModel = HOME .. "/.local/share/voice-input-mac/models/SenseVoiceSmall-Q8_0.gguf",
  vadModel = HOME .. "/.local/share/voice-input-mac/models/silero-vad-v6.2-F32.gguf",
  -- transcribe-cpp を別の場所に入れたときだけ書く（dist/index.js のパス）。
  -- transcribeModule = HOME .. "/somewhere/node_modules/transcribe-cpp/dist/index.js",
  language = "ja",

  -- 届け方。既定はクリップボードに入れるだけ。
  clipboard = true,
  -- 前面のアプリへそのまま貼り付けるなら true。
  paste = false,
  -- 送り先のコマンド。文字にしたものを標準入力で渡す（終了コード 0 で「送りました」）。
  -- 例：examples/append-to-file.sh で、日付つきでメモのファイルに足す。
  -- send = { HOME .. "/path/to/voice-input-mac/examples/append-to-file.sh" },

  -- このファイルが新しく現れたら話し続けモードを止める（会議の録音中の印など。使わなければ書かない）。
  -- pauseFile = HOME .. "/.local/share/my-meeting/in-meeting",

  -- カードの一覧に出す小さな丸いアイコン（使わなければグレーの丸）。
  -- icon = HOME .. "/Pictures/me.jpg",

  -- 区切りと聞き分けの調整。
  silence = 1.0, -- 何秒黙ったら区切るか
  idle = 0, -- 黙ってこの秒数たったらモードを止める（0 は止めない）
  -- onDb = 15, -- 声と見なす線（環境音＋dB）
  -- minRatio = 0.15, -- 離れた声を捨てる割合（上げるほど厳しい）
  -- closeMic = "Wireless Mic|Mic Mini", -- 口元のマイクと見なす入力機器の名前（正規表現）
}
