# EDUMAK — Cloud-connected Digital Library

EDUMAK is a responsive web app/PWA for students and administrators. Supabase provides shared authentication, catalogue data, borrowing records, private PDF storage, and versioned shared datasets.

## Current source layout

- `EDUMAK_Cloud_App/` — deployable static app source and database scripts.
- `EDUMAK_Cloud_App/migrations/` — ordered database upgrades for existing projects.
- `tests/js/` — client tests using jsdom and a mocked Supabase client.
- `tests/sql/` — PostgreSQL scratch-database tests; these do not connect to a live Supabase project.
- `EDUMAK_Cloud_App_FINAL.zip` — earlier baseline archive used by the legacy-upgrade tests; it is not the latest working source.

## Cloud features in the working source

- Student registration and sign-in, with administrator-only controls.
- Shared book catalogue and librarian-controlled lending/returns.
- Manual loan entries saved as loan snapshots without adding catalogue books.
- Database-generated 72-hour due times and student countdowns based on server time.
- Student loan reads limited to the signed-in student's own records.
- Database protections for copy counts, duplicate active loans, and immutable borrowing history with audited corrections.
- Private PDF storage with temporary signed links.
- Shared CSV, JSON, XLSX, and XLS datasets with version history.
- Supabase Realtime refresh and a six-hour fallback while the app is open.
- Installable PWA shell.

## Setup

Read `EDUMAK_Cloud_App/SETUP_GUIDE.txt` before configuring or publishing the app. In short:

1. Configure the public Supabase project URL/key in `EDUMAK_Cloud_App/config.js`. Never put a service-role/secret key in browser code.
2. For a new database, run `database_setup.sql`, then migrations `001`, `002`, and `003` in numeric order. For an existing database, run only the missing migrations as explained in the setup guide.
3. Create the first administrator using the trusted Supabase Dashboard procedure in the setup guide.
4. Host the contents of `EDUMAK_Cloud_App/` together on an HTTPS static host.
5. Test student and administrator accounts, borrowing, returns, storage access, synchronization, and real devices before public use.

## Important limitations

- The source package does not deploy itself or apply database migrations.
- No claim is made that the current Supabase project is configured, migrations are applied, or hosting is live.
- The automated suites use scratch/mock environments, not a real Supabase project or physical phone.
- The six-hour refresh is not operating-system push notification delivery.
