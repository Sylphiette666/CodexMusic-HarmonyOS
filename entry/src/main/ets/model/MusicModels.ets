// Pure ArkTS data contracts: this module has no platform dependencies.
export interface Song {
  id: string;
  title: string;
  artist: string;
  album: string;
  uri: string;
  fileName?: string;
  duration: number;
  cover: string;
  lyrics: string;
}

export interface Playlist {
  id: number;
  name: string;
  count: number;
}

export enum PlayMode {
  Sequence = 0,
  Random = 1,
  RepeatOne = 2
}

export interface VoiceCommand {
  action: 'next' | 'previous' | 'pause' | 'resume' | 'play' | 'search' | 'unknown';
  query: string;
}

// Original instrumental demos; the timed text is a learning caption, not sung vocals.
export const DEMO_SONGS: Song[] = [
  {
    id: 'demo-dawn', title: '晨光序曲', artist: 'Codex 原创合成器', album: '代码与声音',
    uri: 'rawfile://dawn.wav', duration: 30000, cover: '',
    lyrics: '[00:00.00]晨光序曲 · 原创器乐配文\n[00:05.00]第一束光落在窗前\n' +
      '[00:10.00]让旋律陪伴新的清晨\n[00:15.00]跟着节拍慢慢向前\n' +
      '[00:20.00]把每一个灵感写进今天\n[00:25.00]音乐与代码一同醒来'
  },
  {
    id: 'demo-rain', title: '雨中漫步', artist: 'Codex 原创合成器', album: '代码与声音',
    uri: 'rawfile://rain.wav', duration: 30000, cover: '',
    lyrics: '[00:00.00]雨中漫步 · 原创器乐配文\n[00:05.00]雨点轻轻敲响窗台\n' +
      '[00:10.00]街角留下一片安静\n[00:15.00]脚步随着旋律放慢\n' +
      '[00:20.00]把纷乱的思绪放开\n[00:25.00]听见此刻温柔的回声'
  },
  {
    id: 'demo-stars', title: '星河回响', artist: 'Codex 原创合成器', album: '代码与声音',
    uri: 'rawfile://stars.wav', duration: 30000, cover: '',
    lyrics: '[00:00.00]星河回响 · 原创器乐配文\n[00:05.00]星光穿过安静的夜\n' +
      '[00:10.00]远方仍有微小的光\n[00:15.00]让心愿跟随音符飞翔\n' +
      '[00:20.00]每次尝试都留下回响\n[00:25.00]明天继续我们的乐章'
  }
];

export function filterSongs(songs: Song[], query: string): Song[] {
  const terms = query.trim().toLowerCase().split(/\s+/).filter((term: string) => term.length > 0);
  if (terms.length === 0) {
    return songs.slice();
  }
  return songs.filter((song: Song) => {
    const filename = song.uri.slice(song.uri.lastIndexOf('/') + 1);
    const text = (song.title + ' ' + song.artist + ' ' + song.album + ' ' + (song.fileName ?? '') + ' ' + filename).toLowerCase();
    return terms.every((term: string) => text.indexOf(term) >= 0);
  });
}

// RepeatOne applies to automatic completion. Manual next/previous still changes songs.
// Random chooses from the other N-1 songs, so a nontrivial queue cannot repeat immediately.
export function nextIndex(length: number, current: number, mode: PlayMode,
  previous: boolean = false, automatic: boolean = false, random: number = Math.random()): number {
  if (!Number.isInteger(length) || length < 1) {
    return -1;
  }
  if (!Number.isInteger(current) || current < 0 || current >= length) {
    return previous ? length - 1 : 0;
  }
  if (mode === PlayMode.Sequence && automatic && !previous && current === length - 1) {
    return -1;
  }
  if (length === 1 || (mode === PlayMode.RepeatOne && automatic)) {
    return current;
  }
  if (mode === PlayMode.Random) {
    const sample = Number.isFinite(random) ? Math.max(0, Math.min(0.9999999999999999, random)) : 0;
    const candidate = Math.floor(sample * (length - 1));
    return candidate >= current ? candidate + 1 : candidate;
  }
  return (current + (previous ? -1 : 1) + length) % length;
}

export function parseVoiceCommand(input: string): VoiceCommand {
  let text = input.trim().replace(/[，。！？、,.!?]+$/g, '').trim();
  text = text.replace(/^(?:(?:麻烦|请|帮我|给我)\s*)+/, '').trim();
  const compact = text.replace(/\s+/g, '').toLowerCase();
  if (/^(下一首|下一曲|下首|切歌|切到下一首|播放下一首|换一首|next|nextsong)$/.test(compact)) {
    return { action: 'next', query: '' };
  }
  if (/^(上一首|上一曲|上首|切到上一首|播放上一首|previous|previoussong)$/.test(compact)) {
    return { action: 'previous', query: '' };
  }
  if (/^(暂停|暂停播放|停止|停止播放|暂停音乐|停止音乐|pause|stop)$/.test(compact)) {
    return { action: 'pause', query: '' };
  }
  if (/^(播放|继续|继续播放|恢复播放|开始播放|继续音乐|播放音乐|resume|play)$/.test(compact)) {
    return { action: 'resume', query: '' };
  }
  if (/^(不要|别|取消|不想|不需要|停止搜索|停止播放)/.test(compact)) {
    return { action: 'unknown', query: '' };
  }
  if (/^(搜索|搜一下|查找|找一下|搜|search)$/i.test(compact)) {
    return { action: 'unknown', query: '' };
  }
  const search = /^(搜索|搜一下|查找|找一下|搜|search\s+)(.+)$/i.exec(text);
  if (search !== null && search[2].trim().length > 0) {
    return { action: 'search', query: search[2].trim() };
  }
  const play = /^(播放|放一首|来一首|我想听|我要听|听一首|play\s+)(.+)$/i.exec(text);
  if (play !== null && play[2].trim().length > 0) {
    const query = play[2].trim().replace(/这首歌$/, '').trim();
    if (query.length > 0) {
      return { action: 'play', query: query };
    }
  }
  return { action: 'unknown', query: '' };
}


