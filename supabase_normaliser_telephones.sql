-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor),
-- de preference hors production (apres la derniere vacation ou a la pause
-- dejeuner) : voir "Verrous" plus bas.
--
-- Remet au bon format les numeros des fiches deja importees, avec la meme
-- regle que l'import desormais (formaterTelephone dans App.jsx) :
--   1. on retire les espaces (y compris l'espace insecable d'Excel) ;
--   2. on remplace la lettre O par le chiffre 0 quand le resultat n'est fait
--      que de 9 ou 10 chiffres ("O507118074" -> "0507118074") ;
--   3. s'il reste exactement 9 chiffres, on ajoute le 0 initial perdu par
--      Excel (507118074 -> 0507118074).
-- Tout autre format (indicatif 225, numero incomplet...) est garde tel quel,
-- sans ses espaces.
--
-- Colonnes traitees : clients.telephone et clients.numero_mtn.
-- Mesure au 24/09/2026, sur 72 298 fiches :
--   telephone  : 58 410 a 9 chiffres, 2 682 avec des espaces, 4 avec un O ;
--   numero_mtn : 20 587 a 9 chiffres, 2 001 avec des espaces.
--
-- Declencheurs : session_replication_role = replica les suspend pour cette
-- seule transaction. Sans cela, la date de derniere modification de chaque
-- fiche corrigee passerait a aujourd'hui, et l'ecran Recyclage, qui classe
-- les fiches par anciennete de cette date, perdrait son ordre. Aucun autre
-- declencheur n'est concerne : ils surveillent le statut des fiches et les
-- qualifications, que ce script ne touche pas.
--
-- Verrous : chaque fiche corrigee reste verrouillee jusqu'a la fin du script
-- (quelques secondes). Pendant ce temps, get_next_fiche saute ces fiches, et un
-- agent qui qualifie l'une d'elles attend la fin du script. D'ou le conseil
-- de l'executer hors production.
--
-- Le script s'execute d'un bloc : en cas d'erreur, rien n'est modifie.

set local session_replication_role = replica;

-- La regle, en un seul endroit. pg_temp : la fonction disparait avec la
-- session, elle ne reste pas dans la base.
create function pg_temp.formater_telephone(v text)
returns text
language sql
immutable
as $fonction$
  with sans_espaces as (
    select nullif(regexp_replace(v, '[[:space:] ]', '', 'g'), '') as s
  ),
  sans_o as (
    select case when translate(s, 'Oo', '00') ~ '^[0-9]{9,10}$' then translate(s, 'Oo', '00') else s end as s
    from sans_espaces
  )
  select case when s ~ '^[0-9]{9}$' then '0' || s else s end from sans_o;
$fonction$;

-- Bilan avant correction, pour le resultat affiche a la fin.
create temp table bilan_telephones on commit drop as
select
  count(*) filter (where telephone is distinct from pg_temp.formater_telephone(telephone)) as telephones_corriges,
  count(*) filter (where numero_mtn is distinct from pg_temp.formater_telephone(numero_mtn)) as numeros_mtn_corriges
from clients;

update clients
   set telephone = pg_temp.formater_telephone(telephone)
 where telephone is distinct from pg_temp.formater_telephone(telephone);

update clients
   set numero_mtn = pg_temp.formater_telephone(numero_mtn)
 where numero_mtn is distinct from pg_temp.formater_telephone(numero_mtn);

-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : les deux colonnes "restant_..." a 0.
-- ---------------------------------------------------------------------------
select
  b.telephones_corriges,
  b.numeros_mtn_corriges,
  (select count(*) from clients
    where telephone is distinct from pg_temp.formater_telephone(telephone)) as restant_telephones,
  (select count(*) from clients
    where numero_mtn is distinct from pg_temp.formater_telephone(numero_mtn)) as restant_numeros_mtn
from bilan_telephones b;
