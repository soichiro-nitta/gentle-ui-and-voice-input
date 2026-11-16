-- 話しかける道具の、画面の右側に出す黒いピル。話し続けモードで言葉を送ると、ピルが広がって送った言葉の一覧のカードになる。
-- 2台のMacを並べて使っても、どちらが聞いているかを離れて見て分かる大きさにしてある。
-- 面は濃いグレー（不透明）、文字は白。状態は左の点の色と動きで示す。全角スペースの後ろ（「右シフトでやめる」など）はグレーの補足。
-- クリックはふだん下のアプリへ通る。ピル・カードの上だけ、ドラッグで動かせて、2本指スクロールでカードの一覧を送れる
-- （hs.eventtap で、面の上の操作だけを受け取る）。
-- 出る場所は画面の右側（右端から少し内側、縦は真ん中より少し上）。面は右の端をそろえて、カードになるときは左へ広がる。
-- 動かした場所は hs.settings の koe.pillPos に覚え（面の右の端と縦の真ん中）、次から同じ場所に出す。
-- 画面の構成が変わったら右の既定に戻す。ダブルクリックで右の既定へ。カードが画面の左からはみ出すときだけ、右へずらして出す。
-- 絵文字は使わない。
--   recording：赤の点がゆっくり明滅  transcribing：青の小さなくるくる
--   sent：緑の点にチェック（0.8秒で消える）  skipped：グレーの点（1.5秒で消える）
--   listening：話し続けモードで待っている。青の少し小さな点が、ゆっくり息をするように明滅
-- 使い方：pill.show(状態, 文, 消えるまでの秒〔省略で出しっぱなし〕)、pill.hide()、pill.hideAfter(秒)
--         pill.expand(カードの高さ)：カードへ広げる（本文は card.lua が上に重ねる）。pill.collapse()：ピルへ戻す。
--         pill.onLayout(面の位置, 薄さ, 広がり具合 0〜1)：毎コマ呼ぶ（card.lua が本文の位置と薄さを合わせる）。消えたら nil。
--
-- 動き
--   ・ピルは1つだけ。状態が変わっても消して出し直さず、同じピルの幅をばねで文字の長さへ合わせる。
--   ・カードへは、幅・高さ・角丸がばねで続けて変わる（形を変えながら広がる）。状態の行はそのままカードの頭になる。
--     面の右の端と縦の真ん中はそのまま。広がると左と上下へ伸び、頭の行が上へ、縮むと元へ戻る。
--   ・文字は古い文が少し上へ抜け、新しい文が下から入る（その場で重ねてクロスフェード）。
--   ・点は色をばねで混ぜ、形（明滅の点→くるくるの輪→チェックの点）をつなげて変える。
--   ・出るときは面が0.9倍・中身が下から、ばねで。消えるときは少し縮みながら薄くなる。
--   ・文字は拡大しない（拡大の終わりで文字が1px跳ぶため）。
--   ・動きを減らす設定では、形を変えずに、薄くしてから新しい形で出す。
--   ・hs.canvas には動きの仕組みがないので、hs.timer の60fpsでばねを自分で回し、止まったらタイマーも止める。
--     止まって明滅だけになったら、点の濃さだけを4〜8fpsで描き直す（文字や面は組み直さない）。
local M = {}

local function hex(value, alpha)
  return {
    red = ((value >> 16) & 0xff) / 255,
    green = ((value >> 8) & 0xff) / 255,
    blue = (value & 0xff) / 255,
    alpha = alpha or 1,
  }
end

-- 色の値。黒い面に合わせて、青・緑・赤は少し明るくしてある。
local TONE = {
  raised = hex(0x1c1c1e), -- 不透明
  ink = hex(0xf5f5f7),
  hint = hex(0xa1a1a6),
  danger = hex(0xff5a5f),
  accent = hex(0x4c8dff),
  success = hex(0x40c878),
  muted = hex(0x8e8e93),
}
M.TONE = TONE
-- 絵文字を足すときはここに書く（いまは使わない）。
M.prefix = {}

