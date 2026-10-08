import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class VoiceStatus {
  listening: boolean = false;
  busy: boolean = false;
  speaking: boolean = false;
  message: string = '点击麦克风，说“下一首”或“播放晨光序曲”';
  transcript: string = '';
}

type StatusObserver = (status: VoiceStatus) => void;
type RecognitionObserver = (text: string) => void;

/** Actual microphone PCM → local Core Speech engine, never simulated text input. */
export class VoiceService {
  private readonly onStatus: StatusObserver;
  private readonly onRecognized: RecognitionObserver;
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private capturerStart: Promise<void> | undefined = undefined;
  private state: VoiceStatus = new VoiceStatus();
  private disposed: boolean = false;
  private generation: number = 0;
  private sessionId: string = '';
  private timer: number = -1;
  private remainder: Uint8Array = new Uint8Array(0);
  private finishing: boolean = false;
  private delivered: boolean = false;
  private capturingStarted: boolean = false;
  private speechEngine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private speechToken: number = 0;
  private speechTimer: number = -1;

  constructor(onStatus: StatusObserver, onRecognized: RecognitionObserver) {
    this.onStatus = onStatus;
    this.onRecognized = onRecognized;
    this.publish();
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.disposed || this.state.busy || this.state.listening) return;
    this.stopSpeech();
    const ticket = ++this.generation;
    this.finishing = false;
    this.delivered = false;
    this.capturingStarted = false;
    this.remainder = new Uint8Array(0);
    this.state.busy = true;
    this.state.transcript = '';
    this.state.message = '正在检查麦克风权限';
    this.publish();
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,
        ['ohos.permission.MICROPHONE']);
      if (!this.valid(ticket)) return;
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        this.state.busy = false;
        this.state.message = '未获得麦克风权限。请在系统设置中允许麦克风后重试';
        this.publish();
        return;
      }
      this.state.message = '正在启动本机语音识别';
      this.publish();
      this.timer = setTimeout(() => {
        void this.fail(ticket, '语音引擎初始化超时，请在支持语音识别的真机上重试');
      }, 10000);
      const engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1,
        extraParams: { 'locate': 'CN' } });
      if (!this.valid(ticket)) { engine.shutdown(); return; }
      this.clearTimer();
      this.engine = engine;
      this.sessionId = `music-${Date.now()}-${ticket}`;
      engine.setListener({
        onStart: (sessionId: string, eventMessage: string): void => {
          if (!this.matches(ticket, sessionId) || this.finishing || this.capturingStarted) return;
          this.capturingStarted = true;
          this.clearTimer();
          void this.startCapture(ticket, sessionId);
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
          if (!this.matches(ticket, sessionId)) return;
          if (eventCode === 3 && !this.finishing) void this.stop();
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (!this.matches(ticket, sessionId)) return;
          this.state.transcript = result.result.trim();
          this.publish();
          if (result.isLast) void this.complete(ticket);
        },
        onComplete: (sessionId: string, eventMessage: string): void => {
          if (this.matches(ticket, sessionId)) void this.complete(ticket);
        },
        onError: (sessionId: string, code: number, errorMessage: string): void => {
          if (!this.valid(ticket) || this.engine === undefined ||
            (sessionId.length > 0 && sessionId !== this.sessionId)) return;
          void this.fail(ticket, `语音识别失败（${code}），请检查本机语音服务后重试`);
        }
      });
      this.timer = setTimeout(() => {
        void this.fail(ticket, '语音服务启动超时，请在支持语音识别的真机上重试');
      }, 10000);
      engine.startListening({
        sessionId: this.sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
        extraParams: { 'endpointDetect': true, 'maxAudioDuration': 15000 }
      });
    } catch (error) {
      const business = error as BusinessError;
      await this.fail(ticket, `本机离线语音识别不可用（${business.code || '未知错误'}），请使用搜索框`);
    }
  }

  /** End recording, send the padded tail frame, and await the actual final result. */
  async stop(): Promise<void> {
    if (this.disposed || this.finishing || this.sessionId.length === 0) return;
    const ticket = this.generation;
    this.finishing = true;
    this.clearTimer();
    this.state.listening = false;
    this.state.busy = true;
    this.state.message = '正在识别，请稍候';
    this.publish();
    await this.releaseCapturer();
    if (!this.valid(ticket) || this.engine === undefined || this.sessionId.length === 0) return;
    try {
      if (this.remainder.length > 0) {
        const frame = new Uint8Array(this.remainder.length <= 640 ? 640 : 1280);
        frame.set(this.remainder);
        this.engine.writeAudio(this.sessionId, frame);
        this.remainder = new Uint8Array(0);
      }
      this.timer = setTimeout(() => {
        void this.fail(ticket, '没有收到识别结果，请靠近麦克风再试一次');
      }, 8000);
      this.engine.finish(this.sessionId);
    } catch (error) {
      await this.fail(ticket, `语音处理失败（${(error as BusinessError).code || '未知错误'}），请重试`);
    }
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    this.stopSpeech();
    this.generation++;
    this.clearTimer();
    const id = this.sessionId;
    this.sessionId = '';
    const engine = this.engine;
    this.engine = undefined;
    if (engine !== undefined) {
      if (id.length > 0) {
        try { engine.cancel(id); } catch (_) { /* The engine may have completed. */ }
      }
      try { engine.shutdown(); } catch (_) { /* Already released. */ }
    }
    await this.releaseCapturer();
    this.remainder = new Uint8Array(0);
  }

  /** Synthesize one short phrase on-device; recording always has priority. */
  async speak(text: string): Promise<void> {
    if (this.disposed) return;
    if (this.state.busy || this.state.listening) {
      this.state.message = '请先结束语音识别，再播报歌曲信息';
      this.publish();
      return;
    }
    const phrase = text.trim().slice(0, 160);
    if (phrase.length === 0) return;
    this.stopSpeech();
    const token = this.speechToken;
    const requestId = `music-speech-${Date.now()}-${token}`;
    this.state.speaking = true;
    this.state.message = '正在准备语音播报';
    this.publish();
    this.speechTimer = setTimeout(() => {
      if (this.disposed || token !== this.speechToken) return;
      this.stopSpeech();
      this.state.message = '语音播报超时，请检查本机语音合成服务';
      this.publish();
    }, 45000);
    try {
      const engine = await textToSpeech.createEngine({ language: 'zh-CN', person: 0, online: 1,
        extraParams: { 'locate': 'CN', 'style': 'interaction-broadcast' } });
      if (this.disposed || token !== this.speechToken) { engine.shutdown(); return; }
      this.speechEngine = engine;
      engine.setListener({
        onStart: (id: string, response: textToSpeech.StartResponse): void => {
          if (!this.speechMatches(engine, id, requestId)) return;
          this.state.message = '正在播报歌曲信息';
          this.publish();
        },
        onComplete: (id: string, response: textToSpeech.CompleteResponse): void => {
          if (!this.speechMatches(engine, id, requestId) || response.type !== 1) return;
          this.stopSpeech();
          this.state.message = '歌曲信息播报完成';
          this.publish();
        },
        onStop: (id: string, response: textToSpeech.StopResponse): void => {
          if (!this.speechMatches(engine, id, requestId)) return;
          this.stopSpeech();
          this.state.message = '语音播报已停止';
          this.publish();
        },
        onError: (id: string, code: number, message: string): void => {
          if (!this.speechMatches(engine, id, requestId)) return;
          this.stopSpeech();
          this.state.message = `语音合成失败（${code}），请检查本机语音服务`;
          this.publish();
        }
      });
      engine.speak(phrase, { requestId, extraParams: { 'queueMode': 0, 'speed': 1, 'volume': 1, 'pitch': 1 } });
    } catch (error) {
      if (this.disposed || token !== this.speechToken) return;
      this.stopSpeech();
      this.state.message = `本机语音合成不可用（${(error as BusinessError).code || '未知错误'}）`;
      this.publish();
    }
  }

  private speechMatches(engine: textToSpeech.TextToSpeechEngine, id: string, expected: string): boolean {
    return !this.disposed && this.speechEngine === engine && id === expected;
  }

  private stopSpeech(): void {
    this.speechToken++;
    if (this.speechTimer >= 0) clearTimeout(this.speechTimer);
    this.speechTimer = -1;
    this.state.speaking = false;
    const engine = this.speechEngine;
    this.speechEngine = undefined;
    if (engine === undefined) return;
    try { engine.stop(); } catch (_) { /* Already completed. */ }
    try { engine.shutdown(); } catch (_) { /* Already released. */ }
  }

  private async startCapture(ticket: number, sessionId: string): Promise<void> {
    let capture: audio.AudioCapturer | undefined = undefined;
    let ownershipTransferred: boolean = false;
    try {
      this.timer = setTimeout(() => {
        void this.fail(ticket, '麦克风启动超时，请检查麦克风是否被占用');
      }, 8000);
      capture = await audio.createAudioCapturer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 }
      });
      if (!this.matches(ticket, sessionId) || this.finishing) { await capture.release(); return; }
      this.capturer = capture;
      ownershipTransferred = true;
      capture.on('readData', (buffer: ArrayBuffer): void => {
        if (!this.matches(ticket, sessionId) || this.finishing || this.engine === undefined) return;
        try { this.writeFrames(sessionId, buffer); } catch (error) {
          void this.fail(ticket, `麦克风数据处理失败（${(error as BusinessError).code || '未知错误'}）`);
        }
      });
      capture.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if (!this.matches(ticket, sessionId)) return;
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP ||
          event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
          void this.fail(ticket, '麦克风被其他应用占用，请稍后重试');
        }
      });
      const starting = capture.start();
      this.capturerStart = starting;
      await starting;
      if (this.capturerStart === starting) this.capturerStart = undefined;
      if (!this.matches(ticket, sessionId) || this.finishing) return;
      this.clearTimer();
      this.state.busy = false;
      this.state.listening = true;
      this.state.message = '正在聆听，说完后点击麦克风结束（最长 15 秒）';
      this.publish();
      this.timer = setTimeout(() => { void this.stop(); }, 15000);
    } catch (error) {
      if (capture !== undefined && !ownershipTransferred) {
        try { await capture.release(); } catch (_) { /* Already released. */ }
      }
      await this.fail(ticket, `无法启动麦克风（${(error as BusinessError).code || '未知错误'}），请检查权限或占用情况`);
    }
  }

  private writeFrames(sessionId: string, buffer: ArrayBuffer): void {
    const engine = this.engine;
    if (engine === undefined) return;
    const incoming = new Uint8Array(buffer);
    const all = new Uint8Array(this.remainder.length + incoming.length);
    all.set(this.remainder);
    all.set(incoming, this.remainder.length);
    let cursor = 0;
    // API 24 accepts exactly 640 or 1280 bytes, not arbitrary capturer buffers.
    while (cursor + 1280 <= all.length) {
      engine.writeAudio(sessionId, all.slice(cursor, cursor + 1280));
      cursor += 1280;
    }
    this.remainder = all.slice(cursor);
  }

  private async complete(ticket: number): Promise<void> {
    if (!this.valid(ticket) || this.delivered) return;
    this.delivered = true;
    const text = this.state.transcript.trim();
    await this.endSession();
    if (!this.valid(ticket)) return;
    this.state.busy = false;
    this.state.listening = false;
    this.state.message = text.length > 0 ? `已识别：${text}` : '没有听清，请再试一次';
    this.publish();
    if (text.length > 0) this.onRecognized(text);
  }

  private async fail(ticket: number, message: string): Promise<void> {
    if (!this.valid(ticket)) return;
    // Invalidate callbacks immediately; shutdown can synchronously invoke onError.
    this.generation++;
    await this.endSession();
    if (this.disposed) return;
    this.state.busy = false;
    this.state.listening = false;
    this.state.message = message;
    this.publish();
  }

  private async endSession(): Promise<void> {
    this.clearTimer();
    const engine = this.engine;
    this.engine = undefined;
    const id = this.sessionId;
    this.sessionId = '';
    if (engine !== undefined) {
      if (id.length > 0) {
        try { engine.cancel(id); } catch (_) { /* Recognition may already be finished. */ }
      }
      try { engine.shutdown(); } catch (_) { /* Reclaimed by platform. */ }
    }
    await this.releaseCapturer();
    this.remainder = new Uint8Array(0);
  }

  private async releaseCapturer(): Promise<void> {
    const capture = this.capturer;
    this.capturer = undefined;
    if (capture === undefined) return;
    const starting = this.capturerStart;
    this.capturerStart = undefined;
    // Ability destruction may arrive while native start() is pending. Finish
    // that transition before stop/release, so a late start cannot revive recording.
    if (starting !== undefined) {
      try { await starting; } catch (_) { /* A failed start still owns a capturer. */ }
    }
    try { capture.off('readData'); } catch (_) { /* Listener was not attached. */ }
    try { capture.off('audioInterrupt'); } catch (_) { /* Listener was not attached. */ }
    if (capture.state === audio.AudioState.STATE_RUNNING) {
      try { await capture.stop(); } catch (_) { /* Focus loss can stop it first. */ }
    }
    try { await capture.release(); } catch (_) { /* Already released. */ }
  }

  private clearTimer(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }

  private valid(ticket: number): boolean { return !this.disposed && ticket === this.generation; }

  private matches(ticket: number, sessionId: string): boolean {
    return this.valid(ticket) && this.sessionId.length > 0 && sessionId === this.sessionId;
  }

  private publish(): void {
    if (this.disposed) return;
    const value = new VoiceStatus();
    value.listening = this.state.listening;
    value.busy = this.state.busy;
    value.speaking = this.state.speaking;
    value.message = this.state.message;
    value.transcript = this.state.transcript;
    this.onStatus(value);
  }
}
