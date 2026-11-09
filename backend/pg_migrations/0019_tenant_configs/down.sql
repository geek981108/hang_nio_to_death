DO $$ BEGIN
    IF current_schema() = 'public' THEN
        DROP TABLE IF EXISTS public.tenant_configs;
    END IF;
END $$;