local FONT = { name = ".AppleSystemUIFont", size = 20 }
local HEIGHT = 52 -- ピルの高さ＝カードの頭の行の高さ
local PAD_X = 24
local DOT = 13
local GAP = 12
local SHADOW = 36
local K = DOT / 8 -- 点の中の形（輪・チェック）を、もとの8pxの点から大きくする倍率
local RISE = 10 -- 出るとき・文字が入れ替わるときのずれ（px）
local FPS = 60
-- カードの大きさ（card.lua と同じ値を使う）。
-- 中身は送った言葉の一覧だけなので、細めの1列。
M.CARD_W = 420
-- カードの高さの上限は画面の高さの MAX_FRAC（長い一覧も読めるように）。面の縦の真ん中から上下に広がるので、
-- 動かした場所によっては、画面の端までの近いほうの2倍まで。M.maxH() で今の上限を返す。
local MAX_FRAC = 0.78
M.MAX_H = 600 -- 読み込み時の目安（画面が分かったら M.maxH() を使う）
M.HEAD_H = HEIGHT
M.PAD_X = PAD_X
local CARD_RADIUS = 22
-- 動きが止まって明滅だけになったら、この速さに落とし、点だけを描き直す（話し続けモードで長く出しっぱなしでも重くしない）。
-- （12fpsで全部描き直すと Hammerspoon の CPU が約12%、点だけなら約3%）
local PULSE_FPS = { listening = 4, recording = 8 }

-- ばねの値（質量1。c = 2ζ√k）。行き過ぎは小さめ。
--   幅      ：k 420・c 36（ζ≈0.88、行き過ぎ約0.3%）
--   形      ：k 300・c 32（ζ≈0.92。ピル⇄カードの広がり。大きく動くので少しゆっくり）
--   出る    ：k 500・c 34（ζ≈0.76、面の行き過ぎ約2.5%）
--   文字    ：k 520・c 46（ζ≈1.0、行き過ぎなし）
--   色・輪  ：k 400・c 40（ζ=1.0）
--   点の大きさ：k 700・c 30（ζ≈0.57。小さな点だけは少し弾ませてよい）
M.SPRINGS = {
  width = { k = 420, c = 36 },
  morph = { k = 300, c = 32 },
  enter = { k = 500, c = 34 },
  text = { k = 520, c = 46 },
  tone = { k = 400, c = 40 },
  dot = { k = 700, c = 30 },
}
local EXIT_SECONDS = 0.18

local function spring(kind, value)
  local p = M.SPRINGS[kind]
  return { x = value, v = 0, to = value, k = p.k, c = p.c }
end

local function stepSpring(s, dt)
  local a = -s.k * (s.x - s.to) - s.c * s.v
  s.v = s.v + a * dt
  s.x = s.x + s.v * dt
  if math.abs(s.x - s.to) < 0.001 and math.abs(s.v) < 0.01 then
    s.x = s.to
    s.v = 0
    return true
  end
  return false
end

local function clamp01(x)
  return math.max(0, math.min(1, x))
end

local function reduceMotion()
  local out = hs.execute("/usr/bin/defaults read com.apple.universalaccess reduceMotion 2>/dev/null")
  return out and out:match("^%s*1") ~= nil
end

-- 点の見た目（状態ごとの行き先）。
local DOT_LOOK = {
  recording = { color = TONE.danger, fill = DOT / 2, ring = 0, check = 0 },
  listening = { color = TONE.accent, fill = DOT / 2 - K, ring = 0, check = 0 },
  transcribing = { color = TONE.accent, fill = 0, ring = 1, check = 0 },
  sent = { color = TONE.success, fill = DOT / 2 + 2 * K, ring = 0, check = 1 },
  skipped = { color = TONE.muted, fill = DOT / 2, ring = 0, check = 0 },
}

local canvas = nil
local tick = nil
local slow = false -- tick が明滅だけの遅い刻みか
local hideTimer = nil
local last = nil
local pill = nil -- 今の見た目（ばねの集まり）

local function textWidth(text)
  local size = hs.drawing.getTextDrawingSize(text, FONT)
  return math.ceil(size.w) + 2, math.ceil(size.h)
end

local function pillWidth(textW)
  return math.ceil(PAD_X + DOT + GAP + textW + PAD_X)
end

-- 窓はカードのいちばん大きい形が入る大きさ。面の右の端＝窓の右の端から SHADOW 内側、面の縦の真ん中＝窓の縦の真ん中。
-- 置き場所（anchor）は、面の右の端の x と縦の真ん中の y。覚えた場所（koe.pillPos。そのときの画面と同じときだけ）か、右の既定。
local CANVAS_W = M.CARD_W + SHADOW * 2
local CANVAS_H = M.MAX_H + SHADOW * 2
local POS_KEY = "koe.pillPos"
local EDGE = 32 -- 右の既定：画面の右端からの間
local ABOVE = 0.42 -- 右の既定：縦は画面の上からこの割合（真ん中より少し上）
local anchor = nil -- 今の置き場所 { x = 面の右の端, y = 面の縦の真ん中 }

