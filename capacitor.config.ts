// Two Android apps: APP=tenant (default) → Keldan Properties, APP=manager → Keldan Manager (owner + staff).
import type { CapacitorConfig } from '@capacitor/cli';

const APP = (process.env.APP || 'tenant') as 'tenant' | 'manager';
const META = {
  tenant: { id: 'com.keldan.tenant', name: 'Keldan Properties' },
  manager: { id: 'com.keldan.manager', name: 'Keldan Manager' },
}[APP];

const config: CapacitorConfig = {
  appId: META.id,
  appName: META.name,
  webDir: `build/${APP}`,
  android: { path: `android-${APP}`, backgroundColor: '#064e33' },
  plugins: {
    SplashScreen: { launchShowDuration: 1500, launchAutoHide: true, backgroundColor: '#064e33', androidScaleType: 'CENTER_CROP', showSpinner: false },
    StatusBar: { backgroundColor: '#064e33', style: 'DARK' },
  },
};

export default config;
