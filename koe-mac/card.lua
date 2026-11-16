-- 話しかける道具の、ピルが広がってできるカードの「本文」。面と頭の行（状態：聞いています・話しています・文字にしています など）は
-- pill.lua が描き、ここは頭の行より下だけを描く。
-- 中身は、この話し続けモードで送った言葉の一覧だけ（新しい順。小さなアイコン付き、古いものほど少し薄い）。
-- いつ広がるか：話し続けモードの間に、言葉を送ったとき。話し始めても閉じない（頭の行の状態だけ「話しています」に変わる）。
-- いつ縮むか：モードを止めたら、koe.lua が1秒（koe.cardLinger）でピルごと消す。止める印・画面共有が始まったらピルへ戻す。
-- 止める印（設定の pauseFile）がある間と画面共有中は広げない（ピルだけ）。
-- 一覧がカードに入りきらないときは、カードの上で2本指スクロールすると一覧が送られる（上下の端は面の色へぼかす）。
-- 使い方：card.attach(pill)、card.start()（モードを始めた）、card.stop()（止めた）、card.addOwn(送った言葉)、card.preview(言葉の配列)（試し）。
--
-- 作り
--   ・hs.canvas で描く（マウスの受け口を付けないので、クリックは下の画面に通る。hs.webview はクリックを通せない）。
--   ・本文はピルとは別の canvas。ピルが毎コマ面の位置を知らせ（pill.onLayout）、本文はそれに合わせて動き、面の中で切れる。
--     広がりが6割を過ぎてから濃くなり、縮み始めるとすぐ薄くなる。文字は拡大しない。
--   ・自分ではタイマーを回さない（動きはピルのばねが回す）。モードの間に回すのは、止める印・画面共有の見直し（6秒ごと、広がっている間だけ働く）だけ。
local M = {}

local function hex(value, alpha)
  return {
    red = ((value >> 16) & 0xff) / 255,
    green = ((value >> 8) & 0xff) / 255,
    blue = (value & 0xff) / 255,
    alpha = alpha or 1,
  }
end

-- pill.lua と同じダークの値。
local TONE = {
  raised = hex(0x1c1c1e),
  ink = hex(0xf5f5f7),
  muted = hex(0x8e8e93),
}

-- 止める印のファイルとアイコンは、koe.lua が設定から入れる（M.pauseFile・M.iconPath。どちらも省略できる）。
M.pauseFile = nil
M.iconPath = nil

-- 大きさは pill.lua に合わせる（attach で読み直す）。
local WIDTH = 420
local MAX_H = 600
local TOP_H = 52 -- ピルの頭の行の高さ
local PAD_X = 24
local PAD_BOTTOM = 22
local FADE_H = 36 -- 入りきらない側の端をぼかす高さ
local BLOCK_CHECK = 6 -- 止める印・画面共有を見直す間（画面共有の確かめに約30msかかるので間をあける）

local OWN = { name = ".AppleSystemUIFont", size = 15 }
local OWN_LINE_SPACING = 3
local OWN_H = math.ceil(hs.drawing.getTextDrawingSize("あ", OWN).h)
local OWN_KEEP = 50 -- 覚えておく数（このモードの間）
local OWN_GAP = 12 -- 言葉と言葉のあいだ
local OWN_ICON = 18
local OWN_TEXT_GAP = 10 -- アイコンと文のあいだ

-- モードを止めてから出しておく秒。既定は設定の cardLinger（1秒）。hs.settings の koe.cardLinger があればそちらを使う。
function M.linger()
  local v = tonumber(hs.settings.get("koe.cardLinger"))
  return (v and v >= 0) and v or (M.lingerDefault or 1)
end

local function color(tone, alpha)
  return { red = tone.red, green = tone.green, blue = tone.blue, alpha = alpha or 1 }
end

