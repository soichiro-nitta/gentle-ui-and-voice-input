# 使える部品の一覧

`reading.css` で形が決まっている要素とクラスです。
読み物は、この一覧にある部品だけで組み立てます。
ここにないクラスを作っても、見た目は付きません（`reading-style check` が「reading.css にないクラス」と出します）。

組み立ての手本は [`examples/today.html`](examples/today.html)（今日のまとめ）と [`examples/sample.html`](examples/sample.html)（ふつうの読み物）です。

## 土台

どの読み物も、この形から始めます。

```html
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>題</title>
<style>
/* reading.css の中身をそのまま入れる（reading-style apply でも入る） */
</style>
</head>
<body><main>
<h1>題</h1>
<p class="summary">結論を1文。</p>
<!-- ここから段 -->
</main></body>
</html>
```

- 本文は必ず `<main>` の中に書きます。見出しと段落の形は `main h1`・`main h2`・`main h3` に当てているので、外にあると効きません。
- `<style>` は reading.css の1つだけにします。その読み物だけに要る分は `<style data-page>` に分けます。

## 文章

| 部品 | 何に使う | 見た目 |
|---|---|---|
| `main h1` | ページの題 | 小さめ（15px）のグレー。目立たせない |
| `p.summary` | h1 のすぐ下の結論（総括）。1〜3文 | 本文より一段大きい（21px）、ふつうの太さ |
| `p.lead` | summary より強く言いたい一言（どちらか1つ） | 22px、medium |
| `main h2` | 段の見出し（「今日の予定」「ToDo」など） | 14px のグレー、字間を少しあける。上に 60px のゆとり |
| `main h3` | 段の中の小見出し（話題の名前） | 16px、濃いグレー |
| `p` | 1段落に1つのこと | 18px、行の高さ 1.8 |
| `p.note`・`.sub` | 補足・ページの最後の「何時点」 | 15px のグレー。`p.note` は上に大きなゆとり |
| `.meta` | 日付・出どころの小さな行 | 15px のグレー |

```html
<h2>今日の予定</h2>
<h3>お知らせページ</h3>
<p class="note">10:00時点の内容。</p>
```

## 文の中の印

| 部品 | 何に使う | 見た目 |
|---|---|---|
| `<a>` | リンク。文の中の言葉に付ける | 青、下線なし |
| `.key` | 要点・「決定」の印 | 青、少し太い |
| `.wait` | 期限・返事待ち・止まった・失敗 | オレンジ、少し太い。行の頭に置くと少し小さくなる |
| `.ok` | 緑の文字（済みの印には使わず `li.done` を使う） | 緑 |
| `.err` | どうしても赤で伝えたいエラー（ふだんは `.wait`） | 赤 |
| `.ng` | 表の不合格（赤の文字）。`td.n`・`th.n` は表の数字の列（右寄せ） | 赤 |
| `.time` | 時刻・日付 | 数字の幅がそろう、medium |
| `strong` | 文の中の強調 | 少し太い |
| `code` | コード・コマンド | 等幅、薄いグレーの面 |

```html
<li><span class="wait">3/5まで</span>見積もりの日を決めて返事をする</li>
<li class="done"><span class="key">決定</span>写真は角を丸くする（<a href="…">話題のページ</a>）</li>
```

## 並び

### 動きの並び（`ul.log`）

起きたこと・やったことを1行ずつ。行の左に小さなグレーの点が付きます。
済んだ行は `li.done` にすると、点が緑の丸（白いチェック入り）になります。「済み」の文字は書きません。

```html
<ul class="log">
<li class="done">ページの見出しを直した（9:24）</li>
<li>配送の会社から、集荷の時刻が変わるお知らせ</li>
<li><span class="wait">失敗</span>記録が届かず、作れなかった</li>
</ul>
```

### ToDo（`ul.todo`）

本人の手でやること・決めること。行の左に、中が空のうすい丸が付きます。
済んだら `li.done` にすると、丸が緑で塗られ、文字が少し薄くなります（取り消し線は付けません）。
「提案」の並びにも使います。

```html
<ul class="todo">
<li><span class="wait">3/7</span>呼び方を決める（<a href="…">たたき台</a>）</li>
<li class="done">決める：朝の一言をチャットへ出していいか</li>
</ul>
```

### 予定（`ul.plan`）

時刻（右寄せ）と内容の2列の表です。1行おきにごく薄い面が付き、角が丸くなります。罫線はありません。
スマホの幅では、時刻が上・内容が下の2段になります。

```html
<ul class="plan">
<li data-end="14:30"><span class="time">14:00</span><span>定例<span class="links"><a href="…">会議</a><a href="…">台本</a></span><br><span class="note">台本は30分前にできる</span></span></li>
<li><span class="time">19:00</span><span>公開作業</span></li>
</ul>
```

- 各 `<li>` の中は、必ず `<span class="time">` と `<span>`（内容）の2つにします。3つ以上にすると列がずれます。
- 会議のリンクは、内容の後ろに `<span class="links">` で小さく並べます。
- 補足は `<br><span class="note">…</span>` で1行まで。
- `li.past` は終わった予定（薄くなる）。手本の `<script>` が、終わりの時刻 `data-end` を過ぎた行に付けます。

### このあと（`p.later` ＋ `ul.plan.later`）

今日の予定の下に、明日〜今週の大事な予定を2〜4行。日付の列＋内容の、少し小さい表です。独立した段（h2）にはしません。

