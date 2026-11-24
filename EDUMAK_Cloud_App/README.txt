EDUMAK — Cloud-connected Digital Library
========================================

This is a responsive web app/PWA for Android phones and computers.
It uses Supabase for shared accounts, books, loans, and PDF storage.

Included features
- Student registration and login
- Separate administrator login (role-controlled in Supabase)
- Admin book registration, editing, deletion, and quantity management
- Librarian-only lending: the librarian records borrowing and returns on the Lending Desk
  (existing catalogue book or manual entry); the database sets a 72-hour due time
- Student phone view (view-only) of their own loans, due dates, return dates and a live
  countdown with active / due soon / overdue / returned status
- Shared PDF upload and access through private Supabase Storage
- Shared CSV, JSON, XLSX and XLS dataset uploads with version history
- Live Realtime updates, a six-hour refresh while the app is open, a last-synced time,
  a Refresh button and an offline indicator (old data is kept if a refresh fails)
- Installable PWA shell for compatible browsers

IMPORTANT
The ZIP is the app source, not a prebuilt Android APK. Cloud functions will
not work until the Supabase setup below is completed and the app is hosted
on an HTTPS website. The supplied Supabase URL is already in config.js,
but the public anon/publishable key is intentionally a placeholder.

Security
Never put a Supabase service_role/secret key in config.js. Only use the
project's public anon/publishable key. Do not share administrator passwords.

Final review note
-----------------
The SQL setup includes protected role promotion, authenticated loan returns,
and restricted RPC execution. The database, public key, hosting and device
tests still require the project owner's Supabase dashboard and deployment.

Run database_setup.sql, then every file in the migrations/ folder in numeric order.
Migration 002 is required: it makes borrowing and returning librarian-only.
Migration 003 is required: it protects borrowing history and adds audited corrections.
See SETUP_GUIDE.txt for the safe sequence for new and existing projects.
