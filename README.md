# MISTER — guida di deploy (tutto gratuito)

Stack: PWA statica (`public/`) su GitHub Pages · Supabase (Postgres + Auth + Realtime + Edge Function) · Web Push.

## 1. Supabase (5 min)
1. supabase.com → New project (piano Free). Annota **Project URL** e chiave **anon** (Settings → API).
2. Authentication → Providers → Email: **disattiva "Confirm email"** (così la registrazione non dipende dalle email, limitate nel piano free).
3. SQL Editor → incolla `supabase/migrations/001_init.sql` → Run.
4. Primo amministratore: registrati nell'app (passo 4), poi in SQL Editor:
   ```sql
   insert into invites(role,max_uses) values('admin',1) returning code;
   ```
   Usa quel codice alla schermata "codice invito". Gli inviti successivi si generano dal menu dell'app.

## 2. Chiavi notifiche
```
npx web-push generate-vapid-keys
```
- Chiave pubblica → `public/config.js` (`vapid`).
- Secrets della funzione (Supabase → Edge Functions → Secrets, o CLI): `VAPID_PUBLIC`, `VAPID_PRIVATE`, `VAPID_SUBJECT` (`mailto:tua@email`).
- Deploy funzione: `npx supabase login && npx supabase link --project-ref <ref> && npx supabase functions deploy notify`

## 3. Hosting
1. Compila `public/config.js` (url, anon, vapid).
2. Repo GitHub → push su `main` → Settings → Pages → Source: **GitHub Actions**. Il sito esce su `https://<utente>.github.io/<repo>/`.
3. (Consigliato) Secrets repo `SUPABASE_URL` e `SUPABASE_ANON_KEY` per il ping anti-pausa (`keepalive.yml`).

## 4. Installazione per i giocatori
- Manda dal menu app "➕ Invita giocatore" il link su WhatsApp.
- Android: apri il link in Chrome → Installa app. iPhone (iOS 16.4+): Safari → Condividi → **Aggiungi a Home**, poi apri dall'icona e attiva 🔔 dal menu (senza questo passaggio iOS non consegna notifiche).

## Modelli di dati e permessi
- `docs(path,col,id,data)`: players, rosters, matches, events, rsvps, ratings, links, pairs, state.
- Admin: scrive tutto. Giocatore: solo i propri `rsvps`, `ratings` (campo `r` = suo giocatore) e `links`. Imposto tutto con RLS in SQL, non nel client.
- `doc_log`: storico server di ogni insert/update/delete con utente, data, valore vecchio e nuovo (leggibile solo dagli admin).
- Dati esistenti: dal vecchio artifact esporta il backup JSON (menu → Esporta) e importalo da admin (menu → Importa).

## Sviluppo
Solo file statici: `npx serve public`. Modifiche a schema → nuova migration in `supabase/migrations/`.


Deploy attivo su GitHub Pages.
