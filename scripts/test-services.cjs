/* Executes the real .ets service source against strict native API doubles.
 * This verifies async ownership/ordering; it does not replace device audio tests. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.CODEX_TYPESCRIPT || 'D:/HUAWEI/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const modules = new Map();
const nativePlayers = [];
const captures = [];
const engines = [];
const speakers = [];
let gatePrepare;
let gateCaptureStart;
let bgFailure = false;
let permissionGranted = true;
let engineFailure = false;
let speechFailure = false;
let backgroundRunning = false;
let rawOpen = 0;
let rawClose = 0;
let session;
const ticks = async () => { for (let i = 0; i < 12; i++) await new Promise(setImmediate); };
class Events {
  callbacks = new Map();
  on(name, callback) { if (!this.callbacks.has(name)) this.callbacks.set(name, new Set()); this.callbacks.get(name).add(callback); }
  off(name, callback) { if (callback) this.callbacks.get(name)?.delete(callback); else this.callbacks.delete(name); }
  emit(name, ...args) { for (const fn of [...(this.callbacks.get(name) || [])]) fn(...args); }
}
class AVPlayer extends Events {
  state = 'idle'; duration = 30000; volume = 1; released = 0; plays = 0; position = 0;
  constructor() { super(); nativePlayers.push(this); }
  // Native AVPlayer stores one callback per event; temporary listeners replace
  // permanent listeners, and off(event) removes that single native registration.
  on(name, callback) { this.callbacks.set(name, new Set([callback])); }
  off(name) { this.callbacks.delete(name); }
  change(state) { this.state = state; this.emit('stateChange', state, 0); }
  set audioRendererInfo(value) { assert.equal(this.state, 'initialized', 'renderer info requires initialized state'); }
  set audioInterruptMode(value) { assert(['prepared', 'playing', 'paused', 'completed'].includes(this.state), 'interrupt mode requires prepared or playback state'); }
  set fdSrc(source) { assert.equal(this.state, 'idle'); assert(source.fd > 0); queueMicrotask(() => this.change('initialized')); }
  async prepare() { assert.equal(this.state, 'initialized'); if (gatePrepare) { const gate = gatePrepare; gatePrepare = undefined; await gate; } this.change('prepared'); }
  async play() { assert(['prepared', 'paused', 'completed'].includes(this.state)); this.plays++; this.change('playing'); }
  async pause() { assert.equal(this.state, 'playing'); this.change('paused'); }
  seek(position) { assert(['prepared', 'playing', 'paused', 'completed'].includes(this.state)); this.position = position; }
  setVolume(value) { assert(['prepared', 'playing', 'paused', 'completed'].includes(this.state)); this.volume = value; }
  async release() { assert.equal(this.released, 0); this.released++; this.change('released'); }
}
class Session extends Events {
  async activate() {} async deactivate() {} async destroy() { this.destroyed = true; }
  async setLaunchAbility() {} async setAVMetadata(metadata) { this.metadata = metadata; }
  async setAVPlaybackState(state) {
    // Mirrors AVPlaybackState::IsValid and the native integer field contracts.
    assert(Number.isFinite(state.speed) && state.speed > 0, 'AVSession rejects speed=0 even when paused');
    assert(Number.isInteger(state.position.elapsedTime) && state.position.elapsedTime >= 0);
    assert(Number.isInteger(state.position.updateTime) && state.position.updateTime >= 0);
    assert(Number.isInteger(state.duration) && state.duration >= 0);
    assert(Number.isInteger(state.volume) && state.volume >= 0);
    assert(Number.isInteger(state.maxVolume) && state.maxVolume >= state.volume);
    this.playback = state;
  }
}
class Capturer extends Events {
  state = 1; released = 0;
  constructor() { super(); captures.push(this); }
  async start() { if (gateCaptureStart) { const gate = gateCaptureStart; gateCaptureStart = undefined; await gate; } this.state = 2; }
  async stop() { this.state = 3; }
  async release() { this.released++; this.state = 4; }
}
class Engine {
  frames = []; released = 0;
  constructor() { engines.push(this); }
  setListener(listener) { this.listener = listener; }
  startListening(params) { this.id = params.sessionId; assert.equal(params.audioInfo.sampleRate, 16000); this.listener.onStart(this.id, ''); }
  writeAudio(id, frame) { assert.equal(id, this.id); assert([640, 1280].includes(frame.length)); this.frames.push(frame); }
  finish(id) { this.listener.onResult(id, { isFinal: true, isLast: true, result: '下一首' }); this.listener.onComplete(id, ''); }
  cancel() {} shutdown() { this.released++; }
}
class Speaker {
  released = 0;
  constructor() { speakers.push(this); }
  setListener(listener) { this.listener = listener; }
  speak(text, options) { this.text = text; this.id = options.requestId; this.listener.onStart(this.id, {}); }
  stop() {} shutdown() { this.released++; }
}
const audio = {
  InterruptMode: { INDEPENDENT_MODE: 1 }, StreamUsage: { STREAM_USAGE_MUSIC: 1 },
  InterruptHint: { INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3, INTERRUPT_HINT_DUCK: 4, INTERRUPT_HINT_UNDUCK: 5 },
  InterruptForceType: { INTERRUPT_FORCE: 0, INTERRUPT_SHARE: 1 },
  AudioState: { STATE_RUNNING: 2 }, AudioSamplingRate: { SAMPLE_RATE_16000: 16000 },
  AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
  AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, SourceType: { SOURCE_TYPE_VOICE_RECOGNITION: 1 },
  createAudioCapturer: async () => new Capturer()
};
const kits = {
  '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => ({}), OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } },
    abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: async () => ({ authResults: [permissionGranted ? 0 : -1] }) }) } },
  '@kit.MediaKit': { media: { createAVPlayer: async () => new AVPlayer(), SeekMode: { SEEK_CLOSEST: 3 } } },
  '@kit.AudioKit': { audio },
  '@kit.AVSessionKit': { avSession: { createAVSession: async () => { session = new Session(); return session; },
    LoopMode: { LOOP_MODE_SEQUENCE: 0, LOOP_MODE_SINGLE: 1, LOOP_MODE_SHUFFLE: 3 },
    PlaybackState: { PLAYBACK_STATE_BUFFERING: 11, PLAYBACK_STATE_PLAY: 2, PLAYBACK_STATE_PAUSE: 3, PLAYBACK_STATE_COMPLETED: 7 } } },
  '@kit.BackgroundTasksKit': { backgroundTaskManager: { BackgroundMode: { AUDIO_PLAYBACK: 2 },
    startBackgroundRunning: async () => { if (bgFailure) throw { code: 9800002 }; backgroundRunning = true; },
    stopBackgroundRunning: async () => { backgroundRunning = false; } } },
  '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 0 }, open: async () => ({ fd: 777 }), stat: async () => ({ size: 960000 }), close: async () => {} } },
  '@kit.CoreSpeechKit': { speechRecognizer: { createEngine: async () => { if (engineFailure) throw { code: 1002200001 }; return new Engine(); } },
    textToSpeech: { createEngine: async () => { if (speechFailure) throw { code: 1002400001 }; return new Speaker(); } } },
  '@kit.BasicServicesKit': {}
};
function load(relative) {
  const filename = path.join(root, 'entry/src/main/ets', relative + '.ets');
  if (modules.has(filename)) return modules.get(filename);
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const exports = {};
  modules.set(filename, exports);
  vm.runInNewContext(result.outputText, { exports, require: name => {
    if (kits[name]) return kits[name];
    return load(path.relative(path.join(root, 'entry/src/main/ets'), path.resolve(path.dirname(filename), name)));
  }, setTimeout, clearTimeout, console, Uint8Array, ArrayBuffer, Date, Promise, Math }, { filename });
  return exports;
}
const context = { abilityInfo: { bundleName: 'test', name: 'EntryAbility' }, resourceManager: {
  getRawFd: async () => ({ fd: ++rawOpen, offset: 10, length: 960000 }), closeRawFd: async () => { rawClose++; }
} };
(async () => {
  const { PlayerService } = load('services/PlayerService');
  const { VoiceService } = load('services/VoiceService');
  const { DEMO_SONGS, PlayMode } = load('model/MusicModels');
  const player = new PlayerService();
  await player.init(context);
  await player.setQueue(DEMO_SONGS, 0);
  assert.equal(player.snapshot().playing, true); assert.equal(backgroundRunning, true);
  assert.equal(nativePlayers.at(-1).callbacks.get('stateChange').size, 1, 'one permanent state callback survives initialization');
  assert.equal(session.metadata.assetId, DEMO_SONGS[0].id);
  await player.seek(9876); assert.equal(nativePlayers.at(-1).position, 9876);
  const edited = player.snapshot().song;
  edited.lyrics = '[00:00]新的歌词';
  assert.notEqual(player.snapshot().song.lyrics, edited.lyrics, 'snapshots do not leak mutable model ownership');
  const beforeUpdate = nativePlayers.at(-1);
  player.updateSong(edited);
  assert.equal(player.snapshot().song.lyrics, edited.lyrics);
  assert.equal(player.snapshot().position, 9876); assert.equal(nativePlayers.at(-1), beforeUpdate, 'lyric update preserves playback');
  await player.setVolume(3); assert.equal(player.snapshot().volume, 1);
  await player.pause(); assert.equal(backgroundRunning, false); assert.equal(player.snapshot().playing, false);
  assert.equal(session.playback.state, 3); assert.equal(session.playback.speed, 1);
  await player.seek(5432.8);
  assert.equal(player.snapshot().position, 5433); assert.equal(session.playback.position.elapsedTime, 5433);
  assert.doesNotMatch(player.snapshot().background, /状态更新失败/, 'pause plus fractional slider seek remains valid');
  await player.play(); assert.equal(player.snapshot().playing, true);
  session.emit('pause'); await ticks(); assert.equal(player.snapshot().playing, false);
  session.emit('play'); await ticks(); assert.equal(player.snapshot().playing, true);
  await Promise.all([player.next(), player.next(), player.previous()]);
  assert.equal(player.snapshot().index, 1, 'rapid navigation keeps the latest request');
  assert.equal(nativePlayers.filter(p => !p.released).length, 1, 'only one native player survives');
  const old = nativePlayers.at(-1);
  let releasePrepare;
  gatePrepare = new Promise(resolve => { releasePrepare = resolve; });
  const loading = player.next();
  await ticks();
  const preparing = nativePlayers.at(-1);
  const paused = player.pause();
  releasePrepare(); await Promise.all([loading, paused]);
  assert.equal(preparing.plays, 0, 'pause while loading prevents prepare-then-autoplay');
  assert.equal(player.snapshot().playing, false);
  old.emit('timeUpdate', 22222); assert.equal(player.snapshot().position, 0, 'late old-track callbacks ignored');
  await player.play();
  player.setMode(PlayMode.RepeatOne);
  const repeatIndex = player.snapshot().index;
  nativePlayers.at(-1).change('completed'); await ticks();
  assert.equal(player.snapshot().index, repeatIndex, 'automatic completion repeats one');
  await player.next(); assert.notEqual(player.snapshot().index, repeatIndex, 'manual next still changes track');
  nativePlayers.at(-1).emit('audioInterrupt', { hintType: 2, forceType: 0 }); await ticks();
  assert.equal(player.snapshot().playing, false); assert.match(player.snapshot().error, /中断/);
  bgFailure = true; await player.play(); assert.match(player.snapshot().background, /后台播放不可用/);
  assert.equal(player.snapshot().playing, true, 'background denial still permits foreground audio');
  bgFailure = false;
  nativePlayers.at(-1).emit('error', { code: 5400103 }); await ticks();
  assert.equal(player.snapshot().playing, false); assert.match(player.snapshot().error, /5400103/);
  await player.play(); assert.equal(player.snapshot().playing, true, 'retry recreates failed native player');
  player.setMode(PlayMode.Sequence);
  await player.setQueue(DEMO_SONGS, DEMO_SONGS.length - 1);
  const lastTrack = nativePlayers.at(-1);
  lastTrack.change('completed'); await ticks();
  assert.equal(player.snapshot().playing, false); assert.equal(player.snapshot().position, 30000);
  assert.equal(player.snapshot().index, DEMO_SONGS.length - 1); assert.equal(backgroundRunning, false);
  assert.equal(nativePlayers.at(-1), lastTrack, 'sequential completion stops without wrapping or clearing position');
  assert.equal(session.playback.state, 7);
  await player.dispose(); assert.equal(backgroundRunning, false);
  assert.equal(nativePlayers.filter(p => !p.released).length, 0);
  assert.equal(rawOpen, rawClose, 'every raw descriptor is closed exactly once');
  console.log('PASS player: native property state constraints, single native callback, controls, immutable snapshots, live lyric update, AVSession positive speed/integer fields, paused fractional seek, rapid switch, pause during load, stale events, repeat mode, sequential completion, focus interruption, background failure, native failure retry, release');

  let status; const recognized = [];
  const voice = new VoiceService(value => { status = value; }, text => recognized.push(text));
  await voice.speak('正在播放晨光序曲');
  assert.equal(status.speaking, true); assert.equal(speakers.at(-1).text, '正在播放晨光序曲');
  const speaker = speakers.at(-1);
  speaker.listener.onComplete(speaker.id, { type: 0 }); assert.equal(status.speaking, true, 'synthesis completion is not playback completion');
  speaker.listener.onComplete(speaker.id, { type: 1 }); assert.equal(status.speaking, false); assert.equal(speaker.released, 1);
  speechFailure = true; await voice.speak('歌曲信息'); assert.match(status.message, /语音合成不可用/);
  speechFailure = false;
  await voice.speak('录音前会中止这段播报');
  permissionGranted = false; await voice.start(context);
  assert.match(status.message, /未获得麦克风权限/); assert.equal(captures.length, 0);
  assert.equal(speakers.at(-1).released, 1, 'recording request cancels speaker before requesting permission');
  permissionGranted = true;
  engineFailure = true; await voice.start(context); assert.match(status.message, /不可用/); assert.equal(status.busy, false);
  engineFailure = false;
  await voice.start(context); await ticks(); assert.equal(status.listening, true);
  await voice.speak('不能在录音时播报'); assert.match(status.message, /先结束语音识别/);
  const capture = captures.at(-1); const engine = engines.at(-1);
  capture.emit('readData', new Uint8Array(800).fill(1).buffer);
  capture.emit('readData', new Uint8Array(900).fill(2).buffer);
  assert.equal(engine.frames.length, 1); assert.equal(engine.frames[0].length, 1280);
  await voice.stop(); await ticks();
  assert.equal(engine.frames[1].length, 640, 'tail frame is padded to accepted speech SDK frame size');
  assert.equal(engine.frames[1][419], 2); assert.equal(engine.frames[1][420], 0);
  assert.deepEqual(recognized, ['下一首'], 'result plus completion cannot dispatch duplicate command');
  assert.equal(capture.released, 1); assert.equal(engine.released, 1); assert.equal(status.busy, false);
  await voice.start(context); await ticks();
  captures.at(-1).emit('audioInterrupt', { hintType: 2 }); await ticks();
  assert.match(status.message, /占用/); assert.equal(status.listening, false);
  await voice.start(context); await ticks(); await voice.dispose();
  assert(captures.every(item => item.released === 1)); assert(engines.every(item => item.released === 1));
  let releaseStart;
  gateCaptureStart = new Promise(resolve => { releaseStart = resolve; });
  const departingVoice = new VoiceService(() => {}, () => { throw new Error('Disposed page must not receive commands'); });
  await departingVoice.start(context); await ticks();
  const lateCapture = captures.at(-1);
  const teardown = departingVoice.dispose();
  await ticks(); assert.equal(lateCapture.released, 0, 'teardown waits for pending native start');
  releaseStart(); await teardown;
  assert.equal(lateCapture.released, 1); assert.equal(lateCapture.state, 4);
  console.log('PASS voice: local TTS completion/error, synthesis versus playback completion, recording priority, denied permission, missing engine, real capturer plumbing, 1280-byte chunking, 640-byte padded tail, single command dispatch, interruption, cleanup, disposal during native start');
})().catch(error => { console.error(error); process.exitCode = 1; });
