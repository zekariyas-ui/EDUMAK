# EDUMAK — Cloud-connected Digital Library

EDUMAK is a responsive web app/PWA for students and administrators. The app uses Supabase for shared accounts, library catalogue data, borrowing records, private PDF storage, and shared dataset storage.

## Source package

The repository currently contains the original application archive:
- `EDUMAK_Cloud_App_FINAL.zip`

The updated working package was reviewed separately. It contains the app source, a dataset migration, and setup documentation. Do not treat this README commit as a deployment: the Supabase project still needs configuration and the updated source package must be published to the repository before hosting.

## Cloud features in the updated working package

- Student registration and sign-in, with role-based administrator access.
- Book catalogue and borrowing/return records.
- Server-generated 72-hour loan due times with a live countdown and overdue state.
- Private PDF storage with short-lived signed links.
- Shared CSV, JSON, XLSX, and XLS dataset catalogue with version history.
- Supabase Realtime catalogue refresh, plus a six-hour refresh fallback.
- Installable PWA shell.

## Setup requirements

1. Create or select the Supabase project.
2. For a new database, run `database_setup.sql`. For an existing EDUMAK database, run `migration_datasets.sql` only for the dataset addition.
3. Put only the public Supabase anon/publishable key in `config.js`. Never expose a service-role/secret key.
4. Promote the first administrator using the trusted Supabase Dashboard SQL procedure in `SETUP_GUIDE.txt`.
5. Host the app files together on an HTTPS static host.
6. Test registration, student/admin access, borrowing, returns, PDF access, dataset uploads/downloads, and realtime refresh before public release.

## Important limitations

- This repository branch is a work-in-progress; this commit does not deploy the app.
- Supabase configuration, SQL execution, hosting, and real-device testing require the project owner's action.
- Six-hour refresh is a fallback while the app is open; it is not operating-system push notification delivery.
- Never put a Supabase service-role/secret key in browser code.

