import { describe, it, expect } from '@ohos/hypium';
import { getTestContext } from './TestContext';
import { relationalStore } from '@kit.ArkData';
import { Song } from '../../../main/ets/model/MusicModels';
import { MusicRepository } from '../../../main/ets/model/MusicRepository';

function sampleSong(id: string, uri: string = '/sandbox/track.mp3'): Song {
  return { id: id, title: '测试曲目', artist: '测试音乐人', album: '独立测试库', uri: uri,
    fileName: 'Original Song.mp3', duration: 30000, cover: '', lyrics: '[00:00]测试配文' };
}

async function assertRejected(operation: () => Promise<void>): Promise<void> {
  let rejected = false;
  try {
    await operation();
  } catch (error) {
    rejected = true;
  }
  expect(rejected).assertTrue();
}

// Each case uses a unique database. The user's codex_music.db and music files are untouched.
export default function musicRepositoryTest(): void {
  describe('MusicRepositoryDeviceRdb', () => {
    it('persistsSongsPlaylistsAndOriginalNamesAcrossDatabaseReopen', 0, async () => {
      const context = await getTestContext();
      const name = 'test_music_persistence_' + Date.now() + '.db';
      let repository = new MusicRepository(name);
      try {
        await repository.init(context);
        expect((await repository.listSongs()).length).assertEqual(3);
        const song = sampleSong('original');
        song.title = "含单引号 ' 的曲目";
        await repository.saveSongs([song]);
        const playlist = await repository.createPlaylist("学习 ' 专用");
        await repository.addToPlaylist(playlist.id, song.id);
        await repository.addToPlaylist(playlist.id, song.id);
        const duplicate = sampleSong('different-id');
        duplicate.title = '更新后的标题';
        await repository.saveSongs([duplicate]);
        expect((await repository.listSongs()).length).assertEqual(4);
        expect((await repository.playlistSongs(playlist.id))[0].id).assertEqual('original');
        expect((await repository.listPlaylists())[0].count).assertEqual(1);
        await repository.deleteSong('demo-dawn');
        await repository.close();
        repository = new MusicRepository(name);
        await repository.init(context);
        expect((await repository.listSongs()).length).assertEqual(3);
        const found = await repository.searchSongs('original song');
        expect(found.length).assertEqual(1);
        expect(found[0].title).assertEqual('更新后的标题');
        expect(found[0].fileName).assertEqual('Original Song.mp3');
        expect((await repository.playlistSongs(playlist.id))[0].id).assertEqual('original');
      } finally {
        await repository.close();
        await relationalStore.deleteRdbStore(context, name);
      }
    });

    it('rollsBackFailedBatchAndContinuesProcessingLaterWrites', 0, async () => {
      const context = await getTestContext();
      const name = 'test_music_rollback_' + Date.now() + '.db';
      const repository = new MusicRepository(name);
      try {
        await repository.init(context);
        await repository.saveSongs([sampleSong('original')]);
        const count = (await repository.listSongs()).length;
        await assertRejected(async () => {
          await repository.saveSongs([sampleSong('must-rollback', '/sandbox/new.mp3'),
            sampleSong('original', '/sandbox/conflict.mp3')]);
        });
        expect((await repository.listSongs()).length).assertEqual(count);
        expect((await repository.listSongs()).some((song: Song) => song.id === 'must-rollback')).assertEqual(false);
        await repository.saveSongs([sampleSong('next-write', '/sandbox/success.mp3')]);
        expect((await repository.listSongs()).length).assertEqual(count + 1);
        const invalid = sampleSong('invalid');
        invalid.duration = -0.4;
        await assertRejected(async () => { await repository.saveSongs([invalid]); });
      } finally {
        await repository.close();
        await relationalStore.deleteRdbStore(context, name);
      }
    });

    it('cleansRelationsAndSerializesConcurrentPlaylistChanges', 0, async () => {
      const context = await getTestContext();
      const name = 'test_music_relations_' + Date.now() + '.db';
      const repository = new MusicRepository(name);
      try {
        await repository.init(context);
        const first = await repository.createPlaylist('First');
        const second = await repository.createPlaylist('Second');
        await Promise.all([repository.addToPlaylist(first.id, 'demo-dawn'),
          repository.addToPlaylist(first.id, 'demo-rain'), repository.addToPlaylist(second.id, 'demo-dawn')]);
        expect((await repository.playlistSongs(first.id)).length).assertEqual(2);
        await repository.removeFromPlaylist(first.id, 'demo-rain');
        expect((await repository.listSongs()).length).assertEqual(3);
        await repository.deleteSong('demo-dawn');
        expect((await repository.playlistSongs(first.id)).length).assertEqual(0);
        expect((await repository.playlistSongs(second.id)).length).assertEqual(0);
        await repository.addToPlaylist(first.id, 'demo-stars');
        await repository.deletePlaylist(first.id);
        expect((await repository.listPlaylists()).length).assertEqual(1);
        expect((await repository.playlistSongs(first.id)).length).assertEqual(0);
        await assertRejected(async () => { await repository.addToPlaylist(first.id, 'demo-stars'); });
        await assertRejected(async () => { await repository.createPlaylist('second'); });
      } finally {
        await repository.close();
        await relationalStore.deleteRdbStore(context, name);
      }
    });

    it('upgradesLegacySchemaWithoutDeletingExistingSongs', 0, async () => {
      const context = await getTestContext();
      const name = 'test_music_migration_' + Date.now() + '.db';
      const config: relationalStore.StoreConfig = { name: name, securityLevel: relationalStore.SecurityLevel.S1 };
      const legacy = await relationalStore.getRdbStore(context, config);
      const repository = new MusicRepository(name);
      try {
        await legacy.executeSql('CREATE TABLE songs (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, ' +
          'artist TEXT NOT NULL, album TEXT NOT NULL, uri TEXT NOT NULL UNIQUE, duration INTEGER NOT NULL, ' +
          'cover TEXT NOT NULL, lyrics TEXT NOT NULL)');
        await legacy.executeSql('INSERT INTO songs VALUES (?,?,?,?,?,?,?,?)',
          ['legacy', '旧曲目', '音乐人', '旧专辑', '/sandbox/old.mp3', 30000, '', '']);
        await legacy.close();
        await repository.init(context);
        const found = await repository.searchSongs('旧曲目');
        expect(found.length).assertEqual(1);
        expect(found[0].id).assertEqual('legacy');
        expect(found[0].fileName).assertEqual('');
      } finally {
        await repository.close();
        await relationalStore.deleteRdbStore(context, name);
      }
    });
  });
}
