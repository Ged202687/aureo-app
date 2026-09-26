-- Role "direction", morceau 2 sur 3 : les 13 fonctions, modifiees sur place.
--
-- Chaque definition est relue en base ; un seul fragment y est remplace. Si
-- un fragment n'y figure pas exactement une fois, tout s'arrete et RIEN n'est
-- modifie. Une fonction deja a jour est laissee telle quelle.
--
-- A executer dans le SQL Editor apres le morceau 1.

do $$
declare
  remplacements constant text[][] := array[
    -- fonction                              fragment actuel                                           fragment nouveau
    array['public.mon_perimetre_agents()',   'if v_role = ''super_admin'' then',                     'if v_role in (''super_admin'', ''direction'') then'],
    array['public.mon_perimetre_personnes()', 'if v_role = ''super_admin'' then',                     'if v_role in (''super_admin'', ''direction'') then'],
    array['public.supervision_direct()',     'not in (''coach'', ''superviseur'', ''admin'', ''super_admin'')', 'not in (''coach'', ''superviseur'', ''admin'', ''super_admin'', ''direction'')'],
    array['public.resultats_par_lot(timestamptz, timestamptz)', 'role in (''super_admin'', ''admin'', ''superviseur'', ''coach'')', 'role in (''super_admin'', ''admin'', ''superviseur'', ''coach'', ''direction'')'],
    array['public.changer_role(uuid, text)', 'not in (''agent'', ''coach'', ''superviseur'', ''admin'', ''super_admin'')', 'not in (''agent'', ''coach'', ''superviseur'', ''admin'', ''super_admin'', ''direction'')'],
    array['public.est_direction()',          'role in (''admin'', ''super_admin'')',                  'role in (''admin'', ''super_admin'', ''direction'')'],
    array['public.acces_plateau_pour(inet, uuid)', 'role in (''admin'', ''super_admin'')',            'role in (''admin'', ''super_admin'', ''direction'')'],
    array['public.zenith_agents_mois(date, date)', 'not in (''admin'', ''super_admin'')',            'not in (''admin'', ''super_admin'', ''direction'')'],
    array['public.zenith_dates_entree()',    'not in (''admin'', ''super_admin'')',                  'not in (''admin'', ''super_admin'', ''direction'')'],
    array['public.zenith_liste_mouvements(date, date)', 'not in (''admin'', ''super_admin'')',       'not in (''admin'', ''super_admin'', ''direction'')'],
    -- Saisies de Zenith : administration seulement.
    array['public.zenith_modifier_mouvement(uuid, text, text, date)', 'if not est_direction() then', 'if not est_administration() then'],
    array['public.zenith_corriger_dates_entree(jsonb)', 'if not est_direction() then',              'if not est_administration() then'],
    array['public.zenith_definir_projet(uuid, text)', 'if not est_direction() then',                'if not est_administration() then']
  ];
  i int;
  def text;
  n int;
begin
  -- 1. Tout verifier avant de toucher a quoi que ce soit.
  for i in 1 .. array_length(remplacements, 1) loop
    def := pg_get_functiondef(remplacements[i][1]::regprocedure);
    n := (length(def) - length(replace(def, remplacements[i][2], ''))) / length(remplacements[i][2]);
    if n <> 1 and position(remplacements[i][3] in def) = 0 then
      raise exception 'Fragment trouve % fois dans % : script arrete, rien n a ete modifie.', n, remplacements[i][1];
    end if;
  end loop;

  -- 2. Les fonctions, modifiees sur place (deja a jour : laissees telles quelles).
  for i in 1 .. array_length(remplacements, 1) loop
    def := pg_get_functiondef(remplacements[i][1]::regprocedure);
    if position(remplacements[i][3] in def) = 0 then
      execute replace(def, remplacements[i][2], remplacements[i][3]);
    end if;
  end loop;
end $$;

-- Verification : chaque fonction contient bien le role direction (ou la regle
-- d'administration pour les saisies de Zenith).
select p.proname,
       pg_get_functiondef(p.oid) like '%direction%' or pg_get_functiondef(p.oid) like '%est_administration()%' as a_jour
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'mon_perimetre_agents', 'mon_perimetre_personnes', 'supervision_direct', 'resultats_par_lot', 'changer_role',
  'est_direction', 'acces_plateau_pour', 'zenith_agents_mois', 'zenith_dates_entree', 'zenith_liste_mouvements',
  'zenith_modifier_mouvement', 'zenith_corriger_dates_entree', 'zenith_definir_projet')
order by p.proname;
