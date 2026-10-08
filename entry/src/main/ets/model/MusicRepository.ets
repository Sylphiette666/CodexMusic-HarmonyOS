import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Song, Playlist, DEMO_SONGS, filterSongs } from './MusicModels';

// A real HarmonyOS RDB. Parameter binding protects names, titles and paths containing quotes.
// All operations share a queue: reads cannot observe partially completed transactions.
export class MusicRepository {
  private store: relationalStore.RdbStore | null = null;
  private static queue: Promise<void> = Promise.resolve();
  private storageName: string;

  constructor(storageName: string = 'codex_music.db') {
    this.storageName = storageName;
  }

  async init(context: common.Context): Promise<void> {
    return this.enqueue(async () => {
      if (this.store !== null) {
        return;
      }
      const config: relationalStore.StoreConfig = {
        name: this.storageName, securityLevel: relationalStore.SecurityLevel.S1
      };
      const database = await relationalStore.getRdbStore(context, config);
      await database.executeSql('CREATE TABLE IF NOT EXISTS songs (' +
        'id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL, ' +
        'uri TEXT NOT NULL UNIQUE, duration INTEGER NOT NULL CHECK(duration >= 0), ' +
        "cover TEXT NOT NULL, lyrics TEXT NOT NULL, file_name TEXT NOT NULL DEFAULT '')");
      const columns = await database.querySql('PRAGMA table_info(songs)');
      let hasFileName = false;
      try {
        while (columns.goToNextRow()) {
          if (columns.getString(columns.getColumnIndex('name')) === 'file_name') {
            hasFileName = true;
          }
        }
      } finally {
        columns.close();
      }
      if (!hasFileName) {
        await database.executeSql("ALTER TABLE songs ADD COLUMN file_name TEXT NOT NULL DEFAULT ''");
      }
      await database.executeSql('CREATE TABLE IF NOT EXISTS playlists (' +
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL COLLATE NOCASE UNIQUE)');
      await database.executeSql('CREATE TABLE IF NOT EXISTS playlist_songs (' +
        'playlist_id INTEGER NOT NULL, song_id TEXT NOT NULL, position INTEGER NOT NULL, ' +
        'PRIMARY KEY(playlist_id, song_id), FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE, ' +
        'FOREIGN KEY(song_id) REFERENCES songs(id) ON DELETE CASCADE)');
      await database.executeSql('CREATE TABLE IF NOT EXISTS music_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      const marker = await database.querySql('SELECT value FROM music_meta WHERE key = ?', ['seeded']);
      let seeded = false;
      try {
        seeded = marker.goToNextRow();
      } finally {
        marker.close();
      }
      if (!seeded) {
        database.beginTransaction();
        try {
          for (let index = 0; index < DEMO_SONGS.length; index++) {
            await this.writeSong(database, DEMO_SONGS[index]);
          }
          await database.executeSql('INSERT INTO music_meta (key, value) VALUES (?, ?)', ['seeded', '1']);
          database.commit();
        } catch (error) {
          database.rollBack();
          throw error as Error;
        }
      }
      this.store = database;
    });
  }

  async close(): Promise<void> {
    return this.enqueue(async () => {
      if (this.store !== null) {
        await this.store.close();
        this.store = null;
      }
    });
  }

  async listSongs(): Promise<Song[]> {
    return this.enqueue(async () => this.readSongs(this.database(), 'SELECT * FROM songs ORDER BY rowid', []));
  }

  async searchSongs(query: string): Promise<Song[]> {
    return filterSongs(await this.listSongs(), query);
  }

  async saveSongs(songs: Song[]): Promise<void> {
    // Copy before enqueueing so caller mutations cannot change the pending operation.
    songs.forEach((song: Song) => this.validateSong(song));
    const copies: Song[] = songs.map((song: Song) => this.copySong(song));
    return this.enqueue(async () => {
      const database = this.database();
      database.beginTransaction();
      try {
        for (let index = 0; index < copies.length; index++) {
          await this.writeSong(database, copies[index]);
        }
        database.commit();
      } catch (error) {
        database.rollBack();
        throw error as Error;
      }
    });
  }

  async deleteSong(songId: string): Promise<void> {
    return this.enqueue(async () => {
      const database = this.database();
      database.beginTransaction();
      try {
        // Explicit cleanup is atomic even if this device's RDB foreign-key pragma is off.
        await database.executeSql('DELETE FROM playlist_songs WHERE song_id = ?', [songId]);
        await database.executeSql('DELETE FROM songs WHERE id = ?', [songId]);
        database.commit();
      } catch (error) {
        database.rollBack();
        throw error as Error;
      }
    });
  }

  async createPlaylist(name: string): Promise<Playlist> {
    const cleaned = name.trim();
    if (cleaned.length < 1 || cleaned.length > 40) {
      throw new Error('歌单名称需要 1 至 40 个字符');
    }
    return this.enqueue(async () => {
      const database = this.database();
      const existing = await database.querySql('SELECT id FROM playlists WHERE name = ? COLLATE NOCASE', [cleaned]);
      try {
        if (existing.goToNextRow()) {
          throw new Error('已存在同名歌单');
        }
      } finally {
        existing.close();
      }
      const values: relationalStore.ValuesBucket = { name: cleaned };
      const id = await database.insert('playlists', values);
      const playlist: Playlist = { id: id, name: cleaned, count: 0 };
      return playlist;
    });
  }

  async listPlaylists(): Promise<Playlist[]> {
    return this.enqueue(async () => {
      const result = await this.database().querySql('SELECT p.id, p.name, COUNT(s.song_id) AS song_count ' +
        'FROM playlists p LEFT JOIN playlist_songs s ON p.id = s.playlist_id ' +
        'GROUP BY p.id, p.name ORDER BY p.id');
      const playlists: Playlist[] = [];
      try {
        while (result.goToNextRow()) {
          playlists.push({ id: result.getLong(result.getColumnIndex('id')),
            name: result.getString(result.getColumnIndex('name')),
            count: result.getLong(result.getColumnIndex('song_count')) });
        }
      } finally {
        result.close();
      }
      return playlists;
    });
  }

  async deletePlaylist(id: number): Promise<void> {
    return this.enqueue(async () => {
      const database = this.database();
      database.beginTransaction();
      try {
        await database.executeSql('DELETE FROM playlist_songs WHERE playlist_id = ?', [id]);
        await database.executeSql('DELETE FROM playlists WHERE id = ?', [id]);
        database.commit();
      } catch (error) {
        database.rollBack();
        throw error as Error;
      }
    });
  }

  async addToPlaylist(playlistId: number, songId: string): Promise<void> {
    return this.enqueue(async () => {
      const database = this.database();
      const existing = await database.querySql('SELECT p.id FROM playlists p, songs s WHERE p.id = ? AND s.id = ?',
        [playlistId, songId]);
      try {
        if (!existing.goToNextRow()) {
          throw new Error('歌曲或歌单已不存在，请刷新后重试');
        }
      } finally {
        existing.close();
      }
      await database.executeSql('INSERT OR IGNORE INTO playlist_songs (playlist_id, song_id, position) ' +
        'SELECT ?, ?, COALESCE(MAX(position), -1) + 1 FROM playlist_songs WHERE playlist_id = ?',
        [playlistId, songId, playlistId]);
    });
  }

  async removeFromPlaylist(playlistId: number, songId: string): Promise<void> {
    return this.enqueue(async () => {
      await this.database().executeSql('DELETE FROM playlist_songs WHERE playlist_id = ? AND song_id = ?',
        [playlistId, songId]);
    });
  }

  async playlistSongs(playlistId: number): Promise<Song[]> {
    return this.enqueue(async () => this.readSongs(this.database(),
      'SELECT s.* FROM songs s INNER JOIN playlist_songs p ON s.id = p.song_id ' +
      'WHERE p.playlist_id = ? ORDER BY p.position, s.id', [playlistId]));
  }

  private database(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('音乐数据库尚未初始化');
    }
    return this.store;
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = MusicRepository.queue.then(operation);
    MusicRepository.queue = result.then(() => {}, () => {});
    return result;
  }

