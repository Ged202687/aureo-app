# Migration d'Auréo : de Supabase vers un serveur XGS

Document de travail. Rien n'est engagé tant que les deux décisions ouvertes
(§2) ne sont pas tranchées.

---

## 1. La cible

Le front reste sur Cloudflare — rien ne change de ce côté : `wrangler.jsonc`
publie `dist/` en statique. Seule l'API change d'adresse.

```
Navigateur de l'agent
  │
  ├─ (1) charge l'application ──→ Cloudflare Workers  (statique, inchangé)
  │
  └─ (2) appels API ───────────→ api.aureo.xxx
                                   │
                                   ├─ Cloudflare (proxy TLS + WAF)
                                   └─ serveur XGS
                                        ├─ Kong        (passerelle)
                                        ├─ PostgREST   (/rest/v1)
                                        ├─ GoTrue      (/auth/v1)
                                        └─ PostgreSQL  + pg_cron
```

Côté application, la bascule tient en **trois constantes** en haut de
`App.jsx` (`SUPABASE_URL`, `SUPABASE_KEY`, `SUPABASE_ANON_JWT`), un rebuild et
un déploiement Cloudflare.

### Ce que le maintien de Cloudflare implique

**Deux origines distinctes, donc du CORS.** L'application est servie par
Cloudflare, l'API par le serveur : le navigateur exige que l'API autorise
explicitement l'origine du front. À restreindre au domaine d'Auréo — ne pas
recopier le `*` par défaut.

**L'API doit avoir un vrai certificat.** Pas d'auto-signé : le navigateur
refuserait les appels. Le proxy Cloudflare devant l'API règle la question.

**Passer l'API derrière le proxy Cloudflare (nuage orange).** L'IP du serveur
n'est plus exposée, le WAF et la protection DDoS s'appliquent, et le serveur
peut n'accepter que les adresses Cloudflare.

**Cloudflare Tunnel plutôt qu'une ouverture de ports.** Pour un serveur
physique dans les locaux : aucun port à ouvrir, pas besoin d'IP fixe,
fonctionne derrière le NAT, TLS géré par Cloudflare. C'est la réponse au
principal défaut d'un serveur sur une ligne d'entreprise.

**La limite de longueur d'URL reste.** `fetchInChunks()` existe parce que
Cloudflare rejette les URL trop longues en amont de Supabase. L'API restant
derrière Cloudflare, cette contrainte demeure : **ne pas retirer ce
découpage** après la migration.

---

## 2. Décisions ouvertes

| Question | Pourquoi ça compte |
|---|---|
| Serveur physique dans les locaux, ou VPS ? | Le physique impose onduleur, lien Internet fiable et présence sur site. Le VPS donne l'autonomie sans la contrainte matérielle. Le Tunnel Cloudflare rend le physique viable. |
| Qui intervient si ça tombe à 8 h ? | 44 agents s'arrêtent. C'est la vraie question, avant le matériel. |

---

## 3. Ce qui est réellement transporté

Inventaire de ce qu'Auréo utilise aujourd'hui :

| Brique | Usage | Portage |
|---|---|---|
| PostgreSQL | les données (~60 Mo) | `pg_dump` |
| PostgREST | toute l'API — Auréo n'a pas de backend | conteneur |
| GoTrue | connexion, JWT, mots de passe | conteneur |
| RLS + 31 fonctions RPC | logique métier et sécurité | suit la base |
| 4 vues | `vue_rappels_par_agent`, `vue_temps_agent_jour`, `vue_compte_statuts_clients`, `vue_compte_fiches_par_lot` | suit la base |
| pg_cron | remet les fiches « planifiées » en disponible, toutes les 5 min | **à recréer à la main** |

Ni Storage ni Edge Functions : deux briques en moins.

---

## 4. Les six pièges

Dans l'ordre de gravité.

**1. Le job pg_cron.** Il n'est dans aucun fichier du dépôt : il a été créé
dans le tableau de bord. Oublié, aucune fiche ne redevient jamais disponible
— et personne ne s'en aperçoit avant le lendemain matin.
→ Relever sa définition exacte **avant** la migration (`select * from
cron.job;`) et vérifier après restauration qu'il tourne.

**2. Le secret JWT.** `auth.uid()` est utilisé dans 9 migrations, dans la RLS
et au cœur de `get_next_fiche` et `qualifier_fiche`. Conserver le même secret
garde les clés et les sessions valides ; en changer oblige à rediffuser
l'application au même instant.

**3. Les mots de passe.** Ce sont des hachages bcrypt dans `auth.users` : ils
se transportent. **Les 44 agents gardent leur mot de passe** — à condition de
dumper le schéma `auth`, pas seulement `public`. À vérifier par un comptage
de lignes après restauration.

**4. Les rôles.** `anon`, `authenticated`, `service_role` : sans eux, la RLS
ne s'applique pas telle quelle. Dump `--role-only` avant le schéma.

**5. Les extensions.** `pgcrypto`, `uuid-ossp`, `pg_cron`. L'image
`supabase/postgres` les embarque ; un Postgres nu, non.

**6. La version majeure de Postgres.** Identique à celle de Supabase, sinon
la restauration échoue sur des détails difficiles à diagnostiquer un samedi
soir.

---

## 5. Déroulé

### Avant (à froid, sans toucher à la production)

1. Monter le serveur, Docker, et la pile Supabase auto-hébergée
   (`github.com/supabase/supabase`, dossier `docker`).
2. Relever chez Supabase : secret JWT, définition du job pg_cron, version de
   Postgres, liste des extensions.
3. Domaine `api.aureo.xxx`, proxy Cloudflare, Tunnel si serveur physique.
4. **Répétition générale complète** sur une copie, avec deux comptes de test :
   connexion, prise de fiche, qualification, rappel, import, export.

### Le jour J — un samedi soir

5. Couper les campagnes (gel des écritures).
6. Trois dumps, dans cet ordre : rôles, schéma (`public` **et** `auth`),
   données.
7. Restaurer sur le serveur.
8. **Recréer le job pg_cron.**
9. Vérifier : nombre de lignes dans `clients`, `qualifications`,
   `auth.users` ; le job cron actif ; une connexion réelle.
10. Basculer les trois constantes d'`App.jsx`, rebuild, déploiement
    Cloudflare.
11. Test à deux agents sur le nouveau serveur.

### Lundi

12. Surveillance rapprochée la première matinée : c'est là que se voient les
    politiques RLS mal restaurées.

---

## 6. Retour arrière

**Ne rien supprimer chez Supabase pendant un mois.** Tant qu'aucun agent n'a
travaillé sur le nouveau serveur, revenir en arrière consiste à remettre les
trois constantes et redéployer : quelques minutes.

Dès la première fiche qualifiée lundi matin, ce n'est plus vrai : revenir en
arrière perdrait le travail de la journée. C'est la seule porte à sens unique
de l'opération, et elle se referme le lundi à 8 h.

---

## 7. Ce que XGS récupère comme charge

- **Les sauvegardes.** Un `pg_dump` quotidien **hors du serveur**, et une
  restauration **testée** — une sauvegarde jamais restaurée n'est pas une
  sauvegarde.
- **La disponibilité.** Supervision, onduleur, et quelqu'un qui peut
  intervenir.
- **Les mises à jour de sécurité** de Postgres et des conteneurs.

C'est le vrai coût de la migration. Le transfert des données, lui, prend dix
minutes.