```html
<p class="later">このあと</p>
<ul class="plan later">
<li><span class="time">3/5（水）</span><span>14:00 定例</span></li>
</ul>
```

### 今週の予定（`dl.week`）

曜日ごとに並べたいときに使います。

```html
<dl class="week">
<dt>3/5（水）</dt><dd>14:00 定例</dd>
<dt>3/7（金）</dt><dd>お知らせページの公開</dd>
</dl>
```

## 表

表は、今日の予定（`ul.plan`）と同じ考え方の1つの形にそろえます。クラスを付けない素の `<table>` が既定です。

- 線は使いません。データの行の1行おきに薄い面（`--row`）が付き、面の角は丸くなります。
- 見出しの行（`th` だけの行）は、小さなグレーの文字です。
- 数字の列は `td.n`（見出しは `th.n`）で右寄せ。数字はどこでも等幅です。
- 合否は色の文字だけで書きます。`<span class="ok">`は緑（合格）、`<span class="ng">`は赤（不合格）、`<span class="wait">`はオレンジ（注意）。枠や背景、札で囲みません。
- 横に長い表は、狭い画面で表の中だけ横に動きます（ページは横に動きません）。

```html
<table>
<tr><th>背景</th><th>文字</th><th class="n">比</th><th>判定</th></tr>
<tr><td>白</td><td>#333333</td><td class="n">12.63</td><td><span class="ok">AA</span></td></tr>
<tr><td>白</td><td>#999999</td><td class="n">2.85</td><td><span class="ng">×</span></td></tr>
</table>
```

`table.lines`（下線の表）は古い書き方です。`reading-style apply` が外します。表の中に `style=`、自前の線（`border`）、上のほかのクラスを使うと、check が「直してほしい」と出します。

## 画像

| 部品 | 何に使う |
|---|---|
| `figure` ＋ `figcaption` | 画像1枚と、その下の小さな説明 |
| `div.pair` | Before／After を同じ大きさで横に2枚。狭い幅では縦に |
| `main.wide` | 画像を広く見せたいページ。文章の幅は 640px のまま、画像だけ 960px まで |
| `div.scroll` | 横に長い画像を、そのままの大きさで横に動かして見せる |

```html
<div class="pair">
<figure><img src="before.png" alt="直す前"><figcaption>直す前</figcaption></figure>
<figure><img src="after.png" alt="直した後"><figcaption>直した後</figcaption></figure>
</div>
```

## そのほか

| 部品 | 何に使う |
|---|---|
| `<details><summary>` | 詳しい根拠など。最初は閉じておく。「＋」が付く |
| `pre` | 文面の案（薄いグレーの面、ふつうの文字） |
| `blockquote` | 引用（枠なし、グレーの文字） |
| `.legend` ＋ `span.c-blue`・`c-wait`・`c-done`・`c-err` | グラフの凡例 |
| `.check` | 文の中に置く、緑の丸のチェック |

## 使わないもの

- 要素に直接 `style=` を書くこと（`<img>`・`<video>` も）。足りない形は reading.css へ足します。
- カード・色付きの枠・ボタンを並べたアプリ風の形。
- `<br>` を3つ以上つなげること。「どこ：」のようなラベル＋改行で1段落に詰めること。
- 入れ子の箇条書き。
- ほかの CSS（`<link rel="stylesheet">`、Tailwind、マークダウンの見た目など）。reading.css の形を上書きします。

## 効かないときに見るところ

reading.css を入れたのに、見出しが大きな黒の太字のまま・角丸が出ない・余白が詰まっている、というときは、上から順に見ます。
まず `reading-style check <ファイル>` をかけると、多くはそこに出ます。

1. **本文が `<main>` の中にあるか。** 見出し（h1・h2・h3）の形は `main h1` などに当てています。`<main>` がない・閉じる位置がずれていると、ブラウザーの標準の大きな黒い見出しになります。`reading-style apply` が包みます。
2. **クラスの名前が一覧のとおりか。** 予定を `<table>` や `ul.schedule` で書くと、角丸の行も1行おきの面も出ません。予定は `ul.plan`、ToDo は `ul.todo`、動きは `ul.log` です。check が「reading.css にないクラス」と出します。
3. **予定の行の中が2つか。** `ul.plan li` の中は `span.time` と `span`（内容）の2つだけ。`<div>` や3つ目の `<span>` を足すと、時刻と内容の列がずれます。
4. **reading.css が最新か。** 古い写しや、手で書きかえた reading.css だと、新しい部品（`later`・`links`・`dl.week` など）が効きません。check が「reading.css が古い」と出します。`check --fix` か `apply` で入れ直します。
5. **ほかの CSS がぶつかっていないか。** `<style>` が2つ以上ある、`<link rel="stylesheet">` で別の CSS を読んでいる、マークダウンの表示アプリの見た目が乗っている、などで上書きされます。その読み物だけの分は `<style data-page>` にします。
6. **HTML として開いているか。** マークダウンのプレビューや、HTML の中身を文字で見せるアプリでは、reading.css は効きません。ブラウザーで `.html` を開きます。
7. **ブラウザーが新しいか。** 済みのチェックの一部に `:has()` を使っています。古い Safari（15.4 より前）では、古い書き方（`<span class="ok">済み</span>`）の行だけ印が出ません。`li.done` の書き方なら出ます。
8. **文字の形。** Mac は「ヒラギノ角ゴ」、Windows・Linux は「Noto Sans JP」が入っていればそれを使います。どちらもないと、文字の形と幅が変わります。
