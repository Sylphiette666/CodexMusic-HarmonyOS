import { describe, it, expect } from '@ohos/hypium';
import { Song, PlayMode, filterSongs, nextIndex, parseVoiceCommand } from '../../../main/ets/model/MusicModels';
import { parseLrc, findLyricIndex, wordProgress } from '../../../main/ets/model/Lyrics';

export default function musicModelTest(): void {
  describe('MusicModel', () => {
    it('searchesMetadataAndOriginalFilenameAfterHashing', 0, () => {
      const song: Song = { id: 'a', title: '雨中漫步', artist: 'Alice', album: 'Blue',
        uri: '/sandbox/123abc.mp3', fileName: 'Summer.MP3', duration: 30000, cover: '', lyrics: '' };
      expect(filterSongs([song], 'ALICE summer').length).assertEqual(1);
      expect(filterSongs([song], 'Blue').length).assertEqual(1);
      expect(filterSongs([song], '雨中').length).assertEqual(1);
      expect(filterSongs([song], '无匹配').length).assertEqual(0);
    });

    it('sequenceStopsAtEndAndRepeatOneAllowsManualSkip', 0, () => {
      expect(nextIndex(3, 2, PlayMode.Sequence, false, true)).assertEqual(-1);
      expect(nextIndex(1, 0, PlayMode.Sequence, false, true)).assertEqual(-1);
      expect(nextIndex(3, 2, PlayMode.Sequence)).assertEqual(0);
      expect(nextIndex(3, 0, PlayMode.Sequence, true)).assertEqual(2);
      expect(nextIndex(3, 1, PlayMode.RepeatOne, false, true)).assertEqual(1);
      expect(nextIndex(3, 1, PlayMode.RepeatOne)).assertEqual(2);
      expect(nextIndex(0, -1, PlayMode.Sequence)).assertEqual(-1);
    });

    it('randomSkipsCurrentAndHandlesBoundarySamples', 0, () => {
      for (let current = 0; current < 3; current++) {
        for (let sample = 0; sample <= 10; sample++) {
          const next = nextIndex(3, current, PlayMode.Random, false, false, sample / 10);
          expect(next !== current && next >= 0 && next < 3).assertTrue();
        }
      }
    });

    it('voiceParsesActionsQueriesAndRejectsNegation', 0, () => {
      expect(parseVoiceCommand('请帮我播放下一首。').action).assertEqual('next');
      expect(parseVoiceCommand('上一曲').action).assertEqual('previous');
      expect(parseVoiceCommand('暂停播放').action).assertEqual('pause');
      expect(parseVoiceCommand('继续播放').action).assertEqual('resume');
      expect(parseVoiceCommand('播放星河回响').query).assertEqual('星河回响');
      expect(parseVoiceCommand('搜索 雨中').action).assertEqual('search');
      expect(parseVoiceCommand('不要播放晨光序曲').action).assertEqual('unknown');
      expect(parseVoiceCommand('搜索').action).assertEqual('unknown');
    });

    it('lrcSortsMultipleStampsAndLabelsEstimatedCharacterTiming', 0, () => {
      const lines = parseLrc('[ar:test]\n[00:05][00:01]你🙂好\n[00:03]中间', 8000);
      expect(lines.length).assertEqual(3);
      expect(lines[0].start).assertEqual(1000);
      expect(lines[0].words.length).assertEqual(3);
      expect(lines[0].estimated).assertTrue();
      expect(lines[2].end).assertEqual(8000);
      expect(findLyricIndex(lines, 999)).assertEqual(-1);
      expect(findLyricIndex(lines, 5000)).assertEqual(2);
      expect(findLyricIndex(lines, 3000)).assertEqual(1);
    });

    it('enhancedLrcHonorsOffsetWordBoundariesAndDuration', 0, () => {
      const lines = parseLrc('[offset:-2000]\n[00:01]<00:01>你<00:02.50>好<00:04>\n[00:20]忽略', 1500);
      expect(lines.length).assertEqual(1);
      expect(lines[0].estimated).assertEqual(false);
      expect(lines[0].start).assertEqual(0);
      expect(lines[0].words[1].start).assertEqual(500);
      expect(lines[0].words[1].end).assertEqual(1500);
      expect(wordProgress(lines[0].words[1], 1000)).assertEqual(0.5);
      expect(wordProgress(lines[0].words[1], 1600)).assertEqual(1);
    });
  });
}