local function screenFrame()
  return hs.screen.mainScreen():frame()
end

local function screenKey(f)
  -- 座標は小数のことがある（%d だと落ちる）ので、丸めてから並べる。
  return string.format("%.0f,%.0f,%.0f,%.0f", f.x, f.y, f.w, f.h)
end

-- 置き場所を、ピルが画面からはみ出さない範囲に収める（x は面の右の端）。
local function clampAnchor(f, x, y)
  local my = HEIGHT / 2 + 8
  return math.max(f.x + 240, math.min(f.x + f.w - 8, x)), math.max(f.y + my, math.min(f.y + f.h - my, y))
end

local function defaultAnchor(f)
  return f.x + f.w - EDGE, f.y + f.h * ABOVE
end

local function savedAnchor()
  local f = screenFrame()
  local saved = hs.settings.get(POS_KEY)
  if type(saved) == "table" and saved.screen == screenKey(f) and tonumber(saved.y) then
    local x = tonumber(saved.right)
    if not x and tonumber(saved.x) then
      -- 前の形（面の真ん中）で覚えていたら、ピルの右の端へ直す（置いたピルの見た目の場所をそのまま使う）。
      x = saved.x + pillWidth(textWidth("聞いています　右シフトでやめる")) / 2
    end
    if x then
      return clampAnchor(f, x, saved.y)
    end
  end
  return defaultAnchor(f)
end

-- 今のカードの高さの上限。
function M.maxH()
  local f = anchor and anchor.f or screenFrame()
  local cap = math.floor(f.h * MAX_FRAC)
  local cy = anchor and anchor.y or select(2, savedAnchor())
  local room = 2 * math.min(cy - f.y, f.y + f.h - cy) - 24
  return math.max(HEIGHT + 120, math.min(cap, math.floor(room)))
end

-- 面の幅が width のときの、面の右の端（画面の座標）。横長のカードが左からはみ出すときだけ右へずらす。
local function faceRight(width)
  local f = anchor.f -- 出したときの画面（毎コマ画面を聞き直さない。画面が2つのとき、途中で入れ替わらないように）
  return math.min(f.x + f.w - 8, math.max(anchor.x, f.x + 8 + width))
end

local function canvasFrame()
  local f = screenFrame()
  CANVAS_H = math.floor(f.h * MAX_FRAC) + SHADOW * 2
  M.MAX_H = math.floor(f.h * MAX_FRAC)
  local x, y = savedAnchor()
  anchor = { x = x, y = y, f = f }
  return { x = x + SHADOW - CANVAS_W, y = y - CANVAS_H / 2, w = CANVAS_W, h = CANVAS_H }
end

local function newCanvas()
  local c = hs.canvas.new(canvasFrame())
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "transient" })
  c:clickActivating(false)
  c[1] = {
    type = "rectangle",
    frame = { x = 0, y = 0, w = 10, h = HEIGHT },
    roundedRectRadii = { xRadius = HEIGHT / 2, yRadius = HEIGHT / 2 },
    fillColor = TONE.raised,
    strokeColor = { alpha = 0 },
    withShadow = true,
    shadow = { blurRadius = 28, color = { black = 1, alpha = 0.3 }, offset = { h = -8, w = 0 } },
  }
  c[2] = { type = "circle", center = { x = 0, y = 0 }, radius = 0, action = "fill", fillColor = TONE.muted }
  c[3] = {
    type = "arc",
    center = { x = 0, y = 0 },
    radius = DOT / 2 + K,
    startAngle = 0,
    endAngle = 270,
    arcRadii = false,
    action = "stroke",
    strokeColor = TONE.accent,
    strokeWidth = 2 * K,
    strokeCapStyle = "round",
  }
  c[4] = {
    type = "segments",
    coordinates = { { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 } },
    action = "stroke",
    strokeColor = hex(0xffffff, 0),
    strokeWidth = 1.6 * K,
    strokeCapStyle = "round",
    strokeJoinStyle = "round",
  }
  c[5] = { type = "text", text = "", frame = { x = 0, y = 0, w = 1, h = 1 } }
  c[6] = { type = "text", text = "", frame = { x = 0, y = 0, w = 1, h = 1 } }
  c:alpha(0)
  c:show()
  return c
