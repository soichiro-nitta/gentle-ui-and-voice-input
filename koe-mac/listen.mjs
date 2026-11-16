// 話し続けモードの耳。マイクを録り続け、声のかたまりを無音で区切って、1つずつファイルにして知らせる。
// 使い方: node listen.mjs <書き出すフォルダ> [--input <16kHz・モノラル・int16 の raw>]（--input は試し用。マイクの代わりに読む。
//   KOE_INPUT_PACE=1 でマイクと同じ速さで流す）
// 標準出力へ1行1つの JSON を出す（Hammerspoon の koe.lua が読む）。
//   {"event":"ready"}                         録り始めた
//   {"event":"speech-start"}                  話し始めた
//   {"event":"cut","path":…}                  区切った（すぐ出す。ここから文字にし始める）
//   {"event":"segment","path":…,"seconds":…,"code":…,"text":…}
//                                             ひとまとまり（16kHz・モノラル・float32 の raw）と、文字にした結果（code・text は transcribe.mjs と同じ意味）。
//                                             モデルを読み込めなかったときは code なしで出す（呼び出し側が transcribe.mjs で文字にする）。ファイルを消すのは呼び出し側
//   {"event":"discard","reason":…}            捨てた。too-short：短すぎる音（咳・物音）。far：離れた声（隣の人・別のマイクへ向けた声）
//   {"event":"idle"}                          長く声がなかった（呼び出し側がやめる）。KOE_IDLE（秒）を入れたときだけ出す
// 文字にするモデルは、始めたときに1回だけ読み込んで常駐させる（毎回 node を起こして読み込むと0.2秒ほど余計にかかるため）。
// SIGINT・SIGTERM で、話している途中ならそこまでを出し、文字にし終えてから終わる。2回目の合図ではすぐ強制で終わる。録音は止めずに続けて区切るので、取りこぼしはない。
// 区切りは音の大きさで見る。環境音の大きさは、直近8秒の音の大きさの下から15%の値とし（話している間も測り続ける）、
// それより十分大きい所を声とする。最小値を追うと環境音を低く見すぎて、部屋の音を声と見なし区切れなくなるため。
import { spawn } from "node:child_process";
import { createReadStream, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTranscriber } from "./transcribe.mjs";

// 録音には SoX の rec を使う（brew install sox）。場所は KOE_REC で変えられる。
const REC = process.env.KOE_REC || "rec";
const RATE = 16000;
const FRAME = 480; // 30ms
const FRAME_SECONDS = FRAME / RATE;
// 何秒黙ったら区切るか。
const SILENCE_SECONDS = Number(process.env.KOE_SILENCE || 1.0);
// 1件の文字起こしがこれを過ぎたら、あきらめて次へ進む（列が止まらないように）。
const TRANSCRIBE_TIMEOUT_MS = 60000;
// かたまりの中の間（ま）を、これより長いものだけ記録する（区切りの秒数を決める材料。ログに出る）。
const PAUSE_LOG_SECONDS = 0.4;
// 声と数える量がこれ未満なら送らない（咳・物音）。
const MIN_VOICED_SECONDS = 0.4;
// 話し始めの前に足す長さ（出だしを切らない）・区切りのあとに残す長さ。
const PREROLL_SECONDS = 0.4;
const TAIL_SECONDS = 0.3;
// 1つのかたまりの上限。これを過ぎたら区切る。
const MAX_SEGMENT_SECONDS = 60;
// 黙っている時間で止めるか。既定は止めない（0）。止めたいときは KOE_IDLE に秒数を入れる（設定の idle）。
const IDLE_SECONDS = Number(process.env.KOE_IDLE || 0);
// 区切った音声ファイルの置き場で、これより古いものは消す（送り損ねたものがたまらないように）。
const SEGMENT_MAX_AGE_MS = 60 * 60 * 1000;
// 環境音より何 dB 大きければ声とするか（始まり・続き）。小さすぎる音は環境音が静かでも声としない。
// 始まりの線は上げすぎない。掃除機のような大きな音が続く中では、線を上げたぶん口元の声まで越えにくくなるため。
// 離れた声は、下の「越えた割合」で捨てる。KOE_ON_DB（設定の onDb）で試せる。
const ON_DB = Number(process.env.KOE_ON_DB || 15);
const OFF_DB = Number(process.env.KOE_OFF_DB || 9);
const ON_FLOOR_DB = -45;
const OFF_FLOOR_DB = -50;
// 環境音を測る長さと、下から何割の値を環境音とするか。
const NOISE_WINDOW_SECONDS = 8;
const NOISE_PERCENTILE = 0.15;
// 入力機器（KOE_DEVICE は Hammerspoon が今の入力機器の名前を入れる）。口元のマイク（ピンマイクなど）かどうかで、捨てる線を変える。
// 口元のマイクと見なす名前は KOE_CLOSE_MIC（正規表現。既定は無線のピンマイクによくある名前）。
const DEVICE = process.env.KOE_DEVICE || "";
const CLOSE_MIC = new RegExp(process.env.KOE_CLOSE_MIC || "Wireless Mic|Mic Mini|Lavalier", "i").test(DEVICE);
// 離れた声を捨てる。区切った1つの発言で、話し始めから最後の声までのうち、始まりの線（環境音＋ON_DB）を越えた割合（ratio）がこれ未満なら送らない。
// 口元の声は言葉の大半が線を越える（測った例で 0.7〜0.8）。離れた声は続きの線（OFF）と始まりの線の間をうろうろして、
// 区切られずに長く続き、越えるのは一部だけ（測った例で 0.04〜0.17）。小さめ・遠めの口元の声は 0.2〜0.35 になることがあるので、
// 口元のマイクは 0.18、ほかは控えめに 0.15 にしてある。環境に合わせて KOE_MIN_RATIO（設定の minRatio）で変える。
const MIN_VOICED_RATIO = Number(process.env.KOE_MIN_RATIO || (CLOSE_MIC ? 0.18 : 0.15));
// 捨てた発言の音声は、値を直す材料として少しだけ残す（~/.cache/koe-mac/far/。24時間で消す）。
const FAR_DIR = process.env.KOE_FAR_DIR || join(process.env.HOME || "/tmp", ".cache/koe-mac/far");
const FAR_MAX_AGE_MS = 24 * 60 * 60 * 1000;

