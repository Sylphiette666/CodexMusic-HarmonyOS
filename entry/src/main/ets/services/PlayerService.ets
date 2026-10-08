import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song, PlayMode, nextIndex } from '../model/MusicModels';

export class PlayerSnapshot {
  song: Song | undefined = undefined;
  queue: Song[] = [];
  index: number = -1;
  playing: boolean = false;
  loading: boolean = false;
  position: number = 0;
  duration: number = 0;
  volume: number = 0.75;
  mode: PlayMode = PlayMode.Sequence;
  error: string = '';
  background: string = '未启动后台播放';
}

type PlayerObserver = (snapshot: PlayerSnapshot) => void;

/** One process-wide player: navigation only detaches observers, never the audio. */
export class PlayerService {
  private context: common.UIAbilityContext | undefined = undefined;
  private native: media.AVPlayer | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private launchAgent: WantAgent | undefined = undefined;
  private sessionPending: Promise<void> | undefined = undefined;
  private file: fs.File | undefined = undefined;
  private rawName: string = '';
  private activeBackground: boolean = false;
  private observers: PlayerObserver[] = [];
  private state: PlayerSnapshot = new PlayerSnapshot();
  private operations: Promise<void> = Promise.resolve();
  private generation: number = 0;
  private wantedPlaying: boolean = false;
  private disposed: boolean = false;
  private ducked: boolean = false;
  private abortWait: (() => void) | undefined = undefined;
  private initializedWaiter: ((state: media.AVPlayerState) => void) | undefined = undefined;
  private sessionUpdateAt: number = 0;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.disposed = false;
    if (this.session !== undefined) return;
    if (this.sessionPending !== undefined) return this.sessionPending;
    this.sessionPending = this.createSession(context).finally(() => { this.sessionPending = undefined; });
    return this.sessionPending;
  }

  snapshot(): PlayerSnapshot {
    const value = new PlayerSnapshot();
    value.song = this.state.song === undefined ? undefined : this.copySong(this.state.song);
    value.queue = this.state.queue.map((song: Song): Song => this.copySong(song));
    value.index = this.state.index;
    value.playing = this.state.playing;
    value.loading = this.state.loading;
    value.position = this.state.position;
    value.duration = this.state.duration;
    value.volume = this.state.volume;
    value.mode = this.state.mode;
    value.error = this.state.error;
    value.background = this.state.background;
    return value;
  }

  subscribe(observer: PlayerObserver): void {
    if (this.observers.indexOf(observer) < 0) this.observers.push(observer);
    observer(this.snapshot());
  }

  unsubscribe(observer: PlayerObserver): void {
    this.observers = this.observers.filter((item: PlayerObserver) => item !== observer);
  }

  setQueue(songs: Song[], index: number = 0): Promise<void> {
    this.state.queue = songs.map((song: Song): Song => this.copySong(song));
    if (songs.length === 0) {
      this.state.index = -1;
      this.state.song = undefined;
      this.state.duration = 0;
      this.state.error = '';
      return this.stop();
    }
    return this.select(Math.max(0, Math.min(songs.length - 1, Math.floor(index))));
  }

  /** Refresh edited lyrics/metadata without seeking, stopping, or recreating audio. */
  updateSong(song: Song): void {
    this.state.queue = this.state.queue.map((item: Song): Song => item.id === song.id ? this.copySong(song) : item);
    if (this.state.song !== undefined && this.state.song.id === song.id) {
      this.state.song = this.copySong(song);
      void this.updateMetadata(this.state.song);
    }
    this.publish();
  }

  play(): Promise<void> {
    if (this.state.song === undefined || this.disposed) return Promise.resolve();
    this.wantedPlaying = true;
    if (this.native === undefined || this.native.state === 'error' || this.native.state === 'released' ||
      this.native.state === 'stopped') return this.select(this.state.index);
    const ticket = this.generation;
    return this.enqueue(async () => {
      if (!this.valid(ticket) || !this.wantedPlaying || this.native === undefined) return;
      if (this.native.state === 'paused' || this.native.state === 'prepared' || this.native.state === 'completed') {
        this.state.error = '';
        await this.native.play();
        if (this.valid(ticket)) await this.startBackground();
      }
    }, ticket);
  }

  pause(): Promise<void> {
    // Record intent immediately, even if prepare() has not completed yet.
    this.wantedPlaying = false;
    const ticket = this.generation;
    return this.enqueue(async () => {
      if (!this.valid(ticket)) return;
      if (this.native !== undefined && this.native.state === 'playing') await this.native.pause();
      this.state.playing = false;
      await this.stopBackground();
      this.publish();
      await this.updateSession();
    }, ticket);
  }

  toggle(): Promise<void> {
    return (this.state.playing || (this.state.loading && this.wantedPlaying)) ? this.pause() : this.play();
  }

  previous(): Promise<void> {
    const index = nextIndex(this.state.queue.length, this.state.index, this.state.mode, true);
    return index < 0 ? Promise.resolve() : this.select(index);
  }

  next(): Promise<void> {
    const index = nextIndex(this.state.queue.length, this.state.index, this.state.mode);
    return index < 0 ? Promise.resolve() : this.select(index);
  }

  seek(milliseconds: number): Promise<void> {
    const ticket = this.generation;
    return this.enqueue(async () => {
      if (!this.valid(ticket) || this.native === undefined || !Number.isFinite(milliseconds)) return;
      if (this.native.state !== 'playing' && this.native.state !== 'paused' &&
        this.native.state !== 'prepared' && this.native.state !== 'completed') return;
      const destination = Math.max(0, Math.min(Math.round(milliseconds), this.milliseconds(this.state.duration)));
      this.native.seek(destination, media.SeekMode.SEEK_CLOSEST);
      this.state.position = destination;
      this.publish();
      await this.updateSession();
    }, ticket);
  }

  setVolume(volume: number): Promise<void> {
    if (!Number.isFinite(volume)) return Promise.resolve();
    this.state.volume = Math.max(0, Math.min(1, volume));
    this.publish();
    const ticket = this.generation;
    return this.enqueue(async () => {
      if (!this.valid(ticket)) return;
      this.applyVolume();
      await this.updateSession();
    }, ticket);
  }

  setMode(mode: PlayMode): void {
    this.state.mode = mode;
    this.publish();
    void this.updateSession();
  }

  stop(): Promise<void> {
    this.wantedPlaying = false;
    const ticket = this.invalidate();
    this.state.playing = false;
    this.state.loading = false;
    this.state.position = 0;
    this.publish();
    return this.enqueue(async () => {
      await this.releasePlayer();
      await this.stopBackground();
      await this.updateSession();
    }, ticket);
  }

  async dispose(): Promise<void> {
    this.disposed = true;
    this.wantedPlaying = false;
    this.invalidate();
    await this.operations;
    await this.releasePlayer();
    await this.stopBackground();
    if (this.sessionPending !== undefined) await this.sessionPending;
    const session = this.session;
    this.session = undefined;
    if (session !== undefined) {
      try { await session.deactivate(); } catch (_) { /* Already inactive. */ }
      try { await session.destroy(); } catch (_) { /* System may have reclaimed it. */ }
    }
    this.launchAgent = undefined;
    this.context = undefined;
    this.state.playing = false;
    this.state.loading = false;
    this.publish();
    this.observers = [];
  }

  private select(index: number): Promise<void> {
    if (this.disposed || index < 0 || index >= this.state.queue.length) return Promise.resolve();
    const ticket = this.invalidate();
    this.wantedPlaying = true;
    this.state.index = index;
    this.state.song = this.state.queue[index];
    this.state.position = 0;
    this.state.duration = this.state.song.duration;
    this.state.playing = false;
    this.state.loading = true;
    this.state.error = '';
    const song = this.state.song;
    this.publish();
    return this.enqueue(async () => {
      await this.releasePlayer();
      if (!this.valid(ticket)) return;
      const context = this.context;
      if (context === undefined) throw new Error('播放器尚未初始化');
      await this.init(context);
      if (!this.valid(ticket)) return;
      const player = await media.createAVPlayer();
      // Always take ownership before cancellation checks, so a superseding request
      // can release this exact native object and its file descriptor.
      this.native = player;
      if (!this.valid(ticket)) { await this.releasePlayer(); return; }
      this.bindPlayer(player, ticket);
      if (song.uri.startsWith('rawfile://')) {
        this.rawName = song.uri.substring('rawfile://'.length);
        const raw = await context.resourceManager.getRawFd(this.rawName);
        if (!this.valid(ticket)) return;
        player.fdSrc = { fd: raw.fd, offset: raw.offset, length: raw.length };
      } else {
        this.file = await fs.open(song.uri, fs.OpenMode.READ_ONLY);
        if (!this.valid(ticket)) return;
        const stat = await fs.stat(this.file.fd);
        player.fdSrc = { fd: this.file.fd, offset: 0, length: stat.size };
      }
      await this.waitInitialized(player, ticket);
      if (!this.valid(ticket)) return;
      player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 };
      await player.prepare();
      if (!this.valid(ticket)) return;
      // Unlike audioRendererInfo (initialized only), interrupt mode is a
      // dynamic property legal only after prepare() has completed.
      player.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE;
      this.state.duration = player.duration > 0 ? player.duration : song.duration;
      this.state.loading = false;
      this.ducked = false;
      this.applyVolume();
      await this.updateMetadata(song);
      if (!this.valid(ticket)) return;
      if (this.wantedPlaying) {
        await player.play();
        if (this.valid(ticket)) await this.startBackground();
      }
      this.publish();
      await this.updateSession();
    }, ticket);
  }

  private enqueue(action: () => Promise<void>, ticket: number): Promise<void> {
    const operation = this.operations.then(async () => {
      if (!this.valid(ticket)) return;
      try { await action(); } catch (error) {
        if (!this.valid(ticket)) return;
        this.state.playing = false;
        this.state.loading = false;
        this.state.error = `播放失败：请确认文件可访问且格式受支持（${this.errorCode(error as BusinessError)}）`;
        this.wantedPlaying = false;
        await this.releasePlayer();
        await this.stopBackground();
        this.publish();
        await this.updateSession();
      }
    });
    this.operations = operation;
    return operation;
  }

  private invalidate(): number {
    this.generation++;
    const abort = this.abortWait;
    this.abortWait = undefined;
    if (abort !== undefined) abort();
    return this.generation;
  }

  private valid(ticket: number): boolean { return !this.disposed && ticket === this.generation; }

  private waitInitialized(player: media.AVPlayer, ticket: number): Promise<void> {
    if (!this.valid(ticket)) return Promise.reject(new Error('cancelled'));
    if (player.state === 'initialized') return Promise.resolve();
    if (player.state === 'error' || player.state === 'released') return Promise.reject(new Error('音频无法初始化'));
    return new Promise<void>((resolve, reject) => {
      let timer: number = -1;
      const clean = (): void => {
        if (timer >= 0) clearTimeout(timer);
        this.initializedWaiter = undefined;
        this.abortWait = undefined;
      };
      const listener = (state: media.AVPlayerState): void => {
        if (state === 'initialized') { clean(); resolve(); }
        else if (state === 'error' || state === 'released') { clean(); reject(new Error('无法读取音频')); }
      };
      this.abortWait = (): void => { clean(); reject(new Error('cancelled')); };
      // AVPlayer retains a single callback per event. Re-registering a temporary
      // listener would replace the permanent state observer; off() would remove it.
      this.initializedWaiter = listener;
      timer = setTimeout(() => { clean(); reject(new Error('音频载入超时')); }, 12000);
    });
  }

  private bindPlayer(player: media.AVPlayer, ticket: number): void {
    player.on('stateChange', (state: media.AVPlayerState): void => {
      if (!this.valid(ticket) || player !== this.native) return;
      const waiter = this.initializedWaiter;
      if (waiter !== undefined) waiter(state);
      this.state.playing = state === 'playing';
      if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
        this.state.loading = false;
      }
      if (state === 'completed' && this.wantedPlaying) {
        const index = nextIndex(this.state.queue.length, this.state.index, this.state.mode, false, true);
        if (index >= 0) void this.select(index);
        else {
          this.wantedPlaying = false;
          this.state.position = this.state.duration;
          this.publish();
          void this.enqueue(async () => {
            await this.stopBackground();
            await this.updateSession();
          }, ticket);
        }
        return;
      }
      this.publish();
      void this.updateSession();
    });
    player.on('timeUpdate', (position: number): void => {
      if (!this.valid(ticket) || player !== this.native) return;
      this.state.position = Math.max(0, position);
      this.publish();
      if (Date.now() - this.sessionUpdateAt >= 1000) void this.updateSession();
    });
    player.on('durationUpdate', (duration: number): void => {
      if (!this.valid(ticket) || player !== this.native) return;
      this.state.duration = Math.max(0, duration);
      this.publish();
    });
    player.on('error', (error: BusinessError): void => {
      if (!this.valid(ticket) || player !== this.native) return;
      const waiter = this.initializedWaiter;
      if (waiter !== undefined) waiter('error');
      this.state.error = `音频播放出错（${this.errorCode(error)}），请重试或选择其他歌曲`;
      this.state.playing = false;
      this.state.loading = false;
      this.wantedPlaying = false;
      this.publish();
      void this.enqueue(async () => {
        if (player === this.native) await this.releasePlayer();
        await this.stopBackground();
        await this.updateSession();
      }, ticket);
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      if (!this.valid(ticket) || player !== this.native) return;
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.state.error = '播放已被其他音频中断，点击播放继续';
        void this.pause();
      } else if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK) this.ducked = true;
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) this.ducked = false;
        // Forced duck/unduck is performed by the platform; do not apply it twice.
        this.applyVolume();
      }
    });
  }

  private applyVolume(): void {
    const player = this.native;
    if (player === undefined) return;
    if (player.state === 'prepared' || player.state === 'playing' || player.state === 'paused' ||
      player.state === 'completed') player.setVolume(this.state.volume * (this.ducked ? 0.2 : 1));
  }

  private async releasePlayer(): Promise<void> {
    const player = this.native;
    this.native = undefined;
    if (player !== undefined) {
      try { await player.release(); } catch (_) { /* Continue closing the owned fd. */ }
    }
    const file = this.file;
    this.file = undefined;
    if (file !== undefined) {
      try { await fs.close(file); } catch (_) { /* Descriptor may already be invalid. */ }
    }
    const rawName = this.rawName;
    this.rawName = '';
    if (rawName.length > 0 && this.context !== undefined) {
      try { await this.context.resourceManager.closeRawFd(rawName); } catch (_) { /* Failed opens own no fd. */ }
    }
  }

  private async createSession(context: common.UIAbilityContext): Promise<void> {
    let session: avSession.AVSession | undefined = undefined;
    try {
      session = await avSession.createAVSession(context, 'CodexMusic', 'audio');
      if (this.disposed) { await session.destroy(); return; }
      this.session = session;
      session.on('play', (): void => { void this.play(); });
      session.on('pause', (): void => { void this.pause(); });
      session.on('stop', (): void => { void this.stop(); });
      session.on('playNext', (): void => { void this.next(); });
      session.on('playPrevious', (): void => { void this.previous(); });
      session.on('seek', (time: number): void => { void this.seek(time); });
      session.on('setLoopMode', (mode: avSession.LoopMode): void => {
        this.setMode(mode === avSession.LoopMode.LOOP_MODE_SINGLE ? PlayMode.RepeatOne :
          (mode === avSession.LoopMode.LOOP_MODE_SHUFFLE ? PlayMode.Random : PlayMode.Sequence));
      });
      this.launchAgent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 71,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await session.setLaunchAbility(this.launchAgent);
      await session.activate();
      this.state.background = '系统媒体控制已就绪';
      this.publish();
    } catch (error) {
      this.session = undefined;
      if (session !== undefined) {
        try { await session.destroy(); } catch (_) { /* Failed session must not leak. */ }
      }
      this.state.background = `系统媒体控制不可用（${this.errorCode(error as BusinessError)}），仅前台播放`;
      this.publish();
    }
  }

  private async updateMetadata(song: Song): Promise<void> {
    if (this.session === undefined) return;
    try {
      await this.session.setAVMetadata({ assetId: song.id, title: song.title, artist: song.artist,
        album: song.album, duration: this.state.duration });
    } catch (error) {
      this.state.background = `媒体信息更新失败（${this.errorCode(error as BusinessError)}）`;
      this.publish();
    }
  }

  private async updateSession(): Promise<void> {
    const session = this.session;
    if (session === undefined || this.disposed) return;
    this.sessionUpdateAt = Date.now();
    try {
      await session.setAVPlaybackState({
        state: this.state.loading ? avSession.PlaybackState.PLAYBACK_STATE_BUFFERING :
          (this.state.playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
            (this.native !== undefined && this.native.state === 'completed' ?
              avSession.PlaybackState.PLAYBACK_STATE_COMPLETED : avSession.PlaybackState.PLAYBACK_STATE_PAUSE)),
        // Native AVPlaybackState::IsValid requires speed > 0 in every state.
        // Pausing is represented by state, not a zero playback rate.
        speed: 1,
        position: { elapsedTime: this.milliseconds(this.state.position), updateTime: Date.now() },
        duration: this.milliseconds(this.state.duration),
        // AVSession uses int32 volume, unlike AVPlayer's normalized float.
        volume: Math.round(this.state.volume * 100),
        maxVolume: 100,
        loopMode: this.state.mode === PlayMode.RepeatOne ? avSession.LoopMode.LOOP_MODE_SINGLE :
          (this.state.mode === PlayMode.Random ? avSession.LoopMode.LOOP_MODE_SHUFFLE : avSession.LoopMode.LOOP_MODE_SEQUENCE)
      });
      if (this.state.background.startsWith('系统媒体状态更新失败')) {
        this.state.background = this.activeBackground ? '后台播放已开启' : '系统媒体控制已就绪';
        this.publish();
      }
    } catch (error) {
      this.state.background = `系统媒体状态更新失败（${this.errorCode(error as BusinessError)}）`;
      this.publish();
    }
  }

  private async startBackground(): Promise<void> {
    if (this.activeBackground || !this.wantedPlaying || this.disposed) return;
    if (this.context === undefined || this.launchAgent === undefined || this.session === undefined) {
      this.state.background = '后台播放不可用：系统媒体会话未就绪';
      this.publish();
      return;
    }
    try {
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, this.launchAgent);
      this.activeBackground = true;
      this.state.background = '后台播放已开启';
    } catch (error) {
      this.state.background = `后台播放不可用（${this.errorCode(error as BusinessError)}），切换应用可能暂停`;
    }
    this.publish();
  }

  private async stopBackground(): Promise<void> {
    if (!this.activeBackground || this.context === undefined) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.activeBackground = false;
      this.state.background = '后台播放已暂停';
    } catch (error) {
      this.state.background = `后台任务停止失败（${this.errorCode(error as BusinessError)}）`;
    }
    this.publish();
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? '未知错误' : `${error.code}`;
  }

  private milliseconds(value: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(2147483647, Math.round(value))) : 0;
  }

  private copySong(song: Song): Song {
    return { id: song.id, title: song.title, artist: song.artist, album: song.album, uri: song.uri,
      duration: song.duration, cover: song.cover, lyrics: song.lyrics };
  }

  private publish(): void {
    this.observers.forEach((observer: PlayerObserver) => {
      try { observer(this.snapshot()); } catch (_) { /* A route can detach during a native callback. */ }
    });
  }
}

export const playerService: PlayerService = new PlayerService();