end

local function newSlot(element)
  return { element = element, text = nil, w = 0, h = 0, alpha = spring("text", 0), y = spring("text", 0) }
end

-- 文字：全角スペースの前は白、後ろ（操作の補足）はグレー。
local function styled(text, alpha)
  local function part(s, tone)
    return hs.styledtext.new(s, { font = FONT, color = { red = tone.red, green = tone.green, blue = tone.blue, alpha = alpha } })
  end
  local main, rest = text:match("^(.-)(　.*)$")
  if not main then
    return part(text, TONE.ink)
  end
  return part(main, TONE.ink) .. part(rest, TONE.hint)
end

-- 点（塗り）の明滅：録音中はゆっくり明滅。黒い面では暗いと沈むので、下限は高め（話している0.7・聞いている0.6）。
-- カードに広がっている間は明滅しない（読んでいる間は何も回さない。窓が大きく、描き直しが重いため）。
local function pulseOf(p, now)
  if p.expanded then
    return 1
  end
  local t = now - p.since
  if p.state == "recording" then
    return 0.7 + 0.3 * (0.5 + 0.5 * math.cos(t * 2 * math.pi / 1.6))
  elseif p.state == "listening" then
    return 0.6 + 0.4 * (0.5 + 0.5 * math.cos(t * 2 * math.pi / 2.8))
  end
  return 1
end

-- 明滅だけのときは、点の濃さだけを変える（文字や面は組み直さない）。
local function renderPulse(now)
  local p = pill
  canvas[2].fillColor = { red = p.r.x, green = p.g.x, blue = p.b.x, alpha = pulseOf(p, now) }
end

-- 広がり具合（0＝ピル、1＝カード）。
local function progress(p)
  local span = (p.cardH or HEIGHT) - HEIGHT
  if span <= 1 then
    return p.expanded and 1 or 0
  end
  return clamp01((p.height.x - HEIGHT) / span)
end

-- 1コマ分を描く。
local function render(now)
  local c, p = canvas, pill
  local width, height = p.width.x, p.height.x
  local scale = p.scale.x
  local rise = p.rise.x
  -- 窓の場所：面の右の端が置き場所に来るように（はみ出すときはずらす）。動いたときだけ窓を動かす。
  local right = faceRight(width)
  local want = { x = math.floor(right + SHADOW - CANVAS_W + 0.5), y = math.floor(anchor.y - CANVAS_H / 2 + 0.5) }
  local cf0 = c:frame()
  if cf0.x ~= want.x or cf0.y ~= want.y then
    c:topLeft(want)
  end
  local cx = CANVAS_W - SHADOW - width / 2
  local cy = CANVAS_H / 2 + rise
  -- 面：大きさだけ0.9倍などに縮める（文字は縮めない）。面の右の端を置き場所に。
  local sw, sh = width * scale, height * scale
  local radius = math.min(p.radius.x, sh / 2)
  c[1].frame = { x = cx - sw / 2, y = cy - sh / 2, w = sw, h = sh }
  c[1].roundedRectRadii = { xRadius = radius, yRadius = radius }
  local opacity = clamp01(p.opacity.x)
  c:alpha(opacity)

  -- 頭の行（点と文字）は、面の上の端から HEIGHT の中に置く。ピルのときは面そのもの。
  local left = cx - width / 2
  local top = cy - height / 2
  local dx = left + PAD_X + DOT / 2
  local dy = top + HEIGHT / 2
  local color = { red = p.r.x, green = p.g.x, blue = p.b.x }

  c[2].center = { x = dx, y = dy }
  c[2].radius = math.max(0, p.fill.x)
  c[2].fillColor = { red = color.red, green = color.green, blue = color.blue, alpha = pulseOf(p, now) }

  -- くるくるの輪：出てくるときは小さい所から広がり、抜けるときは閉じながら薄くなる。
  local ring = clamp01(p.ring.x)
  local angle = ((now - p.since) * 360) % 360
  c[3].center = { x = dx, y = dy }
  c[3].radius = (DOT / 2 - K) + 2 * K * ring
  c[3].startAngle = angle
  c[3].endAngle = angle + 360 - 90 * ring
  c[3].strokeColor = { red = color.red, green = color.green, blue = color.blue, alpha = ring }

  -- チェック：緑の点の中に、点が開くのと同じばねで出る。
  local check = clamp01(p.check.x)
  local k = (0.6 + 0.4 * check) * K
  c[4].coordinates = {
    { x = dx - 2.4 * k, y = dy + 0.1 * k },
    { x = dx - 0.7 * k, y = dy + 1.7 * k },
    { x = dx + 2.4 * k, y = dy - 1.7 * k },
  }
  c[4].strokeColor = hex(0xffffff, check)

  -- 文字：2つの枠で古い文と新しい文を重ねる。
  local tx = left + PAD_X + DOT + GAP
  for i, slot in ipairs(p.slots) do
    local e = c[4 + i]
    if slot.text then
      e.frame = { x = tx, y = top + (HEIGHT - slot.h) / 2 + slot.y.x, w = slot.w, h = slot.h + 2 }
      e.text = styled(slot.text, clamp01(slot.alpha.x))
    end
  end

  -- 面の位置（画面の座標）を覚えておく（ドラッグ・スクロールの当たり判定に使う）。
  local cf = c:frame()
  M.face = { x = cf.x + cx - sw / 2, y = cf.y + cy - sh / 2, w = sw, h = sh }
  -- 本文（card.lua）へ、面の位置（画面の座標）と薄さと広がり具合を渡す。
  if M.onLayout then
    local f = cf
    M.onLayout({ x = f.x + left, y = f.y + top, w = width, h = height }, opacity, progress(p))
  end
