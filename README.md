# Nuovalab

App reale (non più un prototipo) per la gestione di lavorazioni odontotecniche tra laboratori e studi, con ruoli Admin / Laboratorio / Studio / Medico. Backend su Supabase (database, autenticazione, sicurezza), frontend in un unico file HTML.

## Struttura

```
index.html               → l'intera app (login + dashboard di tutti i ruoli)
config.js                 → chiavi di collegamento a Supabase (Project URL + anon key)
database/schema.sql       → schema completo del database, comprese tutte le regole di sicurezza
supabase-functions/
  create-user.ts           → Edge Function usata da Admin per creare accessi e reimpostare password
```

## Come mettere l'app online (GitHub + Render)

### 1. Carica su GitHub
Nella cartella del progetto, da terminale:
```
git init
git add .
git commit -m "Nuovalab - primo rilascio"
git branch -M main
git remote add origin <url-del-tuo-repository-github>
git push -u origin main
```

Nota: `config.js` viene caricato normalmente (non è più escluso). Contiene solo la chiave `anon public` di Supabase, pensata per essere pubblica: la vera protezione dei dati sta nelle regole di sicurezza del database (Row Level Security), non nel nascondere questa chiave.

### 2. Pubblica su Render
1. Vai su [render.com](https://render.com) → **New** → **Static Site**.
2. Collega il repository GitHub appena creato.
3. **Build command**: lascia vuoto.
4. **Publish directory**: `.` (la cartella principale del progetto).
5. Crea il servizio → Render ti darà un indirizzo tipo `https://nuovalab.onrender.com`.

Da quel momento l'app è online e utilizzabile da chiunque abbia un account creato su Supabase — niente più bisogno di aprire `index.html` a mano.

### 3. (Facoltativo, in futuro) Dominio personalizzato
Se acquisti un dominio (es. `nuovalab.it`), lo colleghi da Render → Settings → Custom Domain, seguendo le istruzioni che Render stesso fornisce. Non richiede modifiche al codice.

## Come funziona il database (Supabase)

Tutto lo schema — tabelle, colonne e soprattutto le **regole di sicurezza (RLS)** che isolano i dati tra laboratori/studi diversi — è in `database/schema.sql`. Se un giorno serve ricreare il database da zero, basta incollare l'intero contenuto di quel file nell'SQL Editor di un nuovo progetto Supabase.

## La Edge Function

`supabase-functions/create-user.ts` non fa parte del sito in sé: va incollata a parte nel pannello **Edge Functions** di Supabase (Deploy → Via Editor), perché usa una chiave "master" che non può mai stare nel codice del sito. Serve a permettere all'Admin di:
- creare accessi (email + password) per laboratori, studi e medici già esistenti;
- reimpostare la password di un accesso, se persa.

## Ruoli previsti

- **Admin**: gestisce l'elenco dei laboratori e degli studi della piattaforma, crea i primi accessi.
- **Laboratorio**: riceve le lavorazioni, gestisce materiali/stato/consegne, imposta categorie/prezzi, genera i documenti, vede l'archivio e il consuntivo.
- **Studio**: crea nuove lavorazioni, gestisce pazienti e medici del proprio team, segue lo stato dei lavori, comunica col laboratorio.
- **Medico**: sola lettura sulle proprie prescrizioni, con firma elettronica semplice.

Tutti i ruoli hanno una chat diretta col laboratorio (canale generale per lo studio, canale dedicato per ogni medico).
