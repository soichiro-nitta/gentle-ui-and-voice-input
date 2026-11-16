-- Koe Mac：右シフトで話して、文字にする道具（Hammerspoon の本体）。
--
-- ・右シフトを長押ししている間だけ録り、離したら文字にする。
-- ・右シフトを短く1回押すと「話し続けモード」。黙ったら（既定1.0秒）そこまでを1件にして文字にし、すぐ次を待つ。もう1回押すとやめる。
-- ・文字にしたものは、既定ではクリップボードに入れる（Hammerspoon のコンソールにも出す）。
--   設定の send に送り先のコマンドを書くと、文字を標準入力で渡して呼ぶ（チャットへ送る・ファイルに足す など、自由に差し替えられる）。
-- ・文字にするのは transcribe-cpp と SenseVoiceSmall（transcribe.mjs）。Macの中だけで動き、声を外へ送らない。
--
-- 右シフトは Karabiner-Elements で合図のキーに置きかえる（karabiner/right-shift-koe.json）：
--   単独で短く押して離す → F17（話し続けモードの切り替え）
--   単独で 0.3 秒押し続ける → F18（長押しの録音を始める）、離す → F19（止める）
--   ほかのキーと一緒に押したら、もとのキーのまま
--
-- 読み込み方（~/.hammerspoon/init.lua）：
--   koe = dofile(os.getenv("HOME") .. "/path/to/koe-mac/koe.lua")
-- 設定は ~/.config/koe-mac/config.lua（config.example.lua を写して直す）。環境変数 KOE_CONFIG で場所を変えられる。
local M = {}

-- 使う拡張は読み込みのときに先に読んでおく（初めて使う瞬間に読み込むと、まれに失敗するため）。
for _, name in ipairs({ "hash", "host", "json", "task", "fs", "timer", "settings", "styledtext", "canvas", "drawing", "image", "screen", "eventtap", "caffeinate", "application", "pasteboard", "keycodes", "window", "mouse", "audiodevice" }) do
  local _ = hs[name]
end

local HOME = os.getenv("HOME")
local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or (HOME .. "/koe-mac")

local function firstExisting(list)
  for _, path in ipairs(list) do
    if path and hs.fs.attributes(path) then
      return path
    end
  end
  return list[1]
end

-- 設定の既定。~/.config/koe-mac/config.lua が返す表で上書きする。
local cfg = {
  node = firstExisting({ "/opt/homebrew/bin/node", "/usr/local/bin/node" }),
  rec = firstExisting({ "/opt/homebrew/bin/rec", "/usr/local/bin/rec" }),
  asrModel = HOME .. "/.local/share/koe-mac/models/SenseVoiceSmall-Q8_0.gguf",
  vadModel = HOME .. "/.local/share/koe-mac/models/silero-vad-v6.2-F32.gguf",
  transcribeModule = nil, -- transcribe-cpp の dist/index.js の場所。nil ならこのフォルダの node_modules
  language = "ja",
  clipboard = true, -- 文字にしたものをクリップボードに入れる
  paste = false, -- true にすると、前面のアプリへ貼り付ける（⌘V）
  send = nil, -- 送り先のコマンド。例 { HOME .. "/bin/my-send" }。文字を標準入力で渡す
  pauseFile = nil, -- このファイルが新しく現れたら話し続けモードを止め、カードも広げない（会議中の印など）
  icon = nil, -- カードの一覧に出す小さな丸いアイコンの画像（省略するとグレーの丸）
  silence = 1.0, -- 何秒黙ったら区切るか
  idle = 0, -- 黙ってこの秒数たったらモードを止める（0 は止めない）
  onDb = nil, -- 声と見なす線（環境音＋dB）
  minRatio = nil, -- 離れた声を捨てる割合
  closeMic = nil, -- 口元のマイクと見なす入力機器の名前（正規表現）
  cardLinger = 1, -- モードを止めてからカードを出しておく秒
  log = HOME .. "/Library/Logs/koe-mac.log",
}
local CONFIG_PATH = os.getenv("KOE_CONFIG") or (HOME .. "/.config/koe-mac/config.lua")
if hs.fs.attributes(CONFIG_PATH) then
  local ok, user = pcall(dofile, CONFIG_PATH)
  if ok and type(user) == "table" then
    for key, value in pairs(user) do
      cfg[key] = value
    end
  else
    print("koe: config error " .. tostring(user))
  end
