import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { playerService } from '../services/PlayerService';
export default class EntryAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
  }
  onDestroy(): void { playerService.dispose(); }
}
