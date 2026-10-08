import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song, Playlist, PlayMode, DEMO_SONGS, filterSongs, parseVoiceCommand } from '../model/MusicModels';
import { MusicRepository } from '../model/MusicRepository';
import { LyricLine, LyricWord, parseLrc, findLyricIndex, wordProgress } from '../model/Lyrics';
import { playerService, PlayerSnapshot } from '../services/PlayerService';
import { VoiceService, VoiceStatus } from '../services/VoiceService';
import { ImportService, ImportResult } from '../services/ImportService';

@Entry
@Component
struct Index {
  @State private tab: number = 0;
  @State private songs: Song[] = [];
  @State private playlists: Playlist[] = [];
  @State private playlistTracks: Song[] = [];
  @State private selectedPlaylist: number = -1;
  @State private selectedName: string = '';
  @State private newName: string = '';
  @State private query: string = '';
  @State private command: string = '';
  @State private notice: string = '';
  @State private busy: boolean = true;
  @State private ready: boolean = false;
  @State private state: PlayerSnapshot = new PlayerSnapshot();
  @State private voiceState: VoiceStatus = new VoiceStatus();
  @State private pendingSong: Song | undefined = undefined;
  @State private lyricLines: LyricLine[] = [];
  private repo: MusicRepository = new MusicRepository();
  private importer?: ImportService;
  private voice?: VoiceService;
  private lastLyricSong: string = '';
  private listener: (snapshot: PlayerSnapshot) => void = (snapshot: PlayerSnapshot): void => {
    this.state = snapshot;
    if (snapshot.song && this.lastLyricSong !== snapshot.song.id + snapshot.song.lyrics + snapshot.duration) {
      this.lastLyricSong = snapshot.song.id + snapshot.song.lyrics + snapshot.duration;
      this.lyricLines = parseLrc(snapshot.song.lyrics, snapshot.duration || snapshot.song.duration);
    }
  };