const outDir = process.argv[2];
const inputIndex = process.argv.indexOf("--input");
const inputFile = inputIndex > 0 ? process.argv[inputIndex + 1] : null;
mkdirSync(outDir, { recursive: true, mode: 0o700 });

// 置き場の古い区切りファイルを消す。始めたときと、つけっぱなしの間は10分ごと。
function sweepDir(dir, maxAge) {
  const now = Date.now();
  let names = [];
  try {
    names = readdirSync(dir);
  } catch {
    return;
  }
  for (const name of names) {
    if (!/^(seg|far)-.*\.f32$/.test(name)) continue;
    const path = join(dir, name);
    try {
      if (now - statSync(path).mtimeMs > maxAge) unlinkSync(path);
    } catch {}
  }
}
function sweepOldSegments() {
  sweepDir(outDir, SEGMENT_MAX_AGE_MS);
  sweepDir(FAR_DIR, FAR_MAX_AGE_MS);
}
sweepOldSegments();
setInterval(sweepOldSegments, 10 * 60 * 1000).unref();

const say = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

let noise = -55; // 環境音の大きさ（dB）。声の線を引くのに使う（上限 -30 で切る）
let rawNoise = -55; // 上限で切らない環境音（掃除機など大きな音が続くときの本当の大きさ。記録用）
let segDb = []; // 今のかたまりの、話し始めてからの各フレームの大きさ（dB）
let startNoise = -55; // 話し始めたときの環境音（上限で切らない）
let levels = []; // 直近の音の大きさ（dB）
let started = false; // rec の出だしの無音（0）を飛ばした
let speaking = false;
let segment = []; // 今のかたまりのフレーム（Float32Array）
let preroll = [];
let recent = []; // 直近6フレームが声だったか（始まりの判定）
let tail = []; // 直近5フレームが続きの声の大きさだったか（区切りの判定）
let voicedFrames = 0;
let sinceVoice = 0; // 最後に声があってからのフレーム数
let idleFrames = 0;
let count = 0;
let idleSent = false;
let pauses = []; // 今のかたまりの中の間（秒）。区切らずに声が戻ったもの
let transcriberReady = createTranscriber().catch((error) => {
  process.stderr.write(`transcriber load failed: ${error?.message || error}\n`);
  return null;
});
let chain = Promise.resolve(); // 文字にする順番を守る

function levelDb(frame) {
  let sum = 0;
  for (const s of frame) sum += s * s;
  return 10 * Math.log10(sum / frame.length + 1e-12);
}

