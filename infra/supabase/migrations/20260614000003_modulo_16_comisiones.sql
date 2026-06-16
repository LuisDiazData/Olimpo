-- Módulo 16: Comisiones, Bonos y Estornos
-- Archivo: 20260614000003_modulo_16_comisiones.sql

-- 1. Tabla de Estados de Cuenta (Cabecera)
CREATE TABLE public.comision_estado_cuenta (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aseguradora_id TEXT NOT NULL, -- Ej: 'GNP', 'METLIFE'
    fecha_corte DATE NOT NULL,
    archivo_url TEXT NOT NULL, -- URL en Supabase Storage
    estado TEXT NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'procesando', 'procesado', 'error')),
    monto_total NUMERIC(15, 2) NOT NULL DEFAULT 0.0,
    moneda TEXT NOT NULL DEFAULT 'MXN',
    procesado_por UUID REFERENCES public.usuario(id),
    creado_en TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    actualizado_en TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.comision_estado_cuenta ENABLE ROW LEVEL SECURITY;

-- 2. Tabla de Recibos / Líneas (Detalle)
CREATE TABLE public.comision_recibo (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    estado_cuenta_id UUID NOT NULL REFERENCES public.comision_estado_cuenta(id) ON DELETE CASCADE,
    poliza_id UUID REFERENCES public.poliza(id) ON DELETE SET NULL, -- Puede ser null si no la encuentra
    numero_poliza_texto TEXT NOT NULL,
    numero_recibo TEXT,
    fecha_pago DATE,
    prima_pagada NUMERIC(15, 2) NOT NULL,
    comision_total NUMERIC(15, 2) NOT NULL,
    comision_agente NUMERIC(15, 2) NOT NULL DEFAULT 0.0,
    comision_promotoria NUMERIC(15, 2) NOT NULL DEFAULT 0.0,
    es_estorno BOOLEAN NOT NULL DEFAULT FALSE,
    moneda TEXT NOT NULL DEFAULT 'MXN',
    creado_en TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE INDEX idx_comision_recibo_poliza_id ON public.comision_recibo(poliza_id);
ALTER TABLE public.comision_recibo ENABLE ROW LEVEL SECURITY;

-- 3. Tabla de Reglas de Split (Porcentajes)
CREATE TABLE public.comision_split_regla (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agente_id UUID NOT NULL REFERENCES public.agente(id) ON DELETE CASCADE,
    ramo TEXT NOT NULL, -- Ej: 'vida', 'autos', 'gmm'
    porcentaje_agente NUMERIC(5, 2) NOT NULL CHECK (porcentaje_agente >= 0 AND porcentaje_agente <= 100),
    creado_en TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(agente_id, ramo)
);

ALTER TABLE public.comision_split_regla ENABLE ROW LEVEL SECURITY;

-- 4. Tabla de Metas y Bonos
CREATE TABLE public.comision_bono_meta (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agente_id UUID NOT NULL REFERENCES public.agente(id) ON DELETE CASCADE,
    ramo TEXT NOT NULL,
    anio INTEGER NOT NULL,
    trimestre INTEGER, -- 1,2,3,4. Si es NULL, es meta anual
    meta_prima NUMERIC(15, 2) NOT NULL,
    bono_ofrecido NUMERIC(15, 2) NOT NULL,
    creado_en TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.comision_bono_meta ENABLE ROW LEVEL SECURITY;

-- Políticas de Seguridad RLS por ROL de aplicación (auth_rol()), no por
-- 'authenticated' genérico: las comisiones son datos financieros sensibles y
-- solo deben verlas/operarlas los roles internos. (DROP previo = idempotente.)
DROP POLICY IF EXISTS "Comisiones: estados_cuenta por rol"  ON public.comision_estado_cuenta;
DROP POLICY IF EXISTS "Comisiones: recibos por rol"         ON public.comision_recibo;
DROP POLICY IF EXISTS "Comisiones: splits por rol"          ON public.comision_split_regla;
DROP POLICY IF EXISTS "Comisiones: bonos por rol"           ON public.comision_bono_meta;

CREATE POLICY "Comisiones: estados_cuenta por rol"
ON public.comision_estado_cuenta FOR ALL
USING       (auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista'))
WITH CHECK  (auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista'));

CREATE POLICY "Comisiones: recibos por rol"
ON public.comision_recibo FOR ALL
USING       (auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista'))
WITH CHECK  (auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista'));

CREATE POLICY "Comisiones: splits por rol"
ON public.comision_split_regla FOR ALL
USING       (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
WITH CHECK  (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY "Comisiones: bonos por rol"
ON public.comision_bono_meta FOR ALL
USING       (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
WITH CHECK  (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- GRANT de tabla: sin esto, bajo RLS el rol authenticated recibe
-- "permission denied for table" (las políticas controlan filas; el GRANT, el acceso).
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
    public.comision_estado_cuenta,
    public.comision_recibo,
    public.comision_split_regla,
    public.comision_bono_meta
TO authenticated;