end

local function stopTick()
  if tick then
    tick:stop()
    tick = nil
  end
  slow = false
end

local stopTap
local function destroy()
  stopTick()
  stopTap()
  M.face = nil
  if canvas then
    canvas:delete()
    canvas = nil
  end
  pill = nil
  if M.onLayout then
    M.onLayout(nil)
  end
end

local function frame()
  if not canvas or not pill then
    stopTick()
    return
  end
  local p = pill
  local now = hs.timer.secondsSinceEpoch()
  -- 明滅だけの遅い刻み：ばねは止まっているので、点の濃さだけ変える（動きが来たら startTick が速い刻みへ戻す）。
  if slow then
    renderPulse(now)
    return
  end
  local dt = math.min(now - (last or now), 1 / 20)
  last = now
  -- ばねは細かく刻んで回す（コマが落ちても安定させる）。
  local settled = true
  local steps = math.max(1, math.ceil(dt / (1 / 240)))
  local h = dt / steps
  local springs = { p.width, p.height, p.radius, p.scale, p.rise, p.r, p.g, p.b, p.fill, p.ring, p.check }
  if not p.exit then
    table.insert(springs, p.opacity)
  end
  for _, slot in ipairs(p.slots) do
    table.insert(springs, slot.alpha)
    table.insert(springs, slot.y)
  end
  for _ = 1, steps do
    for _, s in ipairs(springs) do
      if not stepSpring(s, h) then
        settled = false
      end
    end
  end
  -- 消えるとき：少し縮みながら薄くなる（はじめゆっくり、終わり速く）。
  if p.exit then
    local t = clamp01((now - p.exit.at) / EXIT_SECONDS)
    local e = t * t
    p.opacity.x = p.exit.opacity * (1 - e)
    p.scale.x = p.exit.scale + (0.95 - p.exit.scale) * e
    p.rise.x = p.exit.rise + (2 - p.exit.rise) * e
    if t >= 1 then
      destroy()
      return
    end
    settled = false
  end
  -- 抜けきった文字は外す。
  for i, slot in ipairs(p.slots) do
    if slot.text and slot.alpha.to == 0 and slot.alpha.x <= 0.001 then
      slot.text = nil
      canvas[4 + i].text = ""
    end
  end
  render(now)
  -- 明滅とくるくるは止まらないので回し続ける。それ以外は止まったらタイマーも止める。
  local pulsing = (p.state == "recording" or p.state == "listening") and not p.expanded
  local continuous = pulsing or p.ring.x > 0.001
  if settled and (not continuous or (pulsing and p.ring.x <= 0.001)) then
    stopTick()
    -- 明滅だけが残るときは、遅い刻みで点だけを回す。
    if continuous then
      last = now
      tick = hs.timer.doEvery(1 / (PULSE_FPS[p.state] or 4), frame)
      slow = true
    end
  end
end

