
import { serve } from "std/http/server.ts";
import { createClient } from "@supabase/supabase-js";

// 1. Init Supabase
const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// 2. Configuration CORS
const rawOrigins = Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "";
const allowedOrigins = rawOrigins.split(",").map((o) => o.trim());
const prodUrl = Deno.env.get("PROD_URL")!;

serve(async (req) => {
    const origin = req.headers.get("origin") || "";
    
    // 3. Headers CORS
    const corsHeaders = {
        "Access-Control-Allow-Origin": allowedOrigins.includes(origin) ? origin : prodUrl,
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Credentials": "true",
        "Content-Type": "application/json"
    };

    // Preflight check
    if (req.method === "OPTIONS") {
        return new Response("ok", { status: 200, headers: corsHeaders });
    }

    if (req.method !== "POST") {
        return new Response(JSON.stringify({ error: "Method Not Allowed" }), { status: 405, headers: corsHeaders });
    }

    let body;
    try {
        body = await req.json();
    } catch {
        return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400, headers: corsHeaders });
    }

    const { interaction_id, point_of_distribution_id } = body;

    // 4. Aiguilleur : Choix de la table et du préfixe
    let tableName = '';
    let recordId = '';
    let prefix = '';

    if (interaction_id) {
        tableName = 'interaction';
        recordId = interaction_id;
        prefix = 'i';
    } else if (point_of_distribution_id) {
        tableName = 'point_of_distribution';
        recordId = point_of_distribution_id;
        prefix = 'c';
    } else {
        return new Response(JSON.stringify({ error: 'IDs manquants (interaction_id ou point_of_distribution_id)' }), { status: 400, headers: corsHeaders });
    }

    // 5. Vérifier si un slug existe DÉJÀ pour cet enregistrement
    // On regarde la colonne 'slug'
    const { data: existing, error: fetchError } = await supabase
        .from(tableName)
        .select('slug') 
        .eq('id', recordId)
        .single();
    
    // Ignorer l'erreur si c'est juste "non trouvé" (PGRST116)
    if (fetchError && fetchError.code !== 'PGRST116') {
        return new Response(JSON.stringify({ error: fetchError.message }), { status: 500, headers: corsHeaders });
    }

    // Si déjà généré, on le renvoie tel quel
    if (existing?.slug) {
        return new Response(
            JSON.stringify({ slug: existing.slug }),
            { status: 200, headers: corsHeaders }
        );
    }

    // 6. Boucle de génération (Retry logic)
    let slug = '';
    let updated = false;
    let attempts = 0;
    const maxAttempts = 5;

    while (!updated && attempts < maxAttempts) {
        attempts++;
        
        // Génère le slug : Prefix + 5 char
        const randomPart = Math.random().toString(36).substring(2, 7).padEnd(5, 'x');
        slug = `${prefix}${randomPart}`; 
        
        // Update sur la colonne 'slug'
        const { error } = await supabase
            .from(tableName)
            .update({ slug: slug }) 
            .eq('id', recordId);

        if (!error) {
            updated = true;
        } else {
            // Si collision (le slug existe déjà sur une autre ligne), on retente
            if (error.code === '23505') {
                console.log(`Collision pour slug ${slug} dans ${tableName}, retry...`);
                continue;
            } else {
                return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: corsHeaders });
            }
        }
    }

    if (!updated) {
        return new Response(JSON.stringify({ error: 'Echec génération unique après 5 essais' }), { status: 500, headers: corsHeaders });
    }

    // 7. Succès : On renvoie juste le slug
    return new Response(
        JSON.stringify({ slug: slug }),
        { status: 200, headers: corsHeaders }
    );
});