-- 画面共有中か。ブラウザーの「画面を共有しています」のバーと、Zoom の共有の窓で見る（hs.window.list は約30ms、出している間だけ）。
local SHARING = { "sharing your screen", "is sharing a window", "is sharing a tab", "画面を共有しています", "ウィンドウを共有しています", "タブを共有しています" }
local function screenSharing()
  local ok, list = pcall(hs.window.list, true)
  if not ok or type(list) ~= "table" then
    return false
  end
  for _, w in ipairs(list) do
    if (w.kCGWindowOwnerName or "") == "CptHost" then
      return true
    end
    local name = (w.kCGWindowName or ""):lower()
    for _, word in ipairs(SHARING) do
      if name:find(word, 1, true) then
        return true
      end
    end
  end
  return false
end

local function blocked()
  return (M.pauseFile and hs.fs.attributes(M.pauseFile) ~= nil) or screenSharing()
end

-- ---- 描く ----

local content = nil
local layout = nil -- ピルから届いた面の位置・薄さ・広がり具合
local wantH = nil -- 今の中身に合うカードの高さ
-- 一覧のスクロール。first・last：一覧の要素の番号の範囲。ys：それぞれのもとの y。offset：今どれだけ送ったか。
local scroll = { offset = 0, max = 0, first = nil, last = nil, top = nil, bottom = nil, rect = nil, ys = nil }
local icon = nil

-- アイコンは丸く切ったものを1回だけ作る（一覧のスクロールの切り取りと重ならないよう、描くたびに丸く切らない）。
local function ownIcon()
  if icon == nil then
    icon = false
    local raw = M.iconPath and hs.image.imageFromPath(M.iconPath)
    if raw then
      local size = OWN_ICON * 2
      local c = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
      c:replaceElements({
        { type = "circle", action = "clip", center = { x = size / 2, y = size / 2 }, radius = size / 2 },
        { type = "image", image = raw, frame = { x = 0, y = 0, w = size, h = size }, imageScaling = "scaleProportionally" },
        { type = "resetClip" },
      })
      icon = c:imageFromCanvas() or raw
      c:delete()
    end
  end
  return icon or nil
end

local state = { active = false, own = {}, checkTimer = nil }
M.state = state

local function log(message)
  if M.log then
    M.log("card: " .. message)
  end
end

local function destroy()
  if content then
    content:delete()
  end
  content, wantH = nil, nil
end

-- 新しいものほど濃い（いちばん新しい1件は白、ほかは少し薄く、古いものほど薄く。下限あり）。
local function alphaOf(i)
  return math.max(0.45, 1 - (i - 1) * 0.12)
end

-- 1つの言葉の文と、折り返しをふくめた高さの見積もり。canvas の測る関数は折り返しを数えないので、
-- 1行に並べた幅から行数を見積もる（日本語は文字ごとに折り返すので、少し余裕を見る）。
local function ownText(said, alpha, w)
  local styled = hs.styledtext.new(said, {
    font = OWN,
    color = color(TONE.ink, alpha * 0.9),
    paragraphStyle = { lineSpacing = OWN_LINE_SPACING, lineBreak = "wordWrap" },
  })
  local lines = 0
  for part in (said .. "\n"):gmatch("(.-)\n") do
    local pw = hs.drawing.getTextDrawingSize(part, OWN).w
    lines = lines + math.max(1, math.ceil(pw / (w * 0.95)))
  end
  local h = lines * (OWN_H + OWN_LINE_SPACING) - OWN_LINE_SPACING
  if content then
    content:replaceElements({ { type = "text", frame = { x = 0, y = 0, w = w, h = 10 }, text = "" } })
    local ok, size = pcall(function()
      return content:minimumTextSize(1, styled)
    end)
    if ok and size and size.h and size.h > 0 then
      h = math.max(h, math.ceil(size.h))
    end
  end
  return styled, h + 2
end