end
M.config = cfg

local CACHE = HOME .. "/.cache/koe-mac"
local TRANSCRIBE = DIR .. "/transcribe.mjs"
local LISTEN = DIR .. "/listen.mjs"
local SEGMENT_DIR = CACHE .. "/segments"
local AUDIO_PATH = CACHE .. "/last.f32"
local START_KEY = hs.keycodes.map.f18
local STOP_KEY = hs.keycodes.map.f19
local TOGGLE_KEY = hs.keycodes.map.f17
-- これより短い長押しは送らない。
local MIN_RECORD_SECONDS = 1
-- 押しっぱなしの止め忘れ。これを過ぎたら録るのをやめて文字にする。
local MAX_RECORD_SECONDS = 180
local PASTE_DELAY = 0.15
local RESTORE_DELAY = 0.6

local pill = dofile(DIR .. "/pill.lua")
local card = dofile(DIR .. "/card.lua")
card.pauseFile = cfg.pauseFile
card.iconPath = cfg.icon
card.attach(pill)
M.card = card
card.lingerDefault = cfg.cardLinger

local function log(message)
  local file = io.open(cfg.log, "a")
  if file then
    file:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
    file:close()
  end
end
card.log = log
pill.log = log

-- node に渡す環境変数（モデルの場所など）。
local function nodeEnv(extra)
  local env = {
    HOME = HOME,
    PATH = (cfg.node and cfg.node:match("^(.*)/[^/]*$") or "/usr/local/bin") .. ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    KOE_ASR_MODEL = cfg.asrModel,
    KOE_VAD_MODEL = cfg.vadModel,
    KOE_TRANSCRIBE_MODULE = cfg.transcribeModule,
    KOE_LANGUAGE = cfg.language,
    KOE_REC = cfg.rec,
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return env
end

local function hide()
  pill.hide()
end

-- 話し続けモードの状態。task: 耳（listen.mjs）。speaking: 話している最中。queue: 文字にするのを待つかたまり。
-- busy: 文字にしている最中。flashTimer: 「送りました」などを少しだけ見せている間。
local cont = { active = false, stopping = false, task = nil, buffer = "", speaking = false, queue = {}, busy = false, flashTimer = nil, pending = {} }
M.cont = cont

local function pendingCount()
  local n = 0
  for _ in pairs(cont.pending) do
    n = n + 1
  end
  return n
end

local function inContinuous()
  return cont.task ~= nil or cont.busy or #cont.queue > 0 or pendingCount() > 0
end

-- ピルを今の状態に合わせる（話している＞文字にしている＞待っている）。モードを抜けて仕事もなければ消す。
local function refresh()
  if cont.flashTimer then
    return
  end
  if cont.speaking then
    pill.show("recording", "話しています")
  elseif cont.busy or pendingCount() > 0 then
    pill.show("transcribing", "文字にしています")
  elseif cont.stopping then
    pill.show("transcribing", "やめています")
  elseif cont.active then
    pill.show("listening", "聞いています　右シフトでやめる")
  elseif pill.isExpanded() then
    pill.hideAfter(card.linger())
  else
    hide()
  end
end

-- 「送りました」「送らなかった」を見せる。話し続けモードでは消さずに、少ししたら待っている姿へ戻す。
local function flash(state, text, seconds)
  if not inContinuous() then
    pill.show(state, text, seconds)
    return
  end
  if cont.flashTimer then
    cont.flashTimer:stop()
  end
  pill.show(state, text)
  cont.flashTimer = hs.timer.doAfter(math.min(seconds, 1.2), function()
    cont.flashTimer = nil
    refresh()
  end)
end

local function paused()
  return cfg.pauseFile ~= nil and hs.fs.attributes(cfg.pauseFile) ~= nil
end

-- 長押しの状態。pressedAt: F18 が押された時刻。spoiled: 押している間にほかのキーを押した。
local state = { pressedAt = nil, spoiled = false, recorder = nil, recordStartedAt = nil, maxTimer = nil }
M.state = state

-- 送らなかったときは、理由をログへ1行残し、ピルにもグレーで短く出す。
local function skip(reason, message, detail, seconds)
  log("skipped: " .. reason .. (detail and detail ~= "" and (" " .. detail) or ""))
  flash("skipped", message, seconds or 1.5)
end

-- 試すときは true にすると、録音・文字起こし・送信をせず、判断だけをログと M.events へ残す。
M.dryRun = false
M.events = {}

local function event(name)
  table.insert(M.events, name)
  log(name)
end

local function stopTimers()
  if state.maxTimer then
    state.maxTimer:stop()
    state.maxTimer = nil
  end
end

local function cancelRecording()
  stopTimers()
  if state.recorder then
    local recorder = state.recorder
    state.recorder = nil
    recorder:setCallback(nil)
    recorder:terminate()
    hide()
    event("canceled")
  end
  state.recordStartedAt = nil
end

-- 前面のアプリへ貼り付ける。クリップボードに残さない設定なら、少ししてから元に戻す。
local function pasteText(text)
  local saved = (not cfg.clipboard) and hs.pasteboard.readAllData() or nil
  hs.pasteboard.setContents(text)
  hs.timer.doAfter(PASTE_DELAY, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    if saved then
      hs.timer.doAfter(RESTORE_DELAY, function()
        hs.pasteboard.writeAllData(saved)
      end)
    end
  end)
end

-- 文字にしたものを届ける。既定はクリップボード。send があれば、そのコマンドへ標準入力で渡す。
-- 文はコマンドの引数にしない（hs.task は引数の日本語を濁点の分かれた形〔NFD〕に変えることがあるため）。
function M.deliver(text)
  print("koe: " .. text)
  if cfg.paste then
    pasteText(text)
  elseif cfg.clipboard then
    hs.pasteboard.setContents(text)
  end
  if type(cfg.send) == "table" and cfg.send[1] then
    local command = cfg.send[1]
    local args = {}
    for i = 2, #cfg.send do
      args[#args + 1] = cfg.send[i]
    end
    local task = hs.task.new(command, function(code, _, stderr)
      if code == 0 then
        flash("sent", "送りました", 0.8)
        card.addOwn(text)
        log("sent: chars=" .. utf8.len(text))
      else
        skip("send-failed", "送れませんでした", "code=" .. tostring(code) .. " " .. (stderr or ""), 2.5)
      end
    end, args)
    task:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", LANG = "ja_JP.UTF-8" })
    task:setInput(text)
    if not task:start() then
      skip("send-failed", "送れませんでした", "could not start " .. command, 2.5)
    end
    M.sendTask = task
  else
    flash("sent", cfg.paste and "貼り付けました" or "コピーしました", 0.8)
    card.addOwn(text)
    log("copied: chars=" .. utf8.len(text))
  end
end

-- 文字にした結果で、送るか送らないかを決める。code は transcribe.mjs の終了コードと同じ。
local function handleTranscript(code, text, detail)
  if code == 0 and text and text ~= "" then
    M.deliver(text)
  elseif code == 3 then
    skip("too-short-audio", "短すぎたので送らなかった")
  elseif code == 5 then
    skip("silent", "声が入っていなかった")
  elseif code == 4 then
    skip("unheard", "聞き取れなかった", detail)
  else
    skip("transcribe-failed", "文字にできなかった", "code=" .. tostring(code) .. " " .. (detail or ""))
  end
end

-- 録った音声ファイルを文字にして届ける（長押しと、耳がモデルを読み込めなかったときの話し続けモード）。
function M.transcribeAndSend(path, done)
  if inContinuous() then
    refresh()
  else
    pill.show("transcribing", "文字にしています", 30)
  end
  local task = hs.task.new(cfg.node, function(code, stdout, stderr)
    os.remove(path) -- 声は残さない
    handleTranscript(code, stdout, stderr)
    if done then
      done()
    end
  end, { TRANSCRIBE, path })
  task:setEnvironment(nodeEnv())
  task:start()
  M.transcribeTask = task
end

local function startRecording()
  event("recording")
  if M.dryRun then
    state.recordStartedAt = hs.timer.secondsSinceEpoch()
    return
  end
  hs.fs.mkdir(CACHE)
  os.remove(AUDIO_PATH)
  -- 16kHz・モノラル・float32 の raw で録る。止めるときは SIGINT（rec はそこまでを書いて終わる）。
  local recorder = hs.task.new(cfg.rec, function(code, _, stderr)
    log("rec ended code=" .. tostring(code) .. " " .. (stderr or ""))
  end, { "-q", "-c", "1", "-r", "16000", "-e", "floating-point", "-b", "32", "-t", "raw", AUDIO_PATH })
  if not recorder:start() then
    skip("rec-failed", "録音を始められませんでした")
    return
  end
  state.recorder = recorder
  state.recordStartedAt = hs.timer.secondsSinceEpoch()
  pill.show("recording", "聞いています　離すと送ります")
  state.maxTimer = hs.timer.doAfter(MAX_RECORD_SECONDS, function()
    state.maxTimer = nil
    M.finishRecording()
  end)
end

function M.finishRecording()
  stopTimers()
  local startedAt = state.recordStartedAt
  state.recordStartedAt = nil
  if not startedAt then
    return
  end
  local seconds = hs.timer.secondsSinceEpoch() - startedAt
  log(string.format("stop: recorded %.2fs", seconds))
  if seconds < MIN_RECORD_SECONDS then
    state.recordStartedAt = startedAt
    cancelRecording()
    table.insert(M.events, "too-short")
    skip("too-short", "短すぎたので送らなかった")
    return
  end
  event("finish")
  if M.dryRun then
    return
  end
  local recorder = state.recorder
  state.recorder = nil
  if not recorder then
    return
  end
  recorder:setCallback(function()
    M.transcribeAndSend(AUDIO_PATH)
  end)
  recorder:interrupt()
end

-- 右シフトの単独の長押しになった（down=true、F18）・離した（down=false、F19）。
function M.onTrigger(down)
  if cont.task then
    if down then
      event("ignored-continuous")
    end
    return
  end
  if down then
    if state.pressedAt then
      return
    end
    state.pressedAt = hs.timer.secondsSinceEpoch()
    state.spoiled = false
    stopTimers()
    startRecording()
  else
    if not state.pressedAt then
      return
    end
    state.pressedAt = nil
    if not state.spoiled then
      M.finishRecording()
    end
  end
end

-- 長押しの途中でほかのキーを押した（修飾キーとして使った）。録りかけは捨てる。
function M.onOtherKey()
  if not state.pressedAt or state.spoiled then
    return
  end
  state.spoiled = true
  event("spoiled")
  cancelRecording()
end

-- ここから話し続けモード。

-- 待っているかたまりを、1つずつ順に文字にする（順番を守る）。
local function pump()
  if cont.busy or #cont.queue == 0 then
    refresh()
    return
  end
  cont.busy = true
  local item = table.remove(cont.queue, 1)
  local path = item.path
  refresh()
  local finished = false
  local guard
  local function done()
    if finished then
      return
    end
    finished = true
    if guard then
      guard:stop()
    end
    cont.busy = false
    pump()
  end
  -- 文字にする処理の知らせが落ちても列が止まらないよう、60秒で次へ進む。
  guard = hs.timer.doAfter(60, function()
    if not finished then
      log("continuous: transcribe timed out " .. path)
      os.remove(path)
      done()
    end
  end)
  cont.guard = guard
  M.transcribeAndSend(path, done)
end

local function onListenEvent(message)
  local name = message.event
  if name == "speech-start" then
    if cont.flashTimer then
      cont.flashTimer:stop()
      cont.flashTimer = nil
    end
    cont.speaking = true
    refresh()
  elseif name == "cut" then
    cont.speaking = false
    cont.pending[message.path] = hs.timer.secondsSinceEpoch()
    refresh()
  elseif name == "segment" and cont.discard then
    -- 止める印で止めたときの途中の声は、送らずに捨てる。
    cont.pending[message.path] = nil
    os.remove(message.path)
    log("continuous: segment discarded (paused)")
  elseif name == "segment" then
    cont.speaking = false
    cont.pending[message.path] = nil
    log(string.format("continuous: segment %.2fs voiced=%.2fs cut=%s pauses=%s ms=%s ratio=%s level=%s noise=%s", message.seconds or 0, message.voiced or 0,
      tostring(message.cut), hs.json.encode(message.pauses or {}), tostring(message.ms), tostring(message.ratio), tostring(message.level), tostring(message.noise)))
    if message.code ~= nil then
      local ok, err = pcall(function()
        handleTranscript(message.code, message.text, message.detail)
        os.remove(message.path)
      end)
      if not ok then
        skip("segment-failed", "送れませんでした", tostring(err) .. " kept=" .. tostring(message.path), 2.5)
      end
      refresh()
    else
      -- 耳がモデルを読み込めなかった。transcribe.mjs で順に文字にする。
      table.insert(cont.queue, { path = message.path })
      pump()
    end
  elseif name == "discard" then
    cont.speaking = false
    log("continuous: discard " .. tostring(message.reason) .. " voiced=" .. tostring(message.voiced) .. " ratio=" .. tostring(message.ratio))
    refresh()
  elseif name == "idle" then
    log("continuous: idle")
    M.stopContinuous("idle")
  elseif name == "ready" then
    log("continuous: ready")
  else
    log("continuous: " .. hs.json.encode(message))
  end
end

-- 試し用。耳の知らせを、耳を動かさずに渡せる（マイクを使わずに受け取り側を確かめる）。
M.onListenEvent = onListenEvent

local function readLines(text)
  cont.buffer = cont.buffer .. (text or "")
  while true do
    local line, rest = cont.buffer:match("^(.-)\n(.*)$")
    if not line then
      break
    end
    cont.buffer = rest
    local ok, message = pcall(hs.json.decode, line)
    if ok and type(message) == "table" then
      onListenEvent(message)
    elseif line ~= "" then
      log("continuous: bad line " .. line)
    end
  end
end

function M.startContinuous()
  if cont.task or state.recorder then
    return
  end
  cont.discard = false
  -- 印がある間に自分で始めたときは止めない。印が新しく現れたときだけ止める。
  cont.wasPaused = paused()
  hs.fs.mkdir(CACHE)
  cont.buffer = ""
  cont.speaking = false
  cont.pending = {}
  -- 試すとき（M.testInput に 16kHz・モノラル・int16 の raw のパス）は、マイクの代わりにそのファイルを流す。
  local args = { LISTEN, SEGMENT_DIR }
  if M.testInput then
    args = { LISTEN, SEGMENT_DIR, "--input", M.testInput }
  end
  local task
  task = hs.task.new(cfg.node, function(code, stdout, stderr)
    readLines(stdout)
    log("continuous: ended code=" .. tostring(code) .. " " .. (stderr or ""))
    for path in pairs(cont.pending) do
      os.remove(path)
      log("continuous: segment lost (listener ended)")
    end
    cont.pending = {}
    if cont.task == task then
      cont.task = nil
      cont.active = false
      cont.speaking = false
      cont.stopping = false
      if cont.stopTimer then
        cont.stopTimer:stop()
        cont.stopTimer = nil
      end
      M.sleepWatcher:stop()
      refresh()
      card.stop()
    end
  end, function(_, stdout, stderr)
    readLines(stdout)
    if stderr and stderr ~= "" then
      log("continuous: stderr " .. stderr)
    end
    return true
  end, args)
  local inputDevice = hs.audiodevice.defaultInputDevice()
  local deviceName = inputDevice and inputDevice:name() or ""
  log("continuous: device " .. deviceName)
  task:setEnvironment(nodeEnv({
    KOE_SILENCE = tostring(cfg.silence or 1.0),
    KOE_IDLE = tostring(cfg.idle or 0),
    KOE_INPUT_PACE = M.testInput and "1" or nil,
    KOE_DEVICE = deviceName,
    KOE_ON_DB = cfg.onDb and tostring(cfg.onDb) or nil,
    KOE_MIN_RATIO = cfg.minRatio and tostring(cfg.minRatio) or nil,
    KOE_CLOSE_MIC = cfg.closeMic,
  }))
  if not task:start() then
    skip("rec-failed", "聞き始められませんでした")
    return
  end
  cont.task = task
  cont.active = true
  card.start()
  event("continuous-start")
  M.sleepWatcher:start()
  refresh()
end

-- 止める合図から、耳が終わるのを待つ長さ。過ぎたら強制で終わらせる（耳が固まっても、モードが詰まらないように）。
local STOP_GRACE_SECONDS = 8

local function forceStop(task)
  if cont.task ~= task then
    return
  end
  log("continuous: stop timed out, killing")
  task:terminate() -- 耳は2回目の合図ですぐ自分で終わる
  cont.stopTimer = hs.timer.doAfter(2, function()
    cont.stopTimer = nil
    if cont.task == task then
      local pid = task:pid()
      if pid then
        os.execute("/bin/kill -9 " .. tostring(pid))
      end
      log("continuous: killed -9")
    end
  end)
end

-- やめる。話している途中なら、耳がそこまでを1件として出してから終わる（それは届ける）。
-- 止めるのは1回だけ。止めている間の2回目以降の合図は無視する。
function M.stopContinuous(reason)
  if not cont.task then
    return
  end
  if cont.stopping then
    log("continuous-stop ignored (stopping) " .. (reason or "key"))
    return
  end
  cont.stopping = true
  cont.active = false
  cont.speaking = false
  event("continuous-stop " .. (reason or "key"))
  local task = cont.task
  task:interrupt()
  cont.stopTimer = hs.timer.doAfter(STOP_GRACE_SECONDS, function()
    cont.stopTimer = nil
    forceStop(task)
  end)
  if reason == "paused" then
    cont.discard = true
    flash("skipped", "止める印が出たのでやめました", 2)
  elseif reason == "idle" then
    flash("skipped", "しばらく声がなかったのでやめました", 2)
  else
    refresh()
  end
end

function M.toggleContinuous()
  if cont.stopping then
    event("continuous-toggle ignored (stopping)")
    return
  elseif cont.task then
    M.stopContinuous("key")
  else
    M.startContinuous()
  end
end

-- 話し続けモードの最中に止める印（pauseFile）が新しく現れたら、モードを止め、途中の声は捨てる。
M.pauseWatch = hs.timer.doEvery(2, function()
  if not cfg.pauseFile or not cont.task or not cont.active then
    return
  end
  local now = paused()
  if now and not cont.wasPaused then
    M.stopContinuous("paused")
  end
  cont.wasPaused = now
end)

-- スリープ・画面ロック・スクリーンセーバーでやめる。
M.sleepWatcher = hs.caffeinate.watcher.new(function(kind)
  local w = hs.caffeinate.watcher
  if kind == w.systemWillSleep or kind == w.screensDidLock or kind == w.screensDidSleep
    or kind == w.screensaverDidStart or kind == w.sessionDidResignActive then
    M.stopContinuous("sleep")
  end
end)

M.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp }, function(e)
  local consume = false
  local ok, err = pcall(function()
    local isDown = e:getType() == hs.eventtap.event.types.keyDown
    local keyCode = e:getKeyCode()
    if keyCode == TOGGLE_KEY then
      consume = true
      if isDown then
        M.toggleContinuous()
      end
    elseif keyCode == START_KEY or keyCode == STOP_KEY then
      consume = true -- 合図のキーはアプリへ渡さない
      if isDown then
        M.onTrigger(keyCode == START_KEY)
      end
    elseif isDown then
      M.onOtherKey()
    end
  end)
  if not ok then
    log("tap error: " .. tostring(err))
  end
  return consume
end)
M.tap:start()

-- 区切ってから PENDING_LIMIT 秒たっても文字にした結果が来ないかたまりは、待つのをやめる（ピルが止まらないように）。
local PENDING_LIMIT = 20
local function checkPending()
  local now = hs.timer.secondsSinceEpoch()
  local changed = false
  for path, at in pairs(cont.pending) do
    if now - at > PENDING_LIMIT then
      log(string.format("continuous: segment stuck %.0fs %s", now - at, path))
      cont.pending[path] = nil
      changed = true
    end
  end
  if changed then
    refresh()
  end
end
M.checkPending = checkPending

-- eventtap はまれに macOS に止められるので、止まっていたら動かし直す。
M.watchdog = hs.timer.doEvery(5, function()
  if not M.tap:isEnabled() then
    log("tap restarted")
    M.tap:start()
  end
  if pill.checkTap() then
    log("pill tap restarted")
  end
  checkPending()
end)

log("koe: loaded from " .. DIR)
return M