  private validateSong(song: Song): void {
    if (song.id.trim().length === 0 || song.uri.trim().length === 0 || song.title.trim().length === 0 ||
      !Number.isFinite(song.duration) || song.duration < 0) {
      throw new Error('歌曲信息不完整或时长无效');
    }
  }

  private copySong(song: Song): Song {
    return { id: song.id, title: song.title, artist: song.artist, album: song.album,
      uri: song.uri, duration: Math.round(song.duration), cover: song.cover, lyrics: song.lyrics,
      fileName: song.fileName ?? '' };
  }

  private async writeSong(database: relationalStore.RdbStore, song: Song): Promise<void> {
    // Deduplicate by persistent URI. Keep the existing ID and its playlist memberships.
    // Avoid INSERT OR REPLACE: it deletes the old record before inserting the replacement.
    await database.executeSql('INSERT INTO songs (id,title,artist,album,uri,duration,cover,lyrics,file_name) ' +
      'VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(uri) DO UPDATE SET title=excluded.title, ' +
      'artist=excluded.artist, album=excluded.album, duration=excluded.duration, ' +
      'cover=excluded.cover, lyrics=excluded.lyrics, ' +
      "file_name=CASE WHEN excluded.file_name <> '' THEN excluded.file_name ELSE songs.file_name END",
      [song.id, song.title, song.artist, song.album, song.uri, song.duration, song.cover, song.lyrics, song.fileName ?? '']);
  }

  private async readSongs(database: relationalStore.RdbStore, sql: string,
    args: relationalStore.ValueType[]): Promise<Song[]> {
    const result = await database.querySql(sql, args);
    const songs: Song[] = [];
    try {
      while (result.goToNextRow()) {
        songs.push({ id: result.getString(result.getColumnIndex('id')),
          title: result.getString(result.getColumnIndex('title')),
          artist: result.getString(result.getColumnIndex('artist')),
          album: result.getString(result.getColumnIndex('album')),
          uri: result.getString(result.getColumnIndex('uri')),
          duration: result.getLong(result.getColumnIndex('duration')),
          cover: result.getString(result.getColumnIndex('cover')),
          lyrics: result.getString(result.getColumnIndex('lyrics')),
          fileName: result.getString(result.getColumnIndex('file_name')) });
      }
    } finally {
      result.close();
    }
    return songs;
  }
}