local function startTick()
  if tick and slow then
    stopTick()
  end
  if not tick then
    last = hs.timer.secondsSinceEpoch()
    tick = hs.timer.doEvery(1 / FPS, frame)
  end
end

function M.hide()
  if hideTimer then
    hideTimer:stop()
    hideTimer = nil
  end
  if not pill or pill.exit then
    return
  end
  pill.exit = { at = hs.timer.secondsSinceEpoch(), opacity = pill.opacity.x, scale = pill.scale.x, rise = pill.rise.x }
  startTick()
end

-- 少し待ってから消す（すでに消す予定があれば、そのまま）。
function M.hideAfter(seconds)
  if not pill or pill.exit or hideTimer then
    return
  end
  hideTimer = hs.timer.doAfter(seconds, M.hide)
end

function M.isExpanded()
  return pill ~= nil and pill.expanded == true and not pill.exit
end

function M.canvas()
  return canvas
end

-- 形を変える。動きを減らす設定では、薄くしてから新しい形で出す。
local function morph(p, width, height, radius)
  p.width.to, p.height.to, p.radius.to = width, height, radius
  if p.still then
    p.width.x, p.height.x, p.radius.x = width, height, radius
    p.width.v, p.height.v, p.radius.v = 0, 0, 0
    p.opacity.x = math.min(p.opacity.x, 0.2)
  end
  startTick()
end

-- カードへ広げる（高さは card.lua が本文から決める）。ピルが出ていなければ何もしない（false を返す）。
function M.expand(height)
  local p = pill
  if not p or p.exit then
    return false
  end
  if hideTimer then
    hideTimer:stop()
    hideTimer = nil
  end
  p.expanded = true
  p.cardH = math.max(HEIGHT + 1, math.min(M.maxH(), height))
  -- 広げるときは、新しい形のばねを最初から回す（遅い刻みのままにしない）。
  morph(p, M.CARD_W, p.cardH, CARD_RADIUS)
  return true
end

-- ピルへ戻す。
function M.collapse()
  local p = pill
  if not p or not p.expanded then
    return
  end
  p.expanded = false
  local front = p.slots[p.front]
  morph(p, pillWidth(front.w or 0), HEIGHT, HEIGHT / 2)
end

-- ---- ピル・カードの上の操作（ドラッグ・ダブルクリック・2本指スクロール） ----
-- 面の上で押したときだけ受け取り、ほかはそのまま下のアプリへ通す。出ている間だけ動かす。
-- M.onScroll(dy)：カードの一覧を送る（card.lua が受け取る。送れたら true）。M.onMoved()：動かし終えた（card.lua が高さを合わせ直す）。
local tap = nil
local drag = nil

local function inFace(pt)
  local f = M.face
  return f and pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h
end

local function moveTo(x, y)
  if not canvas then
    return
  end
  local f = screenFrame()
  x, y = clampAnchor(f, x, y)
  anchor = { x = x, y = y, f = f }
  if pill then
    render(hs.timer.secondsSinceEpoch())
  end
  return x, y
end

local function remember(x, y)
  if x then
    hs.settings.set(POS_KEY, { right = x, y = y, screen = screenKey(screenFrame()) })
  else
    hs.settings.clear(POS_KEY)
  end
end

local T = hs.eventtap.event.types
local P = hs.eventtap.event.properties
local function onMouse(e)
  local kind = e:getType()
  -- 場所は合図そのものから読む。hs.mouse.absolutePosition() は、ここで合図を止めている間は押した瞬間の場所のまま変わらず、
  -- ドラッグしてもピルが動かなかった。
  local pt = e:location()
  if kind == T.scrollWheel then
    if not inFace(pt) or not M.isExpanded() or not M.onScroll then
      return false
    end
    local dy = e:getProperty(P.scrollWheelEventPointDeltaAxis1)
    if dy == 0 then
      dy = e:getProperty(P.scrollWheelEventDeltaAxis1) * 12
    end
    -- 送るものがなければ、そのまま下のアプリへ通す。
    return M.onScroll(-dy) == true
  elseif kind == T.leftMouseDown then
    if not inFace(pt) then
      return false
    end
    if e:getProperty(P.mouseEventClickState) == 2 then
      -- ダブルクリック：右の既定へ戻して、覚えた場所を消す。
      drag = nil
      remember(nil)
      moveTo(defaultAnchor(screenFrame()))
      if M.onMoved then
        M.onMoved()
      end
      return true
    end
    -- 今見えている場所から動かす（はみ出してずらしているときも、見えている面の右の端から）。
    drag = { mx = pt.x, my = pt.y, cx = M.face.x + M.face.w, cy = anchor.y, moved = false }
    return true
  elseif kind == T.leftMouseDragged then
    if not drag then
      return false
    end
    drag.moved = true
    drag.x, drag.y = moveTo(drag.cx + pt.x - drag.mx, drag.cy + pt.y - drag.my)
    return true
  elseif kind == T.leftMouseUp then
    if not drag then
      return false
    end
    local d = drag
    drag = nil
    if d.moved and d.x then
      remember(d.x, d.y)
      if M.log then
        M.log(string.format("pill: moved to %.0f,%.0f", d.x, d.y))
      end
      if M.onMoved then
        M.onMoved()
      end
    end
    return true
  end
  return false
