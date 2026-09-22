-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Le tableau de bord donne des totaux globaux : combien de fiches, combien
-- traitees, quel taux de conversion. Il ne dit pas OU en est chaque campagne
-- ni chaque lot, alors que c'est la question de pilotage quotidienne : quel
-- lot avance, lequel stagne, lequel est bientot epuise.
--
-- Cette fonction renvoie une ligne par lot, avec deux familles de chiffres :
--
--   - l'avancement, independant du calendrier : combien de fiches au total,
--     combien ont deja ete qualifiees au moins une fois, combien restent
--     disponibles ;
--   - l'activite sur la periode choisie (jour, semaine, mois) : nombre de
--     qualifications et de ventes.
--
-- "Deja traitee" se lit sur clients.type_qualification_id, qui reflete la
-- derniere qualification : une fiche qui en porte une a forcement ete
-- traitee. Cela evite de joindre les 63 000 qualifications pour l'avancement,
-- et ne laisse qu'une seule agregation sur la periode demandee.
--
-- Les lots arretes sont renvoyes eux aussi, avec leur drapeau : c'est une
-- information de pilotage (des fiches y dorment), mais l'interface les
-- distingue pour que la somme des lots actifs corresponde bien au compteur
-- affiche en haut du tableau de bord.

create or replace function public.resultats_par_lot(p_debut timestamptz, p_fin timestamptz)
returns table (
  campagne_id uuid,
  campagne_nom text,
  campagne_active boolean,
  lot_id uuid,
  lot_nom text,
  lot_actif boolean,
  total bigint,
  disponibles bigint,
  en_cours bigint,
  planifiees bigint,
  archivees bigint,
  deja_traitees bigint,
  traitees_periode bigint,
  ventes_periode bigint
)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- Reserve aux profils qui ont acces au tableau de bord. La fonction passe
  -- outre la RLS : sans ce controle, n'importe quel compte authentifie
  -- lirait le detail de toutes les campagnes.
  if not exists (
    select 1 from profils
    where id = auth.uid()
      and role in ('super_admin', 'admin', 'superviseur', 'coach')
  ) then
    raise exception 'Acces refuse.';
  end if;

  return query
  with etat as (
    select c.lot_id,
           count(*)                                                    as total,
           count(*) filter (where c.statut = 'disponible')              as disponibles,
           count(*) filter (where c.statut = 'en_cours')                as en_cours,
           count(*) filter (where c.statut = 'planifie')                as planifiees,
           count(*) filter (where c.statut = 'archive')                 as archivees,
           count(*) filter (where c.type_qualification_id is not null)  as deja_traitees
    from clients c
    where c.lot_id is not null
    group by c.lot_id
  ),
  activite as (
    select c.lot_id,
           count(*)                                   as traitees,
           count(*) filter (where tq.est_vente)       as ventes
    from qualifications q
    join clients c on c.id = q.client_id
    join types_qualification tq on tq.id = q.type_qualification_id
    where q.created_at >= p_debut
      and q.created_at < p_fin
      and c.lot_id is not null
    group by c.lot_id
  )
  select ca.id, ca.nom, coalesce(ca.actif, true),
         l.id, l.nom, coalesce(l.actif, true),
         coalesce(e.total, 0),
         coalesce(e.disponibles, 0),
         coalesce(e.en_cours, 0),
         coalesce(e.planifiees, 0),
         coalesce(e.archivees, 0),
         coalesce(e.deja_traitees, 0),
         coalesce(a.traitees, 0),
         coalesce(a.ventes, 0)
  from lots l
  join campagnes ca on ca.id = l.campagne_id
  left join etat e on e.lot_id = l.id
  left join activite a on a.lot_id = l.id
  order by ca.nom asc, l.nom asc;
end
$function$;

-- Postgres accorde EXECUTE a PUBLIC sur toute nouvelle fonction : il faut le
-- retirer explicitement, sinon le controle de role ci-dessus reste le seul
-- rempart et la fonction est joignable sans etre connecte.
revoke all on function public.resultats_par_lot(timestamptz, timestamptz) from public, anon;
grant execute on function public.resultats_par_lot(timestamptz, timestamptz) to authenticated;
