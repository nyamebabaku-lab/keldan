// Keldan Properties Limited — one company and its tenants (independent of Efie Wura Pro).
// Which build: 'live' (real accounts, Supabase schema "keldan") or 'demo' (sample data in the browser).
export const MODE = import.meta.env.VITE_APP || 'demo';
export const LIVE = MODE === 'live';
export const SITE = 'https://nyamebabaku-lab.github.io/keldan/';
export const DEMO_SITE = `${SITE}demo/`;
/** Phone-only accounts sign in with this stand-in email behind the scenes. */
export const PHONE_DOMAIN = 'phone.keldan.app';
/** The company's join code (tenants/staff are matched by phone, so nobody types it). */
export const COMPANY_CODE = 'KELDAN';
export const COMPANY = 'Keldan Properties Limited';

/** Android apps: 'tenant' | 'manager' (owner + staff). Empty on the website (everyone). */
export const APP_ROLE = import.meta.env.VITE_ROLE || '';
export const IS_NATIVE = typeof window !== 'undefined' && !!window.Capacitor?.isNativePlatform?.();
const RELEASES = 'https://github.com/nyamebabaku-lab/keldan/releases/latest/download/';
export const APKS = {
  tenant: { name: 'Keldan Properties', who: 'Tenants', url: `${RELEASES}KeldanProperties.apk` },
  manager: { name: 'Keldan Manager', who: 'Owner, managers & caretakers', url: `${RELEASES}KeldanManager.apk` },
};
/** Which app a signed-in role belongs to. */
export const appForRole = (role) => (role === 'tenant' ? 'tenant' : 'manager');
export const APP_NAME = APP_ROLE ? APKS[APP_ROLE].name : COMPANY;