  aboutToAppear(): void { this.initialize(); }
  aboutToDisappear(): void {
    playerService.unsubscribe(this.listener);
    this.voice?.dispose();
  }
  private async initialize(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repo.init(context);
      this.songs = await this.repo.listSongs();
      this.playlists = await this.repo.listPlaylists();
      this.importer = new ImportService(context);
      this.voice = new VoiceService((state: VoiceStatus): void => { this.voiceState = state; },
        (text: string): void => { this.command = text; this.runCommand(text); });
      playerService.subscribe(this.listener);
      await playerService.init(context);
      this.ready = true;
    } catch (error) { this.notice = '初始化失败：' + (error as BusinessError).message; }
    this.busy = false;
  }
  private async perform(action: () => Promise<void>): Promise<void> {
    try { await action(); } catch (error) { this.notice = (error as BusinessError).message || '操作失败，请重试'; }
  }
  private currentSong(): Song { return this.state.song || this.songs[0] || DEMO_SONGS[0]; }
  private time(value: number): string {
    const seconds = Math.floor(Math.max(0, value) / 1000);
    return Math.floor(seconds / 60).toString().padStart(2, '0') + ':' + (seconds % 60).toString().padStart(2, '0');
  }
  private cover(song: Song): ResourceStr {
    if (song.cover && !song.cover.startsWith('demo:') && !song.uri.startsWith('rawfile://')) { return song.cover.startsWith('file://') ? song.cover : 'file://' + song.cover; }
    if (song.uri.indexOf('rain') >= 0) { return $r('app.media.cover_rain'); }
    if (song.uri.indexOf('stars') >= 0) { return $r('app.media.cover_stars'); }
    return $r('app.media.cover_dawn');
  }
  private modeName(): string {
    return this.state.mode === PlayMode.Random ? '随机播放' : this.state.mode === PlayMode.RepeatOne ? '单曲循环' : '顺序播放';
  }
  private async playSong(song: Song, list: Song[]): Promise<void> {
    if (!this.ready) { return; }
    await this.perform(async (): Promise<void> => {
      await playerService.setQueue(list, list.findIndex((item: Song): boolean => item.id === song.id));
      this.tab = 0;
    });
  }
  private async toggle(): Promise<void> {
    await this.perform(async (): Promise<void> => {
      if (!this.state.song) { await playerService.setQueue(this.songs, 0); }
      else { await playerService.toggle(); }
    });
  }
  private async importSongs(scan: boolean = false, directory: boolean = false): Promise<void> {
    if (!this.importer || this.busy) { return; }
    this.busy = true;
    await this.perform(async (): Promise<void> => {
      const result: ImportResult = directory ? await this.importer!.scanDirectory() :
        scan ? await this.importer!.scanImported() : await this.importer!.importAudio();
      if (!result.cancelled) {
        await this.repo.saveSongs(result.songs);
        this.songs = await this.repo.listSongs();
        this.notice = '已读取 ' + result.songs.length + ' 首音频。' + result.errors.join('；');
      }
    });
    this.busy = false;
  }
  private async loadLyrics(): Promise<void> {
    if (!this.importer) { return; }
    await this.perform(async (): Promise<void> => {
      const current = this.currentSong();
      const song: Song = { id: current.id, title: current.title, artist: current.artist, album: current.album,
        uri: current.uri, duration: current.duration, cover: current.cover, lyrics: current.lyrics, fileName: current.fileName };
      const text = await this.importer!.importLyrics();
      if (!text) { return; }
      const parsed = parseLrc(text, song.duration);
      if (parsed.length === 0) { this.notice = '歌词中没有有效的 LRC 时间戳'; return; }
      song.lyrics = text;
      if (!song.uri.startsWith('rawfile://')) { await this.importer!.saveLyrics(song, text); }
      await this.repo.saveSongs([song]);
      this.songs = await this.repo.listSongs();
      playerService.updateSong(song);
      this.notice = '已关联 ' + parsed.length + ' 行歌词';
    });
  }
  private async createPlaylist(): Promise<void> {
    await this.perform(async (): Promise<void> => {
      await this.repo.createPlaylist(this.newName);
      this.newName = '';
      this.playlists = await this.repo.listPlaylists();
      this.notice = '歌单已保存';
    });
  }
  private async viewPlaylist(list: Playlist): Promise<void> {
    await this.perform(async (): Promise<void> => {
      this.selectedPlaylist = list.id;
      this.selectedName = list.name;
      this.playlistTracks = await this.repo.playlistSongs(list.id);
    });
  }
  private confirmDelete(list: Playlist): void {
    this.getUIContext().showAlertDialog({ title: '删除歌单', message: '删除“' + list.name + '”？音乐库中的音频会保留。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => {
        this.perform(async (): Promise<void> => {
          await this.repo.deletePlaylist(list.id);
          this.playlists = await this.repo.listPlaylists();
          if (this.selectedPlaylist === list.id) { this.selectedPlaylist = -1; }
        });
      }} });
  }
  private async addToPlaylist(list: Playlist): Promise<void> {
    if (!this.pendingSong) { return; }
    await this.perform(async (): Promise<void> => {
      await this.repo.addToPlaylist(list.id, this.pendingSong!.id);
      this.pendingSong = undefined;
      this.playlists = await this.repo.listPlaylists();
      if (this.selectedPlaylist === list.id) { this.playlistTracks = await this.repo.playlistSongs(list.id); }
      this.notice = '已加入“' + list.name + '”';
    });
  }
  private async removeFromPlaylist(song: Song): Promise<void> {
    await this.perform(async (): Promise<void> => {
      await this.repo.removeFromPlaylist(this.selectedPlaylist, song.id);
      this.playlistTracks = await this.repo.playlistSongs(this.selectedPlaylist);
      this.playlists = await this.repo.listPlaylists();
    });
  }
  private async runCommand(text: string): Promise<void> {
    const cmd = parseVoiceCommand(text);
    await this.perform(async (): Promise<void> => {
      if (cmd.action === 'next') { await playerService.next(); }
      else if (cmd.action === 'previous') { await playerService.previous(); }
      else if (cmd.action === 'pause') { await playerService.pause(); }
      else if (cmd.action === 'resume') {
        if (!this.state.song) { await playerService.setQueue(this.songs, 0); } else { await playerService.play(); }
      } else if (cmd.action === 'play' || cmd.action === 'search') {
        const matches = filterSongs(this.songs, cmd.query);
        if (cmd.action === 'search') { this.query = cmd.query; this.tab = 2; }
        else if (matches.length) { await playerService.setQueue(matches, 0); this.tab = 0; }
        else { this.notice = '未找到“' + cmd.query + '”'; }
      } else { this.notice = '支持：播放晨光、暂停、继续播放、上一首、下一首、搜索歌名'; return; }
      if (cmd.action !== 'play' || filterSongs(this.songs, cmd.query).length) { this.notice = '指令：' + text; }
    });
  }
  private async listen(): Promise<void> {
    await this.perform(async (): Promise<void> => {
      if (this.voiceState.listening) { await this.voice?.stop(); }
      else { await this.voice?.start(this.getUIContext().getHostContext() as common.UIAbilityContext); }
    });
  }
  private activeLyric(): LyricLine | undefined {
    const index = findLyricIndex(this.lyricLines, this.state.position);
    return index >= 0 ? this.lyricLines[index] : undefined;
  }
  private nextLyric(): string {
    const index = findLyricIndex(this.lyricLines, this.state.position);
    return this.lyricLines[index + 1]?.text || (this.lyricLines.length ? '让音乐，陪你慢下来' : '导入 LRC 歌词，跟随旋律阅读');
  }

  @Builder
  private header(title: string, subtitle: string) {
    Column({ space: 5 }) {
      Row() {
        Text(title).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#183F35').layoutWeight(1)
        Text('听见').fontSize(14).fontColor('#56765D').fontWeight(FontWeight.Medium)
      }.width('100%')
      Text(subtitle).fontSize(12).fontColor('#738176').width('100%')
    }.width('100%').padding({ top: 12, bottom: 20 })
  }
  @Builder
  private smallButton(label: string, action: () => void, id: string) {
    Button(label).id(id).fontSize(13).fontColor('#214D3E').backgroundColor('#E8EDDF').borderRadius(13)
      .height(38).onClick(action)
  }
  @Builder
  private songRow(song: Song, list: Song[], kind: string) {
    Row({ space: 12 }) {
      Image(this.cover(song)).width(52).height(52).borderRadius(12).objectFit(ImageFit.Cover)
        .onClick((): void => { this.playSong(song, list); })
      Column({ space: 5 }) {
        Text(song.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#183F35').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(song.artist + ' · ' + song.album).fontSize(11).fontColor('#768174').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick((): void => { this.playSong(song, list); })
      if (kind === 'playlist') {
        Button('移除').fontSize(11).fontColor('#8B5A45').backgroundColor('#F4E6DD').height(32)
          .onClick((): void => { this.removeFromPlaylist(song); })
      } else if (kind === 'library') {
        Button('+').fontSize(22).fontColor('#315D45').backgroundColor('#EDF0E5').width(36).height(36)
          .id('AddSong_' + song.id).onClick((): void => {
            this.pendingSong = song; this.tab = 3;
            if (!this.playlists.length) { this.notice = '先创建歌单，再点击歌单添加歌曲'; }
          })
      } else {
        Text(this.time(song.duration)).fontSize(11).fontColor('#798677')
      }
    }.id(kind + '_' + song.id).width('100%').padding({ top: 12, bottom: 12 })
  }
  @Builder
  private playerPage() {
    Scroll() {
      Column() {
        this.header('把时间交给音乐', 'NOW PLAYING  /  此刻，听见生活')
        Stack({ alignContent: Alignment.BottomStart }) {
          Image(this.cover(this.currentSong())).width('100%').height(245).objectFit(ImageFit.Cover).borderRadius(24)
          Text(this.currentSong().uri.startsWith('rawfile://') ? '原创纯音乐 · 30 秒试听' : '我的本地音乐')
            .fontSize(11).fontColor('#FFFFFF').backgroundColor('#80213D30').padding(10).borderRadius(10)
            .margin({ left: 16, bottom: 16 })
        }.width('100%')
        Row() {
          Column({ space: 6 }) {
            Text(this.currentSong().title).id('NowTitle').fontSize(26).fontWeight(FontWeight.Bold).fontColor('#183F35').maxLines(1)
            Text(this.currentSong().artist + ' · ' + this.currentSong().album).fontSize(12).fontColor('#738176').maxLines(1)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button('+ 歌单').fontSize(12).backgroundColor('#E8EDDF').fontColor('#315D45').height(34)
            .onClick((): void => { this.pendingSong = this.currentSong(); this.tab = 3; })
        }.width('100%').margin({ top: 20, bottom: 16 })
        Column({ space: 9 }) {
          if (this.activeLyric()) {
            Flex({ justifyContent: FlexAlign.Center, wrap: FlexWrap.Wrap }) {
              ForEach(this.activeLyric()!.words, (word: LyricWord, index: number) => {
                Column({ space: 0 }) {
                  Text('●').fontSize(6).height(11)
                    .fontColor(this.state.position >= word.start && this.state.position < word.end ? '#BC793E' : Color.Transparent)
                  Text(word.text).fontSize(18).fontWeight(FontWeight.Medium)
                    .fontColor(this.state.position >= word.start ? '#28513C' : '#9AA38F')
                }.translate({ y: this.state.position >= word.start && this.state.position < word.end ?
                  -Math.sin(wordProgress(word, this.state.position) * Math.PI) * 7 : 0 })
              }, (word: LyricWord, index: number): string => this.currentSong().id + ':' + word.start + ':' + word.text + ':' + index)
            }.width('100%')
          } else {
            Text('按下播放，让旋律开始').fontSize(18).fontColor('#53704C')
          }
          Text(this.nextLyric()).fontSize(12).fontColor('#929A88').maxLines(2)
          Text(this.lyricLines.length === 0 ? '支持普通 LRC 与增强逐字 LRC' : this.activeLyric()?.estimated ? '普通 LRC · 字间时间为估算' : '增强 LRC · 按字时间同步')
            .fontSize(9).fontColor('#929A88')
        }.height(90).width('100%').justifyContent(FlexAlign.Center)
        Slider({ value: this.state.position, min: 0, max: Math.max(1, this.state.duration || this.currentSong().duration),
          style: SliderStyle.OutSet }).id('SeekSlider').selectedColor('#456B46').trackColor('#DBE1D1')
          .blockColor('#456B46').blockSize({ width: 12, height: 12 })
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { this.perform(async (): Promise<void> => { await playerService.seek(value); }); }
          })
        Row() {
          Text(this.time(this.state.position)).id('Position').fontSize(11).fontColor('#7E8876')
          Blank()
          Text(this.time(this.state.duration || this.currentSong().duration)).fontSize(11).fontColor('#7E8876')
        }.width('100%')
        Row({ space: 24 }) {
          Button('上一首').id('PreviousButton').fontSize(13).backgroundColor(Color.Transparent).fontColor('#264C38')
            .onClick((): void => { this.perform(async (): Promise<void> => { await playerService.previous(); }); })
          Button(this.state.loading ? '…' : this.state.playing ? 'Ⅱ' : '▶︎').id('PlayButton').width(68).height(68)
            .fontSize(26).backgroundColor('#254D39').fontColor('#FFFFFF').enabled(this.ready && !this.state.loading)
            .onClick((): void => { this.toggle(); })
          Button('下一首').id('NextButton').fontSize(13).backgroundColor(Color.Transparent).fontColor('#264C38')
            .onClick((): void => { this.perform(async (): Promise<void> => { await playerService.next(); }); })
        }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 13, bottom: 12 })
        Row() {
          Button(this.modeName()).id('ModeButton').fontSize(13).fontColor('#214D3E').backgroundColor('#E8EDDF')
            .height(38).borderRadius(13).onClick((): void => { playerService.setMode((this.state.mode + 1) % 3); })
          Blank()
          Text('音量').fontSize(11).fontColor('#7A8777')
          Slider({ value: this.state.volume * 100, min: 0, max: 100 }).width(110)
            .selectedColor('#6B8658').trackColor('#DBE1D1').blockSize({ width: 10, height: 10 })
            .onChange((value: number): void => { playerService.setVolume(value / 100); }).id('VolumeSlider')
        }.width('100%')
        Row({ space: 8 }) {
          Button(this.voiceState.listening ? '结束识别' : '语音点歌').id('VoiceButton').fontSize(13).fontColor('#214D3E')
            .backgroundColor('#E8EDDF').height(38).borderRadius(13).onClick((): void => { this.listen(); })
          this.smallButton('导入 LRC', (): void => { this.loadLyrics(); }, 'LyricsButton')
          this.smallButton('播报歌曲', (): void => {
            this.perform(async (): Promise<void> => { await this.voice?.speak('正在播放，' + this.currentSong().title + '，歌手，' + this.currentSong().artist); });
          }, 'SpeakButton')
        }.width('100%').margin({ top: 15 })
        Text(this.voiceState.message || '试着说“播放晨光”或“下一首”').fontSize(11).fontColor('#74816B')
          .width('100%').margin({ top: 9 })
        Row({ space: 6 }) {
          TextInput({ text: this.command, placeholder: '输入指令也能控制播放' }).fontSize(12).height(38).layoutWeight(1)
            .backgroundColor('#EDEFE5').onChange((value: string): void => { this.command = value; }).id('CommandInput')
          this.smallButton('执行', (): void => { this.runCommand(this.command); }, 'CommandButton')
        }.width('100%').margin({ top: 10 })
        Text(this.state.background).id('BackgroundStatus').fontSize(10).fontColor('#86917E').width('100%').margin({ top: 14, bottom: 18 })
      }.padding({ left: 24, right: 24 }).width('100%')
    }.scrollBar(BarState.Off).width('100%').height('100%')
  }
  @Builder
  private queuePage() {
    Scroll() {
      Column() {
        this.header('接下来，继续听', 'PLAY QUEUE  /  让旋律继续')
        Text(this.state.queue.length + ' 首 · ' + this.modeName()).fontSize(12).fontColor('#738176').width('100%')
        if (!this.state.queue.length) {
          Text('播放音乐后，歌曲会出现在这里').fontSize(14).fontColor('#71816D').margin({ top: 50 })
          this.smallButton('播放全部音乐', (): void => {
            this.perform(async (): Promise<void> => { await playerService.setQueue(this.songs, 0); });
          }, 'QueuePlayAll')
        }
        ForEach(this.state.queue, (song: Song) => { this.songRow(song, this.state.queue, 'queue'); }, (song: Song): string => song.id)
      }.width('100%').padding(24)
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
  @Builder
  private libraryPage() {
    Scroll() {
      Column({ space: 10 }) {
        this.header('你的声音收藏', 'LIBRARY  /  私藏每一段旋律')
        Text(this.songs.length + ' 首本地音乐').id('LibraryCount').fontSize(12).fontColor('#738176').width('100%')
        TextInput({ text: this.query, placeholder: '搜索歌名、歌手、专辑或文件名' }).id('SearchInput')
          .height(46).fontSize(14).backgroundColor('#E8EDDF').onChange((text: string): void => { this.query = text; })
        Row({ space: 9 }) {
          Button(this.busy ? '处理中…' : '导入音频').id('ImportButton').fontSize(13).fontColor('#214D3E')
            .backgroundColor('#E8EDDF').height(38).borderRadius(13).enabled(!this.busy).onClick((): void => { this.importSongs(); })
          this.smallButton('扫描本应用', (): void => { this.importSongs(true); }, 'ScanButton')
          this.smallButton('选目录', (): void => { this.importSongs(false, true); }, 'FolderButton')
        }.width('100%')
        Text('通过系统文件选择器授权导入音频。扫描仅访问本应用目录；目录选择取决于设备支持。')
          .fontSize(11).fontColor('#87917B').width('100%').margin({ bottom: 9 })
        if (filterSongs(this.songs, this.query).length === 0) {
          Text('没有找到音乐，试试其他关键词').fontSize(14).fontColor('#75836B').margin(24)
        }
        ForEach(filterSongs(this.songs, this.query), (song: Song) => {
          this.songRow(song, filterSongs(this.songs, this.query), 'library');
        }, (song: Song): string => song.id)
      }.width('100%').padding(24)
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
  @Builder
  private playlistsPage() {
    Scroll() {
      Column({ space: 12 }) {
        this.header('给喜欢的旋律一个家', 'PLAYLISTS  /  本地 RDB 持久保存')
        if (this.pendingSong) {
          Text('将“' + this.pendingSong.title + '”添加到歌单').fontSize(14).fontColor('#365C3F').width('100%')
          this.smallButton('取消添加', (): void => { this.pendingSong = undefined; }, 'CancelAdd')
        }
        Row({ space: 8 }) {
          TextInput({ text: this.newName, placeholder: '新歌单名称' }).id('PlaylistNameInput').height(44)
            .layoutWeight(1).fontSize(14).backgroundColor('#E8EDDF').onChange((value: string): void => { this.newName = value; })
          this.smallButton('创建', (): void => { this.createPlaylist(); }, 'CreatePlaylistButton')
        }.width('100%')
        ForEach(this.playlists, (list: Playlist) => {
          Row({ space: 10 }) {
            Text('♫').fontSize(26).fontColor('#58764D').width(38)
            Column({ space: 5 }) {
              Text(list.name).fontSize(17).fontColor('#284B37').maxLines(1)
              Text(list.count + ' 首歌曲').fontSize(11).fontColor('#84917D')
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              .onClick((): void => { if (this.pendingSong) { this.addToPlaylist(list); } else { this.viewPlaylist(list); } })
            this.smallButton(this.pendingSong ? '添加' : '打开', (): void => {
              if (this.pendingSong) { this.addToPlaylist(list); } else { this.viewPlaylist(list); }
            }, 'OpenPlaylist_' + list.id)
            Button('删除').fontSize(11).fontColor('#8E654E').backgroundColor(Color.Transparent)
              .onClick((): void => { this.confirmDelete(list); })
          }.width('100%').padding({ top: 13, bottom: 13 })
        }, (list: Playlist): string => list.id + ':' + list.count + ':' + list.name + ':' + (this.pendingSong?.id || ''))
        if (!this.playlists.length) {
          Text('从一个名字开始，建立第一张歌单').fontSize(13).fontColor('#8C967F').margin({ top: 30 })
        }
        if (this.selectedPlaylist >= 0) {
          Divider().color('#DDE3D2').margin({ top: 12, bottom: 12 })
          Text(this.selectedName).fontSize(22).fontWeight(FontWeight.Bold).fontColor('#274A36').width('100%')
          if (!this.playlistTracks.length) {
            Text('在音乐库点击 +，将音乐加入这张歌单').fontSize(12).fontColor('#84917D').width('100%')
          }
          ForEach(this.playlistTracks, (song: Song) => { this.songRow(song, this.playlistTracks, 'playlist'); }, (song: Song): string => song.id)
        }
      }.width('100%').padding(24)
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
  @Builder
  private tabLabel(label: string, index: number) {
    Column({ space: 5 }) {
      Text(index === 0 ? '◉' : index === 1 ? '≡' : index === 2 ? '♫' : '♡').fontSize(21).fontColor(this.tab === index ? '#264F38' : '#89927F')
      Text(label).fontSize(11).fontColor(this.tab === index ? '#264F38' : '#89927F')
    }.id('Tab' + index).height(58).width('100%').justifyContent(FlexAlign.Center)
  }
  build() {
    Column() {
      if (this.notice || this.state.error) {
        Row({ space: 8 }) {
          Text(this.notice || this.state.error).id('Notice').fontSize(11).fontColor('#66532F').layoutWeight(1).maxLines(3)
          Text('×').fontSize(20).onClick((): void => { this.notice = ''; })
        }.width('100%').padding(12).backgroundColor('#EAE9D7')
      }
      Tabs({ barPosition: BarPosition.End, index: this.tab }) {
        TabContent() { this.playerPage(); }.tabBar(this.tabLabel('播放', 0))
        TabContent() { this.queuePage(); }.tabBar(this.tabLabel('待播', 1))
        TabContent() { this.libraryPage(); }.tabBar(this.tabLabel('音乐库', 2))
        TabContent() { this.playlistsPage(); }.tabBar(this.tabLabel('我的歌单', 3))
      }.layoutWeight(1).barHeight(65).barBackgroundColor('#F0F1E8').animationDuration(180)
        .onChange((index: number): void => { this.tab = index; })
    }.width('100%').height('100%').backgroundColor('#F6F5EF')
  }
}


