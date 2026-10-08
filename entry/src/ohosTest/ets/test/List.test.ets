import musicModelTest from './MusicModel.test';
import musicRepositoryTest from './MusicRepository.test';

export default function testsuite(): void {
  musicModelTest();
  musicRepositoryTest();
}