function emitSegment(reason) {
  // 後ろの無音を TAIL まで削る。
  const tailFrames = Math.round(TAIL_SECONDS / FRAME_SECONDS);
  const cut = Math.max(0, sinceVoice - tailFrames);
  const frames = segment.slice(0, segment.length - cut);
  const voiced = voicedFrames * FRAME_SECONDS;
  const segmentPauses = pauses;
  // 声の大きさを測る。core：話し始めから最後の声まで（後ろの無音は除く。始まりの判定の6フレームを足す）。
  const coreDb = segDb.slice(0, Math.max(0, segDb.length - sinceVoice));
  const coreFrames = coreDb.length + 6;
  const ratio = Math.min(1, voicedFrames / coreFrames);
  const sortedDb = [...coreDb].sort((a, b) => a - b);
  const pct = (q) => (sortedDb.length ? sortedDb[Math.min(sortedDb.length - 1, Math.floor(sortedDb.length * q))] : -100);
  // level：真ん中の大きさ、loud：上から1割の大きさ。どちらも話し始めたときの環境音（上限で切らない）からの差（dB）。
  const levels_ = {
    ratio: +ratio.toFixed(2),
    level: +(pct(0.5) - startNoise).toFixed(1),
    loud: +(pct(0.9) - startNoise).toFixed(1),
    peak: +pct(1).toFixed(1),
    noise: +noise.toFixed(1),
    rawNoise: +startNoise.toFixed(1),
    on: ON_DB,
    device: DEVICE,
  };
  segDb = [];
  pauses = [];
  speaking = false;
  segment = [];
  voicedFrames = 0;
  sinceVoice = 0;
  recent = [];
  tail = [];
  if (voiced < MIN_VOICED_SECONDS) {
    say({ event: "discard", reason: "too-short", voiced: +voiced.toFixed(2) });
    return;
  }
  if (ratio < MIN_VOICED_RATIO) {
    // 離れた声。送らずに捨てる。音声は値を直す材料として24時間だけ残す。
    let kept = null;
    try {
      mkdirSync(FAR_DIR, { recursive: true, mode: 0o700 });
      const far = new Float32Array(frames.length * FRAME);
      frames.forEach((f, i) => far.set(f, i * FRAME));
      kept = join(FAR_DIR, `far-${Date.now()}.f32`);
      writeFileSync(kept, Buffer.from(far.buffer), { mode: 0o600 });
    } catch {}
    say({ event: "discard", reason: "far", voiced: +voiced.toFixed(2), seconds: +((frames.length * FRAME) / RATE).toFixed(2), min: MIN_VOICED_RATIO, ...levels_, kept });
    return;
  }
  const pcm = new Float32Array(frames.length * FRAME);
  frames.forEach((f, i) => pcm.set(f, i * FRAME));
  count += 1;
  const path = join(outDir, `seg-${process.pid}-${count}.f32`);
  writeFileSync(path, Buffer.from(pcm.buffer), { mode: 0o600 });
  say({ event: "cut", path });
  const info = {
    event: "segment",
    path,
    seconds: +(pcm.length / RATE).toFixed(2),
    voiced: +voiced.toFixed(2),
    cut: reason,
    noise: +noise.toFixed(1),
    silence: SILENCE_SECONDS,
    pauses: segmentPauses.map((p) => +p.toFixed(2)),
    ...levels_,
  };
  chain = chain.then(() => transcribeSegment(pcm, info));
}

async function transcribeSegment(pcm, info) {
  const transcribe = await transcriberReady;
  if (!transcribe) {
    say(info);
    return;
  }
  const startedAt = performance.now();
  let timer;
  try {
    const result = await Promise.race([
      transcribe(pcm),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("timeout")), TRANSCRIBE_TIMEOUT_MS);
      }),
    ]);
    say({ ...info, ...result, ms: Math.round(performance.now() - startedAt) });
  } catch (error) {
    say({ ...info, code: 1, detail: String(error?.message || error) });
  } finally {
    clearTimeout(timer);
  }
}