-- 一覧（新しい順）を組んで、本文の canvas に入れる。合うカードの高さも決める。
local function applyContent()
  local textX = PAD_X + OWN_ICON + OWN_TEXT_GAP
  local textW = WIDTH - PAD_X - textX
  local rows = {}
  local total = 0
  local own = state.own
  for i = 1, #own do
    local said = own[#own - i + 1].text
    local alpha = alphaOf(i)
    local styled, h = ownText(said, alpha, textW)
    table.insert(rows, { styled = styled, h = h, alpha = alpha, y = total })
    total = total + h + (i < #own and OWN_GAP or 0)
  end

  local maxH = (M.pill and M.pill.maxH) and M.pill.maxH() or MAX_H
  local room = maxH - TOP_H - PAD_BOTTOM
  local listH = math.max(OWN_H, math.min(total, room))
  scroll.max = math.max(0, total - listH)
  scroll.offset = math.max(0, math.min(scroll.max, scroll.offset))
  scroll.rect = { x = 0, y = 0, w = WIDTH, h = listH }

  local elements = {}
  table.insert(elements, { type = "rectangle", action = "clip", frame = scroll.rect })
  scroll.first = #elements + 1
  scroll.ys = {}
  local img = ownIcon()
  for _, row in ipairs(rows) do
    local iconY = row.y + (OWN_H - OWN_ICON) / 2
    if img then
      table.insert(elements, { type = "image", image = img, frame = { x = PAD_X, y = iconY, w = OWN_ICON, h = OWN_ICON }, imageScaling = "scaleProportionally", imageAlpha = row.alpha })
    else
      table.insert(elements, { type = "circle", action = "fill", center = { x = PAD_X + OWN_ICON / 2, y = iconY + OWN_ICON / 2 }, radius = OWN_ICON / 2, fillColor = color(TONE.muted, row.alpha) })
    end
    table.insert(scroll.ys, { kind = img and "image" or "circle", y = iconY })
    table.insert(elements, { type = "text", frame = { x = textX, y = row.y, w = textW, h = row.h }, text = row.styled })
    table.insert(scroll.ys, { kind = "text", y = row.y })
  end
  scroll.last = #elements
  table.insert(elements, { type = "resetClip" })
  scroll.top, scroll.bottom = nil, nil
  if scroll.max > 0 then
    -- 入りきらない側の端を、面の色へぼかす（上は送ったとき、下はまだ先があるとき）。
    table.insert(elements, {
      type = "rectangle",
      frame = { x = 0, y = 0, w = WIDTH, h = FADE_H },
      action = "fill",
      fillGradient = "linear",
      fillGradientAngle = 270,
      fillGradientColors = { color(TONE.raised, 1), color(TONE.raised, 0) },
      strokeColor = { alpha = 0 },
    })
    scroll.top = #elements
    table.insert(elements, {
      type = "rectangle",
      frame = { x = 0, y = listH - FADE_H, w = WIDTH, h = FADE_H },
      action = "fill",
      fillGradient = "linear",
      fillGradientAngle = 90,
      fillGradientColors = { color(TONE.raised, 1), color(TONE.raised, 0) },
      strokeColor = { alpha = 0 },
    })
    scroll.bottom = #elements
  end
  content:replaceElements(elements)
  wantH = TOP_H + listH + PAD_BOTTOM
  M.applyScroll()
end

-- 今の送り具合を、一覧の位置と、上下のぼかしの濃さに反映する（組み直さない）。
function M.applyScroll()
  if not content or not scroll.first or not scroll.ys then
    return
  end
  for n, item in ipairs(scroll.ys) do
    local el = content[scroll.first + n - 1]
    if el then
      if item.kind == "circle" then
        local c = el.center
        el.center = { x = c.x, y = item.y + OWN_ICON / 2 - scroll.offset }
      else
        local f = el.frame
        el.frame = { x = f.x, y = item.y - scroll.offset, w = f.w, h = f.h }
      end
    end
  end
  if scroll.top and content[scroll.top] then
    local a = math.min(1, scroll.offset / FADE_H)
    content[scroll.top].fillGradientColors = { color(TONE.raised, a), color(TONE.raised, 0) }
  end
  if scroll.bottom and content[scroll.bottom] then
    local a = math.min(1, (scroll.max - scroll.offset) / FADE_H)
    content[scroll.bottom].fillGradientColors = { color(TONE.raised, a), color(TONE.raised, 0) }
  end
end

-- カードの上の2本指スクロール（pill.lua から）。dy は下へ読み進める向きが正。
local function onScroll(dy)
  if not content or scroll.max <= 0 then
    return false
  end
  local before = scroll.offset
  scroll.offset = math.max(0, math.min(scroll.max, scroll.offset + dy))
  if scroll.offset ~= before then
    M.applyScroll()
  end
  return true
end
M.scroll = scroll

-- 本文を、ピルの面に合わせて置く。面の中だけに見えるよう、窓の高さを面の残りに合わせる（はみ出しは切れる）。
local function place()
  if not content or not layout then
    return
  end
  local r = layout.rect
  local reveal = math.max(0, math.min(1, (layout.progress - 0.6) / 0.4))
  content:frame({ x = r.x, y = r.y + TOP_H, w = WIDTH, h = math.max(1, r.h - TOP_H) })
  content:alpha(layout.opacity * reveal)
end

-- ピルから毎コマ届く。nil はピルが消えた。
local function onLayout(rect, opacity, progress)
  if not rect then
    layout = nil
    destroy()
    return
  end
  layout = { rect = rect, opacity = opacity, progress = progress }
  place()
end

-- 今の一覧でピルを広げる（もう広がっていれば、その場で組み直す）。新しい言葉が来たら、いちばん上（新しい側）へ戻す。
local function render()
  local pill = M.pill
  if not pill or #state.own == 0 then
    return
  end
  scroll.offset = 0
  if not content then
    local c = hs.canvas.new({ x = 0, y = 0, w = WIDTH, h = 1 })
    c:level(hs.canvas.windowLevels.overlay)
    c:behavior({ "canJoinAllSpaces", "transient" })
    c:clickActivating(false)
    c:alpha(0)
    c:show()
    if pill.canvas() then
      c:orderAbove(pill.canvas())
    end
    content = c
    applyContent()
    if not pill.expand(wantH) then
      destroy()
    end
    place()
    return
  end
  applyContent()
  pill.expand(wantH)
end

-- ---- いつ出すか ----

local function blockedNow()
  if blocked() then
    if M.pill and M.pill.isExpanded() then
      M.collapse()
    end
    return true
  end
  return false
end

local function stopWatching()
  if state.checkTimer then
    state.checkTimer:stop()
    state.checkTimer = nil
  end
end

function M.attach(pill)
  M.pill = pill
  WIDTH, MAX_H, TOP_H = pill.CARD_W, pill.MAX_H, pill.HEAD_H
  pill.onLayout = onLayout
  pill.onScroll = onScroll
  -- 動かし終えたら、場所に合わせて高さの上限が変わるので、組み直して合わせる。
  pill.onMoved = function()
    if content then
      applyContent()
      pill.expand(wantH)
    end
  end
end

-- 話し続けモードを始めた。前のモードの言葉は出さない。
function M.start()
  state.active = true
  state.own = {}
  if not state.checkTimer then
    -- 止める印・画面共有が始まったら、カードをピルへ戻す。
    state.checkTimer = hs.timer.doEvery(BLOCK_CHECK, function()
      if M.pill and M.pill.isExpanded() then
        blockedNow()
      end
    end)
  end
end

-- 話し続けモードを止めた。カードはピルと一緒に消える（koe.lua が linger 秒後にピルを消す）。
function M.stop()
  state.active = false
  stopWatching()
end

-- 言葉を送った：一覧のいちばん上に足して、カードを開く（話し続けモードの間だけ）。
function M.addOwn(said)
  if not state.active or not said or said == "" then
    return
  end
  table.insert(state.own, { text = said, at = hs.timer.secondsSinceEpoch() })
  while #state.own > OWN_KEEP do
    table.remove(state.own, 1)
  end
  if blockedNow() then
    log("blocked (pause file or screen sharing)")
    return
  end
  render()
end

-- ピルへ戻す（止める印・画面共有が始まったとき）。
function M.collapse()
  if M.pill then
    M.pill.collapse()
  end
end

-- 試し：モードと関係なく、言葉の配列（古い順。最後がいちばん新しい）でピルを広げる。ピルは先に出しておく。
function M.preview(own)
  state.own = {}
  for _, s in ipairs(own or {}) do
    table.insert(state.own, { text = s, at = 0 })
  end
  render()
end

function M.clear()
  stopWatching()
  state.active = false
  state.own = {}
  destroy()
end

return M
