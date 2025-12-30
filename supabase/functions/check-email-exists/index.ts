import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Init Supabase client avec la clé de rôle de service
const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// Configuration CORS
const rawOrigins = Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "";
const allowedOrigins = rawOrigins.split(",").map((o) => o.trim());
const prodUrl = Deno.env.get("PROD_URL")!

serve(async (req) => {
    const origin = req.headers.get("origin") || "";
    
    // En-têtes CORS dynamiques
    const corsHeaders = {
        "Access-Control-Allow-Origin": allowedOrigins.includes(origin) ? origin : prodUrl,
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Credentials": "true",
        "Content-Type": "application/json"
    };

    // 1. Gestion de la requête Preflight CORS (OPTIONS)
    if (req.method === "OPTIONS") {
        return new Response("ok", { status: 200, headers: corsHeaders });
    }

    // 2. Vérification de la méthode (POST uniquement pour la logique)
    if (req.method !== "POST") {
        return new Response(JSON.stringify({ error: "Method Not Allowed" }), {
            status: 405,
            headers: corsHeaders
        });
    }

    // Lecture du body JSON
    let body;
    try {
        body = await req.json();
    } catch {
        return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
            status: 400,
            headers: corsHeaders
        });
    }

    const email = body.email?.trim();

    if (!email) {
        return new Response(JSON.stringify({ error: "Missing 'email' field" }), {
            status: 400,
            headers: corsHeaders
        });
    }

    // --- LOGIQUE DE VÉRIFICATION D'EXISTENCE AVEC ID ---

    console.log(`Checking existence for email: ${email}`);

    // Requête modifiée : on sélectionne l'email ET l'id
    const { data, error } = await supabase
        .from("user_info")
        .select("id, email") // <-- Changement ici
        .eq("email", email)
        .limit(1); 

    if (error) {
        console.error("Supabase Error:", error);
        return new Response(JSON.stringify({ error: "Database query failed" }), {
            status: 500,
            headers: corsHeaders
        });
    }

    // Si data est non nul et contient un résultat
    const exists = data.length > 0;
    
    // Récupération de l'ID (sera undefined si exists est false)
    const userId = exists ? data[0].id : null; 

    // Retourne un statut 200 avec le résultat booléen et l'ID
    return new Response(JSON.stringify({ 
        email: email,
        exists: exists,
        id: userId // <-- Ajout du champ id
    }), {
        status: 200,
        headers: corsHeaders
    });
});