import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';

// Native RDB requires a real stage UIAbility context; the test runner's app
// context can be a proxy and is rejected with "Illegal context" on devices.
export async function getTestContext(): Promise<common.UIAbilityContext> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      return (await delegator.getCurrentTopAbility()).context;
    } catch (error) {
      if (attempt === 0) {
        await delegator.startAbility({
          bundleName: 'cn.gdut.codexmusic',
          abilityName: 'EntryAbility'
        });
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, 200); });
    }
  }
  throw new Error('未能取得音乐应用的 UIAbility 存储上下文');
}
