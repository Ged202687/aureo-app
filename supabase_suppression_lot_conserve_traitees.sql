-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. S'execute d'un bloc : en cas d'erreur, rien
-- n'est modifie.
--
-- Supprimer un lot effacait ses fiches ET leurs qualifications. Le travail
-- deja fait disparaissait donc de l'export, des resultats par agent, des
-- evaluations qualite : un lot supprime en fin de mois faisait baisser apres
-- coup les chiffres du mois.
--
-- Desormais, supprimer un lot :
--   - efface les fiches jamais traitees (aucune qualification) : elles n'ont
--     aucun historique a proteger ;
--   - CONSERVE les fiches deja traitees, avec toutes leurs qualifications,
--     mais les sort du circuit : statut archive, sans agent, sans date de
--     retour. Plus aucun agent ne les recoit, ni par la file ni par le
--     recyclage (le lot n'y est plus propose) ;
--   - retire les cibles du lot (agents et groupes) ;
--   - garde le lot lui-meme, marque supprime (supprime_le), arrete, et
--     renomme "<nom> (supprime le JJ/MM/AAAA)" : l'export et le tableau de
--     bord continuent d'afficher d'ou vient le travail, en le signalant.
--     L'application ne le propose plus a l'import, dans Campagnes ni au
--     recyclage. S'il ne reste aucune fiche traitee, le lot est efface.
--
-- La fonction renvoie desormais le detail : fiches effacees et fiches
-- conservees. Son type de retour change, d'ou le drop prealable.
--
-- Les lots deja supprimes avant ce script ont perdu leurs qualifications :
-- elles ne peuvent pas etre recuperees ici (seule une sauvegarde Supabase le
-- permettrait).

alter table lots add column if not exists supprime_le timestamptz;
alter table lots add column if not exists supprime_par uuid references profils(id);

comment on column lots.supprime_le is
  'Lot supprime : ses fiches traitees sont conservees (archivees) pour l''historique, le lot n''est plus propose dans l''application.';

drop function if exists public.admin_delete_lot(uuid);

create function public.admin_delete_lot(p_lot_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_lot lots;
  v_effacees integer;
  v_conservees integer;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Acces refuse : reserve aux administrateurs.';
  end if;

  select * into v_lot from lots where id = p_lot_id for update;
  if v_lot.id is null then
    raise exception 'Lot introuvable.';
  end if;
  if v_lot.supprime_le is not null then
    raise exception 'Ce lot est deja supprime.';
  end if;

  delete from lots_cibles where lot_id = p_lot_id;

  -- Fiches jamais traitees : effacees.
  delete from clients c
   where c.lot_id = p_lot_id
     and not exists (select 1 from qualifications q where q.client_id = c.id);
  get diagnostics v_effacees = row_count;

  -- Fiches traitees : conservees, sorties du circuit.
  update clients
     set statut = 'archive', agent_id = null, visible_apres = null
   where lot_id = p_lot_id;
  get diagnostics v_conservees = row_count;

  if v_conservees = 0 then
    delete from lots where id = p_lot_id;
  else
    update lots
       set actif = false,
           supprime_le = now(),
           supprime_par = auth.uid(),
           nom = nom || ' (supprimé le ' || to_char(now() at time zone 'Africa/Abidjan', 'DD/MM/YYYY') || ')'
     where id = p_lot_id;
  end if;

  return jsonb_build_object('fiches_effacees', v_effacees, 'fiches_conservees', v_conservees);
end;
$function$;

revoke execute on function public.admin_delete_lot(uuid) from public, anon;
grant execute on function public.admin_delete_lot(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : colonne_supprime_le = 1, fonction_a_jour = true.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select count(*) from information_schema.columns
    where table_name = 'lots' and column_name = 'supprime_le') as colonne_supprime_le,
  (select pg_get_function_result('public.admin_delete_lot(uuid)'::regprocedure) = 'jsonb') as fonction_a_jour;
