import { createClient } from "@supabase/supabase-js";

// Init Supabase client
// NOTE: L'utilisation de la SUPABASE_SERVICE_ROLE_KEY est essentielle ici pour accéder à user_info
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// Gestion des origines autorisées
const rawOrigins = Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "";
const allowedOrigins = rawOrigins.split(",").map((o) => o.trim());
const prodUrl = Deno.env.get("PROD_URL")!;

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || "";
  const corsHeaders = {
    "Access-Control-Allow-Origin": allowedOrigins.includes(origin)
      ? origin
      : prodUrl,
    "Access-Control-Allow-Headers":
      "authorization, content-type, x-client-info, apikey",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Credentials": "true",
  };

  // Preflight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  // POST uniquement
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", {
      status: 405,
      headers: corsHeaders,
    });
  }

  // Lecture du body JSON
  let body;
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON", {
      status: 400,
      headers: corsHeaders,
    });
  }

  const loginOrEmail = body.login?.trim();

  if (!loginOrEmail) {
    return new Response("Missing 'login' field", {
      status: 400,
      headers: corsHeaders,
    });
  }

  // --- Logique de recherche unifiée (Login OU Email) ---

  console.log(`Attempting lookup for: ${loginOrEmail}`);

  // Recherche l'utilisateur où le champ 'login' OU le champ 'email' correspond à l'entrée
  const { data, error } = await supabase
    .from("user_info")
    .select("email")
    .or(`login.eq.${loginOrEmail},email.eq.${loginOrEmail}`)
    .single();

  console.log("SUPABASE ERROR:", error);

  if (error || !data?.email) {
    // Si aucune ligne n'est trouvée (le code d'erreur sera 406 si .single() ne trouve rien)
    return new Response("User not found by login or email", {
      status: 404,
      headers: corsHeaders,
    });
  }

  // Retour de l'email trouvé
  return new Response(
    JSON.stringify({
      email: data.email,
    }),
    {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
      },
    },
  );
});