function onFrame(frame) {
  const db = levelDb(frame);
  if (!started) {
    if (db < -100) return;
    started = true;
  }
  levels.push(db);
  if (levels.length > NOISE_WINDOW_SECONDS / FRAME_SECONDS) levels.shift();
  if (levels.length % 10 === 0 || levels.length < 20) {
    const sorted = [...levels].sort((a, b) => a - b);
    rawNoise = sorted[Math.floor(sorted.length * NOISE_PERCENTILE)];
    noise = Math.min(rawNoise, -30);
  }
  const on = Math.max(noise + ON_DB, ON_FLOOR_DB);
  const off = Math.max(noise + OFF_DB, OFF_FLOOR_DB);
  if (!speaking) {
    preroll.push(frame);
    const maxPre = Math.round(PREROLL_SECONDS / FRAME_SECONDS);
    if (preroll.length > maxPre) preroll.shift();
    recent.push(db >= on);
    if (recent.length > 6) recent.shift();
    if (recent.filter(Boolean).length >= 4) {
      speaking = true;
      segment = preroll;
      preroll = [];
      segDb = [];
      startNoise = rawNoise;
      voicedFrames = recent.filter(Boolean).length;
      sinceVoice = 0;
      idleFrames = 0;
      idleSent = false;
      say({ event: "speech-start", noise: +noise.toFixed(1), on: +on.toFixed(1) });
      return;
    }
    idleFrames += 1;
    if (IDLE_SECONDS > 0 && !idleSent && idleFrames * FRAME_SECONDS >= IDLE_SECONDS) {
      idleSent = true;
      say({ event: "idle" });
    }
    return;
  }
  segment.push(frame);
  segDb.push(db);
  if (db >= on) voicedFrames += 1;
  // 物音1つで続きと見なさないよう、直近5フレームのうち3つが続きの大きさなら声が続いているとする。
  tail.push(db >= off);
  if (tail.length > 5) tail.shift();
  if (tail.filter(Boolean).length >= 3) {
    if (sinceVoice * FRAME_SECONDS >= PAUSE_LOG_SECONDS) pauses.push(sinceVoice * FRAME_SECONDS);
    sinceVoice = 0;
  } else sinceVoice += 1;
  if (sinceVoice * FRAME_SECONDS >= SILENCE_SECONDS) emitSegment("silence");
  else if (segment.length * FRAME_SECONDS >= MAX_SEGMENT_SECONDS) emitSegment("max");
}

let carry = Buffer.alloc(0);
function onData(chunk) {
  let buf = carry.length ? Buffer.concat([carry, chunk]) : chunk;
  const bytes = FRAME * 2;
  let offset = 0;
  while (buf.length - offset >= bytes) {
    const frame = new Float32Array(FRAME);
    for (let i = 0; i < FRAME; i++) frame[i] = buf.readInt16LE(offset + i * 2) / 32768;
    onFrame(frame);
    offset += bytes;
  }
  carry = buf.subarray(offset);
}

// 文字にするモデルを読み込んでいる最中に process.exit すると、node が終わらずに固まる（始めた直後に止めたとき）。
// そこで、読み込みが終わるのを待ってから終わる。待ちすぎないよう上限を置き、出力を書き切ってから終わる。
const LOAD_WAIT_MS = 15000;
let finished = false;
async function finish() {
  if (finished) return;
  finished = true;
  if (speaking) emitSegment("stop");
  await chain;
  await Promise.race([transcriberReady, new Promise((resolve) => setTimeout(resolve, LOAD_WAIT_MS))]);
  process.stdout.write("", () => process.exit(0));
}
// 2回目の止める合図（呼び出し側が待ちきれずに送る）では、すぐに強制で終わる。
function stopNow() {
  if (finished) process.kill(process.pid, "SIGKILL");
}

if (inputFile) {
  const onEnd = () => {
    // 試しでは、終わりに無音が続いたとみなして区切る。
    const silent = new Float32Array(FRAME);
    for (let i = 0; i < Math.ceil(SILENCE_SECONDS / FRAME_SECONDS) + 1 && speaking; i++) onFrame(silent);
    finish();
  };
  let stopInputFeed = () => {};
  if (process.env.KOE_INPUT_PACE) {
    // マイクと同じ速さで流す（始めた直後に止める・連打するなどを確かめるため）。
    const data = readFileSync(inputFile);
    let offset = 0;
    const timer = setInterval(() => {
      if (offset >= data.length) {
        clearInterval(timer);
        onEnd();
        return;
      }
      onData(data.subarray(offset, offset + FRAME * 2));
      offset += FRAME * 2;
    }, FRAME_SECONDS * 1000);
    stopInputFeed = () => clearInterval(timer);
    say({ event: "ready" });
  } else {
    const stream = createReadStream(inputFile);
    stream.on("data", onData);
    stream.on("end", onEnd);
    stopInputFeed = () => stream.destroy();
  }
  // 試しでも止める合図を受ける（マイクなしで、止め方を確かめるため）。
  const stopInput = () => {
    stopNow();
    stopInputFeed();
    finish();
  };
  process.on("SIGINT", stopInput);
  process.on("SIGTERM", stopInput);
} else {
  const rec = spawn(REC, ["-q", "-c", "1", "-r", String(RATE), "-e", "signed-integer", "-b", "16", "-t", "raw", "-"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  rec.stdout.on("data", onData);
  rec.stderr.on("data", (d) => process.stderr.write(d));
  rec.on("exit", (code) => {
    if (!finished) {
      say({ event: "rec-ended", code });
      finish();
    }
  });
  const stop = () => {
    stopNow();
    rec.kill("SIGINT");
    finish();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  // 呼び出し側（Hammerspoon）が落ちたら一緒に終わる。
  process.stdin.on("end", stop);
  process.stdin.resume();
  say({ event: "ready" });
}
