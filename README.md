# Keldan Properties Limited — rental app

Your Comfort, Our Priority. Tenants pay rent by MoMo or card, get receipts, sign their tenancy and report repairs; the owner and staff manage properties, tenancies, rent, repairs, expenses, SMS and reports. Independent single-company edition of Efie Wura Pro: rent goes straight into Keldan's own Paystack or Hubtel account (no platform fee or wallet).

- **Live app:** https://nyamebabaku-lab.github.io/keldan/ · **Demo:** https://nyamebabaku-lab.github.io/keldan/demo/
- **Android:** `KeldanProperties.apk` (tenants) and `KeldanManager.apk` (owner + staff) from the latest GitHub release.
- **Database:** Supabase project `jepkzvunetajsgscoelv`, schema `keldan` (`supabase/migrations`). Functions `keldan-pay`, `keldan-webhook`, `keldan-sms`.
- **Secrets** (Supabase → Edge Functions): `KELDAN_PAYSTACK_SECRET_KEY` or `KELDAN_HUBTEL_API_ID` / `KELDAN_HUBTEL_API_KEY` / `KELDAN_HUBTEL_POS_SALES_ID`; SMS `KELDAN_MNOTIFY_API_KEY` / `KELDAN_MNOTIFY_SENDER_ID`. Paystack webhook: `https://jepkzvunetajsgscoelv.supabase.co/functions/v1/keldan-webhook?p=paystack`.
- **First-time set-up:** sign up with the reserved email in the Manager app → "First-time set-up". Hand over later in Staff → crown button.

```bash
npm install
npm run dev        # live app (needs .env.local)
npm run dev:demo   # demo with Keldan sample data
```
