// Deno + Supabase Edge Function (TypeScript)
import { createClient } from "@supabase/supabase-js";
// --- Helpers ---
function detectFormat(from) {
  const u = from.split("?")[0].toLowerCase();
  if (u.endsWith(".woff2")) return "woff2";
  if (u.endsWith(".woff")) return "woff";
  if (u.endsWith(".otf")) return "opentype";
  if (u.endsWith(".ttf")) return "truetype";
  return "woff2";
}
// Construit l'URL finale de la fonte depuis le "basename" (file_name) ou un pathname
function buildFontUrl(fileRef, STORAGE_BASE) {
  // STORAGE_BASE ex: "https://<REF>.supabase.co/storage/v1/object/public/app/font"
  // fileRef ex: "AutumnCrush.woff2" ou "/storage/v1/object/public/app/font/AutumnCrush.woff2"
  const base = STORAGE_BASE.replace(/\/+$/, "");
  const ref = fileRef.startsWith("/") ? fileRef : `/${fileRef}`;
  // Si on nous donne déjà un pathname complet /storage/v1/object/public/... : on ne garde que la dernière partie
  const last = ref.split("/").pop() || "";
  return `${base}/${encodeURIComponent(last)}`;
}
// CORS whitelist via secret (séparé par des virgules)
function makeCorsHeaders(req) {
  const prodUrl = Deno.env.get("PROD_URL")!;
  const raw = (Deno.env.get("CORS_ALLOWED_ORIGINS") || "").trim();
  const allowed = new Set(raw.split(",").map((s) => s.trim()).filter(Boolean));
  const origin = req.headers.get("origin") || "";
  const allow = allowed.has(origin) ? origin : prodUrl;
  return {
    "content-type": "text/css; charset=utf-8",
    "access-control-allow-origin": allow,
    "access-control-allow-methods": "GET, OPTIONS",
    "access-control-allow-headers": "Content-Type, Authorization",
    "cache-control": "public, max-age=3600, s-maxage=86400",
  };
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: makeCorsHeaders(req),
    });
  }
  const headers = makeCorsHeaders(req);
  try {
    const STORAGE_BASE = Deno.env.get("STORAGE_FONT_BASE"); // ex: https://<REF>.supabase.co/storage/v1/object/public/app/font
    if (!STORAGE_BASE) {
      return new Response("/* missing STORAGE_FONT_BASE secret */", {
        status: 500,
        headers,
      });
    }
    const url = new URL(req.url);
    const entity = url.searchParams.get("entity");
    if (!entity) {
      return new Response("/* missing ?entity param */", {
        status: 400,
        headers,
      });
    }
    // ⚙️ ANON key + RLS "published=true" recommandé
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL"),
      Deno.env.get("SUPABASE_ANON_KEY"),
    );
    // Supporte 2 schémas :
    //  - file_name (recommandé)  → nom de fichier seulement
    //  - font_url (legacy)       → URL complète; on n'utilise que le pathname
    const { data, error } = await supabase.from("font").select(
      "name, name, font_url, weight, style",
    ).eq("entity", entity).order("name", {
      ascending: true,
    }).order("weight", {
      ascending: true,
    });
    if (error) {
      return new Response(`/* error: ${error.message} */`, {
        status: 500,
        headers,
      });
    }
    if (!data || !data.length) {
      return new Response(`/* no fonts for entity=${entity} */`, {
        status: 200,
        headers,
      });
    }
    const css = data.map((f) => {
      const family = String(f.name || "InteractionFont").replace(/"/g, '\\"');
      // Résout la cible finale depuis file_name OU depuis font_url (pathname)
      let ref = "";
      if (f.name) {
        ref = f.name; // ex: "AutumnCrush.woff2"
      } else if (f.font_url) {
        try {
          ref = new URL(String(f.font_url)).pathname; // ex: "/storage/v1/object/public/app/font/AutumnCrush.woff2"
        } catch {
          // fallback : on traite comme un simple nom de fichier
          ref = String(f.font_url);
        }
      }
      const finalUrl = buildFontUrl(ref, STORAGE_BASE);
      const fmt = detectFormat(ref);
      const weight = Number(f.weight ?? 400);
      const style = String(f.style ?? "normal");
      return `
@font-face{
  font-family:"${family}";
  src:url("${finalUrl}") format("${fmt}");
  font-weight:${weight};
  font-style:${style};
  font-display:swap;
}`;
    }).join("\n");
    return new Response(css, {
      status: 200,
      headers,
    });
  } catch (e) {
    const errorMessage = e instanceof Error ? e.message : String(e);

return new Response(`/* unhandled error: ${errorMessage} */`, {
  headers: { "content-type": "application/json" },
  status: 500,
});
  }
});
