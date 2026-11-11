import { cx } from '../ui';

const B = import.meta.env.BASE_URL;

/** The Keldan hexagon badge (also used as the app icon). */
export function EfieMark({ className }) {
  return <img src={`${B}keldan-badge.png`} alt="Keldan" className={cx('object-contain', className)} />;
}

/** The full Keldan logo (badge + wordmark). `light` puts it on a white pill for dark backgrounds. */
export function EfieLogo({ className, light, owner }) {
  const src = owner?.logoWide || `${B}keldan-logo.png`;
  return (
    <div className={cx('flex items-center', light && 'rounded-2xl bg-white/95 px-3 py-1.5 shadow-lg', className)}>
      <img src={src} alt="Keldan Properties Limited" className="h-10 w-auto object-contain sm:h-11" />
    </div>
  );
}

/** The company's (square) logo, editable in Settings → Branding. */
export function CompanyLogo({ owner, className, size = 'md' }) {
  const sz = { sm: 'h-8 w-8 text-xs', md: 'h-10 w-10 text-sm', lg: 'h-16 w-16 text-xl', xl: 'h-24 w-24 text-3xl' }[size];
  const src = owner?.logo || `${B}keldan-badge.png`;
  return <img src={src} alt={owner?.company || 'Keldan'} className={cx('shrink-0 object-contain drop-shadow-sm', sz, className)} />;
}

/** Wide logo for documents (receipts, agreements, reports). */
export function WideLogo({ owner, className }) {
  const src = owner?.logoWide || `${B}keldan-logo.png`;
  return <img src={src} alt={owner?.company || 'Keldan'} className={cx('h-12 w-auto rounded-lg bg-white object-contain p-1', className)} />;
}
