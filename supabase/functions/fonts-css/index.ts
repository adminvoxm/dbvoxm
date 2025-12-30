// Deno + Supabase Edge Function (TypeScript)
import { createClient } from "@supabase/supabase-js";
import { serve } from "std/http/server.ts";

// --- Helpers ---

function detectFormat(urlStr: string) {
  const u = urlStr.split("?")[0].toLowerCase();
  if (u.endsWith(".woff2")) return "woff2";
  if (u.endsWith(".woff")) return "woff";
  if (u.endsWith(".otf")) return "opentype";
  if (u.endsWith(".ttf")) return "truetype";
  return "woff2";
}

// Cette fonction prend l'URL stockée en BDD et remplace le domaine
// par celui du projet actuel (Dev ou Prod)
function getCurrentEnvUrl(dbUrl: string) {
  try {
    // 1. On récupère l'URL de base du projet actuel (ex: https://mryfk...supabase.co)
    const currentProjectUrl = Deno.env.get("SUPABASE_URL"); 
    if (!currentProjectUrl) return dbUrl;

    // 2. Si l'URL en base est relative (commence par /), on la complète
    if (dbUrl.startsWith("/")) {
        return `${currentProjectUrl}/storage/v1/object/public${dbUrl}`; // ajuster selon si dbUrl contient déjà /storage... ou juste le bucket
    }

    // 3. Si c'est une URL complète, on remplace juste le début (Domaine + ID Projet)
    const urlObj = new URL(dbUrl);
    const currentObj = new URL(currentProjectUrl);
    
    // On force le domaine à être celui de l'environnement actuel
    urlObj.protocol = currentObj.protocol;
    urlObj.host = currentObj.host;
    
    return urlObj.toString();
  } catch {
    // Si l'URL en base est invalide, on la renvoie telle quelle
    return dbUrl;
  }
}

// CORS whitelist
function makeCorsHeaders(req: Request) {
  const prodUrl = Deno.env.get("PROD_URL") || "";
  const raw = (Deno.env.get("CORS_ALLOWED_ORIGINS") || "").trim();
  // Correction: utiliser .has() pour le Set et nettoyer les espaces
  const allowed = new Set(raw.split(",").map((s) => s.trim()).filter(Boolean));
  const origin = req.headers.get("origin") || "";
  
  // Si l'origine est dans la liste, on l'autorise, sinon on fallback sur prodUrl ou *
  const allow = allowed.has(origin) ? origin : (prodUrl || "*");

  return {
    "content-type": "text/css; charset=utf-8",
    "access-control-allow-origin": allow,
    "access-control-allow-methods": "GET, OPTIONS",
    "access-control-allow-headers": "Content-Type, Authorization",
    "cache-control": "public, max-age=3600, s-maxage=86400"
  };
}

serve(async (req) => {
  const headers = makeCorsHeaders(req);

  // Gestion de la requête OPTIONS (Pre-flight CORS)
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }

  try {
    const url = new URL(req.url);
    const entity = url.searchParams.get("entity");

    if (!entity) {
      return new Response("/* missing ?entity param */", { status: 400, headers });
    }

    // Création du client Supabase
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Récupération des polices
    const { data, error } = await supabase
      .from("font")
      .select("name, font_url, weight, style")
      .eq("entity", entity)
      .order("name", { ascending: true });

    if (error) {
      return new Response(`/* error: ${error.message} */`, { status: 500, headers });
    }

    if (!data || !data.length) {
      return new Response(`/* no fonts for entity=${entity} */`, { status: 200, headers });
    }

    // Génération du CSS
    const css = data.map((f) => {
      const family = String(f.name || "InteractionFont").replace(/"/g, '\\"');
      
      // C'est ICI que la magie opère : on garde le chemin complet (UUID inclus)
      // mais on s'assure que le domaine est le bon.
      const rawUrl = f.font_url || ""; 
      const finalUrl = getCurrentEnvUrl(rawUrl);
      
      const fmt = detectFormat(finalUrl);
      const weight = Number(f.weight ?? 400);
      const style = String(f.style ?? "normal");

      return `
@font-face {
  font-family: "${family}";
  src: url("${finalUrl}") format("${fmt}");
  font-weight: ${weight};
  font-style: ${style};
  font-display: swap;
}`;
    }).join("\n");

    return new Response(css, { status: 200, headers });

  } catch (e) {
    // Gestion d'erreur typée
    const errorMessage = e instanceof Error ? e.message : String(e);
    return new Response(`/* unhandled error: ${errorMessage} */`, { status: 500, headers });
  }
});