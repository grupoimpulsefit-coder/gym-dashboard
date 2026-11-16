-- ══════════════════════════════════════════════════════════════════════════
--  CAJA — diferencia de efectivo al ABRIR el turno
--  Correr en Supabase → SQL Editor, después de caja.sql y cierres_proteccion.sql.
--  Se puede repetir sin problema.
--
--  Al abrir un turno, la base busca el último turno cerrado de la sede:
--    · turno 1 del día → el último cierre del día anterior (o del último día
--      con caja, si hubo días sin abrir);
--    · turno 2 en adelante → el turno anterior del mismo día.
--  Compara el efectivo con que se abre contra el que dejó ese cierre
--  (efectivo final) y guarda la diferencia como leyenda del turno. NO bloquea
--  nada: la caja del día funciona igual.
--  Si ese cierre guardó los billetes que quedaron en caja, también compara
--  billete por billete. Si sacó el sobre del conteo, no se puede (se avisa).
--  La cuenta la hace este trigger: el navegador no la puede cambiar.
-- ══════════════════════════════════════════════════════════════════════════

alter table cierres_caja add column if not exists apertura_esperado   numeric;   -- efectivo que dejó el cierre anterior
alter table cierres_caja add column if not exists apertura_diferencia numeric;   -- contado − esperado (negativo = abrió con menos)
alter table cierres_caja add column if not exists apertura_ref        jsonb;     -- { id, fecha, turno_num, estado, por, hora_cierre, den }
alter table cierres_caja add column if not exists apertura_den_dif    jsonb;     -- { "5000": -1, "1000": 2 } (solo si se puede comparar)
alter table cierres_caja add column if not exists apertura_motivo     text;      -- opcional, lo escribe quien abre
alter table cierres_caja add column if not exists apertura_avisado_at timestamptz; -- cuándo se avisó al teléfono

-- Total en colones de un desglose { "20000": 3, "5000": 1, … }
create or replace function _den_total(d jsonb)
returns numeric language sql immutable as $$
  select coalesce(sum(k::numeric * coalesce(nullif(v #>> '{}', '')::numeric, 0)), 0)
    from jsonb_each(coalesce(d, '{}'::jsonb)) as e(k, v)
   where k ~ '^\d+$' and jsonb_typeof(v) in ('number', 'string');
$$;

-- Diferencia por billete: nuevo − referencia, solo los que no calzan
create or replace function _den_dif(nuevo jsonb, ref jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, dif), '{}'::jsonb) from (
    select k, coalesce(nullif(nuevo ->> k, '')::numeric, 0) - coalesce(nullif(ref ->> k, '')::numeric, 0) as dif
      from (select jsonb_object_keys(coalesce(nuevo, '{}'::jsonb)) as k
            union select jsonb_object_keys(coalesce(ref, '{}'::jsonb))) ks
     where k ~ '^\d+$'
  ) t where dif <> 0;
$$;

create or replace function cierres_apertura_ref()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r cierres_caja;
  esp numeric;
  comparable boolean;
begin
  if tg_op = 'INSERT' then
    new.apertura_esperado := null; new.apertura_ref := null; new.apertura_avisado_at := null;
    if coalesce(new.estado, '') = 'abierto' then
      select * into r from cierres_caja c
       where c.sede = new.sede and coalesce(c.estado, 'final') in ('parcial', 'final')
         and (c.fecha < new.fecha or (c.fecha = new.fecha and coalesce(c.turno_num, 0) < coalesce(new.turno_num, 0)))
       order by c.fecha desc, c.turno_num desc nulls last, c.created_at desc
       limit 1;
      if r.id is not null then
        esp := round(coalesce(nullif(r.efectivo_final, 0), r.efectivo, 0));
        -- Por billete solo si lo contado en ese cierre es lo que quedó en caja (no sacó el sobre del conteo)
        comparable := jsonb_typeof(r.denominaciones) = 'object' and esp > 0 and _den_total(r.denominaciones) = esp;
        new.apertura_esperado := esp;
        new.apertura_ref := jsonb_build_object('id', r.id, 'fecha', r.fecha, 'turno_num', r.turno_num,
          'estado', coalesce(r.estado, 'final'), 'por', r.created_by, 'hora_cierre', r.hora_cierre,
          'den', case when comparable then r.denominaciones end);
      end if;
    end if;
  else
    -- La referencia no se cambia después de abrir; el aviso solo se marca una vez
    new.apertura_esperado := old.apertura_esperado;
    new.apertura_ref := old.apertura_ref;
    new.apertura_avisado_at := coalesce(old.apertura_avisado_at, new.apertura_avisado_at);
  end if;

  if new.apertura_esperado is not null then
    new.apertura_diferencia := round(coalesce(new.caja_inicial, 0) - new.apertura_esperado);
    new.apertura_den_dif := case when jsonb_typeof(new.apertura_ref -> 'den') = 'object' and jsonb_typeof(new.denominaciones_apertura) = 'object'
                                 then _den_dif(new.denominaciones_apertura, new.apertura_ref -> 'den') end;
  else
    new.apertura_diferencia := null;
    new.apertura_den_dif := null;
  end if;
  new.apertura_motivo := nullif(left(trim(coalesce(new.apertura_motivo, '')), 300), '');
  return new;
end $$;

drop trigger if exists cierres_apertura_ref on cierres_caja;
create trigger cierres_apertura_ref
  before insert or update on cierres_caja
  for each row execute function cierres_apertura_ref();

-- Comprobación: últimas aperturas con su diferencia
select fecha, turno_num, caja_inicial, apertura_esperado, apertura_diferencia
  from cierres_caja where apertura_esperado is not null
 order by fecha desc, turno_num desc limit 5;
