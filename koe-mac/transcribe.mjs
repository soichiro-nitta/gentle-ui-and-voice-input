// 録った声を文字にする。transcribe-cpp（https://github.com/handy-computer/transcribe.cpp）と SenseVoiceSmall を使う。Macの中だけで動く。
// 使い方: node transcribe.mjs <16kHz・モノラル・float32 の raw ファイル>
// 文字を標準出力へ出す。1秒未満なら何も出さず終了コード 3、聞き取れなければ終了コード 4、声がなければ 5。
// 話し続けモードの耳（listen.mjs）は、ここの createTranscriber を読み込んでモデルを常駐させ、毎回の読み込みを省く。
// 場所は環境変数で変えられる：
//   KOE_ASR_MODEL         文字にするモデル（既定 ~/.local/share/koe-mac/models/SenseVoiceSmall-Q8_0.gguf）
//   KOE_VAD_MODEL         声の区間を見つけるモデル（既定 ~/.local/share/koe-mac/models/silero-vad-v6.2-F32.gguf）
//   KOE_TRANSCRIBE_MODULE transcribe-cpp の場所（既定はこのフォルダの node_modules の transcribe-cpp。npm install で入る）
//   KOE_LANGUAGE          言語（既定 ja）
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const MODELS = join(homedir(), ".local/share/koe-mac/models");
const ASR_MODEL = process.env.KOE_ASR_MODEL || join(MODELS, "SenseVoiceSmall-Q8_0.gguf");
const VAD_MODEL = process.env.KOE_VAD_MODEL || join(MODELS, "silero-vad-v6.2-F32.gguf");
const ENGINE = process.env.KOE_TRANSCRIBE_MODULE ? pathToFileURL(process.env.KOE_TRANSCRIBE_MODULE).href : "transcribe-cpp";
const SAMPLE_RATE = 16000;
const MIN_SECONDS = 1;
// 1回に文字にする長さは30秒までにする。長い録音は声の切れ目で分ける。
const MAX_PIECE_SECONDS = 25;
const LANGUAGE = process.env.KOE_LANGUAGE || "ja";
// 消す日本語の言いよどみ。
const FILLERS = /(?:え[ーえっ]*と|えー+|あのー+|うー+ん|んー+)[、,，…]?\s*/gu;

// モデルを読み込み、pcm（Float32Array）を文字にする関数を返す。
// 返す関数の結果は { code, text, detail }。code は CLI の終了コードと同じ（0・3・4・5）。
export async function createTranscriber() {
  const engine = await import(ENGINE);
  await engine.initialize();
  const model = await engine.TranscribeModel.load(ASR_MODEL);
  const session = model.createSession({ nThreads: 4 });
  const vadModel = await engine.TranscribeModel.load(VAD_MODEL, { backend: "cpu" });
  const vad = vadModel.createVadSession({ nThreads: 1 });

  // 声のある所だけを、25秒までのかたまりにまとめる。無音だけを文字にすると「こ。」のような文字が出るため。
  async function piecesOf(samples) {
    const { segments } = await vad.run(samples, { maxSpeechMs: MAX_PIECE_SECONDS * 1000 });
    const pieces = [];
    let start = null;
    let end = 0;
    for (const segment of segments) {
      if (start !== null && segment.endSample - start > MAX_PIECE_SECONDS * SAMPLE_RATE) {
        pieces.push(samples.subarray(start, end));
        start = null;
      }
      start ??= segment.startSample;
      end = segment.endSample;
    }
    if (start !== null) {
      pieces.push(samples.subarray(start, end));
    }
    return pieces;
  }

  return async function transcribe(pcm) {
    if (pcm.length < MIN_SECONDS * SAMPLE_RATE) {
      return { code: 3 };
    }
    const pieces = await piecesOf(pcm);
    // 声が1つも見つからなければ、無音として 5（呼び出し側がログとピルで知らせる）。
    if (pieces.length === 0) {
      return { code: 5 };
    }
    const texts = [];
    for (const piece of pieces) {
      const result = await session.run(piece, { timestamps: "none", language: LANGUAGE });
      texts.push(result.text.trim());
    }
    // かたまりの切れ目に句読点がなければ「、」を入れる。
    const text = texts
      .filter(Boolean)
      .map((piece, index, all) => (index < all.length - 1 && !/[。、！？.!?,]$/u.test(piece) ? `${piece}、` : piece))
      .join("").replace(FILLERS, "").trim();
    if (!text) {
      // 声はあったが文字にならなかった。何が出ていたかをログ用に残す。
      return { code: 4, detail: `pieces=${pieces.length} raw=${JSON.stringify(texts)}` };
    }
    // 合わさった形（NFC）にそろえて返す（送った文の記録のハッシュは、この形で取る）。
    return { code: 0, text: text.normalize("NFC") };
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const buffer = readFileSync(process.argv[2]);
  const pcm = new Float32Array(buffer.buffer, buffer.byteOffset, Math.floor(buffer.byteLength / 4));
  if (pcm.length < MIN_SECONDS * SAMPLE_RATE) {
    process.exit(3);
  }
  const transcribe = await createTranscriber();
  const { code, text, detail } = await transcribe(pcm);
  if (code === 0) {
    process.stdout.write(text);
  } else if (detail) {
    process.stderr.write(detail);
  }
  process.exit(code);
}
