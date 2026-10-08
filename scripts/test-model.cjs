#!/usr/bin/env node
'use strict';
// Runs the shipped .ets source after in-memory TypeScript transpilation.
// Repository cases execute its actual SQL against a temporary, file-backed SQLite database.
// The adapter only translates the Harmony RDB API; this does not claim device RDB validation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');

function compiler() {
  const explicitIndex = process.argv.indexOf('--typescript');
  if (explicitIndex >= 0) return require(path.resolve(process.argv[explicitIndex + 1]));
  const homeIndex = process.argv.indexOf('--deveco-home');
  const home = homeIndex >= 0 ? process.argv[homeIndex + 1] : process.env.DEVECO_HOME || 'D:/HUAWEI/DevEco Studio';
  const candidates = [process.env.TYPESCRIPT_PATH,
    path.join(home, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'),
    path.join(home, 'tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js')];
  for (const candidate of candidates) if (candidate && fs.existsSync(candidate)) return require(candidate);
  try { return require('typescript'); } catch (_) {
    throw new Error('TypeScript not found. Set DEVECO_HOME/TYPESCRIPT_PATH or pass --typescript PATH.');
  }
}
const ts = compiler();
function load(filename, imports = {}) {
  const absolute = path.join(__dirname, '../entry/src/main/ets/model', filename);
  const result = ts.transpileModule(fs.readFileSync(absolute, 'utf8'), {
    fileName: absolute.replace(/\.ets$/, '.ts'),
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true
  });
  const errors = (result.diagnostics || []).filter((item) => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map((item) => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  const module = { exports: {} };
  const context = vm.createContext({ module, exports: module.exports,
    require: (name) => { assert.ok(imports[name], `Unexpected platform import: ${name}`); return imports[name]; } });
  new vm.Script(result.outputText, { filename: absolute }).runInContext(context);
  return module.exports;
}
const model = load('MusicModels.ets');
const lyrics = load('Lyrics.ets');
const { PlayMode, DEMO_SONGS, filterSongs, nextIndex, parseVoiceCommand } = model;
const { parseLrc, findLyricIndex, wordProgress } = lyrics;
const cases = [];
function test(name, run) { cases.push({ name, run }); }
function plain(value) { return JSON.parse(JSON.stringify(value)); }
function makeSong(id, uri = `/sandbox/${id}.mp3`) {
  return { id, title: id, artist: '音乐人', album: '测试专辑', uri, duration: 12345, cover: '', lyrics: '' };
}

test('search covers title, artist, album and filename with case-insensitive multiple terms', () => {
  const songs = [makeSong('first', '/sandbox/Summer.MP3'), makeSong('second')];
  songs[0].title = '夏夜'; songs[0].artist = 'Alice'; songs[0].album = 'Blue';
  for (const query of ['夏夜', 'ALICE', 'blue', 'summer.mp3', ' Alice   BLUE ']) {
    assert.equal(filterSongs(songs, query)[0].id, 'first');
  }
  assert.equal(filterSongs(songs, '夏夜 second').length, 0);
  assert.equal(filterSongs(songs, '  ').length, 2);
});
test('search retains the original filename after the importer changes URI to a content hash', () => {
  const song = makeSong('hashed', '/sandbox/012345abcdef.mp3'); song.title = 'ID3 标题'; song.fileName = 'Original Song.mp3';
  assert.equal(filterSongs([song], 'original song').length, 1);
});
test('sequential playback stops at the final song on automatic completion only', () => {
  assert.equal(nextIndex(3, 2, PlayMode.Sequence, false, true), -1);
  assert.equal(nextIndex(1, 0, PlayMode.Sequence, false, true), -1);
  assert.equal(nextIndex(3, 2, PlayMode.Sequence), 0);
  assert.equal(nextIndex(3, 1, PlayMode.Sequence, false, true), 2);
});
test('queue wraps forward/backward and handles empty, singleton and invalid selection', () => {
  assert.equal(nextIndex(0, 0, PlayMode.Sequence), -1);
  assert.equal(nextIndex(1, 0, PlayMode.Random), 0);
  assert.equal(nextIndex(3, 2, PlayMode.Sequence), 0);
  assert.equal(nextIndex(3, 0, PlayMode.Sequence, true), 2);
  assert.equal(nextIndex(3, -1, PlayMode.Sequence), 0);
  assert.equal(nextIndex(3, -1, PlayMode.Sequence, true), 2);
  assert.equal(nextIndex(NaN, 0, PlayMode.Sequence), -1);
});
test('single repeat only repeats on automatic completion', () => {
  assert.equal(nextIndex(3, 1, PlayMode.RepeatOne, false, true), 1);
  assert.equal(nextIndex(3, 1, PlayMode.RepeatOne), 2);
  assert.equal(nextIndex(3, 1, PlayMode.RepeatOne, true), 0);
});
test('random mode excludes the current song across samples and clamps bad randomness', () => {
  for (let current = 0; current < 4; current++) {
    const selected = new Set();
    for (let i = 0; i <= 100; i++) {
      const next = nextIndex(4, current, PlayMode.Random, false, false, i / 100);
      assert.notEqual(next, current); assert.ok(next >= 0 && next < 4); selected.add(next);
    }
    assert.equal(selected.size, 3);
  }
  assert.equal(nextIndex(3, 0, PlayMode.Random, false, false, NaN), 1);
});
test('voice parser recognizes synonyms, polite prefixes and play/search arguments', () => {
  const samples = [['请帮我播放下一首。', 'next', ''], ['上一曲', 'previous', ''],
    ['暂停播放', 'pause', ''], ['继续播放！', 'resume', ''], ['我想听晨光序曲', 'play', '晨光序曲'],
    ['播放星河回响这首歌', 'play', '星河回响'], ['搜索 雨中漫步', 'search', '雨中漫步'],
    ['play dawn', 'play', 'dawn'], ['search Alice', 'search', 'Alice']];
  for (const [text, action, query] of samples) assert.deepEqual(plain(parseVoiceCommand(text)), { action, query });
});
test('voice parser avoids executing negated, ambiguous or empty commands', () => {
  for (const text of ['', '不要播放雨中漫步', '别切歌', '搜索', '今天不要暂停', '随便聊聊']) {
    assert.equal(parseVoiceCommand(text).action, 'unknown');
  }
});
test('LRC reads repeated timestamps, sorts lines, handles fractional precision and metadata', () => {
  const lines = parseLrc('[ar:Demo]\n[00:12.3][00:02.34]重复\n[00:05.678]中间\nuntimed', 20000);
  assert.deepEqual(plain(lines.map((line) => line.start)), [2340, 5678, 12300]);
  assert.equal(lines[0].text, '重复'); assert.equal(lines[0].end, 5678);
  assert.equal(lines[2].end, 20000);
});
test('LRC ordinary timing is explicitly estimated and preserves emoji characters', () => {
  const lines = parseLrc('[00:00]你🙂好\n[00:03]下一行', 5000);
  assert.equal(lines[0].estimated, true); assert.equal(lines[0].words.length, 3);
  assert.deepEqual(plain(lines[0].words[1]), { text: '🙂', start: 1000, end: 2000 });
});
test('enhanced LRC preserves actual word boundaries and a terminal marker', () => {
  const line = parseLrc('[00:01]<00:01>你<00:01.40>好<00:02.25>\n[00:04]下一行', 6000)[0];
  assert.equal(line.estimated, false); assert.equal(line.text, '你好');
  assert.deepEqual(plain(line.words), [{ text: '你', start: 1000, end: 1400 }, { text: '好', start: 1400, end: 2250 }]);
});
test('LRC offsets are applied to line and enhanced word stamps, including clipping at zero', () => {
  let line = parseLrc('[offset:500]\n[00:01]<00:01>你<00:02>好<00:03>', 10000)[0];
  assert.equal(line.start, 1500); assert.equal(line.words[1].start, 2500);
  line = parseLrc('[00:01]<00:01>你<00:02.50>好<00:03>\n[offset:-2000]', 10000)[0];
  assert.equal(line.start, 0); assert.equal(line.words[1].start, 500); assert.equal(line.words[1].end, 1000);
});
test('repeated enhanced line stamps shift word timestamps consistently', () => {
  const lines = parseLrc('[00:01][00:06]<00:01>你<00:02>好<00:03>', 10000);
  assert.equal(lines[1].words[0].start, 6000); assert.equal(lines[1].words[1].end, 8000);
});
test('LRC clips final word to track duration and ignores lines starting beyond it', () => {
  const lines = parseLrc('[00:01]<00:01>一<00:20>二\n[00:40]过期', 3000);
  assert.equal(lines.length, 1); assert.equal(lines[0].end, 3000);
  assert.ok(lines[0].words.every((word) => word.start <= word.end && word.end <= 3000));
});
test('malformed timestamps do not become authoritative timing', () => {
  const lines = parseLrc('[00:99]无效\n[00:01]前缀<00:02>正文\n[00:03]<00:05>倒<00:04>序', 10000);
  assert.equal(lines.length, 2); assert.ok(lines.every((line) => line.estimated));
  assert.equal(parseLrc('not lyrics').length, 0);
  assert.equal(parseLrc('[offset:' + '9'.repeat(400) + ']\n[00:01]有限时间', 5000)[0].start, 1000);
});
test('lyric location follows seek in both directions and progress clamps to valid range', () => {
  const lines = parseLrc('[00:01]甲\n[00:03]乙\n[00:05]丙', 6000);
  assert.equal(findLyricIndex(lines, 999), -1); assert.equal(findLyricIndex(lines, 5000), 2);
  assert.equal(findLyricIndex(lines, 3000), 1); assert.equal(findLyricIndex([], 0), -1);
  assert.equal(findLyricIndex(lines, NaN), -1);
  const word = { text: '你', start: 1000, end: 2000 };
  assert.equal(wordProgress(word, 500), 0); assert.equal(wordProgress(word, 1500), 0.5);
  assert.equal(wordProgress(word, 3000), 1);
});
test('demo tracks are three unique 30-second rawfiles with explicitly estimated captions', () => {
  assert.equal(DEMO_SONGS.length, 3); assert.equal(new Set(DEMO_SONGS.map((song) => song.uri)).size, 3);
  for (const song of DEMO_SONGS) {
    assert.equal(song.duration, 30000); assert.match(song.uri, /^rawfile:\/\/(dawn|rain|stars)\.wav$/);
    assert.equal(parseLrc(song.lyrics, song.duration).length, 6);
    assert.ok(parseLrc(song.lyrics, song.duration).every((line) => line.estimated));
  }
});

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-music-model-'));
const dbPath = path.join(temp, 'music.sqlite');
let sqlDb = new DatabaseSync(dbPath);
let failOnce = null;
let openResults = 0;
class ResultSet {
  constructor(statement, args) {
    this.rows = statement.all(...args); this.columns = statement.columns().map((column) => column.name);
    this.at = -1; this.closed = false; openResults++;
  }
  goToNextRow() { return ++this.at < this.rows.length; }
  getColumnIndex(name) { return this.columns.indexOf(name); }
  getString(index) { return String(this.rows[this.at][this.columns[index]]); }
  getLong(index) { return Number(this.rows[this.at][this.columns[index]]); }
  close() { if (!this.closed) { this.closed = true; openResults--; } }
}
const adapter = {
  async executeSql(sql, args = []) {
    if (failOnce && sql.includes(failOnce)) { failOnce = null; throw new Error('injected SQL failure'); }
    sqlDb.prepare(sql).run(...args);
  },
  async querySql(sql, args = []) { return new ResultSet(sqlDb.prepare(sql), args); },
  async insert(table, values) {
    assert.equal(table, 'playlists');
    return Number(sqlDb.prepare('INSERT INTO playlists(name) VALUES(?)').run(values.name).lastInsertRowid);
  },
  beginTransaction() { sqlDb.exec('BEGIN IMMEDIATE'); },
  commit() { sqlDb.exec('COMMIT'); },
  rollBack() { sqlDb.exec('ROLLBACK'); },
  async close() { /* Adapter connection is managed by the test harness. */ }
};
const { MusicRepository } = load('MusicRepository.ets', {
  '@kit.ArkData': { relationalStore: { SecurityLevel: { S1: 1 }, async getRdbStore() { return adapter; } } },
  './MusicModels': model
});
let repo = new MusicRepository();
let playlist;
test('repository requires initialization and initializes real schema with seeds once', async () => {
  await assert.rejects(repo.listSongs(), /初始化/);
  await repo.init({}); await repo.init({});
  assert.equal((await repo.listSongs()).length, 3);
});
test('repository creates persistent playlists and rejects duplicate/invalid names', async () => {
  playlist = await repo.createPlaylist('  Focus  ');
  assert.equal(playlist.name, 'Focus'); assert.ok(playlist.id > 0);
  await assert.rejects(repo.createPlaylist('focus'), /同名/);
  await assert.rejects(repo.createPlaylist(' '), /名称/);
  await assert.rejects(repo.createPlaylist('字'.repeat(41)), /名称/);
});
test('repository parameter-binds quoted names, paths and injection-like titles', async () => {
  const song = makeSong('quote', "/sandbox/it’s 'quoted'.mp3"); song.title = "x'); DROP TABLE songs;--";
  await repo.saveSongs([song]);
  assert.equal((await repo.searchSongs('DROP TABLE'))[0].id, 'quote');
  const list = await repo.createPlaylist("It's fine; --");
  assert.equal((await repo.listPlaylists()).find((item) => item.id === list.id).name, "It's fine; --");
});
test('repository deduplicates URI while retaining the original ID and playlist membership', async () => {
  await repo.saveSongs([makeSong('original', '/sandbox/repeat.mp3')]);
  await repo.addToPlaylist(playlist.id, 'original');
  const revised = makeSong('different-id', '/sandbox/repeat.mp3'); revised.title = '修改标题';
  await repo.saveSongs([revised]);
  const matches = (await repo.listSongs()).filter((song) => song.uri === revised.uri);
  assert.equal(matches.length, 1); assert.equal(matches[0].id, 'original'); assert.equal(matches[0].title, '修改标题');
  assert.equal((await repo.playlistSongs(playlist.id))[0].id, 'original');
});
test('playlist membership deduplicates, keeps order and rejects nonexistent rows', async () => {
  await repo.addToPlaylist(playlist.id, 'demo-rain'); await repo.addToPlaylist(playlist.id, 'demo-rain');
  assert.deepEqual(plain((await repo.playlistSongs(playlist.id)).map((song) => song.id)), ['original', 'demo-rain']);
  assert.equal((await repo.listPlaylists()).find((item) => item.id === playlist.id).count, 2);
  await assert.rejects(repo.addToPlaylist(playlist.id, 'absent'), /不存在/);
  await assert.rejects(repo.addToPlaylist(9999, 'demo-rain'), /不存在/);
});
test('original filenames persist through RDB and remain when metadata updates omit the optional name', async () => {
  const song = makeSong('named', '/sandbox/hash.mp3'); song.title = '元数据标题'; song.fileName = '原始文件名.mp3';
  await repo.saveSongs([song]);
  assert.equal((await repo.searchSongs('原始文件名'))[0].id, 'named');
  delete song.fileName; await repo.saveSongs([song]);
  assert.equal((await repo.searchSongs('原始文件名'))[0].fileName, '原始文件名.mp3');
});
test('batch save rolls back on ID conflict and the operation queue recovers', async () => {
  const count = (await repo.listSongs()).length;
  await assert.rejects(repo.saveSongs([makeSong('rollback-new'), makeSong('original', '/sandbox/id-conflict.mp3')]));
  assert.equal((await repo.listSongs()).length, count);
  assert.equal((await repo.searchSongs('rollback-new')).length, 0);
  await repo.saveSongs([makeSong('after-error')]);
  assert.equal((await repo.searchSongs('after-error')).length, 1);
});
test('invalid durations reject before entering a transaction, including negative fractions', async () => {
  for (const duration of [-0.4, -1, Infinity, NaN]) {
    const song = makeSong('invalid'); song.duration = duration;
    await assert.rejects(repo.saveSongs([song]), /时长/);
  }
});
test('deleting a song atomically cleans all playlist memberships without foreign-key enforcement', async () => {
  const another = await repo.createPlaylist('Another'); await repo.addToPlaylist(another.id, 'original');
  failOnce = 'DELETE FROM songs';
  await assert.rejects(repo.deleteSong('original'), /injected/);
  assert.equal((await repo.playlistSongs(another.id)).length, 1);
  await repo.deleteSong('original');
  assert.equal((await repo.playlistSongs(another.id)).length, 0);
  assert.equal(sqlDb.prepare('SELECT COUNT(*) AS n FROM playlist_songs WHERE song_id = ?').get('original').n, 0);
});
test('deleting a playlist is atomic and removing one membership keeps the library song', async () => {
  await repo.removeFromPlaylist(playlist.id, 'demo-rain');
  assert.equal((await repo.playlistSongs(playlist.id)).length, 0);
  assert.ok((await repo.listSongs()).some((song) => song.id === 'demo-rain'));
  await repo.addToPlaylist(playlist.id, 'demo-stars');
  failOnce = 'DELETE FROM playlists';
  await assert.rejects(repo.deletePlaylist(playlist.id), /injected/);
  assert.equal((await repo.playlistSongs(playlist.id)).length, 1);
  await repo.deletePlaylist(playlist.id);
  assert.equal((await repo.listPlaylists()).some((item) => item.id === playlist.id), false);
  assert.equal(sqlDb.prepare('SELECT COUNT(*) AS n FROM playlist_songs WHERE playlist_id = ?').get(playlist.id).n, 0);
});
test('database data persists after closing/reopening and deleted demos do not reappear', async () => {
  await repo.deleteSong('demo-dawn');
  const before = plain(await repo.listSongs());
  sqlDb.close(); sqlDb = new DatabaseSync(dbPath); repo = new MusicRepository();
  await repo.init({});
  assert.deepEqual(plain(await repo.listSongs()), before);
  assert.ok((await repo.listPlaylists()).length > 0);
});
test('concurrent saves and memberships serialize correctly and close all result sets', async () => {
  await Promise.all([repo.saveSongs([makeSong('parallel-a')]), repo.saveSongs([makeSong('parallel-b')])]);
  const list = await repo.createPlaylist('Concurrent');
  await Promise.all([repo.addToPlaylist(list.id, 'parallel-a'), repo.addToPlaylist(list.id, 'parallel-b')]);
  assert.deepEqual(plain((await repo.playlistSongs(list.id)).map((song) => song.id)), ['parallel-a', 'parallel-b']);
  assert.equal(openResults, 0);
});

test('existing databases upgrade the filename column without losing songs or playlists', async () => {
  const before = (await repo.listSongs()).length; const lists = (await repo.listPlaylists()).length;
  await repo.close(); sqlDb.exec('ALTER TABLE songs DROP COLUMN file_name');
  repo = new MusicRepository(); await repo.init({});
  assert.equal((await repo.listSongs()).length, before); assert.equal((await repo.listPlaylists()).length, lists);
  assert.ok((await repo.listSongs()).every((song) => song.fileName === ''));
  assert.equal(openResults, 0);
});

(async () => {
  let passed = 0;
  try {
    for (const item of cases) {
      try { await item.run(); console.log(`PASS ${item.name}`); passed++; }
      catch (error) { console.error(`FAIL ${item.name}`); console.error(error); process.exitCode = 1; }
    }
    console.log(`Music model / SQLite contract tests: ${passed}/${cases.length} passed.`);
  } finally {
    sqlDb.close();
    const cleanupPath = path.resolve(temp);
    assert.equal(path.dirname(cleanupPath), path.resolve(os.tmpdir()));
    assert.ok(path.basename(cleanupPath).startsWith('codex-music-model-'));
    fs.rmSync(cleanupPath, { recursive: true, force: true });
  }
})();