end

function M.startTap()
  if tap then
    return
  end
  tap = hs.eventtap.new({ T.scrollWheel, T.leftMouseDown, T.leftMouseDragged, T.leftMouseUp }, function(e)
    local ok, consume = pcall(onMouse, e)
    if not ok then
      drag = nil
      if M.log then
        M.log("pill: mouse error " .. tostring(consume))
      end
      return false
    end
    return consume == true
  end)
  tap:start()
end

stopTap = function()
  drag = nil
  if tap then
    tap:stop()
    tap = nil
  end
end

-- eventtap はまれに macOS に止められるので、出ている間に止まっていたら動かし直す（koe.lua の見張りから呼ぶ）。
function M.checkTap()
  if tap and not tap:isEnabled() then
    tap:start()
    return true
  end
  return false
end

function M.show(state, text, seconds)
  if hideTimer then
    hideTimer:stop()
    hideTimer = nil
  end
  text = (M.prefix[state] or "") .. text
  local tw, th = textWidth(text)
  local look = DOT_LOOK[state] or DOT_LOOK.skipped
  local now = hs.timer.secondsSinceEpoch()

  local fresh = (pill == nil)
  if fresh then
    canvas = newCanvas()
    M.startTap()
    local width = pillWidth(tw)
    local still = reduceMotion()
    pill = {
      still = still,
      width = spring("width", width),
      height = spring("morph", HEIGHT),
      radius = spring("morph", HEIGHT / 2),
      scale = spring("enter", still and 1 or 0.9),
      rise = spring("enter", still and 0 or RISE),
      opacity = spring("text", 0),
      r = spring("tone", look.color.red),
      g = spring("tone", look.color.green),
      b = spring("tone", look.color.blue),
      fill = spring("dot", look.fill * 0.5),
      ring = spring("tone", 0),
      check = spring("dot", 0),
      slots = { newSlot(5), newSlot(6) },
      front = 1,
      since = now,
      expanded = false,
    }
  end
  local p = pill
  -- 消えかけていたら、今の姿からそのまま戻す。
  if p.exit then
    p.exit = nil
  end
  if p.state ~= state then
    -- くるくるの回り始めは、入れ替わった瞬間から数える。
    if state == "transcribing" or state == "recording" or state == "listening" then
      p.since = now
    end
    p.state = state
  end
  -- カードのときは幅をカードのまま、ピルのときは文字の長さへ。
  p.width.to = p.expanded and M.CARD_W or pillWidth(tw)
  p.scale.to = 1
  p.rise.to = 0
  p.opacity.to = 1
  p.r.to, p.g.to, p.b.to = look.color.red, look.color.green, look.color.blue
  p.fill.to = look.fill
  p.ring.to = look.ring
  p.check.to = look.check

  -- 文字：同じなら何もしない。違えば、今の文を上へ抜き、もう一方の枠で新しい文を下から入れる。
  local cur = p.slots[p.front]
  if cur.text ~= text then
    if cur.text then
      cur.alpha.to = 0
      cur.y.to = -RISE
      p.front = 3 - p.front
    end
    local slot = p.slots[p.front]
    slot.text = text
    slot.w, slot.h = tw, th
    slot.alpha.x = fresh and 1 or 0
    slot.alpha.v = 0
    slot.alpha.to = 1
    slot.y.x = fresh and 0 or RISE
    slot.y.v = 0
    slot.y.to = 0
  end

  render(now)
  startTick()
  if seconds then
    hideTimer = hs.timer.doAfter(seconds, M.hide)
  end
end

return M
