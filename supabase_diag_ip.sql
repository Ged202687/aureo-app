-- Diagnostic TEMPORAIRE (niveau 2 de la securite "plateau") : quelles
-- adresses IP la base recoit-elle avec une requete ?
--
-- Le verrou du niveau 2 compare l'adresse de l'appelant aux adresses du
-- plateau. Avant de s'y fier, il faut savoir quel en-tete porte la vraie
-- adresse et lequel un appelant pourrait falsifier. Cette fonction renvoie
-- seulement les en-tetes d'adresse de SA PROPRE requete (et le nom des autres
-- en-tetes, sans leur valeur) : elle ne revele rien d'autrui.
--
-- A executer une fois dans le SQL Editor. Elle sera supprimee a l'etape
-- suivante (drop function en tete du script du niveau 2).

create or replace function public.diag_ip_appelant()
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'x_forwarded_for', h->>'x-forwarded-for',
    'x_real_ip', h->>'x-real-ip',
    'cf_connecting_ip', h->>'cf-connecting-ip',
    'true_client_ip', h->>'true-client-ip',
    'x_envoy_external_address', h->>'x-envoy-external-address',
    'x_client_ip', h->>'x-client-ip',
    'noms_des_entetes', (select jsonb_agg(k order by k) from jsonb_object_keys(h) as k)
  )
  from (select coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb as h) as s;
$$;

grant execute on function public.diag_ip_appelant() to anon, authenticated;

-- Verification : la fonction existe.
select proname from pg_proc where proname = 'diag_ip_appelant';
